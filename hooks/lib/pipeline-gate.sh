#!/bin/bash
# pipeline-gate.sh — shared enforcement spine for ledger-gated orchestrator
# pipelines (onboarding, perf-onboarding). Sourced by pipeline-dispatch.sh
# and pipeline-ledger-write.sh, whose callers set the PIPELINE_* config
# (the part both gates of a pipeline share through pipeline_config).
#
# Config contract:
#   PIPELINE_LEDGER        — absolute path to the pipeline's status ledger JSON
#   PIPELINE_SIDECAR       — absolute path to the .ledger-integrity.json sidecar
#                            (both derived from the hook input by the *_main drivers)
#   PIPELINE_KIND          — onboarding | perf (dispatch gate only: ledger_path,
#                            dispatch_phase_number)
#   PIPELINE_SCHEMA_NAME   — validator-bundle schema id (write-gate only)
#   PIPELINE_CAP_PREFIX_RE — sed -E capture extracting a reviewer's target phase
#   JQ                     — path to jq (the gate resolves this already)
#
# Message-token contract (set by the sourcing gate alongside the above):
#   PIPELINE_MSG_LEDGER_NAME   — bare ledger filename (e.g. onboarding-status.json)
#   PIPELINE_MSG_SIDECAR_REL   — relative sidecar path (e.g. tests/e2e/docs/.ledger-integrity.json)
#   PIPELINE_MSG_LEDGER_REL    — relative ledger path  (e.g. tests/e2e/docs/onboarding-status.json)
#   PIPELINE_MSG_REVIEWER_LABEL — reviewer description prefix without trailing number/colon
#                                 (e.g. workflow-reviewer-phase — appended with "${N}:")
#   PIPELINE_MSG_SKILL_REF     — orchestrator skill path (e.g. skills/onboarding/SKILL.md)
#   PIPELINE_MSG_SCHEMA_REF    — ledger schema path (e.g. schemas/onboarding-status.schema.json)
#   PIPELINE_MSG_REVIEWER_SKILL — reviewer skill path (e.g. skills/workflow-reviewer/SKILL.md)

# shellcheck disable=SC1091
[ -n "${LEDGER_ONBOARDING_REL:-}" ] || . "$(dirname "${BASH_SOURCE[0]}")/ledger.sh"

# Deny without the calling hook's HOOK_REFS: the gate's messages carry their own references.
pipeline_emit_deny() { HOOK_REFS= emit_pre_deny "$1"; }

# pipeline_config <onboarding|perf>
# Sets the config both gates of a pipeline share: PIPELINE_KIND, the
# PIPELINE_MSG_* tokens, and HOOK_REFS, the methodology pointers appended to
# every deny the gates emit (repo convention: contributing-to-achilles-protocol/
# SKILL.md §"Hook error message format — repo standard").
pipeline_config() {
  PIPELINE_KIND="$1"
  PIPELINE_MSG_REVIEWER_SKILL='skills/workflow-reviewer/SKILL.md'
  case "$1" in
    onboarding)
      printf -v HOOK_REFS -- "\n\nReferences:\n  skills/onboarding/SKILL.md §\"Status ledger + workflow reviewer\"\n  skills/workflow-reviewer/SKILL.md\n  schemas/onboarding-status.schema.json"
      PIPELINE_MSG_LEDGER_NAME='onboarding-status.json'
      PIPELINE_MSG_SIDECAR_REL='tests/e2e/docs/.ledger-integrity.json'
      PIPELINE_MSG_LEDGER_REL="$LEDGER_ONBOARDING_REL"
      PIPELINE_MSG_REVIEWER_LABEL='workflow-reviewer-phase'
      PIPELINE_MSG_SKILL_REF='skills/onboarding/SKILL.md'
      PIPELINE_MSG_SCHEMA_REF='schemas/onboarding-status.schema.json'
      ;;
    perf)
      printf -v HOOK_REFS -- "\n\nReferences:\n  skills/perf-onboarding/SKILL.md\n  skills/workflow-reviewer/SKILL.md\n  schemas/perf-onboarding-status.schema.json"
      PIPELINE_MSG_LEDGER_NAME='perf-onboarding-status.json'
      PIPELINE_MSG_SIDECAR_REL='tests/perf/docs/.ledger-integrity.json'
      PIPELINE_MSG_LEDGER_REL="$LEDGER_PERF_REL"
      PIPELINE_MSG_REVIEWER_LABEL='perf-reviewer-phase'
      PIPELINE_MSG_SKILL_REF='skills/perf-onboarding/SKILL.md'
      PIPELINE_MSG_SCHEMA_REF='schemas/perf-onboarding-status.schema.json'
      ;;
  esac
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

