#!/bin/bash
# hook-emit.sh — the deny, warn and stop payloads Achilles hooks print.
# Needs JQ (hook_jq_init) and achilles-activation.sh sourced first.
#
# HOOK_REFS stays a literal in each hook file: lint-doc-drift reads it there.
# The pipeline ledger gates are the exception: pipeline_config sets theirs.

# emit_pre_deny <reason> — PreToolUse deny; appends HOOK_REFS and the session-scope notice.
emit_pre_deny() {
  "$JQ" -n --arg r "$1${HOOK_REFS:-}$(achilles_scope_notice)" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": $r
    }
  }'
}

# emit_warn <message> — non-blocking systemMessage; appends HOOK_REFS.
emit_warn() {
  "$JQ" -n --arg m "$1${HOOK_REFS:-}" '{
    "systemMessage": $m,
    "suppressOutput": false
  }'
}

# emit_stop_block <reason> — Stop-event block.
emit_stop_block() {
  "$JQ" -n --arg r "$1" '{ "decision": "block", "reason": $r }'
}

# no_skip_messaging_block
# Print the canonical no-skip contract block. No arguments. Always
# emits the same text — this is the contract surface, not a template.
no_skip_messaging_block() {
  cat <<'NO_SKIP_BLOCK_EOF'
──────────────────────────────────────────────────────────────────
No-skip onboarding contract — Pipeline phases cannot be skipped:
──────────────────────────────────────────────────────────────────
The onboarding pipeline runs to one of two valid exits — full
greenlight (all phases 1–7), or an explicit user-authorised early
stop (touch `.claude/onboarding-stop-authorized`). Pipeline phases
cannot be skipped under any other framing.

  "honest partial reporting"           — NOT authorisation.
  "pragmatic Pass N"                   — NOT authorisation.
  "context-budget exit #2 after ..."   — NOT authorisation.
  "user's final-step instruction"      — NOT authorisation.
  "BENCHMARK is the deliverable so I should write it now"
                                       — NOT authorisation.

The legitimate early-stop path:
  mkdir -p .claude && touch .claude/onboarding-stop-authorized

Reference: skills/onboarding/SKILL.md §"Completion rule"
NO_SKIP_BLOCK_EOF
}

# --- self-test ----------------------------------------------------------------
# Run as `NO_SKIP_MESSAGING_SELFTEST=1 bash hooks/lib/hook-emit.sh`.
# Echoes the block once and exits 0 if the four required substrings are
# present, exits 1 otherwise. Used by 32-no-skip-messaging-coverage.sh.
if [ "${NO_SKIP_MESSAGING_SELFTEST:-0}" = "1" ]; then
  out=$(no_skip_messaging_block)
  ok=1
  for substr in \
      "Pipeline phases cannot be skipped" \
      ".claude/onboarding-stop-authorized" \
      "NOT authorisation" \
      "skills/onboarding/SKILL.md"; do
    if ! printf '%s' "$out" | grep -qF -- "$substr"; then
      echo "FAIL missing required substring: '$substr'"
      ok=0
    fi
  done
  if [ "$ok" = "1" ]; then
    echo "ok no_skip_messaging_block contains all 4 required substrings"
    exit 0
  fi
  exit 1
fi
