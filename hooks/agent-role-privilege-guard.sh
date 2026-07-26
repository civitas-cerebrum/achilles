#!/bin/bash
# agent-role-privilege-guard.sh — agentic-OS privilege enforcement: deny
#                                 command classes the executing context's
#                                 role does not hold.
#
# Hook    : PreToolUse:Bash  (command-class enforcement)
#           PreToolUse:Agent (role-required + nested-dispatch enforcement)
#           PreToolUse:Read  (orchestrator payload-ingest, Read vector)
# Mode    : DENY (privilege violation) / silent allow (everything else)
# Scope   : achilles projects only (lib/achilles-project-gate.sh) — inert
#           in every other repo even though installed globally.
# State   : reads <project>/.achilles/.agent-process-table.json
#           (written by agentic-process-registrar.sh; never writes it)
# Env     : AGENT_ROLE_PRIVILEGE_GUARD=off → disable (calibration escape hatch)
#           AGENTIC_OS_ROLE_REQUIRED=off   → allow role-less dispatches
#                                            during live pipelines
#
# Every deny ends with a transcript-aware methodology citation
# (lib/methodology-citation.sh): if the executing context never loaded
# the agentic-OS spec, the deny instructs a Read of it as the mandatory
# next step; if it did, the deny points back at the section to re-apply.
#
# Model
# -----
# The harness is an agentic OS: subagent dispatch is process creation, the
# description prefix is the login name, lib/agent-role-privileges.sh is
# passwd + sudoers, and this hook is the kernel's capability check on every
# syscall (Bash command / nested dispatch). A tool call from a dispatched
# subagent carries a non-empty `agent_id`; the orchestrator's carry none —
# that distinction is the ring boundary.
#
# Privilege classes enforced here (vocabulary + per-role assignment live in
# lib/agent-role-privileges.sh):
#
#   payload-ingest — ORCHESTRATOR-denied. Bash dumps of subagent payload
#                    artifacts (test spec source, .subagent-returns/ spill
#                    files, .playwright-cli/ traces, test-results/,
#                    playwright-report/, HAR/trace archives). This is the
#                    class that leaks subagent context upward into the
#                    orchestrator window — the isolation contract's "never
#                    hold subagent payload content" rule, made mechanical.
#                    Metadata reads (ls, wc, find, grep -c/-l, stat) stay
#                    allowed; the Read tool is ungated here (subagents use
#                    it on their OWN slice by contract). Enforced only when
#                    a pipeline is live (process table has live entries or
#                    a pipeline ledger exists) so ordinary dev sessions are
#                    untouched.
#   mutate         — write-shaped Bash, denied to read-only verifier roles
#                    (reviewer-inloop, workflow-reviewer, perf-reviewer,
#                    phase-validator, process-validator). Scratch writes
#                    under /dev/null, /tmp, $TMPDIR stay allowed.
#   browser        — playwright-cli, denied to text-only roles (cleanup,
#                    phase4-prioritise-author).
#   dispatch       — nested Agent dispatch, denied to every known role
#                    (single-level fan-out: only the orchestrator creates
#                    processes).
#   remote-push    — git push, denied to every known role.
#
# Role resolution for a subagent context, in order:
#   1. `parent_tool_use_id` → live process-table entry (exact; emitted by
#      some builds).
#   2. Role claim via the `-s=<slug>` playwright-cli session flag — the
#      slug convention puts the same role prefix on both ends (enforced
#      1:1 by playwright-cli-isolation-guard.sh).
#   3. Exactly one live role class in the process table → that role.
#   4. Multiple live role classes → INTERSECTION: deny a class only when
#      every live process denies it (sound under ambiguity — never
#      stricter than the weakest live process; "unconfined" free-form
#      dispatches are registered precisely so they weaken this
#      intersection to nothing).
#   5. Empty/absent table → unconfined (fail-open).
#
# Failure → action
# ----------------
# - Subagent Bash exercising a class its role lacks       → DENY
# - Subagent nested Agent dispatch (role lacks dispatch)  → DENY
# - Orchestrator Bash dumping payload artifacts, pipeline live → DENY
# - Role unresolvable and live intersection empty          → silent allow
# - Orchestrator dispatches, metadata reads, scratch writes → silent allow
#
# Pairs with:
#   hooks/agentic-process-registrar.sh   (PreToolUse:Agent — process table)
#   hooks/lib/agent-role-privileges.sh   (role → privilege mapping, shared)
#
# Canonical reference
# -------------------
# skills/element-interactions/references/agentic-os-roles.md

