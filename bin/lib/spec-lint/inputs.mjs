// The rule inputs the test baseline protects (test-baseline.md TB-G2), read from a commit so a change cannot
// relax the rules it is checked against: the factory rules' `specs.*` and `secrets.*` rules (and the file
// itself), the id pattern in a committed `.env`, the framework-gap register, and the test selection of every
// Playwright config of the project (found as the lint's scope finds them, subdirectories included): `testDir`,
// `testMatch`, `testIgnore`, `grep` and `grepInvert`, at the top and per project, evaluated statically. A
// selection that cannot be evaluated is compared through the text of the config and the relative modules it
// loads: any change there counts as a selection change. CI and `--ratchet` lint with the merge-base's inputs
// and fail a change that weakens one; the pre-commit check lints with HEAD's and names the change.
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import path from 'node:path';
import { gitSync } from './git.mjs';
import { REGISTER } from './waivers.mjs';
import { parserFor } from './ast.mjs';
import { configSelection, findConfigs, isConfigPath, within, SELECTION_KEYS as SELECTION } from './config-scope.mjs';
import { workTreeTop } from './surface.mjs';

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
const digest = (text) => createHash('sha1').update(text).digest('hex');
const MODULE_EXTS = ['', '.ts', '.mts', '.cts', '.js', '.mjs', '.cjs', '.json'];

/**
 * One config's protected shape: its evaluated selection, what could not be evaluated, and the text digests of
 * the config and of the relative modules it loads (followed three levels deep), which decide a change when
 * the selection is not static.
 */
function configShape(root, parser, read, rel, top) {
  const text = read(rel);
  if (typeof text !== 'string') return null;
  const { selection, unevaluable, imports } = configSelection(parser, text, path.join(root, rel), root);
  const deps = { [rel]: digest(text) };
  const outside = [];
  const queue = imports.map((s) => [rel, s, 1]);
  while (queue.length && Object.keys(deps).length < 25) {
    const [from, spec, depth] = queue.shift();
    const base = path.posix.normalize(path.posix.join(path.posix.dirname(from), spec));
    // a module elsewhere in the work tree is read like any other; only one outside the work tree is unknown
    if (!within(top, path.resolve(root, base))) { if (!outside.includes(base)) outside.push(base); deps[base] = '(outside the work tree)'; continue; }
    const candidates = [...MODULE_EXTS.map((e) => base + e), ...MODULE_EXTS.slice(1).map((e) => base.replace(/\.[cm]?js$/, e)), ...MODULE_EXTS.slice(1).map((e) => `${base}/index${e}`)];
    const hit = candidates.find((c) => typeof read(c) === 'string');
    if (!hit) { deps[base] = '(missing)'; continue; }
    if (deps[hit]) continue;
    const t = read(hit);
    deps[hit] = digest(t);
    if (depth < 3 && /\.[cm]?[jt]s$/.test(hit)) {
      try { for (const s of configSelection(parser, t, path.join(root, hit), root).imports) queue.push([hit, s, depth + 1]); } catch { /* not code */ }
    }
  }
  return { selection, unevaluable, deps, outside };
}

const realOf = (p) => { try { return realpathSync(p); } catch { return p; } };
const topOf = (root) => realOf(workTreeTop(root) || root);

function shape(root, read, configNames, top) {
  root = realOf(root);
  const factoryText = read(factoryPath());
  const parser = parserFor(root);
  const configs = {};
  for (const f of configNames) {
    const c = configShape(root, parser, read, f, top);
    if (c) configs[f] = c;
  }
  return { factoryText, factory: parseJson(factoryText), register: read(REGISTER), envPattern: envValue(read('.env')), configs };
}

/** The protected inputs as committed at `rev` (a commit), or staged in the index when `rev` is ''. */
export function inputsAt(root, rev) {
  const cache = new Map();
  const top = topOf(root);
  const real = realOf(root);
  const read = (rel) => {
    if (!cache.has(rel)) {
      let t = null;
      // paths from the work tree's top level, so a module beside the project (../shared/…) is read too
      const fromTop = path.relative(top, path.resolve(real, rel)).split(path.sep).join('/');
      if (!fromTop.startsWith('..')) { try { t = gitSync(root, ['show', `${rev}:${fromTop}`]); } catch { /* not there */ } }
      cache.set(rel, t);
    }
    return cache.get(rel);
  };
  let names = [];
  try {
    const list = rev === '' ? gitSync(root, ['ls-files']) : gitSync(root, ['ls-tree', '-r', '--name-only', rev, './']);
    names = list.split('\n').map((x) => x.trim()).filter((x) => x && isConfigPath(x));
  } catch { /* none */ }
  return shape(root, read, names, top);
}

/** The files that hold protected inputs, at either side (the modules a config loads included). */
export function inputPaths(base, now) {
  const configFiles = [base, now].flatMap((s) => Object.values(s.configs).flatMap((c) => Object.keys(c.deps)));
  return new Set([factoryPath(), '.env', REGISTER, ...Object.keys(base.configs), ...Object.keys(now.configs), ...configFiles]);
}

