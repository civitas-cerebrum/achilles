// Family X: support files (test-baseline.md §Family X). TB-X1 and TB-X2 are judgment rules for the reader;
// the engine checks TB-X3 (no tests in support files) and the unbounded-loop shape of TB-X4 (advisory until
// its mechanical definition is measured).
import { isCall, isMember, unwrap, anyNode, memberChain, propName } from '../shapes.mjs';
import { classifyCall } from '../bindings.mjs';

const BOUND = /deadline|attempt|tries|retries|retry|count|max|limit|timeout|elapsed|budget|remaining|until/i;

export const RULES = [
  { id: 'TB-X3', title: 'test declared in a support file', severity: 'blocking', appliesTo: ['support'], do: 'Move the test into a spec file; support modules export verbs, data and fixtures.' },
  { id: 'TB-X4', title: 'unbounded loop in a verb', severity: 'advisory', appliesTo: ['support'], do: 'Bound the loop with a counter or a deadline and follow it with a hard check.' },
];

/** The loop body or test checks a counter or a deadline that ends it (break, return or throw). */
function bounded(loop) {
  const ends = (b) => anyNode(b, (x) => x.type === 'BreakStatement' || x.type === 'ReturnStatement' || x.type === 'ThrowStatement', { intoFunctions: false });
  const counterTest = (t) => anyNode(t, (x) => (x.type === 'Identifier' && BOUND.test(x.name)) || (isCall(x) && /^(Date\.now|performance\.now)$/.test((memberChain(unwrap(x.callee)) || []).join('.'))) || (isMember(x) && BOUND.test(propName(x) || '')));
  return anyNode(loop.body, (x) => x.type === 'IfStatement' && counterTest(x.test) && ends(x.consequent), { intoFunctions: false });
}

export function visitors() {
  const loop = (n, ctx) => {
    if (ctx.file.kind !== 'support') return;
    const t = n.test ? unwrap(n.test) : null;
    const forever = !t || (t.type === 'BooleanLiteral' && t.value) || (t.type === 'NumericLiteral' && t.value !== 0);
    if (!forever || bounded(n)) return;
    ctx.report('TB-X4', n, { message: `\`${n.type === 'ForStatement' ? 'for (;;)' : n.type === 'DoWhileStatement' ? 'do … while (true)' : 'while (true)'}\` without a counter or deadline (advisory until the shape is measured)` });
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
