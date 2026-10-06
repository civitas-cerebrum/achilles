#!/bin/bash
# pipeline-ledger-write.sh — the PreToolUse:Write|Edit ledger gate shared by
# the onboarding and perf-onboarding pipelines. A gate sources this file, runs
# hook_jq_init (its fatal message names the calling hook), sets the
# pipeline-gate.sh config plus the keys below, and calls
# pipeline_ledger_write_main with its per-phase deliverable check.
#
#   PIPELINE_APPROVER_TYPES         — agent_type values that may record approvals
#   PIPELINE_PHASE_COUNT            — deliverables are checked for phases 1..N
#   PIPELINE_MSG_PHASE_LABEL        — deliverable deny lead (e.g. Phase)
#   PIPELINE_MSG_DELIVERABLE_LEDGER — the ledger as the deliverable deny names it
#   PIPELINE_MSG_DELIVERABLE_WHY    — appended to the deliverable deny's rationale

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/hook-io.sh"
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/hook-emit.sh"
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/achilles-activation.sh"
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/pipeline-gate.sh"

# pipeline_ledger_write_main <deliverables_fn>
# Gates a Write / Edit of the ledger at PIPELINE_MSG_LEDGER_REL with the shared
# checks of pipeline_write_gate, then calls <deliverables_fn> <phase> for each
# phase the write moves to "completed", with PROJECT_ROOT set to the directory
# holding the ledger's tests/ tree. Always exits.
# Reads the hook payload from stdin.
# Requires: JQ  HOOK_REFS  PIPELINE_*
pipeline_ledger_write_main() {
  local deliverables_fn="$1" TOOL_NAME FILE_PATH phase new_status prior_status
  hook_read_input
  # Plain dev sessions silent-allow (lib/achilles-activation.sh).
  achilles_require_active "$INPUT"
  TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")
  case "$TOOL_NAME" in
    Write|Edit) ;;
    *) exit 0 ;;
  esac
  FILE_PATH=$(echo "$INPUT" | "$JQ" -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
  # Match the leading-slash-normalised path so a bare relative path cannot
  # slip the gate.
  case "/${FILE_PATH#/}" in
    */"$PIPELINE_MSG_LEDGER_REL") ;;
    *) exit 0 ;;
  esac
  PIPELINE_LEDGER="$FILE_PATH"
  PIPELINE_SIDECAR="$(dirname "$FILE_PATH")/.ledger-integrity.json"

  pipeline_write_gate "$TOOL_NAME" "$FILE_PATH" && exit 0

  PROJECT_ROOT="${FILE_PATH%/"$PIPELINE_MSG_LEDGER_REL"}"
  phase=1
  while [ "$phase" -le "$PIPELINE_PHASE_COUNT" ]; do
    new_status=$(ledger_get "$TMP_PROPOSED" ".phases[$((phase - 1))].status")
    prior_status="pending"
    if [ -f "$FILE_PATH" ]; then
      prior_status=$(ledger_get "$FILE_PATH" ".phases[$((phase - 1))].status" pending)
    fi
    if [ "$new_status" = "completed" ] && [ "$prior_status" != "completed" ]; then
      "$deliverables_fn" "$phase"
    fi
    phase=$((phase + 1))
  done
  exit 0
}

# pipeline_emit_phase_deny <phase> <missing> <fix> <see>
# Denies the move of <phase> to "completed" while a deliverable is missing,
# then exits.
pipeline_emit_phase_deny() {
  emit_pre_deny "[BLOCKED] ${PIPELINE_MSG_PHASE_LABEL} $1 cannot transition to status: \"completed\" — required deliverable missing.

File: ${PIPELINE_LEDGER}

Missing: $2

This is the per-phase positive-deliverable check. The ${PIPELINE_MSG_DELIVERABLE_LEDGER} cannot
mark a phase complete unless that phase's canonical deliverables exist
on disk.${PIPELINE_MSG_DELIVERABLE_WHY}

Fix: $3

See: $4"
  exit 0
}
