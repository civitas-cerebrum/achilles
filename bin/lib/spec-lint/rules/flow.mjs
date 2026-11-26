// Family F: flow control (test-baseline.md §Family F). Flow rules apply to spec files: test and hook bodies,
// and module- or describe-level helpers (a shared in-spec helper is held to them as if it were the test
// body, TB-S2). Verbs, fixtures and setup files may branch, retry and poll. TB-F5 also reads support
// modules (advisory there).
import {
  isFn, isMember, isCall, propName, memberChain, unwrap, isStr, strValue, anyNode,
  onePass, inLoop, isDriving, drives, drivesUi, awaitsDriving, statementOf, enclosingDeclarations, tagsOf, testModifier, LOOPS, ITERATION,
} from '../shapes.mjs';
import { DRIVER_KINDS } from '../bindings.mjs';
import { resolveRelative } from '../suite.mjs';
import { pointersAbove, resolveRef, refNames, SENTINEL_TITLE } from '../defects.mjs';

const RULEBOOK = 'skills/achilles-orchestrator/references/test-baseline.md';
const TIMERS = /^(?:node:)?timers\/promises$/;
const SLEEP_NAME = /^(sleep|delay|wait|pause)$/;

export const RULES = [
  { id: 'TB-F1', title: 'branch that decides what a test does or checks', severity: 'blocking', appliesTo: ['spec'], do: 'Remove the branch: a fixture resolves the state, a verb in a flow module owns the optional step, or the test skips by name with test.skip(<condition>, \'<reason>\').' },
  { id: 'TB-F2', title: 'loop in a test body', severity: 'advisory', appliesTo: ['spec'], do: 'Repeat only what the scenario defines, with the count in a named constant that states its reason (steps.repeat preferred).' },
  { id: 'TB-F3', title: 'swallowed failure', severity: 'blocking', appliesTo: ['spec'], do: 'Let the failure fail the test: remove the catch, the rejection handler or allSettled; record-and-assert when a collection of failures is the oracle.' },
  { id: 'TB-F4', title: 'retry in a spec', severity: 'advisory', appliesTo: ['spec'], do: 'Move the bounded retry into a verb that ends on a hard check; expect.poll and toPass are allowed in the test.' },
  { id: 'TB-F5', title: 'fixed wait', severity: 'blocking', appliesTo: ['spec', 'support'], waivable: (f) => !(f.data && f.data.unwaivable), do: "Wait for a state of the application: steps.waitForState(…), steps.waitForUrl(…), expect.poll or a verb's own wait." },
  { id: 'TB-F6', title: 'focused test, silent skip or expected failure outside the sentinel forms', severity: 'blocking', appliesTo: ['spec'], waivable: (f) => !(f.data && f.data.only), do: 'Remove .only; give every unconditional skip a reason; write test.fail only in sentinel form (a) or (b) with its `// defect:` pointer.' },
  { id: 'TB-F7', title: 'optional action in a spec', severity: 'advisory', appliesTo: ['spec'], do: 'Move the optional action into a verb or fixture that checks its own effect, or follow it with a check that fails when it did not happen.' },
];

const flowRegion = (ctx) => ctx.file.kind === 'spec' && !ctx.browser && !ctx.nested && (ctx.region === 'test' || ctx.region === 'hook' || ctx.region === 'helper');
const parentOf = (ctx) => ctx.stack[ctx.stack.length - 2];

/** The consequent of an `if` (or a case) holds a `test.skip(…)` / `test.fixme(…)` skip guard. */
const skipGuard = (b, names) => anyNode(b, (x) => isCall(x) && (testModifier(x, names) || []).some((m) => m === 'skip' || m === 'fixme'));

