// Family S: structure (test-baseline.md §Family S).
//
// TB-S1's declarative constant-table form for non-UI tests is not accepted at present. It stays behind one
// setting, the factory rule `specs.constant-table-tests` (`{ "allowed": true }`), which is off by default.
import {
  isFn, isMember, isCall, propName, unwrap, isStr, strValue, anyNode,
  onePass, LOOPS, ITERATION, isAssertion, declarations, referencedNames, statementOf, commentBlockAbove,
} from '../shapes.mjs';
import { DRIVER_KINDS, FRAMEWORK_KINDS, classifyCall, TYPE_KIND } from '../bindings.mjs';
import { idPattern, idsIn } from '../ids.mjs';
import { typeName } from '../ast.mjs';

const RULEBOOK = 'skills/achilles-orchestrator/references/test-baseline.md';
export const CONSTANT_TABLE_SETTING = 'specs.constant-table-tests';
const MAX_LINES = 40;
const MAX_AWAITED = 15;
const UI_NAMES = /^(page|steps|context|locator|request|browser|repo|interactions|driver|frame)$/;
const FRAMEWORK_CTORS = /^(WebElement|ElementInteractions|Steps|ElementRepository)$/;
const INSPECT = /^tests\/e2e\/inspect\//;

export const RULES = [
  { id: 'TB-S1', title: 'generated test', severity: 'blocking', appliesTo: ['spec'], do: 'Write one titled test per scenario by hand, each with its own id; no loop, iteration callback or factory declares tests.' },
  { id: 'TB-S2', title: 'UI-driving helper in a spec file', severity: 'blocking', appliesTo: ['spec'], do: 'Inline a helper only one test uses, move a helper other files need into a support module, and keep classes and page objects out of specs.' },
  { id: 'TB-S2a', title: 'assertion-holding in-spec helper', severity: 'advisory', appliesTo: ['spec'], do: "Keep the scenario's outcome assertion in the test body; the helper may check only its own effect." },
  { id: 'TB-S3', title: 'page-object layer', severity: 'blocking', appliesTo: ['spec', 'support'], do: 'Replace the class with verbs (functions taking steps) in a flow module.' },
  { id: 'TB-S4', title: 'nested test.step', severity: 'blocking', appliesTo: ['spec'], do: 'Keep test.step one level deep; a step never wraps a second scenario.' },
  { id: 'TB-S5', title: 'long test', severity: 'advisory', appliesTo: ['spec'], do: 'Answer TB-S1 and TB-R2: split two scenarios into two tests, or move an unshared chore into a verb.' },
  { id: 'TB-S6', title: 'describes nested more than two deep', severity: 'advisory', appliesTo: ['spec'], do: 'Keep describes at most two deep; contexts (regions, devices, browsers) are config projects.' },
  { id: 'TB-S7', title: 'serial mode without its reason', severity: 'blocking', appliesTo: ['spec'], do: "Add `// serial-deliberate: <reason>` in the comment block directly above test.describe.configure({ mode: 'serial' })." },
  { id: 'TB-S9', title: 'assertion in a hook', severity: 'advisory', appliesTo: ['spec'], do: "Keep the scenario's actions and outcome checks in the test body; a hook may hold a guard that the page is alive." },
  { id: 'TB-S8', title: 'throwaway script committed', severity: 'blocking', appliesTo: ['staged'], waivable: false, do: 'Delete the probe under tests/e2e/inspect/ before the commit; carry its findings in the report.' },
];

