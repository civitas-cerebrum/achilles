#!/bin/bash
# process-validator-checkpoint-gate.sh — make the coverage-expansion
#   process-validator a NON-SKIPPABLE, CONTENT-BOUND workflow checkpoint.
#
# Hook    : PreToolUse:Agent  AND  PostToolUse:Agent  (one file, two events)
# Mode    : DENY (PreToolUse) / record (PostToolUse)
# State   : reads tests/e2e/docs/onboarding-status.json
#           reads+writes tests/e2e/docs/.process-validator-greenlights.json
# Env     : none
#
# Why — this is a WORKFLOW fix, not a literal-exploit patch
# --------------------------------------------------------
# The Phase-5 (coverage-expansion) wave-shaping deviations — an over-cap
# `[group]`, unmarked batching, journey-skipping, pass-skipping — are all
# the same workflow weakness: the orchestrator shapes every dispatch wave
# unilaterally, under budget pressure, with no enforced review of the
# PLAN before the wave fires.
#
# `coverage-expansion` already defines the right mechanism — the
# `process-validator-<scope>:` sub-orchestrator reviews the planned
# dispatch manifest and returns greenlight / improvements-needed. The
# only defect was that nothing FORCED the orchestrator to dispatch it.
#
# Manifest-binding (the second half of the fix)
# ---------------------------------------------
# A process-validator reviews a MANIFEST — a declared table of the
# planned wave. coverage-expansion §5 says "no edits between greenlight
# and dispatch", but that link was an honor-rule: a greenlight keyed
# only by pass-scope certifies "a plan was reviewed", not "THIS dispatch
# matches the reviewed plan". An orchestrator could be greenlit on a
# clean 7+7+1 manifest and then dispatch a single group of 21.
#
# So the greenlight is bound to its CONTENT: the PostToolUse half parses
# the set of journey ids from the manifest the validator was given (its
# input prompt) and records that set. The PreToolUse half then checks
# that every journey in an actual composer/probe dispatch is inside the
# greenlit set. A dispatch that covers a journey the validator never saw
# is denied as manifest divergence — the §5 "no edits" rule is now
# enforced, not honour-system.
#
# How it works
# ------------
# PostToolUse:Agent — when a `process-validator-*` subagent returns
#   `status: greenlight`, record { ts, validator, journeys[] } for the
#   current pass scope (`<currentPhase>:<currentSubStage>`). `journeys[]`
#   is the journey-id set extracted from the validator's input manifest.
#
# PreToolUse:Agent — a Phase-5 composer/probe wave dispatch
#   (`composer-j-` / `composer-sj-` / `probe-j-`, incl. `[group]` /
#   `[P3-batch]`) requires (a) a fresh greenlight for the current pass
#   scope, AND (b) every journey it covers to be inside that greenlight's
#   recorded journey set. Either miss → DENY.
#
# Scope: gated to Phase 5 (coverage-expansion) and Phase 6 (bug-discovery)
# — both fan out per-journey composer/probe waves and share the [group] /
# cap-7 dispatch mechanics. Phase-4 cycle waves have their own cycle-state
# machine and are not gated here. A Phase-6 synthesizer/triage dispatch
# (no composer-j-/probe-j- token) is not a wave and is not gated.
#
# Companion (defense-in-depth, different error-space):
#   group-size-cap-guard.sh — deterministic cap-7 check on the actual
#   dispatch; has no blind spot correlated with an LLM validator.
#
# Canonical reference
# -------------------
# skills/coverage-expansion/SKILL.md §"Recursive dispatch is impossible — plan, don't fan out"
# skills/coverage-expansion/references/process-validator-workflow.md §2 (manifest), §5 (no edits)
#
# Failure → action
# ----------------
# Phase-5 wave, no greenlight for the pass scope        → DENY
# Phase-5 wave, covers a journey not in the greenlight  → DENY (divergence)
# Everything else                                       → silent allow

