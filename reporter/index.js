'use strict';
// index.js — the Achilles Playwright reporter.
//
// Three jobs the archiver hook structurally cannot do:
//   1. copy each failing ATTEMPT's evidence the moment that attempt ends,
//      from the resolved config rather than a grepped one;
//   2. keep a local ledger of outcomes across runs, so a failure arrives with
//      its own history attached;
//   3. print a summary that separates flaky from failed and names the evidence.
//
// It composes: add it alongside `html` / `json` / `list`, never instead of
// them. Every side effect is wrapped — see lib/safe.js for why.

const path = require('node:path');

const { createGuard } = require('./lib/safe');
const { projectRoot, resolveCandidates, statCandidates } = require('./lib/paths');
const { OUTCOMES, classify, isEvidenceWorthy, aggregate, isHeel, slowest, isKnownDefect } = require('./lib/classify');
const history = require('./lib/history');
const { RunArchive, pruneRuns, updateLatest, stampClaim } = require('./lib/archive');
const { render, colorEnabled } = require('./lib/format');

function intFromEnv(env, name, fallback) {
  const raw = env[name];
  if (raw === undefined || raw === '') return fallback;
  const n = Number.parseInt(raw, 10);
  return Number.isFinite(n) && n >= 0 ? n : fallback;
}

class AchillesReporter {
  constructor(options) {
    this.options = options || {};
    this.env = this.options.env || process.env;
    this.stream = this.options.stream || process.stdout;
    this.guard = createGuard(this.options.write);
    this.enabled = this.env.ACHILLES_REPORTER !== 'off';
    this.retain = intFromEnv(this.env, 'ACHILLES_ARTIFACT_RETAIN', 5);
    this.maxBytes = intFromEnv(this.env, 'ACHILLES_ARTIFACT_MAX_MB', 512) * 1024 * 1024;
    this.slowestCount = this.options.slowest !== undefined ? this.options.slowest : intFromEnv(this.env, 'ACHILLES_REPORTER_SLOWEST', 3);
    // Naming the three slowest tests in a suite where the slowest takes 5ms is
    // noise; the section earns its place only once a test is actually slow.
    this.slowMs = this.options.slowMs !== undefined ? this.options.slowMs : intFromEnv(this.env, 'ACHILLES_REPORTER_SLOW_MS', 1000);
    this.tests = new Map();
    this.archive = null;
    this.notes = [];
  }

  // Honest: the summary is the only thing written, and only when enabled.
  printsToStdio() {
    return this.enabled;
  }

  onBegin(config, suite) {
    this.startedAt = Date.now();
    if (!this.enabled) return;
    this.guard.run('setup', () => {
      this.config = config;
      this.root = projectRoot(config, process.cwd());
      this.totalTests = suite && typeof suite.allTests === 'function' ? suite.allTests().length : 0;
      if (this.retain > 0) {
        this.archive = new RunArchive(this.root, { maxBytes: this.maxBytes });
      }
      const priors = history.read(this.root);
      this.priors = history.byTest(priors.entries);
      if (priors.dropped > 0) this.notes.push(`history: skipped ${priors.dropped} unreadable ledger line(s)`);
    });
  }

  onTestEnd(test, result) {
    if (!this.enabled) return;
    this.guard.run('attempt', () => {
      const key = test.id || test.titlePath().join(' › ');
      let entry = this.tests.get(key);
      if (!entry) {
        // titlePath() is [project, file, ...describes, title]; the file is
        // reported separately, so drop it and everything before it.
        const parts = test.titlePath().filter(Boolean);
        const fileAt = parts.indexOf(path.basename(test.location.file));
        entry = {
          id: key,
          title: (fileAt >= 0 ? parts.slice(fileAt + 1) : parts).join(' › '),
          file: this.root ? path.relative(this.root, test.location.file).split(path.sep).join('/') : test.location.file,
          project: (test.parent && test.parent.project && test.parent.project()) ? test.parent.project().name : '',
          expectedStatus: test.expectedStatus,
          // Tag or title token, same semantics as bin/self-repair.mjs.
          knownDefect: isKnownDefect(test.titlePath(), test.tags),
          attempts: [],
          ms: 0,
        };
        this.tests.set(key, entry);
      }
      entry.attempts.push({ retry: result.retry, status: result.status });
      entry.ms += result.duration || 0;

      // Copy now — before the next attempt reuses the directory, before the
      // run ends, and regardless of how Playwright was invoked.
      if (this.archive && isEvidenceWorthy(result, test.expectedStatus)) {
        this.archive.recordAttempt({
          testId: key,
          title: entry.title,
          file: entry.file,
          project: entry.project,
          attempt: result.retry,
          status: result.status,
          durationMs: result.duration,
          attachments: result.attachments,
        });
      }
    });
  }

  onError(error) {
    if (!this.enabled) return;
    this.guard.run('runError', () => {
      const msg = (error && (error.message || error.value)) || 'unknown error';
      this.notes.push(`run error: ${String(msg).split('\n')[0].slice(0, 120)}`);
    });
  }