/** A module-level `const X = [ …literals… ]` the loop iterates directly. */
function constantTable(file, iterated) {
  const id = unwrap(iterated);
  if (!id || id.type !== 'Identifier') return false;
  const literal = (n) => {
    n = unwrap(n);
    if (!n) return false;
    if (['StringLiteral', 'NumericLiteral', 'BooleanLiteral', 'NullLiteral'].includes(n.type) || (n.type === 'TemplateLiteral' && !n.expressions.length)) return true;
    if (n.type === 'ArrayExpression') return n.elements.every(literal);
    if (n.type === 'ObjectExpression') return n.properties.every((p) => p.type === 'ObjectProperty' && !p.computed && literal(p.value));
    return n.type === 'UnaryExpression' && n.operator === '-' && n.argument.type === 'NumericLiteral';
  };
  for (const st of file.ast.program.body) {
    const d = st.type === 'ExportNamedDeclaration' ? st.declaration : st;
    if (!d || d.type !== 'VariableDeclaration' || d.kind !== 'const') continue;
    for (const x of d.declarations) if (x.id.type === 'Identifier' && x.id.name === id.name) { const a = unwrap(x.init); return !!a && a.type === 'ArrayExpression' && a.elements.length > 0 && a.elements.every(literal); }
  }
  return false;
}

/** A test that drives no UI: no page / context / browser fixture, no driver binding, steps only through api*, request* or sql*. */
function nonUi(fn, kind) {
  const p0 = fn.params[0];
  if (p0 && p0.type === 'ObjectPattern' && p0.properties.some((pr) => pr.type === 'ObjectProperty' && /^(page|context|browser)$/.test(pr.key.name || pr.key.value))) return false;
  return !anyNode(fn.body, (x) => {
    if (!isCall(x) || !isMember(unwrap(x.callee))) return false;
    const k = kind(unwrap(x.callee).object);
    if (DRIVER_KINDS.has(k) && k !== 'request') return true;
    return k === 'steps' && !/^(api|request|sql)[A-Z]/.test(propName(unwrap(x.callee)) || '');
  });
}

