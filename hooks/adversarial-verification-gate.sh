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
#           CIVITAS_DISABLE_ADVERSARIAL_GATE=1 disables the hook. Deliberately
#           NOT repeated in the denial message: a gate that prints its own
#           bypass at the moment of maximum frustration is a gate that lives in
#           someone's shell profile by the end of week one. Documented here and
#           in the skill, where it is read in a calmer moment.
#
# Why this exists
# ---------------
# Baseline testing of the ticket-driven-testing skill found that an early
# draft omitted this check every time: an agent that had just written a
# suite produced an otherwise excellent plan and never asked whether the
# suite could fail. An agent with NO skill at all named that check first,
# unprompted — so the draft was worse than nothing on this dimension.
#
# The skill was revised and now does fire the check (see its §"Baseline
# testing"). This gate is therefore DEFENCE IN DEPTH, not the sole
# mechanism, and the honest reason it still earns its place is:
#
#   1. Instructions are advisory; a gate is not. A skill can be skimmed,
#      truncated, or superseded by a user instruction. This cannot.
#   2. It is independent of the skill's CONTENTS. A gate keyed on the action
#      does not care what the skill said, or whether the installed copy
#      matched the repository copy — a desync that once hid a draft's failure
#      for five test runs. It is NOT independent of whether an achilles skill
#      was invoked at all: this hook is session-scoped like every other, and
#      silent-allows in a session that never activated the protocol.
#
# Deliberately NOT claimed: that instruction-level guidance does not work.
# It does. This is a second line, not a replacement.
#
# What counts as a receipt
# ------------------------
# .achilles/adversarial-verification/<ticket>.json, carrying BOTH a
# `negativeControl` object (the author ran the checks) and a `review` object
# (someone independent judged the result adequate):
#
#   "review": {
#     "reviewer": "probe-rigour-<id>",   // who; empty is a denial
#     "uiReviewed": true,                 // they looked at the UI, not only the specs
#     "coverageSufficient": true,         // the explicit conclusion
#     "scores": { "R1": 3, "R2": 2, ... },// any 0 blocks, whatever the total
#     "total": 15                         // <= 12 blocks
#   }
#
# The UI flag is not ceremony. A reviewer who reads only specs can certify that
# every assertion is well-formed while the feature is visibly broken in a
# browser — that exact gap shipped here, where two acceptance criteria were
# declared verified on a mechanism and a tautology and every test passed. It must be NEWER than the newest spec file in
# the workspace — a receipt from before the tests were last edited proves
# nothing about the tests as they now stand. The receipt must ALSO carry the
# ticket key in its filename: without that, any receipt unlocked any ticket,
# which was a real defect found by adversarial review of this gate.
#
# HONEST STATUS — read before relying on this. Adversarial review defeated the receipt binding
# four ways and the staleness scan six. Exact-key matching closed the first set; the rest are
# structural and CANNOT be patched:
#   * the receipt lives in a directory no protected-artifact guard covers, so the agent being
#     judged can author, post-date or delete its own acquittal (`touch -t 2030…` makes staleness
#     permanently unfailable);
#   * the spec scan truncates at 2000 paths in READDIR order and xargs-batches, so on a large
#     monorepo the genuinely-newest spec can be missed;
#   * the `review` block is JSON the same agent can write. This gate enforces the SHAPE and the
#     THRESHOLDS of a review, which is real — it cannot enforce that a reviewer ran, or that the
#     reviewer was not the author. A PreToolUse hook has no way to attest subagent identity. Treat
#     a passing receipt as "the author asserts a review with these scores", not "a review happened";
#   * only mcp__* tools are seen — Bash, curl and gh are ungated, and the skill itself documents
#     them as the fallback;
#   * the status vocabulary is six English words.
# This is a speed bump, not a control. Making it sound needs a hook-authored, hash-chained receipt
# on the protected list — the pattern ledger-integrity-chain.sh already implements.
#
# Deliberately NOT enforced here: whether the receipt's contents are
# honest. A hook cannot tell a real probe run from a fabricated JSON file.
# This gate raises the cost of skipping from "forget" to "actively write a
# false artifact". That is NOT the ceiling for a harness — this repo already
# ships a stronger pattern (hook-authored, hash-chained artifacts on the
# protected list, per ledger-integrity-chain.sh). The receipt should move to
# that pattern; until it does, the honest description is "raises the cost",
# not "prevents".

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
IS_PR=0
case "$TOOL_NAME" in
  *save_issue*|*transitionJiraIssue*|*update_issue*|*editJiraIssue*) IS_TRANSITION=1 ;;
  *save_comment*|*addCommentToJiraIssue*|*create_comment*)           IS_COMMENT=1 ;;
  # A developer-triggered run has no ticket to transition. Its sign-off boundary is opening the
  # PR — the moment the work is presented to others as done — so that is where the same check
  # belongs. Without this the whole entry-B path was ungated: the gate policed a surface the dev
  # flow never touches.
  Bash)                                                              IS_PR=1 ;;
  *) exit 0 ;;
