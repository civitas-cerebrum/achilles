# pi/tests/live/07-context-budget.sh — a real turn keeps the orchestrator's skill load bounded:
# Skill { skill: "coverage-expansion" } returns the skill's MAP (under 6,000 chars, naming the
# always-required sections), and a follow-up `section` fetch returns the five-pass pipeline in full.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The tool result as the model saw it: the text of the Skill tool_execution_end event, JSON-decoded.
skill_result() {
  node - "$1" <<'JS'
const fs = require('fs');
for (const line of fs.readFileSync(process.argv[2], 'utf8').split('\n').filter(Boolean)) {
  let ev; try { ev = JSON.parse(line); } catch { continue; }
  if (ev.type !== 'tool_execution_end' || ev.toolName !== 'Skill') continue;
  const content = ev.result?.content ?? ev.content ?? [];
  const text = (Array.isArray(content) ? content : [content]).map((c) => c?.text ?? '').join('\n');
  if (text) { process.stdout.write(text); break; }
}
JS
}

OUT="$LIVE_HOME/07-map.jsonl"
live_pi "$LIVE_PROJECT" 'Call the Skill tool with skill "coverage-expansion" and no section. Then reply with exactly the word DONE. Do not follow the skill instructions.' > "$OUT"
grep -q '"toolName":"Skill"' "$OUT" || live_fail "model did not call Skill: $(tail -3 "$OUT" | cut -c1-300)"
map=$(skill_result "$OUT")
[ -n "$map" ] || live_fail "no Skill tool result recorded"
chars=${#map}
[ "$chars" -lt 6000 ] || live_fail "coverage-expansion map is $chars chars (want < 6000)"
grep -qF 'Two valid exits' <<<"$map" || live_fail "map does not name the 'Two valid exits' section"
grep -qF 'view="map"' <<<"$map" || live_fail "map is not marked as a map view"
grep -qF 'section: "<heading>"' <<<"$map" || live_fail "map does not tell the model how to fetch a section"
# The whole body must NOT be there: its later sections are only listed, not pasted.
grep -qF 'Slug-length constraint' <<<"$map" && live_fail "the full skill body leaked into the map"

OUT2="$LIVE_HOME/07-section.jsonl"
live_pi "$LIVE_PROJECT" 'Call the Skill tool with skill "coverage-expansion" and section "five-pass pipeline". Then reply with exactly the word DONE. Do not follow the skill instructions.' > "$OUT2"
grep -q '"toolName":"Skill"' "$OUT2" || live_fail "model did not call Skill with a section: $(tail -3 "$OUT2" | cut -c1-300)"
section=$(skill_result "$OUT2")
[ -n "$section" ] || live_fail "no sectioned Skill tool result recorded"
schars=${#section}
[ "$schars" -gt 5000 ] || live_fail "five-pass pipeline section is $schars chars (want > 5000)"
grep -qF 'view="section"' <<<"$section" || live_fail "section is not marked as a section view"
grep -qF '## Standard mode' <<<"$section" || live_fail "section does not start at the Standard mode heading"
grep -qF '## Breadth mode' <<<"$section" && live_fail "section ran past the next top-level heading"
grep -q '"kind":"skill".*"view":"section"' "$ACHILLES_PI_LOG" || live_fail "no sectioned skill load in the log"

live_pass "coverage-expansion map ${chars} chars (body ~89k), five-pass section ${schars} chars"
