#!/bin/bash
# pipeline-gate.sh — shared enforcement spine for ledger-gated orchestrator
# pipelines (onboarding, perf-onboarding). Sourced by each pipeline's gate
# hooks, which set the PIPELINE_* config + define the pipeline-specific
# inference/deliverable functions, then call these generic primitives.
#
# Config contract (the sourcing gate sets these before calling lib fns):
#   PIPELINE_LEDGER        — absolute path to the pipeline's status ledger JSON
#   PIPELINE_SIDECAR       — absolute path to the .ledger-integrity.json sidecar
#   PIPELINE_SCHEMA_NAME   — validator-bundle schema id (write-gate only)
#   PIPELINE_CAP_PREFIX_RE — sed -E capture extracting a reviewer's target phase
#   JQ                     — path to jq (the gate resolves this already)

# Emit a PreToolUse deny payload with the supplied reason (stdout JSON).
pipeline_emit_deny() {
  local reason="$1"
  "$JQ" -n --arg r "$reason" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": $r
    }
  }'
}

# pipeline_reviewer_cap_check <description>
# Checks the reviewer-cycles cap for a reviewer dispatch.
# Returns 0 and emits a deny if the cap is hit; returns 1 (fall-through) otherwise.
# Caller must `exit 0` when this returns 0.
# Requires: PIPELINE_LEDGER  PIPELINE_CAP_PREFIX_RE  JQ
pipeline_reviewer_cap_check() {
  local DESCRIPTION="$1"
  if [ -f "$PIPELINE_LEDGER" ]; then
    CAP_PHASE=$(echo "$DESCRIPTION" | sed -nE "$PIPELINE_CAP_PREFIX_RE" | head -1)
    if [ -n "$CAP_PHASE" ]; then
      CAP_CYCLES=$("$JQ" -r --argjson id "$CAP_PHASE" \
        '[.phases[]? | select(.id == $id)] | .[0].reviewerCycles // 0' "$PIPELINE_LEDGER" 2>/dev/null || echo "0")
      CAP_VERDICT=$("$JQ" -r --argjson id "$CAP_PHASE" \
        '[.phases[]? | select(.id == $id)] | .[0].reviewerVerdict // "pending"' "$PIPELINE_LEDGER" 2>/dev/null || echo "pending")
      case "$CAP_CYCLES" in ''|*[!0-9]*) CAP_CYCLES=0 ;; esac
      if [ "$CAP_CYCLES" -ge 3 ] && [ "$CAP_VERDICT" != "escalated-to-user" ]; then
        pipeline_emit_deny "[BLOCKED] Reviewer dispatch for phase ${CAP_PHASE} denied — reviewerCycles is already ${CAP_CYCLES} (cap is 3) and the verdict is \"${CAP_VERDICT}\", not \"escalated-to-user\".

Description: \"${DESCRIPTION}\"

The reviewer reject cap is 3 rounds. After the 3rd round the phase must
escalate to the user (reviewerVerdict \"escalated-to-user\", pipeline
status \"blocked\"), not enter a 4th review.

Fix: stop re-dispatching the reviewer. Update the ledger so phase
${CAP_PHASE} carries reviewerVerdict \"escalated-to-user\" and surface the
blockage to the user.

See: skills/workflow-reviewer/SKILL.md §\"Reject cap\" (3-cycle limit)"
        return 0
      fi
    fi
  fi
  return 1
}
