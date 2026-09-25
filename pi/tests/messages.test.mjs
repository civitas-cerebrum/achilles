import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { steer } from '../extensions/achilles/messages.ts';
const fx = path.join(import.meta.dirname, 'fixtures', 'skills');
const pkg = path.resolve(import.meta.dirname, '..', '..');
const opts = { roots: [fx], packageDir: pkg };

test('resolves skill references to absolute paths', () => {
  const out = steer('[BLOCKED] x\n\nReferences:\n  skills/orch-skill/references/guide.md §A', opts);
  assert.match(out, new RegExp(path.join(fx, 'orch-skill', 'references', 'guide.md').replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
});
test('appends load hint for orchestrator skill and delegate hint for subagent-only', () => {
  const out = steer('References:\n  skills/orch-skill/SKILL.md\n  skills/sub-flag/SKILL.md', opts);
  assert.match(out, /Load it: Skill \{ skill: "orch-skill" \}/);
  assert.match(out, /Delegate it: Agent \{ skill: "sub-flag"/);
});
test('unknown skill reference is left as-is with no hint', () => {
  const out = steer('References:\n  skills/ghost/SKILL.md', opts);
  assert.match(out, /skills\/ghost\/SKILL\.md/);
  assert.doesNotMatch(out, /Load it|Delegate it/);
});
test('schemas references resolve under the package', () => {
  const out = steer('see schemas/subagent-returns/workflow-reviewer.schema.json', opts);
  assert.match(out, new RegExp(path.join(pkg, 'schemas', 'subagent-returns', 'workflow-reviewer.schema.json').replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
});
test('nonexistent schema reference is left as-is', () => {
  const out = steer('see schemas/ghost.schema.json', opts);
  assert.match(out, /schemas\/ghost\.schema\.json/);
});
test('no references → unchanged', () => { assert.equal(steer('plain', opts), 'plain'); });
