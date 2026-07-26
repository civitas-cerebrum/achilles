#!/bin/bash
# Tests for atelier-telemetry-collector.sh — harness-atelier telemetry
# observer. Always silent-allow; the side effect is one JSONL line per
# context transfer in <project>/.achilles/atelier-telemetry.jsonl.
H="$HOOK_DIR/atelier-telemetry-collector.sh"

TMPAT=$(mktemp -d)
trap 'rm -rf "$TMPAT"' EXIT
( cd "$TMPAT" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init ) >/dev/null 2>&1
# Opt in via the GENERIC marker (not the achilles markers) — atelier is a
# general utility; any Claude Code experiment can `touch .atelier`.
touch "$TMPAT/.atelier"
LOG="$TMPAT/.achilles/atelier-telemetry.jsonl"

last_line() { tail -1 "$LOG" 2>/dev/null; }

section "atelier-collector: dispatch events record brief bytes + role"
rm -rf "$TMPAT/.achilles"
P=$(payload tool_name=Agent hook_event_name=PreToolUse description='composer-j-checkout-1-c1: compose the checkout journey' prompt='You are the composer. Read the journey block and compose the portfolio.' cwd="$TMPAT")
P=$(echo "$P" | "$JQ" -c '. + {tool_use_id: "toolu_d1"}')
assert_allow "$H" "$P" "dispatch → silent allow"
assert_eq "$(last_line | "$JQ" -r '.event')" "dispatch" "event = dispatch"
assert_eq "$(last_line | "$JQ" -r '.dispatch_role')" "composer" "dispatch_role = composer"
assert_eq "$(last_line | "$JQ" -r '.actor')" "orchestrator" "actor = orchestrator"
BRIEF=$(last_line | "$JQ" -r '.brief_bytes')
TESTS_RUN=$((TESTS_RUN+1))
if [ "$BRIEF" -gt 80 ] 2>/dev/null; then TESTS_PASSED=$((TESTS_PASSED+1)); echo "${CLR_PASS}  ✓${CLR_RST} brief_bytes counts prompt+description ($BRIEF)"; else TESTS_FAILED=$((TESTS_FAILED+1)); echo "${CLR_FAIL}  ✗${CLR_RST} brief_bytes wrong: $BRIEF"; fi

section "atelier-collector: nested dispatch records the dispatching agent as actor"
P=$(payload tool_name=Agent hook_event_name=PreToolUse description='helper: side quest' prompt='x' cwd="$TMPAT" agent_id=sub_c)
P=$(echo "$P" | "$JQ" -c '. + {tool_use_id: "toolu_d2"}')
assert_allow "$H" "$P" "nested dispatch → silent allow"
assert_eq "$(last_line | "$JQ" -r '.actor')" "sub_c" "actor = dispatching agent_id"

