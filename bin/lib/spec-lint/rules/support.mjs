// Family X: support files (test-baseline.md §Family X). TB-X1 and TB-X2 are judgment rules for the reader;
// the engine checks TB-X3 (no tests in support files) and the loop shapes of TB-X4:
//   forever   `while (true)`, `do … while (true)`, `for (;;)` or a `for` with no test, whose body has no exit
//             (break, return or throw) guarded by a comparison of a counter or a deadline
//   state     a `while`, `do … while` or `for` whose condition awaits page state and compares no counter or
//             deadline, and whose body has no such guarded exit either
// A counter is a variable the loop itself steps (`++`, `--`, `+= k`, `-= k`, `x = x ± k`, k not 0, in the body,
// the condition or the `for` update) and does not reset in its body; a deadline is `Date.now()`,
// `performance.now()` or `new Date()`, or a variable of the enclosing function computed from one and not set
// again inside the loop; a call of a local helper that takes the deadline and compares the clock counts as the
// guard. Names do not count: `accountCreated` is not a counter.
import { isCall, isFn, unwrap, anyNode, memberChain } from '../shapes.mjs';
import { classifyCall } from '../bindings.mjs';

const ADVISORY = '(advisory until a live measurement confirms it)';

export const RULES = [
  { id: 'TB-X3', title: 'test declared in a support file', severity: 'blocking', appliesTo: ['support'], do: 'Move the test into a spec file; support modules export verbs, data and fixtures.' },
  { id: 'TB-X4', title: 'unbounded loop in a verb', severity: 'advisory', appliesTo: ['support'], do: 'Bound the loop with a counter or a deadline (an exit guarded by it), and follow it with a hard check.' },
];

const COMPARE = new Set(['<', '<=', '>', '>=', '===', '!==', '==', '!=']);
const LOOP = new Set(['WhileStatement', 'DoWhileStatement', 'ForStatement', 'ForInStatement', 'ForOfStatement']);

/** A clock read: `Date.now()`, `performance.now()`, `new Date()`. */
const isClock = (x) => (isCall(x) && /^(Date\.now|performance\.now)$/.test((memberChain(unwrap(x.callee)) || []).join('.'))) || (x.type === 'NewExpression' && x.callee.type === 'Identifier' && x.callee.name === 'Date');

const isZero = (x) => { const u = unwrap(x); return !!u && u.type === 'NumericLiteral' && u.value === 0; };
const sameName = (x, name) => { const u = unwrap(x); return !!u && u.type === 'Identifier' && u.name === name; };

/** A step of `x`: `x++`, `--x`, `x += k`, `x -= k` or `x = x ± k`, with k not 0. */
function stepOf(x) {
  if (x.type === 'UpdateExpression' && x.argument.type === 'Identifier') return x.argument.name;
  if (x.type !== 'AssignmentExpression' || x.left.type !== 'Identifier') return null;
  const name = x.left.name;
  if ((x.operator === '+=' || x.operator === '-=') && !isZero(x.right)) return name;
  const r = unwrap(x.right);
  if (x.operator === '=' && r && r.type === 'BinaryExpression' && (r.operator === '+' || r.operator === '-')) {
    if (sameName(r.left, name) && !isZero(r.right)) return name;
    if (r.operator === '+' && sameName(r.right, name) && !isZero(r.left)) return name;
  }
  return null;
}

/** Names the loop body assigns other than by a step (a reset: `n = 0`, `end = Date.now() + 5000`). */
function resetsIn(loop) {
  const out = new Set();
  for (const part of [loop.body, loop.test]) if (part) anyNode(part, (x) => { if (x.type === 'AssignmentExpression' && x.left.type === 'Identifier' && !stepOf(x)) out.add(x.left.name); return false; }, { intoFunctions: false });
  return out;
}

/** Variables the loop steps (body, condition or `for` update) and never resets in its body. */
function countersOf(loop, resets) {
  const out = new Set();
  const mark = (x) => { const s = stepOf(x); if (s) out.add(s); return false; };
  for (const part of [loop.body, loop.test, loop.update]) if (part) anyNode(part, mark, { intoFunctions: false });
  for (const r of resets) out.delete(r);
  return out;
}

/** Variables of `scope` computed from a clock read (or from another such variable). */
function clockVariables(scope) {
  const out = new Set();
  const assigns = [];
  anyNode(scope, (x) => {
    if (x.type === 'VariableDeclarator' && x.id.type === 'Identifier' && x.init) assigns.push([x.id.name, x.init]);
    if (x.type === 'AssignmentExpression' && x.left.type === 'Identifier') assigns.push([x.left.name, x.right]);
    return false;
  }, { intoFunctions: false });
  for (let changed = true; changed;) {
    changed = false;
    for (const [name, init] of assigns) {
      if (out.has(name)) continue;
      if (anyNode(init, (y) => isClock(y) || (y.type === 'Identifier' && out.has(y.name)), { intoFunctions: false })) { out.add(name); changed = true; }
    }
  }
  return out;
}

/** A function of the same module by name: a top-level declaration or a `const` bound to a function. */
function localFunction(file, name) {
  for (const st of file.ast.program.body) {
    const d = st.type === 'ExportNamedDeclaration' ? st.declaration : st;
    if (d && d.type === 'FunctionDeclaration' && d.id && d.id.name === name) return d;
    if (d && d.type === 'VariableDeclaration') for (const v of d.declarations) if (v.id.type === 'Identifier' && v.id.name === name && isFn(unwrap(v.init))) return unwrap(v.init);
  }
  return null;
}

