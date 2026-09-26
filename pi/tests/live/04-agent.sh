# pi/tests/live/04-agent.sh — Agent tool: real child pi, gates inside it, SubagentStop at its settle.
# A child run doubles the model time, so this check gets a longer default budget than lib.sh's 180 s.
export ACHILLES_PI_TEST_TIMEOUT="${ACHILLES_PI_TEST_TIMEOUT:-420}"
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
out=$(live_pi "$LIVE_PROJECT" 'Use the Agent tool once with description "scout: greet" and prompt "Run the bash command `echo hi` and then reply with exactly the word OK". Then report the tool result verbatim.')
end=$(echo "$out" | grep '"type":"tool_execution_end"' | grep '"toolName":"Agent"' | head -1)
[ -n "$end" ] || live_fail "model did not call Agent: $(echo "$out" | tail -3 | cut -c1-300)"
grep -q '"isError":false' <<<"$end" || live_fail "Agent call errored: ${end:0:400}"
grep -q 'OK' <<<"$end" || live_fail "child text missing: ${end:0:300}"
grep -q '"kind":"session_start".*"depth":"1"' "$ACHILLES_PI_LOG" || live_fail "extension did not load inside the child"
grep -q '"kind":"hook".*"tool":"Bash".*"depth":"1"' "$ACHILLES_PI_LOG" || live_fail "PreToolUse hooks did not run inside the child"
grep '"kind":"hook"' "$ACHILLES_PI_LOG" | grep '"depth":"1"' | grep '"agentType":"scout"' >/dev/null || live_fail "child hooks did not see agent_type scout"
grep -q '"kind":"hook","event":"SubagentStop".*"depth":"1"' "$ACHILLES_PI_LOG" || live_fail "SubagentStop hooks did not run inside the child at its settle"
grep '"kind":"hook","event":"SubagentStop"' "$ACHILLES_PI_LOG" | grep -v '"depth":"1"' >/dev/null && live_fail "SubagentStop also ran outside the child"
grep -q '"kind":"hook","event":"Stop".*"depth":"1"' "$ACHILLES_PI_LOG" && live_fail "Stop hooks ran inside the child"
live_pass "Agent tool runs a real child with gates inside and SubagentStop at the child's settle"
