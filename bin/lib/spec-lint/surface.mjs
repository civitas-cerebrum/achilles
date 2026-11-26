// The Steps surface the project's tests run against (TB-A10, TB-A2, TB-A13, TB-A14).
//
// Resolution chain, first hit wins:
//   1. worktree  <root>/node_modules/@civitas-cerebrum/element-interactions (the installed type definitions)
//   2. checkout  the main checkout's node_modules (the parent of `git rev-parse --git-common-dir`), for a
//                linked worktree that has no node_modules of its own
//   3. snapshot  bin/lib/spec-lint/surfaces/<version>.json shipped with this package, for the version the
//                project pins (package-lock.json, else the package.json range: the highest shipped match)
// When none resolves the lint cannot run, and says what it tried.
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync, realpathSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseDts } from './ast.mjs';
import * as semver from './semver.mjs';

export const PACKAGE = '@civitas-cerebrum/element-interactions';
const REPO_PACKAGE = '@civitas-cerebrum/element-repository';
const HERE = path.dirname(fileURLToPath(import.meta.url));
export const SURFACES_DIR = path.join(HERE, 'surfaces');

export class SurfaceError extends Error {}

/** Members of one declared class: public instance methods and properties, private/protected names. */
export function classMembers(ast, className) {
  const out = { found: false, methods: [], properties: [], privates: [], superClass: null, params: {} };
  const paramName = (q) => (q.type === 'TSParameterProperty' ? paramName(q.parameter) : q.type === 'AssignmentPattern' ? paramName(q.left) : q.type === 'RestElement' ? paramName(q.argument) : q.type === 'Identifier' ? q.name : '');
  const visit = (body) => {
    for (const st of body) {
      const d = st.type === 'ExportNamedDeclaration' || st.type === 'ExportDefaultDeclaration' ? st.declaration : st;
      if (!d || d.type !== 'ClassDeclaration' || !d.id || d.id.name !== className) continue;
      out.found = true;
      if (d.superClass && d.superClass.type === 'Identifier') out.superClass = d.superClass.name;
      for (const m of d.body.body) {
        const key = m.key && (m.key.type === 'Identifier' ? m.key.name : m.key.type === 'StringLiteral' ? m.key.value : null);
        if (!key || key === 'constructor' || m.static) continue;
        if (m.accessibility === 'private' || m.accessibility === 'protected' || m.type === 'ClassPrivateProperty' || m.type === 'ClassPrivateMethod') { out.privates.push(key); continue; }
        const isMethod = m.type === 'TSDeclareMethod' || m.type === 'ClassMethod';
        if (isMethod && (m.kind === 'get' || m.kind === 'set')) out.properties.push(key);
        else if (isMethod) {
          out.methods.push(key);
          const names = (m.params || []).map(paramName);
          const prev = out.params[key];
          if (!prev || names.length > prev.length) out.params[key] = names;
        }
        else out.properties.push(key);
      }
    }
  };
  visit(ast.program.body);
  for (const k of ['methods', 'properties', 'privates']) out[k] = [...new Set(out[k])].sort();
  return out;
}

/** The import specifier a declaration file uses for `name` (`import { Base } from './Base'`), or null. */
function importOf(ast, name) {
  for (const st of ast.program.body) {
    if (st.type !== 'ImportDeclaration') continue;
    for (const s of st.specifiers) if (s.local.name === name) return st.source.value;
  }
  return null;
}

/** Reads one class from a declaration file, following `extends` through relative imports. */
function readClass(parser, file, className, depth = 0) {
  if (!existsSync(file) || depth > 4) return null;
  const ast = parseDts(parser, readFileSync(file, 'utf8'));
  const own = classMembers(ast, className);
  if (!own.found) return null;
  if (own.superClass) {
    const spec = importOf(ast, own.superClass);
    const base = spec && spec.startsWith('.') ? path.resolve(path.dirname(file), `${spec}.d.ts`) : file;
    const sup = readClass(parser, base, own.superClass, depth + 1);
    if (sup) {
      for (const k of ['methods', 'properties', 'privates']) own[k] = [...new Set([...own[k], ...sup[k]])].sort();
      own.params = { ...sup.params, ...own.params };
    }
  }
  return own;
}

/** The Steps surface of an unpacked element-interactions package directory. */
export function readPackageSurface(parser, pkgDir) {
  const pkg = JSON.parse(readFileSync(path.join(pkgDir, 'package.json'), 'utf8'));
  const stepsFile = path.join(pkgDir, 'dist', 'steps', 'CommonSteps.d.ts');
  const steps = readClass(parser, stepsFile, 'Steps');
  if (!steps) return null;
  const facade = readClass(parser, path.join(pkgDir, 'dist', 'interactions', 'facade', 'ElementInteractions.d.ts'), 'ElementInteractions');
  return {
    package: PACKAGE,
    version: pkg.version,
    methods: steps.methods,
    properties: steps.properties,
    params: Object.fromEntries(Object.entries(steps.params).sort(([a], [b]) => (a < b ? -1 : 1))),
    privates: { steps: steps.privates, interactions: facade ? facade.privates : [] },
  };
}

