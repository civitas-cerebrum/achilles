#!/bin/bash
# standard-mode-first-pass-guard.sh — first-pass / first-cycle strict-dispatch
#                                     enforcement for coverage-expansion +
#                                     journey-mapping.
# Size: the strict-dispatch rules of two pipelines (coverage-expansion, journey-mapping) with their ledger fallbacks.
#
# Hook    : PreToolUse:Agent
# Mode    : DENY (blocks the dispatch before the subagent starts)
# State   : reads (all under tests/e2e/docs/)
#             onboarding-status.json         workflow ledger: runMode, currentPhase,
#                                            currentSubStage (primary source, Rule 1)
#             coverage-expansion-state.json  runMode, currentPass (Rule 1 fallback
#                                            when no workflow ledger exists)
#             .phase4-cycle-state.json       cycle-1 sections, cycleStrictness
#                                            ("standard" default | "depth")
# Env     : none
#
# Rule 1 reads the workflow ledger rather than the coverage-expansion state file
# because the latter is deleted at Pass-5 cleanup, and a Phase-6 grouping
# question needs state that survives Phase 5. Under `runMode: standard` grouped
# dispatches are denied on Pass 1 only (currentPhase < 5, or phase 5 with
# sub-stage pass-1); under `depth` they are denied on every pass. Under
# `cycleStrictness: depth`, single-agent dispatches are denied on every cycle,
# not just cycle 1.
#
# Rules
# -----
# 1. Grouping forbidden (Pass-1 under standard, every pass under depth).
#    If the Agent description starts with `<role>-group-<id>:` /
#    `<role>-p3batch-<id>:` (or the legacy `[group]` / `[P3-batch]`) AND
#    EITHER:
#      (a) the coverage-expansion state file doesn't exist (implicit Pass 1
#          → DENY always), OR
#      (b) `currentPass == 1` (DENY always), OR
#      (c) `runMode == "depth"` (DENY regardless of currentPass)
#    DENY. Pass 1 of `mode: standard` is strict
#    per-journey by contract — grouped dispatches are only permitted on
#    Passes 2-5. Under `mode: depth` (strict on every pass) they
#    are forbidden on every pass.
#
# 2. Author-without-≥2-cycle-1-sections forbidden.
#    If the description starts with `phase4-prioritise-author:` AND
#    `.phase4-cycle-state.json` either doesn't exist OR cycle 1 contains
#    fewer than 2 distinct dispatched sections, DENY. The author may only
#    run after the strict per-section cycle-1 wave has produced its baseline.
#
# 3. Single-agent-collapse forbidden (cycle-1 under standard, every cycle
#    under depth).
#    If the description appears to be a single subagent attempting to walk
#    multiple sections sequentially (heuristic: description mentions ≥3
#    canonical section IDs joined with commas or "and"), AND EITHER:
#      (a) `.phase4-cycle-state.json` doesn't exist OR cycle 1 has zero
#          dispatched sections (cycle-1 collapse → DENY always), OR
#      (b) `cycleStrictness == "depth"` (DENY for ANY cycle — including
#          cycle 2+, even after cycle 1 has dispatched sections recorded)
#    DENY. This catches the failure mode where a single agent "walks" the
#    whole app and hides the parallelism the protocol was designed for.
#
# Under the standard defaults, rules 1 and 3 allow once the strict contract
# relaxes (Pass 2+, or cycle-1 sections recorded); under depth it never does.
#
# Empirical origin
# ----------------
# A benchmark onboarding run on a 21-journey app collapsed Phase 4 into one
# subagent (shallow per-section coverage), and Pass 1 grouping diluted
# test-expectations coverage. Strict-on-first-X keeps the high-fidelity moment
# without forbidding grouping on later passes / cycles where it pays.
#
# Canonical reference
# -------------------
# skills/coverage-expansion/SKILL.md §"Stage A per-journey dispatch is
#   non-negotiable" — first-pass strict rule
# skills/journey-mapping/SKILL.md §"Iterative discovery cycles" — first-cycle
#   strict rule
# schemas/subagent-returns/handover.schema.json — `dispatch-mode` enum
#
# Failure → action
# ----------------
# Pass-1 grouped dispatch         → DENY with fix-message pointing at the rule
# Cycle-1 author-without-≥2-sect.  → DENY with fix-message
# Cycle-1 single-agent collapse    → DENY with fix-message

