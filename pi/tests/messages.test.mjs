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

// ── compaction (createMessageCompactor) ──
import fs from 'node:fs';
import { createMessageCompactor, SCOPE_POINTER, firstLine, referencesLine } from '../extensions/achilles/messages.ts';
const activation = fs.readFileSync(path.join(pkg, 'hooks', 'lib', 'achilles-activation.sh'), 'utf8');
const NOTICE = activation.slice(activation.indexOf("'── achilles session-scope") + 1, activation.indexOf("not yours.)'") + 'not yours.)'.length);
const deny = (line) => `[BLOCKED] ${line}\n\nFix: do the other thing.\n\nReferences:\n  skills/orch-skill/SKILL.md\n\n${NOTICE}`;
/** Copied from a real lets-code onboarding run (playwright-artifact-archiver PostToolUse systemMessage). */
const ARCHIVER = (run) => `[WARN] Playwright evidence archived to .achilles/runs/${run} with omissions.\n\nPruned 1 older run(s) past ACHILLES_ARTIFACT_RETAIN=5: 20260926T105516Z. Raise ACHILLES_ARTIFACT_RETAIN to keep more.\n\nReferences:\n  skills/achilles-protocol/references/harness-hooks.md §PostToolUse\n  .achilles/runs/${run}/manifest.json`;
const verboseOff = () => { const p = process.env.ACHILLES_PI_VERBOSE; delete process.env.ACHILLES_PI_VERBOSE; return () => { if (p !== undefined) process.env.ACHILLES_PI_VERBOSE = p; }; };

test('scope notice: the first deny carries it, the second only the one-line pointer', (t) => {
  t.after(verboseOff());
  const c = createMessageCompactor();
  const a = c.deny('guard.sh', deny('one'));
  assert.ok(a.includes(NOTICE));
  const b = c.deny('guard.sh', deny('two'));
  assert.ok(!b.includes('These guardrails are bound'));
  assert.ok(b.endsWith(SCOPE_POINTER));
  assert.match(b, /^\[BLOCKED\] two\n\nFix: do the other thing\./);
});
test('deny dedupe: an identical repeat collapses to one line; a new body under the same first line does not', (t) => {
  t.after(verboseOff());
  const c = createMessageCompactor();
  c.deny('guard.sh', deny('same'));
  assert.equal(c.deny('guard.sh', deny('same')), '[achilles] guard.sh: same block as before — [BLOCKED] same. Apply the fix from the earlier message.');
  assert.match(c.deny('other.sh', deny('same')), /Fix: do the other thing/, 'another hook is not a repeat');
  const changed = deny('same').replace('do the other thing', 'fix field runMode');
  assert.match(c.deny('guard.sh', changed), /fix field runMode/);
});
test('warning compaction: first line plus references on one line; the repeat collapses (run ids differ)', (t) => {
  t.after(verboseOff());
  const c = createMessageCompactor();
  assert.equal(firstLine(ARCHIVER('R1')), '[WARN] Playwright evidence archived to .achilles/runs/R1 with omissions.');
  assert.equal(referencesLine(ARCHIVER('R1')), 'References: skills/achilles-protocol/references/harness-hooks.md §PostToolUse; .achilles/runs/R1/manifest.json');
  const first = c.note('playwright-artifact-archiver.sh', ARCHIVER('20260926T110721Z'), 'systemMessage');
  assert.equal(first, '[WARN] Playwright evidence archived to .achilles/runs/20260926T110721Z with omissions.\nReferences: skills/achilles-protocol/references/harness-hooks.md §PostToolUse; .achilles/runs/20260926T110721Z/manifest.json');
  assert.ok(!first.includes('Pruned') && first.length < ARCHIVER('20260926T110721Z').length);
  assert.equal(c.note('playwright-artifact-archiver.sh', ARCHIVER('20260926T110910Z'), 'systemMessage'), '[achilles] playwright-artifact-archiver.sh: repeated warning (see earlier).');
});
test('additionalContext is kept (scope-compacted) up to 1000 chars on first sight', (t) => {
  t.after(verboseOff());
  const c = createMessageCompactor();
  assert.equal(c.note('h.sh', 'line one\nline two', 'additionalContext'), 'line one\nline two');
  const long = c.note('h2.sh', 'z'.repeat(3000), 'additionalContext');
  assert.equal(long.length, 1000); assert.match(long, /…$/);
});
test('first line is capped at 200 chars', (t) => {
  t.after(verboseOff());
  assert.equal(createMessageCompactor().note('h.sh', 'w'.repeat(500), 'reason').length, 200);
});
test('reset() clears all dedupe state', (t) => {
  t.after(verboseOff());
  const c = createMessageCompactor();
  c.deny('g.sh', deny('x')); c.note('a.sh', ARCHIVER('R1'), 'systemMessage');
  c.reset();
  assert.ok(c.deny('g.sh', deny('x')).includes(NOTICE));
  assert.match(c.note('a.sh', ARCHIVER('R2'), 'systemMessage'), /^\[WARN\]/);
});
test('ACHILLES_PI_VERBOSE=1 passes every text through unchanged', (t) => {
  const prev = process.env.ACHILLES_PI_VERBOSE; process.env.ACHILLES_PI_VERBOSE = '1';
  t.after(() => { if (prev === undefined) delete process.env.ACHILLES_PI_VERBOSE; else process.env.ACHILLES_PI_VERBOSE = prev; });
  const c = createMessageCompactor();
  for (let i = 0; i < 2; i++) {
    assert.equal(c.deny('g.sh', deny('x')), deny('x'));
    assert.equal(c.note('a.sh', ARCHIVER('R1'), 'systemMessage'), ARCHIVER('R1'));
  }
});
