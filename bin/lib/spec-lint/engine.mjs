// The spec-lint engine: scope, parse, bindings, one walk per file with the rule families' visitors,
// waivers, and the report. Rule families are the modules under rules/ (each exports RULES and visitors);
// a new family is a new module there, picked up without changes here.
//
// Pass 1 walks every in-scope file once to bind kinds (parameters, declarations, later assignments) and to
// collect project facts (extend keys, custom fixture kinds); pass 2 walks the selected files again with the
// same scopes, so a binding assigned later in the file (a `beforeAll` assignment) is known everywhere.
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parserFor, parseCode, isFn, isMember, isCall, propName, unwrap, children, relPosix, isStr, strValue } from './ast.mjs';
import { projectScope, candidateFiles, within, CODE_EXT } from './config-scope.mjs';
import { resolveSurface, SURFACES_DIR } from './surface.mjs';
import { loadEquivalents } from './equivalents.mjs';
import { specifiers, resolveRelative, reachable } from './suite.mjs';
import { markTouched } from './touched.mjs';
import {
  Scope, kindOf, bindParams, bindDeclarator, bindAssignment, bindImports, testBindings, classifyCall, idOfTitle,
  extendFixtures, typedFixtureKinds, typeDeclarations, bindForOf, listElement,
} from './bindings.mjs';

const LISTENERS = new Set(['on', 'once', 'addListener', 'prependListener', 'waitForEvent']);
const ITERATION = new Set(['forEach', 'map', 'flatMap', 'filter', 'some', 'every', 'find', 'findLast', 'reduce']);
import { collectComments, blockAbove, readRegister, HATCH_TOKEN } from './waivers.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const PACKAGE_ROOT = path.resolve(HERE, '..', '..', '..');
export const RULEBOOK = 'skills/achilles-orchestrator/references/test-baseline.md';
const RULES_DIR = path.join(HERE, 'rules');
export const DEFAULT_FILE_BUDGET_MS = 5000;

export class BudgetError extends Error {}

// ── rule families ─────────────────────────────────────────────────────────

const FAMILIES = await Promise.all(readdirSync(RULES_DIR).filter((f) => f.endsWith('.mjs')).sort().map(async (f) => ({ name: f.slice(0, -4), mod: await import(pathToFileURL(path.join(RULES_DIR, f)).href) })));
const META = new Map(FAMILIES.flatMap(({ mod }) => (mod.RULES || []).map((r) => [r.id, r])));
/** Rules no waiver applies to, from each family's metadata (`waivable: false`). */
const UNWAIVABLE = new Set([...META.values()].filter((r) => r.waivable === false).map((r) => r.id));

/** The rules this engine implements: [{ id, title, severity, appliesTo, waivable }]. */
export function implementedRules() {
  return [...META.values()].filter((r) => !r.pending).map(({ id, title, severity, appliesTo, waivable }) => ({ id, title, severity, appliesTo, waivable: waivable === false ? false : typeof waivable === 'function' ? 'partly' : true }));
}

/** Rules with an entry but no detection yet: [{ id, pending }] (decided elsewhere, e.g. at the commit gate). */
export function pendingRules() {
  return [...META.values()].filter((r) => r.pending).map(({ id, pending }) => ({ id, pending }));
}

