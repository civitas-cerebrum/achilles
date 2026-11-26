// Family R: readability and the oracle (test-baseline.md §Family R). R1-R3, R5 and R6 are judgment rules for
// the reader; the engine gives the mechanical hints: TB-R4 (a test with no assertion), TB-R7 (evidence keyed
// on a title) and TB-R8 (a comment that says what the next line does instead of why).
import { isMember, isCall, propName, memberChain, unwrap, anyNode, declarations, referencedNames, isAssertion } from '../shapes.mjs';
import { kindOf } from '../bindings.mjs';

const RULEBOOK = 'skills/achilles-orchestrator/references/test-baseline.md';
const PATH_CALLS = /^(?:path\.)?(?:join|resolve)$|^(?:fs\.|fsp\.|fs\.promises\.)?(?:mkdir|mkdirSync|writeFile|writeFileSync|appendFile|appendFileSync|cp|cpSync|copyFile|copyFileSync)$/;
const VERBS = /^(click|clicks|fill|fills|navigate|navigates|go|goes|open|opens|verify|verifies|check|checks|wait|waits|select|selects|hover|hovers|type|types|press|presses|upload|uploads|scroll|scrolls|drag|drags|uncheck|unchecks)\b/i;

export const RULES = [
  { id: 'TB-R4', title: 'test with no assertion', severity: 'advisory', appliesTo: ['spec'], do: "Assert the effect of the test's action (steps.verify*, steps.expect or expect on data read through Steps); a guard may follow it." },
  { id: 'TB-R7', title: 'evidence keyed on the test title', severity: 'advisory', appliesTo: ['spec', 'support'], do: 'Key evidence on the test id, never on the title; annotate every identity the test creates.' },
  { id: 'TB-R8', title: 'a comment that says what the next line does', severity: 'advisory', appliesTo: ['spec'], do: 'Say why the check or step is there (what would go wrong without it), or drop the comment.' },
];

export function visitors(project) {
  const env = { fixtureKinds: project.fixtureKinds };
  const push = (file, rule, node, message, extra = {}) => project.findings.push({
    rule, severity: 'advisory', file: file.rel, line: node.loc.start.line, column: node.loc.start.column + 1, region: extra.region || 'test', message,
    do: RULES.find((r) => r.id === rule).do, why: `${RULEBOOK}#${rule.toLowerCase()}`, test: extra.test || null, stmtLine: node.loc.start.line, waived: false,
  });

  function oracle(file) {
    const d = declarations(file);
    const byName = new Map(d.helpers.map((h) => [h.name, h]));
    for (const t of d.tests) {
      const scope = file.fnScopes && file.fnScopes.get(t.fn);
      const kind = (e) => (scope ? kindOf(e, scope, env) : e && e.type === 'Identifier' && e.name === 'steps' ? 'steps' : null);
      const bodies = [t.fn.body];
      const seen = new Set();
      const queue = [...referencedNames(t.fn.body)].filter((n) => byName.has(n));
      while (queue.length) { const n = queue.pop(); if (seen.has(n)) continue; seen.add(n); bodies.push(byName.get(n).fn.body); for (const m of referencedNames(byName.get(n).fn.body)) if (byName.has(m)) queue.push(m); }
      const helperKind = (e) => kind(e) || (e && e.type === 'Identifier' && e.name === 'steps' ? 'steps' : null);
      if (bodies.some((b) => anyNode(b, (x) => isAssertion(x, helperKind)))) continue;
      const tt = file.testsByNode.get(t.call);
      push(file, 'TB-R4', t.call, 'the test makes no assertion (advisory: the reader checks that the oracle is present and tied to the action)', { test: tt ? { title: tt.title, id: tt.id, line: tt.line } : null });
    }
  }

  return {
    CallExpression(n, ctx) {
      const name = (memberChain(unwrap(n.callee)) || []).join('.');
      if (!PATH_CALLS.test(name)) return;
      const keyed = n.arguments.find((a) => anyNode(a, (x) => {
        if (!isMember(x) || !/^(title|titlePath)$/.test(propName(x) || '')) return false;
        const o = unwrap(x.object);
        return (o.type === 'Identifier' && /^(testInfo|info)$/.test(o.name)) || (isCall(o) && /(^|\.)info$/.test((memberChain(unwrap(o.callee)) || []).join('.')));
      }));
      if (keyed) ctx.report('TB-R7', n, { message: `\`${name}(…)\` builds an evidence path from the test title (advisory)` });
    },
    fileEnd(file) {
      if (file.kind !== 'spec') return;
      oracle(file);
      // TB-R8: a short comment directly above a Steps call that names the call's own verb
      for (const c of file.ast.comments || []) {
        if (c.type !== 'CommentLine' || !file.commentLines.has(c.loc.start.line)) continue;
        const text = c.value.trim();
        if (!text || text.split(/\s+/).length > 6 || !VERBS.test(text) || /\b(because|so that|why|otherwise|only after|until)\b|:/i.test(text)) continue;
        let next = c.loc.end.line + 1;
        if (file.commentLines.has(next)) continue;
        const line = file.lines[next - 1] || '';
        const m = /\bsteps\.(\w+)\(/.exec(line);
        if (!m) continue;
        const verb = text.split(/\s+/)[0].toLowerCase().replace(/s$/, '');
        if (!m[1].toLowerCase().startsWith(verb.slice(0, 4))) continue;
        push(file, 'TB-R8', { loc: { start: { line: c.loc.start.line, column: c.loc.start.column } } }, `the comment "${text}" says what the next line does, not why (advisory)`, { region: 'test' });
      }
    },
  };
}

