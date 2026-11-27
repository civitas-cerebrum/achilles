// Family X: support files (test-baseline.md §Family X). TB-X1 and TB-X2 are judgment rules for the reader;
// the engine checks TB-X3 (no tests in support files) and the loop shapes of TB-X4:
//   forever   `while (true)`, `do … while (true)`, `for (;;)` or a `for` with no test, whose body has no exit
//             (break, return or throw) guarded by a comparison of a counter or a deadline
//   state     a `while` or `do … while` whose condition awaits page state and compares no counter or deadline,
//             and whose body has no such guarded exit either
// A counter is a variable the loop itself steps (`++`, `--`, `+=`, `-=`, in the body or the `for` update); a
// deadline is `Date.now()`, `performance.now()` or `new Date()`, or a variable of the enclosing function
// computed from one. Names do not count: `accountCreated` is not a counter.
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

/** Variables the loop steps: `i++`, `--n`, `tries += 1`, `left -= 1`, in the body, the condition or the `for` update. */
function countersOf(loop) {
  const out = new Set();
  const mark = (x) => {
    if (x.type === 'UpdateExpression' && x.argument.type === 'Identifier') out.add(x.argument.name);
    if (x.type === 'AssignmentExpression' && (x.operator === '+=' || x.operator === '-=') && x.left.type === 'Identifier') out.add(x.left.name);
    return false;
  };
  for (const part of [loop.body, loop.test, loop.update]) if (part) anyNode(part, mark, { intoFunctions: false });
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

/** The condition compares a counter or a deadline. */
const comparesBound = (t, counters, clocks) => !!t && anyNode(t, (x) => x.type === 'BinaryExpression' && COMPARE.has(x.operator)
  && [x.left, x.right].some((side) => anyNode(side, (y) => isClock(y) || (y.type === 'Identifier' && (counters.has(y.name) || clocks.has(y.name))), { intoFunctions: false })), { intoFunctions: false });

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
const guardedExit = (loop, counters, clocks) => anyNode(loop.body, (x) => x.type === 'IfStatement' && comparesBound(x.test, counters, clocks) && leaves(x.consequent), { intoFunctions: false });

export function visitors() {
  const loop = (n, ctx) => {
    if (ctx.file.kind !== 'support') return;
    const t = n.test ? unwrap(n.test) : null;
    const forever = !t || (t.type === 'BooleanLiteral' && t.value) || (t.type === 'NumericLiteral' && t.value !== 0);
    const stateDriven = !forever && n.type !== 'ForStatement' && anyNode(t, (x) => x.type === 'AwaitExpression', { intoFunctions: false });
    if (!forever && !stateDriven) return;
    let scope = null;
    for (let i = ctx.stack.length - 2; i >= 0 && !scope; i--) if (isFn(ctx.stack[i])) scope = ctx.stack[i].body;
    const counters = countersOf(n);
    const clocks = clockVariables(scope || ctx.file.ast.program);
    if (guardedExit(n, counters, clocks)) return;
    if (forever) {
      const shape = n.type === 'ForStatement' ? (n.init || n.update ? 'a `for` with no test' : '`for (;;)`') : n.type === 'DoWhileStatement' ? '`do … while (true)`' : '`while (true)`';
      ctx.report('TB-X4', n, { message: `${shape} without a counter or deadline that ends it ${ADVISORY}`, data: { shape: 'forever' } });
    } else if (!comparesBound(t, counters, clocks)) {
      ctx.report('TB-X4', n, { message: `\`${n.type === 'DoWhileStatement' ? 'do … while' : 'while'}\` bounded only by page state: no counter or deadline ends it (advisory)`, data: { shape: 'state' } });
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