set -uo pipefail

# Escape hatch — calibration / operator override.
[ "${AGENT_ROLE_PRIVILEGE_GUARD:-on}" = "off" ] && exit 0

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
if [ -z "$JQ" ]; then
  echo "[$(basename "${BASH_SOURCE[0]}")] FATAL: jq not found at \$HOOK_DIR/bin/jq nor on PATH." >&2
  exit 1
fi

# shellcheck source=lib/agent-role-privileges.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/agent-role-privileges.sh"
# shellcheck source=lib/agent-process-table.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/agent-process-table.sh"
# shellcheck source=lib/achilles-project-gate.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/achilles-project-gate.sh"
# shellcheck source=lib/methodology-citation.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/methodology-citation.sh"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")
case "$TOOL_NAME" in Bash|Agent|Read) ;; *) exit 0 ;; esac

AGENT_ID=$(echo "$INPUT" | "$JQ" -r '.agent_id // empty' 2>/dev/null || echo "")
PARENT_ID=$(echo "$INPUT" | "$JQ" -r '.parent_tool_use_id // empty' 2>/dev/null || echo "")
TRANSCRIPT_PATH=$(echo "$INPUT" | "$JQ" -r '.transcript_path // empty' 2>/dev/null || echo "")

GUARD_CWD=$(echo "$INPUT" | "$JQ" -r '.cwd // "."' 2>/dev/null || echo ".")
REPO_ROOT=$(cd "$GUARD_CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || echo "$GUARD_CWD")

# Project scoping: the achilles methodology is enforced only in achilles
# projects — everywhere else this hook is inert.
achilles_hooks_active "$REPO_ROOT" || exit 0

# Live process-table slice (shared load + resolution — lib/agent-process-table.sh).
apt_load_live "$REPO_ROOT"

emit_deny() {
  "$JQ" -n --arg r "$1" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": $r
    }
  }'
}

DOC_REF="skills/element-interactions/references/agentic-os-roles.md"

