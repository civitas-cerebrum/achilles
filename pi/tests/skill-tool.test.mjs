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
import { PACKAGE_DIR, parseSections, findSection, parentOf, subsectionsOf, tableOfContents, listSkills, resolveSkill, REQUIRED_HEADING } from '../extensions/achilles/skills.ts';
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
  assert.equal(parseSections(bodyOf('coverage-expansion')).filter((x) => x.required).length, 11);
});

// ── C2: `Hard rules — kernel-resident` is this repo's own name for an always-required block ───────
test('a kernel-resident hard-rules block counts as always required', () => {
  for (const h of ['Hard rules — kernel-resident', 'Hard rules', 'Kernel-resident invariants — convention', 'Engine hard rules'])
    assert.match(h, REQUIRED_HEADING, h);
});

test('every skill with a kernel-resident hard-rules block has it inlined or listed in its map', () => {
  const maps = realSkillMaps();
  const withKernel = maps.filter((m) => m.sections.some((s) => /hard rule|kernel-resident/i.test(s.heading)));
  assert.deepEqual(withKernel.map((m) => m.name).sort(), [
    'achilles-protocol', 'bug-report', 'companion-mode', 'contributing-to-achilles-protocol',
    'coverage-expansion', 'journey-mapping',
  ]);
  for (const m of withKernel) {
    for (const s of m.sections.filter((x) => /hard rule|kernel-resident/i.test(x.heading))) {
      const inlined = m.text.includes(s.ownText) && s.ownText.length > s.heading.length + 4;
      const listed = m.text.includes(`  - ${'#'.repeat(s.level)} ${s.heading} (${s.text.length} chars)`);
      assert.ok(inlined || listed, `${m.name}: kernel block "${s.heading}" is neither inlined nor listed`);
      // A block inlined as a stub over subsections is listed as well (see C1).
      if (inlined && s.text.length > s.ownText.length) assert.ok(listed, `${m.name}: "${s.heading}" inlined as a stub without a fetch line`);
    }
  }
});

test("journey-mapping's map carries the cycle protocol the preread gate assumes is known", async () => {
  const r = await call({ skill: 'journey-mapping' });
  const text = r.content[0].text;
  const all = parseSections(bodyOf('journey-mapping'));
  const kernel = all.find((s) => /Hard rules — kernel-resident/.test(s.heading));
  assert.ok(kernel && kernel.ownText.length > 3000, 'fixture assumption');
  assert.ok(text.includes(kernel.ownText), 'the kernel rules are not in the map');
  assert.ok(text.length <= 6000, `${text.length} chars`);
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
  assert.match(r.content[0].text, /section: "[^"]+ > Hard rules — kernel-resident" \}  \(\d+ chars\)/);
  assert.match(r.content[0].text, /Sections — fetch one with Skill/);
});

// ── M3: the move the ambiguity message offers has to work ────────────────────────────────────────
test('every candidate the ambiguity message prints resolves when asked for verbatim', async () => {
  const r = await call({ skill: 'coverage-expansion', section: 'Hard rules — kernel-resident' });
  assert.equal(r.details.view, 'map');
  const offered = [...r.content[0].text.matchAll(/section: "([^"]+)" \}/g)].map((m) => m[1]).filter((q) => !q.startsWith('<'));
  assert.ok(offered.length >= 5, `${offered.length} candidates offered`);
  for (const q of offered) {
    const one = await call({ skill: 'coverage-expansion', section: q });
    assert.equal(one.details.view, 'section', `"${q}" did not resolve`);
    assert.equal(one.details.section, 'Hard rules — kernel-resident');
  }
  // The five resolve to five DIFFERENT blocks, not all to the first one.
  const sizes = new Set();
  for (const q of offered) sizes.add((await call({ skill: 'coverage-expansion', section: q })).details.chars);
  assert.ok(sizes.size >= 4, `${[...sizes].join(',')}`);
});

