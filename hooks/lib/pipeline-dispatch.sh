#!/bin/bash
# pipeline-dispatch.sh — the PreToolUse:Agent ledger gate shared by the
# onboarding and perf-onboarding pipelines. A gate sources this file, runs
# hook_jq_init (its fatal message names the calling hook), calls
# pipeline_config, sets PIPELINE_CAP_PREFIX_RE, then calls pipeline_dispatch_main.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/hook-io.sh"
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/hook-emit.sh"
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/achilles-activation.sh"
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/hash.sh"
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/pipeline-gate.sh"

# pipeline_dispatch_main <substage_fn>
# Gates an Agent dispatch against the ledger: reviewer dispatches pass subject
# to the reject cap (rule 4); a missing ledger allows (rule 5) unless its
# integrity sidecar survives; then the transition point (rule 3), phase order
# (rules 1+2), and <substage_fn>, the gate's pass / cycle order check, called
# with the ledger's currentPhase. Always exits.
# Reads the hook payload from stdin.
# Requires: JQ  HOOK_REFS  PIPELINE_KIND  PIPELINE_CAP_PREFIX_RE  PIPELINE_MSG_*
pipeline_dispatch_main() {
  local substage_fn="$1" TOOL_NAME DESCRIPTION GUARD_CWD GUARD_REPO_ROOT LEDGER_STATE CURRENT_PHASE
  hook_read_input
  # Plain dev sessions silent-allow (lib/achilles-activation.sh).
  achilles_require_active "$INPUT"
  TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")
  [ "$TOOL_NAME" = "Agent" ] || exit 0
  DESCRIPTION=$(echo "$INPUT" | "$JQ" -r '.tool_input.description // ""' 2>/dev/null || echo "")
  [ -n "$DESCRIPTION" ] || exit 0

  GUARD_CWD=$(echo "$INPUT" | "$JQ" -r '.cwd // "."' 2>/dev/null || echo ".")
  GUARD_REPO_ROOT=$(git -C "$GUARD_CWD" rev-parse --show-toplevel 2>/dev/null || echo "$GUARD_CWD")
  PIPELINE_LEDGER="$(ledger_path "$GUARD_REPO_ROOT" "$PIPELINE_KIND")"
  PIPELINE_SIDECAR="$(dirname "$PIPELINE_LEDGER")/.ledger-integrity.json"

  # is_reviewer_description is the test the approver registry uses, so the
  # allow-list cannot drift from the scopes the registry accepts.
  if is_reviewer_description "$DESCRIPTION"; then
    pipeline_reviewer_cap_check "$DESCRIPTION"
    exit 0
  fi

  pipeline_ledger_integrity_check
  LEDGER_STATE=$?
  [ "$LEDGER_STATE" -eq 2 ] || exit 0

  # A malformed ledger allows: the write gate owns ledger integrity.
  [ -n "$(ledger_get "$PIPELINE_LEDGER" .schemaVersion)" ] || exit 0
  CURRENT_PHASE=$(ledger_get "$PIPELINE_LEDGER" .currentPhase)
  case "$CURRENT_PHASE" in
    ''|*[!0-9]*) exit 0 ;;
  esac

  pipeline_transition_point_check "$DESCRIPTION" && exit 0
  pipeline_out_of_order_phase_check "$DESCRIPTION" "$CURRENT_PHASE" && exit 0
  "$substage_fn" "$CURRENT_PHASE"
  exit 0
}

# pipeline_substage_order_check <phase> <unit> <target> <prior> <reviewer> <criteria> <see>
# Denies a dispatch for <unit>-<target> (a pass or cycle of <phase>) while
# <unit>-<prior> is not reviewer-approved. <reviewer> is the dispatch that
# approves the prior unit, <criteria> ends "The reviewer checks …", and <see>
# is the first methodology reference. Returns 0 + emits deny if gated; 1
# otherwise.
# Requires: DESCRIPTION  PIPELINE_LEDGER  PIPELINE_MSG_REVIEWER_SKILL  PIPELINE_MSG_SCHEMA_REF  JQ
pipeline_substage_order_check() {
  local verdict
  verdict=$("$JQ" -r --argjson phase "$1" --arg id "$2-$4" '
    [.phases[]? | select(.id == $phase) | .subStages[]? | select(.id == $id)] |
    .[0].reviewerVerdict // "pending"
  ' "$PIPELINE_LEDGER" 2>/dev/null || echo "pending")
  [ "$verdict" != "approved" ] || return 1
  emit_pre_deny "[BLOCKED] Out-of-order Phase-$1 $2 dispatch — $2-$3 cannot start while $2-$4 is not reviewer-approved.

Description: \"${DESCRIPTION}\"

Ledger shows $2-$4.reviewerVerdict = \"${verdict}\"
(must be \"approved\").

Fix: dispatch \`$5\` first. The
reviewer checks $6.

See:
  - $7
  - ${PIPELINE_MSG_REVIEWER_SKILL}
  - ${PIPELINE_MSG_SCHEMA_REF}"
  return 0
}
