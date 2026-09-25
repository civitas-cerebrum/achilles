import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { resolveSkill, skillRoots, listSkills } from '../extensions/achilles/skills.ts';
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
  assert.deepEqual(listSkills([fx]), ['orch-skill', 'sub-flag', 'sub-marker']);
});
test('listSkills: nonexistent root and a root that is a regular file are skipped without throwing', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'skills-list-test-'));
  const fileRoot = path.join(tmp, 'not-a-dir');
  fs.writeFileSync(fileRoot, 'not a directory');
  try {
    assert.doesNotThrow(() => listSkills(['/nonexistent', fileRoot, fx]));
    assert.deepEqual(listSkills(['/nonexistent', fileRoot, fx]), ['orch-skill', 'sub-flag', 'sub-marker']);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
test('listSkills: names are de-duplicated across roots', () => {
  assert.deepEqual(listSkills([fx, fx]), ['orch-skill', 'sub-flag', 'sub-marker']);
});
