// The Steps surface the project's tests run against (TB-A10, TB-A2, TB-A13, TB-A14).
//
// Resolution chain, first hit wins:
//   1. worktree  <root>/node_modules/@civitas-cerebrum/element-interactions (the installed type definitions)
//   2. workspace the same under a directory above the project, up to the work tree's top level and never
//                above it (a package of an npm, yarn or pnpm workspace whose install is hoisted to the root);
//                skipped when the project's own package.json declares a range that install does not satisfy
//   3. checkout  the main checkout's node_modules (the parent of `git rev-parse --git-common-dir`), for a
//                linked worktree that has no node_modules of its own, with the same walk up
//   4. snapshot  bin/lib/spec-lint/surfaces/<version>.json shipped with this package, for the version the
//                project pins: its own package-lock.json, else its own package.json range (a workspace lock
//                file above it narrows that range to the installed release; the highest shipped match
//                otherwise); a project that declares nothing takes the lock file, else the declaring
//                package.json, of the nearest workspace directory above it
// When none resolves the lint cannot run, and says what it tried.
import { gitSync } from './git.mjs';
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

/** The range a package.json in `dir` declares for the framework, or null. */
function declaredRange(dir) {
  const pj = path.join(dir, 'package.json');
  if (!existsSync(pj)) return null;
  let p;
  try { p = JSON.parse(readFileSync(pj, 'utf8')); } catch { return null; }
  return p.dependencies?.[PACKAGE] || p.devDependencies?.[PACKAGE] || p.peerDependencies?.[PACKAGE] || p.optionalDependencies?.[PACKAGE] || null;
}

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&');

