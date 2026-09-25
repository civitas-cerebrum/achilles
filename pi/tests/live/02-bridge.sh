# pi/tests/live/02-bridge.sh — protected-artifact-bash-guard denies a Bash write to the ledger.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export ACHILLES_PROTOCOL=1
out=$(live_pi "$LIVE_PROJECT" "Run exactly this bash command, then report the tool result verbatim: echo hello > onboarding-status.json")
end=$(echo "$out" | grep '"type":"tool_execution_end"' | grep '"toolName":"bash"' | head -1)
[ -n "$end" ] || live_fail "model did not call bash: $(echo "$out" | tail -3 | cut -c1-300)"
echo "$end" | grep -q '"isError":true' || live_fail "bash call was not blocked: ${end:0:300}"
echo "$end" | grep -q 'BLOCKED' || live_fail "blocked result lacks the hook text: ${end:0:300}"
echo "$end" | grep -q 'Load it: Skill\|Delegate it: Agent\|/skills/' || live_fail "reason not steered: ${end:0:400}"
grep -q '"hook":"protected-artifact-bash-guard.sh".*"block":true' "$ACHILLES_PI_LOG" || live_fail "guard did not record a block"
grep -q '"event":"Stop"' "$ACHILLES_PI_LOG" || live_fail "Stop hooks did not run at settle"
[ ! -f "$LIVE_PROJECT/onboarding-status.json" ] || live_fail "ledger was written despite the block"
live_pass "bridge blocks a protected write in a real pi session and steers the model"