let knownIdsCache = null;
/** Rule ids the rulebook defines (anchors `tb-<id>`). */
export function knownRuleIds() {
  if (knownIdsCache) return knownIdsCache;
  const file = path.join(PACKAGE_ROOT, RULEBOOK);
  const ids = new Set(META.keys());
  if (existsSync(file)) for (const m of readFileSync(file, 'utf8').matchAll(/^#### (TB-[A-Z]\d+[a-z]?)\b/gm)) ids.add(m[1]);
  return (knownIdsCache = ids);
}

export const docOf = (rule) => `${RULEBOOK}#${rule.toLowerCase()}`;

// ── helpers ───────────────────────────────────────────────────────────────

const MODULE_EXTS = ['.ts', '.mts', '.cts', '.js', '.mjs', '.cjs', '.tsx', '.jsx'];
/** The code file a module path names (with or without its extension), or null. */
function resolveModuleFile(p) {
  if (CODE_EXT.test(p) && existsSync(p)) return p;
  for (const e of MODULE_EXTS) if (existsSync(p + e)) return p + e;
  return null;
}

const STATEMENT = /Statement$|Declaration$/;
const isStatement = (n) => STATEMENT.test(n.type) && n.type !== 'BlockStatement';

function objectFormat(root) {
  try {
    return execFileSync('git', ['-C', root, 'rev-parse', '--show-object-format'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim() === 'sha256' ? 'sha256' : 'sha1';
  } catch { return 'sha1'; }
}
const blobId = (text, algo) => { const b = Buffer.from(text, 'utf8'); return createHash(algo).update(`blob ${b.length}\0`).update(b).digest('hex'); };

function readPackage(root) {
  try { return JSON.parse(readFileSync(path.join(root, 'package.json'), 'utf8')); } catch { return {}; }
}

function factoryRules(root) {
  const p = path.isAbsolute(process.env.FACTORY_RULES || '') ? process.env.FACTORY_RULES : path.join(root, process.env.FACTORY_RULES || 'achilles-factory-rules.json');
  try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return null; }
}

const commentOnlyLines = (lines) => {
  const s = new Set();
  let inBlock = false;
  lines.forEach((l, i) => {
    const t = l.trim();
    if (inBlock) { s.add(i + 1); if (t.includes('*/')) inBlock = false; return; }
    if (t.startsWith('//')) s.add(i + 1);
    else if (t.startsWith('/*')) { s.add(i + 1); if (!t.includes('*/')) inBlock = true; }
  });
  return s;
};

// ── the walk ──────────────────────────────────────────────────────────────

function walkFile(file, project, pass, handlers) {
  const env = { fixtureKinds: project.fixtureKinds };
  const stack = [];
  const overrides = new Map();
  const typeDecls = typeDeclarations(file.ast);
  const deadline = Date.now() + project.budgetMs;
  let steps = 0;
  if (!file.moduleScope) { file.moduleScope = new Scope(null, null); bindImports(file.ast, file.moduleScope); }
  if (!file.fnScopes) file.fnScopes = new WeakMap();
  if (!file.testsByNode) file.testsByNode = new WeakMap();
  file.units = [];
  file.describes = [];

  const baseCtx = { file, project, region: 'module', nested: false, browser: false, scope: file.moduleScope, test: null, fixture: null, inRoute: null, stack };

  const makeApi = (ctx) => {
    ctx.kind = (e) => kindOf(e, ctx.scope, env);
    ctx.report = (rule, node, extra = {}) => {
      if (pass !== 2 || ctx.browser || !file.selected) return;
      const meta = META.get(rule);
      let stmt = null;
      for (let i = stack.length - 1; i >= 0; i--) if (isStatement(stack[i])) { stmt = stack[i]; break; }
      const loc = (node.loc || stmt?.loc || { start: { line: 1, column: 0 } }).start;
      project.findings.push({
        rule, severity: extra.severity || meta.severity, file: file.rel, line: loc.line, column: loc.column + 1,
        region: ctx.region, message: extra.message || meta.title, do: extra.do || meta.do, why: docOf(rule),
        test: (t => (t ? { title: t.title, id: t.id, line: t.line } : null))(extra.test !== undefined ? extra.test : ctx.test),
        stmtLine: stmt ? stmt.loc.start.line : loc.line, waived: false, ...(extra.data ? { data: extra.data } : {}),
        ...(file.followedFrom ? { followedFrom: file.followedFrom } : {}),
      });
    };
    return ctx;
  };

  function enterFunction(fn, ctx) {
    const ov = overrides.get(fn);
    let scope = file.fnScopes.get(fn);
    if (!scope) { scope = new Scope(ctx.scope, fn); file.fnScopes.set(fn, scope); }
    let next;
    if (ov) next = { ...ctx, ...ov, scope };
    else if (ctx.region === 'module' || ctx.region === 'describe') next = { ...ctx, region: 'helper', nested: false, scope, test: null, fixture: null };
    else next = { ...ctx, nested: true, scope };
    if (ov && ov.browserCode) next.browser = true;
    bindParams(fn, scope, env, { fixtureCallback: !!(ov && ov.fixtureCallback), support: file.kind === 'support' });
    if (ov && ov.paramKind && fn.params[0] && fn.params[0].type === 'Identifier') { scope.decls.add(fn.params[0].name); scope.vars.set(fn.params[0].name, ov.paramKind); }
    if (ov && ov.unit) file.units.push({ ...ov.unit, line: fn.loc.start.line, endLine: fn.loc.end.line });
    else if (!ov && (ctx.region === 'module' || ctx.region === 'describe')) file.units.push({ kind: 'helper', label: fn.id ? fn.id.name : 'a helper', line: fn.loc.start.line, endLine: fn.loc.end.line });
    return makeApi(next);
  }

  function onCall(n, ctx) {
    const cls = classifyCall(n, file.testNames);
    if (cls) {
      if (cls.type === 'test') {
        let t = file.testsByNode.get(n);
        if (!t) {
          t = { title: cls.title.text, id: cls.title.dynamic ? null : idOfTitle(cls.title.text), line: n.loc.start.line, endLine: n.loc.end.line, dynamic: cls.title.dynamic };
          file.testsByNode.set(n, t);
          file.tests.push(t);
        }
        overrides.set(cls.fn, { region: 'test', nested: false, test: t, fixtureCallback: true, fixture: null, unit: { kind: 'test', label: `test ${t.id || `"${t.title}"`}`, declLine: n.loc.start.line } });
      } else if (cls.type === 'hook') overrides.set(cls.fn, { region: 'hook', nested: false, test: null, fixtureCallback: true, fixture: null, unit: { kind: 'hook', label: cls.mod, declLine: n.loc.start.line } });
      else if (cls.type === 'describe') {
        overrides.set(cls.fn, { region: 'describe', nested: false, test: null, fixture: null });
        file.describes.push({ title: cls.title ? cls.title.text : null, line: n.loc.start.line, endLine: n.loc.end.line, node: n });
      }
      else if (cls.type === 'step') overrides.set(cls.fn, { region: ctx.region, nested: ctx.nested, test: ctx.test });
      else if (cls.type === 'extend') {
        const { fixtures, open } = extendFixtures(n);
        if (open) project.extendOpen = true;
        for (const [k, v] of typedFixtureKinds(n, typeDecls)) if (!project.fixtureKinds.has(k)) project.fixtureKinds.set(k, v);
        for (const f of fixtures) {
          project.extendKeys.add(f.key);
          if (f.fn) overrides.set(f.fn, { region: file.kind === 'spec' ? 'spec-fixture' : 'fixture', nested: false, test: null, fixtureCallback: true, fixture: f.key });
        }
      }
    }
    const callee = unwrap(n.callee);
    if (isFn(callee)) overrides.set(callee, { region: ctx.region, nested: ctx.nested, test: ctx.test, fixture: ctx.fixture }); // IIFE: same region
    if (isMember(callee) && LISTENERS.has(propName(callee) || '') && /^(page|context|browser)$/.test(ctx.kind(callee.object) || '') && isStr(n.arguments[0]) && /^(page|popup)$/.test(strValue(n.arguments[0]))) {
      const fns = n.arguments.slice(1).flatMap((a) => (isFn(a) ? [a] : a && a.type === 'ObjectExpression' ? a.properties.filter((p) => p.type === 'ObjectProperty' && isFn(p.value)).map((p) => p.value) : []));
      for (const cb of fns) if (!overrides.has(cb)) overrides.set(cb, { region: ctx.region, nested: true, test: ctx.test, fixture: ctx.fixture, paramKind: 'page' });
    }
    if (isMember(callee) && ITERATION.has(propName(callee) || '')) {
      const el = listElement(ctx.kind(callee.object));
      const cb = n.arguments.find(isFn);
      if (el && cb && !overrides.has(cb)) overrides.set(cb, { region: ctx.region, nested: true, test: ctx.test, fixture: ctx.fixture, paramKind: el });
    }
    if (isMember(callee)) {
      const p = propName(callee);
      const ok = ctx.kind(callee.object);
      const driver = ok === 'page' || ok === 'frame' || ok === 'locator' || ok === 'context';
      if ((driver && /^(evaluate|evaluateHandle|\$eval|\$\$eval|addInitScript|exposeFunction|exposeBinding|waitForFunction)$/.test(p || '')) || (ok === 'steps' && /^(evaluateScript|getWindowProperty|waitForFunction)$/.test(p || ''))) {
        for (const a of n.arguments) if (isFn(a)) overrides.set(a, { region: ctx.region, nested: true, test: ctx.test, fixture: ctx.fixture, browserCode: true });
      }
      if (driver && (p === 'route' || p === 'routeFromHAR')) {
        const stmtLine = (() => { for (let i = stack.length - 1; i >= 0; i--) if (isStatement(stack[i])) return stack[i].loc.start.line; return n.loc.start.line; })();
        const cited = file.citations.some((c) => blockAbove(stmtLine, file.commentLines).includes(c.line) && c.row);
        for (const a of n.arguments) if (isFn(a)) overrides.set(a, { region: ctx.region, nested: true, test: ctx.test, fixture: ctx.fixture, inRoute: { cited } });
      }
    }
    if (n.callee.type === 'Identifier' && n.callee.name === 'use' && ctx.fixture && n.arguments[0]) {
      const k = ctx.kind(n.arguments[0]);
      if (k && !project.fixtureKinds.has(ctx.fixture)) project.fixtureKinds.set(ctx.fixture, k);
    }
  }

  function visit(n, ctx) {
    if (!n || typeof n.type !== 'string') return;
    if ((++steps & 1023) === 0 && Date.now() > deadline) throw new BudgetError(`${file.rel}: the time budget of ${project.budgetMs} ms per file ran out`);
    stack.push(n);
    if (n.type === 'VariableDeclarator') bindDeclarator(n, ctx.scope, env);
    else if (n.type === 'AssignmentExpression') bindAssignment(n, ctx.scope, env);
    else if (n.type === 'ForOfStatement') bindForOf(n, ctx.scope, env);
    else if (n.type === 'FunctionDeclaration' && n.id) ctx.scope.decls.add(n.id.name);
    if (isCall(n) || n.type === 'NewExpression') onCall(n, ctx);
    if (pass === 2) for (const h of handlers[n.type] || []) h(n, ctx);
    if (isFn(n)) {
      const inner = enterFunction(n, ctx);
      for (const p of n.params) visit(p, inner);
      visit(n.body, inner);
    } else {
      for (const c of children(n)) visit(c, ctx);
    }
    stack.pop();
  }

  if (Date.now() > deadline) throw new BudgetError(`${file.rel}: the time budget of ${project.budgetMs} ms per file ran out`);
  const ctx = makeApi({ ...baseCtx });
  if (pass === 2) for (const h of handlers.fileStart || []) h(file, ctx);
  visit(file.ast.program, ctx);
  if (pass === 2) for (const h of handlers.fileEnd || []) h(file, ctx);
  if (Date.now() > deadline) throw new BudgetError(`${file.rel}: the time budget of ${project.budgetMs} ms per file ran out`);
}

// ── waivers ───────────────────────────────────────────────────────────────

/** True when a register row's raw methods cover a call of `method` on a binding of `kind`. */
function rowCovers(row, kind, method) {
  return row.methods.some((m) => m.method === method && (!m.recv || m.recv === kind));
}

function applyWaivers(project) {
  const byFile = new Map(project.files.map((f) => [f.rel, f]));
  // caps: at most 2 waivers per test, hook or helper. A waiver in the comment block directly above a
  // test's declaration (a test whose callback is an expression) counts toward that test.
  for (const f of project.allFiles) {
    const owner = (w) => {
      const inner = f.units.filter((u) => w.line >= u.line && w.line <= u.endLine).sort((a, b) => (b.line - a.line) || (a.endLine - b.endLine))[0];
      if (inner) return inner;
      let next = w.line + 1;
      while (f.commentLines.has(next)) next++;
      return f.units.find((u) => u.declLine === next) || null;
    };
    const per = new Map();
    for (const w of f.waivers) {
      if (!w.valid) continue;
      const u = owner(w);
      if (!u) continue;
      const n = (per.get(u) || 0) + 1;
      per.set(u, n);
      if (n > 2) { w.problems.push(`more than 2 waivers in ${u.kind === 'test' ? u.label : u.kind === 'hook' ? `the ${u.label} hook` : `helper ${u.label}`}`); w.valid = false; }
    }
  }
  // gap tokens: the row exists, is open, and its waiver cap holds across every in-scope file of the suite
  const rows = new Map(project.register.rows.map((r) => [r.id, r]));
  const used = new Map();
  for (const f of project.allFiles) {
    for (const w of f.waivers) {
      if (!w.gap) continue;
      const row = rows.get(w.gap);
      if (!row) { w.problems.push(`${w.gap} is not a row of the framework-gap register`); w.valid = false; continue; }
      if (row.fixedIn) { w.problems.push(`${w.gap} is marked ${row.status}: upgrade and remove the waiver`); w.valid = false; continue; }
      const n = (used.get(w.gap) || 0) + 1;
      used.set(w.gap, n);
      if (row.cap !== null && n > row.cap) { w.problems.push(`${w.gap} allows ${row.cap} waiver(s) across the suite; this is number ${n}`); w.valid = false; }
    }
  }
  // match: a valid waiver in the comment block directly above the finding's statement excuses one finding
  const groups = new Map();
  for (const fd of project.findings) {
    const k = `${fd.file}\0${fd.stmtLine}\0${fd.rule}`;
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(fd);
  }
  for (const [k, fds] of groups) {
    const [rel, stmtLine, rule] = k.split('\0');
    const f = byFile.get(rel);
    if (!f) continue;
    const above = new Set(blockAbove(Number(stmtLine), f.commentLines));
    const w = f.waivers.find((x) => above.has(x.line) && x.rule === rule && !x.matched);
    if (!w) continue;
    w.matched = true;
    const meta = META.get(rule);
    const waivable = meta ? (typeof meta.waivable === 'function' ? fds.every((fd) => meta.waivable(fd)) : meta.waivable !== false) : true;
    if (!waivable) { if (!w.problems.some((p) => /unwaivable/.test(p))) w.problems.push(`${rule} is unwaivable here`); w.valid = false; continue; }
    if (fds.length > 1) { w.problems.push(`a waiver excuses one raw call; the statement has ${fds.length} ${rule} findings`); w.valid = false; continue; }
    if (!w.valid) continue;
    const d = fds[0].data || {};
    if (rule === 'TB-A1') {
      const row = w.gap ? rows.get(w.gap) : null;
      if (!d.hatch) { w.problems.push('a TB-A1 waiver covers only the escape-hatch form `interactions.<part>.<method>(new WebElement(<locator>))`'); w.valid = false; continue; }
      if (!row || !row.methods.some((m) => m.hatch)) { w.problems.push(`a TB-A1 waiver names its register row (\`[gap: FG-<n>]\`), and that row's raw methods include \`${HATCH_TOKEN}\``); w.valid = false; continue; }
    }
    if (rule === 'TB-A2') {
      if (d.equivalent) { w.problems.push(`the installed release has steps.${d.equivalent}: use it instead of waiving the raw call`); w.valid = false; continue; }
      if (!w.gap) { w.problems.push('a TB-A2 waiver names the register row that covers the method (`[gap: FG-<n>]`)'); w.valid = false; continue; }
    }
    if (w.gap && rule !== 'TB-A1' && d.method) {
      const row = rows.get(w.gap);
      if (row && !rowCovers(row, d.kind, d.method)) { w.problems.push(`${w.gap} does not cover \`${d.kind}.${d.method}\``); w.valid = false; continue; }
    }
    if (!w.valid) continue;
    fds[0].waived = true;
    fds[0].waiver = { reason: w.reason, ...(w.gap ? { gap: w.gap } : {}), line: w.line };
  }
  // a waiver of an implemented rule that excuses nothing
  for (const f of project.files) {
    for (const w of f.waivers) if (w.valid && !w.matched && META.has(w.rule)) { w.problems.push(`excuses no ${w.rule} finding: remove it`); w.valid = false; }
  }
}

// ── the project ───────────────────────────────────────────────────────────

/**
 * Lints the project at `root`. Options: paths (files to report on; default every in-scope file, or the
 * changed files when `change` is given), snapshotsDir, useGit (surface chain step 2 and blob format),
 * budgetMs (per file), contents (rel → text read instead of the file on disk; a path that does not exist
 * is linted as if it did), change (touched.mjs: rel → { status, lines }, plus staged contents; every finding
 * then carries `touched`, and only touched blocking findings count), suite (ids across files, and the
 * support modules the selected specs import are linted too, with `followedFrom`).
 * Throws SurfaceError when no Steps surface resolves and BudgetError when a file runs out of time.
 */
export function lintProject({ root, paths = null, snapshotsDir = SURFACES_DIR, useGit = true, budgetMs = DEFAULT_FILE_BUDGET_MS, contents = null, change = null, suite = false } = {}) {
  const t0 = Date.now();
  root = path.resolve(root);
  const parser = parserFor(root);
  const surface = resolveSurface(root, parser, { snapshotsDir, useGit });
  const scope = projectScope(root, parser);
  const project = {
    root, parser, surface, equivalents: loadEquivalents(), budgetMs,
    rules: factoryRules(root), register: readRegister(root), knownIds: knownRuleIds(),
    findings: [], projectFindings: [], files: [],
    fixtureKinds: new Map(), extendKeys: new Set(), extendOpen: false,
    pkg: readPackage(root), change, suite, k6Files: [],
  };
  const override = new Map([...(change ? change.contents : []), ...(contents ? (contents instanceof Map ? contents : Object.entries(contents)) : [])].map(([k, v]) => [path.resolve(root, k), v]));
  for (const p of scope.problems) project.projectFindings.push({ rule: 'scope', severity: 'advisory', file: p.file, message: `${p.file}: ${p.message}; the default test glob and tests/** apply`, do: 'Keep testDir, testMatch, testIgnore and projects in the Playwright config as literal values (or path.join / path.resolve over __dirname) so the lint can see which files run.', why: `${RULEBOOK}#scope` });
  for (const n of surface.notes) project.projectFindings.push({ rule: 'surface', severity: 'advisory', message: n, do: 'Nothing to change in the suite: the checks read the installed type definitions.', why: docOf('TB-A10') });

  // classify and parse
  const algo = useGit ? objectFormat(root) : 'sha1';
  const records = [];
  // A config-named globalSetup / globalTeardown module is support wherever it sits (also outside the spec roots).
  const globals = scope.configs.flatMap((c) => c.globals).map(resolveModuleFile).filter((g) => g && within(root, g));
  const virtual = [...override.keys()].filter((a) => CODE_EXT.test(a) && within(root, a) && !/\.d\.[cm]?ts$/.test(a));
  for (const abs of [...new Set([...candidateFiles(root, scope.specRoots), ...globals, ...virtual])].sort()) {
    const stat = scope.staticKind(abs);
    if (stat === 'excluded') continue;
    const rel = relPosix(root, abs);
    const text = override.has(abs) ? override.get(abs) : readFileSync(abs, 'utf8');
    const rec = { abs, rel, text, stat, kind: null, ast: null, parseError: null };
    if (stat !== 'bundle') {
      try { rec.ast = parseCode(parser, text, abs); } catch (e) { rec.parseError = e; }
    }
    if (rec.ast) rec.testNames = testBindings(rec.ast);
    records.push(rec);
  }
  const byAbs = new Map(records.map((r) => [r.abs, r]));
  const declaresTests = (r) => {
    if (!r.ast) return false;
    const stack = [r.ast.program];
    while (stack.length) {
      const n = stack.pop();
      if (isCall(n)) { const c = classifyCall(n, r.testNames); if (c && (c.type === 'test' || c.type === 'describe')) return true; }
      for (const c of children(n)) stack.push(c);
    }
    return false;
  };
  for (const r of records) {
    if (r.stat === 'k6' || r.stat === 'bundle') r.kind = r.stat;
    else if (r.stat === 'run') r.kind = 'spec';
    else if (r.stat === 'setup' || r.stat === 'support-dir') r.kind = 'support';
    else if (r.stat === 'candidate' && declaresTests(r)) r.kind = 'spec';
  }
  const edges = new Map();
  for (const r of records) if (r.ast) edges.set(r.abs, specifiers(r.ast).map((s) => resolveRelative(r.abs, s)).filter((x) => x && byAbs.has(x)));
  const fromSpecs = reachable(records.filter((r) => r.kind === 'spec').map((r) => r.abs), edges);
  for (const r of records) if (!r.kind && r.stat === 'candidate' && (fromSpecs.has(r.abs) || r.parseError)) r.kind = 'support';
  const inScope = records.filter((r) => r.kind);
  const unlinted = records.filter((r) => !r.kind && r.stat === 'candidate');
  if (unlinted.length) {
    const names = unlinted.slice(0, 5).map((r) => r.rel).join(', ');
    project.projectFindings.push({ rule: 'scope', severity: 'advisory', message: `${unlinted.length} code file${unlinted.length === 1 ? '' : 's'} under the spec roots ${unlinted.length === 1 ? 'is' : 'are'} neither a spec nor a support module and ${unlinted.length === 1 ? 'is' : 'are'} not linted: ${names}${unlinted.length > 5 ? ', …' : ''}`, do: 'Import the module from a spec or move it under a support directory (fixtures/, flows/, data/, support/, utils/, lib/, helpers/) so it is linted, or delete it when nothing uses it.', why: `${RULEBOOK}#scope` });
  }

  let selected = null;
  if (paths) selected = new Set(paths.map((p) => path.resolve(root, p)));
  else if (change) selected = new Set([...change.files].filter(([, c]) => c.status !== 'D').map(([rel]) => path.resolve(root, rel)));
  if (selected && suite) {
    // follow the imports of the selected specs: the support modules they reach are linted too
    for (const r of inScope) {
      if (r.kind !== 'spec' || !selected.has(r.abs)) continue;
      for (const g of reachable([r.abs], edges)) {
        const t = byAbs.get(g);
        if (t && t.kind === 'support' && !selected.has(g)) { selected.add(g); t.followedFrom = r.rel; }
      }
    }
  }
  for (const r of inScope) {
    r.selected = !selected || selected.has(r.abs);
    r.lines = r.text.split(/\r?\n/);
    r.tests = [];
    r.blob = blobId(r.text, algo);
    r.facts = {};
    r.commentLines = commentOnlyLines(r.lines);
    const cc = r.ast ? collectComments(r.ast, r.lines, project.knownIds, UNWAIVABLE) : { waivers: [], citations: [] };
    r.waivers = cc.waivers;
    r.citations = cc.citations;
    r.isFixturesModule = r.kind === 'support' && !!r.ast && (/(^|\/)fixtures\//.test(r.rel) || /\bbaseFixture\s*\(|\.extend\s*[<(]/.test(r.text));
  }
  project.files = inScope.filter((r) => r.selected);
  project.byRel = new Map(inScope.map((r) => [r.rel, r]));
  project.k6Files = inScope.filter((r) => r.kind === 'k6' && r.ast && r.selected);

  // handlers of every family
  const handlers = {};
  for (const { mod } of FAMILIES) {
    if (typeof mod.visitors !== 'function') continue;
    for (const [type, fn] of Object.entries(mod.visitors(project))) (handlers[type] ||= []).push(fn);
  }

  const lintable = inScope.filter((r) => (r.kind === 'spec' || r.kind === 'support') && r.ast);
  project.allFiles = lintable;
  const order = [...lintable.filter((r) => r.kind === 'support'), ...lintable.filter((r) => r.kind === 'spec')];
  for (const r of order) walkFile(r, project, 1, handlers);
  for (const h of handlers.projectStart || []) h(project);
  for (const r of order) if (r.selected) walkFile(r, project, 2, handlers);
  for (const r of project.files) if (r.parseError && (r.kind === 'spec' || r.kind === 'support')) for (const h of handlers.parseError || []) h(r, r.parseError);

  applyWaivers(project);
  for (const h of handlers.projectEnd || []) h(project);

  if (change) {
    markTouched(project, change);
    // a version gap blocks in a touched test (upgrade first); legacy sites stay advisory
    for (const f of project.findings) if (f.rule === 'TB-A13' && f.touched) f.severity = 'blocking';
  }
  project.findings.sort((a, b) => (a.file < b.file ? -1 : a.file > b.file ? 1 : a.line - b.line || a.column - b.column || (a.rule < b.rule ? -1 : 1)));
  const charged = (f) => f.severity === 'blocking' && !f.waived && f.touched !== false;
  const blocking = project.findings.filter(charged).length;
  const legacy = project.findings.filter((f) => f.severity === 'blocking' && !f.waived && f.touched === false).length;
  const advisory = project.findings.filter((f) => f.severity === 'advisory' && !f.waived).length + project.projectFindings.length;
  return {
    tool: 'achilles-spec-lint',
    version: JSON.parse(readFileSync(path.join(PACKAGE_ROOT, 'package.json'), 'utf8')).version,
    ok: blocking === 0,
    stepsSurface: { package: surface.package, version: surface.version, source: surface.source },
    ...(change ? { change: { from: change.from || 'the given change', files: [...change.files.keys()].sort() } } : {}),
    files: project.files.map((r) => ({ path: r.rel, kind: r.kind, blob: r.blob, parsed: !r.parseError, tests: r.tests.map((t) => ({ title: t.title, id: t.id, line: t.line, endLine: t.endLine })), ...(r.followedFrom ? { followedFrom: r.followedFrom } : {}) })),
    findings: project.findings.map(({ stmtLine, ...f }) => f),
    project: project.projectFindings,
    summary: {
      files: project.files.length,
      specs: project.files.filter((r) => r.kind === 'spec').length,
      support: project.files.filter((r) => r.kind === 'support').length,
      blocking, advisory,
      waived: project.findings.filter((f) => f.waived).length,
      ...(change ? { legacy } : {}),
    },
    ...(suite && project.suiteIds ? { ids: project.suiteIds } : {}),
    timing: { ms: Date.now() - t0 },
  };
}

/**
 * Write mode (`--stdin`): lints `file` as `after` and as `before`, and reports only the findings new in
 * `after`. A finding is the same when its rule, its test title and the text of its line match (lines may
 * shift). `before` null or missing: every finding is new.
 */
export function lintWrite({ root, file, before, after, ...opts }) {
  const t0 = Date.now();
  root = path.resolve(root);
  const rel = relPosix(root, path.resolve(root, file));
  const run = (text) => lintProject({ ...opts, root, paths: [rel], contents: { [rel]: text } });
  const now = run(after);
  const old = typeof before === 'string' ? run(before) : null;
  const key = (f, text) => `${f.rule}\0${f.test ? f.test.title : ''}\0${(text.split(/\r?\n/)[f.line - 1] || '').trim()}`;
  const left = new Map();
  for (const f of old ? old.findings : []) { const k = key(f, before); left.set(k, (left.get(k) || 0) + 1); }
  const fresh = now.findings.filter((f) => {
    if (f.file !== rel) return false;
    const k = key(f, after);
    const n = left.get(k) || 0;
    if (n > 0) { left.set(k, n - 1); return false; }
    return true;
  });
  const blocking = fresh.filter((f) => f.severity === 'blocking' && !f.waived).length;
  return {
    ...now,
    ok: blocking === 0,
    change: { from: 'the write (before and after)', files: [rel] },
    findings: fresh,
    summary: { ...now.summary, blocking, advisory: fresh.filter((f) => f.severity === 'advisory' && !f.waived).length + now.project.length, waived: fresh.filter((f) => f.waived).length },
    timing: { ms: Date.now() - t0 },
  };
}

