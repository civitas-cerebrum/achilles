// Integration coverage: the reporter driven by REAL Playwright runs, against a
// fixture project with a passing test, a deterministically failing test, a test
// that fails once then passes, and a skipped test. Asserted end-to-end —
// per-attempt evidence on disk, history accumulating across two runs, the flake
// classified as flaky rather than failed — and paired with the archiver hook,
// because a consumer never runs one without the other.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const fixture = path.join(here, 'fixture');
const playwright = path.join(repo, 'node_modules', '.bin', 'playwright');
const archiverHook = path.join(repo, 'hooks', 'playwright-artifact-archiver.sh');

const made = [];
function project() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ach-reporter-'));
  made.push(dir);
  fs.cpSync(fixture, dir, { recursive: true });
  fs.symlinkSync(path.join(repo, 'node_modules'), path.join(dir, 'node_modules'));
  fs.mkdirSync(path.join(dir, '.git'));
  return dir;
}

function run(dir, env) {
  const result = spawnSync(process.execPath, [playwright, 'test'], {
    cwd: dir,
    encoding: 'utf8',
    env: { ...process.env, NO_COLOR: '1', CI: '', ACHILLES_REPORTER_ENTRY: path.join(repo, 'reporter', 'index.js'), ...(env || {}) },
  });
  return { code: result.status, out: `${result.stdout}${result.stderr}` };
}

function archives(dir) {
  const root = path.join(dir, '.achilles', 'runs');
  if (!fs.existsSync(root)) return [];
  return fs.readdirSync(root).filter((n) => /^\d{8}T\d{6}Z(-\d+)?$/.test(n)).sort();
}

function manifest(dir) {
  const ids = archives(dir);
  return JSON.parse(fs.readFileSync(path.join(dir, '.achilles', 'runs', ids[ids.length - 1], 'manifest.json'), 'utf8'));
}

function ledger(dir) {
  const file = path.join(dir, '.achilles', 'history', 'tests.ndjson');
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
}

function fireHook(dir, event = 'PostToolUse') {
  const payload = JSON.stringify({
    hook_event_name: event,
    tool_name: event === 'PostToolUse' ? 'Bash' : undefined,
    tool_input: { command: 'npx playwright test' },
    cwd: dir,
  });
  const result = spawnSync('bash', [archiverHook], { input: payload, encoding: 'utf8' });
  return { code: result.status, out: result.stdout };
}

process.on('exit', () => {
  for (const dir of made) { try { fs.rmSync(dir, { recursive: true, force: true }); } catch { /* best effort */ } }
});

