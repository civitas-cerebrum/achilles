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

. "$(dirname "${BASH_SOURCE[0]}")/lib/hook-io.sh"
hook_lib pipeline-dispatch.sh
hook_jq_init fatal

pipeline_config perf
PIPELINE_CAP_PREFIX_RE="$DISPATCH_CAP_PREFIX_RE_PERF"

# perf_substage_check <current_phase> — in Phase 5 a load-run-<pass>-*
# dispatch waits for the approval of the pass before it in
# load → stress → spike → soak.
perf_substage_check() {
  local target prior="" pass
  [ "$1" = "5" ] || return 1
  target=$(echo "$DESCRIPTION" | sed -nE 's/^load-run-(load|stress|spike|soak)[_-].*/\1/p' | head -1)
  [ -n "$target" ] || return 1
  for pass in load stress spike soak; do
    [ "$pass" = "$target" ] && break
    prior="$pass"
  done
  [ -n "$prior" ] || return 1
  pipeline_substage_order_check 5 pass "$target" "$prior" "perf-reviewer-pass-${prior}:" \
    "every per-pass completion criterion from
skills/perf-onboarding/SKILL.md §\"Phase 5 — Load-run passes\"" \
    "skills/perf-onboarding/SKILL.md §\"Phase 5 — Load-run passes\""
}

pipeline_dispatch_main perf_substage_check