test('a "<parent> > <child>" path resolves, and a heading containing ">" still resolves on its own', () => {
  const all = parseSections(bodyOf('coverage-expansion'));
  const hits = all.filter((x) => x.heading === 'Hard rules — kernel-resident');
  assert.ok(hits.length >= 5);
  for (const h of hits) {
    const parent = parentOf(all, h);
    const { section, candidates } = findSection(all, `${parent.heading} > ${h.heading}`);
    assert.deepEqual(candidates, []);
    assert.equal(section, h, `${parent.heading} > ${h.heading}`);
  }
  // A path whose parent matches nothing falls through to plain heading matching rather than failing.
  assert.equal(findSection(all, 'nothing at all > No-skip contract').section.heading, 'No-skip contract');
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

// ── Round 4, item 1: a child's dispatched skill is mapped too when its body is large ─────────────
// Round 2 bounded the orchestrator only. A subagent on a 32k-context model that is handed
// coverage-expansion's 89k-char body (~22k tokens) has almost no window left for the work, so above
// ACHILLES_PI_SKILL_CHILD_FULL_BELOW a child gets the same map — required rule blocks and all.
const CHILD_HEAVY = [
  'contributing-to-achilles-protocol', 'coverage-expansion', 'ticket-driven-testing',
  'failure-diagnosis', 'companion-mode', 'journey-mapping',
];

for (const name of CHILD_HEAVY) {
  test(`${name}: a depth-1 no-section response is a map under ACHILLES_PI_SKILL_HEAD_MAX`, async () => {
    const r = await call({ skill: name }, { ACHILLES_PI_DEPTH: '1' });
    const text = r.content[0].text;
    assert.equal(r.details.view, 'map', `${name} is not mapped at depth 1`);
    assert.ok(text.length <= 6000, `${name} depth-1 reply is ${text.length} chars`);
    assert.ok(!text.includes(bodyOf(name)), `${name} depth-1 reply still carries the whole body`);
    // Every always-required block is either inlined whole or on the fetch-before-you-act list — the
    // depth-0 contract, unchanged at depth 1. A partial rule block never passes for a complete one.
    const required = parseSections(bodyOf(name)).filter((x) => x.required);
    for (const sec of required) {
      assert.ok(text.includes(sec.heading), `${name} depth-1 map omits required heading "${sec.heading}"`);
      const inlinedWhole = text.includes(sec.text);
      const listed = text.includes(`  - ${'#'.repeat(sec.level)} ${sec.heading} (${sec.text.length} chars)`);
      assert.ok(inlinedWhole || listed, `${name}: required "${sec.heading}" is neither whole nor listed`);
      if (listed) assert.match(text, /required, not included in full here: fetch each before you act/);
    }
    assert.match(text, new RegExp(`Skill \\{ skill: "${name}", section: "<heading>" \\}`));
  });
}

test('a mid-size skill still arrives whole at depth 1, while depth 0 maps it', async () => {
  const body = bodyOf('test-repair');
  assert.ok(body.length > 20000 && body.length < 24000, `fixture assumption: ${body.length} chars`);
  const child = await call({ skill: 'test-repair' }, { ACHILLES_PI_DEPTH: '1' });
  assert.equal(child.details.view, 'full');
  assert.ok(child.content[0].text.includes(body));
  const orch = await call({ skill: 'test-repair' });
  assert.equal(orch.details.view, 'map');
});

test('ACHILLES_PI_SKILL_CHILD_FULL_BELOW moves the child threshold and not the orchestrator\'s', async () => {
  const whole = await call({ skill: 'coverage-expansion' }, { ACHILLES_PI_DEPTH: '1', ACHILLES_PI_SKILL_CHILD_FULL_BELOW: '200000' });
  assert.equal(whole.details.view, 'full');
  const mapped = await call({ skill: 'test-repair' }, { ACHILLES_PI_DEPTH: '1', ACHILLES_PI_SKILL_CHILD_FULL_BELOW: '1000' });
  assert.equal(mapped.details.view, 'map');
  // The orchestrator keeps its own, tighter threshold: the child knob does not loosen depth 0.
  const orch = await call({ skill: 'coverage-expansion' }, { ACHILLES_PI_SKILL_CHILD_FULL_BELOW: '200000' });
  assert.equal(orch.details.view, 'map');
});

test('ACHILLES_PI_VERBOSE=1 bypasses child sectioning too', async () => {
  const r = await call({ skill: 'coverage-expansion' }, { ACHILLES_PI_DEPTH: '1', ACHILLES_PI_VERBOSE: '1' });
  assert.equal(r.details.view, 'full');
  assert.ok(r.content[0].text.includes(bodyOf('coverage-expansion')));
});

test('a subagent-only skill is mapped at depth 1, not refused and not dumped whole', async () => {
  const r = await call({ skill: 'contributing-to-achilles-protocol' }, { ACHILLES_PI_DEPTH: '1' });
  assert.equal(r.details.refused, undefined);
  assert.equal(r.details.view, 'map');
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

// ── I4: an explicit `section` is honoured at any depth and any size ─────────────────────────────
test('a subagent asking for one section gets that section, not the whole body', async () => {
  const r = await call({ skill: 'coverage-expansion', section: 'No-skip contract' }, { ACHILLES_PI_DEPTH: '1' });
  assert.equal(r.details.view, 'section');
  assert.equal(r.details.section, 'No-skip contract');
  const whole = bodyOf('coverage-expansion');
  assert.ok(r.content[0].text.length < whole.length / 5, `${r.content[0].text.length} of ${whole.length}`);
  assert.doesNotMatch(r.content[0].text, /\n## Breadth mode/);
  // The live-04 case: a child asking achilles-protocol for the return schema instead of the body.
  const p = await call({ skill: 'achilles-protocol', section: 'subagent return + ledger schema' }, { ACHILLES_PI_DEPTH: '2' });
  assert.equal(p.details.view, 'section');
  assert.ok(p.details.chars < bodyOf('achilles-protocol').length / 2, `${p.details.chars}`);
  // A section that names nothing gives a child the map, not 57k of body.
  const miss = await call({ skill: 'achilles-protocol', section: 'subagent-return-schema' }, { ACHILLES_PI_DEPTH: '1' });
  assert.equal(miss.details.view, 'map');
  assert.ok(miss.details.chars <= 6000, `${miss.details.chars}`);
});

test('a sub-threshold skill honours a section too', async () => {
  const r = await call({ skill: 'secrets-sweep', section: 'Return shape' });
  assert.equal(r.details.view, 'section');
  assert.equal(r.details.section, 'Return shape');
  assert.ok(r.details.chars < bodyOf('secrets-sweep').length, 'a section can only reduce');
});

// ── M4: a dropped `section` argument is named, never silently ignored ────────────────────────────
test('an unmatched section on a sub-threshold skill returns the body whole and says the section was dropped', async () => {
  const r = await call({ skill: 'secrets-sweep', section: 'no such heading' });
  assert.equal(r.details.view, 'full');
  assert.equal(r.details.sectionDropped, 'no such heading');
  assert.ok(r.content[0].text.includes(bodyOf('secrets-sweep')));
  assert.match(r.content[0].text, /section "no such heading" matches no heading of this skill; it is \d+ chars, so here it is whole/);
});

test('ACHILLES_PI_VERBOSE=1 keeps the whole body and says the section was not applied', async () => {
  const r = await call({ skill: 'coverage-expansion', section: 'No-skip contract' }, { ACHILLES_PI_VERBOSE: '1' });
  assert.equal(r.details.view, 'full');
  assert.equal(r.details.sectionDropped, 'No-skip contract');
  assert.match(r.content[0].text, /not applied: ACHILLES_PI_VERBOSE=1 returns every skill whole/);
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