test('one run: every non-passing attempt is archived under its own attempt', () => {
  const dir = project();
  const { code, out } = run(dir);

  assert.equal(code, 1, 'the fixture has a genuinely failing test');
  assert.equal(archives(dir).length, 1, 'exactly one run archive');

  const m = manifest(dir);
  assert.equal(m.schema, 'playwright-run-archive/v1', 'same manifest schema as the archiver hook');
  assert.equal(m.producer, 'reporter');

  const red = m.attempts.filter((a) => a.title.includes('always red'));
  assert.deepEqual(red.map((a) => a.attempt).sort(), [0, 1], 'both attempts of the always-failing test recorded');

  // Attempt 0 is the honest failure; the retry is a separate artifact. Both
  // must survive, with their own contents.
  const bodies = red.flatMap((a) => a.files.map((f) => fs.readFileSync(path.join(dir, f.archived), 'utf8')));
  assert.ok(bodies.includes('attempt 0'), 'attempt 0 evidence archived');
  assert.ok(bodies.includes('attempt 1'), 'attempt 1 evidence archived');
  assert.equal(new Set(red.flatMap((a) => a.files.map((f) => f.archived))).size, bodies.length, 'no attempt overwrote another');

  // The failing attempt of the flaky test is preserved even though the test
  // ended up green — that attempt is the only record of what went wrong.
  const flakyAttempts = m.attempts.filter((a) => a.title.includes('red then green'));
  assert.deepEqual(flakyAttempts.map((a) => a.attempt), [0]);
  assert.equal(flakyAttempts[0].status, 'failed');

  // Nothing is archived for a test that passed first time.
  assert.equal(m.attempts.filter((a) => a.title.includes('steady')).length, 0);

  // Copies, never moves: the originals are untouched.
  assert.ok(fs.existsSync(path.join(dir, 'test-results')), 'outputDir still intact');

  assert.ok(out.includes('achilles'), 'the summary printed');
  assert.ok(!/\[/.test(out), 'no ANSI when not a TTY');
});

test('the flake is classified flaky, and the outright failure failed', () => {
  const dir = project();
  const { out } = run(dir);

  const entries = ledger(dir);
  const find = (name) => entries.find((e) => e.title.endsWith(name));
  assert.equal(find('always red').status, 'failed');
  assert.equal(find('red then green').status, 'flaky', 'passed on retry is flaky, not failed');
  assert.equal(find('red then green').attempts, 2);
  assert.equal(find('steady').status, 'passed');
  assert.equal(find('skipped one').status, 'skipped');

  const failedAt = out.indexOf('   failed');
  const flakyAt = out.indexOf('   flaky');
  assert.ok(failedAt > -1 && flakyAt > failedAt, 'flaky is its own section, after failures');
  assert.ok(out.slice(flakyAt).includes('red then green'), 'the flake is listed as flaky');
  assert.ok(out.slice(failedAt, flakyAt).includes('always red'), 'the outright failure is listed as failed');
});

test('history accumulates across runs and the second run knows what the first did', () => {
  const dir = project();
  run(dir);
  const afterOne = ledger(dir);
  assert.equal(afterOne.length, 4, 'one entry per test');
  assert.equal(new Set(afterOne.map((e) => e.runId)).size, 1);
  assert.ok(run(dir).out.includes('failed 1 of last 1 run'), 'run 2 reports what run 1 recorded');

  const afterTwo = ledger(dir);
  assert.equal(afterTwo.length, 8);
  assert.equal(new Set(afterTwo.map((e) => e.runId)).size, 2, 'two distinct runs recorded');

  const third = run(dir);
  assert.ok(third.out.includes('failed 2 of last 2 runs'), 'history compounds, it does not reset');
  assert.equal(ledger(dir).length, 12);
});

test('history is bounded and pruned deterministically', () => {
  const dir = project();
  run(dir, { ACHILLES_HISTORY_RUNS: '2' });
  run(dir, { ACHILLES_HISTORY_RUNS: '2' });
  run(dir, { ACHILLES_HISTORY_RUNS: '2' });
  const entries = ledger(dir);
  assert.equal(new Set(entries.map((e) => e.runId)).size, 2, 'the oldest run was pruned out of the ledger');
  assert.equal(entries.length, 8);
});

test('archived runs are retained to the same bound the hook uses', () => {
  const dir = project();
  run(dir, { ACHILLES_ARTIFACT_RETAIN: '2' });
  run(dir, { ACHILLES_ARTIFACT_RETAIN: '2' });
  run(dir, { ACHILLES_ARTIFACT_RETAIN: '2' });
  assert.equal(archives(dir).length, 2, 'oldest archive pruned, newest two kept');
});

// ---------------------------------------------------------------------------
// Paired with the hook. The hook ships one release ahead of the reporter, so
// consumers run hook-alone for a while and then hook-plus-reporter. Every other
// case file in hooks/tests/ covers hook-alone; these cover the combination.
// ---------------------------------------------------------------------------

test('the hook no-ops on a run the reporter already claimed', () => {
  const dir = project();
  run(dir);
  const before = archives(dir);
  assert.equal(before.length, 1);

  const claim = JSON.parse(fs.readFileSync(path.join(dir, '.achilles', 'runs', '.last-archive.json'), 'utf8'));
  assert.equal(claim.claimedBy, 'reporter');
  assert.equal(claim.complete, true);
  assert.ok(claim.candidates.files > 0);

  const hook = fireHook(dir);
  assert.equal(hook.code, 0);
  assert.deepEqual(archives(dir), before, 'the hook did not duplicate the reporter archive');
  assert.equal(hook.out.trim(), '', 'and said nothing about it');

  const stop = fireHook(dir, 'Stop');
  assert.deepEqual(archives(dir), before, 'the Stop backstop honours the claim too');
  assert.equal(stop.code, 0);
});

test('the hook still archives when the artifacts changed after the claim', () => {
  const dir = project();
  run(dir);
  const before = archives(dir);

  // A run the reporter was not wired into — the exact gap the hook covers.
  fs.writeFileSync(path.join(dir, 'test-results', 'unclaimed.txt'), 'evidence from a run with no reporter');
  fireHook(dir);

  const after = archives(dir);
  assert.equal(after.length, before.length + 1, 'a claim never suppresses artifacts the reporter did not see');
  const fresh = JSON.parse(fs.readFileSync(path.join(dir, '.achilles', 'runs', after[after.length - 1], 'manifest.json'), 'utf8'));
  assert.equal(fresh.producer, undefined, "the new archive is the hook's own");
  assert.ok(fs.existsSync(path.join(dir, '.achilles', 'runs', after[after.length - 1], 'artifacts', 'test-results', 'unclaimed.txt')));
});

// ---------------------------------------------------------------------------
// Containment: a reporter that cannot do its job must not change the run's
// verdict. Playwright turns an exception thrown from a reporter callback into a
// run-level error and exit code 1 — a green suite would go red.
// ---------------------------------------------------------------------------

test('an unwritable archive root does not change the run outcome', () => {
  const dir = project();
  // `.achilles` as a regular file: every mkdir under it fails with ENOTDIR.
  fs.writeFileSync(path.join(dir, '.achilles'), 'not a directory');

  const { code, out } = run(dir, { FIXTURE_RETRIES: '0' });
  assert.equal(code, 1, 'exit code still reflects the failing test, nothing more');
  assert.ok(out.includes('always red'), 'the run still reported its tests');
  assert.ok(!out.includes('errors were not a part of any test'), 'the reporter did not inject a run-level error');
});

test('a green suite stays green when the reporter cannot write anything', () => {
  const dir = project();
  fs.rmSync(path.join(dir, 'tests', 'suite.spec.js'));
  fs.writeFileSync(path.join(dir, 'tests', 'suite.spec.js'), [
    "const { test, expect } = require('@playwright/test');",
    "test('green', async () => { expect(1).toBe(1); });",
  ].join('\n'));
  fs.writeFileSync(path.join(dir, '.achilles'), 'not a directory');

  const { code, out } = run(dir);
  assert.equal(code, 0, 'a broken reporter is never the reason a green suite goes red');
  assert.ok(!out.includes('errors were not a part of any test'));
});

test('a corrupt ledger reads as no history and the run continues', () => {
  const dir = project();
  run(dir);
  const file = path.join(dir, '.achilles', 'history', 'tests.ndjson');
  const good = fs.readFileSync(file, 'utf8');
  fs.writeFileSync(file, `${good.slice(0, good.length / 2)}\n   not json {{{\n`);

  const { code, out } = run(dir);
  assert.equal(code, 1, 'still just the failing test');
  assert.ok(out.includes('unreadable ledger line'), 'the damage is reported, not hidden');
  assert.ok(out.includes('achilles'), 'the summary still printed');
  assert.ok(ledger(dir).length > 0, 'and the ledger is usable again afterwards');
});

test('the reporter can be turned off entirely', () => {
  const dir = project();
  const { code, out } = run(dir, { ACHILLES_REPORTER: 'off' });
  assert.equal(code, 1);
  assert.equal(archives(dir).length, 0, 'no archive');
  assert.equal(ledger(dir).length, 0, 'no ledger');
  assert.ok(!out.includes('── achilles'), 'no summary');
});
