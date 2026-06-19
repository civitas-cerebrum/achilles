#!/bin/bash
# onboarding-ledger-gate.sh — pipeline-state-machine gate for the onboarding
#                             workflow. Forces a workflow-reviewer-*
#                             dispatch at every phase / pass / cycle
#                             transition and blocks out-of-order phase
#                             advancement.
#
# Hook    : PreToolUse:Agent
# Mode    : DENY (blocks the dispatch before the subagent starts)
# State   : reads tests/e2e/docs/onboarding-status.json
# Env     : none
#
# Why
# ---
# Markdown-text contract enforcement permits silent scope compression even
# when the methodology rules are crisp. An empirical 21-journey benchmark
# onboarding run demonstrated the orchestrator skipping phases entirely,
# stopping early, and accepting subagent returns whose declared "complete"
# status omitted required sub-deliverables. The status ledger + workflow-
# reviewer subagent family are the contract layer; this hook is their
# enforcement.
#
# What it gates
# -------------
# 1. **No phase N+1 dispatch without reviewer-approved phase N.** If the
#    ledger shows currentPhase = N + 1 (or a dispatch description names a
#    later phase) and phase N's `reviewerVerdict` is not `approved`, DENY.
# 2. **No pass-N+1 (Phase-5) or cycle-N+1 (Phase-4) dispatch without
#    reviewer-approved pass-N / cycle-N.** Same logic at the substage level.
# 3. **Force the workflow-reviewer dispatch at transition points.** If the
#    last completed phase's `reviewerVerdict` is `pending` AND the
#    incoming Agent's role prefix is NOT `workflow-reviewer-*`, DENY.
#    The orchestrator must dispatch the matching `workflow-reviewer-*`
#    subagent FIRST.
# 4. **Always allow `workflow-reviewer-*` dispatches** — those don't gate
#    themselves, and they may fire even with a pending ledger row.
# 5. **Silent-allow when the ledger is absent or malformed.** A brand-new
#    onboarding run starts before any ledger exists; the hook must not
#    block Phase 1 from beginning.
#
# Role prefix → phase / pass / cycle mapping
# ------------------------------------------
# The hook reads the Agent description and extracts which phase / pass /
# cycle the dispatch is targeting. The matching is heuristic and tolerant:
# only dispatches whose target can be confidently identified are gated.
# Free-form prefixes that don't carry a phase / pass / cycle hint
# silent-allow.
#
# Canonical reference
# -------------------
# schemas/onboarding-status.schema.json     — ledger shape
# schemas/subagent-returns/workflow-reviewer.schema.json — reviewer return
# skills/onboarding/SKILL.md §"Status ledger + workflow reviewer"
# skills/workflow-reviewer/SKILL.md         — reviewer methodology
#
# Failure → action
# ----------------
# Out-of-order phase dispatch         → DENY with the missing reviewer hint
# Non-reviewer at transition point    → DENY naming the reviewer prefix
# Workflow-reviewer-*                 → ALWAYS allow
# Malformed / missing ledger          → silent allow

# Intentional: `set -uo pipefail` without `-e`. Input-tolerant by design.
set -uo pipefail

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
if [ -z "$JQ" ]; then
  echo "[$(basename "${BASH_SOURCE[0]}")] FATAL: jq not found at \$HOOK_DIR/bin/jq nor on PATH." >&2
  exit 1
fi

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")

# Only act on Agent dispatches.
[ "$TOOL_NAME" = "Agent" ] || exit 0

DESCRIPTION=$(echo "$INPUT" | "$JQ" -r '.tool_input.description // ""' 2>/dev/null || echo "")
[ -n "$DESCRIPTION" ] || exit 0

# Helper: emit a DENY payload with the supplied reason.
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

# Rule 4 (allow-list): approver-role dispatches (workflow-reviewer-* /
# phase-validator-*) always pass. Detection lives in lib/reviewer-prefix.sh
# — the same helper the approver registry uses, so the allow-list can never
# drift from the set of scopes the registry accepts.
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/reviewer-prefix.sh"