/** The protected inputs as they are on disk. */
export function inputsOnDisk(root) {
  const read = (rel) => { const p = path.join(root, rel); try { return existsSync(p) ? readFileSync(p, 'utf8') : null; } catch { return null; } };
  const names = findConfigs(root).map((abs) => path.relative(root, abs).split(path.sep).join('/'));
  return shape(root, read, names, topOf(root));
}

/**
 * The configs whose test selection the check cannot evaluate, for the summary: [{ config, keys, why, outside }].
 * Such a selection is compared only by the text of the config and the modules it loads, so a change through an
 * environment variable, a package or a workflow file is not seen; `outside` lists loaded modules outside the
 * work tree, which are not compared at all.
 */
export function unevaluatedConfigs(...sides) {
  const out = new Map();
  for (const side of sides) for (const [config, c] of Object.entries((side && side.configs) || {})) {
    if (out.has(config) || !c.unevaluable.length) continue;
    const parts = c.unevaluable.map((u) => { const m = /^([\w.[\]]+) \((.*)\)$/.exec(u); return m ? { key: m[1], why: m[2] } : { key: 'the config', why: u }; });
    out.set(config, { config, keys: [...new Set(parts.map((p) => p.key))], why: [...new Set(parts.map((p) => p.why))], outside: c.outside || [] });
  }
  return [...out.values()].sort((a, b) => (a.config < b.config ? -1 : 1));
}

/** The summary line for one config `unevaluatedConfigs` returned. */
export function unevaluatedLine(u) {
  return `${u.config}: ${u.keys.join(', ')} cannot be evaluated statically (${u.why.join('; ')}); compared by the text of the config and the modules it loads only: a change through an environment variable, a package or a workflow file is not seen${u.outside.length ? `; ${u.outside.join(', ')} ${u.outside.length === 1 ? 'is' : 'are'} outside the work tree and not compared` : ''}`;
}

/** True only for the rule change known to tighten: the constant-table setting switched off. */
function tightens(key, was, is) {
  return key === 'specs.constant-table-tests' && !!(was && was.allowed === true) && !(is && is.allowed === true);
}

const rowsOf = (text) => new Map((typeof text === 'string' ? text.split(/\r?\n/) : []).map((l) => l.trim()).filter((l) => /^\|\s*FG-\d+\s*\|/.test(l)).map((l) => [/FG-\d+/.exec(l)[0], l]));
const guarded = (rules) => Object.fromEntries(Object.entries((rules && rules.rules) || {}).filter(([k]) => /^(specs|secrets)\./.test(k)));
const forbidden = (rules) => new Set((((rules && rules.rules) || {})['selectors.no-inline'] || {}).forbidden || []);

/**
 * How `now` differs from `base`: [{ input, detail, weakens }]. `weakens` is false only for the forms known to
 * tighten: `selectors.no-inline.forbidden` gaining entries, a register row removed, the constant-table setting
 * switched off. Every other change, an added rule included (a new rule can be permissive), is read as weakening.
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
    const d = configChange(base.configs[file], now.configs[file]);
    if (d) out.push({ input: file, detail: d, weakens: true });
  }
  return out;
}

/** Which selection keys differ between two evaluated selections (per project by position). */
function changedKeys(a, b) {
  const keys = [];
  for (const k of SELECTION) if (JSON.stringify(a[k]) !== JSON.stringify(b[k])) keys.push(k);
  const pa = a.projects || [];
  const pb = b.projects || [];
  if (pa.length !== pb.length) keys.push(`projects (${pa.length} to ${pb.length})`);
  else pa.forEach((p, i) => { if (JSON.stringify(p) !== JSON.stringify(pb[i])) keys.push(`projects[${i}]${p && p.name ? ` (${p.name})` : ''}`); });
  return keys;
}

/**
 * How a config's test selection changed, or null. Both sides evaluated: the evaluated values are compared.
 * Either side not static: any change of the config's text or of a relative module it loads is a change (the
 * value cannot be compared, so it goes to the owner's review).
 */
function configChange(a, b) {
  if (!a && !b) return null;
  if (!a) return 'a new Playwright config: its test selection needs review';
  if (!b) return 'the Playwright config is deleted';
  if (!a.unevaluable.length && !b.unevaluable.length) {
    const keys = changedKeys(a.selection || {}, b.selection || {});
    return keys.length ? `its test selection changed (${keys.join(', ')})` : null;
  }
  if (JSON.stringify(a.deps) === JSON.stringify(b.deps)) return null;
  const what = [...new Set([...a.unevaluable, ...b.unevaluable])].slice(0, 3).join('; ');
  const moved = Object.keys({ ...a.deps, ...b.deps }).filter((f) => a.deps[f] !== b.deps[f]);
  return `its test selection cannot be evaluated statically (${what}) and ${moved.join(', ')} changed`;
}