See: ${PIPELINE_MSG_REVIEWER_SKILL} §\"Reject cap\" (3-cycle limit)"
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
      pipeline_emit_deny "[BLOCKED] ${PIPELINE_MSG_LEDGER_NAME} is missing but its integrity sidecar survives — the ledger appears to have been deleted out of band. Dispatches are blocked until the operator confirms the reset by removing ${PIPELINE_MSG_SIDECAR_REL} in their own terminal."
      return 0
    fi
    return 1
  fi
  if [ -f "$PIPELINE_SIDECAR" ]; then
    CHAIN_LATEST=$("$JQ" -r '.records[-1].sha256 // empty' "$PIPELINE_SIDECAR" 2>/dev/null || echo "")
    CHAIN_PREV=$("$JQ" -r '.records[-2].sha256 // empty' "$PIPELINE_SIDECAR" 2>/dev/null || echo "")
    LEDGER_HASH=$(file_sha256 "$PIPELINE_LEDGER")
    if [ -n "$CHAIN_LATEST" ] && [ -n "$LEDGER_HASH" ] && [ "$LEDGER_HASH" != "$CHAIN_LATEST" ] && [ "$LEDGER_HASH" != "$CHAIN_PREV" ]; then
      pipeline_emit_deny "[BLOCKED] ${PIPELINE_MSG_LEDGER_NAME} does not match its sanctioned hash chain (out-of-band mutation detected). Dispatches are blocked. Surface this to the user — recovery is an operator action (restore the ledger or delete ${PIPELINE_MSG_SIDECAR_REL} in their own terminal)."
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
    pipeline_emit_deny "[BLOCKED] Phase ${LAST_DONE_PHASE} completed but no ${PIPELINE_MSG_REVIEWER_LABEL}${LAST_DONE_PHASE}: has approved the transition yet.

Description: \"${DESCRIPTION}\"

