#!/bin/bash
# Tests for hook-authored-state-guard.sh — denies direct Write|Edit to the
# approver registry + integrity sidecar, and gates monotonicity of the
# cycle/coverage progress files. PreToolUse:Write|Edit. DENY mode.
H="$HOOK_DIR/hook-authored-state-guard.sh"

TMP_HAS=$(mktemp -d /tmp/hook-authored-state-XXXXXX)
mkdir -p "$TMP_HAS/tests/e2e/docs"
trap 'rm -rf "$TMP_HAS"' EXIT
DOCS="$TMP_HAS/tests/e2e/docs"

wpayload() { "$JQ" -n --arg p "$1" --arg c "$2" '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}'; }

section "hook-authored-state-guard: tool-name filtering"
assert_allow "$H" "$(payload tool_name=Bash command='ls')" "Bash → silent allow"
assert_allow "$H" "$(payload tool_name=Read file_path="$DOCS/.workflow-approvers.json")" "Read → silent allow"

section "hook-authored-state-guard: hook-authored state is never Write|Edit"
assert_deny "$H" "$(wpayload "$DOCS/.workflow-approvers.json" '{}')" "Write .workflow-approvers.json → DENY" "hook-authored state"
assert_deny "$H" "$(wpayload "$DOCS/.ledger-integrity.json" '{}')" "Write .ledger-integrity.json → DENY" "hook-authored state"
# Bare relative form normalises and is still denied.
assert_deny "$H" "$(wpayload "tests/e2e/docs/.workflow-approvers.json" '{}')" "relative .workflow-approvers.json → DENY" "hook-authored state"

section "hook-authored-state-guard: cycle-state monotonicity"
CYCLE="$DOCS/.phase4-cycle-state.json"
rm -f "$CYCLE"
# First write with non-empty returned-sections → DENY (returns predate dispatch).
assert_deny "$H" "$(wpayload "$CYCLE" '{"cycles":{"1":{"dispatched-sections":["a"],"returned-sections":["a"]}}}')" \
  "first cycle-state write with non-empty returned-sections → DENY" "predate"
# Legit first write: dispatch only, returns empty → ALLOW.
assert_allow "$H" "$(wpayload "$CYCLE" '{"cycles":{"1":{"dispatched-sections":["a","b"],"returned-sections":[]}}}')" \
  "first cycle-state write, dispatch only → ALLOW"
# Establish a prior on disk, then a shrinking rewrite → DENY.
printf '%s' '{"cycles":{"1":{"dispatched-sections":["a","b","c"],"returned-sections":["a","b"]}}}' > "$CYCLE"
assert_deny "$H" "$(wpayload "$CYCLE" '{"cycles":{"1":{"dispatched-sections":["a"],"returned-sections":["a"]}}}')" \
  "cycle-state dispatched-sections shrink (3→1) → DENY" "shrinks or rewrites"
# Growth (adding a return) → ALLOW.
assert_allow "$H" "$(wpayload "$CYCLE" '{"cycles":{"1":{"dispatched-sections":["a","b","c"],"returned-sections":["a","b","c"]}}}')" \
  "cycle-state returned-sections grow (2→3) → ALLOW"

section "hook-authored-state-guard: coverage-state monotonicity"
COV="$DOCS/coverage-expansion-state.json"
rm -f "$COV"
assert_deny "$H" "$(wpayload "$COV" '{"passes":{"1":{"dispatched-journeys":["j-x"],"returned-journeys":["j-x"]}}}')" \
  "first coverage-state write with non-empty returned-journeys → DENY" "predate"
assert_allow "$H" "$(wpayload "$COV" '{"passes":{"1":{"dispatched-journeys":["j-x","j-y"],"returned-journeys":[]}}}')" \
  "first coverage-state write, dispatch only → ALLOW"
printf '%s' '{"passes":{"1":{"dispatched-journeys":["j-x","j-y"],"returned-journeys":["j-x"]}}}' > "$COV"
assert_deny "$H" "$(wpayload "$COV" '{"passes":{"1":{"dispatched-journeys":["j-x"],"returned-journeys":["j-x"]}}}')" \
  "coverage-state dispatched-journeys shrink (2→1) → DENY" "shrinks or rewrites"
assert_allow "$H" "$(wpayload "$COV" '{"passes":{"1":{"dispatched-journeys":["j-x","j-y"],"returned-journeys":["j-x","j-y"]}}}')" \
  "coverage-state returned-journeys grow (1→2) → ALLOW"

section "hook-authored-state-guard: unrelated paths silent-allow"
assert_allow "$H" "$(wpayload "/tmp/whatever.json" '{}')" "unrelated json write → ALLOW"

rm -rf "$TMP_HAS"