# Resolve repo root + ledger path (needed for the reviewerCycles cap check
# on reviewer dispatches, below).
GUARD_CWD=$(echo "$INPUT" | "$JQ" -r '.cwd // "."' 2>/dev/null || echo ".")
GUARD_REPO_ROOT=$(git -C "$GUARD_CWD" rev-parse --show-toplevel 2>/dev/null || echo "$GUARD_CWD")
LEDGER="$GUARD_REPO_ROOT/tests/e2e/docs/onboarding-status.json"
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/hash.sh"
SIDECAR="$(dirname "$LEDGER")/.ledger-integrity.json"
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/pipeline-gate.sh"
PIPELINE_LEDGER="$LEDGER"
PIPELINE_SIDECAR="$SIDECAR"
PIPELINE_CAP_PREFIX_RE='s/^(workflow-reviewer-phase|phase-validator-)([0-9]+).*/\2/p'
PIPELINE_MSG_LEDGER_NAME='onboarding-status.json'
PIPELINE_MSG_SIDECAR_REL='tests/e2e/docs/.ledger-integrity.json'
PIPELINE_MSG_LEDGER_REL='tests/e2e/docs/onboarding-status.json'
PIPELINE_MSG_REVIEWER_LABEL='workflow-reviewer-phase'
PIPELINE_MSG_SKILL_REF='skills/onboarding/SKILL.md'
PIPELINE_MSG_SCHEMA_REF='schemas/onboarding-status.schema.json'
PIPELINE_MSG_REVIEWER_SKILL='skills/workflow-reviewer/SKILL.md'

if is_reviewer_description "$DESCRIPTION"; then
  # Rule 4 normally always-allows reviewer dispatches. EXCEPTION (change
  # #8b): a reviewer dispatch targeting a phase whose reviewerCycles is
  # already >= 3 without an escalated verdict is denied — the reject cap is
  # 3 rounds; a 4th review round means the cap was meant to escalate and
  # didn't. Parse the target phase from the description (workflow-reviewer-
  # phase<N>: / phase-validator-<N>:) and check the ledger.
  pipeline_reviewer_cap_check "$DESCRIPTION" && exit 0
  exit 0
fi

# Rule 5 + integrity verify: missing-ledger guard and hash-chain check.
pipeline_ledger_integrity_check
_lic_ret=$?
[ "$_lic_ret" -eq 0 ] && exit 0
[ "$_lic_ret" -eq 1 ] && exit 0

# Probe the ledger. Any extraction failure → silent allow (malformed
# ledger should not jam the pipeline; the write-gate is responsible for
# ledger integrity).
SCHEMA_VERSION=$("$JQ" -r '.schemaVersion // empty' "$LEDGER" 2>/dev/null || echo "")
[ -n "$SCHEMA_VERSION" ] || exit 0

CURRENT_PHASE=$("$JQ" -r '.currentPhase // empty' "$LEDGER" 2>/dev/null || echo "")
case "$CURRENT_PHASE" in
  ''|*[!0-9]*) exit 0 ;;
esac

# ---------------------------------------------------------------------------
# Rule 3: transition-point enforcement (lib call).
# ---------------------------------------------------------------------------
pipeline_transition_point_check "$DESCRIPTION" && exit 0

# ---------------------------------------------------------------------------
# Rule 1 & 2: out-of-order phase / pass / cycle dispatch (lib call).
# Onboarding-specific target-phase inference; the generic rule lives in lib.
# ---------------------------------------------------------------------------
# Patterns observed:
#   phase<N>-*           → target N
#   secrets-sweep-*      → Phase 7
#   work-summary-deck-*  → Phase 8
onboarding_infer_target_phase() {
  local DESC="$1"
  case "$DESC" in
    phase1-*|phase1_*) echo 1 ;;
    phase2-*|phase2_*) echo 2 ;;
    phase3-*|phase3_*) echo 3 ;;
    phase4-*|phase4_*) echo 4 ;;
    phase5-*|phase5_*) echo 5 ;;
    phase6-*|phase6_*) echo 6 ;;
    phase7-*|phase7_*) echo 7 ;;
    phase8-*|phase8_*) echo 8 ;;
    secrets-sweep-*|secrets_sweep-*) echo 7 ;;
    work-summary-deck-*|qa-summary-*) echo 8 ;;
  esac
}
pipeline_out_of_order_phase_check "$DESCRIPTION" "$CURRENT_PHASE" onboarding_infer_target_phase && exit 0

