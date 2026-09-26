import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { makeFakePi } from './fake-pi.mjs';
import { createPromptCompactor, registerPromptCompaction, firstSentence, delegateLine, skillsSection, DESCRIPTION_CAP } from '../extensions/achilles/prompt.ts';
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
test('subagent-only: the delegate line at depth 0, the first-sentence form at depth 1', () => {
  const at = (depth) => { const s = [{ name: 'sub-marker', description: '**Subagent-only.** Marker style. Long tail.' }, { name: 'sub-flag', description: 'Flagged subagent-only.' }]; createPromptCompactor(fx).compact(s, depth); return s; };
  const d0 = at(0);
  assert.equal(d0[0].description, delegateLine('sub-marker'));
  assert.match(d0[0].description, /^Subagent-only — delegate with Agent \{ skill: "sub-marker" \}; do not read it here\.$/);
  assert.equal(d0[1].description, delegateLine('sub-flag'));
  const d1 = at(1);
  assert.equal(d1[0].description, 'Marker style.');
  assert.equal(d1[1].description, 'Flagged subagent-only.');
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
test('REAL repo skills: all 24 compact (names + descriptions) under 1,600 tokens (chars/4), both depths', () => {
  const names = listSkills([pkgSkills]);
  assert.equal(names.length, 24);
  for (const depth of [0, 1]) {
    const skills = names.map((name) => ({ name, description: resolveSkill(name, [pkgSkills]).description }));
    const before = skills.reduce((n, s) => n + s.name.length + s.description.length, 0);
    assert.equal(createPromptCompactor(pkgSkills).compact(skills, depth), 24);
    const listing = skills.map((s) => `<name>${s.name}</name><description>${s.description}</description>`).join('\n');
    assert.ok(listing.length / 4 < 1600, `depth ${depth}: ${listing.length / 4} tokens`);
    assert.ok(listing.length < before / 4, `depth ${depth}: ${listing.length} vs ${before}`);
    for (const s of skills) assert.ok(s.description.length <= DESCRIPTION_CAP + 20 && !/\*\*/.test(s.description) && !/^>/.test(s.description), `${s.name}: ${s.description}`);
  }
  assert.ok(fs.existsSync(path.join(pkgSkills, 'workflow-reviewer', 'SKILL.md')));
});