  onEnd(result) {
    if (!this.enabled) return undefined;
    const model = this.guard.run('summary', () => this.buildModel(result), null);
    this.guard.run('history', () => this.persist());
    if (model) {
      this.guard.run('print', () => {
        this.stream.write(render(model, {
          color: colorEnabled(this.stream, this.env),
          width: this.stream.columns || 72,
        }));
      });
    }
    return undefined;
  }

  // Called after every reporter's onEnd has resolved, so the html/json output
  // on disk is final and the claim describes what the hook would see.
  async onExit() {
    if (!this.enabled || !this.archive) return;
    this.guard.run('claim', () => {
      const candidates = this.candidateSet();
      const stats = statCandidates(this.root, candidates);
      if (stats.files === 0) return;
      stampClaim(this.root, this.archive.runId, stats, candidates);
    });
  }

  // ---- internals -----------------------------------------------------------

  /**
   * Resolved on demand, never cached from `onBegin`: Playwright wipes and
   * recreates `outputDir` as the run starts, so a set resolved before any test
   * ran would exclude the very directories the run is about to fill.
   */
  candidateSet() {
    if (!this.config || !this.root) return [];
    return resolveCandidates(this.config, this.root, this.env);
  }

  buildModel(result) {
    const failed = [];
    const flaky = [];
    const counts = { passed: 0, failed: 0, flaky: 0, skipped: 0, knownDefect: 0 };
    const knownDefectPassed = [];
    const all = [];

    for (const entry of this.tests.values()) {
      const outcome = classify(entry.attempts, entry.expectedStatus);
      const agg = aggregate(this.priors ? this.priors.get(entry.id) || [] : []);
      entry.outcome = outcome;
      entry.history = agg;
      all.push(entry);

      if (outcome === OUTCOMES.FAILED) counts.failed += 1;
      else if (outcome === OUTCOMES.FLAKY) counts.flaky += 1;
      else if (outcome === OUTCOMES.SKIPPED) counts.skipped += 1;
      else counts.passed += 1;

      if (entry.knownDefect && outcome !== OUTCOMES.SKIPPED) {
        counts.knownDefect += 1;
        // The anomaly from test-identity.md §2: @known-defect predicts red,
        // so any pass (outright, or on retry) is never silently green.
        if (outcome === OUTCOMES.PASSED || outcome === OUTCOMES.FLAKY) {
          knownDefectPassed.push(`${entry.file} › ${entry.title}`);
        }
      }

      const evidence = this.archive ? this.archive.evidenceFor(entry.id) : [];
      if (outcome === OUTCOMES.FAILED) {
        failed.push({ title: `${entry.file} › ${entry.title}`, history: agg, heel: isHeel(agg), evidence });
      } else if (outcome === OUTCOMES.FLAKY) {
        const passedIdx = entry.attempts.findIndex((a) => a.status === (entry.expectedStatus || 'passed'));
        flaky.push({
          title: `${entry.file} › ${entry.title}`,
          history: agg,
          attempts: entry.attempts.length,
          passedOnAttempt: passedIdx < 0 ? entry.attempts.length - 1 : passedIdx,
          evidence,
        });
      }
    }

    const wrote = this.guard.run('manifest', () => (this.archive ? this.archive.writeManifest({
      retention: { keep: this.retain },
      sources: this.candidateSet().map((c) => ({ path: c.path, kind: c.kind, resolvedFrom: c.resolvedFrom })),
    }) : false), false);
    if (wrote) {
      this.guard.run('retention', () => {
        const pruned = pruneRuns(this.root, this.retain);
        updateLatest(this.root, this.archive.runId);
        if (pruned.length) this.notes.push(`pruned ${pruned.length} older run(s): ${pruned.join(', ')}`);
      });
    }
    if (this.archive && this.archive.skipped.length) {
      this.notes.push(`${this.archive.skipped.length} attachment(s) not archived (see manifest.json)`);
    }

    return {
      counts,
      failed,
      flaky,
      knownDefectPassed,
      slowest: slowest(all.filter((t) => t.outcome !== OUTCOMES.SKIPPED && t.ms >= this.slowMs).map((t) => ({
        title: `${t.file} › ${t.title}`, ms: t.ms, history: t.history,
      })), this.slowestCount),
      durationMs: this.startedAt ? Date.now() - this.startedAt : 0,
      evidenceDir: wrote ? path.relative(this.root, this.archive.dir).split(path.sep).join('/') : null,
      status: result && result.status,
      notes: this.notes,
    };
  }

  persist() {
    if (!this.root || this.tests.size === 0) return;
    const runId = this.archive ? this.archive.runId : new Date().toISOString().slice(0, 19).replace(/[-:]/g, '') + 'Z';
    const ts = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
    const entries = [];
    for (const entry of this.tests.values()) {
      entries.push({
        v: 1,
        runId,
        ts,
        id: entry.id,
        title: entry.title,
        file: entry.file,
        project: entry.project,
        status: entry.outcome || classify(entry.attempts, entry.expectedStatus),
        attempts: entry.attempts.length,
        ms: entry.ms,
      });
    }
    history.append(this.root, entries, history.limits(this.env));
  }
}

module.exports = AchillesReporter;
module.exports.default = AchillesReporter;
module.exports.AchillesReporter = AchillesReporter;
