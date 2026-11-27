// Family A, TB-A6 (test-baseline.md §Family A): every element and page name a test hands to the framework
// names an entry of the page repository the fixture loads.
//
// The repository is found exactly as the fixture finds it: the path argument of `baseFixture(base, <path>, …)`
// or `new ElementRepository(<driver>, <path>)` in a fixtures module, evaluated statically (a literal resolves
// against the project root, the directory Playwright runs from, as the repository package does; `path.resolve`
// and `path.join` over `__dirname` or `import.meta.dirname`, the module's own constants, a JSON module imported
// by default). The file at that path is the built repository (when a build step generates it, that output, not
// its sources), read from the change's content when it has one. Pages that repeat a name (one entry per
// platform) are merged. A spec or support module is checked against the repositories of the fixtures modules
// it imports (transitively), else against every repository of the project. A repository that cannot be read
// is one project finding, and nothing is checked against it.
//
// Pairs checked: the `elementName` / `pageName` arguments of a `steps.*` call (as the installed release names
// them; `steps.on` and `steps.expect` included), the first two arguments of the repository's name methods, and
// every `{ pageName, elementName }` object, when the value is a literal or a constant of the same file.
// Retyping the repository path outside the fixtures module is advisory too.
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { isCall, isMember, isStr, strValue, unwrap, propName, memberChain } from '../ast.mjs';
import { staticValue, Unevaluable } from '../config-scope.mjs';
import { reachable } from '../suite.mjs';

const URL_STEPS = /^(navigateTo|waitForUrl|waitForResponse|verifyUrlContains|expectNoRequest|openDeepLink|api[A-Z]\w*|request[A-Z]\w*)$/;
const REPO_PAIR = new Set(['get', 'getAll', 'getRandom', 'getByText', 'getByAttribute', 'getByIndex', 'getVisible', 'getByRole', 'getElementMeta', 'getSelectorRaw', 'getSelector']);
const REPO_PAGE = new Set(['getPagePlatform']);
const ADVISORY = '(advisory until a live measurement confirms it)';

export const RULES = [
  { id: 'TB-A6', title: 'repository name that does not resolve', severity: 'advisory', appliesTo: ['spec', 'support'], do: 'Use the element and page names of the page repository the fixture loads, or add the entry to the repository first.' },
];

/** Levenshtein distance, capped: the nearest name for a "did you mean". */
function distance(a, b, cap = 3) {
  if (Math.abs(a.length - b.length) > cap) return cap + 1;
  let prev = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    for (let j = 1; j <= b.length; j++) cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1].toLowerCase() === b[j - 1].toLowerCase() ? 0 : 1));
    prev = cur;
  }
  return prev[b.length];
}
const nearest = (name, names) => {
  let best = null;
  for (const n of names) { const d = distance(name, n); if (d <= 2 && (!best || d < best.d)) best = { n, d }; }
  return best ? `; did you mean \`${best.n}\`?` : '';
};

/** Top-level `const` declarations of a module: name → init node. */
function moduleConsts(ast) {
  const m = new Map();
  for (const st of ast.program.body) {
    const decl = st.type === 'ExportNamedDeclaration' ? st.declaration : st;
    if (decl && decl.type === 'VariableDeclaration' && decl.kind === 'const') for (const d of decl.declarations) if (d.id.type === 'Identifier' && d.init) m.set(d.id.name, d.init);
  }
  return m;
}

/** Default imports of a relative JSON module: local name → absolute path. */
function jsonImports(ast, abs) {
  const m = new Map();
  for (const st of ast.program.body) {
    if (st.type !== 'ImportDeclaration' || !st.source.value.startsWith('.') || !/\.json$/.test(st.source.value)) continue;
    for (const s of st.specifiers) if (s.type === 'ImportDefaultSpecifier' || (s.type === 'ImportNamespaceSpecifier')) m.set(s.local.name, path.resolve(path.dirname(abs), st.source.value));
  }
  return m;
}

