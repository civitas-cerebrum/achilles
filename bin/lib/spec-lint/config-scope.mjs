// Which files the spec lint reads, and as what (test-baseline.md §Scope).
//
// Spec roots and globs come from every playwright*.config.* read statically (testDir, testMatch,
// testIgnore, projects[].testDir/testMatch/testIgnore/dependencies), unioned with Playwright's default
// testMatch and with tests/**. A config value the engine cannot evaluate statically is reported (advisory)
// and the defaults apply. Kinds:
//   spec     a file a config would run as a test, or code under a spec root that calls test()/describe()
//            on a test binding (a *.setup.* file that no setup project uses counts only when it declares tests)
//   support  non-spec code under the spec roots that a spec imports (transitively), anything under
//            fixtures/ flows/ data/ support/ utils/ lib/ helpers/, a *.setup.* file a setup project uses,
//            a globalSetup / globalTeardown module a config names
//   k6       under tests/perf/
//   bundle   inside a directory under an evidence/ folder that holds a summary.md, when no glob runs it
//   excluded tests/e2e/inspect/**, node_modules, reports, .d.ts, JSON, the configs themselves
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parseCode, isStr, strValue, unwrap, memberChain, isCall } from './ast.mjs';

export const CODE_EXT = /\.(?:[cm]?[jt]sx?)$/i;
const CONFIG_RE = /^playwright[\w.-]*\.config\.(?:[cm]?[jt]s)$/;
const SKIP_DIRS = new Set(['node_modules', '.git', 'playwright-report', 'test-results', 'blob-report', 'coverage', '.achilles', 'dist', 'build', '.next']);
const SUPPORT_DIRS = new Set(['fixtures', 'flows', 'data', 'support', 'utils', 'lib', 'helpers']);
export const DEFAULT_TEST_MATCH = '**/*.@(spec|test).?(c|m)[jt]s?(x)';

/** Glob (minimatch subset: **, *, ?, [..], {a,b}, @(a|b), ?(a|b), *(a|b), +(a|b)) to a RegExp over posix paths. */
export function globToRegExp(glob) {
  let re = '';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    const ext = /[@?*+!]/.test(c) && glob[i + 1] === '(';
    if (ext) {
      const end = matching(glob, i + 1, '(', ')');
      const alts = splitTop(glob.slice(i + 2, end), '|').map((a) => globToRegExp(a).source.slice(1, -1)).join('|');
      re += c === '@' ? `(?:${alts})` : c === '?' ? `(?:${alts})?` : c === '*' ? `(?:${alts})*` : c === '+' ? `(?:${alts})+` : `(?!(?:${alts}))[^/]*`;
      i = end;
    } else if (c === '*') {
      if (glob[i + 1] === '*') {
        const slash = glob[i + 2] === '/';
        re += slash ? '(?:[^/]*/)*' : '.*';
        i += slash ? 2 : 1;
      } else re += '[^/]*';
    } else if (c === '?') re += '[^/]';
    else if (c === '[') {
      const end = glob.indexOf(']', i + 1);
      if (end === -1) re += '\\[';
      else { re += `[${glob.slice(i + 1, end).replace(/^!/, '^').replace(/\\/g, '\\\\')}]`; i = end; }
    } else if (c === '{') {
      const end = matching(glob, i, '{', '}');
      re += `(?:${splitTop(glob.slice(i + 1, end), ',').map((a) => globToRegExp(a).source.slice(1, -1)).join('|')})`;
      i = end;
    } else re += /[.+^${}()|\\]/.test(c) ? `\\${c}` : c;
  }
  return new RegExp(`^${re}$`);
}
function matching(s, i, open, close) {
  let d = 0;
  for (let j = i; j < s.length; j++) { if (s[j] === open) d++; else if (s[j] === close && --d === 0) return j; }
  return s.length - 1;
}
function splitTop(s, sep) {
  const out = [];
  let d = 0, cur = '';
  for (const ch of s) {
    if (ch === '(' || ch === '{') d++;
    if (ch === ')' || ch === '}') d--;
    if (ch === sep && d === 0) { out.push(cur); cur = ''; } else cur += ch;
  }
  out.push(cur);
  return out;
}

