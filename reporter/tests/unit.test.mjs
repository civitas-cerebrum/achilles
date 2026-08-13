// Unit coverage for the reporter's pure logic: classification, aggregation,
// pruning, formatting, and the containment layer that keeps a broken reporter
// from failing a run.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { classify, aggregate, isHeel, isEvidenceWorthy, slowest, median, OUTCOMES } = require('../lib/classify.js');
const history = require('../lib/history.js');
const { render, historyLine, colorEnabled, duration } = require('../lib/format.js');
const { createGuard } = require('../lib/safe.js');
const { uniqueDest, isRunId, allocateRunId } = require('../lib/archive.js');
const { relToRoot, resolveCandidates, statCandidates } = require('../lib/paths.js');

const A = (status, retry) => ({ status, retry });

// ---------------------------------------------------------------------------
// classification
// ---------------------------------------------------------------------------

test('single passing attempt is passed', () => {
  assert.equal(classify([A('passed', 0)], 'passed'), OUTCOMES.PASSED);
});

test('every attempt failing is failed, not flaky', () => {
  assert.equal(classify([A('failed', 0), A('failed', 1)], 'passed'), OUTCOMES.FAILED);
});

test('fail then pass is flaky, not failed and not passed', () => {
  assert.equal(classify([A('failed', 0), A('passed', 1)], 'passed'), OUTCOMES.FLAKY);
});

test('timeout then pass is flaky', () => {
  assert.equal(classify([A('timedOut', 0), A('passed', 1)], 'passed'), OUTCOMES.FLAKY);
});

test('attempts out of order still classify by attempt index', () => {
  assert.equal(classify([A('passed', 1), A('failed', 0)], 'passed'), OUTCOMES.FLAKY);
});

test('skipped stays skipped', () => {
  assert.equal(classify([A('skipped', 0)], 'passed'), OUTCOMES.SKIPPED);
  assert.equal(classify([], 'passed'), OUTCOMES.SKIPPED);
});

test('a test expected to fail that fails is not reported as a failure', () => {
  assert.equal(classify([A('failed', 0)], 'failed'), OUTCOMES.EXPECTED_FAILURE);
});

test('a test expected to fail that passes is a failure', () => {
  assert.equal(classify([A('passed', 0)], 'failed'), OUTCOMES.FAILED);
});

test('interrupted attempt with no pass is failed', () => {
  assert.equal(classify([A('interrupted', 0)], 'passed'), OUTCOMES.FAILED);
});

test('evidence is kept for every non-passing attempt and no passing one', () => {
  assert.equal(isEvidenceWorthy({ status: 'failed' }, 'passed'), true);
  assert.equal(isEvidenceWorthy({ status: 'timedOut' }, 'passed'), true);
  assert.equal(isEvidenceWorthy({ status: 'passed' }, 'passed'), false);
  assert.equal(isEvidenceWorthy({ status: 'skipped' }, 'passed'), false);
});

// ---------------------------------------------------------------------------
// history aggregation
// ---------------------------------------------------------------------------

const entry = (runId, status, ms = 100) => ({ runId, status, ms, ts: `2026-08-1${runId.slice(-1)}T00:00:00Z` });

test('aggregate counts failures, flakes and passes separately', () => {
  const agg = aggregate([
    entry('r1', 'passed'), entry('r2', 'failed'), entry('r3', 'flaky'), entry('r4', 'failed'),
  ]);
  assert.equal(agg.runs, 4);
  assert.equal(agg.fails, 2);
  assert.equal(agg.flakes, 1);
  assert.equal(agg.passes, 1);
  assert.equal(agg.failRate, 0.75);
});

test('runsSincePass counts back from the newest entry', () => {
  const agg = aggregate([entry('r1', 'passed'), entry('r2', 'failed'), entry('r3', 'failed')]);
  assert.equal(agg.runsSincePass, 2);
});

test('a test that never passed reports null rather than zero', () => {
  const agg = aggregate([entry('r1', 'failed'), entry('r2', 'failed')]);
  assert.equal(agg.runsSincePass, null);
});

