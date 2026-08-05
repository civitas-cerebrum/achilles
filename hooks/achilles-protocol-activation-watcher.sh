#!/bin/bash
# achilles-protocol-activation-watcher.sh — owns the session-scope
# lifecycle: marks the session protocol-active the moment achilles
# methodology enters the conversation, and retires the marker when the
# pipeline reaches a terminal status.
#
# Hook    : PreToolUse:Skill, PreToolUse:Agent, UserPromptSubmit
#           PostToolUse:Write|Edit (pipeline-completion detection)
# Mode    : OBSERVE (never denies, never emits output)
# State   : writes $ACHILLES_SESSION_STATE_DIR/<session_id>.active /
#           .completed (default ~/.claude/achilles/sessions/)
# Env     : ACHILLES_PROTOCOL=0 disables marking (activation suppression)
#           ACHILLES_SESSION_STATE_DIR overrides the marker directory
#
# Lifecycle: activation is ONE-WAY for the session. The only deactivation
# paths are (a) this watcher observing a sanctioned ledger write that
# lands a terminal pipeline status ("complete" / "aborted") on
# onboarding-status.json / perf-onboarding-status.json — PostToolUse, so
# the write already passed every ledger gate — or (b) the user
# terminating the Claude session. There is no mid-session off switch;
# deny messages across the suite point agents and users to those two
# exits.
#
# Why
# ---
# Every enforcement hook in this suite is gated by
# lib/achilles-activation.sh: guards apply only to sessions where the
# achilles protocol is actually in play, and silent-allow in plain dev
# sessions. This watcher is the cheap, immediate half of that detection —
# it records the activation moment (an achilles Skill invocation, a
# role-prefixed subagent dispatch, or a typed /<skill> command) as a
# session marker file, so the gates answer "active?" with a single stat
# instead of re-scanning the transcript on every tool call.
#
# The gates do NOT depend on this hook having run first: the same
# signatures are re-checked in-line by achilles_session_active() against
# the current call and the transcript. The watcher is a cache writer, not
# a correctness dependency — hook-ordering races cannot open a gap.
#
# Housekeeping: markers older than 7 days are pruned on each firing.
#
# Failure → action
# ----------------
# Never blocks anything. Always exits 0 silently.

set -uo pipefail

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
[ -n "$JQ" ] || exit 0

HOOK_LIB_DIR="$(dirname "${BASH_SOURCE[0]}")/lib"
# shellcheck disable=SC1091
. "$HOOK_LIB_DIR/achilles-activation.sh"

# Hard off — never mark.
case "${ACHILLES_PROTOCOL:-}" in
  0|false|off|OFF) exit 0 ;;
esac

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | "$JQ" -r '.session_id // empty' 2>/dev/null || echo "")
[ -n "$SESSION_ID" ] || exit 0

EVENT=$(printf '%s' "$INPUT" | "$JQ" -r '.hook_event_name // empty' 2>/dev/null || echo "")
TOOL_NAME=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")

# ── Pipeline-completion detection (PostToolUse:Write|Edit) ──
# A sanctioned Write/Edit that lands a terminal status on a pipeline
# ledger retires the session's activation marker. PostToolUse: the write
# has already cleared the ledger write-gate + integrity chain, so the
# on-disk state is authoritative. Enforcement gates go quiet from the
# next tool call; summary/cleanup hooks keep running via the .completed
# marker (achilles_require_active_or_completed).
if [ "$EVENT" = "PostToolUse" ]; then
  case "$TOOL_NAME" in
    Write|Edit)
      FILE_PATH=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
      case "$FILE_PATH" in
        */onboarding-status.json|onboarding-status.json|*/perf-onboarding-status.json|perf-onboarding-status.json)
          if [ -f "$FILE_PATH" ]; then
            LEDGER_STATUS=$("$JQ" -r '.status // empty' "$FILE_PATH" 2>/dev/null || echo "")
            case "$LEDGER_STATUS" in
              complete|aborted)
                achilles_mark_session_completed "$SESSION_ID" "$(basename "$FILE_PATH"):${LEDGER_STATUS}"
                ;;
            esac
          fi
          ;;
      esac
      ;;
  esac
  exit 0
fi

MATCHED=0

if [ "$EVENT" = "UserPromptSubmit" ]; then
  # A typed /<skill> command activates without a Skill tool call having
  # happened yet (slash invocations can inject the skill body directly).
  # Real UserPromptSubmit input carries top-level .prompt; tolerate
  # tool_input.prompt for harness variations / synthetic payloads.
  PROMPT=$(printf '%s' "$INPUT" | "$JQ" -r '.prompt // .tool_input.prompt // empty' 2>/dev/null || echo "")
  if printf '%s' "$PROMPT" | grep -qE "^[[:space:]]*/(${ACHILLES_SKILL_ALT})([[:space:]]|$)"; then
    MATCHED=1
  fi
else
  case "$TOOL_NAME" in
    Skill)
      SKILL_NAME=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.skill // empty' 2>/dev/null || echo "")
      if printf '%s' "$SKILL_NAME" | grep -qE "(^|:)(${ACHILLES_SKILL_ALT})$"; then
        MATCHED=1
      fi
      ;;
    Agent)
      DESCRIPTION=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.description // empty' 2>/dev/null || echo "")
      if printf '%s' "$DESCRIPTION" | grep -qE "$ACHILLES_DISPATCH_PREFIX_RE"; then
        MATCHED=1
      fi
      ;;
  esac
fi

if [ "$MATCHED" = "1" ]; then
  achilles_mark_session_active "$SESSION_ID"
  # Prune stale markers so the state dir doesn't grow unbounded.
  find "$(achilles__state_dir)" -name '*.active' -type f -mtime +7 -delete 2>/dev/null || true
fi

exit 0