# Intentional: `set -uo pipefail` without `-e`. The hook is input-tolerant by
# design — malformed stdin, missing state files, or jq extraction failures
# should silent-allow the dispatch rather than crash the PreToolUse pipeline.
set -uo pipefail

# Methodology pointers appended to every deny/warn message this hook
# can emit (repo convention: contributing-to-achilles-protocol/SKILL.md
# §"Hook error message format — repo standard").
printf -v HOOK_REFS -- "\n\nReferences:\n  skills/coverage-expansion/SKILL.md §\"Stage A per-journey dispatch is non-negotiable\"\n  skills/journey-mapping/SKILL.md §\"Iterative discovery cycles\""


# Resolve jq.
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/hook-io.sh"
hook_lib hook-emit.sh
hook_jq_init fatal

hook_read_input

# Session-scope gate: this hook applies only to achilles-activated
# sessions; plain dev sessions silent-allow (lib/achilles-activation.sh).
hook_lib achilles-activation.sh
achilles_require_active "$INPUT"
TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")

# Only act on Agent dispatches.
[ "$TOOL_NAME" = "Agent" ] || exit 0

DESCRIPTION=$(echo "$INPUT" | "$JQ" -r '.tool_input.description // ""' 2>/dev/null || echo "")
[ -n "$DESCRIPTION" ] || exit 0

# Resolve the cwd (where the state files live) — fall back to "." if absent.
GUARD_CWD=$(echo "$INPUT" | "$JQ" -r '.cwd // "."' 2>/dev/null || echo ".")
GUARD_REPO_ROOT=$(git -C "$GUARD_CWD" rev-parse --show-toplevel 2>/dev/null || echo "$GUARD_CWD")
hook_lib ledger.sh
WORKFLOW_LEDGER="$(ledger_path "$GUARD_REPO_ROOT" onboarding)"
COV_STATE="$GUARD_REPO_ROOT/tests/e2e/docs/coverage-expansion-state.json"
CYCLE_STATE="$GUARD_REPO_ROOT/tests/e2e/docs/.phase4-cycle-state.json"

# ---------------------------------------------------------------------------
# Rule 1: Grouping forbidden (Pass-1 under standard, every pass under depth)
# ---------------------------------------------------------------------------
if echo "$DESCRIPTION" | grep -qE "$DISPATCH_GROUPED_RE"; then
  # Primary source: the workflow ledger. Fallback: the coverage-expansion state
  # file. Neither present: implicitly Pass 1, mode standard.
  CURRENT_PASS=""
  RUN_MODE="standard"
  LEDGER_USED=""
  if [ -f "$WORKFLOW_LEDGER" ]; then
    LEDGER_USED="workflow"
    [ "$(ledger_get "$WORKFLOW_LEDGER" .runMode standard)" = depth ] && RUN_MODE="depth"
    CURRENT_PHASE=$(ledger_get "$WORKFLOW_LEDGER" .currentPhase 0)
    CURRENT_SUB_STAGE=$(ledger_get "$WORKFLOW_LEDGER" .currentSubStage)
    case "$CURRENT_PHASE" in
      ''|*[!0-9]*) CURRENT_PHASE=0 ;;
    esac
    # Map phase + sub-stage onto Rule 1's pass number: pre-Phase-5 is ""
    # (Pass-1-equivalent), Phase 5 is its pass, later phases are 6 (grouping ok).
    if [ "$CURRENT_PHASE" -lt 5 ]; then
      CURRENT_PASS=""
    elif [ "$CURRENT_PHASE" -eq 5 ]; then
      case "$CURRENT_SUB_STAGE" in
        pass-[2-5]) CURRENT_PASS="${CURRENT_SUB_STAGE#pass-}" ;;
        *)          CURRENT_PASS="1" ;;
      esac
    else
      CURRENT_PASS="6"
    fi
  elif [ -f "$COV_STATE" ]; then
    LEDGER_USED="coverage-expansion"
    CURRENT_PASS=$("$JQ" -r '.currentPass // empty' "$COV_STATE" 2>/dev/null || echo "")
    [ "$("$JQ" -r '.runMode // "standard"' "$COV_STATE" 2>/dev/null)" = depth ] && RUN_MODE="depth"
  fi
  # Depth denies on any pass; standard denies when currentPass is empty or 1.
  if [ "$RUN_MODE" = "depth" ]; then
    emit_pre_deny "[BLOCKED] Grouping forbidden on every pass under \`mode: depth\`.