export function visitors(project) {
  const ids = idPattern(project.root, project.rules);
  const tablesAllowed = !!(project.rules?.rules?.[CONSTANT_TABLE_SETTING]?.allowed === true);
  const report = (file, rule, node, message, extra = {}) => project.findings.push({
    rule, severity: extra.severity || RULES.find((r) => r.id === rule).severity, file: file.rel, line: node.loc.start.line, column: node.loc.start.column + 1,
    region: extra.region || 'module', message, do: extra.do || RULES.find((r) => r.id === rule).do, why: `${RULEBOOK}#${rule.toLowerCase()}`,
    test: extra.test || null, stmtLine: node.loc.start.line, waived: false, ...(extra.data ? { data: extra.data } : {}), ...(file.followedFrom ? { followedFrom: file.followedFrom } : {}),
  });
  const classes = new WeakMap(); // class node → { drives, field }

  /** TB-S1: where a test declaration sits: a loop, an iteration callback or a factory, up to its describe or module. */
  function generated(n, ctx) {
    const st = ctx.stack;
    for (let i = st.length - 2; i >= 0; i--) {
      const a = st[i], child = st[i + 1];
      if (LOOPS.has(a.type) && child === a.body && !onePass(a)) return { how: 'a loop', iterated: a.type === 'ForOfStatement' ? a.right : null };
      if (isFn(a)) {
        const parent = st[i - 1];
        if (parent && isCall(parent) && parent.arguments.includes(a)) {
          const c = classifyCall(parent, ctx.file.testNames);
          if (c && (c.type === 'describe' || c.type === 'test' || c.type === 'hook' || c.type === 'step')) return null;
          const p = isMember(unwrap(parent.callee)) ? propName(unwrap(parent.callee)) : null;
          if (p && ITERATION.has(p)) return { how: `a .${p}(…) callback`, iterated: unwrap(parent.callee).object };
        }
        const name = a.id ? a.id.name : parent && parent.type === 'VariableDeclarator' && parent.id.type === 'Identifier' ? parent.id.name : null;
        if (!name) return null;
        let calls = 0;
        anyNode(ctx.file.ast.program, (x) => { if (isCall(x) && unwrap(x.callee).type === 'Identifier' && unwrap(x.callee).name === name) calls++; return false; });
        return calls > 1 ? { how: `factory ${name}(), called ${calls} times`, iterated: null } : null;
      }
    }
    return null;
  }

  function onCall(n, ctx) {
    const { file } = ctx;
    const c = isCall(n) ? classifyCall(n, file.testNames) : null;
    if (file.kind === 'spec' && c && c.type === 'test') {
      const g = generated(n, ctx);
      if (g) {
        const table = g.iterated && constantTable(file, g.iterated) && nonUi(c.fn, ctx.kind);
        if (!(table && tablesAllowed)) {
          const t = file.testsByNode.get(n);
          ctx.report('TB-S1', n, { message: `test declared inside ${g.how}${table ? ` (a non-UI constant table is not accepted at present; the \`${CONSTANT_TABLE_SETTING}\` setting is off)` : ''}`, test: t || null });
        }
      }
      const title = c.title && !c.title.dynamic ? c.title.text : null;
      if (title && idsIn(title, ids).length >= 2) ctx.report('TB-S1', n, { severity: 'advisory', message: `the title carries two ids (${idsIn(title, ids).join(', ')}) (advisory: unmeasured)`, do: 'One test, one scenario, one id: split the test.' });
    }
    if (file.kind === 'spec' && c && c.type === 'step') {
      const outer = ctx.stack.slice(0, -1).some((a, i, arr) => isFn(a) && isCall(arr[i - 1]) && (classifyCall(arr[i - 1], file.testNames) || {}).type === 'step');
      if (outer) ctx.report('TB-S4', n, { message: '`test.step` nested inside another `test.step`' });
      else ctx.report('TB-S4', n, { severity: 'advisory', message: '`test.step` (advisory: a step never wraps a second scenario)', do: 'Keep each step one part of the one scenario; a second scenario is a second test.' });
    }
    if (file.kind === 'spec' && c && c.type === 'configure') serialMode(n, ctx);
    if (file.kind === 'spec' && c && c.type === 'describe' && c.mod === 'serial') {
      const st = statementOf(ctx.stack);
      if (!commentBlockAbove(file, (st || n).loc.start.line).some((l) => /serial-deliberate:/.test(l))) ctx.report('TB-S7', n, { severity: 'advisory', message: '`test.describe.serial` without a `// serial-deliberate:` reason (advisory: prefer test.describe.configure)' });
    }
    // TB-S3: classes whose methods drive the UI through framework objects or a driver binding
    const cls = ctx.stack.slice().reverse().find((x) => x.type === 'ClassDeclaration' || x.type === 'ClassExpression');
    if (cls && isMember(unwrap(n.callee))) {
      const info = classes.get(cls);
      const obj = unwrap(unwrap(n.callee).object);
      // `this.<field>.<method>(…)`: memberChain stops at `this`, so read the field off the receiver directly
      const field = isMember(obj) && unwrap(obj.object).type === 'ThisExpression' ? propName(obj) : null;
      const k = ctx.kind(obj);
      if (info && !info.drives && !field && (FRAMEWORK_KINDS.has(k) || DRIVER_KINDS.has(k))) { info.drives = true; ctx.report('TB-S3', cls, { message: `class ${cls.id ? cls.id.name : '(anonymous)'} calls ${k} methods: a page-object layer` }); }
      if (info && !info.field && field && info.injected.has(field)) { info.field = true; ctx.report('TB-S3', cls, { severity: 'advisory', message: `class ${cls.id ? cls.id.name : '(anonymous)'} drives through its injected \`this.${field}\` (advisory: unmeasured)` }); }
    }
  }

  function serialMode(n, ctx) {
    const o = unwrap(n.arguments[0]);
    if (!o || o.type !== 'ObjectExpression') return;
    const mode = o.properties.find((p) => p.type === 'ObjectProperty' && (p.key.name || p.key.value) === 'mode');
    if (!mode || !isStr(unwrap(mode.value)) || strValue(unwrap(mode.value)) !== 'serial') return;
    const st = statementOf(ctx.stack);
    if (!commentBlockAbove(ctx.file, (st || n).loc.start.line).some((l) => /serial-deliberate:\s*\S/.test(l))) ctx.report('TB-S7', n, { message: "`test.describe.configure({ mode: 'serial' })` without `// serial-deliberate: <reason>` directly above it" });
  }

  function onClass(n, ctx) {
    const injected = new Set();
    const ctor = n.body.body.find((m) => m.type === 'ClassMethod' && m.kind === 'constructor');
    const actor = (p) => { const k = TYPE_KIND[typeName(p)]; return (k && (FRAMEWORK_KINDS.has(k) || DRIVER_KINDS.has(k))) || UI_NAMES.test(p.name || ''); };
    if (ctor) {
      const params = new Set();
      for (const p of ctor.params) {
        if (p.type === 'TSParameterProperty' && p.parameter.type === 'Identifier' && actor(p.parameter)) injected.add(p.parameter.name);
        if (p.type === 'Identifier' && actor(p)) params.add(p.name);
      }
      anyNode(ctor.body, (x) => {
        if (x.type === 'AssignmentExpression' && isMember(x.left) && x.left.object.type === 'ThisExpression' && unwrap(x.right).type === 'Identifier' && params.has(unwrap(x.right).name)) injected.add(propName(x.left));
        return false;
      });
    }
    classes.set(n, { drives: false, field: false, injected });
    const sup = n.superClass && unwrap(n.superClass);
    const supName = sup && (sup.type === 'Identifier' ? sup.name : isMember(sup) ? propName(sup) : null);
    if (supName && /(Page|Screen)$/.test(supName)) ctx.report('TB-S3', n, { message: `class ${n.id ? n.id.name : '(anonymous)'} extends ${supName}: a page-object layer` });
    if (ctx.file.kind === 'spec') ctx.report('TB-S2', n, { message: `class ${n.id ? n.id.name : '(anonymous)'} in a spec file` });
  }

  function helpers(file) {
    const d = declarations(file);
    const byName = new Map(d.helpers.map((h) => [h.name, h]));
    const refs = new Map(d.helpers.map((h) => [h.name, [...referencedNames(h.fn.body)].filter((x) => byName.has(x) && x !== h.name)]));
    const closure = (names) => {
      const seen = new Set();
      const stack = [...names];
      while (stack.length) { const x = stack.pop(); if (seen.has(x)) continue; seen.add(x); for (const y of refs.get(x) || []) stack.push(y); }
      return seen;
    };
    const uses = new Map(d.helpers.map((h) => [h.name, new Set()]));
    const testsUnder = (describes) => d.tests.filter((t) => describes.every((x) => t.describes.includes(x)));
    for (const t of d.tests) for (const x of closure([...referencedNames(t.fn)].filter((n) => byName.has(n)))) uses.get(x).add(t.call);
    for (const h of d.hooks) {
      const names = closure([...referencedNames(h.fn)].filter((n) => byName.has(n)));
      for (const t of testsUnder(h.describes)) for (const x of names) uses.get(x).add(t.call);
    }
    return { d, uses };
  }

  return {
    CallExpression: onCall,
    NewExpression(n, ctx) {
      const name = unwrap(n.callee).type === 'Identifier' ? unwrap(n.callee).name : null;
      if (!name || FRAMEWORK_CTORS.test(name)) return;
      const arg = n.arguments.find((a) => { const k = ctx.kind(a); return FRAMEWORK_KINDS.has(k) || DRIVER_KINDS.has(k); });
      if (arg) ctx.report('TB-S3', n, { message: `\`new ${name}(…)\` wraps a ${ctx.kind(arg)} binding: a page-object layer` });
      else if (ctx.file.kind === 'spec' && /(Page|Screen|Flow)$/.test(name)) ctx.report('TB-S2', n, { message: `\`new ${name}()\` in a spec file` });
    },
    ClassDeclaration: onClass,
    ClassExpression: onClass,
    fileEnd(file) {
      if (file.kind !== 'spec') return;
      const { d, uses } = helpers(file);
      for (const h of d.helpers) {
        const body = h.fn.body;
        if (anyNode(body, (x) => isCall(x) && ['test', 'describe'].includes((classifyCall(x, file.testNames) || {}).type))) continue; // a test factory is TB-S1
        const ui = anyNode(body, (x) => x.type === 'AwaitExpression' || (x.type === 'Identifier' && UI_NAMES.test(x.name))) || h.fn.params.some((p) => p.type === 'Identifier' && TYPE_KIND[typeName(p)]);
        if (!ui) continue;
        const n = uses.get(h.name).size;
        if (h.exported) report(file, 'TB-S2', h.node, `exported spec helper ${h.name}(): a helper other files use belongs in a support module`, { region: h.describes.length ? 'describe' : 'module' });
        else if (n < 2) report(file, 'TB-S2', h.node, `helper ${h.name}() drives the UI and is used by ${n} test${n === 1 ? '' : 's'} of this file`, { region: h.describes.length ? 'describe' : 'module' });
        else if (anyNode(body, (x) => isAssertion(x, (e) => (e.type === 'Identifier' && e.name === 'steps' ? 'steps' : null)))) report(file, 'TB-S2a', h.node, `shared in-spec helper ${h.name}() holds assertions (used by ${n} tests): the scenario's outcome check belongs in each test (advisory)`, { region: h.describes.length ? 'describe' : 'module' });
      }
      for (const t of d.tests) {
        const lines = t.endLine - t.line + 1;
        const body = t.fn.body;
        const awaited = body.type === 'BlockStatement' ? body.body.filter((s) => anyNode(s, (x) => x.type === 'AwaitExpression', { intoFunctions: false })).length : (anyNode(body, (x) => x.type === 'AwaitExpression', { intoFunctions: false }) ? 1 : 0);
        if (lines > MAX_LINES || awaited > MAX_AWAITED) {
          const tt = file.testsByNode.get(t.call);
          report(file, 'TB-S5', t.call, `test of ${lines} lines and ${awaited} awaited statements (limits ${MAX_LINES} and ${MAX_AWAITED}) (advisory)`, { region: 'test', test: tt ? { title: tt.title, id: tt.id, line: tt.line } : null });
        }
      }
      for (const h of d.hooks) {
        const scope = file.fnScopes && file.fnScopes.get(h.fn);
        const kind = (e) => (scope ? scope.lookup(e.name) : null) || (e.name === 'steps' ? 'steps' : null);
        if (anyNode(h.fn.body, (x) => isAssertion(x, (e) => (e && e.type === 'Identifier' ? kind(e) : null)))) report(file, 'TB-S9', h.call, `\`${h.mod}\` hook asserts: a hook arranges, the test checks (advisory hint for the reader)`, { region: 'hook' });
      }
      for (const x of d.describes) if (x.depth > 2) report(file, 'TB-S6', x.call, `describe nested ${x.depth} deep (at most two) (advisory)`, { region: 'describe' });
    },
    projectEnd(p) {
      if (!p.change) return;
      for (const [rel, c] of p.change.files) {
        if (c.status === 'D' || !INSPECT.test(rel)) continue;
        p.findings.push({ rule: 'TB-S8', severity: 'blocking', file: rel, line: 1, column: 1, region: 'module', message: `${rel} under tests/e2e/inspect/ is part of the change (unwaivable)`, do: RULES.find((r) => r.id === 'TB-S8').do, why: `${RULEBOOK}#tb-s8`, test: null, waived: false, touched: true });
      }
    },
  };
}
