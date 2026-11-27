// The rule inputs the test baseline protects (test-baseline.md TB-G2), read from a commit so a change cannot
// relax the rules it is checked against: the factory rules' `specs.*` and `secrets.*` rules (and the file
// itself), the id pattern in a committed `.env`, the framework-gap register, and the `grep`, `grepInvert`,
// `testIgnore` and `testMatch` lines of the Playwright configs. CI and `--ratchet` lint with the merge-base's
// inputs and fail a change that weakens one; the pre-commit check lints with HEAD's and names the change.
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { gitSync } from './git.mjs';
import { REGISTER } from './waivers.mjs';

const CONFIG = /^playwright[^/]*\.config\.[cm]?[jt]s$/;
const SELECTION = /\b(grep|grepInvert|testIgnore|testMatch)\s*:/;

const factoryPath = () => process.env.FACTORY_RULES && !path.isAbsolute(process.env.FACTORY_RULES) ? process.env.FACTORY_RULES : 'achilles-factory-rules.json';

const envValue = (text) => {
  if (typeof text !== 'string') return null;
  for (const line of text.split(/\r?\n/)) {
    const m = /^\s*(?:export\s+)?CIVITAS_TEST_ID_PATTERN\s*=\s*(.*?)\s*$/.exec(line);
    if (m) return m[1].replace(/^(['"])(.*)\1$/, '$2');
  }
  return null;
};

const parseJson = (text) => { if (typeof text !== 'string') return null; try { return JSON.parse(text); } catch { return null; } };

function shape(read, configNames) {
  const factoryText = read(factoryPath());
  const configs = {};
  for (const f of configNames) {
    const t = read(f);
    if (typeof t === 'string') configs[f] = t.split(/\r?\n/).filter((l) => SELECTION.test(l)).map((l) => l.trim());
  }
  return { factoryText, factory: parseJson(factoryText), register: read(REGISTER), envPattern: envValue(read('.env')), configs };
}

/** The protected inputs as committed at `rev` (a commit), or staged in the index when `rev` is ''. */
export function inputsAt(root, rev) {
  const read = (rel) => { try { return gitSync(root, ['show', `${rev}:./${rel}`]); } catch { return null; } };
  let names = [];
  try {
    const list = rev === '' ? gitSync(root, ['ls-files']) : gitSync(root, ['ls-tree', '--name-only', rev, './']);
    names = list.split('\n').map((x) => x.trim()).filter((x) => CONFIG.test(x));
  } catch { /* none */ }
  return shape(read, names);
}

/** The files that hold protected inputs, at either side. */
export function inputPaths(base, now) {
  return new Set([factoryPath(), '.env', REGISTER, ...Object.keys(base.configs), ...Object.keys(now.configs)]);
}

/** The protected inputs as they are on disk. */
export function inputsOnDisk(root) {
  const read = (rel) => { const p = path.join(root, rel); return existsSync(p) ? readFileSync(p, 'utf8') : null; };
  let names = [];
  try { names = readdirSync(root).filter((x) => CONFIG.test(x)); } catch { /* none */ }
  return shape(read, names);
}

/** True when a rule change only tightens: the rule is new, the constant-table setting goes off, or every array only gained entries. */
function tightens(key, was, is) {
  // the one permissive setting: turning it on weakens, wherever it comes from
  if (key === 'specs.constant-table-tests') return !(is && is.allowed === true && !(was && was.allowed === true));
  if (was === undefined && is !== undefined) return true;
  if (is === undefined) return false;
  const sup = (x, y) => {
    if (Array.isArray(x) && Array.isArray(y)) return x.every((v) => y.some((w) => JSON.stringify(w) === JSON.stringify(v)));
    if (x && y && typeof x === 'object' && typeof y === 'object') return Object.keys(x).every((k) => k in y && sup(x[k], y[k])) && Object.keys(y).every((k) => k in x || Array.isArray(y[k]));
    return JSON.stringify(x) === JSON.stringify(y);
  };
  return sup(was, is);
}

const rowsOf = (text) => new Map((typeof text === 'string' ? text.split(/\r?\n/) : []).map((l) => l.trim()).filter((l) => /^\|\s*FG-\d+\s*\|/.test(l)).map((l) => [/FG-\d+/.exec(l)[0], l]));
const guarded = (rules) => Object.fromEntries(Object.entries((rules && rules.rules) || {}).filter(([k]) => /^(specs|secrets)\./.test(k)));
const forbidden = (rules) => new Set((((rules && rules.rules) || {})['selectors.no-inline'] || {}).forbidden || []);

/**
 * How `now` differs from `base`: [{ input, detail, weakens }]. `weakens` is false only for a change known to
 * tighten (a rule added, an array that only gained entries, the constant-table setting switched off, a register
 * row removed); every other change is read as weakening.
 */
export function compareInputs(base, now) {
  const out = [];
  const f = factoryPath();
  if (base.factoryText !== null && now.factoryText === null) out.push({ input: f, detail: 'the factory rules file is deleted', weakens: true });
  else {
    const a = guarded(base.factory);
    const b = guarded(now.factory);
    for (const k of [...new Set([...Object.keys(a), ...Object.keys(b)])].sort()) if (JSON.stringify(a[k]) !== JSON.stringify(b[k])) out.push({ input: f, detail: `rule ${k} ${a[k] === undefined ? 'added' : b[k] === undefined ? 'removed' : 'changed'}`, weakens: !tightens(k, a[k], b[k]) });
    const removed = [...forbidden(base.factory)].filter((x) => !forbidden(now.factory).has(x));
    if (removed.length) out.push({ input: f, detail: `selectors.no-inline.forbidden lost ${removed.join(', ')}`, weakens: true });
    const added = [...forbidden(now.factory)].filter((x) => !forbidden(base.factory).has(x));
    if (added.length) out.push({ input: f, detail: `selectors.no-inline.forbidden gained ${added.join(', ')}`, weakens: false });
  }
  if (base.envPattern !== now.envPattern) out.push({ input: '.env', detail: `CIVITAS_TEST_ID_PATTERN changed from ${JSON.stringify(base.envPattern)} to ${JSON.stringify(now.envPattern)}`, weakens: true });
  const ra = rowsOf(base.register);
  const rb = rowsOf(now.register);
  for (const [id, line] of rb) if (ra.get(id) !== line) out.push({ input: REGISTER, detail: `row ${id} ${ra.has(id) ? 'changed' : 'added'}`, weakens: true });
  for (const id of ra.keys()) if (!rb.has(id)) out.push({ input: REGISTER, detail: `row ${id} removed`, weakens: false });
  for (const file of [...new Set([...Object.keys(base.configs), ...Object.keys(now.configs)])].sort()) {
    const a = JSON.stringify(base.configs[file] || []);
    const b = JSON.stringify(now.configs[file] || []);
    if (a !== b) out.push({ input: file, detail: 'its grep, grepInvert, testIgnore or testMatch changed', weakens: true });
  }
  return out;
}