set -uo pipefail

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
if [ -z "$JQ" ]; then
  echo "[$(basename "${BASH_SOURCE[0]}")] FATAL: jq not found at \$HOOK_DIR/bin/jq nor on PATH." >&2
  exit 1
fi

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")
[ "$TOOL_NAME" = "Agent" ] || exit 0

EVENT_NAME=$(echo "$INPUT" | "$JQ" -r '.hook_event_name // empty' 2>/dev/null || echo "")
DESCRIPTION=$(echo "$INPUT" | "$JQ" -r '.tool_input.description // ""' 2>/dev/null || echo "")

GUARD_CWD=$(echo "$INPUT" | "$JQ" -r '.cwd // "."' 2>/dev/null || echo ".")
GUARD_REPO_ROOT=$(git -C "$GUARD_CWD" rev-parse --show-toplevel 2>/dev/null || echo "$GUARD_CWD")
LEDGER="$GUARD_REPO_ROOT/tests/e2e/docs/onboarding-status.json"
DOCS_DIR="$GUARD_REPO_ROOT/tests/e2e/docs"
REGISTRY="$DOCS_DIR/.process-validator-greenlights.json"

TTL_SECONDS=14400   # 4h — the scope key is the real invalidation; TTL
                    # only guards cross-run bleed.

# Extract the set of journey ids (j-<slug> / sj-<slug>) referenced in a
# blob of text. Catches both role-prefixed forms (composer-j-x, probe-j-x)
# and bare journey-id tokens (the manifest's journey-id column). Output:
# sorted, unique, newline-separated.
extract_journey_slugs() {
  printf '%s' "$1" \
    | grep -oE '\b(sj-|j-)[a-z0-9]+(-[a-z0-9]+)*' 2>/dev/null \
    | sort -u
}

# ===========================================================================
# PostToolUse — record a process-validator greenlight + its manifest set.
# ===========================================================================
if [ "$EVENT_NAME" = "PostToolUse" ]; then
  echo "$DESCRIPTION" | grep -qE '^[[:space:]]*process-validator-' || exit 0

  RET=$(echo "$INPUT" | "$JQ" -r '.tool_response // "" | tostring' 2>/dev/null || echo "")
  [ -n "$RET" ] || exit 0

  # Must carry an explicit greenlight status, and must NOT be an
  # improvements-needed / block return.
  echo "$RET" | grep -qiE 'status["'"'"' ]{0,3}:?["'"'"' ]{0,3}greenlight' || exit 0
  if echo "$RET" | grep -qiE 'improvements-needed|status["'"'"' ]{0,3}:?["'"'"' ]{0,3}block'; then
    exit 0
  fi

  [ -f "$LEDGER" ] || exit 0
  CP=$("$JQ" -r '.currentPhase // empty' "$LEDGER" 2>/dev/null || echo "")
  CS=$("$JQ" -r '.currentSubStage // "none"' "$LEDGER" 2>/dev/null || echo "none")
  [ -n "$CP" ] || exit 0
  SCOPE="${CP}:${CS}"

  [ -d "$DOCS_DIR" ] || exit 0
  NOW=$(date +%s)

  # The manifest the validator reviewed lives in its input prompt. Parse
  # the journey-id set from it — this is what the greenlight binds to.
  PROMPT=$(echo "$INPUT" | "$JQ" -r '.tool_input.prompt // ""' 2>/dev/null || echo "")
  JSET=$(extract_journey_slugs "$PROMPT")
  JSET_JSON=$(echo "$JSET" | "$JQ" -R . 2>/dev/null | "$JQ" -sc 'map(select(length > 0))' 2>/dev/null || echo "[]")
  [ -n "$JSET_JSON" ] || JSET_JSON="[]"

  EXISTING="{}"
  if [ -f "$REGISTRY" ]; then
    EXISTING=$(cat "$REGISTRY" 2>/dev/null || echo "{}")
    if ! echo "$EXISTING" | "$JQ" -e 'type == "object"' >/dev/null 2>&1; then
      EXISTING="{}"
    fi
  fi

  UPDATED=$(echo "$EXISTING" | "$JQ" -c \
    --arg scope "$SCOPE" \
    --arg desc "$DESCRIPTION" \
    --argjson now "$NOW" \
    --argjson ttl "$TTL_SECONDS" \
    --argjson journeys "$JSET_JSON" '
      . as $reg
      | reduce keys[] as $k ({};
          if ($reg[$k].ts // 0) >= ($now - $ttl)
            then . + { ($k): $reg[$k] }
            else .
          end
        )
      | . + { ($scope): { ts: $now, validator: $desc, journeys: $journeys } }
    ' 2>/dev/null || echo "")

  if [ -n "$UPDATED" ]; then
    TMP="$REGISTRY.tmp.$$"
    echo "$UPDATED" > "$TMP" 2>/dev/null && mv "$TMP" "$REGISTRY" 2>/dev/null || rm -f "$TMP" 2>/dev/null || true
  fi
  exit 0
fi

# ===========================================================================
# PreToolUse — gate composer/probe wave dispatches.
# ===========================================================================

# Is this a composer/probe wave dispatch? (covers [group] / [P3-batch]).
echo "$DESCRIPTION" | grep -qE '(composer-j-|composer-sj-|probe-j-)' || exit 0

# Only gate inside Phase 5 (coverage-expansion) or Phase 6 (bug-discovery)
# — both fan out per-journey composer/probe waves and share the [group] /
# cap-7 dispatch mechanics, so both warrant a plan-review checkpoint. A
# Phase-6 synthesizer/triage dispatch carries no composer-j-/probe-j-
# token and is not gated; only actual per-journey probe waves are.
[ -f "$LEDGER" ] || exit 0
CP=$("$JQ" -r '.currentPhase // empty' "$LEDGER" 2>/dev/null || echo "")
case "$CP" in
  5) PHASE_LABEL="Phase-5 (coverage-expansion)" ;;
  6) PHASE_LABEL="Phase-6 (bug-discovery)" ;;
  *) exit 0 ;;