# ---------------------------------------------------------------------------
# Sub-stage gate (Phase 4 cycles + Phase 5 passes).
# If the description targets a specific pass-N or cycle-N within the
# current phase, check the prior substage's reviewerVerdict.
# ---------------------------------------------------------------------------
# Phase 5 — composer-j-<slug>-<pass>-<...> or probe-j-<slug>-<pass>-<...>
#   when currentPhase = 5. We only block when the pass number is
#   strictly greater than the highest-substage's pass and that prior
#   pass is unapproved.
TARGET_PASS=""
if [ "$CURRENT_PHASE" = "5" ]; then
  TARGET_PASS=$(echo "$DESCRIPTION" | grep -oE '(composer|probe)-j-[a-z0-9-]+-[1-5]' | grep -oE '[1-5]$' | head -1 || true)
fi
if [ -n "$TARGET_PASS" ]; then
  PRIOR_PASS=$((TARGET_PASS - 1))
  if [ "$PRIOR_PASS" -ge 1 ]; then
    PRIOR_PASS_ID="pass-${PRIOR_PASS}"
    PRIOR_PASS_VERDICT=$("$JQ" -r --arg id "$PRIOR_PASS_ID" '
      [.phases[]? | select(.id == 5) | .subStages[]? | select(.id == $id)] |
      .[0].reviewerVerdict // "pending"
    ' "$LEDGER" 2>/dev/null || echo "pending")
    if [ "$PRIOR_PASS_VERDICT" != "approved" ]; then
      emit_deny "[BLOCKED] Out-of-order Phase-5 pass dispatch — pass-${TARGET_PASS} cannot start while pass-${PRIOR_PASS} is not reviewer-approved.

Description: \"${DESCRIPTION}\"

Ledger shows pass-${PRIOR_PASS}.reviewerVerdict = \"${PRIOR_PASS_VERDICT}\"
(must be \"approved\").

Fix: dispatch \`workflow-reviewer-pass${PRIOR_PASS}:\` first. The
reviewer checks every per-pass completion criterion from
skills/coverage-expansion/SKILL.md §\"Per-pass completion criteria\".

See:
  - skills/coverage-expansion/SKILL.md §\"Authoritative state file\"
  - skills/workflow-reviewer/SKILL.md
  - schemas/onboarding-status.schema.json"
      exit 0
    fi
  fi
fi

# Phase 4 — phase4-cycle-<N>-section-<id>: when currentPhase = 4.
TARGET_CYCLE=""
if [ "$CURRENT_PHASE" = "4" ]; then
  TARGET_CYCLE=$(echo "$DESCRIPTION" | sed -nE 's/.*phase4-cycle-([1-5])-.*/\1/p' | head -1)
fi
if [ -n "$TARGET_CYCLE" ]; then
  PRIOR_CYCLE=$((TARGET_CYCLE - 1))
  if [ "$PRIOR_CYCLE" -ge 1 ]; then
    PRIOR_CYCLE_ID="cycle-${PRIOR_CYCLE}"
    PRIOR_CYCLE_VERDICT=$("$JQ" -r --arg id "$PRIOR_CYCLE_ID" '
      [.phases[]? | select(.id == 4) | .subStages[]? | select(.id == $id)] |
      .[0].reviewerVerdict // "pending"
    ' "$LEDGER" 2>/dev/null || echo "pending")
    if [ "$PRIOR_CYCLE_VERDICT" != "approved" ]; then
      emit_deny "[BLOCKED] Out-of-order Phase-4 cycle dispatch — cycle-${TARGET_CYCLE} cannot start while cycle-${PRIOR_CYCLE} is not reviewer-approved.

Description: \"${DESCRIPTION}\"

Ledger shows cycle-${PRIOR_CYCLE}.reviewerVerdict = \"${PRIOR_CYCLE_VERDICT}\"
(must be \"approved\").

Fix: dispatch \`workflow-reviewer-cycle${PRIOR_CYCLE}:\` first. The
reviewer checks the iterative-discovery-cycle criteria from
skills/journey-mapping/SKILL.md §\"Iterative discovery cycles\".

See:
  - skills/journey-mapping/SKILL.md
  - skills/workflow-reviewer/SKILL.md
  - schemas/onboarding-status.schema.json"
      exit 0
    fi
  fi
fi

# All checks passed — silent allow.
exit 0