test('lastChange names the most recent transition', () => {
  const agg = aggregate([entry('r1', 'passed'), entry('r2', 'passed'), entry('r3', 'failed'), entry('r4', 'failed')]);
  assert.deepEqual(agg.lastChange, { runId: 'r3', from: 'passed', to: 'failed', runsAgo: 1 });
});

test('empty history is not an error', () => {
  const agg = aggregate([]);
  assert.equal(agg.runs, 0);
  assert.equal(agg.medianMs, null);
});

test('median of durations', () => {
  assert.equal(median([10, 30, 20]), 20);
  assert.equal(median([10, 20, 30, 40]), 25);
  assert.equal(median([]), null);
});

test('heel needs enough history to mean anything', () => {
  assert.equal(isHeel(aggregate([entry('r1', 'failed')])), false, 'one failure is not chronic');
  assert.equal(isHeel(aggregate([entry('r1', 'failed'), entry('r2', 'failed'), entry('r3', 'failed')])), true);
  assert.equal(isHeel(aggregate([entry('r1', 'failed'), entry('r2', 'passed'), entry('r3', 'passed'), entry('r4', 'passed')])), false);
});

test('slowest ranks by duration and reports the delta against the median', () => {
  const out = slowest([
    { title: 'a', ms: 100, history: { medianMs: 100 } },
    { title: 'b', ms: 900, history: { medianMs: 300 } },
    { title: 'c', ms: 500, history: { medianMs: null } },
  ], 2);
  assert.deepEqual(out.map((t) => t.title), ['b', 'c']);
  assert.equal(out[0].deltaPct, 200);
  assert.equal(out[1].deltaPct, null);
});

// ---------------------------------------------------------------------------
// ledger: parsing, pruning, appending
// ---------------------------------------------------------------------------

test('a corrupt ledger degrades to the readable lines', () => {
  const { entries, dropped } = history.parse([
    '{"id":"a","runId":"r1","status":"passed"}',
    'not json at all',
    '{"id":"b","runId":"r1"',
    '{"noIdField":true,"runId":"r1"}',
    '{"id":"c","runId":"r2","status":"failed"}',
  ].join('\n'));
  assert.equal(entries.length, 2);
  assert.equal(dropped, 3);
});

test('prune keeps the newest N runs and drops the rest whole', () => {
  const entries = [];
  for (let i = 1; i <= 5; i += 1) {
    entries.push({ id: 'a', runId: `r${i}`, ts: `2026-08-0${i}T00:00:00Z`, status: 'passed' });
    entries.push({ id: 'b', runId: `r${i}`, ts: `2026-08-0${i}T00:00:00Z`, status: 'passed' });
  }
  const kept = history.prune(entries, { keepRuns: 2, keepDays: 0, maxEntries: 0 }, Date.parse('2026-08-06T00:00:00Z'));
  assert.equal(kept.length, 4);
  assert.deepEqual([...new Set(kept.map((e) => e.runId))], ['r4', 'r5']);
});

test('prune drops entries past the age bound', () => {
  const entries = [
    { id: 'a', runId: 'old', ts: '2026-01-01T00:00:00Z', status: 'passed' },
    { id: 'a', runId: 'new', ts: '2026-08-11T00:00:00Z', status: 'passed' },
  ];
  const kept = history.prune(entries, { keepRuns: 50, keepDays: 30, maxEntries: 0 }, Date.parse('2026-08-12T00:00:00Z'));
  assert.deepEqual(kept.map((e) => e.runId), ['new']);
});

test('prune enforces the hard entry ceiling oldest-first', () => {
  const entries = [];
  for (let i = 1; i <= 10; i += 1) entries.push({ id: `t${i}`, runId: `r${i}`, ts: `2026-08-0${i % 9}T00:00:00Z`, status: 'passed' });
  const kept = history.prune(entries, { keepRuns: 50, keepDays: 0, maxEntries: 3 }, Date.now());
  assert.equal(kept.length, 3);
});

