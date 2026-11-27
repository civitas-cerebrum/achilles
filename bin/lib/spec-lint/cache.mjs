// The lint cache of the baseline commands: `.achilles/compliance/index.json`, keyed by the content the result
// depends on (git object ids of every index entry, the disk content of what differs, the change compared, the
// recorded id pattern, the engine version and ruleset). A commit checked once (by a gate that simulates it,
// or by `--ratchet`) and then by the pre-commit hook over the same content is linted once. A cache that cannot
// be read or written is skipped; it is never needed for a correct answer.
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import path from 'node:path';

export const CACHE_FILE = '.achilles/compliance/index.json';
const KEEP = 6;

export const cacheKey = (parts) => createHash('sha256').update(JSON.stringify(parts)).digest('hex');

function load(root) {
  try {
    const doc = JSON.parse(readFileSync(path.join(root, CACHE_FILE), 'utf8'));
    return doc && doc.version === 1 && Array.isArray(doc.entries) ? doc : { version: 1, entries: [] };
  } catch { return { version: 1, entries: [] }; }
}

/** The cached lint result for `key` (a report with its `facts` restored), or null. */
export function readCache(root, key) {
  const hit = load(root).entries.find((e) => e.key === key);
  if (!hit) return null;
  const report = hit.report;
  Object.defineProperty(report, 'facts', { value: new Map(hit.facts), enumerable: false });
  return report;
}

/** Stores a lint result under `key`, keeping the most recent few entries. */
export function writeCache(root, key, report) {
  try {
    const doc = load(root);
    const entries = [{ key, at: Date.now(), report, facts: [...(report.facts || new Map())] }, ...doc.entries.filter((e) => e.key !== key)].slice(0, KEEP);
    const abs = path.join(root, CACHE_FILE);
    mkdirSync(path.dirname(abs), { recursive: true });
    writeFileSync(path.join(path.dirname(abs), '.gitignore'), '*\n');
    const tmp = `${abs}.${process.pid}.tmp`;
    writeFileSync(tmp, JSON.stringify({ version: 1, entries }));
    renameSync(tmp, abs);
  } catch { /* no cache: the next run lints again */ }
}
