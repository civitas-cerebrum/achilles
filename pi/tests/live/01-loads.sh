# pi/tests/live/01-loads.sh — the extension loads in a real pi and logs session_start.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
out=$(live_pi "$LIVE_PROJECT" "Reply with exactly the word OK and nothing else.")
grep -q '"type":"agent_settled"' <<<"$out" || live_fail "pi did not settle: $(echo "$out" | tail -3)"
grep -q '"kind":"session_start"' "$ACHILLES_PI_LOG" || live_fail "extension did not log session_start"
live_pass "extension loads and observes session_start"
