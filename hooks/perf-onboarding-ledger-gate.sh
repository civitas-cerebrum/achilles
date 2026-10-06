#!/bin/bash
# perf-onboarding-ledger-gate.sh — pipeline-state-machine gate for the
#                                  perf-onboarding workflow. Forces a
#                                  perf-reviewer-* dispatch at every phase
#                                  / pass transition and blocks out-of-order
#                                  phase advancement.
#
# Hook    : PreToolUse:Agent
# Mode    : DENY (blocks the dispatch before the subagent starts)
# State   : reads tests/perf/docs/perf-onboarding-status.json
# Env     : none
#
# Why
# ---
# The perf-onboarding pipeline has the same phase-gate requirement as the
# main onboarding pipeline: every phase transition requires an approved
# perf-reviewer-* subagent before the next phase may start. Additionally,
# Phase 5 (Load-run) has four named passes (load → stress → spike → soak)
# each of which requires prior-pass reviewer approval.
#
# What it gates
# -------------
# 1. **No phase N+1 dispatch without reviewer-approved phase N.**
# 2. **No next-pass dispatch while prior pass is unapproved** (Phase-5).
# 3. **Force the perf-reviewer-* dispatch at transition points.**
# 4. **Always allow perf-reviewer-* dispatches** (subject to the 3-cycle cap).
# 5. **Silent-allow when the ledger is absent or malformed.**
#
# Canonical reference
# -------------------
# schemas/perf-onboarding-status.schema.json  — ledger shape
# skills/perf-onboarding/SKILL.md             — orchestrator skill
# skills/workflow-reviewer/SKILL.md           — reviewer methodology
#
# Failure → action
# ----------------
# Out-of-order phase dispatch       → DENY with the missing reviewer hint
# Non-reviewer at transition point  → DENY naming the reviewer prefix
# perf-reviewer-*                   → ALWAYS allow (subject to cap)
# Malformed / missing ledger        → silent allow

# Intentional: `set -uo pipefail` without `-e`. Input-tolerant by design.
set -uo pipefail

# Methodology pointers appended to every deny/warn message this hook
# can emit (repo convention: contributing-to-achilles-protocol/SKILL.md
# §"Hook error message format — repo standard").
printf -v HOOK_REFS -- "\n\nReferences:\n  skills/perf-onboarding/SKILL.md\n  skills/workflow-reviewer/SKILL.md\n  schemas/perf-onboarding-status.schema.json"


# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/hook-io.sh"
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/hook-emit.sh"
hook_jq_init fatal

hook_read_input

# Session-scope gate: this hook applies only to achilles-activated
# sessions; plain dev sessions silent-allow (lib/achilles-activation.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/achilles-activation.sh"
achilles_require_active "$INPUT"
TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")

# Only act on Agent dispatches.
[ "$TOOL_NAME" = "Agent" ] || exit 0

DESCRIPTION=$(echo "$INPUT" | "$JQ" -r '.tool_input.description // ""' 2>/dev/null || echo "")
[ -n "$DESCRIPTION" ] || exit 0

# Helper: emit a DENY payload with the supplied reason.

# Resolve repo root + ledger path.
GUARD_CWD=$(echo "$INPUT" | "$JQ" -r '.cwd // "."' 2>/dev/null || echo ".")
GUARD_REPO_ROOT=$(git -C "$GUARD_CWD" rev-parse --show-toplevel 2>/dev/null || echo "$GUARD_CWD")
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/ledger.sh"
LEDGER="$(ledger_path "$GUARD_REPO_ROOT" perf)"
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/hash.sh"
SIDECAR="$(dirname "$LEDGER")/.ledger-integrity.json"
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/pipeline-gate.sh"
PIPELINE_KIND=perf
PIPELINE_LEDGER="$LEDGER"
PIPELINE_SIDECAR="$SIDECAR"
PIPELINE_CAP_PREFIX_RE="$DISPATCH_CAP_PREFIX_RE_PERF"
PIPELINE_MSG_LEDGER_NAME='perf-onboarding-status.json'
PIPELINE_MSG_SIDECAR_REL='tests/perf/docs/.ledger-integrity.json'
PIPELINE_MSG_LEDGER_REL="$LEDGER_PERF_REL"
PIPELINE_MSG_REVIEWER_LABEL='perf-reviewer-phase'
PIPELINE_MSG_SKILL_REF='skills/perf-onboarding/SKILL.md'
PIPELINE_MSG_SCHEMA_REF='schemas/perf-onboarding-status.schema.json'
PIPELINE_MSG_REVIEWER_SKILL='skills/workflow-reviewer/SKILL.md'

