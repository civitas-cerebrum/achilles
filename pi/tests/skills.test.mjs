import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { resolveSkill, skillRoots, listSkills, kernelEntries, KERNEL_DELIMITER, declaredKernelSections, parseSections } from '../extensions/achilles/skills.ts';
const fx = path.join(import.meta.dirname, 'fixtures', 'skills');

test('resolves an orchestrator skill with body', () => {
  const s = resolveSkill('orch-skill', [fx]);
  assert.equal(s.subagentOnly, false);
  assert.match(s.body, /Body of orch skill/);
  assert.equal(s.file, path.join(fx, 'orch-skill', 'SKILL.md'));
});
test('subagent-only by flag', () => { assert.equal(resolveSkill('sub-flag', [fx]).subagentOnly, true); });
test('subagent-only by marker', () => { assert.equal(resolveSkill('sub-marker', [fx]).subagentOnly, true); });
test('unknown skill', () => { assert.equal(resolveSkill('nope', [fx]), undefined); });
test('first root wins', () => {
  const s = resolveSkill('orch-skill', ['/nonexistent', fx]);
  assert.equal(s.dir, path.join(fx, 'orch-skill'));
});
test('real repo skills classify as expected', () => {
  const repoSkills = path.resolve(import.meta.dirname, '..', '..', 'skills');
  assert.equal(resolveSkill('onboarding', [repoSkills]).subagentOnly, false);
  assert.equal(resolveSkill('workflow-reviewer', [repoSkills]).subagentOnly, true);
  assert.equal(resolveSkill('failure-diagnosis', [repoSkills]).subagentOnly, true);
  assert.equal(resolveSkill('contributing-to-achilles-protocol', [repoSkills]).subagentOnly, true);
});
test('SKILL.md as a directory does not throw, resolves as unfound', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'skills-test-'));
  try {
    fs.mkdirSync(path.join(tmp, 'weird-skill', 'SKILL.md'), { recursive: true });
    assert.doesNotThrow(() => resolveSkill('weird-skill', [tmp]));
    assert.equal(resolveSkill('weird-skill', [tmp]), undefined);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
test('skillRoots order', () => {
  const r = skillRoots('/h');
  assert.equal(r[0], path.join('/h', '.agents', 'skills'));
  assert.ok(r[1].endsWith(path.join('achilles', 'skills')) || r[1].endsWith('skills'));
});
test('listSkills: fixture root returns sorted names', () => {
  assert.deepEqual(listSkills([fx]), ['kernel-skill', 'orch-skill', 'sub-flag', 'sub-marker']);
});
test('listSkills: nonexistent root and a root that is a regular file are skipped without throwing', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'skills-list-test-'));
  const fileRoot = path.join(tmp, 'not-a-dir');
  fs.writeFileSync(fileRoot, 'not a directory');
  try {
    assert.doesNotThrow(() => listSkills(['/nonexistent', fileRoot, fx]));
    assert.deepEqual(listSkills(['/nonexistent', fileRoot, fx]), ['kernel-skill', 'orch-skill', 'sub-flag', 'sub-marker']);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
test('listSkills: names are de-duplicated across roots', () => {
  assert.deepEqual(listSkills([fx, fx]), ['kernel-skill', 'orch-skill', 'sub-flag', 'sub-marker']);
});

// ── Round 6 item 1: a skill DECLARES its kernel instead of the adapter guessing ───────────────────

test('pi-kernel: is parsed off the frontmatter as entries, and absent when the skill has none', () => {
  assert.deepEqual(resolveSkill('kernel-skill', [fx]).piKernel, ['The deal', 'Rules > The hard part', 'Per load-test pass']);
  assert.equal(resolveSkill('orch-skill', [fx]).piKernel, undefined);
  // The body is what it always was: the frontmatter line is not part of the skill's text.
  assert.ok(!resolveSkill('kernel-skill', [fx]).body.includes('pi-kernel'));
});

test('kernelEntries splits on the delimiter, trims, de-duplicates, and drops an author typo', () => {
  assert.equal(KERNEL_DELIMITER, '|');
  assert.deepEqual(kernelEntries('A | B'), ['A', 'B']);
  assert.deepEqual(kernelEntries('  A   |B|  '), ['A', 'B']);
  assert.deepEqual(kernelEntries('A || B |'), ['A', 'B'], 'a doubled or trailing delimiter is not an empty entry');
  assert.deepEqual(kernelEntries('A | A'), ['A']);
  assert.deepEqual(kernelEntries(''), []);
});

test('a heading that itself contains the delimiter is still declarable, by a unique substring', () => {
  const s = resolveSkill('kernel-skill', [fx]);
  const hit = declaredKernelSections(parseSections(s.body.trim()), ['Per load-test pass']);
  assert.deepEqual(hit.unresolved, []);
  assert.match(hit.sections[0].heading, /perf-reviewer-pass-<load\|stress\|spike\|soak>/);
});

test('a pi-kernel entry resolves the way the map addresses a section: exact, substring, or parent > child', () => {
  const body = resolveSkill('kernel-skill', [fx]).body.trim();
  const sections = parseSections(body);
  const one = (entry) => declaredKernelSections(sections, [entry]);
  assert.equal(one('The deal').sections[0].heading, 'The deal');
  assert.equal(one('the DEAL').sections[0].heading, 'The deal', 'case-insensitive, like findSection');
  // "The hard part" is repeated, so only the path form can name one — the same rule the ambiguity
  // reply teaches the model.
  assert.deepEqual(one('The hard part').unresolved, ['The hard part']);
  assert.equal(one('Rules > The hard part').sections[0].heading, 'The hard part');
  assert.equal(parseSections(body, ['Rules > The hard part']).find((s) => s.required && s.heading === 'The hard part').level, 3);
});

test('an entry that names no heading is unresolved, and so is a table-of-contents NUMBER', () => {
  const sections = parseSections(resolveSkill('kernel-skill', [fx]).body.trim());
  assert.deepEqual(declaredKernelSections(sections, ['No such section']).unresolved, ['No such section']);
  // "3" resolves for a MODEL fetching the 3rd section; as a declaration it is meaningless, and the
  // containment guard rejects it rather than pinning a block by position.
  assert.deepEqual(declaredKernelSections(sections, ['3']).unresolved, ['3']);
  assert.deepEqual(declaredKernelSections(sections, undefined), { sections: [], unresolved: [] });
});

test('pi-kernel and a required HEADING union: neither suppresses the other', () => {
  const s = resolveSkill('kernel-skill', [fx]);
  const declared = parseSections(s.body.trim(), s.piKernel).filter((x) => x.required).map((x) => x.heading);
  assert.ok(declared.some((h) => /ABSOLUTE RULES/.test(h)), 'the heading-declared block survives annotation');
  assert.ok(declared.includes('The deal'));
  assert.ok(declared.includes('The hard part'));
  assert.equal(declared.filter((h) => h === 'The hard part').length, 1, 'only the one the path named');
  assert.ok(!declared.includes('Prose'));
});

test('every pi-kernel entry of every real skill resolves to exactly one heading of that skill', () => {
  const repoSkills = path.resolve(import.meta.dirname, '..', '..', 'skills');
  const annotated = [];
  for (const name of listSkills([repoSkills])) {
    const s = resolveSkill(name, [repoSkills]);
    if (!s.piKernel) continue;
    annotated.push(name);
    const { sections, unresolved } = declaredKernelSections(parseSections(s.body.trim()), s.piKernel);
    assert.deepEqual(unresolved, [], `${name}: pi-kernel entries that name no heading of this skill`);
    assert.equal(sections.length, s.piKernel.length, `${name}: two entries resolved to the same heading`);
  }
  // The 14 that had no required heading at all before this round; scripts/lint-doc-drift.mjs checks
  // the same thing where a methodology author will see it.
  assert.equal(annotated.length, 15, `${annotated.length} skills carry pi-kernel: ${annotated.join(', ')}`);
});
