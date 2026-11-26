// Family W: timeouts (test-baseline.md §Family W). TB-W1 a per-call or per-test timeout override without a
// `// perf:` or `// slow:` reason; TB-W2 a describe-level timeout. Both advisory; the reader decides.
import { isCall, isMember, memberChain, unwrap, propKey, statementOf, commentBlockAbove, trailingComment } from '../shapes.mjs';
import { DRIVER_KINDS, classifyCall } from '../bindings.mjs';

const REASON = /\b(perf|slow):\s*\S/;

export const RULES = [
  { id: 'TB-W1', title: 'timeout override without its reason', severity: 'advisory', appliesTo: ['spec', 'support'], do: 'Say why the default is not enough in a `// perf:` or `// slow:` comment directly above the override, or drop the override.' },
  { id: 'TB-W2', title: 'describe-level timeout', severity: 'advisory', appliesTo: ['spec'], do: 'Give the one test that needs more time its own budget (test.setTimeout with a `// perf:` reason); no describe needs a timeout of its own.' },
];

/** What a call with an options `timeout` is: steps | interactions | raw | expect | test, or null (not a hit). */
function overrideOf(call, ctx) {
  if (!isCall(call)) return null;
  const c = classifyCall(call, ctx.file.testNames);
  if (c && c.type === 'test') return 'test';
  if (c && c.type === 'configure') return 'configure';
  if (c) return null;
  const callee = unwrap(call.callee);
  const ch = memberChain(callee) || [];
  if (ch[0] === 'expect') return 'expect';
  let b = callee;
  while (isMember(b) || isCall(b)) b = isMember(b) ? unwrap(b.object) : unwrap(b.callee);
  if (b && b.type === 'Identifier' && b.name === 'expect') return 'expect';
  if (!isMember(callee)) return null;
  const k = ctx.kind(callee.object);
  let r = callee;
  while (isMember(r) || isCall(r)) r = isMember(r) ? unwrap(r.object) : unwrap(r.callee);
  const rk = r ? ctx.kind(r) : null;
  if (rk === 'steps') return 'steps';
  if (rk === 'interactions' || k === 'interactions-part') return 'interactions';
  if (DRIVER_KINDS.has(k)) return 'raw';
  return null;
}

export function visitors() {
  return {
    ObjectProperty(n, ctx) {
      if (propKey(n) !== 'timeout') return;
      const obj = ctx.stack[ctx.stack.length - 2];
      const call = ctx.stack[ctx.stack.length - 3];
      if (!obj || obj.type !== 'ObjectExpression' || !call || !isCall(call) || !call.arguments.includes(obj)) return;
      const what = overrideOf(call, ctx);
      if (!what) return;
      if (what === 'configure') {
        if (ctx.file.kind === 'spec') ctx.report('TB-W2', n, { message: '`test.describe.configure({ timeout })` gives a describe its own timeout (advisory)' });
        return;
      }
      const st = statementOf(ctx.stack);
      const lines = [...commentBlockAbove(ctx.file, (st || n).loc.start.line), trailingComment(ctx.file, n.loc.start.line), trailingComment(ctx.file, (st || n).loc.start.line)];
      if (lines.some((l) => REASON.test(l))) return;
      ctx.report('TB-W1', n, { message: `${what === 'test' ? 'per-test' : 'per-call'} \`timeout\` override on ${what === 'raw' ? 'a raw call' : what === 'test' ? 'test(…)' : `${what}(…)`} without a \`// perf:\` or \`// slow:\` reason (advisory)` });
    },
  };
}

