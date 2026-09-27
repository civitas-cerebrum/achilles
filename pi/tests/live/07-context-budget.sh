# pi/tests/live/07-context-budget.sh — a real turn keeps the skill load bounded, for the orchestrator
# AND for a subagent: Skill { skill: "coverage-expansion" } returns the skill's MAP (under 6,000
# chars, naming the always-required sections); a `section` fetch of a section over
# ACHILLES_PI_SECTION_MAX returns its own prose plus a listing of its subsections rather than 19,721
# chars in one go; a fetch of an always-required rule block still returns it WHOLE; and the same map,
# not the 89k body, is what a depth-1 child receives.
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

# A section over ACHILLES_PI_SECTION_MAX (19,721 chars here) is split: its own prose plus a listing of
# its subsections, each named so the follow-up fetch resolves. It must never claim to be the whole.
OUT2="$LIVE_HOME/07-section.jsonl"
live_pi "$LIVE_PROJECT" 'Call the Skill tool with skill "coverage-expansion" and section "five-pass pipeline". Then reply with exactly the word DONE. Do not follow the skill instructions.' > "$OUT2"
grep -q '"toolName":"Skill"' "$OUT2" || live_fail "model did not call Skill with a section: $(tail -3 "$OUT2" | cut -c1-300)"
section=$(skill_result "$OUT2")
[ -n "$section" ] || live_fail "no sectioned Skill tool result recorded"
schars=${#section}
[ "$schars" -lt 12000 ] || live_fail "five-pass pipeline fetch is $schars chars (want < 12000: it should be split)"
grep -qF 'view="section"' <<<"$section" || live_fail "section is not marked as a section view"
grep -qF '## Standard mode' <<<"$section" || live_fail "section does not start at the Standard mode heading"
grep -qF 'NOT the whole section' <<<"$section" || live_fail "a split section did not say it is incomplete"
grep -qF 'Hard rules — kernel-resident' <<<"$section" || live_fail "the split section does not name its required subsection"
grep -qF 'fetch each before you act' <<<"$section" || live_fail "a required subsection was dropped without a fetch-first line"
grep -qF '## Breadth mode' <<<"$section" && live_fail "section ran past the next top-level heading"
grep -q '"kind":"skill".*"view":"section"' "$ACHILLES_PI_LOG" || live_fail "no sectioned skill load in the log"

# An always-required rule block is NEVER split, whatever its size: a part of a rule block reads as a
# different rule. "Two valid exits — read this before anything else" is 15,200 chars and comes whole.
OUT3="$LIVE_HOME/07-rules.jsonl"
live_pi "$LIVE_PROJECT" 'Call the Skill tool with skill "coverage-expansion" and section "Two valid exits". Then reply with exactly the word DONE. Do not follow the skill instructions.' > "$OUT3"
rules=$(skill_result "$OUT3")
[ -n "$rules" ] || live_fail "no rule-block Skill tool result recorded"
rchars=${#rules}
[ "$rchars" -gt 12000 ] || live_fail "the required rule block came back at $rchars chars (want it whole, > 12000)"
grep -qF 'returned whole rather than split' <<<"$rules" || live_fail "the rule block does not say why it was not split"
grep -qF 'Stage A per-journey dispatch is non-negotiable' <<<"$rules" || live_fail "the rule block lost its subsections"
grep -qF 'NOT the whole section' <<<"$rules" && live_fail "a whole rule block was labelled incomplete"

# Same bound for a subagent: at depth 1 the child gets the map, not 89k chars of body.
OUT4="$LIVE_HOME/07-child.jsonl"
ACHILLES_PI_DEPTH=1 live_pi "$LIVE_PROJECT" 'Call the Skill tool with skill "coverage-expansion" and no section. Then reply with exactly the word DONE. Do not follow the skill instructions.' > "$OUT4"
grep -q '"toolName":"Skill"' "$OUT4" || live_fail "child did not call Skill: $(tail -3 "$OUT4" | cut -c1-300)"
child=$(skill_result "$OUT4")
[ -n "$child" ] || live_fail "no child Skill tool result recorded"
cchars=${#child}
[ "$cchars" -lt 6000 ] || live_fail "the depth-1 coverage-expansion load is $cchars chars (want < 6000)"
grep -qF 'view="map"' <<<"$child" || live_fail "the child did not get a map"
grep -qF 'Slug-length constraint' <<<"$child" && live_fail "the full skill body leaked into the child's map"
grep -qF 'Two valid exits' <<<"$child" || live_fail "the child's map omits the always-required section"

live_pass "coverage-expansion map ${chars} chars (body ~89k), five-pass split to ${schars}, rule block whole at ${rchars}, child map ${cchars}"