/** A testMatch / testIgnore entry as a predicate over an absolute path. Playwright matches a glob without a slash against any directory depth. */
function matcher(entry, testDir) {
  if (entry instanceof RegExp) return (abs) => entry.test(abs);
  let g = String(entry);
  if (!g.includes('/')) g = `**/${g}`;
  const re = globToRegExp(g);
  return (abs) => {
    const rel = path.relative(testDir, abs).split(path.sep).join('/');
    return re.test(abs.split(path.sep).join('/')) || (!rel.startsWith('..') && re.test(rel));
  };
}

// ── static evaluation of a config ─────────────────────────────────────────

export class Unevaluable extends Error {}

/**
 * The static value of an expression: literals, arrays, `+`, `path.join` / `path.resolve` (relative to `env.cwd`,
 * else `env.dir`), `path.dirname`, `__dirname`, `import.meta.dirname` / `import.meta.url`, `fileURLToPath`,
 * `new URL(<rel>, import.meta.url)` and the module's constants (`env.consts`); `env.file` is the module itself.
 * Throws Unevaluable otherwise.
 */
export function staticValue(node, env) { return evaluate(node, env); }

function evaluate(node, env) {
  const n = unwrap(node);
  if (!n) throw new Unevaluable('missing');
  if (isStr(n)) return strValue(n);
  if (n.type === 'RegExpLiteral') return new RegExp(n.pattern, n.flags);
  if (n.type === 'ArrayExpression') return n.elements.map((e) => evaluate(e, env));
  if (n.type === 'Identifier') {
    if (n.name === '__dirname') return env.dir;
    if (n.name === 'undefined') return undefined;
    if (env.consts.has(n.name)) return evaluate(env.consts.get(n.name), env);
    throw new Unevaluable(n.name);
  }
  if (n.type === 'ObjectExpression') {
    const o = {};
    for (const p of n.properties) {
      if (p.type !== 'ObjectProperty' || p.computed) throw new Unevaluable('object shape');
      const k = p.key.type === 'Identifier' ? p.key.name : isStr(p.key) ? strValue(p.key) : null;
      if (k === null) throw new Unevaluable('object key');
      o[k] = { node: p.value };
    }
    return o;
  }
  if (n.type === 'BinaryExpression' && n.operator === '+') return evaluate(n.left, env) + evaluate(n.right, env);
  if (isCall(n)) {
    const ch = memberChain(n.callee);
    const name = ch && ch.join('.');
    if (name && /^(?:path\.)?(?:join|resolve)$/.test(name)) {
      const parts = n.arguments.map((a) => evaluate(a, env));
      return name.endsWith('resolve') ? path.resolve(env.cwd || env.dir, ...parts) : path.join(...parts);
    }
    if (name && /^(?:path\.)?dirname$/.test(name) && n.arguments.length === 1) return path.dirname(evaluate(n.arguments[0], env));
    if (name === 'defineConfig' && n.arguments.length === 1) return evaluate(n.arguments[0], env);
    if (name === 'require.resolve' && n.arguments.length === 1) return path.resolve(env.dir, evaluate(n.arguments[0], env));
    if (name === 'fileURLToPath' || name === 'url.fileURLToPath') {
      if (!env.file) return env.dir;
      const v = evaluate(n.arguments[0], env);
      if (typeof v !== 'string' || !v.startsWith('file:')) throw new Unevaluable('fileURLToPath of a non-file URL');
      return fileURLToPath(v);
    }
  }
  if (n.type === 'MemberExpression' && memberChain(n)?.join('.') === 'import.meta.dirname') return env.dir;
  if (n.type === 'MemberExpression' && env.file && memberChain(n)?.join('.') === 'import.meta.url') return pathToFileURL(env.file).href;
  if (n.type === 'NewExpression' && n.callee.type === 'Identifier' && n.callee.name === 'URL' && n.arguments.length === 2) return new URL(evaluate(n.arguments[0], env), evaluate(n.arguments[1], env)).href;
  throw new Unevaluable(n.type);
}