test('prune is deterministic for the same input', () => {
  const entries = [];
  for (let i = 1; i <= 6; i += 1) entries.push({ id: 'a', runId: `r${i}`, ts: `2026-08-0${i}T00:00:00Z`, status: 'passed' });
  const now = Date.parse('2026-08-07T00:00:00Z');
  assert.deepEqual(history.prune(entries, { keepRuns: 3 }, now), history.prune(entries, { keepRuns: 3 }, now));
});

test('append writes, then prunes, and leaves a parseable ledger', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ach-hist-'));
  for (let i = 1; i <= 4; i += 1) {
    history.append(root, [{ v: 1, id: 'a', runId: `r${i}`, ts: `2026-08-0${i}T00:00:00Z`, status: 'passed', ms: 10 }], { keepRuns: 2, keepDays: 0, maxEntries: 0 });
  }
  const { entries, dropped } = history.read(root);
  assert.equal(dropped, 0);
  assert.deepEqual(entries.map((e) => e.runId), ['r3', 'r4']);
  fs.rmSync(root, { recursive: true, force: true });
});

test('reading a ledger that does not exist yields no history, not an error', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ach-hist-'));
  assert.deepEqual(history.read(root), { entries: [], dropped: 0 });
  fs.rmSync(root, { recursive: true, force: true });
});

// ---------------------------------------------------------------------------
// formatting
// ---------------------------------------------------------------------------

const model = {
  counts: { passed: 3, failed: 1, flaky: 1, skipped: 1 },
  failed: [{
    title: 'tests/e2e/a.spec.js › checkout completes',
    history: aggregate([entry('r1', 'failed'), entry('r2', 'failed'), entry('r3', 'failed')]),
    heel: true,
    evidence: ['.achilles/runs/20260812T120000Z/artifacts/test-results/a/trace.zip'],
  }],
  flaky: [{
    title: 'tests/e2e/b.spec.js › session survives reload',
    history: aggregate([entry('r1', 'passed')]),
    attempts: 2,
    passedOnAttempt: 1,
    evidence: [],
  }],
  slowest: [{ title: 'tests/e2e/c.spec.js › search', ms: 18200, deltaPct: 42 }],
  durationMs: 12400,
  evidenceDir: '.achilles/runs/20260812T120000Z',
  notes: [],
};

test('summary separates flaky from failed', () => {
  const text = render(model, { color: false });
  const failedAt = text.indexOf('\n   failed');
  const flakyAt = text.indexOf('\n   flaky');
  assert.ok(failedAt > 0 && flakyAt > 0, 'both sections present');
  assert.ok(failedAt < flakyAt, 'failures first');
  assert.ok(text.includes('session survives reload'));
  assert.ok(text.includes('passed on attempt 2 of 2'));
});

test('summary carries history and the evidence path inline', () => {
  const text = render(model, { color: false });
  assert.ok(text.includes('failed 3 of last 3 runs'), text);
  assert.ok(text.includes('.achilles/runs/20260812T120000Z/artifacts/test-results/a/trace.zip'));
  assert.ok(text.includes('heel'));
});

test('a first-time failure is not dressed up as a chronic one', () => {
  const fresh = { ...model, failed: [{ title: 'x › y', history: aggregate([]), heel: false, evidence: [] }] };
  const text = render(fresh, { color: false });
  assert.ok(text.includes('no prior local runs'));
  assert.ok(!text.includes('heel'));
});

