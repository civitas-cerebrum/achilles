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

. "$(dirname "${BASH_SOURCE[0]}")/lib/hook-io.sh"
hook_lib pipeline-dispatch.sh
hook_jq_init fatal

pipeline_config onboarding
PIPELINE_CAP_PREFIX_RE="$DISPATCH_CAP_PREFIX_RE_ONBOARDING"

# onboarding_substage_check <current_phase> — a Phase-5 composer / probe
# dispatch for pass N, or a Phase-4 phase4-cycle-<N>-* dispatch, waits for
# the approval of pass / cycle N-1.
onboarding_substage_check() {
  local target
  case "$1" in
    5)
      target=$(echo "$DESCRIPTION" | grep -oE "$DISPATCH_PHASE5_PASS_RE" | grep -oE '[1-5]$' | head -1 || true)
      [ -n "$target" ] && [ "$target" -ge 2 ] || return 1
      pipeline_substage_order_check 5 pass "$target" "$((target - 1))" "workflow-reviewer-pass$((target - 1)):" \
        "every per-pass completion criterion from
skills/coverage-expansion/SKILL.md §\"Per-pass completion criteria\"" \
        "skills/coverage-expansion/SKILL.md §\"Authoritative state file\""
      ;;
    4)
      target=$(echo "$DESCRIPTION" | sed -nE 's/.*phase4-cycle-([1-5])-.*/\1/p' | head -1)
      [ -n "$target" ] && [ "$target" -ge 2 ] || return 1
      pipeline_substage_order_check 4 cycle "$target" "$((target - 1))" "workflow-reviewer-cycle$((target - 1)):" \
        "the iterative-discovery-cycle criteria from
skills/journey-mapping/SKILL.md §\"Iterative discovery cycles\"" \
        "skills/journey-mapping/SKILL.md"
      ;;
  esac
}

pipeline_dispatch_main onboarding_substage_check