/** The exported config object (property → { node }) or null. */
function configObject(ast, env) {
  for (const st of ast.program.body) {
    if (st.type === 'VariableDeclaration') for (const d of st.declarations) if (d.id.type === 'Identifier' && d.init) env.consts.set(d.id.name, d.init);
  }
  for (const st of ast.program.body) {
    let expr = null;
    if (st.type === 'ExportDefaultDeclaration') expr = st.declaration;
    else if (st.type === 'ExpressionStatement' && st.expression.type === 'AssignmentExpression' && memberChain(st.expression.left)?.join('.') === 'module.exports') expr = st.expression.right;
    if (expr) return evaluate(expr, env);
  }
  return null;
}

/** Reads one config. Returns { file, projects: [{ name, testDir, match, ignore, dependencies, setup }], problems }. */
export function readConfig(root, abs, parser) {
  const rel = path.relative(root, abs).split(path.sep).join('/');
  const dir = path.dirname(abs);
  const env = { dir, file: abs, consts: new Map() };
  const problems = [];
  let top = null;
  try {
    top = configObject(parseCode(parser, readFileSync(abs, 'utf8'), abs), env);
    if (!top) problems.push('no exported config object');
  } catch (e) { problems.push(e instanceof Unevaluable ? `the exported config is not a static object (${e.message})` : `does not parse (${e.message})`); }
  const value = (obj, key, fallback) => {
    if (!obj || !(key in obj)) return fallback;
    try { return evaluate(obj[key].node, env); } catch (e) { problems.push(`${key} cannot be evaluated statically (${e.message})`); return fallback; }
  };
  const list = (v) => (v === undefined ? undefined : Array.isArray(v) ? v : [v]);
  const baseDir = value(top, 'testDir', undefined);
  const base = {
    testDir: typeof baseDir === 'string' ? path.resolve(dir, baseDir) : dir,
    match: list(value(top, 'testMatch', undefined)),
    ignore: list(value(top, 'testIgnore', undefined)) || [],
  };
  const projects = [];
  const raw = value(top, 'projects', undefined);
  if (Array.isArray(raw)) {
    for (const p of raw) {
      if (!p || typeof p !== 'object' || p instanceof RegExp) { problems.push('a project is not an object literal'); continue; }
      const td = value(p, 'testDir', undefined);
      projects.push({
        name: value(p, 'name', undefined),
        testDir: typeof td === 'string' ? path.resolve(dir, td) : base.testDir,
        match: list(value(p, 'testMatch', undefined)) || base.match,
        ignore: list(value(p, 'testIgnore', undefined)) || base.ignore,
        dependencies: (list(value(p, 'dependencies', undefined)) || []).filter((d) => typeof d === 'string'),
        teardown: value(p, 'teardown', undefined),
      });
    }
  }
  if (!projects.length) projects.push({ name: undefined, ...base, dependencies: [] });
  const setupNames = new Set(projects.flatMap((p) => [...p.dependencies, ...(typeof p.teardown === 'string' ? [p.teardown] : [])]));
  for (const p of projects) {
    p.setup = p.name !== undefined && setupNames.has(p.name);
    const m = (p.match || [DEFAULT_TEST_MATCH]).map((e) => matcher(e, p.testDir));
    const ig = p.ignore.map((e) => matcher(e, p.testDir));
    p.runs = (abs) => within(p.testDir, abs) && m.some((f) => f(abs)) && !ig.some((f) => f(abs));
  }
  // Playwright's global setup / teardown modules run code but declare no tests: support files.
  const globals = ['globalSetup', 'globalTeardown'].flatMap((k) => list(value(top, k, undefined)) || []).filter((g) => typeof g === 'string').map((g) => path.resolve(dir, g));
  return { file: rel, projects, globals, problems };
}

export const within = (dir, abs) => { const r = path.relative(dir, abs); return r === '' || (!r.startsWith('..') && !path.isAbsolute(r)); };

