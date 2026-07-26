#!/bin/bash
# atelier-telemetry-collector.sh — harness-atelier telemetry: record every
#                                  context transfer between the orchestrator
#                                  and its subagent processes.
#
# Hook    : PreToolUse:Agent   (dispatch  — context DOWN into a subagent)
#           PostToolUse:Agent  (return    — context UP into the orchestrator)
#           PostToolUse:Bash   (command   — per-context activity + ingest leaks)
#           PostToolUse:Read|Write|Edit|Grep|Glob|Skill|WebFetch|WebSearch
#                              (tool/skill — generic context ingestion)
# Mode    : silent allow (pure observer, never blocks, best-effort writes)
# Scope   : harness-atelier is a GENERAL utility, not achilles-only.
#           Collection is on in any project that opts in — an achilles
#           project (lib/achilles-project-gate.sh), a `.atelier` marker
#           file at the repo root (any Claude Code experiment), or
#           ATELIER_TELEMETRY=on forced via env. Everywhere else: inert.
# State   : appends JSONL to <project>/.achilles/atelier-telemetry.jsonl
# Env     : ATELIER_TELEMETRY=off → disable collection
#           ATELIER_TELEMETRY=on  → collect regardless of project markers
#
# Why
# ---
# The agentic-OS harness is built around one budget: ORCHESTRATOR CONTEXT.
# Whether the harness is working cannot be assessed from vibes — it needs
# the actual byte flows: how much brief went down into each dispatch, how
# much return came back up, what each context pulled in through Bash, and
# where payload content crossed a boundary it shouldn't have. This
# collector records exactly that, one JSON line per transfer, so
# `npm run atelier` (scripts/atelier/harness-atelier.mjs) can render the
# context-flow map, per-agent context use, compression ratios, and the
# leak panel that points at the precise event where a leak happened.
#
# Event shapes (all carry ts, event, actor, role):
#   dispatch — {tool_use_id, role, brief_bytes, description}
#              actor is always "orchestrator" for top-level dispatches;
#              a nested dispatch records the dispatching agent_id.
#   return   — {tool_use_id?, role, return_bytes, leak?}
#              leak set when the return violates "structured summary
#              only": oversized, or carrying a pasted source block —
#              context leaking UP into the orchestrator window.
#   skill    — {skill, bytes_out} — a Skill invocation and the bytes of
#              instruction content it injected into the executing
#              context. The visualizer segments context consumption by
#              skill from these markers.
#   tool     — {tool, bytes_in, bytes_out} — generic context ingestion
#              for non-Agent/non-Bash tools (Read/Grep/WebFetch/...):
#              bytes_out is what landed in the executing context's
#              window.
#   command  — {role, tool, bytes_out, leak?, command_head}
#              bytes_out = stdout returned into the executing context.
#              leak set for orchestrator commands with payload-ingest
#              shape (dump command × payload artifact — same detector
#              vocabulary as agent-role-privilege-guard.sh): if such a
#              command RAN (guard off / pre-guard build), the leak is
#              recorded with the command itself as evidence.
#
# Leak channels reported: bash-ingest (orchestrator dump command ran),
# oversized-return (> ATELIER_RETURN_BUDGET bytes, default 8000),
# pasted-source-return (fenced code block > 1200 chars inside a return).
#
# Failure posture: every write is best-effort (|| true); a telemetry
# failure must never affect the tool call being observed.
#
# Pairs with:
#   scripts/atelier/harness-atelier.mjs   (the visualizer this feeds)
#   hooks/agentic-process-registrar.sh    (role vocabulary via shared lib)
#
# Canonical reference
# -------------------
# skills/element-interactions/references/harness-atelier.md

set -uo pipefail

[ "${ATELIER_TELEMETRY:-on}" = "off" ] && exit 0

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
[ -n "$JQ" ] || exit 0   # observer: no jq → no telemetry, never an error

# shellcheck source=lib/agent-role-privileges.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/agent-role-privileges.sh"
# shellcheck source=lib/agent-process-table.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/agent-process-table.sh"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")
EVENT_NAME=$(echo "$INPUT" | "$JQ" -r '.hook_event_name // empty' 2>/dev/null || echo "")
AGENT_ID=$(echo "$INPUT" | "$JQ" -r '.agent_id // empty' 2>/dev/null || echo "")
PARENT_ID=$(echo "$INPUT" | "$JQ" -r '.parent_tool_use_id // empty' 2>/dev/null || echo "")

