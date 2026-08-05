#!/usr/bin/env node
// self-repair.mjs — external driver for the self-repair entrypoint.
//
// Restores a Playwright suite to a green-or-explained state without a human
// in the loop: baseline the suite, classify failures (deterministic vs
// flaky), spawn one `claude -p` worker subprocess per red spec file (each
// worker loads the failure-diagnosis skill), verify the heals with re-runs,
// and write an audit-grade report. The interactive twin of this pipeline is
// skills/self-repair/SKILL.md — same stages, Agent-tool subagents instead of
// subprocesses, same worker report schema.
//
// Consumers reach this through the `achilles-self-repair` bin, wired into
// `npm run test:repair` by the onboarding scaffold (Phase 1).
//
// Exit codes: 0 = every test green or explained (app-bug / quarantined /
// operator-pending), 2 = unresolved tests remain, 1 = driver error.

import { spawn } from 'node:child_process';
import {
  mkdirSync,
  readFileSync,
  writeFileSync,
  appendFileSync,
  existsSync,
  rmSync,
} from 'node:fs';
import { join, dirname, resolve, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const PKG_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(import.meta.url);

// ---------------------------------------------------------------------------
// CLI parsing
// ---------------------------------------------------------------------------

const HELP = `achilles-self-repair — autonomous per-file suite repair

Usage: achilles-self-repair [options] [playwright-filter...]

Positional args are passed to \`playwright test\` as test filters, scoping
the baseline (and therefore the repair) to matching spec files.

Modes:
  (default)             Run the repair pipeline
  --init-scripts        Scan package.json for suite-scoped Playwright run
                        scripts and generate one test:repair:<flow> preset per
                        flow (idempotent; never overwrites existing scripts)

Options:
  --baseline-runs <n>   Baseline runs used to classify flake (default 3)
  --baseline-mode <m>   focus (default) — run 1 covers the full scope, runs
                        2..N are FAILURE RERUNS scoped to the red files only,
                        with --trace on and the analysis timeout cap; cost
                        scales with failures, not suite size.
                        full — every baseline run covers the full scope with
                        the suite's own timeouts (for suites with cross-file
                        state coupling).
  --timeout-cap <s>     Per-test timeout cap applied to failure reruns
                        (default 60; 0 disables). Analysis runs only need the
                        failure signature, not full-length timeout burn.
                        Discovery and verification runs always use the
                        suite's own timeouts — a heal is only proven under
                        real conditions.
  --rerun-delay <s>     Wall-clock spacing between failure reruns (default 0).
                        Use for incident-shaped failures: a 3/3-red snapshot
                        taken inside one tight window can be a time-varying
                        app incident, not a deterministic failure.
  --verify-runs <n>     Post-repair verification runs, suite order (default 3)
  --concurrency <n>     Parallel claude workers (default 2)
  --max-rounds <n>      Fan-out rounds before declaring unresolved (default 2)
  --worker-timeout <m>  Per-worker timeout in minutes (default 30)
  --model <name>        Model passed to claude workers (default: claude default)
  --claude-bin <path>   Claude Code binary (default: claude)
  --project <name>      Playwright --project value, passed through
  --grep <re>           Playwright --grep value, passed through
  --grep-invert <re>    Playwright --grep-invert value, passed through
  --keep-permissions    Run workers WITHOUT --dangerously-skip-permissions
                        (workers will stall on permission prompts; only useful
                        with a pre-approved settings allowlist)
  --dry-run             Baseline + classification + plan only; no workers
  --json                Emit NDJSON events on stdout instead of human lines
  -h, --help            Show this help
`;

function parseArgs(argv) {
  const opts = {
    baselineRuns: 3,
    baselineMode: 'focus',
    timeoutCapSec: 60,
    rerunDelaySec: 0,
    verifyRuns: 3,
    concurrency: 2,
    maxRounds: 2,
    workerTimeoutMin: 30,
    model: null,
    claudeBin: 'claude',
    project: null,
    grep: null,
    grepInvert: null,
    skipPermissions: true,
    dryRun: false,
    initScripts: false,
    json: false,
    filters: [],
  };
  const num = (flag, v) => {
    const n = Number(v);
    if (!Number.isInteger(n) || n < (flag === '--max-rounds' ? 0 : 1)) {
      fail(`${flag} expects a positive integer, got: ${v}`);
    }
    return n;
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case '--baseline-runs': opts.baselineRuns = num(a, argv[++i]); break;
      case '--baseline-mode': {
        const m = argv[++i];
        if (m !== 'focus' && m !== 'full') fail(`--baseline-mode expects focus|full, got: ${m}`);
        opts.baselineMode = m;
        break;
      }
      case '--timeout-cap': {
        const n = Number(argv[++i]);
        if (!Number.isInteger(n) || n < 0) fail(`--timeout-cap expects a non-negative integer, got: ${argv[i]}`);
        opts.timeoutCapSec = n;
        break;
      }
      case '--rerun-delay': {
        const n = Number(argv[++i]);
        if (!Number.isInteger(n) || n < 0) fail(`--rerun-delay expects a non-negative integer, got: ${argv[i]}`);
        opts.rerunDelaySec = n;
        break;
      }
      case '--verify-runs': opts.verifyRuns = num(a, argv[++i]); break;
      case '--concurrency': opts.concurrency = num(a, argv[++i]); break;
      case '--max-rounds': opts.maxRounds = num(a, argv[++i]); break;
      case '--worker-timeout': opts.workerTimeoutMin = num(a, argv[++i]); break;
      case '--model': opts.model = argv[++i]; break;
      case '--claude-bin': opts.claudeBin = argv[++i]; break;
      case '--project': opts.project = argv[++i]; break;
      case '--grep': opts.grep = argv[++i]; break;
      case '--grep-invert': opts.grepInvert = argv[++i]; break;
      case '--keep-permissions': opts.skipPermissions = false; break;
      case '--dry-run': opts.dryRun = true; break;
      case '--init-scripts': opts.initScripts = true; break;
      case '--json': opts.json = true; break;
      case '-h':
      case '--help':
        process.stdout.write(HELP);
        process.exit(0);
        break;
      default:
        if (a.startsWith('--')) fail(`Unknown option: ${a}\n\n${HELP}`);
        opts.filters.push(a);
    }
  }
  return opts;
}

