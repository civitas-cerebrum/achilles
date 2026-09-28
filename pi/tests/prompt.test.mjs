import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { makeFakePi } from './fake-pi.mjs';
import { createPromptCompactor, registerPromptCompaction, firstSentence, delegateLine, skillsSection, DESCRIPTION_CAP, compactDescription, stripDelegate, DISPATCHED_PREFIX } from '../extensions/achilles/prompt.ts';
import { listSkills, resolveSkill } from '../extensions/achilles/skills.ts';

const fx = path.join(import.meta.dirname, 'fixtures', 'skills');
const pkgSkills = path.resolve(import.meta.dirname, '..', '..', 'skills');
const LONG = 'Use this skill when the orchestrator needs **fixture** work, e.g. a test. Triggers on "a", "b", "c" and a very long tail of trigger phrases that should never reach the model.';

test('firstSentence: first sentence, emphasis stripped, "e.g." does not end it', () => {
  assert.equal(firstSentence(LONG), 'Use this skill when the orchestrator needs fixture work, e.g. a test.');
  assert.equal(firstSentence('> **Subagent-only.** Do the thing here. More.'), 'Do the thing here.');
  assert.equal(firstSentence('No terminal punctuation at all'), 'No terminal punctuation at all');
});
test('firstSentence: capped at 160 chars on a word boundary with an ellipsis', () => {
  const out = firstSentence(`${'word '.repeat(60)}end.`);
  assert.ok(out.length <= DESCRIPTION_CAP, String(out.length));
  assert.match(out, /word…$/);
});
test('an achilles description is compacted; a non-achilles skill is untouched', () => {
  const skills = [
    { name: 'orch-skill', description: LONG, filePath: '/x/orch-skill/SKILL.md' },
    { name: 'someone-elses', description: LONG, filePath: '/y/SKILL.md' },
  ];
  assert.equal(createPromptCompactor(fx).compact(skills, 0), 1);
  assert.equal(skills[0].description, 'Use this skill when the orchestrator needs fixture work, e.g. a test.');
  assert.equal(skills[1].description, LONG);
});
test('subagent-only without a pi-description: the delegate line at depth 0, a positive dispatched line at depth 1', () => {
  const at = (depth) => { const s = [{ name: 'sub-marker', description: '**Subagent-only.** Marker style. Long tail.' }, { name: 'sub-flag', description: 'Flagged subagent-only.' }]; createPromptCompactor(fx).compact(s, depth); return s; };
  const d0 = at(0);
  assert.equal(d0[0].description, delegateLine('sub-marker'));
  assert.match(d0[0].description, /^Subagent-only — delegate with Agent \{ skill: "sub-marker" \}; do not read it here\.$/);
  assert.equal(d0[1].description, delegateLine('sub-flag'));
  const d1 = at(1);
  assert.equal(d1[0].description, `${DISPATCHED_PREFIX}Marker style.`);
  assert.equal(d1[1].description, `${DISPATCHED_PREFIX}Flagged subagent-only.`);
});
test('results are cached: pi hands a fresh copy each turn and gets the same compact form', () => {
  const c = createPromptCompactor(fx);
  const a = [{ name: 'orch-skill', description: LONG }];
  c.compact(a, 0);
  const b = [{ name: 'orch-skill', description: LONG }];
  c.compact(b, 0);
  assert.equal(b[0].description, a[0].description);
});
test('before_agent_start mutates event.systemPromptOptions.skills in place (pi re-renders from it)', async () => {
  const pi = makeFakePi();
  registerPromptCompaction(pi, fx);
  const options = { skills: [{ name: 'orch-skill', description: LONG }, { name: 'other', description: LONG }] };
  const event = { type: 'before_agent_start', prompt: 'hi', systemPromptOptions: options, get systemPrompt() { return options.skills.map((s) => s.description).join('\n'); } };
  const prev = process.env.ACHILLES_PI_DEPTH; delete process.env.ACHILLES_PI_DEPTH;
  try { assert.equal(await pi.fire('before_agent_start', event, {}), undefined); }
  finally { if (prev !== undefined) process.env.ACHILLES_PI_DEPTH = prev; }
  assert.equal(options.skills[0].description, 'Use this skill when the orchestrator needs fixture work, e.g. a test.');
  assert.equal(options.skills[1].description, LONG);
  assert.doesNotMatch(event.systemPrompt, /never reach the model.*\n.*never reach/s);
});
test('skillsSection extracts pi\'s rendered skills block', () => {
  const sp = 'head\n\nThe following skills provide specialized instructions for specific tasks.\n<available_skills>\n  <skill>x</skill>\n</available_skills>\ntail';
  assert.match(skillsSection(sp), /^The following skills[\s\S]*<\/available_skills>$/);
  assert.equal(skillsSection('no skills'), '');
});
test('pi-description wins over the first sentence; subagent-only keeps its delegate line at depth 0 and turns positive at depth 1', () => {
  const pd = 'Subagent-only — failing tests ("the nightly failed", "CI is red"): delegate with Agent { skill: "fd" }.';
  assert.equal(compactDescription('x', LONG, false, 0, 'Route here: "a", "b". Not for c (use d).'), 'Route here: "a", "b". Not for c (use d).');
  assert.equal(compactDescription('x', LONG, false, 0), firstSentence(LONG));
  assert.equal(compactDescription('fd', '**Subagent-only.** Do not load in the orchestrator.', true, 0, pd), pd);
  const d1 = compactDescription('fd', '**Subagent-only.** Do not load in the orchestrator.', true, 1, pd);
  assert.equal(d1, `${DISPATCHED_PREFIX}failing tests ("the nightly failed", "CI is red").`);
  assert.doesNotMatch(d1, /delegate|Do not load|Subagent-only/);
  assert.equal(stripDelegate('Subagent-only — delegate with Agent { skill: "w" }; do not read it here.'), '');
});
test('REAL repo skills: every achilles skill has a pi-description of at most 200 chars; subagent-only ones carry a delegate line with triggers', () => {
  for (const name of listSkills([pkgSkills])) {
    const s = resolveSkill(name, [pkgSkills]);
    assert.ok(s.piDescription, `${name}: pi-description missing`);
    assert.ok(s.piDescription.length <= 200, `${name}: ${s.piDescription.length}`);
    if (s.subagentOnly) {
      assert.match(s.piDescription, new RegExp(`^Subagent-only — .+\\(.+\\): delegate with Agent \\{ skill: "${name}" \\}\\.$`), name);
      const d1 = compactDescription(name, s.description, true, 1, s.piDescription);
      assert.ok(d1.startsWith(DISPATCHED_PREFIX) && !/delegate|do not load/i.test(d1), `${name}: ${d1}`);
    }
  }
  const fd = resolveSkill('failure-diagnosis', [pkgSkills]).piDescription;
  assert.match(fd, /the nightly failed/); assert.match(fd, /CI is red/);
  assert.match(resolveSkill('achilles-protocol', [pkgSkills]).piDescription, /the nightly failed/);
  assert.match(resolveSkill('bug-discovery', [pkgSkills]).piDescription, /performance-testing/);
  assert.match(resolveSkill('performance-testing', [pkgSkills]).piDescription, /bug-discovery/);
  assert.match(resolveSkill('test-composer', [pkgSkills]).piDescription, /coverage-expansion/);
  assert.match(resolveSkill('coverage-expansion', [pkgSkills]).piDescription, /test-composer/);
  assert.match(resolveSkill('self-repair', [pkgSkills]).piDescription, /test-repair.*failure-diagnosis/);
});
test('REAL repo skills: the orchestrator\'s whole rendered compact listing (pi\'s XML, with locations) is under 2,000 tokens', () => {
  // Depth 0 only: a child runs with --no-skills and lists just its dispatched skill (see the child test).
  const esc = (t) => t.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;');
  for (const depth of [0]) {
    const skills = listSkills([pkgSkills]).map((name) => ({ name, description: resolveSkill(name, [pkgSkills]).description, filePath: path.join(pkgSkills, name, 'SKILL.md') }));
    createPromptCompactor(pkgSkills).compact(skills, depth);
    // Same shape as pi's formatSkillsForPrompt (dist/core/skills.js), header included.
    const listing = ['', '', 'The following skills provide specialized instructions for specific tasks.', "Use the read tool to load a skill's file when the task matches its description.", 'When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.', '', '<available_skills>',
      ...skills.flatMap((s) => ['  <skill>', `    <name>${esc(s.name)}</name>`, `    <description>${esc(s.description)}</description>`, `    <location>${esc(s.filePath)}</location>`, '  </skill>']), '</available_skills>'].join('\n');
    assert.ok(listing.length / 4 < 2000, `depth ${depth}: ${listing.length / 4} tokens`);
  }
});
test('REAL repo skills: all 25 compact (names + descriptions) under 1,600 tokens (chars/4), both depths', () => {
  const names = listSkills([pkgSkills]);
  assert.equal(names.length, 25);
  for (const depth of [0, 1]) {
    const skills = names.map((name) => ({ name, description: resolveSkill(name, [pkgSkills]).description }));
    const before = skills.reduce((n, s) => n + s.name.length + s.description.length, 0);
    assert.equal(createPromptCompactor(pkgSkills).compact(skills, depth), 25);
    const listing = skills.map((s) => `<name>${s.name}</name><description>${s.description}</description>`).join('\n');
    assert.ok(listing.length / 4 < 1600, `depth ${depth}: ${listing.length / 4} tokens`);
    assert.ok(listing.length < before / 4, `depth ${depth}: ${listing.length} vs ${before}`);
    const extra = depth ? DISPATCHED_PREFIX.length : 0;
    for (const s of skills) assert.ok(s.description.length <= Math.max(DESCRIPTION_CAP, 200) + extra && !/\*\*/.test(s.description) && !/^>/.test(s.description), `${s.name}: ${s.description}`);
  }
  assert.ok(fs.existsSync(path.join(pkgSkills, 'workflow-reviewer', 'SKILL.md')));
});
test('depth >= 1: any dispatched achilles skill (a test-composer child) reads as the dispatched methodology', () => {
  // What a child spawned with --no-skills --skill <test-composer> hands before_agent_start.
  const skills = [{ name: 'test-composer', description: resolveSkill('test-composer', [pkgSkills]).description }];
  assert.equal(createPromptCompactor(pkgSkills).compact(skills, 1), 1);
  assert.equal(skills[0].description, `${DISPATCHED_PREFIX}${resolveSkill('test-composer', [pkgSkills]).piDescription}`);
  assert.match(skills[0].description, /^Your dispatched methodology — read this skill before starting: All test variants for ONE user journey/);
  // At depth 0 the same skill keeps its plain routing line.
  const d0 = [{ name: 'test-composer', description: 'x' }];
  createPromptCompactor(pkgSkills).compact(d0, 0);
  assert.equal(d0[0].description, resolveSkill('test-composer', [pkgSkills]).piDescription);
  // The fixture orchestrator-grade skill without a pi-description uses its first sentence.
  const f = [{ name: 'orch-skill', description: LONG }];
  createPromptCompactor(fx).compact(f, 1);
  assert.equal(f[0].description, `${DISPATCHED_PREFIX}Use this skill when the orchestrator needs fixture work, e.g. a test.`);
});