const compares = (t, hit) => !!t && anyNode(t, (x) => x.type === 'BinaryExpression' && COMPARE.has(x.operator) && [x.left, x.right].some((side) => anyNode(side, hit, { intoFunctions: false })), { intoFunctions: false });

/** A local helper the loop calls with a deadline argument that compares the clock and throws (or returns true for the guard). */
function deadlineHelper(call, file, clocks) {
  const c = unwrap(call && call.type === 'AwaitExpression' ? call.argument : call);
  if (!c || !isCall(c) || unwrap(c.callee).type !== 'Identifier') return null;
  if (!c.arguments.some((a) => anyNode(a, (y) => isClock(y) || (y.type === 'Identifier' && clocks.has(y.name)), { intoFunctions: false }))) return null;
  const fn = localFunction(file, unwrap(c.callee).name);
  if (!fn || !compares(fn.body, (y) => isClock(y) || y.type === 'Identifier')) return null;
  return anyNode(fn.body, isClock, { intoFunctions: false }) ? fn : null;
}

/** The condition compares a counter or a deadline (directly, or through a local deadline helper). */
const comparesBound = (t, counters, clocks, file, resets = new Set()) => !!t && (anyNode(t, (x) => {
  if (x.type !== 'BinaryExpression' || !COMPARE.has(x.operator)) return false;
  const has = (pred) => [x.left, x.right].some((side) => anyNode(side, pred, { intoFunctions: false }));
  if (has((y) => y.type === 'Identifier' && (counters.has(y.name) || clocks.has(y.name)))) return true;
  // a clock read against a bound the loop itself sets again moves with it
  return has(isClock) && !has((y) => y.type === 'Identifier' && resets.has(y.name));
}, { intoFunctions: false }) || anyNode(t, (x) => isCall(x) && !!deadlineHelper(x, file, clocks), { intoFunctions: false }));

/** The statement leaves the loop: a return or throw anywhere, a break not inside a nested loop or switch. */
function leaves(node, nested = false) {
  if (!node || typeof node.type !== 'string' || isFn(node)) return false;
  if (node.type === 'ReturnStatement' || node.type === 'ThrowStatement') return true;
  if (node.type === 'BreakStatement') return !nested || !!node.label;
  const inner = nested || LOOP.has(node.type) || node.type === 'SwitchStatement';
  for (const k of Object.keys(node)) {
    if (k === 'loc' || k.endsWith('Comments')) continue;
    const v = node[k];
    if (Array.isArray(v)) { if (v.some((c) => c && typeof c.type === 'string' && leaves(c, inner))) return true; } else if (v && typeof v.type === 'string' && leaves(v, inner)) return true;
  }
  return false;
}

/** The body has an exit guarded by a comparison of a counter or a deadline. */
const guardedExit = (loop, counters, clocks, file, resets) => anyNode(loop.body, (x) => (x.type === 'IfStatement' && comparesBound(x.test, counters, clocks, file, resets) && leaves(x.consequent))
  // a statement that calls a local helper which throws once the deadline passed
  || (x.type === 'ExpressionStatement' && (() => { const fn = deadlineHelper(x.expression, file, clocks); return !!fn && anyNode(fn.body, (y) => y.type === 'ThrowStatement', { intoFunctions: false }); })()), { intoFunctions: false });

export function visitors() {
  const loop = (n, ctx) => {
    if (ctx.file.kind !== 'support') return;
    const t = n.test ? unwrap(n.test) : null;
    const forever = !t || (t.type === 'BooleanLiteral' && t.value) || (t.type === 'NumericLiteral' && t.value !== 0);
    const stateDriven = !forever && anyNode(t, (x) => x.type === 'AwaitExpression', { intoFunctions: false });
    if (!forever && !stateDriven) return;
    let scope = null;
    for (let i = ctx.stack.length - 2; i >= 0 && !scope; i--) if (isFn(ctx.stack[i])) scope = ctx.stack[i].body;
    const resets = resetsIn(n);
    const counters = countersOf(n, resets);
    // a deadline set again inside the loop moves with it: it bounds nothing
    const clocks = new Set([...clockVariables(scope || ctx.file.ast.program)].filter((c) => !resets.has(c)));
    if (guardedExit(n, counters, clocks, ctx.file, resets)) return;
    if (forever) {
      const shape = n.type === 'ForStatement' ? (n.init || n.update ? 'a `for` with no test' : '`for (;;)`') : n.type === 'DoWhileStatement' ? '`do … while (true)`' : '`while (true)`';
      ctx.report('TB-X4', n, { message: `${shape} without a counter or deadline that ends it ${ADVISORY}`, data: { shape: 'forever' } });
    } else if (!comparesBound(t, counters, clocks, ctx.file, resets)) {
      ctx.report('TB-X4', n, { message: `\`${n.type === 'DoWhileStatement' ? 'do … while' : n.type === 'ForStatement' ? 'for' : 'while'}\` bounded only by page state: no counter or deadline ends it (advisory)`, data: { shape: 'state' } });
    }
  };
  return {
    CallExpression(n, ctx) {
      if (ctx.file.kind !== 'support' || ctx.file.stat === 'setup') return;
      const c = classifyCall(n, ctx.file.testNames);
      if (c && (c.type === 'test' || c.type === 'describe')) ctx.report('TB-X3', n, { message: `\`${(memberChain(unwrap(n.callee)) || ['test']).join('.')}(…)\` declares a ${c.type} in a support module` });
    },
    WhileStatement: loop,
    DoWhileStatement: loop,
    ForStatement: loop,
  };
}
