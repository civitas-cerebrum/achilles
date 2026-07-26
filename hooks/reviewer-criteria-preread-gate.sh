#!/bin/bash
# reviewer-criteria-preread-gate.sh — the reviewer must READ the pinned,
#                                     un-editable criteria before its
#                                     approval lands in the ledger.
#
# Hook    : PreToolUse:Write|Edit
# Mode    : DENY (approval write with no criteria-read in the transcript)
# Scope   : achilles projects only (lib/achilles-project-gate.sh); fires
#           only on a write that transitions the onboarding ledger to
#           reviewerVerdict: approved.
# State   : reads the pinned criteria (hooks/data/reviewer-criteria.txt,
#           installed to ~/.claude/hooks/data/) and the writer's transcript.
# Env     : REVIEWER_CRITERIA_PREREAD_GATE=off → bypass (calibration/operator)
#
# Why
# ---
# The reviewer decides whether a stage's exit criteria are met. If the
# orchestrator could supply / paraphrase / soften those criteria in the
# dispatch brief, "dispatch a reviewer and tell it the bar is already met"
# would defeat the whole check (see skills/workflow-reviewer/SKILL.md and
# the injection surface the brief-gate only partially closes). The bar is
# pinned in hooks/data/reviewer-criteria.txt — a file the orchestrator
# cannot edit (Write/Edit denied by harness-self-protection-guard.sh; Bash
# mutation denied by protected-artifact-bash-guard.sh, whose PROTECTED set
# includes `.claude/hooks`). This gate closes the last link: an approval
# cannot land unless the approving context actually READ that pinned file.
# Authority for the criteria thereby shifts from the orchestrator's brief
# to the pinned text.
#
# The approval write is authored by the reviewer subagent (the SoD gate in
# lib/pipeline-gate.sh denies approval writes from the orchestrator's own
# context), so the transcript at this write is the REVIEWER's — its Reads
# are visible here.
#
# Fail-open (documented, mirrors journey-mapping-skill-preread-gate.sh):
#   - no transcript_path / unreadable transcript → allow. On such harness
#     builds this gate provides no protection; the TRANSCRIPT-INDEPENDENT
#     floor is workflow-reviewer-brief-gate.sh, which denies at dispatch
#     time any reviewer brief that doesn't cite the pinned criteria and any
#     brief carrying fault-suppression directives.
#   - non-approval writes → allow (silent).
#
# Pairs with:
#   hooks/workflow-reviewer-brief-gate.sh (dispatch-time: brief must cite
#     the pinned criteria + no fault-suppression language)
#   hooks/data/reviewer-criteria.txt      (the pinned bar)
#   hooks/lib/pipeline-gate.sh            (SoD + scope-matched approver)

set -uo pipefail

[ "${REVIEWER_CRITERIA_PREREAD_GATE:-on}" = "off" ] && exit 0

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
[ -n "$JQ" ] || exit 0   # no jq → cannot evaluate; never jam a write

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")
case "$TOOL_NAME" in Write|Edit) ;; *) exit 0 ;; esac

FILE_PATH=$(echo "$INPUT" | "$JQ" -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
[ -n "$FILE_PATH" ] || exit 0

# Only the onboarding ledger carries reviewerVerdict transitions.
case "$FILE_PATH" in
  */tests/e2e/docs/onboarding-status.json) ;;
  *) exit 0 ;;
esac

GUARD_CWD=$(echo "$INPUT" | "$JQ" -r '.cwd // "."' 2>/dev/null || echo ".")
REPO_ROOT=$(cd "$GUARD_CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || echo "$GUARD_CWD")

# Project scoping.
# shellcheck source=lib/achilles-project-gate.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/achilles-project-gate.sh"
achilles_hooks_active "$REPO_ROOT" || exit 0

emit_deny() {
  "$JQ" -n --arg r "$1" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": $r
    }
  }'
}

