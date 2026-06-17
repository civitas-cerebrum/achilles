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
