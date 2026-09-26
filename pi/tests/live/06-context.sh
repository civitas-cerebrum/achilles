# pi/tests/live/06-context.sh — context budget: the achilles skill listing reaches the model compacted,
# and an Agent child's system prompt lists only the skill it was given. A recording proxy between pi
# and the model endpoint captures the exact requests (the system message the model sees).
export ACHILLES_PI_TEST_TIMEOUT="${ACHILLES_PI_TEST_TIMEOUT:-420}"
UPSTREAM="${ACHILLES_PI_TEST_BASE_URL:-http://localhost:8000/v1}"
PROXY_DIR=$(mktemp -d /tmp/achilles-proxy-XXXXXX)
node "$(dirname "${BASH_SOURCE[0]}")/record-proxy.mjs" "${UPSTREAM%/v1}" "$PROXY_DIR/requests.jsonl" "$PROXY_DIR/port" &
PROXY_PID=$!
for _ in $(seq 50); do [ -s "$PROXY_DIR/port" ] && break; sleep 0.1; done
export ACHILLES_PI_TEST_BASE_URL="http://127.0.0.1:$(cat "$PROXY_DIR/port")/v1"
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'kill $PROXY_PID 2>/dev/null; rm -rf "$PROXY_DIR"; [ "${ACHILLES_PI_KEEP_LIVE:-0}" = 1 ] || rm -rf "$LIVE_HOME"' EXIT
REQ="$PROXY_DIR/requests.jsonl"

out=$(live_pi "$LIVE_PROJECT" 'Use the Agent tool exactly once with description "scout: greet", skill "bug-report", and prompt "Reply with exactly the word OK". Then report the tool result verbatim.')
end=$(echo "$out" | grep '"type":"tool_execution_end"' | grep '"toolName":"Agent"' | head -1)
[ -n "$end" ] || live_fail "model did not call Agent: $(echo "$out" | tail -3 | cut -c1-300)"
grep -q '"isError":false' <<<"$end" || live_fail "Agent call errored: ${end:0:400}"
[ -s "$REQ" ] || live_fail "proxy recorded no requests"

# One line per request: <depth-guess> <skills-section chars> <achilles skill names listed>.
# The orchestrator's requests offer the Agent tool; a child's (--tools without Agent) do not.
report=$(node - "$REQ" "$LIVE_REPO/skills" <<'JS'
const fs = require('fs');
const [file, skillsDir] = process.argv.slice(2);
const achilles = new Set(fs.readdirSync(skillsDir));
for (const line of fs.readFileSync(file, 'utf8').split('\n').filter(Boolean)) {
  const r = JSON.parse(line);
  const sys = (r.messages ?? []).find((m) => m.role === 'system' || m.role === 'developer');
  if (!sys) continue;
  const text = typeof sys.content === 'string' ? sys.content : sys.content.map((c) => c.text ?? '').join('');
  const a = text.indexOf('The following skills provide'), b = text.indexOf('</available_skills>');
  const section = a >= 0 && b > a ? text.slice(a, b + 19) : '';
  const names = [...section.matchAll(/<name>([^<]+)<\/name>/g)].map((m) => m[1]).filter((n) => achilles.has(n));
  const parent = (r.tools ?? []).some((t) => (t.function?.name ?? t.name) === 'Agent');
  console.log(`${parent ? 'parent' : 'child'} ${text.length} ${section.length} ${names.join(',') || '-'}`);
}
JS
)
echo "$report" | sort -u | sed 's/^/  request: /'
parent=$(grep '^parent' <<<"$report" | head -1)
child=$(grep '^child' <<<"$report" | head -1)
[ -n "$parent" ] || live_fail "no orchestrator request recorded"
[ -n "$child" ] || live_fail "no child request recorded"
read -r _ psys psec pnames <<<"$parent"
read -r _ csys csec cnames <<<"$child"
[ "$(tr ',' '\n' <<<"$pnames" | grep -c .)" -eq 24 ] || live_fail "orchestrator does not list the 24 achilles skills: $pnames"
# Budget: the compact form is ~8k chars for 24 entries; pi's fixed per-skill markup (XML tags and the
# <location> path) is ~4.4k of that. The uncompacted listing is ~32k.
[ "$psec" -lt 8000 ] || live_fail "orchestrator skills section is $psec chars (want < 8000)"
# pi XML-escapes skill descriptions, so the quotes reach the model as &quot;.
grep -qF 'delegate with Agent { skill: &quot;workflow-reviewer&quot; }.' "$REQ" || live_fail "subagent-only delegate line missing from the orchestrator prompt"
# The hand-written pi-description routing lines (skills/*/SKILL.md) are what the model sees.
grep -qF '“the nightly failed”, “CI is red”): delegate with Agent { skill: &quot;failure-diagnosis&quot; }.' "$REQ" || live_fail "failure-diagnosis routing line missing from the orchestrator prompt"
[ "$cnames" = "bug-report" ] || live_fail "child lists achilles skills beyond the passed one: $cnames"
grep -q '"kind":"prompt_size","depth":"1".*"skills":\["bug-report"\]' "$ACHILLES_PI_LOG" || live_fail "child prompt_size log does not show only bug-report"
live_pass "skill listing compacted (orchestrator system ${psys} chars, skills section ${psec} chars); child lists only its skill (system ${csys} chars, skills section ${csec} chars)"