if is_reviewer_description "$DESCRIPTION"; then
  # Rule 4: perf-reviewer-* dispatches always-allow subject to the 3-cycle cap.
  pipeline_reviewer_cap_check "$DESCRIPTION" && exit 0
  exit 0
fi

# Rule 5 + integrity verify: missing-ledger guard and hash-chain check.
pipeline_ledger_integrity_check
_lic_ret=$?
[ "$_lic_ret" -eq 0 ] && exit 0
[ "$_lic_ret" -eq 1 ] && exit 0

# Probe the ledger. Any extraction failure → silent allow.
SCHEMA_VERSION=$(ledger_get "$LEDGER" .schemaVersion)
[ -n "$SCHEMA_VERSION" ] || exit 0

CURRENT_PHASE=$(ledger_get "$LEDGER" .currentPhase)
case "$CURRENT_PHASE" in
  ''|*[!0-9]*) exit 0 ;;
esac

# ---------------------------------------------------------------------------
# Rule 3: transition-point enforcement (lib call).
# ---------------------------------------------------------------------------
pipeline_transition_point_check "$DESCRIPTION" && exit 0

# ---------------------------------------------------------------------------
# Rules 1 & 2: out-of-order phase dispatch (lib call).
# ---------------------------------------------------------------------------
pipeline_out_of_order_phase_check "$DESCRIPTION" "$CURRENT_PHASE" && exit 0

# ---------------------------------------------------------------------------
# Phase-5 sub-stage gate: pass ordering (load → stress → spike → soak).
# When currentPhase = 5, a dispatch targeting load-run-<pass>-* must not
# start while the prior pass's reviewerVerdict is not approved.
# ---------------------------------------------------------------------------
# Named pass order array (bash 3-compatible positional approach).
PASS_ORDER="load stress spike soak"
TARGET_PASS_NAME=""
if [ "$CURRENT_PHASE" = "5" ]; then
  # Extract the pass name from descriptions like: load-run-stress-*, load-run-spike-*, etc.
  TARGET_PASS_NAME=$(echo "$DESCRIPTION" | sed -nE 's/^load-run-(load|stress|spike|soak)[_-].*/\1/p' | head -1)
fi

if [ -n "$TARGET_PASS_NAME" ]; then
  # Find the prior pass name by looking up the pass order.
  PRIOR_PASS_NAME=""
  PREV=""
  for PASS in $PASS_ORDER; do
    if [ "$PASS" = "$TARGET_PASS_NAME" ]; then
      PRIOR_PASS_NAME="$PREV"
      break
    fi
    PREV="$PASS"
  done

  if [ -n "$PRIOR_PASS_NAME" ]; then
    PRIOR_PASS_ID="pass-${PRIOR_PASS_NAME}"
    PRIOR_PASS_VERDICT=$("$JQ" -r --arg id "$PRIOR_PASS_ID" '
      [.phases[]? | select(.id == 5) | .subStages[]? | select(.id == $id)] |
      .[0].reviewerVerdict // "pending"
    ' "$LEDGER" 2>/dev/null || echo "pending")
    if [ "$PRIOR_PASS_VERDICT" != "approved" ]; then
      emit_pre_deny "[BLOCKED] Out-of-order Phase-5 pass dispatch — pass-${TARGET_PASS_NAME} cannot start while pass-${PRIOR_PASS_NAME} is not reviewer-approved.

Description: \"${DESCRIPTION}\"

Ledger shows pass-${PRIOR_PASS_NAME}.reviewerVerdict = \"${PRIOR_PASS_VERDICT}\"
(must be \"approved\").

Fix: dispatch \`perf-reviewer-pass-${PRIOR_PASS_NAME}:\` first. The
reviewer checks every per-pass completion criterion from
skills/perf-onboarding/SKILL.md §\"Phase 5 — Load-run passes\".

See:
  - skills/perf-onboarding/SKILL.md §\"Phase 5 — Load-run passes\"
  - skills/workflow-reviewer/SKILL.md
  - schemas/perf-onboarding-status.schema.json"
      exit 0
    fi
  fi
fi

# All checks passed — silent allow.
exit 0
