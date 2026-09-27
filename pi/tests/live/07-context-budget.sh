# pi/tests/live/07-context-budget.sh — a real turn keeps the skill load bounded, for the orchestrator
# AND for a subagent: Skill { skill: "coverage-expansion" } returns the skill's MAP (under 6,000
# chars, naming the always-required sections); a `section` fetch of a section over
# ACHILLES_PI_SECTION_MAX returns its own prose plus a listing of its subsections rather than 19,721
# chars in one go; a fetch of an always-required rule block still returns it WHOLE; and the same map,
# not the 89k body, is what a REAL nested child receives (dispatched through the Agent tool, measured
# in the shared log by the depth each Skill load happened at).
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

# Same bound for a subagent — and asserted by NESTING A REAL CHILD, not by setting ACHILLES_PI_DEPTH=1
# on an orchestrator-shaped session (round 4 simulated it; that was concern 5 of its report). The
# orchestrator dispatches through the Agent tool, agent-tool.ts spawns a real `pi` child, and the
# child's own Skill call is what is measured. Measured cost on the local 27B: 19 s for this turn (two
# model turns, parent then child) — inside the live budget, so there is no reason to simulate it.
#
# The role prefix is "scout:" on purpose: a schema-validated prefix (probe-, composer-, reviewer-, …)
# is blocked by subagent-schema-preread-gate.sh until the orchestrator has read the return schema,
# which is a different check's business and would make this one assert the wrong thing.
#
# The child's map is not in this process's event stream (a child's events are consumed by the parent),
# so the evidence is the shared $ACHILLES_PI_LOG, where every Skill load records the depth it happened
# at. That is also the only thing that distinguishes the two maps: they are byte-identical by design.
OUT4="$LIVE_HOME/07-child.jsonl"
live_pi "$LIVE_PROJECT" 'Use the Agent tool once with description "scout: check the skill load", skill "coverage-expansion", and prompt "Call the Skill tool with skill coverage-expansion and no section. Then reply with exactly the word DONE." Then reply with exactly the word DONE.' > "$OUT4"
grep -q '"toolName":"Agent"' "$OUT4" || live_fail "model did not dispatch a child: $(tail -3 "$OUT4" | cut -c1-300)"
grep -q '"kind":"agent_spawn".*"skill":"coverage-expansion".*"depth":1' "$ACHILLES_PI_LOG" || live_fail "no child was spawned with the skill"
grep -q '"kind":"session_start".*"depth":"1"' "$ACHILLES_PI_LOG" || live_fail "the extension did not load inside the child"
childline=$(grep '"kind":"skill","depth":1' "$ACHILLES_PI_LOG" | grep '"view":"map"' | head -1)
[ -n "$childline" ] || live_fail "the real child did not receive a map: $(grep '"kind":"skill"' "$ACHILLES_PI_LOG" | tail -3)"
json_num() { node -e 'process.stdout.write(String(JSON.parse(process.argv[1])[process.argv[2]] ?? ""))' "$1" "$2"; }
cchars=$(json_num "$childline" chars)
[ -n "$cchars" ] && [ "$cchars" -lt 6000 ] || live_fail "the child's coverage-expansion load is $cchars chars (want < 6000)"
[ "$(json_num "$childline" bodyChars)" = "89400" ] || live_fail "the child was not mapped from the whole 89,400-char body: $childline"
# Change 1 of round 4 in one line: the child's map IS the orchestrator's map, byte for byte.
orchline=$(grep '"kind":"skill","depth":0' "$ACHILLES_PI_LOG" | grep '"view":"map"' | head -1)
[ -n "$orchline" ] || live_fail "no orchestrator map recorded to compare against"
ochars=$(json_num "$orchline" chars)
[ "$cchars" = "$ochars" ] || live_fail "the child's map ($cchars chars) is not the orchestrator's ($ochars)"
# Nothing of the body reached it: 89,400 chars cannot hide inside $cchars.
grep '"kind":"skill","depth":1' "$ACHILLES_PI_LOG" | grep -q '"view":"full"' && live_fail "a depth-1 load came back whole"

live_pass "coverage-expansion map ${chars} chars (body ~89k), five-pass split to ${schars}, rule block whole at ${rchars}, REAL nested child map ${cchars} == orchestrator ${ochars}"