# --- Does this write introduce a NEW approval? ------------------------------
# Write: compare the proposed content's approved set against the on-disk one,
#        and capture the NEW unit list for the coverage check.
# Edit: best-effort — an Edit whose new_string introduces an approved verdict
# is treated as a candidate approval (coverage can't be checked from a
# fragment, so an Edit approval gets the transcript-read check only).
IS_APPROVAL=0
NEW_CONTENT=""
NEW_UNITS="[]"   # e.g. ["phase:1","substage:5.pass-2"]
if [ "$TOOL_NAME" = "Write" ]; then
  NEW_CONTENT=$(echo "$INPUT" | "$JQ" -r '.tool_input.content // ""' 2>/dev/null || echo "")
  NEW_APPROVED=$(printf '%s' "$NEW_CONTENT" | "$JQ" -c '
    [ (.phases // [])[]? | select(.reviewerVerdict == "approved") | "phase:\(.id)" ]
    + [ (.phases // [])[]? as $p | ($p.subStages // [])[]? | select(.reviewerVerdict == "approved") | "substage:\($p.id).\(.id)" ]
  ' 2>/dev/null || echo "[]")
  PRIOR_APPROVED="[]"
  if [ -f "$FILE_PATH" ]; then
    PRIOR_APPROVED=$("$JQ" -c '
      [ (.phases // [])[]? | select(.reviewerVerdict == "approved") | "phase:\(.id)" ]
      + [ (.phases // [])[]? as $p | ($p.subStages // [])[]? | select(.reviewerVerdict == "approved") | "substage:\($p.id).\(.id)" ]
    ' "$FILE_PATH" 2>/dev/null || echo "[]")
  fi
  NEW_UNITS=$("$JQ" -nc --argjson prior "$PRIOR_APPROVED" --argjson new "$NEW_APPROVED" \
    '[$new[] | select(. as $n | $prior | index($n) | not)]' 2>/dev/null || echo "[]")
  [ "$("$JQ" -r 'length' <<<"$NEW_UNITS" 2>/dev/null || echo 0)" -gt 0 ] && IS_APPROVAL=1
else
  NEW_STRING=$(echo "$INPUT" | "$JQ" -r '.tool_input.new_string // ""' 2>/dev/null || echo "")
  if printf '%s' "$NEW_STRING" | grep -qE '"reviewerVerdict"[[:space:]]*:[[:space:]]*"approved"|reviewerVerdict:[[:space:]]*approved'; then
    IS_APPROVAL=1
  fi
fi
[ "$IS_APPROVAL" -eq 1 ] || exit 0

# --- Coverage: the approval must cover EVERY pinned criterion for the unit --
# Transcript-INDEPENDENT hard gate (backstops the read-check's fail-open):
# for each newly-approved unit, `criteriaCovered` in the ledger must include
# every criterion ID pinned for that unit's section. Write path only — an
# Edit fragment can't carry the full state. Skips a unit whose pinned section
# is absent (perf units, unknown units) or when the pinned file is missing.
CRITERIA_FILE="$(dirname "${BASH_SOURCE[0]}")/data/reviewer-criteria.txt"
if [ "$TOOL_NAME" = "Write" ] && [ -f "$CRITERIA_FILE" ]; then
  # pinned IDs for a section key (phase<N> | pass | cycle).
  pinned_ids() {
    sed -n "/^\[$1\]/,/^\[/p" "$CRITERIA_FILE" | grep -oE '^\([a-z0-9-]+\)' | tr -d '()' || true
  }
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    case "$unit" in
      phase:*)
        pid="${unit#phase:}"; section="phase${pid}"
        covered=$(printf '%s' "$NEW_CONTENT" | "$JQ" -r --argjson id "$pid" \
          '[(.phases // [])[]? | select(.id == $id) | (.criteriaCovered // [])[]] | .[]' 2>/dev/null || echo "")
        ;;
      substage:*)
        rest="${unit#substage:}"; pid="${rest%%.*}"; sid="${rest#*.}"
        section=$(printf '%s' "$sid" | sed -E 's/^(pass|cycle)-[0-9]+$/\1/')
        [ "$section" = "$sid" ] && continue   # unrecognised substage shape
        covered=$(printf '%s' "$NEW_CONTENT" | "$JQ" -r --argjson id "$pid" --arg sid "$sid" \
          '[(.phases // [])[]? | select(.id == $id) | (.subStages // [])[]? | select(.id == $sid) | (.criteriaCovered // [])[]] | .[]' 2>/dev/null || echo "")
        ;;
      *) continue ;;
    esac
    PINNED=$(pinned_ids "$section")
    [ -n "$PINNED" ] || continue   # no pinned criteria for this section → skip
    MISSING=""
    while IFS= read -r pid_crit; do
      [ -n "$pid_crit" ] || continue
      printf '%s\n' "$covered" | grep -qxF "$pid_crit" || MISSING="${MISSING} ${pid_crit}"
    done <<< "$PINNED"
    if [ -n "$MISSING" ]; then
      emit_deny "[BLOCKED] Reviewer approval does not cover every pinned criterion.

File: ${FILE_PATH}
Unit: ${unit}  (pinned section [${section}])
Uncovered criteria (pinned but not in criteriaCovered):${MISSING}

The reviewer approved this unit, but its \`criteriaCovered\` in the ledger
omits pinned criteria. An approval must assess EVERY criterion pinned for
the unit in hooks/data/reviewer-criteria.txt §[${section}] — a reviewer
cannot approve while silently dropping one (e.g. \"P0/P1 may not be
skipped\").

Do this instead: for each pinned criterion, verify it on disk and add its
id to \`phases[].criteriaCovered\` (or the substage's) before approving.
Read the pinned ids from ~/.claude/hooks/data/reviewer-criteria.txt
§[${section}].

Reference: hooks/data/reviewer-criteria.txt; skills/workflow-reviewer/SKILL.md"
      exit 0
    fi
  done < <("$JQ" -r '.[]' <<<"$NEW_UNITS" 2>/dev/null)
fi

# --- Transcript proof the reviewer READ the pinned criteria -----------------
TRANSCRIPT_PATH=$(echo "$INPUT" | "$JQ" -r '.transcript_path // empty' 2>/dev/null || echo "")
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  exit 0   # fail-open; the brief-gate is the transcript-independent floor
fi

# A Read tool_use whose file_path resolves to reviewer-criteria.txt (any
# install prefix: ~/.claude/hooks/data/, the repo copy, node_modules) OR a
# Bash command that cats/reads it. Same transcript-walk shape as
# journey-mapping-skill-preread-gate.sh.
PREREAD_FOUND=$(
  "$JQ" -r '
    if (.message? | type) == "object" and (.message.content? | type) == "array" then
      .message.content[] |
        select(.type? == "tool_use") |
        (
          (select(.name? == "Read") | (.input.file_path // "")),
          (select(.name? == "Bash") | (.input.command  // ""))
        )
    else empty end
  ' "$TRANSCRIPT_PATH" 2>/dev/null \
    | grep -E 'reviewer-criteria\.txt' \
    | head -1 || true
)
[ -n "$PREREAD_FOUND" ] && exit 0

emit_deny "[BLOCKED] Reviewer approval without reading the pinned criteria.

File: ${FILE_PATH}

This write transitions the ledger to reviewerVerdict: approved, but the
approving context's transcript shows no Read of the pinned reviewer
criteria (hooks/data/reviewer-criteria.txt). The bar a reviewer approves
against must come from that pinned, un-editable file — NOT from criteria
supplied or paraphrased in the dispatch brief. An approval that never
loaded the pinned bar cannot be trusted to have evaluated the real one.

Do this instead:
  1. Read the pinned criteria for this unit before approving — it is
     installed at ~/.claude/hooks/data/reviewer-criteria.txt (section
     [phase<N>] / [pass] / [cycle] / [perf-phase<N>] / [perf-pass]).
  2. Build the checklist from THOSE criteria (every one assessed), verify
     each on disk, and only then record the verdict.

Reference:
  hooks/data/reviewer-criteria.txt
  skills/workflow-reviewer/SKILL.md §\"Per-unit checklist\""
exit 0
