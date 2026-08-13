'use strict';
// archive.js — per-attempt evidence copying into the run archive.
//
// Layout is the one `hooks/playwright-artifact-archiver.sh` established:
// `.achilles/runs/<runId>/artifacts/<path-relative-to-project-root>` plus a
// `manifest.json`. Copy, never move, so `show-report` / `show-trace` against
// `test-results/` keep working. Attempt attribution lives in the manifest's
// `attempts[]`, and a second attempt writing to a path a first attempt already
// claimed lands beside it as `<name>.attempt<N><ext>` rather than over it —
// attempt 0 is usually the honest failure and the retry is what passed, so a
// diagnosis needs both.

const fs = require('node:fs');
const path = require('node:path');

const BLOB = new Set(['.zip', '.webm', '.mp4']);

function runsDir(root) { return path.join(root, '.achilles', 'runs'); }
function claimFile(root) { return path.join(runsDir(root), '.last-archive.json'); }

/** Same `YYYYmmddTHHMMSSZ[-N]` shape the hook creates and prunes. */
function allocateRunId(root, now) {
  const d = now ? new Date(now) : new Date();
  const base = `${d.toISOString().slice(0, 19).replace(/[-:]/g, '')}Z`;
  let id = base;
  let n = 1;
  while (fs.existsSync(path.join(runsDir(root), id))) {
    id = `${base}-${n}`;
    n += 1;
  }
  return id;
}

function isRunId(name) {
  return /^\d{8}T\d{6}Z(-\d+)?$/.test(name);
}

function uniqueDest(dest, attempt) {
  if (!fs.existsSync(dest)) return dest;
  const ext = path.extname(dest);
  const stem = dest.slice(0, dest.length - ext.length);
  let candidate = `${stem}.attempt${attempt}${ext}`;
  let n = 2;
  while (fs.existsSync(candidate)) {
    candidate = `${stem}.attempt${attempt}-${n}${ext}`;
    n += 1;
  }
  return candidate;
}

class RunArchive {
  constructor(root, opts) {
    this.root = root;
    this.runId = (opts && opts.runId) || allocateRunId(root, opts && opts.now);
    this.dir = path.join(runsDir(root), this.runId);
    this.maxBytes = (opts && opts.maxBytes) !== undefined ? opts.maxBytes : 512 * 1024 * 1024;
    this.attempts = [];
    this.skipped = [];
    this.bytes = 0;
    this.files = 0;
    this.incomplete = false;
  }

  relFor(absolute) {
    const rel = path.relative(this.root, absolute);
    if (rel && !rel.startsWith('..') && !path.isAbsolute(rel)) return rel.split(path.sep).join('/');
    // Attachments can point outside the project (a fixture writing to a temp
    // dir). Keep them, but in a clearly-labelled corner of the archive.
    return `_external/${path.basename(absolute)}`;
  }

  /**
   * Copy one attempt's attachments. Called from `onTestEnd`, i.e. before the
   * next attempt starts and long before the run ends — the window in which
   * Playwright itself would not yet have overwritten anything.
   */
  recordAttempt(entry) {
    const copied = [];
    for (const attachment of entry.attachments || []) {
      const src = attachment.path;
      if (!src) continue;
      let st;
      try { st = fs.statSync(src); } catch { continue; }
      if (!st.isFile()) continue;

      const rel = this.relFor(src);
      if (BLOB.has(path.extname(src).toLowerCase()) && this.maxBytes >= 0 && this.bytes + st.size > this.maxBytes) {
        this.skipped.push({ path: rel, bytes: st.size, reason: 'maxBytes' });
        continue;
      }

      const dest = uniqueDest(path.join(this.dir, 'artifacts', rel), entry.attempt);
      try {
        fs.mkdirSync(path.dirname(dest), { recursive: true });
        fs.copyFileSync(src, dest);
      } catch (err) {
        this.incomplete = true;
        this.skipped.push({ path: rel, bytes: st.size, reason: (err && err.code) || 'copyFailed' });
        continue;
      }
      this.bytes += st.size;
      this.files += 1;
      copied.push({
        name: attachment.name,
        contentType: attachment.contentType,
        source: rel,
        archived: path.relative(this.root, dest).split(path.sep).join('/'),
        bytes: st.size,
      });
    }
    this.attempts.push({ ...entry, attachments: undefined, files: copied });
    return copied;
  }

  /** Evidence path a reader can copy-paste, per test. */
  evidenceFor(testId) {
    const files = [];
    for (const a of this.attempts) {
      if (a.testId !== testId) continue;
      for (const f of a.files) files.push(f.archived);
    }
    return files;
  }

