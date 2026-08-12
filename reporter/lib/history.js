'use strict';
// history.js — the local outcome ledger.
//
// Store: `.achilles/history/tests.ndjson`, one JSON object per test per run,
// appended once at the end of the run when the test's final outcome is known.
// NDJSON because appending is a single write with no read-modify-write of
// existing content, and because a truncated tail costs exactly one line.
//
// Reads are total: a line that will not parse is dropped and counted, never
// thrown. A ledger someone edited by hand, a half-written line from a killed
// process, or a file of unrelated content all degrade to "less history", which
// is the same failure mode as a fresh checkout.

const fs = require('node:fs');
const path = require('node:path');

const DEFAULTS = { keepRuns: 20, keepDays: 30, maxEntries: 5000 };

function limits(env) {
  const e = env || process.env;
  const int = (name, fallback) => {
    const raw = e[name];
    if (raw === undefined || raw === '') return fallback;
    const n = Number.parseInt(raw, 10);
    return Number.isFinite(n) && n >= 0 ? n : fallback;
  };
  return {
    keepRuns: int('ACHILLES_HISTORY_RUNS', DEFAULTS.keepRuns),
    keepDays: int('ACHILLES_HISTORY_DAYS', DEFAULTS.keepDays),
    maxEntries: int('ACHILLES_HISTORY_MAX_ENTRIES', DEFAULTS.maxEntries),
  };
}

function ledgerPath(root) {
  return path.join(root, '.achilles', 'history', 'tests.ndjson');
}

/** Parse NDJSON text into entries, dropping anything unparseable. */
function parse(text) {
  const entries = [];
  let dropped = 0;
  for (const line of String(text || '').split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    let obj;
    try { obj = JSON.parse(trimmed); } catch { dropped += 1; continue; }
    if (!obj || typeof obj !== 'object' || typeof obj.id !== 'string' || typeof obj.runId !== 'string') {
      dropped += 1;
      continue;
    }
    entries.push(obj);
  }
  return { entries, dropped };
}

function read(root) {
  let text = '';
  try { text = fs.readFileSync(ledgerPath(root), 'utf8'); } catch { return { entries: [], dropped: 0 }; }
  return parse(text);
}

/** Index prior entries by test id, preserving file order (oldest → newest). */
function byTest(entries) {
  const map = new Map();
  for (const e of entries) {
    if (!map.has(e.id)) map.set(e.id, []);
    map.get(e.id).push(e);
  }
  return map;
}

/**
 * Deterministic prune. Runs are ordered by (ts, runId) — both recorded per
 * entry — and everything outside the newest `keepRuns`, older than `keepDays`,
 * or beyond `maxEntries` (oldest first) is dropped. Same input, same output,
 * no clock dependence beyond the explicit `now`.
 */
function prune(entries, opts, now) {
  const cfg = { ...DEFAULTS, ...(opts || {}) };
  const at = now === undefined ? Date.now() : now;

  const runs = new Map();
  for (const e of entries) {
    const key = e.runId;
    const ts = Date.parse(e.ts) || 0;
    const prev = runs.get(key);
    if (!prev || ts > prev) runs.set(key, ts);
  }
  const ordered = [...runs.entries()]
    .sort((a, b) => (a[1] - b[1]) || (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))
    .map(([runId]) => runId);
  const keptRuns = new Set(cfg.keepRuns > 0 ? ordered.slice(-cfg.keepRuns) : []);

  const cutoff = cfg.keepDays > 0 ? at - cfg.keepDays * 86400000 : null;
  let kept = entries.filter((e) => {
    if (!keptRuns.has(e.runId)) return false;
    if (cutoff !== null) {
      const ts = Date.parse(e.ts);
      if (Number.isFinite(ts) && ts < cutoff) return false;
    }
    return true;
  });

  if (cfg.maxEntries > 0 && kept.length > cfg.maxEntries) {
    kept = kept.slice(kept.length - cfg.maxEntries);
  }
  return kept;
}

function serialize(entries) {
  return entries.map((e) => JSON.stringify(e)).join('\n') + (entries.length ? '\n' : '');
}

/**
 * Append this run's entries, then rewrite the ledger only when the prune
 * actually drops something. The rewrite is tmp-file + rename, so a reader
 * never observes a partial ledger and a crash mid-write leaves the previous
 * ledger intact.
 */
function append(root, entries, opts, now) {
  const file = ledgerPath(root);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  if (entries.length) fs.appendFileSync(file, serialize(entries));

  const cfg = { ...limits(), ...(opts || {}) };
  const { entries: all, dropped } = read(root);
  const kept = prune(all, cfg, now);
  const removed = all.length - kept.length;
  // Rewrite when the prune dropped something OR when the file contained lines
  // that would not parse — the ledger compacts itself on the next run rather
  // than carrying damage forward for ever.
  if (removed > 0 || dropped > 0) {
    const tmp = `${file}.tmp-${process.pid}`;
    fs.writeFileSync(tmp, serialize(kept));
    fs.renameSync(tmp, file);
  }
  return { written: entries.length, pruned: removed, repaired: dropped, total: kept.length };
}

module.exports = { DEFAULTS, limits, ledgerPath, parse, read, byTest, prune, append, serialize };
