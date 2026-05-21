#!/bin/bash
# group-size-cap-guard.sh — enforce the cap-7 journey limit on batched
#                           Agent dispatches.
#
# Hook    : PreToolUse:Agent
# Mode    : DENY (blocks the dispatch before the subagent starts)
# State   : reads tests/e2e/docs/onboarding-status.json (phase context only)
# Env     : none
#
# Why
# ---
# `coverage-expansion` permits two batched-dispatch shapes — the relevance
# `[group]` (compositional Passes 2-3 + adversarial Passes 4-5) and the
# `[P3-batch]` peripheral group — but BOTH are hard-capped at 7 journeys
# per brief. The cap exists because a batched composer/probe rations its
# attention across the journeys in the brief; past ~7, per-journey
# Test-expectation coverage degrades and Stage-B reviews trend toward
# `improvements-needed`.
#
# The cap is a markdown rule in `coverage-expansion/SKILL.md`
# (§"Relevance grouping" / §"Adversarial grouping for Passes 4 and 5" /
# §"Batched dispatch for P3 peripheral journeys"). Markdown rules are
# skippable under context pressure — an orchestrator under a token budget
# can rationalise "I'll consolidate all 15 into one [group] to save
# dispatches." A BookHive benchmark run (Run 10) did exactly that on
# Phase-5 Pass-5: one `[group]` of 15 journeys. This hook is the
# programmatic backstop the markdown rule lacked.
#
# What it gates
# -------------
# 1. Only Agent dispatches whose `description` begins (after optional
#    whitespace) with the literal marker `[group]` or `[P3-batch]`.
# 2. Counts the journeys named in the brief — the comma-separated
#    `composer-j-` / `composer-sj-` / `probe-j-` role tokens.
# 3. DENY when the count exceeds 7. The deny message names the count,
#    the ledger phase/sub-stage context, and the number of cap-7 groups
#    the dispatch should be split into.
# 4. Silent-allow everything else (non-Agent tools, un-marked single
#    dispatches, groups of 1-7).
#
# Canonical reference
# -------------------
# skills/coverage-expansion/SKILL.md §"Relevance grouping for compositional
#   passes", §"Adversarial grouping for Passes 4 and 5", §"Batched dispatch
#   for P3 peripheral journeys"
# skills/bug-discovery/SKILL.md  (Phase-6 element/flow probing reuses [group])
#
# Failure → action
# ----------------
# Group of >7 journeys             → DENY with the split-into-N-groups hint
# Malformed / non-Agent / <=7      → silent allow

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

# Only act on [group] / [P3-batch] marked dispatches — the marker is a
# role-prefix and sits at the start of the description.
if ! echo "$DESCRIPTION" | grep -qE '^[[:space:]]*\[(group|P3-batch)\]'; then
  exit 0
fi

MARKER=$(echo "$DESCRIPTION" | grep -oE '\[(group|P3-batch)\]' | head -1)

# Count the journeys named in the brief. Each batched item carries one of
# the leaf role prefixes — composer-j- / composer-sj- / probe-j-. One token
# == one journey.
COUNT=$(echo "$DESCRIPTION" | grep -oE '(composer-sj-|composer-j-|probe-j-)' | wc -l | tr -d ' ')
case "$COUNT" in ''|*[!0-9]*) COUNT=0 ;; esac

# A well-formed group of 1-7 journeys passes. Everything else is denied
# below: COUNT == 0 (malformed — marker present but no enumerated list,
# the evasion path where a 15-journey group hides its members in the
# prompt body) or COUNT > 7 (over the cap).
if [ "$COUNT" -ge 1 ] && [ "$COUNT" -le 7 ]; then
  exit 0
fi

# Pull phase context from the onboarding ledger — "within the context of
# the status ledger". Best-effort; absence is not an error.
GUARD_CWD=$(echo "$INPUT" | "$JQ" -r '.cwd // "."' 2>/dev/null || echo ".")
GUARD_REPO_ROOT=$(git -C "$GUARD_CWD" rev-parse --show-toplevel 2>/dev/null || echo "$GUARD_CWD")
LEDGER="$GUARD_REPO_ROOT/tests/e2e/docs/onboarding-status.json"
PHASE_CTX="no onboarding ledger found"
if [ -f "$LEDGER" ]; then
  CP=$("$JQ" -r '.currentPhase // "?"' "$LEDGER" 2>/dev/null || echo "?")
  CS=$("$JQ" -r '.currentSubStage // "null"' "$LEDGER" 2>/dev/null || echo "null")
  PHASE_CTX="currentPhase=${CP}, currentSubStage=${CS}"
fi

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

# COUNT == 0 — marker present, no journeys enumerated in the description.
# This closes the evasion path: a [group] whose member list lives only in
# the prompt body cannot be cap-counted, so a 15-journey group could slip
# through as a 0-journey group. A batched dispatch MUST enumerate its
# journeys in the description.
if [ "$COUNT" -eq 0 ]; then
  emit_deny "[BLOCKED] ${MARKER} dispatch does not enumerate any journeys in its description.

Description: \"${DESCRIPTION}\"
Ledger context: ${PHASE_CTX}

A \`[group]\` / \`[P3-batch]\` dispatch MUST list its journeys in the
description, comma-separated, after the marker — e.g.:
  [group] composer-j-search,composer-j-genre-filter,composer-j-add-to-cart:

The cap-7 audit counts the journeys named in the description. A batched
dispatch that hides its journey list in the prompt body defeats the
audit — a 15-journey group would pass as a 0-journey group. Enumerating
the members in the description is mandatory so the cap can be verified.

Fix: put the full comma-separated journey list in the dispatch
description.

See: skills/coverage-expansion/SKILL.md §\"Role prefixes\""
  exit 0
fi

# COUNT > 7 — over the cap.
GROUPS=$(( (COUNT + 6) / 7 ))

emit_deny "[BLOCKED] Batched ${MARKER} dispatch names ${COUNT} journeys — the cap is 7.

Description: \"${DESCRIPTION}\"
Ledger context: ${PHASE_CTX}

\`coverage-expansion\` hard-caps every batched dispatch (\`[group]\` and
\`[P3-batch]\`) at 7 journeys per brief. A batched composer/probe rations
its attention across the journeys in the brief; past 7 the per-journey
Test-expectation coverage degrades and Stage-B reviews trend toward
\`improvements-needed\`.

Fix: split this dispatch into ${GROUPS} priority-pure groups of <=7
journeys each, dispatched as ${GROUPS} parallel Agent calls in one
message. Groups must be priority-pure (no mixing P0/P1/P2/P3 in one
group). Example for a 15-journey tier: two groups of 7 + 8 → re-balance
to 8+7 is still over; use 7+7+1 or 5+5+5.

See:
  - skills/coverage-expansion/SKILL.md §\"Relevance grouping for compositional passes\"
  - skills/coverage-expansion/SKILL.md §\"Adversarial grouping for Passes 4 and 5\"
  - skills/coverage-expansion/SKILL.md §\"Batched dispatch for P3 peripheral journeys\""

exit 0
