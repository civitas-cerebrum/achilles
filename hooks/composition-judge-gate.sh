#!/bin/bash
# composition-judge-gate.sh — Stage 4c judge-loop leash: once a
#                              composition-judge dispatch exists, the
#                              session cannot stop on an unresolved
#                              NOT SATISFIED verdict below the cap.
#
# Hook    : PreToolUse:Agent (RECORD), PostToolUse:Agent (RECORD), Stop (DENY)
# Mode    : RECORD (Agent events) + DENY (Stop blocks while a judge loop is
#           open on a NOT SATISFIED verdict below the 3-reject cap; single
#           shot — a repeat Stop with stop_hook_active is allowed so the
#           gate cannot loop the session forever)
# State   : ${ACHILLES_JUDGE_STATE_DIR:-$HOME/.claude/achilles/composition-judge}/<session_id>.json
# Env     : ACHILLES_JUDGE_STATE_DIR=<dir>  (state-dir override, used by tests)
#
# Rule
# ----
# Stage 4c of the composing pipeline (test-composition-standards.md §4)
# requires an author↔judge loop to terminate in exactly one of two ways:
# a SATISFIED verdict, or operator escalation after 3 consecutive
# NOT SATISFIED verdicts. This hook records every `composition-judge-*`
# Agent dispatch (PreToolUse) and parses each such dispatch's return for
# its verdict (PostToolUse: `improvements-needed` → NOT SATISFIED,
# `greenlight` → SATISFIED). At Stop, a session whose most recent judge
# verdict is NOT SATISFIED with fewer than 3 consecutive rejections is
# blocked: the loop is open, and stopping abandons must-fix findings.
# At the cap (>= 3) the sanctioned next step IS stopping to escalate to
# the operator, so the gate allows it.
#
# Why
# ---
# The judge loop's arming half ("dispatch a judge at every composing
# exit") is not mechanically detectable — spec writes also happen in
# repair / diagnosis / evidence contexts that legitimately never judge
# (see anti-rationalizations.md §"markdown-only deferral — judge-loop
# arming"). But the abandonment half IS detectable: once a judge has
# been dispatched, "fix, re-run 4a/4b, re-judge" vs "stop mid-loop" is
# visible in the dispatch/verdict ledger this hook keeps. Under context
# pressure an author reading its own NOT SATISFIED verdict will
# rationalise stopping ("the findings can wait", "I'll re-judge next
# session"); the harness is the second reader it cannot talk past.
#
# Canonical reference
# -------------------
# skills/achilles-protocol/references/test-composition-standards.md §4
# skills/coverage-expansion/references/anti-rationalizations.md
#   §"Pattern: Judge-loop skipping (Stage 4c self-exemption)"
#
# Failure → action
# ----------------
# - Stop w/ last verdict NOT SATISFIED, consecutive < 3   → DENY (decision: block)
# - Stop w/ stop_hook_active already true                 → silent allow (no infinite loop)
# - Stop at the cap (consecutive >= 3)                    → silent allow (operator escalation)
# - Stop w/ last verdict SATISFIED / no verdict / no judge → silent allow
# - composition-judge-* dispatch (PreToolUse)             → RECORD, silent allow
# - composition-judge-* return (PostToolUse)              → RECORD verdict, silent allow
# - malformed input / jq missing / state unreadable       → silent allow (fail open)

set -uo pipefail

JQ="$(dirname "${BASH_SOURCE[0]}")/bin/jq"
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
[ -n "$JQ" ] || exit 0

INPUT=$(cat 2>/dev/null || echo "{}")

# Session-scope gate: only achilles-activated sessions feel this leash.
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/achilles-activation.sh"
achilles_require_active "$INPUT"

EVENT=$(printf '%s' "$INPUT" | "$JQ" -r '.hook_event_name // empty' 2>/dev/null || echo "")
TOOL_NAME=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")
SID=$(printf '%s' "$INPUT" | "$JQ" -r '.session_id // empty' 2>/dev/null || echo "")
[ -n "$SID" ] || SID="default"

STATE_DIR="${ACHILLES_JUDGE_STATE_DIR:-$HOME/.claude/achilles/composition-judge}"
STATE_FILE="$STATE_DIR/${SID}.json"

read_state() {
  local s="{}"
  if [ -f "$STATE_FILE" ]; then
    s=$(cat "$STATE_FILE" 2>/dev/null || echo "{}")
    printf '%s' "$s" | "$JQ" -e 'type == "object"' >/dev/null 2>&1 || s="{}"
  fi
  printf '%s' "$s"
}

write_state() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  local tmp="$STATE_FILE.tmp.$$"
  printf '%s' "$1" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}

# ── Stop: the leash ─────────────────────────────────────────────────────
if [ "$EVENT" = "Stop" ]; then
  [ -f "$STATE_FILE" ] || exit 0
  STOP_ACTIVE=$(printf '%s' "$INPUT" | "$JQ" -r '.stop_hook_active // false' 2>/dev/null || echo "false")
  [ "$STOP_ACTIVE" = "true" ] && exit 0   # single-shot: never loop the session
  STATE=$(read_state)
  LAST=$(printf '%s' "$STATE" | "$JQ" -r '.last // "none"' 2>/dev/null || echo "none")
  CONSEC=$(printf '%s' "$STATE" | "$JQ" -r '.consecutiveNotSatisfied // 0' 2>/dev/null || echo 0)
  case "$CONSEC" in (*[!0-9]*|"") CONSEC=0 ;; esac
  if [ "$LAST" = "not-satisfied" ] && [ "$CONSEC" -ge 1 ] && [ "$CONSEC" -lt 3 ]; then
    REASON=""
    # read -d '' (not $(cat <<EOF)) — command substitution around a heredoc
    # mis-parses apostrophes under macOS bash 3.2.
    read -r -d '' REASON <<EOF || true
