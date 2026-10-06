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

# pipeline_write_gate <tool_name> <file_path>
# The ledger write gates' shared checks, in order: synthesise the proposed
# ledger, schema + parseability, state-machine transition, approver identity
# (new approvals, then the terminal-status off-switch), mode authorisation.
# Leaves the proposed ledger in TMP_PROPOSED (removed on exit) for the
# caller's per-phase deliverable checks.
# Returns 0 when the caller must exit 0 (deny emitted, or no content to
# check); 1 when every check passed.
# Requires: INPUT  JQ  HOOK_REFS  PIPELINE_*
pipeline_write_gate() {
  local TOOL_NAME="$1" FILE_PATH="$2"
  local PROPOSED_CONTENT="" OLD_STRING NEW_STRING REPLACE_ALL TMP_OLD TMP_NEW ALL_FLAG SYNTH_EXIT SYNTH_ERR_FILE SYNTH_ERR AGENT_ID AGENT_TYPE
  VALIDATOR="$(dirname "${BASH_SOURCE[0]}")/validator.bundle.mjs"
  # An Edit is applied to the on-disk ledger with the bundle's literal
  # `replace` (the Edit tool's uniqueness and replace_all semantics). An
  # Edit against a missing file fails in the tool itself, so it falls
  # through to the empty-content allow. Command substitution drops a
  # trailing newline — harmless for JSON.
  case "$TOOL_NAME" in
    Write)
      PROPOSED_CONTENT=$(echo "$INPUT" | "$JQ" -r '.tool_input.content // empty' 2>/dev/null || echo "")
      ;;
    Edit)
      OLD_STRING=$(echo "$INPUT" | "$JQ" -r '.tool_input.old_string // empty' 2>/dev/null || echo "")
      NEW_STRING=$(echo "$INPUT" | "$JQ" -r '.tool_input.new_string // ""' 2>/dev/null || echo "")
      REPLACE_ALL=$(echo "$INPUT" | "$JQ" -r '.tool_input.replace_all // false' 2>/dev/null || echo "false")
      if [ -f "$FILE_PATH" ] && [ -n "$OLD_STRING" ]; then
        NODE_BIN="$(command -v node 2>/dev/null || true)"
        if [ -z "$NODE_BIN" ] || [ ! -f "$VALIDATOR" ]; then
          emit_pre_deny "[BLOCKED] Cannot synthesise the proposed ledger content for an Edit (node or the validator bundle is unavailable), so the gate cannot validate the transition.

File: ${FILE_PATH}

Fix: re-issue this change as a full Write of the complete ledger JSON
(the Write path validates without content synthesis), or restore node /
reinstall @civitas-cerebrum/achilles to get hooks/lib/validator.bundle.mjs."
          return 0
        fi
        TMP_OLD=$(mktemp "${TMPDIR:-/tmp}/${PIPELINE_SCHEMA_NAME}-old-XXXXXX") ; TMP_NEW=$(mktemp "${TMPDIR:-/tmp}/${PIPELINE_SCHEMA_NAME}-new-XXXXXX")
        printf '%s' "$OLD_STRING" > "$TMP_OLD"
        printf '%s' "$NEW_STRING" > "$TMP_NEW"
        ALL_FLAG=""
        [ "$REPLACE_ALL" = "true" ] && ALL_FLAG="--all"
        SYNTH_EXIT=0
        SYNTH_ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/${PIPELINE_SCHEMA_NAME}-synth-err-XXXXXX")
        PROPOSED_CONTENT=$("$NODE_BIN" "$VALIDATOR" replace "$FILE_PATH" "$TMP_OLD" "$TMP_NEW" $ALL_FLAG 2>"$SYNTH_ERR_FILE") || SYNTH_EXIT=$?
        SYNTH_ERR=$(cat "$SYNTH_ERR_FILE" 2>/dev/null || true)
        rm -f "$TMP_OLD" "$TMP_NEW" "$SYNTH_ERR_FILE"
        if [ "$SYNTH_EXIT" != "0" ]; then
          emit_pre_deny "[BLOCKED] Edit to ${PIPELINE_MSG_LEDGER_NAME} could not be synthesised: ${SYNTH_ERR:-unknown error}.

File: ${FILE_PATH}

The gate validates the post-edit content before allowing the write. An
old_string that is missing or not unique would also fail the Edit tool
itself. Fix the old_string (or use replace_all) and re-issue."
          return 0
        fi
      fi
      ;;
  esac
  [ -n "$PROPOSED_CONTENT" ] || return 0

  TMP_PROPOSED=$(mktemp "${TMPDIR:-/tmp}/${PIPELINE_SCHEMA_NAME}-XXXXXX")
  trap 'rm -f "$TMP_PROPOSED"' EXIT
  printf '%s' "$PROPOSED_CONTENT" > "$TMP_PROPOSED"

  NODE_BIN="${NODE_BIN:-$(command -v node 2>/dev/null || true)}"
  pipeline_schema_validate "$TMP_PROPOSED" "$FILE_PATH" && return 0
  # Without node the schema check is skipped, but the jq checks below are
  # meaningless on unparseable content, and skipping the whole gate would
  # let a node-less orchestrator bypass it: deny.
  if [ "${PIPELINE_SCHEMA_VALIDATION_SKIPPED:-0}" = "1" ]; then
    if ! "$JQ" -e . "$TMP_PROPOSED" >/dev/null 2>&1; then
      emit_pre_deny "[BLOCKED] Proposed ${PIPELINE_MSG_LEDGER_NAME} is not parseable JSON (schema validation was skipped because node/ajv is unavailable, but jq parsing failed).

File: ${FILE_PATH}

Fix: re-author the JSON, run \`jq . <<< '<contents>'\` locally to confirm it parses, then re-issue the write."
      return 0
    fi
  fi

  pipeline_validate_transition "$TMP_PROPOSED" "$FILE_PATH" && return 0
  AGENT_ID=$(echo "$INPUT" | "$JQ" -r '.agent_id // empty' 2>/dev/null || echo "")
  AGENT_TYPE=$(echo "$INPUT" | "$JQ" -r '.agent_type // empty' 2>/dev/null || echo "")
  pipeline_check_sod "$TMP_PROPOSED" "$FILE_PATH" "$AGENT_ID" "$AGENT_TYPE" && return 0
  pipeline_check_terminal_sod "$TMP_PROPOSED" "$FILE_PATH" "$AGENT_ID" "$AGENT_TYPE" && return 0
  pipeline_check_mode_authorizer "$TMP_PROPOSED" "$FILE_PATH" && return 0
  return 1
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
