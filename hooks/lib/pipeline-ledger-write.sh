#!/bin/bash
# pipeline-ledger-write.sh — the PreToolUse:Write|Edit ledger gate shared by
# the onboarding and perf-onboarding pipelines. A gate sources this file, runs
# hook_jq_init (its fatal message names the calling hook), calls
# pipeline_config, sets PIPELINE_SCHEMA_NAME plus the keys below, and calls
# pipeline_ledger_write_main with its per-phase deliverable check.
#
#   PIPELINE_APPROVER_TYPES         — agent_type values that may record approvals
#   PIPELINE_PHASE_COUNT            — deliverables are checked for phases 1..N
#   PIPELINE_MSG_PHASE_LABEL        — deliverable deny lead (e.g. Phase)
#   PIPELINE_MSG_DELIVERABLE_LEDGER — the ledger as the deliverable deny names it
#   PIPELINE_MSG_DELIVERABLE_WHY    — appended to the deliverable deny's rationale

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/hook-io.sh"
hook_lib hook-emit.sh achilles-activation.sh pipeline-gate.sh

# pipeline_ledger_write_main <deliverables_fn>
# Gates a Write / Edit of the ledger at PIPELINE_MSG_LEDGER_REL, in order:
# synthesise the proposed ledger (TMP_PROPOSED, removed on exit), schema +
# parseability, state-machine transition, approver identity (new approvals,
# then the terminal-status off-switch), mode authorisation. Then calls
# <deliverables_fn> <phase> for each phase the write moves to "completed",
# with PROJECT_ROOT set to the directory holding the ledger's tests/ tree.
# Always exits.
# Reads the hook payload from stdin.
# Requires: JQ  HOOK_REFS  PIPELINE_*
pipeline_ledger_write_main() {
  local deliverables_fn="$1" TOOL_NAME FILE_PATH phase new_status prior_status
  local PROPOSED_CONTENT="" OLD_STRING NEW_STRING REPLACE_ALL TMP_OLD TMP_NEW ALL_FLAG SYNTH_EXIT SYNTH_ERR_FILE SYNTH_ERR AGENT_ID AGENT_TYPE
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
          exit 0
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
          exit 0
        fi
      fi
      ;;
  esac
  [ -n "$PROPOSED_CONTENT" ] || exit 0

  TMP_PROPOSED=$(mktemp "${TMPDIR:-/tmp}/${PIPELINE_SCHEMA_NAME}-XXXXXX")
  trap 'rm -f "$TMP_PROPOSED"' EXIT
  printf '%s' "$PROPOSED_CONTENT" > "$TMP_PROPOSED"

  NODE_BIN="${NODE_BIN:-$(command -v node 2>/dev/null || true)}"
  pipeline_schema_validate "$TMP_PROPOSED" "$FILE_PATH" && exit 0
  # Without node the schema check is skipped, but the jq checks below are
  # meaningless on unparseable content, and skipping the whole gate would
  # let a node-less orchestrator bypass it: deny.
  if [ "${PIPELINE_SCHEMA_VALIDATION_SKIPPED:-0}" = "1" ]; then
    if ! "$JQ" -e . "$TMP_PROPOSED" >/dev/null 2>&1; then
      emit_pre_deny "[BLOCKED] Proposed ${PIPELINE_MSG_LEDGER_NAME} is not parseable JSON (schema validation was skipped because node/ajv is unavailable, but jq parsing failed).

File: ${FILE_PATH}

Fix: re-author the JSON, run \`jq . <<< '<contents>'\` locally to confirm it parses, then re-issue the write."
      exit 0
    fi
  fi

  # The user-approved plumber (lib/plumber.sh) repairs a ledger the state machine would refuse.
  # The shape is still validated above; in place of the transition and approver checks, the
  # repair must leave its own audit row.
  hook_lib plumber.sh
  if plumber_caller_is_plumber "$INPUT"; then
    pipeline_plumber_audit_row "$TMP_PROPOSED" "$FILE_PATH" && exit 0
    plumber_audit "$INPUT" ledger-repair "$FILE_PATH"
    exit 0
  fi

  pipeline_validate_transition "$TMP_PROPOSED" "$FILE_PATH" && exit 0
  AGENT_ID=$(echo "$INPUT" | "$JQ" -r '.agent_id // empty' 2>/dev/null || echo "")
  AGENT_TYPE=$(echo "$INPUT" | "$JQ" -r '.agent_type // empty' 2>/dev/null || echo "")
  pipeline_check_sod "$TMP_PROPOSED" "$FILE_PATH" "$AGENT_ID" "$AGENT_TYPE" && exit 0
  pipeline_check_terminal_sod "$TMP_PROPOSED" "$FILE_PATH" "$AGENT_ID" "$AGENT_TYPE" && exit 0
  pipeline_check_mode_authorizer "$TMP_PROPOSED" "$FILE_PATH" && exit 0

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
# Requires: JQ  HOOK_REFS  PIPELINE_LEDGER  PIPELINE_MSG_PHASE_LABEL  PIPELINE_MSG_DELIVERABLE_*
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

# pipeline_plumber_audit_row <proposed> <file_path>
# A plumber write must ADD an approvedDeviations[] entry whose deviation starts with
# "plumber-repair:" and whose authorizer is the user's approval, verbatim, and must keep every
# entry already there. Returns 0 + emits deny when it does not; 1 when the row is in place.
# Requires: JQ  plumber_live_grant (lib/plumber.sh)
pipeline_plumber_audit_row() {
  local proposed="$1" file="$2" approval prior="[]" ok
  approval=$(plumber_live_grant) || approval=""
  [ -f "$file" ] && prior=$("$JQ" -c '.approvedDeviations // []' "$file" 2>/dev/null || echo "[]")
  ok=$("$JQ" -r --argjson prior "$prior" --arg a "$approval" '
    (.approvedDeviations // []) as $now
    | ($prior | all(. as $p | $now | index([$p]) != null))
      and ([$now[] | select(. as $e | $prior | index([$e]) == null)
            | select((.deviation // "" | startswith("plumber-repair:")) and (.authorizer // "") == $a)]
           | length > 0)' "$proposed" 2>/dev/null || echo false)
  [ "$ok" = "true" ] && return 1
  emit_pre_deny "[BLOCKED] Plumber ledger repair without its audit row.

File: ${file}

A plumber write to a pipeline ledger must add one approvedDeviations[] entry, and keep
every entry already there:

  { \"phase\": <currentPhase>,
    \"deviation\": \"plumber-repair: <what was wrong and what you changed>\",
    \"authorizer\": <the user's approval, verbatim — below> }

The user's approval for this grant:
${approval}

Fix: add that entry in the same write and re-issue it."
  return 0
}