GUARD_CWD=$(echo "$INPUT" | "$JQ" -r '.cwd // "."' 2>/dev/null || echo ".")
REPO_ROOT=$(cd "$GUARD_CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || echo "$GUARD_CWD")

# Opt-in scope: achilles project, a generic `.atelier` marker (any Claude
# Code experiment), or forced on via env. Inert everywhere else.
# shellcheck source=lib/achilles-project-gate.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/achilles-project-gate.sh"
if [ "${ATELIER_TELEMETRY:-auto}" != "on" ]; then
  achilles_hooks_active "$REPO_ROOT" || [ -e "$REPO_ROOT/.atelier" ] || exit 0
fi

LOG_DIR="$REPO_ROOT/.achilles"
LOG_FILE="$LOG_DIR/atelier-telemetry.jsonl"

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RETURN_BUDGET="${ATELIER_RETURN_BUDGET:-8000}"

emit() {
  # emit <json-line> — best-effort append.
  { mkdir -p "$LOG_DIR" 2>/dev/null && printf '%s\n' "$1" >> "$LOG_FILE"; } 2>/dev/null || true
}

# Actor identity for this tool call.
actor_fields() {
  # Sets ACTOR ("orchestrator" | agent_id) and ROLE.
  if [ -z "$AGENT_ID" ]; then
    ACTOR="orchestrator"; ROLE="orchestrator"
    return 0
  fi
  ACTOR="$AGENT_ID"
  apt_load_live "$REPO_ROOT"
  apt_resolve_actor "$PARENT_ID" "${CLAIMED_SLUG:-}"
  ROLE="$ACTOR_ROLE"
}

case "$TOOL_NAME:$EVENT_NAME" in
  # ==========================================================================
  Agent:PreToolUse)
    DESCRIPTION=$(echo "$INPUT" | "$JQ" -r '.tool_input.description // ""' 2>/dev/null || echo "")
    PROMPT_BYTES=$(echo "$INPUT" | "$JQ" -r '(.tool_input.prompt // "") | length' 2>/dev/null || echo 0)
    DESC_BYTES=${#DESCRIPTION}
    TOOL_USE_ID=$(echo "$INPUT" | "$JQ" -r '.tool_use_id // empty' 2>/dev/null || echo "")
    DESC_TRIMMED=$(echo "$DESCRIPTION" | sed -E 's/^[[:space:]]+//')
    if ! DISPATCH_ROLE=$(resolve_privilege_role "$DESC_TRIMMED"); then
      DISPATCH_ROLE="unconfined"
    fi
    CLAIMED_SLUG=""
    actor_fields
    LINE=$("$JQ" -nc \
      --arg ts "$TS" --arg actor "$ACTOR" --arg role "$ROLE" \
      --arg id "$TOOL_USE_ID" --arg drole "$DISPATCH_ROLE" \
      --arg desc "${DESCRIPTION:0:120}" \
      --argjson brief "$((PROMPT_BYTES + DESC_BYTES))" \
      '{ts:$ts, event:"dispatch", actor:$actor, role:$role,
        tool_use_id:$id, dispatch_role:$drole, brief_bytes:$brief,
        description:$desc}' 2>/dev/null || echo "")
    [ -n "$LINE" ] && emit "$LINE"
    ;;

  # ==========================================================================
  Agent:PostToolUse)
    DESCRIPTION=$(echo "$INPUT" | "$JQ" -r '.tool_input.description // ""' 2>/dev/null || echo "")
    TOOL_USE_ID=$(echo "$INPUT" | "$JQ" -r '.tool_use_id // empty' 2>/dev/null || echo "")
    DESC_TRIMMED=$(echo "$DESCRIPTION" | sed -E 's/^[[:space:]]+//')
    if ! DISPATCH_ROLE=$(resolve_privilege_role "$DESC_TRIMMED"); then
      DISPATCH_ROLE="unconfined"
    fi
    # Return text — same multi-shape extraction as the schema guard.
    RESPONSE=$(echo "$INPUT" | "$JQ" -r '
      [
        (.tool_response.output? | if type == "array" then map(.text? // (. | tostring)) | join("\n") elif type == "string" then . else (. | tostring) end),
        (.tool_response.content? | if type == "array" then map(.text? // empty) | join("\n") else empty end),
        (if (.tool_response | type) == "string" then .tool_response else empty end)
      ] | map(select(. != null and . != "")) | unique | join("\n")
    ' 2>/dev/null || echo "")
    RET_BYTES=${#RESPONSE}

    # Leak heuristics on the RETURN channel (context flowing UP).
    LEAK_CHANNEL=""
    LEAK_EVIDENCE=""
    if [ "$RET_BYTES" -gt "$RETURN_BUDGET" ]; then
      LEAK_CHANNEL="oversized-return"
      LEAK_EVIDENCE="return is ${RET_BYTES} bytes (budget ${RETURN_BUDGET})"
    fi
    if [ -z "$LEAK_CHANNEL" ] && [ "$RET_BYTES" -gt 0 ]; then
      # Fenced block > 1200 chars → pasted source / transcript in a return.
      FENCE_MAX=$(printf '%s' "$RESPONSE" | awk '
        /^```/ { if (inb) { if (len > max) max = len; inb = 0 } else { inb = 1; len = 0 } ; next }
        inb    { len += length($0) + 1 }
        END    { if (inb && len > max) max = len; print max + 0 }
      ' 2>/dev/null || echo 0)
      if [ "${FENCE_MAX:-0}" -gt 1200 ]; then
        LEAK_CHANNEL="pasted-source-return"
        LEAK_EVIDENCE="fenced block of ${FENCE_MAX} chars inside the return"
      fi
    fi

    LINE=$("$JQ" -nc \
      --arg ts "$TS" --arg id "$TOOL_USE_ID" --arg drole "$DISPATCH_ROLE" \
      --arg desc "${DESCRIPTION:0:120}" \
      --argjson ret "$RET_BYTES" \
      --arg lc "$LEAK_CHANNEL" --arg le "$LEAK_EVIDENCE" \
      '{ts:$ts, event:"return", actor:"orchestrator", role:"orchestrator",
        tool_use_id:$id, dispatch_role:$drole, return_bytes:$ret,
        description:$desc}
       + (if $lc != "" then {leak:{channel:$lc, evidence:$le}} else {} end)' \
      2>/dev/null || echo "")
    [ -n "$LINE" ] && emit "$LINE"
    ;;

  # ==========================================================================
  Bash:PostToolUse)
    CMD=$(echo "$INPUT" | "$JQ" -r '.tool_input.command // ""' 2>/dev/null || echo "")
    [ -n "$CMD" ] || exit 0
    OUT_BYTES=$(echo "$INPUT" | "$JQ" -r '
      [(.tool_response.stdout? // ""), (.tool_response.output? // "" | tostring)]
      | map(length) | max // 0
    ' 2>/dev/null || echo 0)
    CLAIMED_SLUG=$(apt_extract_slug "$CMD")
    actor_fields

    # Ingest-leak detection: orchestrator ran a payload dump. Same
    # detector vocabulary as agent-role-privilege-guard.sh — if it fired
    # here, the dump actually EXECUTED (guard off or pre-guard build):
    # this event is the exact place the leak happened.
    LEAK_CHANNEL=""
    LEAK_EVIDENCE=""
    if [ "$ACTOR" = "orchestrator" ]; then
      WORD='(^|[;&|(][[:space:]]*)((command|env)[[:space:]]+)?'
      ARTIFACT='\.spec\.(ts|js|mjs|tsx)|\.subagent-returns|\.playwright-cli/|test-results/|playwright-report/|trace\.zip|\.har([[:space:]]|$)'
      if echo "$CMD" | grep -qE "${WORD}(cat|head|tail|less|more|nl|strings|base64|xxd|od)[[:space:]]" \
        && echo "$CMD" | grep -qE "$ARTIFACT"; then
        LEAK_CHANNEL="bash-ingest"
        LEAK_EVIDENCE="payload dump executed in orchestrator context: ${CMD:0:160}"
      fi
    fi

    LINE=$("$JQ" -nc \
      --arg ts "$TS" --arg actor "$ACTOR" --arg role "$ROLE" \
      --arg head "${CMD:0:120}" \
      --argjson out "${OUT_BYTES:-0}" \
      --arg lc "$LEAK_CHANNEL" --arg le "$LEAK_EVIDENCE" \
      '{ts:$ts, event:"command", actor:$actor, role:$role,
        tool:"Bash", bytes_out:$out, command_head:$head}
       + (if $lc != "" then {leak:{channel:$lc, evidence:$le}} else {} end)' \
      2>/dev/null || echo "")
    [ -n "$LINE" ] && emit "$LINE"
    ;;

  # ==========================================================================
  *:PostToolUse)
    # Generic context-ingestion event for every other matched tool
    # (Read/Write/Edit/Grep/Glob/Skill/WebFetch/WebSearch). bytes_out is
    # what the tool put into the executing context's window; a Skill
    # invocation is additionally recorded as a skill-segment marker the
    # visualizer uses to attribute subsequent consumption per skill.
    BYTES_IN=$(echo "$INPUT" | "$JQ" -r '(.tool_input // {}) | tostring | length' 2>/dev/null || echo 0)
    BYTES_OUT=$(echo "$INPUT" | "$JQ" -r '(.tool_response // "") | tostring | length' 2>/dev/null || echo 0)
    CLAIMED_SLUG=""
    actor_fields
    if [ "$TOOL_NAME" = "Skill" ]; then
      SKILL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_input.skill // .tool_input.command // ""' 2>/dev/null || echo "")
      LINE=$("$JQ" -nc \
        --arg ts "$TS" --arg actor "$ACTOR" --arg role "$ROLE" \
        --arg skill "$SKILL_NAME" \
        --argjson bin "${BYTES_IN:-0}" --argjson bout "${BYTES_OUT:-0}" \
        '{ts:$ts, event:"skill", actor:$actor, role:$role,
          skill:$skill, bytes_in:$bin, bytes_out:$bout}' 2>/dev/null || echo "")
    else
      LINE=$("$JQ" -nc \
        --arg ts "$TS" --arg actor "$ACTOR" --arg role "$ROLE" \
        --arg tool "$TOOL_NAME" \
        --argjson bin "${BYTES_IN:-0}" --argjson bout "${BYTES_OUT:-0}" \
        '{ts:$ts, event:"tool", actor:$actor, role:$role,
          tool:$tool, bytes_in:$bin, bytes_out:$bout}' 2>/dev/null || echo "")
    fi
    [ -n "$LINE" ] && emit "$LINE"
    ;;

  *) exit 0 ;;
esac

exit 0