function fail(msg) {
  process.stderr.write(`[self-repair] ERROR ${msg}\n`);
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Logging — every event goes to events.ndjson; human lines mirror to stdout
// and driver.log. With --json, stdout carries the NDJSON stream instead.
// ---------------------------------------------------------------------------

const state = {
  runDir: null,
  json: false,
};

// The run dir lives OUTSIDE Playwright's outputDir (typically test-results/)
// because Playwright wipes its outputDir at run start — session artifacts
// written during a run would be deleted mid-flight. `.achilles/` is the
// package's gitignored per-project state dir, so it is the natural home.
// safeAppend re-creates the directory if something removes it anyway.
function safeAppend(path, data) {
  try {
    appendFileSync(path, data);
  } catch (err) {
    if (err.code !== 'ENOENT') throw err;
    mkdirSync(dirname(path), { recursive: true });
    appendFileSync(path, data);
  }
}

function log(stage, message, extra = {}) {
  const evt = { at: new Date().toISOString(), stage, message, ...extra };
  const line = `[self-repair] ${evt.at} stage=${stage} ${message}`;
  if (state.runDir) {
    safeAppend(join(state.runDir, 'events.ndjson'), JSON.stringify(evt) + '\n');
    safeAppend(join(state.runDir, 'driver.log'), line + '\n');
  }
  process.stdout.write(state.json ? JSON.stringify(evt) + '\n' : line + '\n');
}

// ---------------------------------------------------------------------------
// Playwright runs
// ---------------------------------------------------------------------------

function runPlaywright(label, jsonOut, extraArgs, opts) {
  return new Promise((resolvePromise) => {
    const args = ['playwright', 'test', ...opts.filters, ...extraArgs];
    if (opts.project) args.push(`--project=${opts.project}`);
    if (opts.grep) args.push('--grep', opts.grep);
    if (opts.grepInvert) args.push('--grep-invert', opts.grepInvert);
    const child = spawn('npx', args, {
      cwd: process.cwd(),
      env: {
        ...process.env,
        PLAYWRIGHT_JSON_OUTPUT_NAME: jsonOut,
        // Force the json reporter regardless of the project's config.
        PW_TEST_HTML_REPORT_OPEN: 'never',
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    child.stdout.on('data', (d) => safeAppend(join(state.runDir, `${label}.out.log`), d));
    child.stderr.on('data', (d) => safeAppend(join(state.runDir, `${label}.out.log`), d));
    child.on('close', (code) => resolvePromise(code));
    child.on('error', (err) => {
      log(label, `playwright spawn failed: ${err.message}`);
      resolvePromise(-1);
    });
  });
}

// Flatten a Playwright JSON report into [{file, title, status, error}]
function collectResults(reportPath) {
  if (!existsSync(reportPath)) return null;
  const report = JSON.parse(readFileSync(reportPath, 'utf8'));
  const out = [];
  const walk = (suite, file) => {
    const f = suite.file || file;
    for (const spec of suite.specs ?? []) {
      for (const test of spec.tests ?? []) {
        const results = test.results ?? [];
        const last = results[results.length - 1] ?? {};
        const anyPass = results.some((r) => r.status === 'passed');
        out.push({
          file: spec.file || f,
          title: spec.title,
          status: last.status === 'passed' || anyPass ? 'passed' : (last.status ?? 'unknown'),
          error: errorSignature(last),
        });
      }
    }
    for (const child of suite.suites ?? []) walk(child, f);
  };
  for (const suite of report.suites ?? []) walk(suite, suite.file);
  return out;
}

function errorSignature(result) {
  const raw = result?.error?.message ?? result?.errors?.[0]?.message ?? '';
  return raw
    .replace(/\[[0-9;]*m/g, '') // strip ANSI
    .split('\n')[0]
    .slice(0, 160);
}

// ---------------------------------------------------------------------------
// Classification (mirrors test-repair Stage 2 patterns)
// ---------------------------------------------------------------------------

function classify(runs) {
  // runs: array of per-run result arrays
  const byTest = new Map(); // key: file :: title
  for (let i = 0; i < runs.length; i++) {
    for (const r of runs[i] ?? []) {
      const key = `${r.file}::${r.title}`;
      if (!byTest.has(key)) byTest.set(key, { file: r.file, title: r.title, outcomes: [], errors: [] });
      const t = byTest.get(key);
      t.outcomes[i] = r.status;
      if (r.status !== 'passed') t.errors.push(r.error);
    }
  }
  for (const t of byTest.values()) {
    // Skipped (test.skip / test.fixme placeholders) is neither pass nor
    // fail — a fixme'd bug placeholder must not get a repair worker.
    const failures = t.outcomes.filter((o) => o && o !== 'passed' && o !== 'skipped').length;
    const ran = t.outcomes.filter((o) => o && o !== 'skipped').length;
    if (ran === 0 || failures === 0) t.pattern = 'green';
    else if (failures === ran) t.pattern = 'deterministic-fail';
    else if (new Set(t.errors).size <= 1) t.pattern = 'flaky-consistent';
    else t.pattern = 'flaky-chaotic';
  }
  return byTest;
}

function redFiles(byTest) {
  const files = new Map();
  for (const t of byTest.values()) {
    if (t.pattern === 'green') continue;
    if (!files.has(t.file)) files.set(t.file, []);
    files.get(t.file).push(t);
  }
  return files;
}

const slug = (file) => file.replace(/[^a-zA-Z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 80);

// ---------------------------------------------------------------------------
// Worker subprocess
// ---------------------------------------------------------------------------

function workerBrief(file, tests, reportPath, schemaPath, opts) {
  const matrix = tests
    .map(
      (t) =>
        `- "${t.title}" — pattern: ${t.pattern}; outcomes: [${t.outcomes.join(', ')}]` +
        (t.errors[0] ? `; first error: ${t.errors[0]}` : ''),
    )
    .join('\n');
  return `You are a self-repair worker for exactly one Playwright spec file. Scope: ${file}. Do not touch any other spec file.

Load the failure-diagnosis skill via the Skill tool and follow its methodology for every failing test below. Also honour the bug-vs-heal discipline from the test-repair skill: screenshot evidence of wrong UI means an app bug — report it with evidence and do NOT modify the test; mechanical heals (selector re-learning, timing hardening, state isolation) apply autonomously; semantic changes (assertion re-baselining, flow-step drift) are returned as operator-pending, not applied; irreducible flake is quarantined per the methodology, never silently skipped.

Baseline evidence (${opts.baselineRuns} runs):
${matrix}

Process per failing test: diagnose with evidence, fix test-side issues (broken selectors in the page repository, waits, state), then prove each heal with 5 consecutive passing runs of this file (\`npx playwright test ${file}\`). If a fix does not stabilise, revert it and try the next hypothesis or classify.

Report back at every stage by printing a single line to the user: [self-repair:worker] stage=<diagnosing|fixing|verifying|classifying|done> file=${file} detail=<short note>. Emit one line per stage transition per test.

Bug-evidence contract for app-bug outcomes: assemble the full bundle — failure screenshot, error context/trace, the failing run's video, AND a slow-motion screen recording of a reproduction run. The slow-down happens at the source: re-run the failing test with the browser's launchOptions.slowMo pacing the actions themselves (>= 1500ms per action; raise it if actions still blur — the native real-time recording must be watchable with no post-processing; prefer the project's existing hook such as an E2E_SLOWMO=<ms> env var when the config supports one). Keep the trace.zip too — npx playwright show-trace is the action-by-action artifact for engineers; the recording is for humans and bug tickets. Copy every evidence file IMMEDIATELY to bug-evidence/<TEST-ID>/<UTC-timestamp>-<label>/ at the project root (Playwright reuses test-results/ dirs, so reruns silently overwrite artifacts). bug-report.evidence paths must point at the bug-evidence/ copies, never at test-results/. If the bug is intermittent, loop the recorded reproduction up to 12 attempts; if no failure occurs, state explicitly in the report that the slow-mo recording is pending a bad window and record the attempt count.

When finished, write your report as JSON to ${reportPath} conforming to the JSON Schema at ${schemaPath} (read the schema first). The report's handover.role must be "repair-worker-${slug(file)}". Every test from the baseline evidence must appear in the tests array with an outcome of already-green, healed, app-bug, quarantined, operator-pending, or unresolved. For app-bug outcomes include a bug-report object with a summary and evidence paths (screenshot, trace, video, slow-mo recording — under bug-evidence/). Keep stage-log entries for each stage you announced.

Do not commit anything. Do not run the full suite — only this file.`;
}

function spawnWorker(file, tests, round, opts) {
  return new Promise((resolvePromise) => {
    const s = slug(file);
    const workersDir = join(state.runDir, 'workers');
    mkdirSync(workersDir, { recursive: true });
    const reportPath = join(workersDir, `${s}.report.json`);
    const streamPath = join(workersDir, `${s}.stream.ndjson`);
    const schemaPath = join(PKG_ROOT, 'schemas', 'subagent-returns', 'repair-worker.schema.json');

    const args = ['-p', workerBrief(file, tests, reportPath, schemaPath, opts), '--output-format', 'stream-json', '--verbose'];
    if (opts.skipPermissions) args.push('--dangerously-skip-permissions');
    if (opts.model) args.push('--model', opts.model);

    log('fan-out', `worker started file=${file} round=${round}`, { file, round });
    const child = spawn(opts.claudeBin, args, {
      cwd: process.cwd(),
      env: process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    const timeout = setTimeout(() => {
      log('fan-out', `worker timeout after ${opts.workerTimeoutMin}m file=${file} — killing`, { file });
      child.kill('SIGTERM');
    }, opts.workerTimeoutMin * 60_000);

    let buf = '';
    child.stdout.on('data', (d) => {
      appendFileSync(streamPath, d);
      buf += d.toString();
      let idx;
      while ((idx = buf.indexOf('\n')) !== -1) {
        const line = buf.slice(0, idx);
        buf = buf.slice(idx + 1);
        relayWorkerEvent(file, line);
      }
    });
    child.stderr.on('data', (d) => appendFileSync(streamPath, d));

    child.on('close', (code) => {
      clearTimeout(timeout);
      let report = null;
      let reportError = null;
      if (existsSync(reportPath)) {
        try {
          report = JSON.parse(readFileSync(reportPath, 'utf8'));
          const schemaErrors = validateWorkerReport(report);
          if (schemaErrors) {
            reportError = `schema violations: ${schemaErrors}`;
            log('fan-out', `worker report INVALID file=${file} — ${reportError}`, { file });
          }
        } catch (err) {
          reportError = `unparseable report: ${err.message}`;
        }
      } else {
        reportError = 'no report written';
      }
      log('fan-out', `worker finished file=${file} exit=${code} report=${report ? (reportError ? 'invalid' : 'ok') : 'missing'}`, {
        file,
        exit: code,
      });
      resolvePromise({ file, tests, report, reportError, exit: code });
    });
    child.on('error', (err) => {
      clearTimeout(timeout);
      log('fan-out', `worker spawn failed file=${file}: ${err.message}`, { file });
      resolvePromise({ file, tests, report: null, reportError: `spawn failed: ${err.message}`, exit: -1 });
    });
  });
}

// Surface the worker's own stage announcements and key lifecycle events.
function relayWorkerEvent(file, line) {
  if (!line.trim()) return;
  let evt;
  try {
    evt = JSON.parse(line);
  } catch {
    return;
  }
  if (evt.type === 'assistant') {
    const parts = evt.message?.content ?? [];
    for (const p of parts) {
      if (p.type === 'text') {
        for (const l of p.text.split('\n')) {
          if (l.includes('[self-repair:worker]')) log('worker', l.trim(), { file });
        }
      }
    }
  } else if (evt.type === 'result') {
    log('worker', `[self-repair:worker] session result file=${file} subtype=${evt.subtype ?? 'unknown'} turns=${evt.num_turns ?? '?'}`, { file });
  }
}

// ---------------------------------------------------------------------------
// Schema validation (ajv is a package dependency)
// ---------------------------------------------------------------------------

let workerValidator = null;
function validateWorkerReport(data) {
  if (!workerValidator) {
    const Ajv = require('ajv/dist/2020.js');
    const addFormats = require('ajv-formats');
    const ajv = new Ajv({ strict: true, allErrors: true, allowUnionTypes: true, strictSchema: false });
    addFormats(ajv);
    const dir = join(PKG_ROOT, 'schemas', 'subagent-returns');
    ajv.addSchema(JSON.parse(readFileSync(join(dir, 'handover.schema.json'), 'utf8')));
    workerValidator = ajv.compile(JSON.parse(readFileSync(join(dir, 'repair-worker.schema.json'), 'utf8')));
  }
  if (workerValidator(data)) return null;
  return workerValidator.errors.map((e) => `${e.instancePath || '/'} ${e.message}`).join('; ');
}

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

function testOutcome(workerReports, file, title) {
  for (const w of workerReports) {
    if (w.file !== file || !w.report) continue;
    const t = (w.report.tests ?? []).find((x) => x.title === title);
    if (t) return t;
  }
  return null;
}

const EXPLAINED = new Set(['app-bug', 'quarantined', 'operator-pending']);

function buildReport(runId, opts, byTest, workerReports, verifyByTest, rounds, startedAt) {
  const files = new Map();
  for (const t of byTest.values()) {
    if (!files.has(t.file)) files.set(t.file, []);
    const worker = testOutcome(workerReports, t.file, t.title);
    const verified = verifyByTest?.get(`${t.file}::${t.title}`);
    let outcome;
    if (t.pattern === 'green') outcome = 'already-green';
    else if (worker && EXPLAINED.has(worker.outcome)) outcome = worker.outcome;
    else if (verified && verified.pattern === 'green') outcome = 'healed';
    else if (worker?.outcome === 'healed' && !verified) outcome = 'healed';
    else outcome = 'unresolved';
    files.get(t.file).push({
      title: t.title,
      'baseline-pattern': t.pattern,
      outcome,
      'root-cause': worker?.['root-cause'] ?? null,
      fix: worker?.fix ?? null,
      'bug-report': worker?.['bug-report'] ?? null,
      notes: worker?.notes ?? null,
    });
  }

  const fileEntries = [...files.entries()].map(([file, tests]) => {
    const statuses = new Set(tests.map((t) => t.outcome));
    let status;
    if ([...statuses].every((s) => s === 'already-green')) status = 'green';
    else if (statuses.has('unresolved')) status = 'unresolved';
    else if ([...statuses].every((s) => s === 'already-green' || s === 'healed')) status = 'healed';
    else status = 'explained';
    return { file, status, tests };
  });

  const all = fileEntries.flatMap((f) => f.tests);
  const count = (o) => all.filter((t) => t.outcome === o).length;
  const totals = {
    'already-green': count('already-green'),
    healed: count('healed'),
    'app-bugs': count('app-bug'),
    quarantined: count('quarantined'),
    'operator-pending': count('operator-pending'),
    unresolved: count('unresolved'),
  };

  const observations = [];
  for (const w of workerReports) {
    if (w.reportError) observations.push(`worker for ${w.file}: ${w.reportError}`);
    for (const o of w.report?.observations ?? []) observations.push(`${w.file}: ${o}`);
  }

  return {
    version: 'self-repair-report/v1',
    'run-id': runId,
    mode: 'script',
    'started-at': startedAt,
    'finished-at': new Date().toISOString(),
    scope: { files: files.size, tests: all.length },
    baseline: {
      runs: opts.baselineRuns,
      mode: opts.baselineMode,
      'timeout-cap-seconds': opts.baselineMode === 'focus' ? opts.timeoutCapSec : 0,
      'rerun-delay-seconds': opts.rerunDelaySec,
    },
    'verify-runs': opts.verifyRuns,
    rounds,
    totals,
    files: fileEntries,
    observations,
    artifacts: {
      'run-dir': relative(process.cwd(), state.runDir),
      'events-ndjson': relative(process.cwd(), join(state.runDir, 'events.ndjson')),
      'workers-dir': relative(process.cwd(), join(state.runDir, 'workers')),
    },
  };
}

function renderMarkdown(r) {
  const lines = [
    `# Self-Repair Session — ${r['run-id']}`,
    '',
    `Mode: ${r.mode} · Baseline: ${r.baseline.runs}× · Verify: ${r['verify-runs']}× · Rounds: ${r.rounds}`,
    `Window: ${r['started-at']} → ${r['finished-at']}`,
    '',
    '## Outcome',
    '',
    `| Already green | Healed | App bugs | Quarantined | Operator-pending | Unresolved |`,
    `|---|---|---|---|---|---|`,
    `| ${r.totals['already-green']} | ${r.totals.healed} | ${r.totals['app-bugs']} | ${r.totals.quarantined} | ${r.totals['operator-pending']} | ${r.totals.unresolved} |`,
    '',
    '## Per-file results',
    '',
  ];
  for (const f of r.files) {
    if (f.status === 'green') continue;
    lines.push(`### \`${f.file}\` — ${f.status}`, '');
    for (const t of f.tests) {
      if (t.outcome === 'already-green') continue;
      lines.push(`- **${t.title}** — ${t.outcome} (baseline: ${t['baseline-pattern']})`);
      if (t['root-cause']) lines.push(`  - Root cause: ${t['root-cause']}`);
      if (t.fix) lines.push(`  - Fix: ${t.fix}`);
      if (t['bug-report']) lines.push(`  - Bug report: ${t['bug-report'].summary}`);
      if (t.notes) lines.push(`  - Notes: ${t.notes}`);
    }
    lines.push('');
  }
  const bugs = r.files.flatMap((f) => f.tests.filter((t) => t['bug-report']).map((t) => ({ f: f.file, t })));
  if (bugs.length) {
    lines.push('## Bug reports (tests NOT modified)', '');
    for (const { f, t } of bugs) {
      lines.push(`- \`${f}\` :: ${t.title} — ${t['bug-report'].summary}`);
      for (const e of t['bug-report'].evidence ?? []) lines.push(`  - Evidence: ${e}`);
    }
    lines.push('');
  }
  if (r.observations.length) {
    lines.push('## Observations', '', ...r.observations.map((o) => `- ${o}`), '');
  }
  lines.push('## Artifacts', '', `- Events: \`${r.artifacts['events-ndjson']}\``, `- Worker transcripts + reports: \`${r.artifacts['workers-dir']}\``, '');
  return lines.join('\n');
}

// ---------------------------------------------------------------------------
// --init-scripts — derive test:repair:<flow> presets from package.json
// ---------------------------------------------------------------------------
// For every suite-scoped Playwright run script (test:e2e:regression,
// test:e2e:smoke:desktop, …) generate the matching repair preset with the
// same env prefix, path filters, --project, and --grep/--grep-invert scope.
// Idempotent: existing test:repair* scripts are never overwritten.

// Tokenize a shell command respecting single/double quotes (enough for the
// npm-script shapes this targets; command substitution is not supported and
// such scripts are skipped by the caller's safety checks).
function shellTokens(cmd) {
  const tokens = [];
  const re = /'([^']*)'|"([^"]*)"|(\S+)/g;
  let m;
  while ((m = re.exec(cmd)) !== null) tokens.push(m[1] ?? m[2] ?? m[3]);
  return tokens;
}

function deriveRepairScript(cmd) {
  // Must invoke `playwright test` with the default config, non-interactively.
  if (!/\bplaywright\s+test\b/.test(cmd)) return null;
  if (/--config[= ]|--ui\b|--headed\b|&&|\|\||\$\(|`/.test(cmd)) return null;

  const tokens = shellTokens(cmd);
  const pwIdx = tokens.findIndex((t, i) => t === 'playwright' && tokens[i + 1] === 'test');
  if (pwIdx === -1) return null;

  // Env prefix: leading VAR=VALUE assignments (verbatim — ${…:-default}
  // shell expansions stay intact).
  const envPrefix = [];
  for (const t of tokens) {
    if (/^[A-Z_][A-Z0-9_]*=/.test(t)) envPrefix.push(t);
    else break;
  }

  // Keep only the scope-defining args after `playwright test`.
  const kept = [];
  const rest = tokens.slice(pwIdx + 2);
  for (let i = 0; i < rest.length; i++) {
    const t = rest[i];
    if (t === '--grep' || t === '--grep-invert') {
      kept.push(t, JSON.stringify(rest[++i] ?? ''));
    } else if (t.startsWith('--grep=') || t.startsWith('--grep-invert=')) {
      const [flag, ...v] = t.split('=');
      kept.push(flag, JSON.stringify(v.join('=')));
    } else if (t.startsWith('--project')) {
      kept.push(t.includes('=') ? t : `${t}=${rest[++i] ?? ''}`);
    } else if (t.startsWith('-')) {
      return null; // unknown flag — safer to skip than mistranslate
    } else {
      kept.push(t); // positional path filter
    }
  }

  return [...envPrefix, 'achilles-self-repair', ...kept].join(' ');
}

function initScripts() {
  const pkgPath = resolve(process.cwd(), 'package.json');
  if (!existsSync(pkgPath)) fail('no package.json in the current directory');
  const raw = readFileSync(pkgPath, 'utf8');
  const pkg = JSON.parse(raw);
  pkg.scripts ??= {};

  const added = [];
  const skipped = [];
  for (const [name, cmd] of Object.entries({ ...pkg.scripts })) {
    if (name.startsWith('test:repair')) continue;
    const derived = deriveRepairScript(cmd);
    if (!derived) continue;
    // test:e2e:regression:desktop → test:repair:regression:desktop;
    // a bare runner script (test:e2e, e2e) → test:repair.
    const flow = name.replace(/^(test:)?(e2e|playwright)(:|$)/, '').replace(/^:+|:+$/g, '');
    const target = flow ? `test:repair:${flow}` : 'test:repair';
    if (pkg.scripts[target]) {
      skipped.push(`${target} (exists)`);
      continue;
    }
    pkg.scripts[target] = derived;
    added.push(target);
  }

  if (added.length) {
    const trailing = raw.endsWith('\n') ? '\n' : '';
    writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + trailing);
  }
  for (const t of added) console.log(`[self-repair] init-scripts added: ${t} = ${pkg.scripts[t]}`);
  for (const s of skipped) console.log(`[self-repair] init-scripts skipped: ${s}`);
  if (!added.length && !skipped.length) console.log('[self-repair] init-scripts: no suite-scoped playwright scripts found');
  process.exit(0);
}

// ---------------------------------------------------------------------------
// Main pipeline
// ---------------------------------------------------------------------------

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.initScripts) initScripts();
  state.json = opts.json;

  const runId = new Date().toISOString().replace(/[:.]/g, '-').replace('T', '_').slice(0, 19);
  state.runDir = resolve(process.cwd(), '.achilles', 'self-repair', runId);
  mkdirSync(join(state.runDir, 'workers'), { recursive: true });
  const startedAt = new Date().toISOString();

  log('init', `run-id=${runId} run-dir=${relative(process.cwd(), state.runDir)}`, {
    options: { ...opts },
  });

  // Stage 1 — baseline: discovery run + focused failure reruns.
  //
  // Detect first, analyse before fixing: run 1 covers the full scope and
  // finds the red set; runs 2..N (focus mode) re-run ONLY the red files —
  // with --trace on so workers start from real evidence, with the analysis
  // timeout cap so broken tests don't burn full-length timeouts, and with
  // optional wall-clock spacing so an app incident isn't misread as a
  // deterministic failure. Cost scales with failures, not suite size.
  const runs = [];
  {
    log('baseline', `discovery run 1/${opts.baselineRuns} starting (full scope, suite timeouts)`);
    const jsonOut = join(state.runDir, 'baseline-1.json');
    await runPlaywright('baseline-1', jsonOut, ['--reporter=json'], opts);
    const results = collectResults(jsonOut);
    if (!results) fail('discovery run produced no JSON report — is this a Playwright project?');
    const failed = results.filter((r) => r.status !== 'passed' && r.status !== 'skipped').length;
    log('baseline', `discovery run 1/${opts.baselineRuns} done: ${results.length} tests, ${failed} failing`);
    runs.push(results);
  }
  const redAfterDiscovery = redFiles(classify(runs));
  if (redAfterDiscovery.size > 0) {
    const focus = opts.baselineMode === 'focus';
    const rerunFilters = focus ? [...redAfterDiscovery.keys()] : opts.filters;
    const capMs = focus && opts.timeoutCapSec > 0 ? opts.timeoutCapSec * 1000 : 0;
    const rerunArgs = ['--reporter=json'];
    if (focus) rerunArgs.push('--trace', 'on');
    if (capMs) rerunArgs.push('--timeout', String(capMs));
    for (let i = 2; i <= opts.baselineRuns; i++) {
      if (opts.rerunDelaySec > 0) {
        log('baseline', `waiting ${opts.rerunDelaySec}s before failure rerun ${i} (incident-shape spacing)`);
        await new Promise((r) => setTimeout(r, opts.rerunDelaySec * 1000));
      }
      log(
        'baseline',
        focus
          ? `failure rerun ${i}/${opts.baselineRuns}: ${redAfterDiscovery.size} red file(s), trace on` +
              (capMs ? `, timeout cap ${opts.timeoutCapSec}s` : '')
          : `full baseline run ${i}/${opts.baselineRuns} starting`,
      );
      const jsonOut = join(state.runDir, `baseline-${i}.json`);
      await runPlaywright(`baseline-${i}`, jsonOut, rerunArgs, { ...opts, filters: rerunFilters });
      const results = collectResults(jsonOut);
      if (!results) {
        log('baseline', `run ${i} produced no JSON report — skipping its outcomes`);
        continue;
      }
      const failed = results.filter((r) => r.status !== 'passed' && r.status !== 'skipped').length;
      log('baseline', `run ${i}/${opts.baselineRuns} done: ${results.length} tests, ${failed} failing`);
      runs.push(results);
    }
  } else {
    log('baseline', 'discovery run green — skipping failure reruns');
  }

  // Stage 2 — classify
  let byTest = classify(runs);
  let red = redFiles(byTest);
  const patterns = { 'deterministic-fail': 0, 'flaky-consistent': 0, 'flaky-chaotic': 0 };
  for (const t of byTest.values()) if (t.pattern !== 'green') patterns[t.pattern]++;
  log(
    'classify',
    `${byTest.size} tests: ${byTest.size - [...red.values()].flat().length} green, ` +
      `${patterns['deterministic-fail']} deterministic, ${patterns['flaky-consistent']} flaky-consistent, ` +
      `${patterns['flaky-chaotic']} flaky-chaotic across ${red.size} red files`,
  );

  if (red.size === 0) {
    log('report', 'suite already green — nothing to repair');
    const report = buildReport(runId, opts, byTest, [], null, 0, startedAt);
    writeFileSync(join(state.runDir, 'report.json'), JSON.stringify(report, null, 2));
    writeFileSync(join(state.runDir, 'report.md'), renderMarkdown(report));
    process.exit(0);
  }

  for (const [file, tests] of red) {
    log('classify', `red file ${file}: ${tests.map((t) => `"${t.title}" (${t.pattern})`).join(', ')}`, { file });
  }

  if (opts.dryRun) {
    log('plan', `dry-run: would spawn ${red.size} worker(s) at concurrency ${opts.concurrency}, max ${opts.maxRounds} round(s)`);
    process.exit(0);
  }

  // Stage 3+4 — fan-out rounds with verification
  const workerReports = [];
  let verifyByTest = null;
  let round = 0;
  while (round < opts.maxRounds && red.size > 0) {
    round++;
    log('fan-out', `round ${round}/${opts.maxRounds}: ${red.size} file(s), concurrency ${opts.concurrency}`);

    const queue = [...red.entries()];
    const active = new Set();
    while (queue.length || active.size) {
      while (queue.length && active.size < opts.concurrency) {
        const [file, tests] = queue.shift();
        const p = spawnWorker(file, tests, round, opts).then((res) => {
          active.delete(p);
          workerReports.unshift(res); // newest first — testOutcome finds latest
        });
        active.add(p);
      }
      await Promise.race(active);
    }

    // Verify: re-run previously-red files in suite order
    const filesToVerify = [...red.keys()];
    const verifyRunsResults = [];
    for (let i = 1; i <= opts.verifyRuns; i++) {
      log('verify', `run ${i}/${opts.verifyRuns} over ${filesToVerify.length} file(s)`);
      const jsonOut = join(state.runDir, `verify-r${round}-${i}.json`);
      const verifyOpts = { ...opts, filters: filesToVerify };
      await runPlaywright(`verify-r${round}-${i}`, jsonOut, ['--reporter=json'], verifyOpts);
      const results = collectResults(jsonOut);
      if (results) verifyRunsResults.push(results);
    }
    verifyByTest = classify(verifyRunsResults);

    // Recompute red set: still-failing tests lacking an explained classification
    const nextRed = new Map();
    for (const t of verifyByTest.values()) {
      if (t.pattern === 'green') continue;
      const w = testOutcome(workerReports, t.file, t.title);
      if (w && EXPLAINED.has(w.outcome)) continue;
      if (!nextRed.has(t.file)) nextRed.set(t.file, []);
      nextRed.get(t.file).push(t);
    }
    log('verify', `round ${round} verification: ${nextRed.size} file(s) still red and unexplained`);
    red = nextRed;
  }

  // Stage 5 — report
  const report = buildReport(runId, opts, byTest, workerReports, verifyByTest, round, startedAt);
  const reportJsonPath = join(state.runDir, 'report.json');
  const reportMdPath = join(state.runDir, 'report.md');
  writeFileSync(reportJsonPath, JSON.stringify(report, null, 2));
  writeFileSync(reportMdPath, renderMarkdown(report));
  log(
    'report',
    `written ${relative(process.cwd(), reportMdPath)} — healed=${report.totals.healed} app-bugs=${report.totals['app-bugs']} ` +
      `quarantined=${report.totals.quarantined} operator-pending=${report.totals['operator-pending']} unresolved=${report.totals.unresolved}`,
  );

  process.exit(report.totals.unresolved > 0 ? 2 : 0);
}

main().catch((err) => fail(err.stack ?? String(err)));