esac

ARGS="$(printf '%s' "$INPUT" | "$JQ" -c '.tool_input // {}')"

if [ "$IS_PR" = "1" ]; then
  CMD="$(printf '%s' "$ARGS" | "$JQ" -r '.command // empty')"
  # Only PR-publishing commands. `gh pr view/list/diff/checkout` are reads and stay silent, as do
  # all other Bash calls — a gate that fires on ordinary shell use gets disabled the same day.
  # `gh` must START the command or follow a shell separator. Matching the words anywhere meant
  # `echo gh pr create` and `grep "gh pr create" .` both tripped the gate — a hook that fires when
  # someone greps for its own trigger is the over-firing that gets hooks switched off.
  printf '%s' "$CMD" | grep -qE '(^|[;&|])[[:space:]]*gh[[:space:]]+pr[[:space:]]+(create|ready)([[:space:]]|$)' || exit 0
  # `--draft` is explicitly not sign-off: it is how you share work in progress.
  printf '%s' "$CMD" | grep -qE '(^|[[:space:]])(--draft|-d)([[:space:]]|$)' && exit 0
fi

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

# The ticket being signed off. Without this the gate cannot tell whose receipt it is looking at —
# an earlier version accepted ANY receipt for ANY ticket, which made it worthless the moment a
# second ticket was worked in the same repo.
TICKET_KEY="$(printf '%s' "$ARGS" | "$JQ" -r '(.id // .issue // .issueId // .issueIdOrKey // .key // empty) | tostring' 2>/dev/null || true)"

# Entry B has no ticket, so the receipt binds to the BRANCH instead — the only stable identifier
# the work has. Same exact-match rules apply; slashes become dashes so the key is a legal stem.
if [ "$IS_PR" = "1" ] && [ -z "$TICKET_KEY" ]; then
  TICKET_KEY="$(git -C "$WORKSPACE_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null | tr '/' '-' || true)"
fi

