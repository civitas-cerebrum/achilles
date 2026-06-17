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

# pipeline_transition_point_check <description>
# Rule 3: if the last completed/blocked phase has reviewerVerdict pending,
# force a reviewer dispatch. Returns 0 + emits deny if gated; 1 otherwise.
# Requires: PIPELINE_LEDGER  JQ
pipeline_transition_point_check() {
  local DESCRIPTION="$1"
  local LAST_DONE_PHASE LAST_DONE_VERDICT
  LAST_DONE_PHASE=$("$JQ" -r '
    [.phases[]? | select(.status == "completed" or .status == "blocked")] |
    if length == 0 then "" else (.[-1].id | tostring) end
  ' "$PIPELINE_LEDGER" 2>/dev/null || echo "")

  LAST_DONE_VERDICT=""
  if [ -n "$LAST_DONE_PHASE" ]; then
    LAST_DONE_VERDICT=$("$JQ" -r --argjson id "$LAST_DONE_PHASE" '
      [.phases[]? | select(.id == $id)] | .[0].reviewerVerdict // "pending"
    ' "$PIPELINE_LEDGER" 2>/dev/null || echo "")
  fi

  if [ -n "$LAST_DONE_PHASE" ] && [ "$LAST_DONE_VERDICT" = "pending" ]; then
    pipeline_emit_deny "[BLOCKED] Phase ${LAST_DONE_PHASE} completed but no workflow-reviewer-phase${LAST_DONE_PHASE}: has approved the transition yet.

Description: \"${DESCRIPTION}\"

The ledger at tests/e2e/docs/onboarding-status.json shows phase ${LAST_DONE_PHASE}
finished (status = completed / blocked) but reviewerVerdict is still
\"pending\". Every phase / pass / cycle transition is gated by a
workflow-reviewer-* subagent — the orchestrator cannot start the next
unit of work until the reviewer for the prior unit has returned
\`verdict: approve\`.

Fix: dispatch \`workflow-reviewer-phase${LAST_DONE_PHASE}:\` next. Brief
the reviewer with the ledger row + the closing subagent's handoverEnvelope
and the canonical exit criteria from skills/onboarding/SKILL.md §\"Phase
${LAST_DONE_PHASE}\".

See:
  - skills/onboarding/SKILL.md §\"Status ledger + workflow reviewer\"
  - skills/workflow-reviewer/SKILL.md
  - schemas/subagent-returns/workflow-reviewer.schema.json"
    return 0
  fi
  return 1
}

# pipeline_out_of_order_phase_check <description> <current_phase> <infer_fn>
# Rules 1+2: if the description targets a phase ahead of current and the
# prior phase is not approved, deny. <infer_fn> is the name of a bash
# function defined by the caller that echoes the target phase number (or
# empty string) given the description.
# Returns 0 + emits deny if gated; 1 for fall-through.
# Requires: PIPELINE_LEDGER  JQ
pipeline_out_of_order_phase_check() {
  local DESCRIPTION="$1"
  local CURRENT_PHASE="$2"
  local INFER_FN="$3"
  local TARGET_PHASE PRIOR_PHASE PRIOR_VERDICT
  TARGET_PHASE=$("$INFER_FN" "$DESCRIPTION")
  if [ -n "$TARGET_PHASE" ] && [ "$TARGET_PHASE" -gt "$CURRENT_PHASE" ]; then
    PRIOR_PHASE=$((TARGET_PHASE - 1))
    PRIOR_VERDICT=$("$JQ" -r --argjson id "$PRIOR_PHASE" '
      [.phases[]? | select(.id == $id)] | .[0].reviewerVerdict // "pending"
    ' "$PIPELINE_LEDGER" 2>/dev/null || echo "pending")
    if [ "$PRIOR_VERDICT" != "approved" ]; then
      pipeline_emit_deny "[BLOCKED] Out-of-order phase dispatch — phase ${TARGET_PHASE} cannot start while phase ${PRIOR_PHASE} is not reviewer-approved.

Description: \"${DESCRIPTION}\"

The ledger at tests/e2e/docs/onboarding-status.json shows:
  currentPhase     = ${CURRENT_PHASE}
  target phase     = ${TARGET_PHASE} (inferred from the dispatch description)
  prior phase      = ${PRIOR_PHASE}
  prior verdict    = \"${PRIOR_VERDICT}\" (must be \"approved\")

Every phase transition is state-machine-enforced via the
workflow-reviewer-* subagent family.

Fix: dispatch \`workflow-reviewer-phase${PRIOR_PHASE}:\` first. If the
reviewer returns \`verdict: approve\`, the orchestrator updates the
ledger (reviewerVerdict → approved, currentPhase → ${TARGET_PHASE}) and
re-issues this dispatch.

See:
  - skills/onboarding/SKILL.md §\"Status ledger + workflow reviewer\"
  - skills/workflow-reviewer/SKILL.md
  - schemas/onboarding-status.schema.json
  - schemas/subagent-returns/workflow-reviewer.schema.json"
      return 0
    fi
  fi
  return 1
}