section "atelier-collector: clean return records return bytes, no leak"
P=$(payload tool_name=Agent hook_event_name=PostToolUse description='composer-j-checkout-1-c1: compose' response_content='status: complete
handover:
  cycle: 1
tests-created: 4' cwd="$TMPAT")
P=$(echo "$P" | "$JQ" -c '. + {tool_use_id: "toolu_d1"}')
assert_allow "$H" "$P" "return → silent allow"
assert_eq "$(last_line | "$JQ" -r '.event')" "return" "event = return"
assert_eq "$(last_line | "$JQ" -r 'has("leak")')" "false" "clean return carries no leak"
RB=$(last_line | "$JQ" -r '.return_bytes')
TESTS_RUN=$((TESTS_RUN+1))
if [ "$RB" -gt 0 ] 2>/dev/null; then TESTS_PASSED=$((TESTS_PASSED+1)); echo "${CLR_PASS}  ✓${CLR_RST} return_bytes recorded ($RB)"; else TESTS_FAILED=$((TESTS_FAILED+1)); echo "${CLR_FAIL}  ✗${CLR_RST} return_bytes missing"; fi

section "atelier-collector: leak channels on the return path"
BIG=$(printf 'x%.0s' $(seq 1 9000))
P=$(payload tool_name=Agent hook_event_name=PostToolUse description='probe-j-checkout-4: probe' response_content="$BIG" cwd="$TMPAT")
assert_allow "$H" "$P" "oversized return → silent allow"
assert_eq "$(last_line | "$JQ" -r '.leak.channel')" "oversized-return" "oversized return flagged"
# The %d + %.0s pair consumes two args per iteration → 100 lines ≈ 1900
# chars of fenced body, comfortably over the 1200-char paste threshold.
PASTED="summary ok
\`\`\`ts
$(printf 'const line%03d = 1;\n%.0s' $(seq 1 200))
\`\`\`"
P=$(payload tool_name=Agent hook_event_name=PostToolUse description='composer-j-x-1-c1: compose' response_content="$PASTED" cwd="$TMPAT")
assert_allow "$H" "$P" "pasted-source return → silent allow"
assert_eq "$(last_line | "$JQ" -r '.leak.channel')" "pasted-source-return" "pasted source block flagged"

section "atelier-collector: orchestrator bash-ingest leak (executed dump)"
P=$(payload tool_name=Bash hook_event_name=PostToolUse command='cat tests/e2e/journeys/checkout.spec.ts' stdout='test("x", ...)' cwd="$TMPAT")
assert_allow "$H" "$P" "orchestrator dump command → silent allow"
assert_eq "$(last_line | "$JQ" -r '.event')" "command" "event = command"
assert_eq "$(last_line | "$JQ" -r '.leak.channel')" "bash-ingest" "executed orchestrator dump flagged as bash-ingest"
P=$(payload tool_name=Bash hook_event_name=PostToolUse command='wc -l tests/e2e/journeys/checkout.spec.ts' stdout='42' cwd="$TMPAT")
assert_allow "$H" "$P" "metadata read → silent allow"
assert_eq "$(last_line | "$JQ" -r 'has("leak")')" "false" "metadata read carries no leak"

section "atelier-collector: subagent commands attribute to their context, never bash-ingest"
mkdir -p "$TMPAT/.achilles"
NOW=$(date +%s)
echo "{\"toolu_rev\": {\"role\": \"reviewer-inloop\", \"denied\": [], \"ts\": $NOW}}" > "$TMPAT/.achilles/.agent-process-table.json"
P=$(payload tool_name=Bash hook_event_name=PostToolUse command='cat tests/e2e/journeys/checkout.spec.ts' stdout='src' cwd="$TMPAT" agent_id=sub_r parent_tool_use_id=toolu_rev)
assert_allow "$H" "$P" "subagent dump of own slice → silent allow"
assert_eq "$(last_line | "$JQ" -r '.actor')" "sub_r" "actor = subagent id"
assert_eq "$(last_line | "$JQ" -r '.role')" "reviewer-inloop" "role resolved via process table"
assert_eq "$(last_line | "$JQ" -r 'has("leak")')" "false" "subagent ingest is not a leak (own context)"

section "atelier-collector: off switch"
COUNT_BEFORE=$(wc -l < "$LOG")
OFF_OUT=$(printf '%s' "$(payload tool_name=Bash hook_event_name=PostToolUse command='ls' stdout='x' cwd="$TMPAT")" | ATELIER_TELEMETRY=off bash "$H" 2>/dev/null)
assert_eq "$OFF_OUT" "" "ATELIER_TELEMETRY=off → silent allow"
assert_eq "$(wc -l < "$LOG")" "$COUNT_BEFORE" "off switch writes nothing"

section "atelier-collector: skill events segment context consumption"
P=$(payload tool_name=Skill hook_event_name=PostToolUse skill='journey-mapping' response_text='...skill instructions loaded into context...' cwd="$TMPAT")
assert_allow "$H" "$P" "Skill invocation → silent allow"
assert_eq "$(last_line | "$JQ" -r '.event')" "skill" "event = skill"
assert_eq "$(last_line | "$JQ" -r '.skill')" "journey-mapping" "skill name recorded"
SKB=$(last_line | "$JQ" -r '.bytes_out')
TESTS_RUN=$((TESTS_RUN+1))
if [ "$SKB" -gt 0 ] 2>/dev/null; then TESTS_PASSED=$((TESTS_PASSED+1)); echo "${CLR_PASS}  ✓${CLR_RST} skill bytes_out recorded ($SKB)"; else TESTS_FAILED=$((TESTS_FAILED+1)); echo "${CLR_FAIL}  ✗${CLR_RST} skill bytes_out missing"; fi

section "atelier-collector: generic tool events record context ingestion"
P=$(payload tool_name=Read hook_event_name=PostToolUse file_path='/x/src/app.ts' response_text='file content pulled into the window' cwd="$TMPAT")
assert_allow "$H" "$P" "Read → silent allow"
assert_eq "$(last_line | "$JQ" -r '.event')" "tool" "event = tool"
assert_eq "$(last_line | "$JQ" -r '.tool')" "Read" "tool name recorded"
TESTS_RUN=$((TESTS_RUN+1))
[ "$(last_line | "$JQ" -r '.bytes_out')" -gt 0 ] 2>/dev/null && { TESTS_PASSED=$((TESTS_PASSED+1)); echo "${CLR_PASS}  ✓${CLR_RST} tool bytes_out recorded"; } || { TESTS_FAILED=$((TESTS_FAILED+1)); echo "${CLR_FAIL}  ✗${CLR_RST} tool bytes_out missing"; }

section "atelier-collector: not opted in → inert (general-utility scoping)"
PLAINAT=$(mktemp -d)
( cd "$PLAINAT" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init ) >/dev/null 2>&1
assert_allow "$H" "$(payload tool_name=Bash hook_event_name=PostToolUse command='ls' stdout='x' cwd="$PLAINAT")" "plain repo, no marker → silent allow"
TESTS_RUN=$((TESTS_RUN+1))
[ ! -d "$PLAINAT/.achilles" ] && { TESTS_PASSED=$((TESTS_PASSED+1)); echo "${CLR_PASS}  ✓${CLR_RST} no telemetry written without opt-in"; } || { TESTS_FAILED=$((TESTS_FAILED+1)); echo "${CLR_FAIL}  ✗${CLR_RST} telemetry written without opt-in"; }
FORCED=$(printf '%s' "$(payload tool_name=Bash hook_event_name=PostToolUse command='ls' stdout='x' cwd="$PLAINAT")" | ATELIER_TELEMETRY=on bash "$H" 2>/dev/null)
TESTS_RUN=$((TESTS_RUN+1))
if [ -z "$FORCED" ] && [ -f "$PLAINAT/.achilles/atelier-telemetry.jsonl" ]; then TESTS_PASSED=$((TESTS_PASSED+1)); echo "${CLR_PASS}  ✓${CLR_RST} ATELIER_TELEMETRY=on forces collection anywhere"; else TESTS_FAILED=$((TESTS_FAILED+1)); echo "${CLR_FAIL}  ✗${CLR_RST} forced collection failed"; fi
rm -rf "$PLAINAT"