test('no ANSI escapes when colour is off', () => {
  const text = render(model, { color: false });
  assert.ok(!/\[/.test(text), 'plain text only');
});

test('ANSI escapes when colour is on', () => {
  assert.ok(/\[/.test(render(model, { color: true })));
});

test('colour follows TTY, NO_COLOR, TERM and FORCE_COLOR', () => {
  assert.equal(colorEnabled({ isTTY: true }, {}), true);
  assert.equal(colorEnabled({ isTTY: false }, {}), false, 'piped output is plain');
  assert.equal(colorEnabled({ isTTY: true }, { NO_COLOR: '1' }), false);
  assert.equal(colorEnabled({ isTTY: true }, { TERM: 'dumb' }), false);
  assert.equal(colorEnabled({ isTTY: false }, { FORCE_COLOR: '1' }), true);
});

test('durations read as humans write them', () => {
  assert.equal(duration(400), '400ms');
  assert.equal(duration(12400), '12.4s');
  assert.equal(duration(125000), '2m5s');
});

test('historyLine says what it knows and nothing more', () => {
  assert.equal(historyLine(aggregate([])), 'no prior local runs');
  assert.equal(historyLine(aggregate([entry('r1', 'passed')])), 'clean of last 1 run');
  assert.equal(historyLine(aggregate([entry('r1', 'flaky'), entry('r2', 'passed')])), 'flaky in 1 of last 2 runs · flaky → passed last run');
  assert.ok(historyLine(aggregate([entry('r1', 'failed'), entry('r2', 'failed')])).includes('no clean run recorded'));
});

// ---------------------------------------------------------------------------
// containment
// ---------------------------------------------------------------------------

test('guard swallows a throw, returns the fallback, and reports once', () => {
  const lines = [];
  const guard = createGuard((l) => lines.push(l));
  const result = guard.run('op', () => { throw new Error('disk on fire'); }, 'fallback');
  assert.equal(result, 'fallback');
  guard.run('op', () => { throw new Error('again'); }, 'fallback');
  assert.equal(lines.length, 1, 'one line per operation, not per occurrence');
  assert.match(lines[0], /op skipped — disk on fire/);
});

test('guard stops talking after a handful of distinct failures', () => {
  const lines = [];
  const guard = createGuard((l) => lines.push(l));
  for (let i = 0; i < 20; i += 1) guard.run(`op${i}`, () => { throw new Error('x'); });
  assert.ok(lines.length <= 6, `bounded output, got ${lines.length}`);
});

// ---------------------------------------------------------------------------
// paths and archive naming
// ---------------------------------------------------------------------------

test('paths outside the project root are rejected', () => {
  assert.equal(relToRoot('/a/b', '/a/b/c/d'), 'c/d');
  assert.equal(relToRoot('/a/b', '/a/x'), null);
  assert.equal(relToRoot('/a/b', '/a/b'), null);
});

test('candidate resolution reads the resolved config, including a computed outputDir', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ach-cand-'));
  const computed = path.join(root, 'build', 'pw-out');
  fs.mkdirSync(computed, { recursive: true });
  fs.writeFileSync(path.join(computed, 'f.txt'), 'x');
  fs.mkdirSync(path.join(root, 'playwright-report'), { recursive: true });
  fs.writeFileSync(path.join(root, 'playwright-report', 'index.html'), 'x');
  const config = {
    configFile: path.join(root, 'playwright.config.ts'),
    projects: [{ name: 'chromium', outputDir: computed }],
    reporter: [['html', {}], [path.join(root, 'reporter.js')]],
  };
  const candidates = resolveCandidates(config, root, {});
  assert.deepEqual(candidates.map((c) => c.path).sort(), ['build/pw-out', 'playwright-report']);
  const stats = statCandidates(root, candidates);
  assert.equal(stats.files, 2);
  assert.ok(stats.newestMtime > 0);
  fs.rmSync(root, { recursive: true, force: true });
});

test('a second attempt never overwrites the first attempt evidence', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ach-dest-'));
  const first = path.join(dir, 'trace.zip');
  assert.equal(uniqueDest(first, 0), first);
  fs.writeFileSync(first, 'a');
  assert.equal(uniqueDest(first, 1), path.join(dir, 'trace.attempt1.zip'));
  fs.rmSync(dir, { recursive: true, force: true });
});

test('run ids match the shape the archiver hook prunes', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ach-id-'));
  const id = allocateRunId(root, Date.parse('2026-08-12T13:05:01Z'));
  assert.equal(id, '20260812T130501Z');
  assert.ok(isRunId(id));
  assert.ok(isRunId('20260812T130501Z-2'));
  assert.ok(!isRunId('latest'));
  assert.ok(!isRunId('.last-archive.json'));
  fs.rmSync(root, { recursive: true, force: true });
});