Description: \"${DESCRIPTION}\"

\`mode: depth\` is the first-class strict-parallel-everywhere mode —
\`<role>-group-<id>:\` / \`<role>-p3batch-<id>:\` dispatches (and the legacy
\`[group]\` / \`[P3-batch]\` markers) are FORBIDDEN on every pass
(Passes 1, 2, 3, 4, AND 5), not just Pass 1. Under depth the cost is
explicit (up to ~20× more dispatches than \`mode: standard\`) and the
contract is exhaustive per-unit fidelity.

Fix: split this dispatch into N parallel single-journey dispatches in
one message (one \`test-composer-j-<slug>:\` or \`probe-j-<slug>:\` Agent
per journey, all sent in the same parallel wave). If grouping is
genuinely needed on this run, the operator must re-enter the onboarding
front-load gate and select \`runMode: standard\` instead.

See:
  - skills/coverage-expansion/SKILL.md §\"Depth mode — strict-parallel-everywhere\"
  - skills/achilles-protocol/references/harness-hooks.md (this hook indexed there)"
    exit 0
  fi
  if [ -z "$CURRENT_PASS" ] || [ "$CURRENT_PASS" = "1" ]; then
    emit_pre_deny "[BLOCKED] Pass-1 grouping forbidden under \`mode: standard\`.

Description: \"${DESCRIPTION}\"

Pass 1 of \`mode: standard\` (formerly \`mode: depth\`) is strict
per-journey by contract — \`<role>-group-<id>:\` / \`<role>-p3batch-<id>:\`
(and legacy \`[group]\` / \`[P3-batch]\`) dispatches are only permitted on Passes 2-5. The first pass establishes the test
foundation at maximum fidelity; that quality propagates through every
later pass.

Fix: split this dispatch into N parallel single-journey dispatches in
one message (one \`test-composer-j-<slug>:\` Agent per journey, all sent in
the same parallel wave). Re-issue any grouped
dispatches on Pass 2 or later, once Pass 1 has completed and the state
file shows \`currentPass >= 2\`.

See:
  - skills/coverage-expansion/SKILL.md §\"Stage A per-journey dispatch is non-negotiable\"
  - skills/achilles-protocol/references/harness-hooks.md (this hook indexed there)"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Rule 2: phase4-prioritise-author without ≥2 cycle-1 sections forbidden
# ---------------------------------------------------------------------------
if echo "$DESCRIPTION" | grep -qE '^[[:space:]]*phase4-prioritise-author:'; then
  CYCLE_1_COUNT=0
  if [ -f "$CYCLE_STATE" ]; then
    # Count distinct dispatched-sections in cycle 1.
    CYCLE_1_COUNT=$("$JQ" -r '
      (.cycles["1"]["dispatched-sections"] // []) | unique | length
    ' "$CYCLE_STATE" 2>/dev/null || echo "0")
    # Defensive: empty/non-numeric → 0.
    case "$CYCLE_1_COUNT" in
      ''|*[!0-9]*) CYCLE_1_COUNT=0 ;;
    esac
  fi
  if [ "$CYCLE_1_COUNT" -lt 2 ]; then
    emit_pre_deny "[BLOCKED] \`phase4-prioritise-author:\` dispatch denied — cycle 1 has not yet established the per-section baseline.

Description: \"${DESCRIPTION}\"

Journey-mapping cycle 1 (discovery) is strict per-section parallel in
EVERY mode (\`full\` and \`phases-2-4\`). The author may only run after
the strict cycle-1 wave has dispatched ≥ 2 distinct section subagents
and their returns have been recorded in
\`tests/e2e/docs/.phase4-cycle-state.json\`. Currently observed
cycle-1 dispatched-sections count: ${CYCLE_1_COUNT}.

Fix: dispatch \`phase4-cycle-1-section-<id>:\` subagents in one
parallel wave (one per target section from the discovery draft's
\`cycle-1-targets\`), wait for their returns to land in the state
file, then re-dispatch the author.

See:
  - skills/journey-mapping/SKILL.md §\"Iterative discovery cycles\"
  - skills/achilles-protocol/references/harness-hooks.md (this hook indexed there)"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Rule 3: Cycle-1 single-agent collapse forbidden
# ---------------------------------------------------------------------------
# Heuristic: a description naming >= 3 canonical section IDs joined with commas
# or "and" is one subagent walking cycle 1 sequentially.
#
# IDs come from hooks/data/canonical-sections.txt; fall back to a curated subset.
SECTIONS_DATA="$(dirname "${BASH_SOURCE[0]}")/data/canonical-sections.txt"
CANONICAL_SECTIONS=""
if [ -f "$SECTIONS_DATA" ]; then
  CANONICAL_SECTIONS=$(grep -vE '^[[:space:]]*(#|$)' "$SECTIONS_DATA" 2>/dev/null | tr '\n' ' ')
fi
# Fallback: skills/journey-mapping/SKILL.md §"Section vocabulary".
if [ -z "$CANONICAL_SECTIONS" ]; then
  CANONICAL_SECTIONS="auth profile admin catalog detail cart order billing marketplace content documentation dashboard settings integrations notifications inbox support reports analytics error"
fi

# Count distinct canonical section IDs mentioned, as whole words ("authentication"
# must not match "auth"). Journey slugs (j-<slug> / sj-<slug>) are stripped first:
# a coordinator listing "j-auth, j-cart, j-order" is not a section walkthrough.
# Commas and "and" become whitespace so "auth, cart, and order" tokenises.
TOKENS=$(echo "$DESCRIPTION" | sed -E 's/\b(s?j-[a-z0-9-]+)//g; s/[,]/ /g; s/[[:space:]]+and[[:space:]]+/ /g' | tr -s ' ')
HIT_COUNT=0
HIT_NAMES=""
for sec in $CANONICAL_SECTIONS; do
  if echo "$TOKENS" | grep -qiwE "$sec"; then
    HIT_COUNT=$((HIT_COUNT + 1))
    HIT_NAMES="${HIT_NAMES}${sec} "
  fi
done

if [ "$HIT_COUNT" -ge 3 ]; then
  # Rule 3 is a Phase-4 rule: a Phase-5 coordinator or Phase-8 reporter naming
  # several sections is not a cycle collapse. In scope when currentPhase==4, or
  # with no ledger when the description is phase4-shaped (bare journey-mapping).
  RULE3_IN_SCOPE=0
  if [ -f "$WORKFLOW_LEDGER" ]; then
    R3_PHASE=$(ledger_get "$WORKFLOW_LEDGER" .currentPhase 0)
    case "$R3_PHASE" in ''|*[!0-9]*) R3_PHASE=0 ;; esac
    [ "$R3_PHASE" -eq 4 ] && RULE3_IN_SCOPE=1
  else
    # No ledger: only phase4-shaped dispatches are in scope.
    [ "$(dispatch_phase_number onboarding "$DESCRIPTION")" = 4 ] && RULE3_IN_SCOPE=1
  fi
  if [ "$RULE3_IN_SCOPE" != "1" ]; then
    exit 0
  fi

  # Read cycle state: dispatched-sections count + cycleStrictness.
  CYCLE_1_DISPATCHED=0
  CYCLE_STRICTNESS="standard"
  if [ -f "$CYCLE_STATE" ]; then
    CYCLE_1_DISPATCHED=$("$JQ" -r '
      (.cycles["1"]["dispatched-sections"] // []) | length
    ' "$CYCLE_STATE" 2>/dev/null || echo "0")
    case "$CYCLE_1_DISPATCHED" in
      ''|*[!0-9]*) CYCLE_1_DISPATCHED=0 ;;
    esac
    [ "$("$JQ" -r '.cycleStrictness // "standard"' "$CYCLE_STATE" 2>/dev/null)" = depth ] && CYCLE_STRICTNESS="depth"
  fi
  # Walkthrough attempts only: author / validator briefs may name many sections.
  # depth denies on any cycle; standard only while no cycle-1 dispatch exists.
  if ! is_multi_section_consumer "$DESCRIPTION"; then
      if [ "$CYCLE_STRICTNESS" = "depth" ]; then
        emit_pre_deny "[BLOCKED] Single-subagent walkthrough forbidden on every cycle under \`cycleStrictness: depth\`.

Description: \"${DESCRIPTION}\"

Detected canonical section IDs in the brief: ${HIT_NAMES}(${HIT_COUNT})

Under \`cycleStrictness: depth\` (selected via onboarding's
\`runMode: depth\` front-load gate), every cycle — cycle 1 AND every
later cycle (edge-probe and any additional discovery cycles) — is
strict per-section parallel. A single subagent attempting to walk ≥ 3
sections in one dispatch is the failure mode the protocol exists to
prevent, and the strict contract does not relax after cycle 1 under
depth.

Fix: split this dispatch into N parallel
\`phase4-cycle-<N>-section-<id>:\` subagents in one message (one Agent
per target section). If single-agent cycle-2+ dispatches are genuinely
acceptable for this run, the operator must re-enter the onboarding
front-load gate and select \`runMode: standard\` instead.

See:
  - skills/journey-mapping/SKILL.md §\"First-cycle strict / later-cycle relaxed\" — every-cycle-strict counterpart under depth
  - skills/achilles-protocol/references/harness-hooks.md (this hook indexed there)"
        exit 0
      fi
      if [ "$CYCLE_1_DISPATCHED" -eq 0 ]; then
        emit_pre_deny "[BLOCKED] Single-subagent walkthrough of journey-mapping cycle 1 forbidden.

Description: \"${DESCRIPTION}\"

Detected canonical section IDs in the brief: ${HIT_NAMES}(${HIT_COUNT})

Journey-mapping cycle 1 (discovery) is strict per-section parallel in
EVERY mode. A single subagent attempting to walk ≥ 3 sections in one
dispatch is the failure mode the protocol exists to prevent — it
produces shallow per-section coverage and hides the parallelism the
skill was designed for.

Fix: split this dispatch into N parallel \`phase4-cycle-1-section-<id>:\`
subagents in one message (one Agent per target section). After the
strict cycle-1 wave returns, cycle 2+ (edge-probe / additional
discovery) may use a single subagent if the orchestrator chooses —
the strict contract relaxes from cycle 2 onward (under
\`cycleStrictness: standard\`; depth keeps the strict contract on every
cycle).

See:
  - skills/journey-mapping/SKILL.md §\"Iterative discovery cycles\"
  - skills/achilles-protocol/references/harness-hooks.md (this hook indexed there)"
        exit 0
      fi
  fi
fi

# All checks passed — silent allow.
exit 0