esac
CS=$("$JQ" -r '.currentSubStage // "none"' "$LEDGER" 2>/dev/null || echo "none")
SCOPE="${CP}:${CS}"

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

# Fetch the greenlight entry for this pass scope.
NOW=$(date +%s)
ENTRY="null"
if [ -f "$REGISTRY" ]; then
  ENTRY=$("$JQ" -c --arg s "$SCOPE" '.[$s] // null' "$REGISTRY" 2>/dev/null || echo "null")
fi

# --- (a) no fresh greenlight at all ---------------------------------------
GL_TS=0
if [ "$ENTRY" != "null" ]; then
  GL_TS=$(echo "$ENTRY" | "$JQ" -r '.ts // 0' 2>/dev/null || echo 0)
  case "$GL_TS" in ''|*[!0-9]*) GL_TS=0 ;; esac
fi
if [ "$ENTRY" = "null" ] || [ "$GL_TS" -lt "$((NOW - TTL_SECONDS))" ]; then
  emit_deny "[BLOCKED] ${PHASE_LABEL} composer/probe wave dispatched without a process-validator greenlight for the current scope.

Description: \"${DESCRIPTION}\"
Wave scope: ${SCOPE}  (currentPhase=${CP}, currentSubStage=${CS})

A composer/probe dispatch wave's PLAN must be reviewed BEFORE the wave
fans out — by a fresh \`process-validator-<scope>:\` sub-orchestrator.
The validator inspects the planned manifest against the contract:
parallelism / cap-7 group size, journey-coverage completeness,
role-prefix consistency, slug convention, marked-vs-unmarked batching.
Only its \`status: greenlight\` return unlocks the wave. Phase 5
(coverage-expansion) and Phase 6 (bug-discovery) both fan out per-journey
waves and share the [group] / cap-7 mechanics, so both require it.

Fix:
  1. Build the dispatch manifest for this wave (the table of
     description-prefix / journey-id / slug / model-hint per
     references/process-validator-workflow.md §2). The manifest MUST
     enumerate every planned journey — the greenlight binds to that set.
  2. Dispatch \`process-validator-<scope>:\` (e.g.
     \`process-validator-pass-<N>:\` in Phase 5, or
     \`process-validator-phase6:\` in Phase 6) with that manifest + the
     relevant skill loaded.
  3. On \`status: greenlight\`, re-issue this wave.
  4. On \`improvements-needed\`, revise the manifest and re-validate.

Ensure the ledger's currentSubStage already reflects this scope before
dispatching the validator.

See:
  - skills/coverage-expansion/SKILL.md §\"Recursive dispatch is impossible — plan, don't fan out\"
  - skills/coverage-expansion/references/process-validator-workflow.md"
  exit 0
fi

# --- (b) manifest-binding: dispatched journeys must be in the greenlit set -
GL_JOURNEYS=$(echo "$ENTRY" | "$JQ" -c '.journeys // null' 2>/dev/null || echo "null")

# Old-format greenlight (recorded before manifest-binding) — no journeys
# key. Fall back to scope-only allow (backward compatible).
[ "$GL_JOURNEYS" = "null" ] && exit 0

# A greenlight whose manifest yielded zero journey tokens binds to
# nothing — the validator reviewed a manifest the gate could not parse.
# Deny rather than silently pass an un-bindable plan.
GL_COUNT=$(echo "$GL_JOURNEYS" | "$JQ" -r 'length' 2>/dev/null || echo 0)
if [ "$GL_COUNT" = "0" ]; then
  emit_deny "[BLOCKED] The process-validator greenlight for ${PHASE_LABEL} scope ${SCOPE} recorded ZERO journeys.

Description: \"${DESCRIPTION}\"

A greenlight binds to the journey set named in the manifest the
validator reviewed. This greenlight's manifest had no parseable
journey-id tokens (composer-j-… / probe-j-… / j-… / sj-…), so it cannot
certify any wave.

Fix: re-dispatch the process-validator with a manifest that explicitly
enumerates the planned per-journey dispatches (one row per journey, with
the description-prefix and journey-id columns per
references/process-validator-workflow.md §2)."
  exit 0
fi

# Which journeys does THIS dispatch cover?
DISPATCH_JOURNEYS=$(extract_journey_slugs "$DESCRIPTION")
OUTSIDE=""
while IFS= read -r J; do
  [ -n "$J" ] || continue
  IN=$(echo "$GL_JOURNEYS" | "$JQ" -r --arg j "$J" 'if (index($j) != null) then "y" else "n" end' 2>/dev/null || echo "n")
  [ "$IN" = "y" ] || OUTSIDE="${OUTSIDE} ${J}"
done <<EOF
$DISPATCH_JOURNEYS
EOF

OUTSIDE=$(echo "$OUTSIDE" | sed -E 's/^ +//; s/ +/ /g')
if [ -n "$OUTSIDE" ]; then
  GL_LIST=$(echo "$GL_JOURNEYS" | "$JQ" -r 'join(", ")' 2>/dev/null || echo "")
  emit_deny "[BLOCKED] Manifest divergence — this ${PHASE_LABEL} dispatch covers journeys the process-validator did not greenlight.

Description: \"${DESCRIPTION}\"
Wave scope: ${SCOPE}

Journeys in this dispatch NOT in the greenlit manifest: ${OUTSIDE}
Greenlit manifest covered: ${GL_LIST}

The process-validator greenlight for this scope binds to the journey set
it actually reviewed. \`coverage-expansion\` §5 requires NO edits
between greenlight and dispatch — a wave that covers a journey the
validator never saw is exactly the divergence that rule forbids.

Fix — pick one:
  (a) The dispatch is wrong: re-shape it to match the greenlit manifest
      (only journeys the validator reviewed).
  (b) The plan legitimately changed: re-dispatch the process-validator
      with the UPDATED manifest (covering the new journey set) and get a
      fresh greenlight before re-issuing this wave.

See: skills/coverage-expansion/references/process-validator-workflow.md §5"
  exit 0
fi

exit 0