/** pnpm-lock.yaml: the release the importer at `rel` ('.' for the root) resolved, else a single package entry. */
function pnpmVersion(text, rel) {
  const lines = text.split(/\r?\n/);
  const name = new RegExp(`^ {6}(['"]?)${escapeRe(PACKAGE)}\\1:\\s*(.*)$`);
  let inImporters = false;
  let inProject = false;
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    if (/^importers:\s*$/.test(l)) { inImporters = true; continue; }
    if (inImporters && /^\S/.test(l)) break;
    const imp = /^ {2}(?! )(['"]?)(.+?)\1:\s*$/.exec(l);
    if (inImporters && imp) { inProject = imp[2] === rel; continue; }
    const m = inProject ? name.exec(l) : null;
    if (!m) continue;
    const inline = /^['"]?(\d+\.\d+\.\d+)/.exec(m[2]);
    if (inline) return inline[1];
    for (let j = i + 1; j < lines.length && /^ {8}/.test(lines[j]); j++) {
      const v = /^ {8}version:\s*['"]?(\d+\.\d+\.\d+)/.exec(lines[j]);
      if (v) return v[1];
    }
  }
  const found = new Set([...text.matchAll(new RegExp(`^ {2}['"]?/?${escapeRe(PACKAGE)}[@/](\\d+\\.\\d+\\.\\d+)`, 'gm'))].map((m) => m[1]));
  return found.size === 1 ? [...found][0] : null;
}

/** yarn.lock: the release it resolved the framework to, when it resolved exactly one. */
function yarnVersion(text) {
  const found = new Set();
  let inEntry = false;
  for (const l of text.split(/\r?\n/)) {
    if (/^\S/.test(l)) { inEntry = l.replace(/^"/, '').startsWith(`${PACKAGE}@`); continue; }
    const m = inEntry ? /^\s+version:?\s+"?(\d+\.\d+\.\d+)/.exec(l) : null;
    if (m) found.add(m[1]);
  }
  return found.size === 1 ? [...found][0] : null;
}

/**
 * The framework release a lock file in `dir` records for the project at `rel` (its posix path from `dir`, ''
 * for `dir` itself): package-lock.json (the project's nested entry, else the hoisted one), pnpm-lock.yaml (the
 * project's importer) or yarn.lock. Returns { exact, file } or null.
 */
function lockedVersion(dir, rel) {
  const npmLock = path.join(dir, 'package-lock.json');
  if (existsSync(npmLock)) {
    try {
      const l = JSON.parse(readFileSync(npmLock, 'utf8'));
      const v = (rel && l.packages?.[`${rel}/node_modules/${PACKAGE}`]?.version) || l.packages?.[`node_modules/${PACKAGE}`]?.version || (!rel && l.dependencies?.[PACKAGE]?.version);
      if (v) return { exact: v, file: npmLock };
    } catch { /* not a lock file */ }
  }
  const pnpm = path.join(dir, 'pnpm-lock.yaml');
  if (existsSync(pnpm)) {
    const v = pnpmVersion(readFileSync(pnpm, 'utf8'), rel || '.');
    if (v) return { exact: v, file: pnpm };
  }
  const yarn = path.join(dir, 'yarn.lock');
  if (existsSync(yarn)) {
    const v = yarnVersion(readFileSync(yarn, 'utf8'));
    if (v) return { exact: v, file: yarn };
  }
  return null;
}

/** The directories above `root` up to and including `top`, nearest first; none when `top` does not hold `root`. */
function workspaceDirs(root, top) {
  if (!top) return [];
  const rel = path.relative(top, root);
  if (rel === '' || rel.startsWith('..') || path.isAbsolute(rel)) return [];
  const out = [];
  for (let d = path.dirname(root); ; d = path.dirname(d)) {
    out.push(d);
    if (d === top || path.dirname(d) === d) break;
  }
  return out;
}

const realOf = (p) => { try { return realpathSync(p); } catch { return p; } };
const relPosixOf = (from, to) => path.relative(from, to).split(path.sep).join('/');

/** The top level of the work tree that holds `root` (its real path), or null (no git, not in a work tree). */
export function workTreeTop(root) {
  try {
    const t = gitSync(root, ['rev-parse', '--show-toplevel'], { stderr: 'ignore', timeoutMs: 10000 }).trim();
    return t ? realOf(t) : null;
  } catch { return null; }
}

/** The files above the project the resolved surface may come from (a workspace root's install and lock files), for a cache key. */
export function workspaceInputs(root) {
  return workspaceDirs(realOf(root), workTreeTop(root)).flatMap((d) => [path.join(d, 'node_modules', ...PACKAGE.split('/'), 'package.json'), ...['package.json', 'package-lock.json', 'pnpm-lock.yaml', 'yarn.lock'].map((f) => path.join(d, f))]);
}

/**
 * The version the project pins: its own lock file's installed version, else its own package.json range (a
 * workspace lock file above it, up to `top`, narrows that range to the release installed for it). A project
 * that declares nothing takes the nearest workspace directory's lock file, else its declaring package.json.
 */
export function pinnedVersion(root, { top = null } = {}) {
  const own = lockedVersion(root, '');
  if (own) return { exact: own.exact, from: path.basename(own.file) };
  const real = realOf(root);
  const above = workspaceDirs(real, top);
  const range = declaredRange(root);
  for (const d of above) {
    const l = lockedVersion(d, relPosixOf(d, real));
    if (l && (!range || semver.satisfies(l.exact, range))) return { exact: l.exact, from: `${relPosixOf(real, l.file)} (workspace lock file)` };
    if (range) continue;
    const r = declaredRange(d);
    if (r) return { range: r, from: `${relPosixOf(real, path.join(d, 'package.json'))} (workspace root)` };
  }
  return range ? { range, from: 'package.json' } : null;
}

/** The main checkout's directory for this project: the parent of the common git dir, plus the project's prefix in the repository. */
function mainCheckout(root) {
  try {
    const git = (...a) => gitSync(root, a, { stderr: 'ignore', timeoutMs: 10000 }).trim();
    const out = git('rev-parse', '--path-format=absolute', '--git-common-dir');
    if (!out) return null;
    const top = path.dirname(out);
    const prefix = git('rev-parse', '--show-prefix');
    const dir = path.join(top, prefix);
    return existsSync(dir) && realpathSync(dir) === realpathSync(root) ? null : dir;
  } catch { return null; }
}

/** The main checkout's top level (the parent of the common git directory), or null. */
function mainTop(root) {
  try {
    const out = gitSync(root, ['rev-parse', '--path-format=absolute', '--git-common-dir'], { stderr: 'ignore', timeoutMs: 10000 }).trim();
    return out ? realOf(path.dirname(out)) : null;
  } catch { return null; }
}

function finish(s, source, where, dir) {
  const versions = shippedVersions(dir);
  const newest = versions.at(-1);
  const notes = [];
  if (newest && semver.valid(s.version) && semver.compare(s.version, newest) > 0) {
    notes.push(`the installed ${s.version} is newer than every release in the shipped surface table (newest ${newest}); its own type definitions are used for the method checks`);
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
  const range = declaredRange(root);
  const fromNodeModules = (base, source, { hoisted = false } = {}) => {
    const dir = path.join(base, 'node_modules', ...PACKAGE.split('/'));
    if (!existsSync(path.join(dir, 'package.json'))) { if (!hoisted) tried.push(`${source}: ${dir}`); return null; }
    tried.push(`${source}: ${dir}`);
    const s = readPackageSurface(parser, dir);
    if (!s) return null;
    // a hoisted install another package of the workspace uses is not the project's when its own range excludes it
    if (hoisted && range && semver.valid(s.version) && !semver.satisfies(s.version, range)) { tried[tried.length - 1] += ` (${s.version}, outside the project's ${range})`; return null; }
    s.privates = { ...s.privates, ...repositoryPrivates(parser, dir) };
    return finish(s, source, dir, snapshotsDir);
  };
  // the project's own directory, then each workspace directory above it up to the work tree's top level
  const walk = (base, source, top, hoistedAs) => fromNodeModules(base, source)
    || workspaceDirs(base, top).reduce((hit, d) => hit || fromNodeModules(d, hoistedAs, { hoisted: true }), null);
  const top = useGit ? workTreeTop(root) : null;
  const wt = walk(realOf(root), 'worktree', top, 'workspace');
  if (wt) return wt;
  if (useGit) {
    const main = mainCheckout(root);
    if (main) {
      const co = walk(realOf(main), 'checkout', mainTop(root), 'checkout');
      if (co) return co;
    } else tried.push('checkout: not a linked worktree');
  }
  const pin = pinnedVersion(root, { top });
  const versions = shippedVersions(snapshotsDir);
  if (!pin) tried.push(`snapshot: no ${PACKAGE} dependency in package.json${top ? ', nor in a workspace directory above it' : ''}`);
  else {
    const v = pin.exact ? (versions.includes(pin.exact) ? pin.exact : null) : semver.maxSatisfying(versions, pin.range);
    tried.push(`snapshot: ${pin.exact || pin.range} (${pin.from}) against shipped ${versions[0] || '-'}..${versions.at(-1) || '-'}`);
    if (v) return finish(readSnapshot(v, snapshotsDir), 'snapshot', path.join(snapshotsDir, `${v}.json`), snapshotsDir);
  }
  throw new SurfaceError(`no Steps surface for ${PACKAGE} resolved (${tried.join('; ')})`);
}
