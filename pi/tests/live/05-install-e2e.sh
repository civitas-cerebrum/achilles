# pi/tests/live/05-install-e2e.sh — npm pack + install into a temp project with a fake ~/.pi/agent; pi loads the
# extension through the settings entry (no -e). Skips chromium and jq downloads; jq comes from PATH.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
tgz=$(cd "$LIVE_REPO" && npm pack --ignore-scripts --silent 2>/dev/null | tail -1)
[ -f "$LIVE_REPO/$tgz" ] || live_fail "npm pack produced nothing"
proj="$LIVE_HOME/consumer"; mkdir -p "$proj" && cd "$proj" && npm init -y >/dev/null
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 CIVITAS_SKIP_JQ_INSTALL=1 npm install --no-audit --no-fund "$LIVE_REPO/$tgz" > "$LIVE_HOME/npm.log" 2>&1 || live_fail "npm install failed: $(tail -5 "$LIVE_HOME/npm.log")"
rm -f "$LIVE_REPO/$tgz"
grep -q 'node_modules/@civitas-cerebrum/achilles/pi' "$proj/.pi/settings.json" || live_fail "pi package not registered in project .pi/settings.json"
[ -f "$proj/.claude/hooks/protected-artifact-bash-guard.sh" ] || live_fail "hooks not installed in project"
[ -f "$LIVE_HOME/.agents/skills/onboarding/SKILL.md" ] || live_fail "skills not installed to ~/.agents/skills"
# Checks use here-strings, not `echo "$out" | grep -q`: lib.sh sets pipefail, and grep -q exiting on an
# early match SIGPIPEs echo on large outputs, which fails the pipeline even though the text was found.
out=$(cd "$proj" && timeout "$LIVE_TIMEOUT" pi --mode json -p --no-session -a --model "$LIVE_MODEL" --thinking off "Reply with exactly the word OK and nothing else.")
grep -q '"type":"agent_settled"' <<<"$out" || live_fail "pi did not settle in the consumer project"
grep -q 'Agent: dispatch a subagent' <<<"$out" || live_fail "Agent tool not advertised in the system prompt"
grep -q '"kind":"bridge_ready"' "$ACHILLES_PI_LOG" || live_fail "extension did not load from the settings entry"
live_pass "postinstall registers the pi package and pi loads it from settings"