// ── the test selection of a config, evaluated (the protected input of TB-G2) ──

/** The selection keys of a config and of each of its projects. */
export const SELECTION_KEYS = ['testDir', 'testMatch', 'testIgnore', 'grep', 'grepInvert'];

/** True for a project-relative posix path findConfigs would return (same name rule, same skipped directories, same depth). */
export function isConfigPath(rel) {
  const parts = rel.split('/');
  const dirs = parts.slice(0, -1);
  return CONFIG_RE.test(parts.at(-1)) && dirs.length <= 4 && dirs.every((d) => d && !SKIP_DIRS.has(d) && !d.startsWith('.'));
}

/**
 * The test selection a config makes, evaluated as the lint reads it: `testDir`, `testMatch`, `testIgnore`,
 * `grep`, `grepInvert` at the top and per project (with the project's name), paths relative to `root`,
 * regular expressions as `/source/flags`. Constants declared in the config are followed. Returns
 * { selection, unevaluable, imports }: `unevaluable` lists what could not be read statically (then the
 * selection is incomplete), `imports` the relative module specifiers the config loads.
 */
export function configSelection(parser, text, abs, root) {
  const env = { dir: path.dirname(abs), file: abs, consts: new Map() };
  const unevaluable = [];
  let ast = null;
  try { ast = parseCode(parser, text, abs); } catch (e) { return { selection: null, unevaluable: [`does not parse (${e.message})`], imports: [] }; }
  const imports = [];
  for (const st of ast.program.body) {
    if ((st.type === 'ImportDeclaration' || st.type === 'ExportAllDeclaration' || st.type === 'ExportNamedDeclaration') && st.source && st.source.value.startsWith('.')) imports.push(st.source.value);
  }
  const stack = [ast.program];
  while (stack.length) {
    const n = stack.pop();
    if (!n || typeof n.type !== 'string') continue;
    if (isCall(n) && n.callee.type === 'Identifier' && n.callee.name === 'require' && isStr(n.arguments[0]) && strValue(n.arguments[0]).startsWith('.')) imports.push(strValue(n.arguments[0]));
    for (const k of Object.keys(n)) {
      if (k === 'loc' || k.endsWith('Comments')) continue;
      const v = n[k];
      if (Array.isArray(v)) for (const c of v) { if (c && typeof c.type === 'string') stack.push(c); } else if (v && typeof v.type === 'string') stack.push(v);
    }
  }
  const ser = (v) => {
    if (v instanceof RegExp) return `/${v.source}/${v.flags}`;
    if (Array.isArray(v)) return v.map(ser);
    if (typeof v === 'string') return path.isAbsolute(v) ? (within(root, v) ? `./${path.relative(root, v).split(path.sep).join('/')}` : v) : v;
    if (v === undefined) return null;
    if (v && typeof v === 'object') throw new Unevaluable('an object');
    return v;
  };
  const read = (obj, key, where) => {
    if (!obj || !(key in obj)) return undefined;
    try {
      const v = evaluate(obj[key].node, env);
      return ser(key === 'testDir' && typeof v === 'string' ? path.resolve(env.dir, v) : v);
    } catch (e) { unevaluable.push(`${where}${key} (${e instanceof Unevaluable ? e.message : e.message})`); return '(not static)'; }
  };
  let top;
  try { top = configObject(ast, env); } catch (e) { return { selection: null, unevaluable: [`the exported config is not a static object (${e.message})`], imports: [...new Set(imports)] }; }
  if (!top) return { selection: null, unevaluable: ['no exported config object'], imports: [...new Set(imports)] };
  const pick = (obj, where) => Object.fromEntries(SELECTION_KEYS.map((k) => [k, read(obj, k, where)]).filter(([, v]) => v !== undefined));
  const selection = pick(top, '');
  if ('projects' in top) {
    let raw;
    try { raw = evaluate(top.projects.node, env); } catch (e) { unevaluable.push(`projects (${e.message})`); raw = null; }
    if (Array.isArray(raw)) {
      selection.projects = raw.map((p, i) => {
        if (!p || typeof p !== 'object' || p instanceof RegExp || Array.isArray(p)) { unevaluable.push(`projects[${i}] (not an object literal)`); return '(not static)'; }
        const name = read(p, 'name', `projects[${i}].`);
        return { ...(name !== undefined ? { name } : {}), ...pick(p, `projects[${i}].`) };
      });
    } else if (raw !== null) unevaluable.push('projects (not an array)');
  }
  return { selection, unevaluable, imports: [...new Set(imports)] };
}

