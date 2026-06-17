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

# pipeline_ledger_integrity_check
# Missing-ledger + hash-chain guard. Returns 0 and emits deny on violation;
# returns 1 to signal "ledger absent but clean" (silent allow); returns 2
# when ledger exists and is valid (fall-through to further checks).
# Caller: on return 0 → exit 0; on return 1 → exit 0; on return 2 → continue.
# Requires: PIPELINE_LEDGER  PIPELINE_SIDECAR  JQ  file_sha256 (from hash.sh)
pipeline_ledger_integrity_check() {
  if [ ! -f "$PIPELINE_LEDGER" ]; then
    if [ -f "$PIPELINE_SIDECAR" ] && [ -n "$("$JQ" -r '.records[-1].sha256 // empty' "$PIPELINE_SIDECAR" 2>/dev/null)" ]; then
      pipeline_emit_deny "[BLOCKED] onboarding-status.json is missing but its integrity sidecar survives — the ledger appears to have been deleted out of band. Dispatches are blocked until the operator confirms the reset by removing tests/e2e/docs/.ledger-integrity.json in their own terminal."
      return 0
    fi
    return 1
  fi
  if [ -f "$PIPELINE_SIDECAR" ]; then
    CHAIN_LATEST=$("$JQ" -r '.records[-1].sha256 // empty' "$PIPELINE_SIDECAR" 2>/dev/null || echo "")
    CHAIN_PREV=$("$JQ" -r '.records[-2].sha256 // empty' "$PIPELINE_SIDECAR" 2>/dev/null || echo "")
    LEDGER_HASH=$(file_sha256 "$PIPELINE_LEDGER")
    if [ -n "$CHAIN_LATEST" ] && [ -n "$LEDGER_HASH" ] && [ "$LEDGER_HASH" != "$CHAIN_LATEST" ] && [ "$LEDGER_HASH" != "$CHAIN_PREV" ]; then
      pipeline_emit_deny "[BLOCKED] onboarding-status.json does not match its sanctioned hash chain (out-of-band mutation detected). Dispatches are blocked. Surface this to the user — recovery is an operator action (restore the ledger or delete tests/e2e/docs/.ledger-integrity.json in their own terminal)."
      return 0
    fi
  fi
  return 2
}
