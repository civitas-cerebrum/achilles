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
     skills/onboarding/SKILL.md §\"Status ledger + workflow reviewer\""
    return 0
  fi
  return 2
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
  PRIOR_PHASE=$("$JQ" -r '.currentPhase // empty' "$FILE_PATH" 2>/dev/null || echo "")
  NEW_PHASE=$("$JQ" -r '.currentPhase // empty' "$TMP_PROPOSED" 2>/dev/null || echo "")
  case "$PRIOR_PHASE" in ''|*[!0-9]*) PRIOR_PHASE=0 ;; esac
  case "$NEW_PHASE"   in ''|*[!0-9]*) NEW_PHASE=0 ;; esac

  # Phase-skip detection: new > prior + 1 AND the in-between phase is
  # still `pending` in the new content.
  if [ "$NEW_PHASE" -gt "$((PRIOR_PHASE + 1))" ]; then
    # For every phase id between prior+1 and new-1, check status.
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

See: schemas/onboarding-status.schema.json
     skills/onboarding/SKILL.md §\"Status ledger + workflow reviewer\""
        return 0
      fi
    done
  fi

  # reviewerVerdict approved without handoverEnvelope check — scan every
  # phase's new state for the violation.
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

See: schemas/onboarding-status.schema.json
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
    PRIOR_V=$("$JQ" -r ".phases[${vp_idx}].reviewerVerdict // empty" "$FILE_PATH" 2>/dev/null || echo "")
    NEW_V=$("$JQ" -r ".phases[${vp_idx}].reviewerVerdict // empty" "$TMP_PROPOSED" 2>/dev/null || echo "")
    [ -n "$NEW_V" ] || continue
    PRIOR_C=$("$JQ" -r ".phases[${vp_idx}].reviewerCycles // 0" "$FILE_PATH" 2>/dev/null || echo "0")
    NEW_C=$("$JQ" -r ".phases[${vp_idx}].reviewerCycles // 0" "$TMP_PROPOSED" 2>/dev/null || echo "0")
    case "$PRIOR_C" in ''|*[!0-9]*) PRIOR_C=0 ;; esac
    case "$NEW_C"   in ''|*[!0-9]*) NEW_C=0 ;; esac
    PHASE_ID=$((vp_idx + 1))
    # Exempt user-authorised skips: a phase whose new status is "skipped"
    # with a matching approvedDeviations[] authorizer is approved via the
    # user channel, not a reviewer round — reviewerCycles does not apply.
    NEW_STATUS_VP=$("$JQ" -r ".phases[${vp_idx}].status // empty" "$TMP_PROPOSED" 2>/dev/null || echo "")
    if [ "$NEW_STATUS_VP" = "skipped" ]; then
      HAS_AUTH=$("$JQ" -r --argjson id "$PHASE_ID" \
        '((.approvedDeviations // []) | any(.phase == $id and ((.authorizer // "") | length) > 0))' \
        "$TMP_PROPOSED" 2>/dev/null || echo "false")
      [ "$HAS_AUTH" = "true" ] && continue
    fi
    if [ "$NEW_V" != "$PRIOR_V" ]; then
      # Verdict changed — reviewerCycles must increment by exactly 1.
      if [ "$NEW_C" -ne "$((PRIOR_C + 1))" ]; then
        pipeline_emit_deny "[BLOCKED] Phase ${PHASE_ID} reviewerVerdict changed (\"${PRIOR_V:-<unset>}\" → \"${NEW_V}\") without incrementing reviewerCycles by exactly 1 (was ${PRIOR_C}, proposed ${NEW_C}).

File: ${FILE_PATH}

Each verdict is one review round. reviewerCycles is the round counter the
3-cycle escalation cap keys on — a verdict change that doesn't bump it by
exactly 1 either hides re-review churn or evades the cap.

Fix: set phases[${vp_idx}].reviewerCycles = $((PRIOR_C + 1)) in the same write.

See: schemas/onboarding-status.schema.json
     skills/workflow-reviewer/SKILL.md §\"Reject cap\""
        return 0
      fi
    fi
    # 3rd-round rejection must escalate, not reject — fires whenever the
    # proposed state lands a rejected verdict at the cap, whether or not the
    # verdict string changed in this write.
    if [ "$NEW_C" -eq 3 ] && [ "$NEW_V" = "rejected" ]; then
      NEW_PIPE=$("$JQ" -r '.status // empty' "$TMP_PROPOSED" 2>/dev/null || echo "")
      pipeline_emit_deny "[BLOCKED] Phase ${PHASE_ID} reviewerVerdict \"rejected\" at reviewerCycles == 3.

File: ${FILE_PATH}

The reviewer reject cap is 3 rounds. A 3rd rejection cannot stay
\"rejected\" — it must escalate to the user: reviewerVerdict
\"escalated-to-user\" AND the top-level pipeline status \"blocked\"
(observed pipeline status: \"${NEW_PIPE:-<unset>}\").

Fix: set phases[${vp_idx}].reviewerVerdict = \"escalated-to-user\" and the
top-level .status = \"blocked\". The orchestrator surfaces the blockage to
the user rather than looping a 4th review.

See: skills/workflow-reviewer/SKILL.md §\"Reject cap\" (3-cycle limit)"
      return 0
    fi
  done
  return 1
}