const CONSTANT = new Set(['NullLiteral', 'BooleanLiteral', 'StringLiteral', 'NumericLiteral', 'ArrayExpression', 'ObjectExpression', 'TemplateLiteral', 'RegExpLiteral']);
/** A rejection handler that turns the failure into a value: a constant body, or a block that neither rethrows nor asserts. */
function swallows(fn) {
  const b = unwrap(fn.body);
  if (b.type !== 'BlockStatement') return CONSTANT.has(b.type) || (b.type === 'Identifier' && (b.name === 'undefined' || fn.params.some((q) => q.type === 'Identifier' && q.name === b.name))) || (b.type === 'UnaryExpression' && b.operator === 'void');
  return !anyNode(b, (x) => x.type === 'ThrowStatement' || (isCall(x) && ((memberChain(unwrap(x.callee)) || [])[0] === 'expect' || (unwrap(x.callee).type === 'Identifier' && /^(fail|expect|assert)/.test(unwrap(x.callee).name)))));
}

/** Top-level functions of a file whose body builds a timer sleep (setTimeout, timers/promises). */
function timerHelpers(file) {
  const out = new Set();
  const timerImports = new Set();
  for (const st of file.ast.program.body) if (st.type === 'ImportDeclaration' && TIMERS.test(st.source.value)) for (const sp of st.specifiers) timerImports.add(sp.local.name);
  // aliases of setTimeout (`const st = setTimeout`) and promisified timers (`promisify(setTimeout)`)
  const aliases = new Set(['setTimeout']);
  const body = file.ast.program.body.map((st) => ((st.type === 'ExportNamedDeclaration' || st.type === 'ExportDefaultDeclaration') && st.declaration ? st.declaration : st));
  for (const st of body) if (st.type === 'VariableDeclaration') for (const d of st.declarations) if (d.id.type === 'Identifier' && unwrap(d.init) && unwrap(d.init).type === 'Identifier' && unwrap(d.init).name === 'setTimeout') aliases.add(d.id.name);
  const isTimerFn = (e) => { const u = unwrap(e); return !!u && ((u.type === 'Identifier' && aliases.has(u.name)) || (isMember(u) && propName(u) === 'setTimeout')); };
  const promisified = (init) => { const c = unwrap(init); return isCall(c) && /(^|\.)promisify$/.test((memberChain(unwrap(c.callee)) || []).join('.')) && isTimerFn(c.arguments[0]); };
  for (const st of body) if (st.type === 'VariableDeclaration') for (const d of st.declarations) if (d.id.type === 'Identifier' && promisified(d.init)) out.add(d.id.name);
  // a promise-sleep: `new Promise((r) => setTimeout(r, n))`; a bare setTimeout (an abort timer) is not one
  const sleeps = (x) => (x.type === 'NewExpression' && unwrap(x.callee).type === 'Identifier' && unwrap(x.callee).name === 'Promise' && isFn(unwrap(x.arguments[0])) && anyNode(unwrap(x.arguments[0]).body, (y) => isCall(y) && isTimerFn(y.callee)))
    || (isCall(x) && unwrap(x.callee).type === 'Identifier' && (timerImports.has(unwrap(x.callee).name) || out.has(unwrap(x.callee).name)));
  const isTimer = (fn) => anyNode(fn.body, sleeps);
  for (const st of body) {
    if (st.type === 'FunctionDeclaration' && st.id && isTimer(st)) out.add(st.id.name);
    if (st.type === 'VariableDeclaration') for (const d of st.declarations) if (d.id.type === 'Identifier' && isFn(unwrap(d.init)) && isTimer(unwrap(d.init))) out.add(d.id.name);
  }
  // re-exports: `export { sleep as nap } from './a'`, `export * from './b'`
  const reexports = [];
  for (const st of file.ast.program.body) {
    if (st.type === 'ExportAllDeclaration') reexports.push({ source: st.source.value, all: true });
    if (st.type === 'ExportNamedDeclaration' && st.source) for (const sp of st.specifiers) if (sp.local) reexports.push({ source: st.source.value, local: sp.local.name || sp.local.value, exported: sp.exported.name || sp.exported.value });
    if (st.type === 'ExportNamedDeclaration' && !st.source && !st.declaration) for (const sp of st.specifiers) if (out.has(sp.local.name)) out.add(sp.exported.name || sp.exported.value);
  }
  return { helpers: out, timerImports, aliases, reexports };
}

