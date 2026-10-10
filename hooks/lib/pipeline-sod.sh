#!/bin/bash
# pipeline-sod.sh — who may write a pipeline ledger: separation of duties for
# approval-class writes (phase/substage approvals, terminal status) and the
# runMode authoriser. Sourced by pipeline-gate.sh; same config contract.
# Size: approver registry, TTL, skip stripping and the runMode authoriser are one separation-of-duties check.

# pipeline_check_sod <tmp_proposed> <file_path> <agent_id>
# Separation-of-duties: any write that newly approves a phase or substage
# must come from a dispatched subagent that is in the approver registry and
# within the TTL. Also strips user-authorised skips from the approval set.
# Returns 0 + emits deny on violation; 1 when no new approvals (silent pass)
# or when all checks pass.
# Requires: JQ
# The registry file is expected at $(dirname <file_path>)/.workflow-approvers.json
# Caller: on return 0 → exit 0.
pipeline_check_sod() {
  local TMP_PROPOSED="$1"
  local FILE_PATH="$2"
  local AGENT_ID="$3"
  local AGENT_TYPE="${4:-}"

  # Compute the set of phase ids that are NEWLY approved in this write.
  local PRIOR_APPROVED NEW_APPROVED NEW_APPROVAL_IDS SKIP_AUTHORISED_IDS
  if [ -f "$FILE_PATH" ]; then
    PRIOR_APPROVED=$("$JQ" -c '[.phases[]? | select(.reviewerVerdict == "approved") | .id]' "$FILE_PATH" 2>/dev/null || echo "[]")
  else
    PRIOR_APPROVED="[]"
  fi
  NEW_APPROVED=$("$JQ" -c '[.phases[]? | select(.reviewerVerdict == "approved") | .id]' "$TMP_PROPOSED" 2>/dev/null || echo "[]")

  NEW_APPROVAL_IDS=$("$JQ" -nc \
    --argjson prior "$PRIOR_APPROVED" \
    --argjson new "$NEW_APPROVED" \
    '[$new[] | select(. as $n | $prior | index($n) | not)]' 2>/dev/null || echo "[]")

  # Carve-out: user-authorised skips. A phase whose `status == "skipped"`
  # AND has a matching `approvedDeviations[]` entry with a non-empty
  # `authorizer` field is approved via the user-authorization channel,
  # not via a reviewer subagent. The authorizer's verbatim quote is the
  # attestation. Remove these phase ids from the approval-set so the
  # actor-identity check below doesn't fire on them.
  SKIP_AUTHORISED_IDS=$("$JQ" -c '
    [ .phases[]? as $p
      | select($p.status == "skipped" and $p.reviewerVerdict == "approved")
      | $p.id as $pid
      | select(
          (.approvedDeviations // [])
          | any(.phase == $pid and ((.authorizer // "") | length) > 0)
        )
      | $pid
    ]
  ' "$TMP_PROPOSED" 2>/dev/null || echo "[]")

  NEW_APPROVAL_IDS=$("$JQ" -nc \
    --argjson all "$NEW_APPROVAL_IDS" \
    --argjson skip "$SKIP_AUTHORISED_IDS" \
    '[$all[] | select(. as $n | $skip | index($n) | not)]' 2>/dev/null || echo "[]")

  # Same check at sub-stage level (Phase-4 cycles, Phase-5 passes). We
  # expose the substage approvals as `<phase-id>.<substage-id>` strings.
  local PRIOR_SUBSTAGE_APPROVED NEW_SUBSTAGE_APPROVED NEW_SUBSTAGE_APPROVAL_IDS
  if [ -f "$FILE_PATH" ]; then
    PRIOR_SUBSTAGE_APPROVED=$("$JQ" -c '
      [ .phases[]? as $p | $p.subStages[]? | select(.reviewerVerdict == "approved")
        | "\($p.id).\(.id)" ]
    ' "$FILE_PATH" 2>/dev/null || echo "[]")
  else
    PRIOR_SUBSTAGE_APPROVED="[]"
  fi
  NEW_SUBSTAGE_APPROVED=$("$JQ" -c '
    [ .phases[]? as $p | $p.subStages[]? | select(.reviewerVerdict == "approved")
      | "\($p.id).\(.id)" ]
  ' "$TMP_PROPOSED" 2>/dev/null || echo "[]")
  NEW_SUBSTAGE_APPROVAL_IDS=$("$JQ" -nc \
    --argjson prior "$PRIOR_SUBSTAGE_APPROVED" \
    --argjson new "$NEW_SUBSTAGE_APPROVED" \
    '[$new[] | select(. as $n | $prior | index($n) | not)]' 2>/dev/null || echo "[]")

  # Are there any new approvals at all?
  local HAS_NEW_PHASE_APPROVAL HAS_NEW_SUBSTAGE_APPROVAL
  HAS_NEW_PHASE_APPROVAL=$([ "$NEW_APPROVAL_IDS" = "[]" ] && echo "no" || echo "yes")
  HAS_NEW_SUBSTAGE_APPROVAL=$([ "$NEW_SUBSTAGE_APPROVAL_IDS" = "[]" ] && echo "no" || echo "yes")

  if [ "$HAS_NEW_PHASE_APPROVAL" != "yes" ] && [ "$HAS_NEW_SUBSTAGE_APPROVAL" != "yes" ]; then
    return 1
  fi

  # Actor-identity discriminator (Claude Code subagent convention).
  # A tool call from a dispatched subagent carries a non-empty `agent_id`
  # (+ `agent_type`); the top-level orchestrator's tool calls carry neither.
  local APPROVAL_SUMMARY
  APPROVAL_SUMMARY="phase ids: $NEW_APPROVAL_IDS, substage ids: $NEW_SUBSTAGE_APPROVAL_IDS"

  if [ -z "$AGENT_ID" ]; then
    pipeline_emit_deny "[BLOCKED] Ledger write transitions ${APPROVAL_SUMMARY} to reviewerVerdict: \"approved\" but the write is coming directly from the orchestrator context (no agent_id — not a dispatched subagent).

File: ${FILE_PATH}

This is the separation-of-duties gate: the orchestrator does the work, an
approver subagent records the verdict. Only writes originating inside a
\`workflow-reviewer-*\` or \`phase-validator-*\` subagent are permitted to
transition a reviewerVerdict to approved.

Fix: dispatch the matching approver subagent (e.g. \`workflow-reviewer-phase1:\`
or \`phase-validator-1:\`) and let it author this write. The orchestrator's
job ends at dispatch; the approver owns the verdict record.

See:
  - hooks/workflow-approver-registry.sh (PreToolUse:Agent — records approvers)
  - ${PIPELINE_MSG_SKILL_REF} §\"Status ledger + workflow reviewer\"
  - schemas/subagent-returns/workflow-reviewer.schema.json"
    return 0
  fi

  # Subagent context — verify the parent is in the approver registry.
  pipeline_approver_registry_check "$FILE_PATH" "Ledger write transitions ${APPROVAL_SUMMARY} to approved" "$AGENT_TYPE"
}

# pipeline_check_terminal_sod <tmp_proposed> <file_path> <agent_id> <agent_type>
# The off-switch is an approval-class write. A write that transitions the
# top-level `.status` to a TERMINAL value ("complete" / "aborted") is what
# retires the session's protocol activation marker (the activation watcher
# observes it on PostToolUse) — and with the marker goes every achilles
# gate AND the kernel-mandate role binding. Left to the orchestrator, that
# write would let the governed party end its own governance with one
# ledger edit, so it is held to exactly the identity the reviewerVerdict →
# approved transitions require: a dispatched subagent context whose parent
# is a registered, unexpired approver. Non-terminal statuses ("blocked",
# "in-progress") and writes that leave an already-terminal status in place
# are not transitions and pass through.
# Returns 0 + emits deny on violation; 1 when there is no terminal
# transition or every check passes.
# Requires: JQ
# Caller: on return 0 → exit 0.
pipeline_check_terminal_sod() {
  local TMP_PROPOSED="$1"
  local FILE_PATH="$2"
  local AGENT_ID="$3"
  local AGENT_TYPE="${4:-}"
  local NEW_STATUS PRIOR_STATUS
  NEW_STATUS=$(ledger_get "$TMP_PROPOSED" .status)
  case "$NEW_STATUS" in
    complete|aborted) ;;
    *) return 1 ;;
  esac
  PRIOR_STATUS=""
  if [ -f "$FILE_PATH" ]; then
    PRIOR_STATUS=$(ledger_get "$FILE_PATH" .status)
  fi
  # Already terminal with the same value — no transition, nothing to gate.
  [ "$PRIOR_STATUS" = "$NEW_STATUS" ] && return 1

  if [ -z "$AGENT_ID" ]; then
    pipeline_emit_deny "[BLOCKED] Ledger write transitions the top-level .status to \"${NEW_STATUS}\" (from \"${PRIOR_STATUS:-<unset>}\") but the write is coming directly from the orchestrator context (no agent_id — not a dispatched subagent).

File: ${FILE_PATH}

A terminal pipeline status is the session's OFF-SWITCH: the activation
watcher retires the achilles session marker when it lands, and with the
marker goes every achilles guardrail and the kernel-mandate role binding
for this session. That makes it an approval-class write, held to the
same separation of duties as a reviewerVerdict → approved transition —
the orchestrator does the work, an approver subagent records that the
pipeline is finished (or abandoned). The governed party does not get to
end its own governance.

Fix: dispatch the matching approver subagent (e.g. \`workflow-reviewer-final:\`
or \`phase-validator-8:\` for the onboarding pipeline, \`perf-reviewer-final:\`
for the perf pipeline) with a brief that cites the ledger and the terminal
status to record, and let it author this write. The orchestrator's job
ends at dispatch; the approver owns the terminal record.

See:
  - hooks/workflow-approver-registry.sh (PreToolUse:Agent — records approvers)
  - hooks/achilles-protocol-activation-watcher.sh (PostToolUse — retires the marker)
  - ${PIPELINE_MSG_SKILL_REF} §\"Status ledger + workflow reviewer\""
    return 0
  fi

  pipeline_approver_registry_check "$FILE_PATH" "Ledger write transitions the top-level .status to \"${NEW_STATUS}\"" "$AGENT_TYPE"
}

# pipeline_approver_registry_check <file_path> <lead> <agent_type>
# Shared registry half of the separation-of-duties checks: the calling
# write is already known to come from a subagent context (non-empty
# agent_id); verify that an approver-role dispatch was recorded in the
# registry next to the ledger and that the most recent one is unexpired.
# <lead> is the opening clause of every deny (\"Ledger write transitions …\")
# so each caller's message names its own transition.
# <agent_type> is the writer's subagent type; it must be one of
# $PIPELINE_APPROVER_TYPES (space-separated). Empty fails closed: a typed
# dispatch is part of the reviewer contract (skills/workflow-reviewer).
# Stricter than the kernel's "general-purpose is not a claim"
# rule: there, general-purpose is merely unbound; here a missing or
# general-purpose agent_type is an explicit deny because the write is an
# approval and only a named approver role may make one.
# Returns 0 + emits deny on violation; 1 when the registry checks pass.
# Requires: JQ
# The registry file is expected at $(dirname <file_path>)/.workflow-approvers.json
pipeline_approver_registry_check() {
  local FILE_PATH="$1"
  local LEAD="$2"
  local AGENT_TYPE="${3:-}"
  local REGISTRY_FILE
  case " ${PIPELINE_APPROVER_TYPES:-} " in
    *" ${AGENT_TYPE:-<none>} "*) ;;
    *)
      pipeline_emit_deny "[BLOCKED] ${LEAD}, but the writer's agent_type '${AGENT_TYPE:-<missing>}' is not an approver role (${PIPELINE_APPROVER_TYPES:-none configured}).

File: ${FILE_PATH}

Only a subagent dispatched with an approver \`subagent_type\` can record
an approval-class write; the registry check alone cannot tell a composer
from a reviewer while any approver registration is fresh.

Fix: dispatch the approver for this ledger with \`subagent_type: <role>\`
(agent definitions ship in \`agents/\`) and let it record the write.

See:
  - hooks/workflow-approver-registry.sh
  - ${PIPELINE_MSG_SKILL_REF} §\"Status ledger + workflow reviewer\""
      return 0 ;;
  esac
  REGISTRY_FILE="$(dirname "$FILE_PATH")/${LEDGER_APPROVERS_NAME}"
  if [ ! -f "$REGISTRY_FILE" ]; then
    pipeline_emit_deny "[BLOCKED] ${LEAD} from a subagent context, but no approver registry exists at:

  ${REGISTRY_FILE}

The registry is written by hooks/workflow-approver-registry.sh when a
\`workflow-reviewer-*\` or \`phase-validator-*\` Agent dispatch fires.
Its absence means the dispatching Agent did NOT have an approver-role
description prefix.

Fix: ensure the approving subagent is dispatched with description
prefix \`workflow-reviewer-<scope>:\` or \`phase-validator-<N>:\`. Other
prefixes (composer-, probe-, cleanup-) do the work but cannot record
verdicts."
    return 0
  fi

  # The registry is keyed by dispatch tool_use_id, but this build's subagent
  # writes carry `agent_id` (assigned post-dispatch), so the write cannot be
  # matched to a specific registry entry. Instead require: at least one
  # approver-prefixed dispatch recorded, AND its registration within the TTL.
  local REGISTRY_COUNT
  REGISTRY_COUNT=$("$JQ" -r '[keys[]] | length' "$REGISTRY_FILE" 2>/dev/null || echo 0)
  case "$REGISTRY_COUNT" in ''|*[!0-9]*) REGISTRY_COUNT=0 ;; esac
  if [ "$REGISTRY_COUNT" -lt 1 ]; then
    pipeline_emit_deny "[BLOCKED] ${LEAD} from a subagent context, but the approver registry is empty.

File: ${FILE_PATH}
Registry: ${REGISTRY_FILE}

Only subagents dispatched with one of these description prefixes can
record approvals:

  workflow-reviewer-<scope>:   the workflow reviewer / inspector skill
  phase-validator-<N>:         per-phase greenlight emitter

An empty registry means no approver-role subagent was dispatched. Other
prefixes (composer-, probe-, cleanup-) do the work but do not record
verdicts.

Fix: dispatch a \`workflow-reviewer-*\` or \`phase-validator-*\` to author
this approval write."
    return 0
  fi

  # TTL check — most recent approver registration within 30 minutes.
  local NOW TTL LATEST_TS REG_AGE
  NOW=$(date +%s)
  TTL=1800
  LATEST_TS=$("$JQ" -r '[.[].ts // 0] | max // 0' "$REGISTRY_FILE" 2>/dev/null || echo "0")
  case "$LATEST_TS" in ''|*[!0-9]*) LATEST_TS=0 ;; esac
  REG_AGE=$((NOW - LATEST_TS))
  if [ "$REG_AGE" -gt "$TTL" ]; then
    pipeline_emit_deny "[BLOCKED] ${LEAD} but the most recent approver registration has expired (age ${REG_AGE}s, TTL ${TTL}s).

Registry entries live for 30 minutes from dispatch. If the approver
subagent has been running longer than that, re-dispatch a fresh
\`workflow-reviewer-*\` to land the verdict.

Fix: re-dispatch the approver."
    return 0
  fi
  return 1
}

# pipeline_check_mode_authorizer <tmp_proposed> <file_path>
# Mode-authorisation: setting or changing `runMode` requires a non-empty
# `modeAuthorizer` co-located in the same write. Also prevents clearing
# modeAuthorizer while runMode is still set.
# Returns 0 + emits deny on violation; 1 when all checks pass.
# Requires: JQ
# Caller: on return 0 → exit 0.
pipeline_check_mode_authorizer() {
  local TMP_PROPOSED="$1"
  local FILE_PATH="$2"
  local NEW_MODE NEW_AUTHORIZER PRIOR_MODE PRIOR_AUTHORIZER
  NEW_MODE=$(ledger_get "$TMP_PROPOSED" .runMode)
  NEW_AUTHORIZER=$(ledger_get "$TMP_PROPOSED" .modeAuthorizer)

  PRIOR_MODE=""
  PRIOR_AUTHORIZER=""
  if [ -f "$FILE_PATH" ]; then
    PRIOR_MODE=$(ledger_get "$FILE_PATH" .runMode)
    PRIOR_AUTHORIZER=$(ledger_get "$FILE_PATH" .modeAuthorizer)
  fi

  # Case A: runMode being set or changed. The new value differs from the
  # prior (or the prior didn't exist). Requires a non-empty modeAuthorizer
  # in the SAME write — co-located with the runMode field so the audit
  # trail can't be reconstructed out of order.
  if [ -n "$NEW_MODE" ] && [ "$NEW_MODE" != "$PRIOR_MODE" ]; then
    if [ -z "$NEW_AUTHORIZER" ]; then
      pipeline_emit_deny "[BLOCKED] runMode being set to \"${NEW_MODE}\" without a modeAuthorizer field.

File: ${FILE_PATH}
Prior runMode: \"${PRIOR_MODE:-<unset>}\"
New runMode:   \"${NEW_MODE}\"

The orchestrator cannot silently choose between \`standard\` and \`depth\`
coverage-expansion modes — the user must make that choice explicitly
and the choice must land in the ledger as an audit-trail quote.

Fix: add a top-level \`modeAuthorizer\` field to the proposed write,
containing the user's verbatim quote. Examples:

  \"modeAuthorizer\": \"user said: run onboarding in standard mode\"
  \"modeAuthorizer\": \"user typed 'depth' in response to mode-selection prompt\"
  \"modeAuthorizer\": \"external CLI driver --mode=depth (CLI flag)\"

If the user has not yet been asked, ASK first; then write the ledger
with the captured quote.

See:
  - ${PIPELINE_MSG_SCHEMA_REF} §runMode
  - ${PIPELINE_MSG_SKILL_REF} §\"Front-load mode-selection gate\""
      return 0
    fi
  fi

  # Case B: runMode persists across the write but modeAuthorizer was
  # silently cleared. Prevents post-hoc tampering of the audit trail —
  # once a mode is authorised, the authoriser quote stays in the ledger
  # for as long as that mode is in effect.
  if [ -n "$NEW_MODE" ] && [ -n "$PRIOR_AUTHORIZER" ] && [ -z "$NEW_AUTHORIZER" ]; then
    pipeline_emit_deny "[BLOCKED] modeAuthorizer cleared while runMode remains set.

File: ${FILE_PATH}
runMode (preserved):       \"${NEW_MODE}\"
Prior modeAuthorizer:      \"${PRIOR_AUTHORIZER}\"
New modeAuthorizer:        <empty/missing>

Once a mode has been user-authorised, the authorisation quote must
stay in the ledger for as long as the mode is in effect. Clearing it
post-hoc would erase the audit trail.

Fix: keep the existing modeAuthorizer field unchanged, OR update both
runMode AND modeAuthorizer together (which re-triggers the case-A
check above).

See: ${PIPELINE_MSG_SCHEMA_REF} §runMode"
    return 0
  fi
  return 1
}
