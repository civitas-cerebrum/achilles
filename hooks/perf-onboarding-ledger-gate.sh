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
. "$(dirname "${BASH_SOURCE[0]}")/lib/pipeline-dispatch.sh"
hook_jq_init fatal

PIPELINE_KIND=perf
PIPELINE_CAP_PREFIX_RE="$DISPATCH_CAP_PREFIX_RE_PERF"
PIPELINE_MSG_LEDGER_NAME='perf-onboarding-status.json'
PIPELINE_MSG_SIDECAR_REL='tests/perf/docs/.ledger-integrity.json'
PIPELINE_MSG_LEDGER_REL="$LEDGER_PERF_REL"
PIPELINE_MSG_REVIEWER_LABEL='perf-reviewer-phase'
PIPELINE_MSG_SKILL_REF='skills/perf-onboarding/SKILL.md'
PIPELINE_MSG_SCHEMA_REF='schemas/perf-onboarding-status.schema.json'
PIPELINE_MSG_REVIEWER_SKILL='skills/workflow-reviewer/SKILL.md'

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