/** Every playwright*.config.* under root (outside node_modules and report folders). */
export function findConfigs(root) {
  const out = [];
  const walk = (dir, depth) => {
    if (depth > 4) return;
    let entries;
    try { entries = readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      if (e.isDirectory()) { if (!SKIP_DIRS.has(e.name) && !e.name.startsWith('.')) walk(path.join(dir, e.name), depth + 1); }
      else if (CONFIG_RE.test(e.name)) out.push(path.join(dir, e.name));
    }
  };
  walk(root, 0);
  return out.sort();
}

/** Code files under the spec roots (candidates for classification), excluding the always-excluded paths. */
export function candidateFiles(root, specRoots) {
  const out = new Set();
  const walk = (dir) => {
    let entries;
    try { entries = readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) { if (!SKIP_DIRS.has(e.name)) walk(p); continue; }
      if (!CODE_EXT.test(e.name) || /\.d\.[cm]?ts$/.test(e.name) || CONFIG_RE.test(e.name)) continue;
      out.add(p);
    }
  };
  for (const r of specRoots) if (existsSync(r) && statSync(r).isDirectory()) walk(r);
  return [...out].sort();
}

/** The scope of a project: configs, spec roots, and a classifier for one file. */
export function projectScope(root, parser) {
  const configs = findConfigs(root).map((f) => readConfig(root, f, parser));
  const globalFiles = new Set(configs.flatMap((c) => c.globals));
  const testsDir = path.join(root, 'tests');
  const specRoots = [...new Set([testsDir, ...configs.flatMap((c) => c.projects.map((p) => p.testDir))])].filter((d) => within(root, d));
  const defaultMatch = globToRegExp(DEFAULT_TEST_MATCH);
  const rel = (abs) => path.relative(root, abs).split(path.sep).join('/');
  const underRoot = (abs) => specRoots.find((r) => within(r, abs));

  /** Static kind before import and test-call information: excluded | k6 | bundle | run | setup | support-dir | candidate. */
  function staticKind(abs) {
    const r = rel(abs);
    if (/^tests\/e2e\/inspect\//.test(r) || specRoots.some((sr) => within(path.join(sr, 'inspect'), abs) && path.basename(sr) === 'e2e')) return 'excluded';
    if (/^tests\/perf\//.test(r)) return 'k6';
    const projects = configs.flatMap((c) => c.projects);
    const setupHit = projects.some((p) => p.setup && p.runs(abs));
    const isSetupName = /\.setup\.[cm]?[jt]sx?$/.test(abs);
    if (globalFiles.has(abs) || globalFiles.has(abs.replace(/\.[cm]?[jt]sx?$/, ''))) return 'setup';
    if (setupHit && isSetupName) return 'setup';
    const root0 = underRoot(abs);
    const runs = projects.some((p) => p.runs(abs)) || (root0 && defaultMatch.test(path.basename(abs)));
    if (runs) return 'run';
    const m = /(^|\/)evidence\/([^/]+)\//.exec(r);
    if (m) {
      const bundleDir = path.join(root, r.slice(0, m.index + m[0].length));
      if (existsSync(path.join(bundleDir, 'summary.md'))) return 'bundle';
    }
    const inner = root0 ? path.relative(root0, path.dirname(abs)).split(path.sep) : [];
    if (inner.some((seg) => SUPPORT_DIRS.has(seg))) return 'support-dir';
    return 'candidate';
  }

  const problems = configs.filter((c) => c.problems.length).map((c) => ({ file: c.file, message: c.problems.join('; ') }));
  return { configs, specRoots, staticKind, problems };
}