/** Local name → { source, imported } of a file's imports. */
function importsOf(file) {
  if (file.facts.imports) return file.facts.imports;
  const out = new Map();
  for (const st of file.ast.program.body) {
    if (st.type !== 'ImportDeclaration') continue;
    for (const sp of st.specifiers) out.set(sp.local.name, { source: st.source.value, imported: sp.type === 'ImportSpecifier' ? (sp.imported.name || sp.imported.value) : sp.type === 'ImportDefaultSpecifier' ? 'default' : '*' });
  }
  return (file.facts.imports = out);
}

const nullish = (a) => { const u = unwrap(a); return !u || u.type === 'NullLiteral' || (u.type === 'Identifier' && u.name === 'undefined') || (u.type === 'UnaryExpression' && u.operator === 'void'); };

/** The in-file function a name is bound to at module level, or null. */
function localFunction(file, name) {
  for (let st of file.ast.program.body) {
    if ((st.type === 'ExportNamedDeclaration' || st.type === 'ExportDefaultDeclaration') && st.declaration) st = st.declaration;
    if (st.type === 'FunctionDeclaration' && st.id && st.id.name === name) return st;
    if (st.type === 'VariableDeclaration') for (const d of st.declarations) if (d.id.type === 'Identifier' && d.id.name === name && isFn(unwrap(d.init))) return unwrap(d.init);
  }
  return null;
}

/** A `.catch` handler swallows: a function that turns the failure into a value, or any handler the lint cannot read. */
function handlerSwallows(file, a) {
  const u = unwrap(a);
  if (isFn(u)) return swallows(u);
  if (u && u.type === 'Identifier') { const f = localFunction(file, u.name); return f ? swallows(f) : true; }
  return true;
}