/** Private names of ElementRepository and WebElement in an unpacked element-repository package directory. */
export function repositoryPrivatesAt(parser, dir) {
  const repo = readClass(parser, path.join(dir, 'dist', 'repo', 'ElementRepository.d.ts'), 'ElementRepository');
  const el = readClass(parser, path.join(dir, 'dist', 'types', 'WebElement.d.ts'), 'WebElement');
  return { repo: repo ? repo.privates : [], element: el ? el.privates : [] };
}

/** Private names of the repository classes, read from an installed element-repository next to the framework. */
function repositoryPrivates(parser, pkgDir) {
  const candidates = [path.join(pkgDir, 'node_modules', ...REPO_PACKAGE.split('/')), path.join(pkgDir, '..', '..', ...REPO_PACKAGE.split('/'))];
  const dir = candidates.find((d) => existsSync(path.join(d, 'package.json')));
  if (!dir) return { repo: [], element: [] };
  return repositoryPrivatesAt(parser, dir);
}

/** Every shipped snapshot version, ascending. */
export function shippedVersions(dir = SURFACES_DIR) {
  if (!existsSync(dir)) return [];
  return semver.sort(readdirSync(dir).filter((f) => f.endsWith('.json')).map((f) => f.slice(0, -5)).filter(semver.valid));
}

export function readSnapshot(version, dir = SURFACES_DIR) {
  return JSON.parse(readFileSync(path.join(dir, `${version}.json`), 'utf8'));
}

/** The version the project pins: the lock file's installed version, else the package.json range. */
export function pinnedVersion(root) {
  const lock = path.join(root, 'package-lock.json');
  if (existsSync(lock)) {
    try {
      const l = JSON.parse(readFileSync(lock, 'utf8'));
      const v = l.packages?.[`node_modules/${PACKAGE}`]?.version || l.dependencies?.[PACKAGE]?.version;
      if (v) return { exact: v, from: 'package-lock.json' };
    } catch { /* fall through to package.json */ }
  }
  const pj = path.join(root, 'package.json');
  if (!existsSync(pj)) return null;
  let p;
  try { p = JSON.parse(readFileSync(pj, 'utf8')); } catch { return null; }
  const range = p.dependencies?.[PACKAGE] || p.devDependencies?.[PACKAGE] || p.peerDependencies?.[PACKAGE] || p.optionalDependencies?.[PACKAGE];
  return range ? { range, from: 'package.json' } : null;
}

/** The main checkout's directory for this project: the parent of the common git dir, plus the project's prefix in the repository. */
function mainCheckout(root) {
  try {
    const git = (...a) => execFileSync('git', ['-C', root, ...a], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    const out = git('rev-parse', '--path-format=absolute', '--git-common-dir');
    if (!out) return null;
    const top = path.dirname(out);
    const prefix = git('rev-parse', '--show-prefix');
    const dir = path.join(top, prefix);
    return existsSync(dir) && realpathSync(dir) === realpathSync(root) ? null : dir;
  } catch { return null; }
}

function finish(s, source, where, dir) {
  const versions = shippedVersions(dir);
  const newest = versions.at(-1);
  const notes = [];
  if (newest && semver.valid(s.version) && semver.compare(s.version, newest) > 0) {
    notes.push(`the shipped surface table stops at ${newest}, older than the installed ${s.version}: upgrade Achilles; the installed type definitions are used for method checks`);
  }
  return {
    package: PACKAGE, version: s.version, source, where,
    methods: new Set(s.methods), properties: new Set(s.properties || []), params: s.params || {},
    privates: { steps: new Set(s.privates?.steps || []), interactions: new Set(s.privates?.interactions || []), repo: new Set(s.privates?.repo || []), element: new Set(s.privates?.element || []) },
    notes,
  };
}

/** Resolves the surface for the project at `root`. Throws SurfaceError naming every place tried. */
export function resolveSurface(root, parser, { snapshotsDir = SURFACES_DIR, useGit = true } = {}) {
  const tried = [];
  const fromNodeModules = (base, source) => {
    const dir = path.join(base, 'node_modules', ...PACKAGE.split('/'));
    tried.push(`${source}: ${dir}`);
    if (!existsSync(path.join(dir, 'package.json'))) return null;
    const s = readPackageSurface(parser, dir);
    if (!s) return null;
    s.privates = { ...s.privates, ...repositoryPrivates(parser, dir) };
    return finish(s, source, dir, snapshotsDir);
  };
  const wt = fromNodeModules(root, 'worktree');
  if (wt) return wt;
  if (useGit) {
    const main = mainCheckout(root);
    if (main) {
      const co = fromNodeModules(main, 'checkout');
      if (co) return co;
    } else tried.push('checkout: not a linked worktree');
  }
  const pin = pinnedVersion(root);
  const versions = shippedVersions(snapshotsDir);
  if (!pin) tried.push(`snapshot: no ${PACKAGE} dependency in package.json`);
  else {
    const v = pin.exact ? (versions.includes(pin.exact) ? pin.exact : null) : semver.maxSatisfying(versions, pin.range);
    tried.push(`snapshot: ${pin.exact || pin.range} (${pin.from}) against shipped ${versions[0] || '-'}..${versions.at(-1) || '-'}`);
    if (v) return finish(readSnapshot(v, snapshotsDir), 'snapshot', path.join(snapshotsDir, `${v}.json`), snapshotsDir);
  }
  throw new SurfaceError(`no Steps surface for ${PACKAGE} resolved (${tried.join('; ')})`);
}
