#!/bin/bash
# Tests for composition-judge-gate.sh — Stage 4c judge-loop leash.
#
# RECORD on Agent events (silent allow always), DENY-shaped Stop block
# ({"decision":"block"}) while a judge loop is open on NOT SATISFIED
# below the 3-reject cap. State is per-session JSON under
# ACHILLES_JUDGE_STATE_DIR (env override used here).
H="$HOOK_DIR/composition-judge-gate.sh"

CJG_STATE=$(mktemp -d)
export ACHILLES_JUDGE_STATE_DIR="$CJG_STATE"
export ACHILLES_PROTOCOL=1

section "composition-judge-gate: dispatch recording (PreToolUse:Agent)"
assert_allow "$H" "$(payload session_id=cjg-s1 tool_name=Agent description='composition-judge-j-flow: judge pass-1 specs' prompt='cite schemas/subagent-returns/reviewer-inloop.schema.json')" "judge dispatch → silent allow + record"
assert_eq "$("$JQ" -r '.dispatched // 0' "$CJG_STATE/cjg-s1.json" 2>/dev/null)" "1" "state records dispatched=1"
assert_allow "$H" "$(payload session_id=cjg-s1 tool_name=Agent description='composer-j-flow: compose variants')" "non-judge dispatch → silent allow, not recorded"
assert_eq "$("$JQ" -r '.dispatched // 0' "$CJG_STATE/cjg-s1.json" 2>/dev/null)" "1" "non-judge dispatch does not bump the counter"

section "composition-judge-gate: verdict recording (PostToolUse:Agent)"
assert_allow "$H" "$(payload session_id=cjg-s1 tool_name=Agent description='composition-judge-j-flow: judge pass-1 specs' response_text='handover: {status: improvements-needed} findings: ...')" "NOT SATISFIED return → silent allow + record"
assert_eq "$("$JQ" -r '.last // ""' "$CJG_STATE/cjg-s1.json" 2>/dev/null)" "not-satisfied" "state records last=not-satisfied"
assert_eq "$("$JQ" -r '.consecutiveNotSatisfied // 0' "$CJG_STATE/cjg-s1.json" 2>/dev/null)" "1" "consecutive counter = 1"

section "composition-judge-gate: Stop blocked while the loop is open"
assert_stop_block "$H" "$(payload session_id=cjg-s1 hook_event_name=Stop)" "Stop on open loop (1 of 3) → block" "Composition-judge loop is still open"
# Single-shot: a repeat Stop with stop_hook_active must not loop the session.
assert_allow "$H" "$("$JQ" -c -n '{session_id:"cjg-s1", hook_event_name:"Stop", stop_hook_active:true}')" "Stop with stop_hook_active → silent allow (no infinite loop)"

section "composition-judge-gate: SATISFIED clears the leash"
assert_allow "$H" "$(payload session_id=cjg-s1 tool_name=Agent description='composition-judge-j-flow: re-judge cycle 2' response_text='status: greenlight summary: all four dimensions satisfied')" "SATISFIED return → silent allow + record"
assert_eq "$("$JQ" -r '.consecutiveNotSatisfied // -1' "$CJG_STATE/cjg-s1.json" 2>/dev/null)" "0" "SATISFIED resets the consecutive counter"
assert_allow "$H" "$(payload session_id=cjg-s1 hook_event_name=Stop)" "Stop after SATISFIED → silent allow"

section "composition-judge-gate: the 3-reject cap sanctions operator escalation"
for _ in 1 2 3; do
  printf '%s' "$(payload session_id=cjg-s2 tool_name=Agent description='composition-judge-j-x: judge' response_text='improvements-needed')" | bash "$H" >/dev/null 2>&1
done
assert_eq "$("$JQ" -r '.consecutiveNotSatisfied // 0' "$CJG_STATE/cjg-s2.json" 2>/dev/null)" "3" "three rejects recorded"
assert_allow "$H" "$(payload session_id=cjg-s2 hook_event_name=Stop)" "Stop at the cap (3 of 3) → silent allow (escalate to operator)"

section "composition-judge-gate: unverdicted / adjacent traffic stays silent"
assert_allow "$H" "$(payload session_id=cjg-s3 tool_name=Agent description='composition-judge-j-y: judge' response_text='no recognisable verdict tokens here')" "unverdicted judge return → silent allow, ledger untouched"
assert_allow "$H" "$(payload session_id=cjg-s3 hook_event_name=Stop)" "Stop with no verdict on record → silent allow"
assert_allow "$H" "$(payload session_id=cjg-s4 hook_event_name=Stop)" "Stop with no judge state at all → silent allow"
assert_allow "$H" "" "empty stdin → silent allow"
assert_allow "$H" "not-json" "invalid JSON → silent allow"

unset ACHILLES_PROTOCOL
unset ACHILLES_JUDGE_STATE_DIR
rm -rf "$CJG_STATE"