# The receipt must belong to THIS ticket.
#
# EXACT matching only. Substring matching was defeated on ordinary payloads: with ABC-15.json on
# disk, a transition of ABC-1 was allowed (prefix collision — the normal state of every tracker),
# and a key of "json" or "-" matched every receipt on disk.
#
# HONEST LIMIT, do not read this as a security boundary: the receipt is written by the same actor
# the gate judges, in a directory no protected-artifact guard covers. Filename binding raises the
# cost of a mistake; it does not stop a determined agent, which can author the file. Content-based
# binding is strictly worse — a receipt that names its own scope is self-declared — so the `.ticket`
# fallback below requires EXACT equality and exists only for trackers whose payload `.id` is a UUID.
# Making this sound requires a hook-authored, hash-chained receipt on the protected list, the
# pattern ledger-integrity-chain.sh already implements for other artifacts. Until then this gate is
# a speed bump, and the docs must say so.
receipt_for_ticket() {
  [ -d "$RECEIPT_DIR" ] || return 1
  [ -n "$TICKET_KEY" ] || return 1
  # Reject degenerate keys outright — they only ever arise from a malformed or hostile payload.
  case "$TICKET_KEY" in ''|'-'|'.'|json|JSON) return 1 ;; esac
  [ "${#TICKET_KEY}" -ge 3 ] || return 1

  local key_lc f base stem recorded
  key_lc="$(printf '%s' "$TICKET_KEY" | tr '[:upper:]' '[:lower:]')"
  for f in $(ls -t "$RECEIPT_DIR"/*.json 2>/dev/null); do
    "$JQ" -e 'has("negativeControl") and has("review")' "$f" >/dev/null 2>&1 || continue
    base="$(basename "$f" | tr '[:upper:]' '[:lower:]')"
    stem="${base%.json}"
    # Exact stem, or exact stem followed by a separator (ABC-450-run2.json), never a bare substring.
    if [ "$stem" = "$key_lc" ] || case "$stem" in "$key_lc"[-_.]*) true ;; *) false ;; esac; then
      echo "$f"; return 0
    fi
    # UUID-shaped ids never appear in filenames. Exact equality on ONE field only.
    recorded="$("$JQ" -r '(.ticket? // "") | if type=="string" then ascii_downcase else "" end' "$f" 2>/dev/null || true)"
    [ -n "$recorded" ] && [ "$recorded" = "$key_lc" ] && { echo "$f"; return 0; }
  done
  return 1
}

RECEIPT="$(receipt_for_ticket || true)"

# A receipt older than the newest spec describes tests that no longer exist in that form.
#
# The scan is bounded and prunes node_modules DURING the walk, not after: this hook runs with a
# 10s budget and an unpruned walk of a monorepo blows it, which fails OPEN. Sorting by mtime is
# done by `ls -t` over the pruned set rather than by truncating the walk, so the genuinely-newest
# spec cannot be excluded by directory order.
STALE=0
if [ -n "$RECEIPT" ]; then
  NEWEST_SPEC="$(find "$WORKSPACE_ROOT" \
      \( -name node_modules -o -name .git -o -name dist -o -name build \) -prune -o \
      -type f \( -name '*.spec.*' -o -name '*.test.*' \) -print 2>/dev/null |
    head -2000 | tr '\n' '\0' | xargs -0 ls -t 2>/dev/null | head -1 || true)"
  if [ -n "$NEWEST_SPEC" ] && [ "$NEWEST_SPEC" -nt "$RECEIPT" ]; then STALE=1; fi
fi

# A receipt proves the author ran the checks. It does not prove anyone INDEPENDENT looked at the
# result and judged the coverage adequate — and "I verified my own work" is the failure mode this
# whole skill exists to catch. So the receipt must carry a reviewer's explicit green light, and
# that reviewer must have looked at the UI as well as the tests: a reviewer who only reads specs
# can confirm the assertions are well-formed while the feature is visibly broken in the browser.
#
# Thresholds mirror ticket-driven-testing §8c. They are enforced here rather than trusted because
# a score with no consequence is a decoration.
REVIEW_PROBLEM=""
if [ -n "$RECEIPT" ] && [ "$STALE" = "0" ]; then
  if ! "$JQ" -e '.review.coverageSufficient == true' "$RECEIPT" >/dev/null 2>&1; then
    REVIEW_PROBLEM="the reviewer did not conclude the coverage is sufficient (.review.coverageSufficient is not true)"
  elif ! "$JQ" -e '.review.uiReviewed == true' "$RECEIPT" >/dev/null 2>&1; then
    REVIEW_PROBLEM="the reviewer did not review the UI (.review.uiReviewed is not true). A specs-only review confirms the assertions are well-formed while the feature is visibly broken."
  elif ! "$JQ" -e '(.review.reviewer // "") | type == "string" and length > 0' "$RECEIPT" >/dev/null 2>&1; then
    REVIEW_PROBLEM="no reviewer is named (.review.reviewer is empty)"
  elif "$JQ" -e '[.review.scores // {} | to_entries[] | select(.value == 0)] | length > 0' "$RECEIPT" >/dev/null 2>&1; then
    REVIEW_PROBLEM="a rubric dimension scored 0: $("$JQ" -r '[.review.scores | to_entries[] | select(.value == 0) | .key] | join(", ")' "$RECEIPT" 2>/dev/null). Any 0 blocks sign-off regardless of the total."
  elif ! "$JQ" -e '(.review.total // 0) > 12' "$RECEIPT" >/dev/null 2>&1; then
    REVIEW_PROBLEM="the review scored $("$JQ" -r '.review.total // "nothing"' "$RECEIPT" 2>/dev/null)/18. 12 or below means rework before the report ships."
  fi
fi

[ -n "$RECEIPT" ] && [ "$STALE" = "0" ] && [ -z "$REVIEW_PROBLEM" ] && exit 0

if [ -n "$REVIEW_PROBLEM" ]; then
  REASON="A verification receipt exists, but the review did not green-light it: ${REVIEW_PROBLEM}"
elif [ "$STALE" = "1" ]; then
  REASON="An adversarial-verification receipt exists but is OLDER than the most recently edited spec. It describes tests that have since changed, so it does not vouch for the suite as it now stands."
else
  REASON="No adversarial-verification receipt found under .achilles/adversarial-verification/."
fi

GUIDANCE="Run ticket-driven-testing §8 and §8b before signing off.

Opening a PR IS sign-off — it presents the work to others as done. For a
developer-triggered run the receipt binds to the branch name rather than a
ticket key; \`gh pr create --draft\` is not gated, because sharing work in
progress is not a claim that it is verified.


  §8   the negative control — run the suite against an environment WITHOUT
       the fix and require it to FAIL. A suite nobody has seen fail is not
       regression cover.
  §8b  dispatch probe-mutation, probe-coverage, probe-assertions and
       probe-value in parallel. Do not self-assess tests you wrote — a
       reviewer with no stake in them is the point.

Then write .achilles/adversarial-verification/<ticket>.json with at least a
negativeControl object.

If the control genuinely cannot be run here, say so IN THE VERDICT — an
unverified suite reported as unverified is honest; reported as regression
cover it is not.

Cannot run the control here? Say that in the verdict and scope the claim to
what you did run. That is a legitimate outcome and it does not need the gate
turned off — it needs the report to be accurate."

# Publishing a PR is a terminal act in exactly the way a Done transition is: it presents the
# work to others as finished. So it DENIES rather than advises — an entry-B run that only warned
# here would leave the developer path with no enforcement at all.
if [ "$IS_TRANSITION" = "1" ] || [ "$IS_PR" = "1" ]; then
  "$JQ" -n --arg r "$REASON" --arg g "$GUIDANCE" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:("Sign-off blocked. " + $r + "\n\n" + $g)}}'
  exit 0
fi

"$JQ" -n --arg m "Posting a QA verdict with no adversarial verification. $REASON

$GUIDANCE" '{systemMessage: $m}'
exit 0
