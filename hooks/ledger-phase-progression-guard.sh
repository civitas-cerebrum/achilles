#!/bin/bash
# ledger-phase-progression-guard.sh — enforce phase-by-phase,
#   reviewer-gated advancement of `currentPhase` on the onboarding
#   status ledger.
#
# Hook    : PreToolUse:Write|Edit
# Mode    : DENY (blocks the write before it lands on disk)
# State   : reads the pre-existing tests/e2e/docs/onboarding-status.json
# Env     : none
#
# Why
# ---
# The onboarding pipeline advances through 8 phases. Every phase
# transition is supposed to be gated by a `workflow-reviewer-phaseN:`
# subagent: the orchestrator finishes phase N, the reviewer inspects the
# deliverables and records `reviewerVerdict: approved`, and only THEN
# does `currentPhase` advance to N+1.
#
# `onboarding-ledger-gate.sh` enforces this on the DISPATCH side (no
# phase N+1 Agent dispatch until phase N is approved). But the ledger
# WRITE side had a gap: the orchestrator could Write the ledger with
# `currentPhase` already bumped (and several phases marked `completed`)
# in a single shot, BEFORE any reviewer ran — then "retroactively
# reviewer-walk" the skipped phases afterward. A BookHive benchmark run
# (Run 10) did exactly that for Phases 1-3: did the work inline, wrote
# `currentPhase: 3` with phases 1-3 all `completed`, then dispatched the
# phase-1/2/3 reviewers after the fact. The pipeline still reached a
# valid end-state, but the per-phase reviewer gate was bypassed in
# spirit for the first three phases.
#
# This hook closes the write-side gap. It makes a forward `currentPhase`
# move legal ONLY when:
#   (a) the phase being LEFT is already `reviewerVerdict: approved` (or
#       itself `status: skipped`) in the on-disk ledger, and
#   (b) the move is exactly +1 (no multi-phase jumps), unless every
#       jumped phase is `status: skipped` in the proposed content.
#
# Together with the dispatch gate this forces the clean protocol for
# EVERY phase, 1 through 8:
#   1. write phase N completed + handoverEnvelope (currentPhase stays N)
#   2. dispatch workflow-reviewer-phaseN: → it records reviewerVerdict
#   3. write currentPhase = N+1
#
# What it gates
# -------------
# 1. Only Write/Edit to a path ending `tests/e2e/docs/onboarding-status.json`.
# 2. Reads the proposed `currentPhase`: from `.content` for Write, from
#    `.new_string` for an Edit that touches `currentPhase` (an Edit that
#    does not mention `currentPhase` cannot change it — silent allow).
# 3. Initial creation (file absent): proposed `currentPhase` must be 1.
# 4. Forward move (P_new > P_old): the phase being left must be
#    `approved`/`skipped` on disk, and the move must be +1 unless the
#    intervening phases are `skipped` in the proposed content.
# 5. Non-forward writes (P_new <= P_old — within-phase progress, reviewer
#    verdict edits, sub-stage updates) → silent allow.
#
# Failure → action
# ----------------
# Fresh ledger with currentPhase > 1     → DENY
# currentPhase advanced past an un-approved prior phase → DENY
# currentPhase jumped over a non-skipped phase          → DENY
#
# Canonical reference
# -------------------
# skills/onboarding/SKILL.md §"Status ledger + workflow reviewer"
# schemas/onboarding-status.schema.json
# hooks/onboarding-ledger-gate.sh        (dispatch-side companion)
# hooks/onboarding-ledger-write-gate.sh  (shape + actor-identity companion)

set -uo pipefail

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
if [ -z "$JQ" ]; then
  echo "[$(basename "${BASH_SOURCE[0]}")] FATAL: jq not found at \$HOOK_DIR/bin/jq nor on PATH." >&2
  exit 1
fi

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")

case "$TOOL_NAME" in
  Write|Edit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | "$JQ" -r '.tool_input.file_path // empty' 2>/dev/null || echo "")

# Only gate the onboarding status ledger.
case "$FILE_PATH" in
  */tests/e2e/docs/onboarding-status.json) ;;
  *) exit 0 ;;
esac

emit_deny() {
  local reason="$1"
  "$JQ" -n --arg r "$reason" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": $r
    }
  }'
}

# ---------------------------------------------------------------------------
# Resolve the proposed currentPhase.
# ---------------------------------------------------------------------------
P_NEW=""
case "$TOOL_NAME" in
  Write)
    CONTENT=$(echo "$INPUT" | "$JQ" -r '.tool_input.content // empty' 2>/dev/null || echo "")
    [ -n "$CONTENT" ] || exit 0
    P_NEW=$(printf '%s' "$CONTENT" | "$JQ" -r '.currentPhase // empty' 2>/dev/null || echo "")
    ;;
  Edit)
    NEW_STRING=$(echo "$INPUT" | "$JQ" -r '.tool_input.new_string // empty' 2>/dev/null || echo "")
    # An Edit can only change currentPhase if its new_string contains the
    # currentPhase key. If it doesn't, the edit is verdict/substage/etc. —
    # not our concern.
    if ! echo "$NEW_STRING" | grep -q '"currentPhase"'; then
      exit 0
    fi
    P_NEW=$(echo "$NEW_STRING" | grep -oE '"currentPhase"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+$' || echo "")
    ;;
esac

# Not parseable / absent → not a currentPhase-affecting write we can judge.
case "$P_NEW" in
  ''|*[!0-9]*) exit 0 ;;
esac

