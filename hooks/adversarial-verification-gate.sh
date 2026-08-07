#!/bin/bash
# adversarial-verification-gate.sh — no QA sign-off without an adversarial
#                                     review of the tests.
#
# Hook    : PreToolUse:mcp__.*  (tracker mutation tools)
# Mode    : DENY  (transitioning a ticket to a COMPLETED state with no
#                  verification receipt — that is sign-off, and sign-off is
#                  exactly the moment the check must already have happened)
# Mode    : WARN  (posting a verdict-shaped comment with no receipt — the
#                  report can still be useful, but it must not read as
#                  verified when nothing verified it)
# Mode    : silent allow (protocol inactive; non-tracker tools; tracker
#                  reads; a valid receipt exists)
# State   : reads <workspace>/.achilles/adversarial-verification/*.json
#           (no writes — this gate never authors the thing it checks)
# Env     : WORKSPACE_ROOT (defaults to git toplevel of cwd)
#           CIVITAS_DISABLE_ADVERSARIAL_GATE=1 disables the hook
#
# Why this exists
# ---------------
# Baseline testing of the ticket-driven-testing skill found that an agent
# which has just written a test suite reliably SKIPS checking whether that
# suite can fail. Three instruction-level fixes were attempted — a prose
# sign-off gate, a structural heading fix, an explicit numbered template —
# and all three failed: the agent produced an otherwise excellent plan and
# omitted the negative control every time. An agent with NO skill at all
# named it first, unprompted.
#
# The conclusion is that this cannot be fixed by asking. The skill now
# DELEGATES the check to adversarial subagents (ticket-driven-testing §8b),
# and this gate makes the delegation load-bearing: the receipt those
# subagents write is what unlocks sign-off. Instruction failed; structure
# is the fallback.
#
# What counts as a receipt
# ------------------------
# .achilles/adversarial-verification/<ticket>.json, containing at minimum a
# `negativeControl` object. It must be NEWER than the newest spec file in
# the workspace — a receipt from before the tests were last edited proves
# nothing about the tests as they now stand. That staleness check is the
# point: without it, one receipt would unlock every future sign-off.
#
# Deliberately NOT enforced here: whether the receipt's contents are
# honest. A hook cannot tell a real probe run from a fabricated JSON file.
# This gate raises the cost of skipping from "forget" to "actively write a
# false artifact", which is the most a harness can do.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

JQ="$HOOK_DIR/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
if [ -z "$JQ" ]; then
  echo "[$(basename "${BASH_SOURCE[0]}")] FATAL: jq not found at \$HOOK_DIR/bin/jq nor on PATH." >&2
  exit 1
fi

[ "${CIVITAS_DISABLE_ADVERSARIAL_GATE:-}" = "1" ] && exit 0

INPUT="$(cat)"

# shellcheck source=lib/achilles-activation.sh
if [ -f "$HOOK_DIR/lib/achilles-activation.sh" ]; then
  . "$HOOK_DIR/lib/achilles-activation.sh"
  achilles_session_active "$INPUT" || exit 0
fi

TOOL_NAME="$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name // empty')"
[ -n "$TOOL_NAME" ] || exit 0

# Tracker mutation surfaces across vendors. Reads are not gated — only the
# two actions that constitute sign-off.
IS_TRANSITION=0
IS_COMMENT=0
case "$TOOL_NAME" in
  *save_issue*|*transitionJiraIssue*|*update_issue*|*editJiraIssue*) IS_TRANSITION=1 ;;
  *save_comment*|*addCommentToJiraIssue*|*create_comment*)           IS_COMMENT=1 ;;
  *) exit 0 ;;
esac

ARGS="$(printf '%s' "$INPUT" | "$JQ" -c '.tool_input // {}')"

# A transition only matters when it moves the ticket to a terminal state.
# Status vocabularies are per-project, so match on the common completed
# names rather than assuming one canonical "Done".
if [ "$IS_TRANSITION" = "1" ]; then
  STATE="$(printf '%s' "$ARGS" | "$JQ" -r '(.state // .status // .transition // empty) | if type=="object" then (.name // .id // "") else . end' 2>/dev/null || true)"
  printf '%s' "$STATE" | grep -qiE 'done|complete|closed|resolved|shipped|released' || exit 0
fi

# A comment only matters when it reads as a QA verdict.
if [ "$IS_COMMENT" = "1" ]; then
  BODY="$(printf '%s' "$ARGS" | "$JQ" -r '.body // empty')"
  printf '%s' "$BODY" | grep -qiE 'qa (test )?report|acceptance criteri|verdict|sign.?off|AC-[0-9]' || exit 0
fi

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
RECEIPT_DIR="$WORKSPACE_ROOT/.achilles/adversarial-verification"

newest_receipt() {
  [ -d "$RECEIPT_DIR" ] || return 1
  find "$RECEIPT_DIR" -maxdepth 1 -name '*.json' -type f 2>/dev/null |
    while read -r f; do
      "$JQ" -e 'has("negativeControl")' "$f" >/dev/null 2>&1 && echo "$f"
    done | head -1
}

RECEIPT="$(newest_receipt || true)"

# A receipt older than the newest spec describes tests that no longer exist
# in that form.
STALE=0
if [ -n "$RECEIPT" ]; then
  NEWEST_SPEC="$(find "$WORKSPACE_ROOT" -name '*.spec.ts' -o -name '*.spec.js' -o -name '*.test.ts' 2>/dev/null |
    grep -v node_modules | head -400 | xargs ls -t 2>/dev/null | head -1 || true)"
  if [ -n "$NEWEST_SPEC" ] && [ "$NEWEST_SPEC" -nt "$RECEIPT" ]; then STALE=1; fi
fi

[ -n "$RECEIPT" ] && [ "$STALE" = "0" ] && exit 0

if [ "$STALE" = "1" ]; then
  REASON="An adversarial-verification receipt exists but is OLDER than the most recently edited spec. It describes tests that have since changed, so it does not vouch for the suite as it now stands."
else
  REASON="No adversarial-verification receipt found under .achilles/adversarial-verification/."
fi

GUIDANCE="Run ticket-driven-testing §8 and §8b before signing off:

  §8   the negative control — run the suite against an environment WITHOUT
       the fix and require it to FAIL. A suite nobody has seen fail is not
       regression cover.
  §8b  dispatch probe-mutation, probe-coverage and probe-assertions in
       parallel. Do not self-assess tests you wrote; baseline testing shows
       that check gets skipped, which is why it is delegated.

Then write .achilles/adversarial-verification/<ticket>.json with at least a
negativeControl object.

If the control genuinely cannot be run here, say so IN THE VERDICT — an
unverified suite reported as unverified is honest; reported as regression
cover it is not. Kill-switch: CIVITAS_DISABLE_ADVERSARIAL_GATE=1."

if [ "$IS_TRANSITION" = "1" ]; then
  "$JQ" -n --arg r "$REASON" --arg g "$GUIDANCE" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:("Sign-off blocked. " + $r + "\n\n" + $g)}}'
  exit 0
fi

echo "[adversarial-verification-gate] WARN: posting a QA verdict with no adversarial verification. $REASON" >&2
echo "$GUIDANCE" >&2
exit 0