/** The repository argument of a fixture call in `file`: [{ node, line }]. */
function repositoryArgs(file) {
  const out = [];
  const stack = [file.ast.program];
  while (stack.length) {
    const n = stack.pop();
    if (!n || typeof n.type !== 'string') continue;
    const callee = n.callee ? unwrap(n.callee) : null;
    const name = callee ? (memberChain(callee) || []).at(-1) : null;
    if (isCall(n) && name === 'baseFixture' && n.arguments[1]) out.push({ node: n.arguments[1], line: n.loc.start.line });
    if (n.type === 'NewExpression' && name === 'ElementRepository' && n.arguments[1]) out.push({ node: n.arguments[1], line: n.loc.start.line });
    for (const k of Object.keys(n)) {
      if (k === 'loc' || k.endsWith('Comments')) continue;
      const v = n[k];
      if (Array.isArray(v)) for (const c of v) { if (c && typeof c.type === 'string') stack.push(c); } else if (v && typeof v.type === 'string') stack.push(v);
    }
  }
  return out.sort((a, b) => a.line - b.line);
}

/** Pages and their element names, duplicate page names (one entry per platform) merged. */
function indexOf(data) {
  const pages = new Map();
  for (const p of (data && Array.isArray(data.pages)) ? data.pages : []) {
    if (!p || typeof p.name !== 'string') continue;
    const set = pages.get(p.name) || new Set();
    for (const e of Array.isArray(p.elements) ? p.elements : []) if (e && typeof e.elementName === 'string') set.add(e.elementName);
    pages.set(p.name, set);
  }
  return pages;
}

