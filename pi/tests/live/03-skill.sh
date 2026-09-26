# pi/tests/live/03-skill.sh — Skill tool routes by class and trips the activation watcher.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
out=$(live_pi "$LIVE_PROJECT" 'Call the Skill tool with skill "workflow-reviewer" and report the tool result verbatim. Do not do anything else.')
end=$(echo "$out" | grep '"type":"tool_execution_end"' | grep '"toolName":"Skill"' | head -1)
[ -n "$end" ] || live_fail "model did not call Skill: $(echo "$out" | tail -3 | cut -c1-300)"
grep -q 'subagent-only' <<<"$end" || live_fail "workflow-reviewer was not refused: ${end:0:300}"
grep -q 'Owns the 3-cycle' <<<"$end" && live_fail "subagent-only body leaked into the orchestrator"
out=$(live_pi "$LIVE_PROJECT" 'Call the Skill tool with skill "onboarding" and then reply with exactly the word DONE. Do not follow the skill instructions.')
end=$(echo "$out" | grep '"type":"tool_execution_end"' | grep '"toolName":"Skill"' | head -1)
grep -q '<skill name=\\"onboarding\\"' <<<"$end" || live_fail "onboarding body not returned: ${end:0:300}"
ls "$ACHILLES_SESSION_STATE_DIR"/*.active >/dev/null 2>&1 || live_fail "activation watcher did not mark the session active"
grep -q '"hook":"achilles-protocol-activation-watcher.sh"' "$ACHILLES_PI_LOG" || live_fail "watcher hook did not run on PreToolUse:Skill"
live_pass "Skill tool refuses subagent-only skills, returns orchestrator skills, activates the protocol"