  counts() {
    const tally = { archivedFiles: this.files, traces: 0, videos: 0, screenshots: 0, errorContexts: 0, attempts: this.attempts.length };
    for (const a of this.attempts) {
      for (const f of a.files) {
        const ext = path.extname(f.source).toLowerCase();
        if (ext === '.zip') tally.traces += 1;
        else if (ext === '.webm' || ext === '.mp4') tally.videos += 1;
        else if (ext === '.png' || ext === '.jpg' || ext === '.jpeg') tally.screenshots += 1;
        if (path.basename(f.source) === 'error-context.md') tally.errorContexts += 1;
      }
    }
    return tally;
  }

  writeManifest(extra) {
    if (this.files === 0 && this.attempts.length === 0) return false;
    const manifest = {
      schema: 'playwright-run-archive/v1',
      producer: 'reporter',
      runId: this.runId,
      timestamp: new Date().toISOString().replace(/\.\d+Z$/, 'Z'),
      trigger: 'reporter:onTestEnd',
      mode: 'failure-evidence',
      incomplete: this.incomplete,
      counts: this.counts(),
      bytes: { archived: this.bytes, skipped: this.skipped.reduce((n, s) => n + s.bytes, 0) },
      skipped: this.skipped,
      attempts: this.attempts,
      ...(extra || {}),
    };
    fs.mkdirSync(this.dir, { recursive: true });
    fs.writeFileSync(path.join(this.dir, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
    return true;
  }
}

/**
 * Retention over the shared `.achilles/runs/` directory, oldest first, using
 * the hook's rule: only runId-shaped directories are ever counted or removed.
 */
function pruneRuns(root, keep) {
  const dir = runsDir(root);
  let names = [];
  try { names = fs.readdirSync(dir); } catch { return []; }
  const runs = names.filter((n) => isRunId(n) && (() => {
    try { return fs.statSync(path.join(dir, n)).isDirectory(); } catch { return false; }
  })()).sort();
  if (keep <= 0 || runs.length <= keep) return [];
  const drop = runs.slice(0, runs.length - keep);
  const pruned = [];
  for (const name of drop) {
    if (!isRunId(name)) continue;
    try { fs.rmSync(path.join(dir, name), { recursive: true, force: true }); pruned.push(name); } catch { /* keep going */ }
  }
  return pruned;
}

function updateLatest(root, runId) {
  const link = path.join(runsDir(root), 'latest');
  try { fs.rmSync(link, { force: true }); } catch { /* ignore */ }
  try { fs.symlinkSync(runId, link); } catch { /* a filesystem without symlinks is not a reason to fail */ }
}

/**
 * The handshake with `hooks/playwright-artifact-archiver.sh`.
 *
 * The hook no-ops when the fingerprint it computes over the run's artifacts
 * matches the one recorded in `.achilles/runs/.last-archive.json`. It cannot
 * recompute the reporter's (that would mean reimplementing the hook's
 * stat/sort/digest pipeline byte-identically in another language), so the
 * reporter records, per candidate path, the three quantities that ARE
 * reproducible across implementations: file count, byte total, and newest
 * mtime in whole seconds.
 *
 * Per PATH rather than in aggregate, because the hook's candidate set is often
 * a subset of the reporter's: the hook greps the config, so a computed
 * `outputDir` is invisible to it and it sees only the html report. The hook
 * no-ops when every path IT resolved is present in the claim with matching
 * numbers — so a claim can never suppress artifacts the reporter did not see,
 * and a mismatch costs a duplicate archive rather than lost evidence.
 *
 * Stamped from `onExit`, which Playwright calls after every reporter's `onEnd`
 * has resolved — the earliest point at which the html/json reports on disk are
 * final.
 */
function stampClaim(root, runId, stats, candidates) {
  const file = claimFile(root);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const claim = {
    fingerprint: `reporter:${runId}`,
    runId,
    timestamp: new Date().toISOString().replace(/\.\d+Z$/, 'Z'),
    claimedBy: 'reporter',
    complete: true,
    candidates: {
      paths: candidates.map((c) => c.path),
      files: stats.files,
      bytes: stats.bytes,
      newestMtime: stats.newestMtime,
      byPath: stats.byPath || {},
    },
  };
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, `${JSON.stringify(claim, null, 2)}\n`);
  fs.renameSync(tmp, file);
  return claim;
}

module.exports = { RunArchive, allocateRunId, isRunId, pruneRuns, updateLatest, stampClaim, runsDir, claimFile, uniqueDest };