export function visitors(project) {
  const rel = (abs) => path.relative(project.root, abs).split(path.sep).join('/');
  const textOf = (abs) => (project.textOf ? project.textOf(abs) : existsSync(abs) ? readFileSync(abs, 'utf8') : null);
  /** fixtures module abs → { abs (repository), rel, index } | { problem } */
  const repos = new Map();
  const paths = new Set();
  let all = null;

  /** Evaluates one repository argument of the fixtures module `file`. */
  function resolveArg(file, node) {
    const n = unwrap(node);
    const json = jsonImports(file.ast, file.abs);
    if (n.type === 'Identifier' && json.has(n.name)) return { abs: json.get(n.name) };
    const env = { dir: path.dirname(file.abs), consts: moduleConsts(file.ast), cwd: project.root };
    try {
      const v = staticValue(n, env);
      if (typeof v === 'string') return { abs: path.resolve(project.root, v) };
      return { problem: 'the repository argument is not a path' };
    } catch (e) {
      return { problem: `the repository path cannot be evaluated statically (${e instanceof Unevaluable ? e.message : e.message})` };
    }
  }

  function load(abs) {
    const text = textOf(abs);
    if (typeof text !== 'string') return { problem: `the page repository ${rel(abs)} the fixture loads does not exist (when a build step generates it, run that first)` };
    try { return { abs, rel: rel(abs), index: indexOf(JSON.parse(text)) }; } catch (e) { return { problem: `the page repository ${rel(abs)} is not valid JSON (${e.message})` }; }
  }

  /** The repositories a file is checked against: those of the fixtures modules it reaches, else all. */
  function reposFor(file) {
    if (repos.has(file.abs)) return [repos.get(file.abs)];
    const reached = [...reachable([file.abs], project.edges || new Map())].filter((g) => repos.has(g)).map((g) => repos.get(g));
    return reached.length ? reached : all;
  }

  /** A name argument's value: a literal, a constant of the file, or a member of a constant object of the file. */
  function nameValue(file, node) {
    const n = unwrap(node);
    if (!n) return null;
    if (isStr(n)) return strValue(n);
    file.a6Consts ||= moduleConsts(file.ast);
    if (n.type === 'Identifier') { const init = unwrap(file.a6Consts.get(n.name)); return init && isStr(init) ? strValue(init) : null; }
    if (isMember(n) && !n.computed && unwrap(n.object).type === 'Identifier') {
      const obj = unwrap(file.a6Consts.get(unwrap(n.object).name));
      if (!obj || obj.type !== 'ObjectExpression') return null;
      const key = propName(n);
      const p = obj.properties.find((q) => q.type === 'ObjectProperty' && !q.computed && ((q.key.type === 'Identifier' && q.key.name === key) || (isStr(q.key) && strValue(q.key) === key)));
      const v = p ? unwrap(p.value) : null;
      return v && isStr(v) ? strValue(v) : null;
    }
    return null;
  }

  function check(ctx, node, element, page) {
    if (page === null) return;
    const rs = reposFor(ctx.file);
    if (!rs || !rs.length || rs.some((r) => r.problem)) return;
    const pages = new Map();
    for (const r of rs) for (const [p, els] of r.index) pages.set(p, new Set([...(pages.get(p) || []), ...els]));
    const where = rs.map((r) => r.rel).join(', ');
    if (!pages.has(page)) { ctx.report('TB-A6', node, { message: `page \`${page}\` is not in the page repository (${where})${nearest(page, pages.keys())} ${ADVISORY}` }); return; }
    if (element !== undefined && element !== null && !pages.get(page).has(element)) ctx.report('TB-A6', node, { message: `\`${element}\` is not an element of \`${page}\` in the page repository (${where})${nearest(element, pages.get(page))} ${ADVISORY}` });
  }

  const literal = (n, ctx) => {
    if (!paths.size || ctx.file.isFixturesModule && repos.has(ctx.file.abs)) return;
    const v = n.type === 'StringLiteral' ? n.value : n.expressions.length ? null : n.quasis.map((q) => q.value.cooked).join('');
    if (!v || !/\.json$/i.test(v)) return;
    const hit = [path.resolve(project.root, v), path.resolve(path.dirname(ctx.file.abs), v)].find((a) => paths.has(a));
    if (hit) ctx.report('TB-A6', n, { message: `the page repository path (${rel(hit)}) is typed again outside the fixtures module ${ADVISORY}`, do: 'Declare the repository path once, in the fixtures module; reach the repository through the `repo` fixture or `steps.forPage`.' });
  };

  return {
    projectStart(p) {
      for (const f of p.allFiles) {
        if (f.kind !== 'support' || !f.ast) continue;
        const args = repositoryArgs(f);
        if (!args.length) continue;
        const r = resolveArg(f, args[0].node);
        const loaded = r.problem ? r : load(r.abs);
        repos.set(f.abs, loaded);
        if (loaded.problem) p.projectFindings.push({ rule: 'TB-A6', severity: 'advisory', file: f.rel, message: `${f.rel}: ${loaded.problem}; repository names are not checked against it`, do: 'Pass the repository path to baseFixture as a literal (or path.resolve / path.join over __dirname), and have the repository file in place before linting.', why: 'skills/achilles-orchestrator/references/test-baseline.md#tb-a6' });
        else paths.add(loaded.abs);
      }
      all = [...repos.values()];
    },
    CallExpression(n, ctx) {
      if (!repos.size) return;
      const callee = unwrap(n.callee);
      if (!isMember(callee) || callee.computed) return;
      const m = propName(callee);
      const k = ctx.kind(callee.object);
      if (k === 'steps' && m && !URL_STEPS.test(m)) {
        const params = project.surface.params && project.surface.params[m];
        if (!params) return;
        const ei = params.indexOf('elementName');
        const pi = params.indexOf('pageName');
        if (pi < 0 || !n.arguments[pi]) return;
        const page = nameValue(ctx.file, n.arguments[pi]);
        const element = ei >= 0 ? (n.arguments[ei] ? nameValue(ctx.file, n.arguments[ei]) : null) : undefined;
        if (ei >= 0 && element === null) return;
        check(ctx, n.arguments[ei >= 0 ? ei : pi], element, page);
      } else if (k === 'repo' && (REPO_PAIR.has(m) || REPO_PAGE.has(m))) {
        const pair = REPO_PAIR.has(m);
        const page = n.arguments[pair ? 1 : 0] ? nameValue(ctx.file, n.arguments[pair ? 1 : 0]) : null;
        const element = pair ? (n.arguments[0] ? nameValue(ctx.file, n.arguments[0]) : null) : undefined;
        if (pair && element === null) return;
        check(ctx, n.arguments[0], element, page);
      }
    },
    ObjectExpression(n, ctx) {
      if (!repos.size) return;
      const get = (k) => { const p = n.properties.find((q) => q.type === 'ObjectProperty' && !q.computed && ((q.key.type === 'Identifier' && q.key.name === k) || (isStr(q.key) && strValue(q.key) === k))); return p ? nameValue(ctx.file, p.value) : null; };
      const page = get('pageName');
      const element = get('elementName');
      if (page !== null && element !== null) check(ctx, n, element, page);
    },
    StringLiteral: literal,
    TemplateLiteral: literal,
  };
}