export function visitors(project) {
  const timers = new Map(); // abs → { helpers, timerImports }

  /** `name` called in `file` resolves to a timer sleep helper (local, imported from a project module, or timers/promises). */
  function sleepHelper(file, name) {
    const own = timers.get(file.abs);
    if (own && (own.helpers.has(name) || own.timerImports.has(name))) return true;
    const imp = importsOf(file).get(name);
    if (!imp) return false;
    if (TIMERS.test(imp.source)) return true;
    const target = resolveRelative(file.abs, imp.source);
    // an awaited sleep-named callee from a module the lint cannot follow (a package, a path alias)
    if (!target || !timers.has(target)) return (SLEEP_NAME.test(name) || SLEEP_NAME.test(imp.imported)) && (!imp.source.startsWith('.') || !target);
    return exportsSleep(target, imp.imported, 0);
  }

  /** Module `abs` exports `name` as a sleep helper, following `export { … } from` and `export *`. */
  function exportsSleep(abs, name, depth) {
    const t = timers.get(abs);
    if (!t || depth > 8) return false;
    if (t.helpers.has(name)) return true;
    for (const r of t.reexports) {
      const target = resolveRelative(abs, r.source);
      if (!target) continue;
      if (r.all ? exportsSleep(target, name, depth + 1) : r.exported === name && exportsSleep(target, r.local, depth + 1)) return true;
    }
    return false;
  }

  const f1Wrappers = (file) => (file.facts.f1Wrappers ||= []);

  function f1(n, ctx, what) {
    if (!flowRegion(ctx) || inLoop(ctx.stack, ctx.file.testNames)) return;
    ctx.report('TB-F1', n, { message: what });
  }

  function onIf(n, ctx) {
    if (!flowRegion(ctx)) return;
    const parent = parentOf(ctx);
    if (parent && parent.type === 'IfStatement' && parent.alternate === n) return; // an else-if is part of its chain
    if (inLoop(ctx.stack, ctx.file.testNames)) return;
    if (skipGuard(n.consequent, ctx.file.testNames)) return;
    const branches = [];
    for (let x = n; x; x = x.alternate && x.alternate.type === 'IfStatement' ? x.alternate : null) { branches.push(x.consequent); if (x.alternate && x.alternate.type !== 'IfStatement') branches.push(x.alternate); }
    if (branches.some((b) => branchCounts(b, ctx))) f1(n, ctx, `\`if\` whose branch performs an action or an assertion (${ctx.region === 'hook' ? 'hook' : ctx.region === 'helper' ? 'in-spec helper' : 'test'} body)`);
  }

  /**
   * A branch counts when it acts or asserts. In a hook only an assertion or a UI-driving call counts: conditional
   * teardown through verbs, API calls or cleanup is bookkeeping.
   */
  function branchCounts(b, ctx) {
    return ctx.region === 'hook' ? anyNode(b, (x) => drivesUi(x, ctx.kind)) : drives(b, ctx.kind);
  }

  function wrapper(node, ctx, kind) {
    if (!flowRegion(ctx)) return;
    f1Wrappers(ctx.file).push({ node, kind, region: ctx.region, test: ctx.test });
  }

  function onCall(n, ctx) {
    const { file } = ctx;
    const callee = unwrap(n.callee);
    const p = isMember(callee) ? propName(callee) : null;
    const names = file.testNames;
    const spec = file.kind === 'spec';

    // F1 evasion: an IIFE in a test or hook body is analysed as the body (the engine inlines it)
    if (isFn(callee) && spec) wrapper(n, ctx, 'an IIFE');

    // F3: swallowed failures directly in a test body (or a shared in-spec helper)
    const f3Region = spec && !ctx.browser && !ctx.nested && (ctx.region === 'test' || ctx.region === 'helper');
    if (f3Region && p === 'catch' && n.arguments.length === 1 && handlerSwallows(file, n.arguments[0])) ctx.report('TB-F3', n, { message: '`.catch(…)` turns the failure into a value' });
    if (f3Region && p === 'then' && n.arguments.length >= 2 && !nullish(n.arguments[1])) ctx.report('TB-F3', n, { message: '`.then(…, onRejected)` handles the failure in the test body' });
    const pc = (memberChain(callee) || []).join('.');
    if (f3Region && (pc === 'Promise.allSettled' || pc === 'Promise.any')) ctx.report('TB-F3', n, { message: `\`${pc}(…)\` ${pc === 'Promise.any' ? 'passes when any one promise succeeds' : 'settles failures'} instead of failing the test` });

    // F2 / F4: iteration callbacks, steps.repeat, steps.retryUntil
    if (spec && !ctx.browser && !ctx.nested && (ctx.region === 'test' || ctx.region === 'helper') && p && ITERATION.has(p)) {
      const cb = n.arguments.map(unwrap).find(isFn);
      if (cb && (anyNode(cb.body, (x) => x.type === 'AwaitExpression') || drives(cb.body, ctx.kind))) ctx.report('TB-F2', n, { message: `\`.${p}(…)\` callback that drives the test` });
    }
    if (spec && isMember(callee) && ctx.kind(callee.object) === 'steps') {
      if (p === 'repeat' && (ctx.region === 'test' || ctx.region === 'helper')) ctx.report('TB-F2', n, { message: 'steps.repeat (the preferred form): the count is a named constant with its reason' });
      if (p === 'retryUntil') ctx.report('TB-F4', n, { message: 'steps.retryUntil in a spec' });
    }

    // F5: fixed waits
    if (!ctx.inRoute) {
      const awaited = parentOf(ctx) && parentOf(ctx).type === 'AwaitExpression';
      const sev = spec ? 'blocking' : 'advisory';
      const recvKind = isMember(callee) ? ctx.kind(callee.object) : null;
      const recvName = isMember(callee) && unwrap(callee.object).type === 'Identifier' ? unwrap(callee.object).name : null;
      if (p === 'waitForTimeout') ctx.report('TB-F5', n, { severity: sev, message: `\`${recvName || recvKind || '…'}.waitForTimeout(…)\` waits a fixed time${spec ? ' (unwaivable in a spec)' : ' (advisory in support)'}`, data: { unwaivable: spec } });
      else if (p === 'pause' && (DRIVER_KINDS.has(recvKind) || recvName === 'driver' || recvName === 'browser')) ctx.report('TB-F5', n, { severity: sev, message: `\`${recvName || recvKind}.pause(…)\`${spec ? ' (unwaivable in a spec)' : ' (advisory in support)'}`, data: { unwaivable: spec } });
      else if (awaited && callee.type === 'Identifier' && sleepHelper(file, callee.name)) {
        ctx.report('TB-F5', n, { severity: sev, message: `awaited \`${callee.name}(…)\` is a fixed wait${spec ? '' : ' (advisory in support)'}` });
      } else if (awaited && isMember(callee) && p === 'setTimeout' && unwrap(callee.object).type === 'Identifier' && TIMERS.test((importsOf(file).get(unwrap(callee.object).name) || {}).source || '')) {
        ctx.report('TB-F5', n, { severity: sev, message: `awaited \`${unwrap(callee.object).name}.setTimeout(…)\` is a fixed wait${spec ? '' : ' (advisory in support)'}` });
      } else if (spec && p === 'pace' && recvKind === 'steps') ctx.report('TB-F5', n, { severity: 'advisory', message: 'steps.pace slows every step by a fixed time (advisory)' });
    }

    // F6: focus, silent skips, expected failures
    if (spec) {
      const mods = testModifier(n, names);
      if (mods && mods.includes('only')) ctx.report('TB-F6', n, { message: `\`.only\` in a committed spec (unwaivable)`, data: { only: true } });
      else if (mods && !mods.includes('step') && (mods.at(-1) === 'skip' || mods.at(-1) === 'fixme')) {
        const declared = n.arguments.some((a) => isFn(unwrap(a))) && n.arguments.length >= 2 && (isStr(unwrap(n.arguments[0])) || unwrap(n.arguments[0]).type === 'TemplateLiteral');
        const a0 = unwrap(n.arguments[0]);
        const reasonless = declared || n.arguments.length === 0 || (a0 && a0.type === 'BooleanLiteral' && a0.value && n.arguments.length < 2);
        if (reasonless) ctx.report('TB-F6', n, { severity: 'advisory', message: `unconditional \`${mods.join('.')}\` without a reason (advisory)`, do: "Give the skip its reason: test.skip(<condition>, '<the premise or the defect>'), or delete the test." });
      } else if (mods && mods.length === 1 && mods[0] === 'fail') sentinel(n, ctx);
      else if (p === 'fail' && isMember(callee) && infoObject(unwrap(callee.object), ctx)) sentinel(n, ctx, 'testInfo.fail(…)');
    }

    // F7: optional actions in a spec
    if (spec && isMember(callee)) {
      let r = callee;
      while (isMember(r) || isCall(r)) r = isMember(r) ? unwrap(r.object) : unwrap(r.callee);
      const rooted = r && ctx.kind(r) === 'steps';
      if (rooted && (p === 'clickIfPresent' || p === 'ifVisible')) ctx.report('TB-F7', n, { message: `\`${p}\` in a spec: does the test pass if the element never appears?` });
      else if (rooted && n.arguments.some((a) => { const o = unwrap(a); return o && o.type === 'ObjectExpression' && o.properties.some((q) => q.type === 'ObjectProperty' && (q.key.name === 'optional' || q.key.value === 'optional') && unwrap(q.value).type === 'BooleanLiteral' && unwrap(q.value).value); })) ctx.report('TB-F7', n, { message: `\`{ optional: true }\` on steps.${p} in a spec: does the test pass if the element never appears?` });
    }
  }

  /** TB-F6 for `test.fail(…)`: accepted only in sentinel form (a) or (b) inside the test it marks. */
  /**
   * TB-F6 for an expected failure (`test.fail(…)`, `testInfo.fail(…)`, `testInfo.expectedStatus = 'failed'`).
   * Form (a): the title carries `[SENTINEL <TICKET>-D<n>]`, `test.fail(true, '<that id>: …')`, `@known-defect`.
   * Form (b): `test.fail(true, '<register key>: …')`, `@known-defect`, a pointer resolving to the key.
   */
  function sentinel(n, ctx, what = 'test.fail(…)', args = n.arguments) {
    const { file } = ctx;
    const declared = args.length >= 2 && isFn(unwrap(args.at(-1)));
    if (declared) { ctx.report('TB-F6', n, { message: '`test.fail(title, …)` declares an expected failure outside the sentinel forms' }); return; }
    const own = enclosingDeclarations(ctx.stack, file.testNames).find((d) => d.cls.type === 'test');
    if (!own || ctx.region !== 'test') { ctx.report('TB-F6', n, { message: `\`${what}\` outside a test body: only a sentinel test marks itself` }); return; }
    const title = own.cls.title ? own.cls.title.text : '';
    const [cond, reason] = args.map(unwrap);
    const tags = new Set([...tagsOf(own.call), ...enclosingDeclarations(ctx.stack, file.testNames).filter((d) => d.cls.type === 'describe').flatMap((d) => [...tagsOf(d.call)])]);
    const isTrue = cond && cond.type === 'BooleanLiteral' && cond.value;
    const text = reason && isStr(reason) ? strValue(reason) : '';
    const sentinelId = (SENTINEL_TITLE.exec(title) || [])[1];
    if (sentinelId) {
      // form (a)
      const problems = [];
      if (!isTrue) problems.push('`test.fail(true, …)`');
      if (!text.includes(sentinelId)) problems.push(`a reason naming ${sentinelId}`);
      if (!tags.has('@known-defect')) problems.push('`@known-defect` on the test');
      if (problems.length) ctx.report('TB-F6', n, { message: `\`${what}\` in a [SENTINEL ${sentinelId}] test: form (a) needs ${problems.join('; ')}` });
      return;
    }
    const key = text ? (/^\s*([A-Za-z][\w.-]*)\s*:/.exec(text) || [])[1] : null;
    const problems = [];
    if (!isTrue) problems.push('the first argument is `true`');
    if (!key) problems.push('the reason starts with the register key (`\'L3: …\'`)');
    if (!tags.has('@known-defect')) problems.push('the test carries `@known-defect`');
    const stmtLine = (statementOf(ctx.stack.slice(0, ctx.stack.indexOf(own.call) + 1)) || own.call).loc.start.line;
    const pointers = pointersAbove(file, stmtLine).map((x) => resolveRef(project.root, x.ref));
    if (key && !pointers.some((r) => refNames(r, key))) problems.push(`a \`// defect:\` pointer in the test's own comment block resolves to ${key}`);
    if (problems.length) ctx.report('TB-F6', n, { message: `\`${what}\` is in neither sentinel form: form (b) needs ${problems.join('; ')}`, data: { key } });
  }

  /** `testInfo` (the test callback's second parameter, or a name for it) or `test.info()`. */
  function infoObject(o, ctx) {
    if (isCall(o)) { const ch = (testModifier(o, ctx.file.testNames) || []); return ch.length === 1 && ch[0] === 'info'; }
    if (o.type !== 'Identifier') return false;
    if (/^(testInfo|info)$/.test(o.name)) return true;
    const own = enclosingDeclarations(ctx.stack, ctx.file.testNames).find((d) => d.cls.type === 'test');
    const p1 = own && own.cls.fn.params[1];
    return !!(p1 && p1.type === 'Identifier' && p1.name === o.name);
  }

  return {
    projectStart(p) {
      for (const f of p.allFiles) timers.set(f.abs, timerHelpers(f));
    },
    IfStatement: onIf,
    SwitchStatement(n, ctx) {
      if (!flowRegion(ctx) || inLoop(ctx.stack, ctx.file.testNames)) return;
      if (n.cases.some((c) => c.consequent.some((s) => branchCounts(s, ctx)))) f1(n, ctx, '`switch` whose case performs an action or an assertion');
    },
    ConditionalExpression(n, ctx) {
      const parent = parentOf(ctx);
      const branches = [unwrap(n.consequent), unwrap(n.alternate)];
      const direct = parent && (parent.type === 'AwaitExpression' || parent.type === 'ExpressionStatement') && branches.some((b) => isDriving(b, ctx.kind));
      // a conditional that picks the action: `(c ? steps.click : steps.hover)(…)`, `steps[c ? 'click' : 'hover'](…)`,
      // `const go = c ? () => steps.click(…) : () => …`
      const picksCallee = parent && isCall(parent) && unwrap(parent.callee) === n && branches.some((b) => isMember(b) && ctx.kind(b.object));
      const picksKey = parent && isMember(parent) && parent.computed && parent.property === n && ctx.kind(parent.object);
      const picksFn = branches.some((b) => isFn(b) && drives(b.body, ctx.kind));
      if (direct || picksCallee || picksKey || picksFn || awaitsDriving(n.consequent, ctx.kind) || awaitsDriving(n.alternate, ctx.kind)) f1(n, ctx, 'conditional expression whose branch performs, awaits or picks an action or an assertion');
    },
    LogicalExpression(n, ctx) {
      if (!['&&', '||', '??'].includes(n.operator)) return;
      const parent = parentOf(ctx);
      const direct = parent && (parent.type === 'AwaitExpression' || parent.type === 'ExpressionStatement') && isDriving(unwrap(n.right), ctx.kind);
      if (direct || awaitsDriving(n.right, ctx.kind)) f1(n, ctx, `\`${n.operator}\` whose right operand awaits an action or an assertion`);
    },
    ForStatement: loop, ForOfStatement: loop, ForInStatement: loop, WhileStatement: loop, DoWhileStatement: loop,
    TryStatement(n, ctx) {
      if (!(ctx.file.kind === 'spec' && !ctx.browser && !ctx.nested && (ctx.region === 'test' || ctx.region === 'helper'))) return;
      if (!n.handler) { ctx.report('TB-F3', n, { severity: 'advisory', message: '`try/finally` in a test body (advisory: prefer a fixture teardown)' }); return; }
      if (!drives(n.block, ctx.kind)) return;
      const h = n.handler.body;
      const rethrows = anyNode(h, (x) => x.type === 'ThrowStatement' || (isCall(x) && (((memberChain(unwrap(x.callee)) || [])[0] === 'expect') || (unwrap(x.callee).type === 'Identifier' && /^(fail|expect|assert)/.test(unwrap(x.callee).name)))));
      const records = anyNode(h, (x) => isCall(x) && isMember(unwrap(x.callee)) && /^(push|add|set|unshift)$/.test(propName(unwrap(x.callee)) || ''));
      if (!rethrows && !records) ctx.report('TB-F3', n, { severity: 'advisory', message: '`try` that drives the UI with a `catch` that neither rethrows, asserts nor records (advisory: unmeasured)' });
    },
    CallExpression: onCall,
    OptionalCallExpression: onCall,
    NewExpression(n, ctx) {
      if (ctx.inRoute) return;
      const parent = parentOf(ctx);
      if (!(parent && parent.type === 'AwaitExpression') || n.callee.type !== 'Identifier' || n.callee.name !== 'Promise') return;
      const f = unwrap(n.arguments[0]);
      const aliases = (timers.get(ctx.file.abs) || {}).aliases || new Set(['setTimeout']);
      if (f && isFn(f) && anyNode(f.body, (x) => isCall(x) && ((unwrap(x.callee).type === 'Identifier' && aliases.has(unwrap(x.callee).name)) || (isMember(unwrap(x.callee)) && propName(unwrap(x.callee)) === 'setTimeout')))) {
        ctx.report('TB-F5', n, { severity: ctx.file.kind === 'spec' ? 'blocking' : 'advisory', message: `awaited promise-sleep \`new Promise(… setTimeout …)\`${ctx.file.kind === 'spec' ? '' : ' (advisory in support)'}` });
      }
    },
    AssignmentExpression(n, ctx) {
      if (ctx.file.kind !== 'spec' || !isMember(n.left) || propName(n.left) !== 'expectedStatus' || !infoObject(unwrap(n.left.object), ctx)) return;
      const r = unwrap(n.right);
      if (isStr(r) && strValue(r) === 'failed') sentinel(n, ctx, "testInfo.expectedStatus = 'failed'", []);
    },
    MemberExpression(n, ctx) {
      if (ctx.file.kind !== 'spec' || propName(n) !== 'retry' || n.computed) return;
      const o = unwrap(n.object);
      const isInfo = (o.type === 'Identifier' && /^(testInfo|info)$/.test(o.name)) || (isCall(o) && /\.info$/.test((memberChain(unwrap(o.callee)) || []).join('.')));
      if (isInfo) ctx.report('TB-F4', n, { message: '`testInfo.retry` branches on the retry attempt' });
    },
    fileEnd(file) {
      // an IIFE or one-pass loop around an F1 branch is itself the evasion shape
      for (const w of file.facts.f1Wrappers || []) {
        const s = w.node.loc.start.line, e = w.node.loc.end.line;
        if (project.findings.some((f) => f.file === file.rel && f.rule === 'TB-F1' && f.line > s && f.line <= e) || project.findings.some((f) => f.file === file.rel && f.rule === 'TB-F1' && f.line === s && f.column > w.node.loc.start.column + 1)) {
          project.findings.push({ rule: 'TB-F1', severity: 'blocking', file: file.rel, line: s, column: w.node.loc.start.column + 1, region: w.region, message: `${w.kind} around a branch that decides what the test does (an evasion shape of TB-F1)`, do: RULES[0].do, why: `${RULEBOOK}#tb-f1`, test: w.test ? { title: w.test.title, id: w.test.id, line: w.test.line } : null, stmtLine: s, waived: false, ...(file.followedFrom ? { followedFrom: file.followedFrom } : {}) });
        }
      }
    },
  };

  function loop(n, ctx) {
    if (ctx.file.kind !== 'spec' || ctx.browser || ctx.nested || !(ctx.region === 'test' || ctx.region === 'helper' || ctx.region === 'hook')) return;
    if (onePass(n)) { wrapper(n, ctx, 'a one-pass loop'); return; }
    if (ctx.region === 'hook') return;
    ctx.report('TB-F2', n, { message: `loop in a ${ctx.region === 'helper' ? 'shared in-spec helper' : 'test body'}` });
    const retry = (n.type === 'WhileStatement' && unwrap(n.test).type === 'BooleanLiteral')
      || (n.type !== 'ForOfStatement' && n.type !== 'ForInStatement' && (anyNode(n.body, (x) => x.type === 'BreakStatement' || (x.type === 'IfStatement' && anyNode(x.consequent, (y) => y.type === 'ReturnStatement')), { intoFunctions: false })
        || anyNode(n.body, (x) => x.type === 'TryStatement' && !!x.handler && anyNode(x.handler, (y) => y.type === 'ContinueStatement'), { intoFunctions: false })));
    if (retry) ctx.report('TB-F4', n, { message: 'hand-rolled retry loop in a spec' });
  }
}

