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
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import { createMessageCompactor, SCOPE_POINTER, NO_SKIP_POINTER, firstLine, referencesLine, fixLines, warnRole, firstError, shapedWarnLine } from '../extensions/achilles/messages.ts';
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
  assert.equal(c.deny('guard.sh', deny('same')), '[achilles] guard.sh: same block as before — [BLOCKED] same. Fix: do the other thing.');
  assert.match(c.deny('other.sh', deny('same')), /Fix: do the other thing/, 'another hook is not a repeat');
  const changed = deny('same').replace('do the other thing', 'fix field runMode');
  assert.match(c.deny('guard.sh', changed), /fix field runMode/);
});
/** Shape of subagent-return-schema-guard's warning in the real run: a first line, then an issue list. */
const SCHEMA_WARN = `[WARN] Subagent return validation surfaced issues.\n\nDescription: "workflow-reviewer-phase1: gate Phase 1"\nIssues:\n  - /handover/status: must be one of approved|rejected|escalated\n  - /checklist/2/evidence: required property missing\n  - /verdict: must be string\n\nFix: correct the return and re-dispatch.\n\nReferences:\n  schemas/subagent-returns/workflow-reviewer.schema.json`;
test('warning: the first archiver warning reaches the model in full (<= 1,200 chars); the repeat collapses (run ids differ)', (t) => {
  t.after(verboseOff());
  const c = createMessageCompactor();
  const first = c.note('playwright-artifact-archiver.sh', ARCHIVER('20260926T110721Z'), 'systemMessage');
  assert.equal(first, ARCHIVER('20260926T110721Z'));
  assert.ok(first.length <= 1200);
  assert.equal(c.note('playwright-artifact-archiver.sh', ARCHIVER('20260926T110910Z'), 'systemMessage'), '[achilles] playwright-artifact-archiver.sh: repeated warning (see earlier).');
});
test('warning: the first schema-guard body reaches the model in full; a second, different one is one line', (t) => {
  t.after(verboseOff());
  const c = createMessageCompactor();
  const second = SCHEMA_WARN.replace('/verdict: must be string', '/handover/next-action: required property missing');
  assert.equal(c.note('subagent-return-schema-guard.sh', SCHEMA_WARN, 'systemMessage'), SCHEMA_WARN);
  const line = c.note('subagent-return-schema-guard.sh', second, 'systemMessage');
  assert.equal(line, '[achilles] subagent-return-schema-guard.sh: workflow-reviewer-phase1: gate Phase 1 return failed validation again — /handover/status: must be one of approved|rejected|escalated. Same return-shape rules as the first warning this session; the full text is in the UI/log.');
  assert.match(c.note('subagent-return-schema-guard.sh', second, 'systemMessage'), /repeated warning/, 'the identical body still collapses');
  // Pruned-run ids and counts differ between archiver messages; they still count as the same warning.
  c.note('a.sh', ARCHIVER('20260926T110721Z'), 'systemMessage');
  assert.match(c.note('a.sh', ARCHIVER('20260926T111023Z').replace('20260926T105516Z', '20260926T110433Z'), 'systemMessage'), /repeated warning/);
});
test('warning: a schema-guard issue list is shown on first sight', (t) => {
  t.after(verboseOff());
  const out = createMessageCompactor().note('subagent-return-schema-guard.sh', SCHEMA_WARN, 'systemMessage');
  for (const issue of ['/handover/status: must be one of', '/checklist/2/evidence: required property missing', '/verdict: must be string']) assert.ok(out.includes(issue), issue);
});
test('warning: a different text is a new key; the same hook with a new first line is shown in full', (t) => {
  t.after(verboseOff());
  const c = createMessageCompactor();
  c.note('g.sh', SCHEMA_WARN, 'systemMessage');
  const other = SCHEMA_WARN.replace('surfaced issues', 'found a missing handover');
  assert.equal(c.note('g.sh', other, 'systemMessage'), other);
  assert.match(c.note('g.sh', SCHEMA_WARN, 'systemMessage'), /repeated warning/);
});
test('warning: over 1,200 chars is cut at a line boundary with the truncation marker', (t) => {
  t.after(verboseOff());
  const long = Array.from({ length: 100 }, (_, i) => `line ${i} ${'x'.repeat(30)}`).join('\n');
  const out = createMessageCompactor().note('h.sh', long, 'systemMessage');
  assert.ok(out.length <= 1200, String(out.length));
  assert.ok(out.endsWith('\n… [achilles] truncated; full text in the UI/log'));
  const kept = out.split('\n').slice(0, -1);
  for (const l of kept) assert.match(l, /^line \d+ x{30}$/, 'whole lines only');
});
test('referencesLine collapses a References block onto one line', () => {
  assert.equal(firstLine(ARCHIVER('R1')), '[WARN] Playwright evidence archived to .achilles/runs/R1 with omissions.');
  assert.equal(referencesLine(ARCHIVER('R1')), 'References: skills/achilles-protocol/references/harness-hooks.md §PostToolUse; .achilles/runs/R1/manifest.json');
});
test('additionalContext is kept (scope-compacted) up to 1000 chars on first sight', (t) => {
  t.after(verboseOff());
  const c = createMessageCompactor();
  assert.equal(c.note('h.sh', 'line one\nline two', 'additionalContext'), 'line one\nline two');
  const long = c.note('h2.sh', Array.from({ length: 100 }, (_, i) => `ctx ${i} ${'z'.repeat(40)}`).join('\n'), 'additionalContext');
  assert.ok(long.length <= 1000, String(long.length));
  assert.ok(long.endsWith('\n… [achilles] truncated; full text in the UI/log'));
});
test('a repeat line quotes the first line capped at 200 chars', (t) => {
  t.after(verboseOff());
  assert.equal(firstLine('w'.repeat(500)).length, 200);
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
test('repeat line: carries the Fix block (<= 300 chars), no doubled period, and falls back without one', (t) => {
  t.after(verboseOff());
  const c = createMessageCompactor();
  const real = `[BLOCKED] Subagent return failed validation.\n\nFix:\n  - To change the artifact: use the Write or Edit tool on the file.\n  - To read it: drop the write-shaped construct.\n\nReferences:\n  skills/orch-skill/SKILL.md\n\n${NOTICE}`;
  c.deny('g.sh', real);
  const rep = c.deny('g.sh', real);
  assert.equal(rep, '[achilles] g.sh: same block as before — [BLOCKED] Subagent return failed validation. Fix: - To change the artifact: use the Write or Edit tool on the file. - To read it: drop the write-shaped construct.');
  assert.doesNotMatch(rep, /\.\./);
  const instead = '[BLOCKED] no.\n\nDo this instead:\n  run the gate first\n\nmore';
  c.deny('h.sh', instead);
  assert.match(c.deny('h.sh', instead), /— \[BLOCKED\] no\. Do this instead: run the gate first$/);
  const long = `[BLOCKED] x.\n\nFix: ${'y'.repeat(600)}`;
  c.deny('l.sh', long);
  assert.ok(fixLines(long).length <= 300);
  c.deny('n.sh', '[BLOCKED] no fix here.');
  assert.equal(c.deny('n.sh', '[BLOCKED] no fix here.'), '[achilles] n.sh: same block as before — [BLOCKED] no fix here. Apply the fix from the earlier message.');
});
test('fixLines: the real compliance-sweep-exit-gate "Do this instead — <what>:" heading is found (hook run on a crafted blocking Stop payload)', (t) => {
  t.after(verboseOff());
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'csg-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  // A transcript with a spec Write and no compliance sweep after it: the gate blocks (exit 2, stderr).
  fs.writeFileSync(path.join(dir, 't.jsonl'), JSON.stringify({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', id: 'w1', name: 'Write', input: { file_path: path.join(dir, 'a.spec.ts'), content: 'x' } }] } }) + '\n');
  const payload = { hook_event_name: 'Stop', session_id: 's1', transcript_path: path.join(dir, 't.jsonl'), cwd: dir, stop_hook_active: false };
  const r = spawnSync('bash', [path.join(pkg, 'hooks', 'compliance-sweep-exit-gate.sh')], { input: JSON.stringify(payload), encoding: 'utf8', env: { ...process.env, ACHILLES_PROTOCOL: '1', ACHILLES_SESSION_STATE_DIR: path.join(dir, 'state') } });
  assert.equal(r.status, 2, r.stderr);
  const reason = r.stderr.trim();
  assert.match(reason, /^Do this instead — run the sweep now, then stop:$/m);
  const fix = fixLines(reason);
  assert.match(fix, /^Do this instead — run the sweep now, then stop: 1\. Read skills\/achilles-protocol\/references\/api-reference\.md/);
  assert.doesNotMatch(fix, /──/);
  assert.ok(fix.length <= 300);
  const c = createMessageCompactor();
  c.deny('compliance-sweep-exit-gate.sh', reason);
  assert.match(c.deny('compliance-sweep-exit-gate.sh', reason), /^\[achilles\] compliance-sweep-exit-gate\.sh: same block as before — \[BLOCKED\] Test code changed in this session, but the Stage-4b compliance sweep never ran\. Do this instead — run the sweep now, then stop: 1\. Read /);
});

// ---- operator-only denies (round-1 fix 3) ----
import { operatorOnly, withOperatorStop, OPERATOR_STOP } from '../extensions/achilles/messages.ts';
test('operatorOnly: the hooks\' operator-recovery denies match; agent-fixable denies do not', () => {
  const hooks = path.join(pkg, 'hooks');
  const src = (f) => fs.readFileSync(path.join(hooks, f), 'utf8');
  // The live texts, cut from the hook sources so a rewording there is caught here.
  const gate = src('lib/pipeline-gate.sh');
  const missing = gate.match(/"\[BLOCKED\] \$\{PIPELINE_MSG_LEDGER_NAME\} is missing[^"]*"/)[0];
  const drift = gate.match(/"\[BLOCKED\] \$\{PIPELINE_MSG_LEDGER_NAME\} does not match[^"]*"/)[0];
  const chain = src('ledger-integrity-chain.sh');
  const mismatch = chain.match(/emit_deny "(\[BLOCKED\] \$\{CHAIN_KEY\} was mutated out of band[\s\S]*?)"\n/)[1];
  const deleted = chain.match(/emit_deny "(\[BLOCKED\] \$\{CHAIN_KEY\} has been deleted out of band[\s\S]*?)"\n/)[1];
  for (const t of [missing, drift, mismatch, deleted, 'only a person may clear this']) assert.ok(operatorOnly(t), t.slice(0, 80));
  const bashGuard = src('protected-artifact-bash-guard.sh').match(/REASON="(\[BLOCKED\][\s\S]*?)\n\n\$\(no_skip/)[1];
  const hookState = src('hook-authored-state-guard.sh');
  const sidecar = hookState.match(/emit_deny "(\[BLOCKED\] \.ledger-integrity\.json is hook-authored state[\s\S]*?)"\n/)[1];
  const monotonic = hookState.match(/Fix: do not remove entries[\s\S]*?not an in-band rewrite\./)[0];
  for (const t of [bashGuard, sidecar, monotonic]) assert.equal(operatorOnly(t), false, t.slice(0, 80));
});
test('withOperatorStop appends the line once and leaves other text alone', () => {
  const r = '[BLOCKED] x. Surface this to the user.';
  const once = withOperatorStop(r, r);
  assert.equal(once, `${r}\n${OPERATOR_STOP}`);
  assert.equal(withOperatorStop(r, once), once);
  assert.equal(withOperatorStop('[BLOCKED] use Edit', 'short'), 'short');
  assert.equal(withOperatorStop(r, '[achilles] h: same block as before — x.'), `[achilles] h: same block as before — x.\n${OPERATOR_STOP}`);
});

// ── round 2: the no-skip contract block and the shaped schema-guard warning ───────────────────────
/** The canonical block, read from the hook library that every pipeline hook interpolates. */
const NO_SKIP = spawnSync('bash', ['-c', `source ${path.join(pkg, 'hooks', 'lib', 'no-skip-messaging.sh')}; no_skip_messaging_block`], { encoding: 'utf8' }).stdout.trimEnd();
/** A schema-guard warning shaped exactly as hooks/subagent-return-schema-guard.sh emits it. */
const GUARD_WARN = (err) => `[WARN] Subagent return validation surfaced issues.

Description: "workflow-reviewer-phase5: gate Phase 5"
Role:        workflow-reviewer

Schema validation errors (schemas/subagent-returns/workflow-reviewer.schema.json):
${err}

References:
  schemas/subagent-returns/README.md
${NO_SKIP}`;

test('the no-skip block is real and large enough to be worth stripping', () => {
  assert.ok(NO_SKIP.includes('Pipeline phases cannot be skipped'));
  assert.ok(NO_SKIP.length > 800, `${NO_SKIP.length} chars`);
});
test('no-skip block: the first sighting keeps it in full, a later different warning gets the pointer', (t) => {
  t.after(verboseOff());
  const c = createMessageCompactor();
  const first = c.note('onboarding-ledger-write-gate.sh', `[WARN] phase 5 not recorded.\n\nReferences:\n  skills/onboarding/SKILL.md\n${NO_SKIP}`, 'systemMessage');
  assert.ok(first.includes('Pipeline phases cannot be skipped'), first);
  const second = c.note('standard-mode-first-pass-guard.sh', `[WARN] pass 2 grouped without permission.\n\nReferences:\n  skills/coverage-expansion/SKILL.md\n${NO_SKIP}`, 'systemMessage');
  assert.ok(!second.includes('Pipeline phases cannot be skipped'));
  assert.ok(second.includes(NO_SKIP_POINTER), second);
  assert.match(second, /^\[WARN\] pass 2 grouped without permission\./);
});
test('no-skip block: a deny carries it once too, then the pointer', (t) => {
  t.after(verboseOff());
  const c = createMessageCompactor();
  const a = c.deny('guard.sh', `[BLOCKED] one\n\nFix: do it right.\n${NO_SKIP}`);
  assert.ok(a.includes('Pipeline phases cannot be skipped'));
  const b = c.deny('guard.sh', `[BLOCKED] two\n\nFix: do it right.\n${NO_SKIP}`);
  assert.ok(!b.includes('Pipeline phases cannot be skipped'));
  assert.ok(b.includes(NO_SKIP_POINTER));
  // The dedupe key ignores the block: two denies that differ only in it still collapse as repeats.
  const c2 = createMessageCompactor();
  c2.deny('g.sh', `[BLOCKED] same\n\nFix: f.\n${NO_SKIP}`);
  assert.match(c2.deny('g.sh', '[BLOCKED] same\n\nFix: f.'), /same block as before/);
});
test('text that only mentions the contract in passing, with no closing Reference line, is left alone', (t) => {
  t.after(verboseOff());
  const c = createMessageCompactor();
  const mention = '[WARN] a.\n\nThis is the onboarding contract in passing.\nKeep this tail.\n' + 'x'.repeat(2500) + '\nAnd this one.';
  c.note('h.sh', `[WARN] first\n${NO_SKIP}`, 'systemMessage');
  const out = c.note('h.sh', mention, 'systemMessage');
  assert.ok(out.includes('Keep this tail.'));
  assert.ok(!out.includes(NO_SKIP_POINTER));
});
// ── I1: only the canonical block closes the match; a short mention keeps its own tail ─────────────
test('a short deny that mentions the onboarding contract keeps its Fix and References blocks', (t) => {
  t.after(verboseOff());
  const c = createMessageCompactor();
  c.deny('first.sh', `[BLOCKED] seed\n\nFix: seed.\n${NO_SKIP}`); // marks the block seen
  const short = `[BLOCKED] Phase 4 ledger row missing for journey "checkout".\n\nThe row is what the next phase reads, and this violates the onboarding contract for the run.\n\nFix: write the ledger row for phase 4, then retry the dispatch with the same description.\n\nReferences:\n  skills/onboarding/SKILL.md\n  schemas/subagent-returns/README.md`;
  assert.ok(short.length > 320 && short.length < 400, `${short.length} chars`);
  const out = c.deny('ledger.sh', short);
  assert.equal(out, short);
  assert.ok(out.includes('Fix: write the ledger row'));
  assert.ok(out.includes('schemas/subagent-returns/README.md'));
  assert.ok(!out.includes(NO_SKIP_POINTER));
});
test('schema-guard: the second and later warnings collapse to role + first error', (t) => {
  t.after(verboseOff());
  const c = createMessageCompactor();
  const full = c.note('subagent-return-schema-guard.sh', GUARD_WARN('PARSE_FAIL: Unexpected token `\u0060` in JSON at position 0'), 'systemMessage');
  assert.match(full, /^\[WARN\] Subagent return validation surfaced issues\./);
  assert.ok(full.includes('PARSE_FAIL'), 'the first sighting carries the detail');
  const next = c.note('subagent-return-schema-guard.sh', GUARD_WARN('SCHEMA_FAIL: /handover must have required property \'next-action\''), 'systemMessage');
  assert.equal(next.split('\n').length, 1, next);
  assert.ok(next.includes('workflow-reviewer return failed validation again'));
  assert.ok(next.includes("SCHEMA_FAIL: /handover must have required property 'next-action'"));
  assert.ok(next.length < 300, `${next.length} chars`);
  // Another hook's warnings are untouched by the schema guard's sighting.
  assert.match(c.note('other.sh', '[WARN] different hook.\n\nDetails here.', 'systemMessage'), /Details here/);
});
test('schema-guard helpers: role and first error come out of the real warning shape', () => {
  assert.equal(warnRole(GUARD_WARN('SCHEMA_FAIL: /verdict must be string')), 'workflow-reviewer');
  assert.equal(firstError(GUARD_WARN('SCHEMA_FAIL: /verdict must be string')), 'SCHEMA_FAIL: /verdict must be string');
  // A warning with an issue-bullet list instead of validator lines.
  assert.equal(firstError(SCHEMA_WARN), '/handover/status: must be one of approved|rejected|escalated');
  assert.equal(warnRole(SCHEMA_WARN), 'workflow-reviewer-phase1: gate Phase 1');
  assert.equal(warnRole('[WARN] nothing to name here.'), '?');
  assert.equal(firstError('[WARN] nothing to name here.'), '');
  assert.match(shapedWarnLine('g.sh', '[WARN] nothing to name here.'), /^\[achilles\] g\.sh: \? return failed validation again\. Same return-shape rules/);
});
test('ACHILLES_PI_VERBOSE=1 keeps the no-skip block and the full schema-guard body', (t) => {
  const prev = process.env.ACHILLES_PI_VERBOSE;
  process.env.ACHILLES_PI_VERBOSE = '1';
  t.after(() => { if (prev === undefined) delete process.env.ACHILLES_PI_VERBOSE; else process.env.ACHILLES_PI_VERBOSE = prev; });
  const c = createMessageCompactor();
  const w = GUARD_WARN('SCHEMA_FAIL: /verdict must be string');
  assert.equal(c.note('subagent-return-schema-guard.sh', w, 'systemMessage'), w);
  assert.equal(c.note('subagent-return-schema-guard.sh', GUARD_WARN('SCHEMA_FAIL: /phase must be integer'), 'systemMessage'), GUARD_WARN('SCHEMA_FAIL: /phase must be integer'));
});
