// Family K: k6 (test-baseline.md §Family K), advisory until measured on a live k6 suite. Files under tests/perf/.
//   TB-K1 an origin literal in a request call or an __ENV fallback
//   TB-K2 a script whose options declare no thresholds
//   TB-K3 a script with more than one scenario (a hint for the reader)
//   TB-K4 a sleep inside a loop: a polling wait, not think time between iterations
import { isFn, isMember, isCall, unwrap, isStr, strValue, anyNode, memberChain, propKey } from '../shapes.mjs';
import { LOOPS } from '../shapes.mjs';

const RULEBOOK = 'skills/achilles-orchestrator/references/test-baseline.md';
const ORIGIN = /^https?:\/\/[^/\s'"`]+/i;

export const RULES = [
  { id: 'TB-K1', title: 'k6 origin not from configuration', severity: 'advisory', appliesTo: ['k6'], do: 'Take the origin from the perf configuration module (`config.baseUrl`) and address paths on it.' },
  { id: 'TB-K2', title: 'k6 script without thresholds', severity: 'advisory', appliesTo: ['k6'], do: 'Declare thresholds in options; a breach is a finding, never a reason to loosen them.' },
  { id: 'TB-K3', title: 'k6 script with more than one scenario', severity: 'advisory', appliesTo: ['k6'], do: 'Keep one scenario with one workload intent per script.' },
  { id: 'TB-K4', title: 'k6 sleep used as a polling wait', severity: 'advisory', appliesTo: ['k6'], do: 'Keep sleep for think time between iterations; wait for a condition with a bounded check instead of sleeping in a loop.' },
];

function walk(n, visit, stack = []) {
  if (!n || typeof n.type !== 'string') return;
  visit(n, stack);
  stack.push(n);
  for (const k of Object.keys(n)) {
    if (k === 'loc' || k.endsWith('Comments')) continue;
    const v = n[k];
    if (Array.isArray(v)) { for (const x of v) if (x && typeof x.type === 'string') walk(x, visit, stack); } else if (v && typeof v.type === 'string') walk(v, visit, stack);
  }
  stack.pop();
}

export function visitors(project) {
  return {
    projectEnd(p) {
      for (const file of p.k6Files) {
        const push = (rule, node, message) => p.findings.push({ rule, severity: 'advisory', file: file.rel, line: node.loc.start.line, column: node.loc.start.column + 1, region: 'module', message, do: RULES.find((r) => r.id === rule).do, why: `${RULEBOOK}#${rule.toLowerCase()}`, test: null, waived: false });
        let options = null;
        let runs = false;
        for (const st of file.ast.program.body) {
          if (st.type === 'ExportNamedDeclaration' && st.declaration && st.declaration.type === 'VariableDeclaration') for (const d of st.declaration.declarations) if (d.id.type === 'Identifier' && d.id.name === 'options') options = unwrap(d.init);
          if (st.type === 'ExportDefaultDeclaration') runs = true;
        }
        if (runs) {
          if (!options || options.type !== 'ObjectExpression') push('TB-K2', file.ast.program.body[0] || file.ast.program, 'the script exports no options object with thresholds (advisory)');
          else {
            const keys = options.properties.filter((x) => x.type === 'ObjectProperty').map(propKey);
            if (!keys.includes('thresholds')) push('TB-K2', options, 'options declare no thresholds (advisory)');
            const sc = options.properties.find((x) => x.type === 'ObjectProperty' && propKey(x) === 'scenarios');
            const v = sc && unwrap(sc.value);
            if (v && v.type === 'ObjectExpression' && v.properties.length > 1) push('TB-K3', sc, `options declare ${v.properties.length} scenarios (advisory)`);
          }
        }
        walk(file.ast.program, (n, stack) => {
          if (isStr(n) && ORIGIN.test(strValue(n))) {
            const parent = stack.at(-1);
            const req = stack.some((a) => isCall(a) && /^(http\.(get|post|put|patch|del|request|batch|head|options)|fetch)$/.test((memberChain(unwrap(a.callee)) || []).join('.')));
            const envFallback = parent && parent.type === 'LogicalExpression' && anyNode(parent.left, (x) => isMember(x) && (memberChain(x) || [])[0] === '__ENV');
            if (req || envFallback) push('TB-K1', n, `origin literal ${ORIGIN.exec(strValue(n))[0]}${envFallback ? ' as an __ENV fallback' : ''} (advisory)`);
          }
          if (isCall(n) && unwrap(n.callee).type === 'Identifier' && unwrap(n.callee).name === 'sleep') {
            for (let i = stack.length - 1; i >= 0 && !isFn(stack[i]); i--) if (LOOPS.has(stack[i].type)) { push('TB-K4', n, '`sleep` inside a loop waits for a condition instead of modelling think time (advisory)'); break; }
          }
        });
      }
    },
  };
}