[BLOCKED] Composition-judge loop is still open — last verdict NOT SATISFIED (consecutive: ${CONSEC} of 3).

──────────────────────────────────────────────────────────────────
Do this instead — close the loop before stopping:
──────────────────────────────────────────────────────────────────

  Option A — fix and re-judge (the normal path)
    1. Fix the judge's [must-fix] findings in the specs under review.
    2. Re-run Stage 4a + 4b if code changed.
    3. Dispatch a FRESH composition-judge-<scope>: subagent (brief must
       cite schemas/subagent-returns/reviewer-inloop.schema.json).
  Option B — the loop already converged and this gate missed it
    The gate reads verdicts only from composition-judge-* returns.
    Re-dispatch the judge; a status: greenlight return clears the leash.

──────────────────────────────────────────────────────────────────
What was wrong:
──────────────────────────────────────────────────────────────────
File: ${STATE_FILE}
last verdict=not-satisfied, consecutive NOT SATISFIED=${CONSEC} (operator-escalation cap: 3)

Stage 4c forbids ending a composing session while an author↔judge loop
stands open below the 3-reject cap — stopping here abandons must-fix
findings nobody will pick up.

──────────────────────────────────────────────────────────────────
If you were stopping because "the findings can wait" — read this:
──────────────────────────────────────────────────────────────────
That framing is the judge-loop-skipping pattern. At 3 consecutive
NOT SATISFIED the sanctioned exit is operator escalation — this gate
allows Stop once the cap is reached.

References:
  skills/achilles-protocol/references/test-composition-standards.md §4
  skills/coverage-expansion/references/anti-rationalizations.md §"Judge-loop skipping"
EOF
    "$JQ" -n --arg r "$REASON" '{ "decision": "block", "reason": $r }'
    exit 0
  fi
  exit 0
fi

# ── Agent events: the ledger ────────────────────────────────────────────
[ "$TOOL_NAME" = "Agent" ] || exit 0
DESCRIPTION=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.description // ""' 2>/dev/null || echo "")
printf '%s' "$DESCRIPTION" | grep -qE '^[[:space:]]*composition-judge-' || exit 0

HAS_RESPONSE=$(printf '%s' "$INPUT" | "$JQ" -r 'has("tool_response")' 2>/dev/null || echo "false")
NOW=$(date +%s)
STATE=$(read_state)

if [ "$HAS_RESPONSE" != "true" ]; then
  # PreToolUse — record the dispatch.
  UPDATED=$(printf '%s' "$STATE" | "$JQ" -c --argjson now "$NOW" \
    '.dispatched = ((.dispatched // 0) + 1) | .ts = $now' 2>/dev/null || echo "")
  [ -n "$UPDATED" ] && write_state "$UPDATED"
  exit 0
fi

# PostToolUse — parse the judge's verdict from the return text.
RESPONSE_TEXT=$(printf '%s' "$INPUT" | "$JQ" -r '
  [
    (.tool_response.output? | if type == "array" then map(.text? // (. | tostring)) | join("\n") elif type == "string" then . else (. | tostring) end),
    (.tool_response.content? // empty | if type == "array" then map(.text? // (. | tostring)) | join("\n") else (. | tostring) end),
    (if (.tool_response | type) == "string" then .tool_response else empty end)
  ] | map(select(. != null and . != "null")) | join("\n")
' 2>/dev/null || echo "")

# Anchor the parse on the return's status line — a greenlight return that
# MENTIONS a prior cycle's improvements-needed verdict in prose must not
# be mis-recorded. Fall back to an anywhere-grep only when no status line
# is present at all.
VERDICT="unknown"
STATUS_TOKEN=$(printf '%s' "$RESPONSE_TEXT" | grep -oE '"?status"?[[:space:]]*:[[:space:]]*"?(greenlight|improvements-needed)"?' | head -1 || echo "")
if [ -n "$STATUS_TOKEN" ]; then
  case "$STATUS_TOKEN" in
    *improvements-needed*) VERDICT="not-satisfied" ;;
    *greenlight*)          VERDICT="satisfied" ;;
  esac
elif printf '%s' "$RESPONSE_TEXT" | grep -q 'improvements-needed'; then
  VERDICT="not-satisfied"
elif printf '%s' "$RESPONSE_TEXT" | grep -q 'greenlight'; then
  VERDICT="satisfied"
fi

case "$VERDICT" in
  not-satisfied)
    UPDATED=$(printf '%s' "$STATE" | "$JQ" -c --argjson now "$NOW" \
      '.last = "not-satisfied" | .consecutiveNotSatisfied = ((.consecutiveNotSatisfied // 0) + 1) | .verdicts = ((.verdicts // 0) + 1) | .ts = $now' 2>/dev/null || echo "") ;;
  satisfied)
    UPDATED=$(printf '%s' "$STATE" | "$JQ" -c --argjson now "$NOW" \
      '.last = "satisfied" | .consecutiveNotSatisfied = 0 | .verdicts = ((.verdicts // 0) + 1) | .ts = $now' 2>/dev/null || echo "") ;;
  *)
    UPDATED="" ;;  # unverdicted return — leave the ledger untouched (fail open)
esac
[ -n "$UPDATED" ] && write_state "$UPDATED"
exit 0