The ledger at ${PIPELINE_MSG_LEDGER_REL} shows phase ${LAST_DONE_PHASE}
finished (status = completed / blocked) but reviewerVerdict is still
\"pending\". Every phase / pass / cycle transition is gated by a
workflow-reviewer-* subagent — the orchestrator cannot start the next
unit of work until the reviewer for the prior unit has returned
\`verdict: approve\`.

Fix: dispatch \`${PIPELINE_MSG_REVIEWER_LABEL}${LAST_DONE_PHASE}:\` next. Brief
the reviewer with the ledger row + the closing subagent's handoverEnvelope
and the canonical exit criteria from ${PIPELINE_MSG_SKILL_REF} §\"Phase
${LAST_DONE_PHASE}\".

See:
  - ${PIPELINE_MSG_SKILL_REF} §\"Status ledger + workflow reviewer\"
  - ${PIPELINE_MSG_REVIEWER_SKILL}
  - schemas/subagent-returns/workflow-reviewer.schema.json"
    return 0
  fi
  return 1
}

# pipeline_schema_validate <tmp_proposed> <file_path>
# Validates <tmp_proposed> against the Ajv schema named by PIPELINE_SCHEMA_NAME.
# Sets PIPELINE_SCHEMA_VALIDATION_SKIPPED=1 when node/bundle are unavailable
# (schema check is skipped, but jq-parseability check still fires in caller).
# Returns 0 + emits deny on failure; 1 when schema check was skipped;
# 2 when validation passed.
# Requires: PIPELINE_SCHEMA_NAME  NODE_BIN  VALIDATOR  JQ
# Caller: on return 0 → exit 0.
pipeline_schema_validate() {
  local TMP_PROPOSED="$1"
  local FILE_PATH="$2"
  PIPELINE_SCHEMA_VALIDATION_SKIPPED=0
  local VALIDATE_EXIT=0
  local VALIDATE_OUT=""
  if [ -z "${NODE_BIN:-}" ] || [ ! -f "${VALIDATOR:-}" ]; then
    PIPELINE_SCHEMA_VALIDATION_SKIPPED=1
    return 1
  fi
  VALIDATE_OUT=$("$NODE_BIN" "$VALIDATOR" validate "$PIPELINE_SCHEMA_NAME" "$TMP_PROPOSED" 2>&1) || VALIDATE_EXIT=$?
  if [ "$VALIDATE_EXIT" != "0" ]; then
    local IS_PARSE_FAIL=0
    case "$VALIDATE_OUT" in
      *PARSE_FAIL:*) IS_PARSE_FAIL=1 ;;
    esac
    # The bundle reads the data file with a YAML-tolerant parser, so a
    # non-JSON bare scalar (e.g. 'not-json-at-all') parses as a YAML
    # string and surfaces as SCHEMA_FAIL ('/ must be object') instead of
    # PARSE_FAIL. Re-check with jq so the parse/schema deny split stays
    # accurate for JSON.
    if [ "$IS_PARSE_FAIL" = "0" ] && ! "$JQ" -e . "$TMP_PROPOSED" >/dev/null 2>&1; then
      IS_PARSE_FAIL=1
    fi
    if [ "$IS_PARSE_FAIL" = "1" ]; then
      pipeline_emit_deny "[BLOCKED] Proposed ${PIPELINE_SCHEMA_NAME}.json is not parseable JSON.

File: ${FILE_PATH}

The ledger is the single source of truth for the pipeline state. A
malformed write would silently degrade every downstream gate.

Validator output:
${VALIDATE_OUT}

Fix: re-author the JSON, run \`jq . <<< '<contents>'\` locally to confirm
it parses, then re-issue the write.

See: schemas/${PIPELINE_SCHEMA_NAME}.schema.json"
      return 0
    fi

    pipeline_emit_deny "[BLOCKED] Proposed ${PIPELINE_SCHEMA_NAME}.json fails schema validation.

File: ${FILE_PATH}
Schema: ${PIPELINE_SCHEMA_NAME} (inlined in hooks/lib/validator.bundle.mjs; source schemas/${PIPELINE_SCHEMA_NAME}.schema.json)

Validator output:
${VALIDATE_OUT}

Fix: correct the failing field(s) above; the schema is the authoritative
spec. The valid + invalid fixtures under schemas/${PIPELINE_SCHEMA_NAME}.fixtures/
are working examples of the shape.

See: schemas/${PIPELINE_SCHEMA_NAME}.schema.json
     ${PIPELINE_MSG_SKILL_REF} §\"Status ledger + workflow reviewer\""
    return 0
  fi
  return 2
}

# pipeline_out_of_order_phase_check <description> <current_phase>
# Rules 1+2: if the description targets a phase ahead of current and the
# prior phase is not approved, deny.
# Returns 0 + emits deny if gated; 1 for fall-through.
# Requires: PIPELINE_LEDGER  PIPELINE_KIND  JQ
pipeline_out_of_order_phase_check() {
  local DESCRIPTION="$1"
  local CURRENT_PHASE="$2"
  local TARGET_PHASE PRIOR_PHASE PRIOR_VERDICT
  TARGET_PHASE=$(dispatch_phase_number "$PIPELINE_KIND" "$DESCRIPTION")
  if [ -n "$TARGET_PHASE" ] && [ "$TARGET_PHASE" -gt "$CURRENT_PHASE" ]; then
    PRIOR_PHASE=$((TARGET_PHASE - 1))
    PRIOR_VERDICT=$("$JQ" -r --argjson id "$PRIOR_PHASE" '
      [.phases[]? | select(.id == $id)] | .[0].reviewerVerdict // "pending"
    ' "$PIPELINE_LEDGER" 2>/dev/null || echo "pending")
    if [ "$PRIOR_VERDICT" != "approved" ]; then
      pipeline_emit_deny "[BLOCKED] Out-of-order phase dispatch — phase ${TARGET_PHASE} cannot start while phase ${PRIOR_PHASE} is not reviewer-approved.

Description: \"${DESCRIPTION}\"

The ledger at ${PIPELINE_MSG_LEDGER_REL} shows:
  currentPhase     = ${CURRENT_PHASE}
  target phase     = ${TARGET_PHASE} (inferred from the dispatch description)
  prior phase      = ${PRIOR_PHASE}
  prior verdict    = \"${PRIOR_VERDICT}\" (must be \"approved\")

Every phase transition is state-machine-enforced via the
workflow-reviewer-* subagent family.

Fix: dispatch \`${PIPELINE_MSG_REVIEWER_LABEL}${PRIOR_PHASE}:\` first. If the
reviewer returns \`verdict: approve\`, the orchestrator updates the
ledger (reviewerVerdict → approved, currentPhase → ${TARGET_PHASE}) and
re-issues this dispatch.

See:
  - ${PIPELINE_MSG_SKILL_REF} §\"Status ledger + workflow reviewer\"
  - ${PIPELINE_MSG_REVIEWER_SKILL}
  - ${PIPELINE_MSG_SCHEMA_REF}
  - schemas/subagent-returns/workflow-reviewer.schema.json"
      return 0
    fi
  fi
  return 1
}

# pipeline_validate_transition <tmp_proposed> <file_path>
# State-machine transition checks: phase-skip, approved-requires-handover,
# reviewerCycles+1 on verdict-change, 3rd-reject-must-escalate.
# Only meaningful when <file_path> exists (prior ledger present).
# Returns 0 + emits deny on violation; 1 when all checks pass.
# Requires: JQ
# Caller: on return 0 → exit 0.
pipeline_validate_transition() {
  local TMP_PROPOSED="$1"
  local FILE_PATH="$2"
  [ -f "$FILE_PATH" ] || return 1

  local PRIOR_PHASE NEW_PHASE
  PRIOR_PHASE=$(ledger_get "$FILE_PATH" .currentPhase)
  NEW_PHASE=$(ledger_get "$TMP_PROPOSED" .currentPhase)
  case "$PRIOR_PHASE" in ''|*[!0-9]*) PRIOR_PHASE=0 ;; esac
  case "$NEW_PHASE"   in ''|*[!0-9]*) NEW_PHASE=0 ;; esac

  # Phase-skip detection: new > prior + 1 AND the in-between phase is
  # still `pending` in the new content.
  if [ "$NEW_PHASE" -gt "$((PRIOR_PHASE + 1))" ]; then
    local MID_ID MID_STATUS
    for MID_ID in $(seq $((PRIOR_PHASE + 1)) $((NEW_PHASE - 1))); do
      MID_STATUS=$("$JQ" -r --argjson id "$MID_ID" '
        [.phases[]? | select(.id == $id)] | .[0].status // "pending"
      ' "$TMP_PROPOSED" 2>/dev/null || echo "pending")
      if [ "$MID_STATUS" = "pending" ] || [ "$MID_STATUS" = "in-progress" ]; then
        pipeline_emit_deny "[BLOCKED] Out-of-order ledger transition — currentPhase jumped ${PRIOR_PHASE} → ${NEW_PHASE} while phase ${MID_ID} is still \"${MID_STATUS}\".

File: ${FILE_PATH}

Every phase must progress through pending → in-progress → completed in
order. Skips are allowed only when the phase's status is set to
\"skipped\" AND an approvedDeviations[] entry carries a verbatim
authorizer field.

Fix: either (a) complete phase ${MID_ID} first, OR (b) mark phase
${MID_ID} as status: skipped AND add the corresponding
approvedDeviations[] entry with the authorizer quote.

See: ${PIPELINE_MSG_SCHEMA_REF}
     ${PIPELINE_MSG_SKILL_REF} §\"Status ledger + workflow reviewer\""
        return 0
      fi
    done
  fi

  # An approved verdict needs a handoverEnvelope in any phase.
  local BAD_PHASE
  BAD_PHASE=$("$JQ" -r '
    [.phases[]? | select(.reviewerVerdict == "approved" and (.handoverEnvelope == null))] |
    if length == 0 then "" else (.[0].id | tostring) end
  ' "$TMP_PROPOSED" 2>/dev/null || echo "")
  if [ -n "$BAD_PHASE" ]; then
    pipeline_emit_deny "[BLOCKED] Ledger phase ${BAD_PHASE} has reviewerVerdict: \"approved\" but handoverEnvelope is null.

File: ${FILE_PATH}

A phase cannot be approved unless the closing subagent's handover
envelope is captured in the same record — the reviewer reads the
envelope as part of its evidence base, and downstream tooling needs the
envelope to reconstruct what the phase produced.

Fix: populate phases[${BAD_PHASE} - 1].handoverEnvelope with the closing
subagent's envelope (see schemas/subagent-returns/handover.schema.json
for the shape) before re-issuing the write.

See: ${PIPELINE_MSG_SCHEMA_REF}
     schemas/subagent-returns/handover.schema.json"
    return 0
  fi

  # reviewerCycles enforcement.
  #  - Any write that CHANGES a phase's reviewerVerdict must increment that
  #    phase's reviewerCycles by exactly 1 (each verdict is one review
  #    round; skipping the counter hides re-review churn / lets the 3-cap
  #    be evaded).
  #  - At reviewerCycles == 3 the verdict may NOT be "rejected": the 3rd
  #    rejection must escalate — reviewerVerdict "escalated-to-user" AND the
  #    top-level pipeline status "blocked".
  local vp_idx PRIOR_V NEW_V PRIOR_C NEW_C PHASE_ID NEW_STATUS_VP HAS_AUTH NEW_PIPE
  for vp_idx in 0 1 2 3 4 5 6 7; do
    PRIOR_V=$(ledger_get "$FILE_PATH" ".phases[${vp_idx}].reviewerVerdict")
    NEW_V=$(ledger_get "$TMP_PROPOSED" ".phases[${vp_idx}].reviewerVerdict")
    [ -n "$NEW_V" ] || continue
    PRIOR_C=$(ledger_get "$FILE_PATH" ".phases[${vp_idx}].reviewerCycles" 0)
    NEW_C=$(ledger_get "$TMP_PROPOSED" ".phases[${vp_idx}].reviewerCycles" 0)
    case "$PRIOR_C" in ''|*[!0-9]*) PRIOR_C=0 ;; esac
    case "$NEW_C"   in ''|*[!0-9]*) NEW_C=0 ;; esac
    PHASE_ID=$((vp_idx + 1))
    # Exempt user-authorised skips: a phase whose new status is "skipped"
    # with a matching approvedDeviations[] authorizer is approved via the
    # user channel, not a reviewer round — reviewerCycles does not apply.
    NEW_STATUS_VP=$(ledger_get "$TMP_PROPOSED" ".phases[${vp_idx}].status")
    if [ "$NEW_STATUS_VP" = "skipped" ]; then
      HAS_AUTH=$("$JQ" -r --argjson id "$PHASE_ID" \
        '((.approvedDeviations // []) | any(.phase == $id and ((.authorizer // "") | length) > 0))' \
        "$TMP_PROPOSED" 2>/dev/null || echo "false")
      [ "$HAS_AUTH" = "true" ] && continue
    fi
    if [ "$NEW_V" != "$PRIOR_V" ]; then
      if [ "$NEW_C" -ne "$((PRIOR_C + 1))" ]; then
        pipeline_emit_deny "[BLOCKED] Phase ${PHASE_ID} reviewerVerdict changed (\"${PRIOR_V:-<unset>}\" → \"${NEW_V}\") without incrementing reviewerCycles by exactly 1 (was ${PRIOR_C}, proposed ${NEW_C}).

File: ${FILE_PATH}

Each verdict is one review round. reviewerCycles is the round counter the
3-cycle escalation cap keys on — a verdict change that doesn't bump it by
exactly 1 either hides re-review churn or evades the cap.

Fix: set phases[${vp_idx}].reviewerCycles = $((PRIOR_C + 1)) in the same write.

See: ${PIPELINE_MSG_SCHEMA_REF}
     ${PIPELINE_MSG_REVIEWER_SKILL} §\"Reject cap\""
        return 0
      fi
    fi
    # 3rd-round rejection must escalate, not reject — fires whenever the
    # proposed state lands a rejected verdict at the cap, whether or not the
    # verdict string changed in this write.
    if [ "$NEW_C" -eq 3 ] && [ "$NEW_V" = "rejected" ]; then
      NEW_PIPE=$(ledger_get "$TMP_PROPOSED" .status)
      pipeline_emit_deny "[BLOCKED] Phase ${PHASE_ID} reviewerVerdict \"rejected\" at reviewerCycles == 3.

File: ${FILE_PATH}

The reviewer reject cap is 3 rounds. A 3rd rejection cannot stay
\"rejected\" — it must escalate to the user: reviewerVerdict
\"escalated-to-user\" AND the top-level pipeline status \"blocked\"
(observed pipeline status: \"${NEW_PIPE:-<unset>}\").

Fix: set phases[${vp_idx}].reviewerVerdict = \"escalated-to-user\" and the
top-level .status = \"blocked\". The orchestrator surfaces the blockage to
the user rather than looping a 4th review.

See: ${PIPELINE_MSG_REVIEWER_SKILL} §\"Reject cap\" (3-cycle limit)"
      return 0
    fi
  done
  return 1
}

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/pipeline-sod.sh"
