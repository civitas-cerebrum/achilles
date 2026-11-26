// Family D: data, types and secrets (test-baseline.md §Family D). TB-D1 type escapes are counted per file;
// TB-D2 is the advisory hint of the reader's "is any literal a real credential?" (unwaivable); TB-D3 hard-coded
// origins and retyped routes; TB-D4 generation once at module scope. TB-D5 is judgment.
import { isFn, isMember, isCall, propName, memberChain, unwrap, isStr, strValue, anyNode, propKey } from '../shapes.mjs';
import { resolveRelative } from '../suite.mjs';

const RULEBOOK = 'skills/achilles-orchestrator/references/test-baseline.md';
const SECRET_NAME = /(pass(word)?|passwd|pwd|secret|token|api[_-]?key|private[_-]?key|client[_-]?secret)$/i;
const JWT = /\beyJ[\w-]{8,}\.eyJ[\w-]{8,}\.[\w-]{8,}/;
const ORIGIN = /^https?:\/\/([^/:?#\s'"`]+)/i;
const RESERVED_HOST = /^(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]|::1)$|(^|\.)(example\.(com|org|net)|test|example|invalid|localhost)$/i;
const URL_STEP = /^(navigateTo|waitForUrl|verifyUrlContains|waitForResponse|expectNoRequest|openDeepLink|(api|request)[A-Z]\w*)$/;
const ROUTE_NAME = /route|path|url|page/i;
const DATA_DIR = /(^|\/)(data|fixtures)\//;

export const RULES = [
  { id: 'TB-D1', title: 'type escapes counted', severity: 'advisory', appliesTo: ['spec', 'support'], do: 'Replace non-null assertions, `as any` and @ts-ignore with a checked value (a guard that throws with a reason) or a correct type.' },
  { id: 'TB-D2', title: 'literal that may be a credential', severity: 'advisory', appliesTo: ['spec', 'support'], waivable: false, do: 'Read credentials from env through a fixture or data module; boundary data is fine, a real credential never is.' },
  { id: 'TB-D3', title: 'hard-coded origin or retyped route', severity: 'advisory', appliesTo: ['spec', 'support'], do: 'Address paths through the route constants and take the origin from configuration (baseURL, env with a reserved-domain fallback).' },
  { id: 'TB-D4', title: 'data generated once at module scope', severity: 'blocking', appliesTo: ['spec', 'support'], do: 'Generate the data inside the test or a hook, so every attempt (a retry included) gets its own.' },
];

/** A generation primitive: Date.now(), Math.random(), randomUUID(), crypto.random*, faker.*. */
const GENERATOR_PACKAGES = /^(@faker-js\/faker|faker|chance|nanoid|uuid)$/;

/** Local names a file binds to a generator package (`import { faker as f } from '@faker-js/faker'`). */
function generatorImports(file) {
  if (file.facts.generatorImports) return file.facts.generatorImports;
  const out = new Set();
  for (const st of file.ast.program.body) if (st.type === 'ImportDeclaration' && GENERATOR_PACKAGES.test(st.source.value)) for (const sp of st.specifiers) out.add(sp.local.name);
  return (file.facts.generatorImports = out);
}

function primitive(x, file = null) {
  if (x.type === 'NewExpression') return unwrap(x.callee).type === 'Identifier' && unwrap(x.callee).name === 'Date' && x.arguments.length === 0;
  if (!isCall(x)) return false;
  const ch = memberChain(unwrap(x.callee)) || [];
  const name = ch.join('.');
  if (file && ch.length && generatorImports(file).has(ch[0])) return true;
  return name === 'Date.now' || name === 'Math.random' || /(^|\.)randomUUID$/.test(name) || /^crypto\.random\w*$/.test(name) || /^(randomBytes|randomInt)$/.test(name) || ch[0] === 'faker' || ch[0] === 'chance' || ch[0] === 'nanoid' || name === 'uuid' || name === 'uuidv4' || name === 'v4';
}

export function visitors(project) {
  const generators = new Map(); // abs → Set of top-level function names whose body generates
  const routes = new Map(); // route literal → constant name
  const escapes = new WeakMap(); // file → { nonNull, asAny, tsIgnore, first }

  const isGenerator = (file, name) => {
    if ((generators.get(file.abs) || new Set()).has(name)) return true;
    for (const st of file.ast.program.body) {
      if (st.type !== 'ImportDeclaration') continue;
      const sp = st.specifiers.find((s) => s.local.name === name);
      if (!sp) continue;
      const target = resolveRelative(file.abs, st.source.value);
      const imported = sp.type === 'ImportSpecifier' ? (sp.imported.name || sp.imported.value) : 'default';
      return !!(target && (generators.get(target) || new Set()).has(imported));
    }
    return false;
  };
  const generates = (file, x) => primitive(x, file) || (isCall(x) && unwrap(x.callee).type === 'Identifier' && isGenerator(file, unwrap(x.callee).name));

  const esc = (file) => { let e = escapes.get(file); if (!e) { e = { nonNull: 0, asAny: 0, tsIgnore: 0, first: null }; escapes.set(file, e); } return e; };
  const note = (file, node, k) => { const e = esc(file); e[k]++; if (!e.first || node.loc.start.line < e.first.loc.start.line) e.first = node; };

  function literal(n, ctx) {
    const s = n.type === 'StringLiteral' ? n.value : n.quasis.map((q) => q.value.cooked).join('');
    const parent = ctx.stack[ctx.stack.length - 2];
    if (!parent || parent.type === 'ImportDeclaration' || parent.type === 'ExportNamedDeclaration' || parent.type === 'ExportAllDeclaration' || parent.type === 'TSLiteralType' || parent.type === 'TaggedTemplateExpression') return;
    if (isCall(parent) && parent.arguments[0] === n && (unwrap(parent.callee).type === 'Identifier' && unwrap(parent.callee).name === 'require')) return;
    if (JWT.test(s)) ctx.report('TB-D2', n, { message: 'a JWT-shaped literal (advisory: is it a real token?)' });
    const o = ORIGIN.exec(s);
    if (o && !RESERVED_HOST.test(o[1])) ctx.report('TB-D3', n, { message: `hard-coded origin ${o[0]} (advisory)` });
    // a literal route passed to a URL-taking step where a route constant holds the same path
    if (ctx.file.kind === 'spec' && isCall(parent) && parent.arguments.includes(n) && isMember(unwrap(parent.callee)) && ctx.kind(unwrap(parent.callee).object) === 'steps' && URL_STEP.test(propName(unwrap(parent.callee)) || '') && routes.has(s)) {
      ctx.report('TB-D3', n, { message: `\`'${s}'\` retypes the route ${routes.get(s)} already holds (advisory)` });
    }
  }

  function secretPair(name, value, node, ctx) {
    if (!name || !SECRET_NAME.test(name)) return;
    const v = unwrap(value);
    if (!v) return;
    if (isStr(v) && strValue(v).length >= 4) ctx.report('TB-D2', node, { message: `\`${name}\` holds a literal (advisory: is it a real credential?)` });
    else if (v.type === 'LogicalExpression' && (v.operator === '||' || v.operator === '??') && isStr(unwrap(v.right)) && strValue(unwrap(v.right)).length >= 4) ctx.report('TB-D2', node, { message: `\`${name}\` falls back to a literal when the env value is missing (advisory: is it a real credential?)` });
  }

  function generation(n, ctx) {
    const { file } = ctx;
    const dataModule = file.kind === 'spec' || (file.kind === 'support' && (DATA_DIR.test(file.rel) || file.isFixturesModule));
    if (!dataModule || !generates(file, n)) return;
    const label = n.type === 'NewExpression' ? 'new Date()' : `${(memberChain(unwrap(n.callee)) || ['…']).join('.')}(…)`;
    // the outermost generating call reports once
    if (ctx.stack.slice(0, -1).some((a) => (isCall(a) || a.type === 'NewExpression') && generates(file, a))) return;
    if (ctx.region === 'module') ctx.report('TB-D4', n, { message: `\`${label}\` generates data once at module scope: a retry reuses it` });
    else if (ctx.region === 'describe') ctx.report('TB-D4', n, { severity: 'advisory', message: `\`${label}\` generates data once in a describe callback, outside tests and hooks (advisory: unmeasured)` });
  }

  return {
    projectStart(p) {
      for (const f of p.allFiles) {
        const gen = new Set();
        for (let st of f.ast.program.body) {
          if ((st.type === 'ExportNamedDeclaration' || st.type === 'ExportDefaultDeclaration') && st.declaration) st = st.declaration;
          const fns = st.type === 'FunctionDeclaration' && st.id ? [[st.id.name, st]] : st.type === 'VariableDeclaration' ? st.declarations.filter((d) => d.id.type === 'Identifier' && isFn(unwrap(d.init))).map((d) => [d.id.name, unwrap(d.init)]) : [];
          for (const [name, fn] of fns) if (anyNode(fn.body, (x) => primitive(x, f))) gen.add(name);
          // route constants of support modules: `const ROUTES = { LOGIN: '/login' }`, `export const LOGIN_PATH = '/login'`
          if (f.kind === 'support' && st.type === 'VariableDeclaration') {
            for (const d of st.declarations) {
              if (d.id.type !== 'Identifier' || !ROUTE_NAME.test(d.id.name)) continue;
              const init = unwrap(d.init);
              if (init && isStr(init) && /^\/\S*$/.test(strValue(init))) routes.set(strValue(init), d.id.name);
              if (init && init.type === 'ObjectExpression') for (const pr of init.properties) if (pr.type === 'ObjectProperty' && isStr(unwrap(pr.value)) && /^\/\S*$/.test(strValue(unwrap(pr.value)))) routes.set(strValue(unwrap(pr.value)), `${d.id.name}.${propKey(pr)}`);
            }
          }
        }
        generators.set(f.abs, gen);
      }
    },
    TSNonNullExpression(n, ctx) { note(ctx.file, n, 'nonNull'); },
    TSAsExpression(n, ctx) { if (n.typeAnnotation.type === 'TSAnyKeyword') note(ctx.file, n, 'asAny'); },
    StringLiteral: literal,
    TemplateLiteral: literal,
    VariableDeclarator(n, ctx) { if (n.id.type === 'Identifier') secretPair(n.id.name, n.init, n, ctx); },
    ObjectProperty(n, ctx) { secretPair(propKey(n), n.value, n, ctx); },
    NewExpression(n, ctx) { generation(n, ctx); },
    CallExpression(n, ctx) { generation(n, ctx); },
    fileEnd(file) {
      for (const c of file.ast.comments || []) if (/^[\s*/]*@ts-(ignore|expect-error)\b/.test(c.value)) note(file, c, 'tsIgnore'); // the directive, not prose naming it
      const e = escapes.get(file);
      if (!e || !e.first) return;
      const parts = [e.nonNull && `${e.nonNull} non-null assertion${e.nonNull === 1 ? '' : 's'}`, e.asAny && `${e.asAny} \`as any\``, e.tsIgnore && `${e.tsIgnore} @ts-ignore / @ts-expect-error`].filter(Boolean);
      project.findings.push({ rule: 'TB-D1', severity: 'advisory', file: file.rel, line: e.first.loc.start.line, column: e.first.loc.start.column + 1, region: 'module', message: `${parts.join(', ')} in this file (a code-health count, advisory)`, do: RULES[0].do, why: `${RULEBOOK}#tb-d1`, test: null, stmtLine: e.first.loc.start.line, waived: false });
    },
  };
}