# ---------------------------------------------------------------------------
# Initial creation — file does not yet exist.
# ---------------------------------------------------------------------------
if [ ! -f "$FILE_PATH" ]; then
  if [ "$P_NEW" -gt 1 ]; then
    emit_deny "[BLOCKED] New onboarding-status.json initialised with currentPhase=${P_NEW}.

File: ${FILE_PATH}

A fresh onboarding ledger MUST start at currentPhase=1 — the pipeline
begins at Phase 1 (Scaffold) and advances one reviewer-gated phase at a
time. A ledger that starts mid-pipeline cannot have had its earlier
phases reviewer-approved.

Fix: initialise the ledger with currentPhase=1 and all 8 phases pending,
then advance one phase at a time as each workflow-reviewer-phaseN:
records its verdict.

See: skills/onboarding/SKILL.md §\"Status ledger + workflow reviewer\""
    exit 0
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Existing ledger — compare prior vs proposed currentPhase.
# ---------------------------------------------------------------------------
P_OLD=$("$JQ" -r '.currentPhase // empty' "$FILE_PATH" 2>/dev/null || echo "")
case "$P_OLD" in
  ''|*[!0-9]*) exit 0 ;;
esac

# Non-forward write (within-phase progress, reviewer verdict edits,
# sub-stage updates, rollbacks) → not gated here.
[ "$P_NEW" -gt "$P_OLD" ] || exit 0

# ---------------------------------------------------------------------------
# Forward move. The phase being LEFT must be reviewer-approved (or itself
# skipped) in the PRIOR on-disk ledger.
# ---------------------------------------------------------------------------
PRIOR_VERDICT=$("$JQ" -r --argjson id "$P_OLD" '
  [.phases[]? | select(.id == $id)] | .[0].reviewerVerdict // "pending"
' "$FILE_PATH" 2>/dev/null || echo "pending")
PRIOR_STATUS=$("$JQ" -r --argjson id "$P_OLD" '
  [.phases[]? | select(.id == $id)] | .[0].status // "pending"
' "$FILE_PATH" 2>/dev/null || echo "pending")

if [ "$PRIOR_VERDICT" != "approved" ] && [ "$PRIOR_STATUS" != "skipped" ]; then
  emit_deny "[BLOCKED] onboarding-status.json write advances currentPhase ${P_OLD} → ${P_NEW}, but phase ${P_OLD} has not been reviewer-approved (reviewerVerdict=\"${PRIOR_VERDICT}\", status=\"${PRIOR_STATUS}\").

File: ${FILE_PATH}

Every phase transition — including Phases 1, 2, and 3 — must be gated by
a workflow-reviewer-phase${P_OLD}: subagent. The orchestrator does the
phase work; an approver subagent records the verdict; only then does
currentPhase advance. Writing currentPhase forward before the reviewer
runs is the 'orchestrator-direct then retroactively reviewer-walked'
deviation this gate exists to prevent.

Fix:
  1. Write the ledger with phase ${P_OLD} status=completed +
     handoverEnvelope, leaving currentPhase=${P_OLD}.
  2. Dispatch \`workflow-reviewer-phase${P_OLD}:\` — it inspects the
     deliverables and records reviewerVerdict=approved.
  3. Re-issue this write to advance currentPhase to ${P_OLD}+1.

See:
  - skills/onboarding/SKILL.md §\"Status ledger + workflow reviewer\"
  - skills/workflow-reviewer/SKILL.md
  - hooks/onboarding-ledger-gate.sh (the dispatch-side companion)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Multi-phase jump — every phase between P_OLD and P_NEW must be
# status:skipped in the proposed content (the skip itself is validated
# for an approvedDeviations[] entry by onboarding-ledger-write-gate.sh).
# ---------------------------------------------------------------------------
if [ "$P_NEW" -gt "$((P_OLD + 1))" ]; then
  # Re-derive the full proposed content for the skip check. For Write we
  # have it; for Edit we re-read the on-disk file (the jumped phases'
  # status lives outside the small new_string and is unchanged on disk).
  PROPOSED_DOC=""
  case "$TOOL_NAME" in
    Write) PROPOSED_DOC="$CONTENT" ;;
    Edit)  PROPOSED_DOC=$(cat "$FILE_PATH" 2>/dev/null || echo "") ;;
  esac
  for MID in $(seq $((P_OLD + 1)) $((P_NEW - 1))); do
    MID_STATUS=$(printf '%s' "$PROPOSED_DOC" | "$JQ" -r --argjson id "$MID" '
      [.phases[]? | select(.id == $id)] | .[0].status // "pending"
    ' 2>/dev/null || echo "pending")
    if [ "$MID_STATUS" != "skipped" ]; then
      emit_deny "[BLOCKED] onboarding-status.json write jumps currentPhase ${P_OLD} → ${P_NEW}, skipping phase ${MID} (status=\"${MID_STATUS}\").

File: ${FILE_PATH}

currentPhase must advance ONE phase at a time (${P_OLD} → ${P_OLD}+1),
each transition gated by its own workflow-reviewer-phaseN: subagent. A
phase may only be jumped when its status is \"skipped\" AND an
approvedDeviations[] entry authorises the skip.

Fix: advance currentPhase by exactly +1 per write. Run phase ${MID}
(and its reviewer) before reaching phase ${P_NEW}, OR mark phase ${MID}
status=skipped with an approvedDeviations[] entry carrying a verbatim
authorizer.

See:
  - skills/onboarding/SKILL.md §\"Status ledger + workflow reviewer\"
  - schemas/onboarding-status.schema.json"
      exit 0
    fi
  done
fi

exit 0