denied_has() {
  case " $ACTOR_DENIED " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# cite <section-hint> — transcript-aware methodology citation appended to
# every deny (lib/methodology-citation.sh): instructs a Read of the spec
# when the transcript shows it was never loaded, a re-apply otherwise.
cite() {
  methodology_block "$TRANSCRIPT_PATH" "$DOC_REF" "$1"
}

# pipeline_live — 0 iff an achilles pipeline is actually running here
# (live process-table entries or a pipeline ledger on disk). Orchestrator
# policing is scoped to live pipelines only.
pipeline_live() {
  [ "$APT_LIVE_COUNT" -gt 0 ] && return 0
  local f
  for f in \
    "$REPO_ROOT/tests/e2e/docs/onboarding-status.json" \
    "$REPO_ROOT/tests/e2e/docs/coverage-expansion-state.json" \
    "$REPO_ROOT/tests/perf/docs/perf-onboarding-status.json"; do
    [ -f "$f" ] && return 0
  done
  return 1
}

# ============================================================================
# PreToolUse:Agent — process-creation enforcement
# ============================================================================
if [ "$TOOL_NAME" = "Agent" ]; then
  DESCRIPTION=$(echo "$INPUT" | "$JQ" -r '.tool_input.description // ""' 2>/dev/null || echo "")

  if [ -z "$AGENT_ID" ]; then
    # Orchestrator dispatch — process creation by the session owner.
    # While a pipeline is live, every process must be created under a
    # role user: a role-less (unconfined) dispatch would run with no
    # privilege set, no return schema, and no slug convention — outside
    # the OS entirely. Ordering/shape gates for role-prefixed dispatches
    # live in the other Agent hooks.
    [ "${AGENTIC_OS_ROLE_REQUIRED:-on}" = "off" ] && exit 0
    pipeline_live || exit 0
    DESC_TRIMMED=$(echo "$DESCRIPTION" | sed -E 's/^[[:space:]]+//')
    if ! resolve_privilege_role "$DESC_TRIMMED" >/dev/null; then
      emit_deny "[BLOCKED] Role-less subagent dispatch while a pipeline is live.

Attempted dispatch: \"${DESCRIPTION:0:120}\"

Every process created during an achilles run must be assigned a role user via its description prefix — the role fixes its privilege set (lib/agent-role-privileges.sh), its return schema, and its playwright-cli session slug. A free-form dispatch would execute UNCONFINED alongside privileged pipeline work.

Do this instead — prefix the description with the role that matches the work:
  composer-<j-slug>: | reviewer-<j-slug>: | probe-<j-slug>: | workflow-reviewer-<scope>: | phase-validator-<N>: | process-validator-<scope>: | phase1-<entry>: | phase4-cycle-<N>-<section>: | stage2-<scenario>: | cleanup-<scope>: | companion-<task>: | fd-<failure>: | load-run-<pass>:

$(cite '§"Roles" (the description-prefix vocabulary) and §"The model" (dispatch = process creation under a role user)')"
      exit 0
    fi
    exit 0
  fi

  # Subagent context: nested-dispatch enforcement.
  apt_resolve_actor "$PARENT_ID" ""
  if denied_has dispatch; then
    emit_deny "[BLOCKED] Privilege violation: role '${ACTOR_ROLE}' lacks the 'dispatch' capability.

Attempted nested dispatch: \"${DESCRIPTION:0:120}\"

This tool call is executing inside a dispatched subagent context (agent_id present), and the methodology is single-level fan-out: only the ORCHESTRATOR creates agentic processes. A subagent that needs more work done returns a structured report and lets the orchestrator dispatch the follow-up.

Do this instead:
  1. Finish this subagent's own assignment.
  2. Put the follow-up need in the structured return (canonical schema — schemas/subagent-returns/).
  3. The orchestrator dispatches the next process with a fresh isolated context.

$(cite '§"Privilege classes" — the dispatch class (single-level fan-out)')"
    exit 0
  fi
  exit 0
fi

# ============================================================================
# PreToolUse:Read — orchestrator payload-ingest enforcement (Read vector)
# ============================================================================
if [ "$TOOL_NAME" = "Read" ]; then
  # Subagents read their own slices by contract — the Read vector is
  # gated for the ORCHESTRATOR only, and only while a pipeline is live.
  [ -z "$AGENT_ID" ] || exit 0
  pipeline_live || exit 0
  FILE_PATH=$(echo "$INPUT" | "$JQ" -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
  [ -n "$FILE_PATH" ] || exit 0
  if echo "$FILE_PATH" | grep -qE '\.spec\.(ts|js|mjs|tsx)$|/\.subagent-returns/|/\.playwright-cli/|/test-results/|/playwright-report/|trace\.zip$|\.har$'; then
    emit_deny "[BLOCKED] Privilege violation: role 'orchestrator' lacks the 'payload-ingest' capability (Read vector).

File: ${FILE_PATH}

Reading this payload artifact pulls subagent-context content (test source / spill returns / traces / run reports) into the ORCHESTRATOR window — the same leak the Bash-dump denial closes, through the Read tool instead. The isolation contract's single sanctioned bounded Read is one journey's pass-4 section of the adversarial-findings ledger — which this path is not.

Do this instead:
  - Dispatch a role-prefixed subagent whose brief points at this file; it reads in ITS context and returns a structured summary.
  - Need existence/size/counts? ls, find, wc -l, grep -c, grep -l, stat.

$(cite '§"Privilege classes" — the payload-ingest class (the context-leak class, Bash and Read vectors)')"
    exit 0
  fi
  exit 0
fi

# ============================================================================
# PreToolUse:Bash — command-class enforcement
# ============================================================================
CMD=$(echo "$INPUT" | "$JQ" -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -n "$CMD" ] || exit 0

CMD_PREVIEW="$CMD"
[ ${#CMD} -gt 160 ] && CMD_PREVIEW="${CMD:0:160}..."

# --- class detectors --------------------------------------------------------
# Command-word anchor: start of line or after a separator, tolerating
# `command` / `env` wrappers (same posture as commit-message-gate.sh).
WORD='(^|[;&|(][[:space:]]*)((command|env)[[:space:]]+)?'

exercises_browser() {
  local runners='(npx|bunx|pnpm[[:space:]]+exec|yarn[[:space:]]+exec)[[:space:]]+'
  local sep='(^|[;|][[:space:]]*|&&[[:space:]]*|\|\|[[:space:]]*)'
  echo "$CMD" | grep -qE "${sep}(${runners})?playwright-cli[[:space:]]"
}

exercises_remote_push() {
  echo "$CMD" | grep -qE "${WORD}git([[:space:]]+(-[cC][[:space:]]+[^[:space:]]+|--[a-z-]+(=[^[:space:]]+)?))*[[:space:]]+push([[:space:]]|\$)"
}

exercises_mutate() {
  # git commit
  echo "$CMD" | grep -qE "${WORD}git([[:space:]]+(-[cC][[:space:]]+[^[:space:]]+|--[a-z-]+(=[^[:space:]]+)?))*[[:space:]]+commit([[:space:]]|\$)" && return 0
  # filesystem mutators as the command word
  echo "$CMD" | grep -qE "${WORD}(rm|mv|cp|touch|mkdir|ln|chmod|chown|truncate)[[:space:]]" && return 0
  # in-place editors
  echo "$CMD" | grep -qE "${WORD}sed[[:space:]]+[^;|&]*-i" && return 0
  echo "$CMD" | grep -qE "${WORD}perl[[:space:]]+[^;|&]*-i" && return 0
  # package installs
  echo "$CMD" | grep -qE "${WORD}(npm[[:space:]]+(install|ci|i)([[:space:]]|\$)|yarn[[:space:]]+add[[:space:]]|pnpm[[:space:]]+(add|install)([[:space:]]|\$))" && return 0
  # tee into a non-scratch target
  local tee_target
  tee_target=$(echo "$CMD" | grep -oE '(^|[;&|][[:space:]]*|\|[[:space:]]*)tee[[:space:]]+(-[aip]+[[:space:]]+)*[^[:space:];|&]+' | sed -E 's/.*tee[[:space:]]+(-[aip]+[[:space:]]+)*//' | head -1 || true)
  if [ -n "$tee_target" ]; then
    case "$tee_target" in /dev/*|/tmp/*|\$TMPDIR*|\${TMPDIR}*) ;; *) return 0 ;; esac
  fi
  # redirection into a non-scratch target: strip quoted spans, heredocs,
  # fd-duplications, fd-numbered redirects, and scratch targets — any `>`
  # left is a write into the project surface.
  local scan
  scan=$(printf '%s' "$CMD" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g")
  scan=$(printf '%s' "$scan" | sed -E 's/<<-?[[:space:]]*[A-Za-z_]+//g')
  scan=$(printf '%s' "$scan" | sed -E 's/[0-9]*>&[0-9]+//g')
  scan=$(printf '%s' "$scan" | sed -E 's/[0-9]+[[:space:]]*>>?[[:space:]]*[^[:space:];|&]*//g')
  scan=$(printf '%s' "$scan" | sed -E 's/&?>>?[[:space:]]*(\/dev\/[a-z]+|\/tmp\/[^[:space:];|&]*|\$\{?TMPDIR\}?[^[:space:];|&]*)//g')
  printf '%s' "$scan" | grep -q '>' && return 0
  return 1
}

PAYLOAD_ARTIFACT_RE='\.spec\.(ts|js|mjs|tsx)|\.subagent-returns|\.playwright-cli/|test-results/|playwright-report/|trace\.zip|\.har([[:space:]]|$)'
exercises_payload_ingest() {
  echo "$CMD" | grep -qE "${WORD}(cat|head|tail|less|more|nl|strings|base64|xxd|od)[[:space:]]" || return 1
  echo "$CMD" | grep -qE "$PAYLOAD_ARTIFACT_RE"
}

# --- actor resolution --------------------------------------------------------
if [ -z "$AGENT_ID" ]; then
  # Orchestrator context (ring 0's OWNER, but with the payload-ingest
  # capability removed — context hygiene is the point of the fan-out).
  ACTOR_ROLE="orchestrator"
  ACTOR_DENIED=$(role_denied_classes orchestrator)

  # Only police the orchestrator while a pipeline is actually live —
  # quiet sessions in achilles projects stay untouched.
  pipeline_live || exit 0

  if exercises_payload_ingest; then
    emit_deny "[BLOCKED] Privilege violation: role 'orchestrator' lacks the 'payload-ingest' capability.

Command: $CMD_PREVIEW

This command dumps subagent payload artifacts (test source / spill returns / CLI traces / run reports) into the ORCHESTRATOR context. The isolation contract is explicit: the orchestrator never holds probe transcripts, DOM snapshots, test source, or stabilization output — that content lives and dies inside the subagent context that produced it. Leaked payload burns the orchestrator's window and contaminates every later dispatch brief.

Do this instead:
  - Need the content examined? Dispatch a role-prefixed subagent whose brief points at the file — it reads in ITS context and returns a structured summary.
  - Need existence/size/counts? Metadata reads are allowed: ls, find, wc -l, grep -c, grep -l, stat.
  - Need one journey's ledger section (the single sanctioned exception)? Use the Read tool on that bounded slice, not a Bash dump.

$(cite '§"Privilege classes" — the payload-ingest class (the context-leak class)') Also: skills/coverage-expansion/references/subagent-isolation.md."
    exit 0
  fi
  exit 0
fi

# Subagent context.
CLAIMED_SLUG=$(apt_extract_slug "$CMD")
apt_resolve_actor "$PARENT_ID" "$CLAIMED_SLUG"
[ -n "$ACTOR_DENIED" ] || exit 0

if denied_has browser && exercises_browser; then
  emit_deny "[BLOCKED] Privilege violation: role '${ACTOR_ROLE}' lacks the 'browser' capability.

Command: $CMD_PREVIEW

This role's contract is text-only work — no browser session is opened for it (cleanup consolidates the ledger; phase4-prioritise-author writes prioritisation from section returns). A playwright-cli invocation from this context indicates scope drift beyond the dispatch brief.

Do this instead: finish the text deliverable from the inputs in the brief. If live-DOM evidence is genuinely missing, report the gap in the structured return so the orchestrator dispatches a browser-privileged role (composer/probe/section agent).

$(cite '§"Privilege classes" — the browser class (text-only role contracts)')"
  exit 0
fi

if denied_has remote-push && exercises_remote_push; then
  emit_deny "[BLOCKED] Privilege violation: role '${ACTOR_ROLE}' lacks the 'remote-push' capability.

Command: $CMD_PREVIEW

No subagent role publishes to a remote. Pushing is a session-owner action taken by the orchestrator (or the human) after the pipeline's own gates have passed.

Do this instead: commit locally if your role's contract calls for it, and note readiness-to-push in the structured return.

$(cite '§"Privilege classes" — the remote-push class')"
  exit 0
fi

if denied_has mutate && exercises_mutate; then
  emit_deny "[BLOCKED] Privilege violation: role '${ACTOR_ROLE}' lacks the 'mutate' capability.

Command: $CMD_PREVIEW

This context is a read-only verifier (reviewer / validator family). A reviewer that can rewrite the artifact it verifies is not a reviewer — the separation-of-duties model depends on verifier contexts being unable to touch the surface they grade.

Do this instead:
  - Verify with reads: Read tool, ls, find, wc, grep, git diff, git log.
  - Scratch space is allowed: write under /tmp or \$TMPDIR if you need a workfile.
  - Report defects in the structured return; the orchestrator routes fixes to a mutate-privileged role.

$(cite '§"Privilege classes" — the mutate class (read-only verifier roles)')"
  exit 0
fi

exit 0
