import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { makeFakePi, makeFakeCtx } from './fake-pi.mjs';
import { registerSkillTool } from '../extensions/achilles/skill-tool.ts';
const fx = path.join(import.meta.dirname, 'fixtures', 'skills');
function tool() { const pi = makeFakePi(); registerSkillTool(pi, { roots: [fx] }); return pi.tools.find((t) => t.name === 'Skill'); }

test('registers as Skill with skill/args params', () => {
  const t = tool(); assert.equal(t.label, 'Skill'); assert.ok(t.parameters.properties.skill); assert.ok(t.parameters.properties.args);
});
test('orchestrator skill returns the body wrapped with its path', async () => {
  const r = await tool().execute('c1', { skill: 'orch-skill', args: 'go' }, undefined, undefined, makeFakeCtx());
  assert.match(r.content[0].text, /<skill name="orch-skill" path="[^"]*orch-skill\/SKILL\.md">/);
  assert.match(r.content[0].text, /Body of orch skill/); assert.match(r.content[0].text, /User request: go/);
  assert.equal(r.details.refused, undefined);
});
test('subagent-only by flag refuses with a delegate instruction', async () => {
  const r = await tool().execute('c2', { skill: 'sub-flag' }, undefined, undefined, makeFakeCtx());
  assert.doesNotMatch(r.content[0].text, /Secret body/);
  assert.match(r.content[0].text, /Delegate it: Agent \{ skill: "sub-flag"/);
  assert.equal(r.details.refused, true);
});
test('subagent-only by marker refuses too', async () => {
  const r = await tool().execute('c3', { skill: 'sub-marker' }, undefined, undefined, makeFakeCtx());
  assert.doesNotMatch(r.content[0].text, /Secret body/); assert.equal(r.details.refused, true);
});
test('unknown skill throws with the known names', async () => {
  await assert.rejects(() => tool().execute('c4', { skill: 'ghost' }, undefined, undefined, makeFakeCtx()), /Unknown skill "ghost".*orch-skill/s);
});
test('inside a subagent (depth >= 1) a subagent-only skill returns its body', async (t) => {
  const saved = process.env.ACHILLES_PI_DEPTH;
  t.after(() => { if (saved === undefined) delete process.env.ACHILLES_PI_DEPTH; else process.env.ACHILLES_PI_DEPTH = saved; });
  process.env.ACHILLES_PI_DEPTH = '1';
  const r = await tool().execute('c5', { skill: 'sub-flag' }, undefined, undefined, makeFakeCtx());
  assert.match(r.content[0].text, /<skill name="sub-flag"/); assert.match(r.content[0].text, /Secret body/);
  assert.equal(r.details.refused, undefined);
});

test('NaN ACHILLES_PI_DEPTH counts as the orchestrator: subagent-only is refused', async () => {
  const prev = process.env.ACHILLES_PI_DEPTH; process.env.ACHILLES_PI_DEPTH = 'NaN';
  try {
    const r = await tool().execute('s', { skill: 'sub-flag' });
    assert.equal(r.details.refused, true);
  } finally { if (prev === undefined) delete process.env.ACHILLES_PI_DEPTH; else process.env.ACHILLES_PI_DEPTH = prev; }
});

// ── Sectioned skill bodies (round 2: bounded orchestrator context) ───────────────────────────────
import { PACKAGE_DIR, parseSections, findSection, subsectionsOf, tableOfContents, listSkills, resolveSkill, REQUIRED_HEADING } from '../extensions/achilles/skills.ts';
import { skillMap, capTableOfContents, PENDING_HEADER } from '../extensions/achilles/skill-tool.ts';
const realRoot = path.join(PACKAGE_DIR, 'skills');
function realTool() { const pi = makeFakePi(); registerSkillTool(pi, { roots: [realRoot] }); return pi.tools.find((t) => t.name === 'Skill'); }
async function call(params, env = {}) {
  const saved = Object.fromEntries(Object.keys(env).map((k) => [k, process.env[k]]));
  for (const [k, v] of Object.entries(env)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
  try { return await realTool().execute('c', params, undefined, undefined, makeFakeCtx()); }
  finally { for (const [k, v] of Object.entries(saved)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; } }
}
const HEAVY = ['coverage-expansion', 'journey-mapping', 'achilles-protocol', 'onboarding'];
const bodyOf = (name) => fs.readFileSync(path.join(realRoot, name, 'SKILL.md'), 'utf8').replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n?/, '').trim();
/** Every real skill whose body is over the full-below threshold, with the map the orchestrator gets. */
function realSkillMaps() {
  return listSkills([realRoot])
    .map((name) => ({ name, body: resolveSkill(name, [realRoot]).body.trim() }))
    .filter((x) => x.body.length >= 12000)
    .map((x) => ({ name: x.name, body: x.body, ...skillMap(x.name, x.body, 6000) }));
}

for (const name of HEAVY) {
  test(`${name}: the no-section response is a map under 6,000 chars naming every always-required heading`, async () => {
    const r = await call({ skill: name });
    const text = r.content[0].text;
    assert.equal(r.details.view, 'map');
    assert.ok(text.length < 6000, `${name} map is ${text.length} chars`);
    assert.ok(text.length < r.details.bodyChars / 4, `${name} map is not much smaller than its ${r.details.bodyChars}-char body`);
    // Every always-required heading is in the map, either as its own rule text or as mandatory
    // reading to fetch; every required block that IS included is included whole, never cut.
    const required = parseSections(bodyOf(name)).filter((s) => s.required);
    for (const s of required) {
      assert.ok(text.includes(s.heading), `${name} map omits required heading "${s.heading}"`);
      if (text.includes(s.ownText)) continue;
      assert.match(text, /required, not included in full here: fetch each before you act/);
    }
    // The table of contents carries every `## ` section with its size.
    for (const s of parseSections(bodyOf(name)).filter((x) => x.level === 2)) {
      assert.ok(text.includes(`${s.heading} (${s.text.length} chars)`), `${name} TOC omits "${s.heading}"`);
    }
    assert.match(text, new RegExp(`Skill \\{ skill: "${name}", section: "<heading>" \\}`));
  });
}

test('an always-required block that fits the budget is included verbatim, and marked in the TOC', async () => {
  const r = await call({ skill: 'achilles-protocol' });
  const req = parseSections(bodyOf('achilles-protocol')).filter((s) => s.required);
  assert.ok(req.length > 0);
  assert.match(r.content[0].text, /── always required ──/);
  for (const s of req) assert.ok(r.content[0].text.includes(s.ownText), `missing required block "${s.heading}"`);
  assert.match(r.content[0].text, /ABSOLUTE RULES.*\[required reading\]/);
});

test('every always-required heading matches the documented pattern', () => {
  for (const s of parseSections(bodyOf('coverage-expansion')).filter((x) => x.required)) assert.match(s.heading, REQUIRED_HEADING);
  assert.equal(parseSections(bodyOf('coverage-expansion')).filter((x) => x.required).length, 5);
});

test('a section fetch returns that section only, in full, with its subsections', async () => {
  const r = await call({ skill: 'coverage-expansion', section: 'five-pass pipeline' });
  const text = r.content[0].text;
  assert.equal(r.details.view, 'section');
  assert.match(r.details.section, /^Standard mode — five-pass pipeline/);
  assert.ok(text.length > 5000, `section is ${text.length} chars`);
  assert.match(text, /^<skill name="coverage-expansion"[^>]*view="section">\n## Standard mode/);
  // Bounded by the next `## `: the following top-level section is not in it.
  assert.doesNotMatch(text, /\n## Breadth mode/);
  assert.doesNotMatch(text, /Sections — fetch one with Skill/);
});

test('a section fetch matches on a substring and on the TOC number', async () => {
  const bySubstring = await call({ skill: 'onboarding', section: 'secrets sweep' });
  assert.match(bySubstring.details.section, /Secrets sweep/);
  const top = parseSections(bodyOf('onboarding')).filter((s) => s.level === 2);
  const byNumber = await call({ skill: 'onboarding', section: '3' });
  assert.equal(byNumber.details.section, top[2].heading);
});

test('a `### ` heading is addressable too', async () => {
  const r = await call({ skill: 'coverage-expansion', section: 'Stage A per-journey dispatch' });
  assert.equal(r.details.view, 'section');
  assert.match(r.content[0].text, /### Stage A per-journey dispatch is non-negotiable/);
});

test('an ambiguous section returns the candidates with their parents, plus the map — it does not throw', async () => {
  const r = await call({ skill: 'coverage-expansion', section: 'Hard rules' });
  assert.equal(r.details.view, 'map');
  assert.ok(r.details.candidates.length > 1);
  assert.match(r.content[0].text, /matches \d+ headings/);
  assert.match(r.content[0].text, /\(under "[^"]+"\)/);
  assert.match(r.content[0].text, /Sections — fetch one with Skill/);
});

test('an unmatched section returns the map and the pick-one line — it does not throw', async () => {
  const r = await call({ skill: 'onboarding', section: 'no such heading at all' });
  assert.equal(r.details.view, 'map');
  assert.deepEqual(r.details.candidates, []);
  assert.match(r.content[0].text, /no section of "onboarding" matches "no such heading at all"/);
  assert.match(r.content[0].text, /Sections — fetch one with Skill/);
});

test('a skill under the threshold still returns whole', async () => {
  const r = await call({ skill: 'secrets-sweep' });
  assert.equal(r.details.view, 'full');
  assert.ok(r.content[0].text.includes(bodyOf('secrets-sweep')));
  assert.ok(r.details.chars < 12000);
});

test('ACHILLES_PI_SKILL_FULL_BELOW moves the threshold', async () => {
  const small = await call({ skill: 'secrets-sweep' }, { ACHILLES_PI_SKILL_FULL_BELOW: '1000' });
  assert.equal(small.details.view, 'map');
  const big = await call({ skill: 'coverage-expansion' }, { ACHILLES_PI_SKILL_FULL_BELOW: '200000' });
  assert.equal(big.details.view, 'full');
});

test('inside a subagent (depth >= 1) a heavy skill returns its whole body', async () => {
  const r = await call({ skill: 'coverage-expansion' }, { ACHILLES_PI_DEPTH: '1' });
  assert.equal(r.details.view, 'full');
  assert.ok(r.content[0].text.includes(bodyOf('coverage-expansion')));
});

test('ACHILLES_PI_VERBOSE=1 bypasses sectioning at depth 0', async () => {
  const r = await call({ skill: 'coverage-expansion' }, { ACHILLES_PI_VERBOSE: '1' });
  assert.equal(r.details.view, 'full');
  assert.ok(r.content[0].text.includes(bodyOf('coverage-expansion')));
});

test('args ride along with a map and with a section', async () => {
  assert.match((await call({ skill: 'onboarding', args: 'go' })).content[0].text, /User request: go$/);
  assert.match((await call({ skill: 'onboarding', section: 'Phase map', args: 'go' })).content[0].text, /User request: go$/);
});

test('skillMap keeps a required block whole or lists it — it never cuts one in half', () => {
  const body = bodyOf('coverage-expansion');
  const all = parseSections(body);
  const required = all.filter((s) => s.required);
  for (const max of [3000, 6000, 12000, 40000]) {
    const { text } = skillMap('coverage-expansion', body, max);
    for (const s of required) {
      const head = `${'#'.repeat(s.level)} ${s.heading}`;
      // Either the whole block is there, or only its listing line is.
      if (text.includes(head)) assert.ok(text.includes(s.ownText) || text.includes(`  - ${head} (${s.text.length} chars)`), `${s.heading} at max=${max}`);
    }
  }
  // A generous budget includes every required block's own text.
  const wide = skillMap('coverage-expansion', body, 60000).text;
  for (const s of required) assert.ok(wide.includes(s.ownText), `${s.heading} missing at max=60000`);
  // Blocks whose rules live in subsections stay on the fetch list even then — their own text is not
  // the whole block — and blocks that carry all their own rules are off it.
  const listed = wide.slice(wide.indexOf(PENDING_HEADER)).split('\n').filter((l) => l.startsWith('  - '));
  const withSubs = required.filter((s) => subsectionsOf(all, s).length);
  assert.equal(listed.length, withSubs.length);
  for (const s of withSubs) assert.ok(listed.some((l) => l.includes(s.heading) && l.includes('its own rules are inlined above')), s.heading);
});

// ── C1: an inlined required block is never allowed to read as the whole rule set ──────────────────
test('a required block whose rules live in subsections is inlined AND listed, with a continuation marker', async () => {
  const r = await call({ skill: 'achilles-protocol' });
  const text = r.content[0].text;
  const all = parseSections(bodyOf('achilles-protocol'));
  const abs = all.find((s) => /ABSOLUTE RULES/.test(s.heading));
  const subs = subsectionsOf(all, abs);
  assert.ok(subs.length > 1 && abs.text.length > abs.ownText.length * 10, 'fixture assumption: the block is a stub over subsections');
  assert.ok(text.includes(abs.ownText), 'the own rules are inlined');
  assert.ok(text.includes(`[achilles] this rule block continues in ${subs.length} subsections (${abs.text.length} chars total)`), text);
  assert.match(text, new RegExp(`fetch Skill \\{ skill: "achilles-protocol", section: "${abs.heading.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}" \\} before acting`));
  // And it is on the fetch-before-you-act list, not silently counted as satisfied.
  const listed = text.slice(text.indexOf(PENDING_HEADER)).split('\n').filter((l) => l.startsWith('  - '));
  assert.ok(listed.some((l) => l.includes(abs.heading)), listed.join('|'));
});

test('a required block that carries all its own rules gets no continuation marker', async () => {
  const r = await call({ skill: 'contract-testing' }, { ACHILLES_PI_SKILL_FULL_BELOW: '1000' });
  const text = r.content[0].text;
  const abs = parseSections(bodyOf('contract-testing')).find((s) => /Absolute Rules/i.test(s.heading));
  assert.equal(abs.text.length, abs.ownText.length);
  assert.ok(text.includes(abs.ownText));
  assert.doesNotMatch(text, /this rule block continues in/);
  assert.ok(!text.includes(PENDING_HEADER), 'nothing pending');
});

// ── M1: the table of contents absorbs the hard cap ───────────────────────────────────────────────
test('capTableOfContents cuts whole lines and says how many it left out', () => {
  const toc = tableOfContents(parseSections(bodyOf('onboarding')), 'onboarding');
  const n = toc.split('\n').length - 1;
  const cut = capTableOfContents(toc, 400, 'onboarding');
  assert.ok(cut.length <= 400, `${cut.length}`);
  assert.match(cut, /more sections? not listed — ask by number: Skill \{ skill: "onboarding", section: "<n>" \}\./);
  for (const l of cut.split('\n').slice(1, -1)) assert.ok(toc.includes(`\n${l}`), l);
  // A room too small even for the header collapses to the one pointer line.
  const tiny = capTableOfContents(toc, 10, 'onboarding');
  assert.equal(tiny.split('\n').length, 1);
  assert.ok(tiny.includes(`${n} more sections not listed`));
  // Room to spare leaves it untouched.
  assert.equal(capTableOfContents(toc, toc.length, 'onboarding'), toc);
});

test('every real skill that maps stays within ACHILLES_PI_SKILL_HEAD_MAX', () => {
  const maps = realSkillMaps();
  assert.ok(maps.length >= 15, `only ${maps.length} skills mapped`);
  for (const { name, text } of maps) assert.ok(text.length <= 6000, `${name} map is ${text.length} chars`);
});

test('parseSections ignores headings inside fenced code blocks', () => {
  const secs = parseSections('# T\n\nintro\n\n## Real\n\n```md\n## Fake heading\n```\n\n## Second\n');
  assert.deepEqual(secs.map((s) => s.heading), ['Real', 'Second']);
  assert.ok(secs[0].text.includes('## Fake heading'));
  // The journey-mapping document template is fenced, so its sample `## ` lines are not sections.
  const jm = parseSections(bodyOf('journey-mapping')).filter((s) => s.level === 2);
  assert.ok(!jm.some((s) => s.heading === 'Site Map'), 'a template heading leaked into the section list');
});

test('findSection on an empty query yields no section and no candidates', () => {
  assert.deepEqual(findSection(parseSections(bodyOf('onboarding')), '   '), { candidates: [] });
});
