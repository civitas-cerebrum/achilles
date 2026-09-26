import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { steer } from '../extensions/achilles/messages.ts';
const fx = path.join(import.meta.dirname, 'fixtures', 'skills');
const pkg = path.resolve(import.meta.dirname, '..', '..');
const opts = { roots: [fx], packageDir: pkg, depth: 0 };
const esc = (p) => new RegExp(p.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));

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

test('SKILL.md §section citation: absolute path, no hint', () => {
  const out = steer('References:\n  skills/orch-skill/SKILL.md §"Phase 4 — Journey mapping"', opts);
  assert.match(out, esc(path.join(fx, 'orch-skill', 'SKILL.md') + ' §"Phase 4'));
  assert.doesNotMatch(out, /Under pi|Load it|Delegate it/);
});
test('§section aligned with spaces still counts as a section', () => {
  assert.doesNotMatch(steer('  skills/orch-skill/SKILL.md        §"Redaction"', opts), /Load it/);
});
test('references/* citation: absolute path, no hint', () => {
  const out = steer('See skills/orch-skill/references/guide.md', opts);
  assert.match(out, esc(path.join(fx, 'orch-skill', 'references', 'guide.md')));
  assert.doesNotMatch(out, /Under pi/);
});
test('depth 0: a bare subagent-only SKILL.md stays relative and gets the Delegate hint', () => {
  const out = steer('References:\n  skills/sub-flag/SKILL.md', opts);
  assert.match(out, /^References:\n  skills\/sub-flag\/SKILL\.md\n/);
  assert.doesNotMatch(out, esc(path.join(fx, 'sub-flag')));
  assert.match(out, /Delegate it: Agent \{ skill: "sub-flag"/);
});
test('depth >= 1: every hint is Load it, never Delegate; subagent-only paths are absolutised', () => {
  const out = steer('References:\n  skills/orch-skill/SKILL.md\n  skills/sub-flag/SKILL.md', { ...opts, depth: 1 });
  assert.match(out, /Load it: Skill \{ skill: "orch-skill" \}/);
  assert.match(out, /Load it: Skill \{ skill: "sub-flag" \}/);
  assert.doesNotMatch(out, /Delegate it/);
  assert.match(out, esc(path.join(fx, 'sub-flag', 'SKILL.md')));
});
test('depth defaults from ACHILLES_PI_DEPTH, NaN treated as 0', () => {
  const prev = process.env.ACHILLES_PI_DEPTH;
  try {
    process.env.ACHILLES_PI_DEPTH = '1';
    assert.match(steer('skills/sub-flag/SKILL.md', { roots: [fx], packageDir: pkg }), /Load it: Skill \{ skill: "sub-flag" \}/);
    process.env.ACHILLES_PI_DEPTH = 'banana';
    assert.match(steer('skills/sub-flag/SKILL.md', { roots: [fx], packageDir: pkg }), /Delegate it/);
  } finally { if (prev === undefined) delete process.env.ACHILLES_PI_DEPTH; else process.env.ACHILLES_PI_DEPTH = prev; }
});
test('commit-message-gate citation of a subagent-only SKILL.md §section yields no Delegate hint', () => {
  const realRoots = [path.join(pkg, 'skills')];
  const text = 'References:\n  skills/coverage-expansion/references/depth-mode-pipeline.md §"Commit-message conventions"\n  skills/contributing-to-achilles-protocol/SKILL.md §"AI assistants don\'t get Co-Authored-By trailers"';
  for (const depth of [0, 1]) {
    const out = steer(text, { roots: realRoots, packageDir: pkg, depth });
    assert.doesNotMatch(out, /Delegate it|Load it|Under pi/, `depth ${depth}`);
    assert.match(out, esc(path.join(pkg, 'skills', 'coverage-expansion', 'references', 'depth-mode-pipeline.md')));
  }
  assert.match(steer(text, { roots: realRoots, packageDir: pkg, depth: 0 }), /  skills\/contributing-to-achilles-protocol\/SKILL\.md §/);
});
