// Family G: governance (test-baseline.md §Family G). TB-G0 the file parses; TB-G1 waivers, gap citations
// and register rows are well formed. TB-G2 (rule inputs are not weakened) is a commit-gate check of a
// later unit.
import { REGISTER } from '../waivers.mjs';

export const RULES = [
  { id: 'TB-G0', title: 'the file does not parse', severity: 'blocking', appliesTo: ['spec', 'support'], waivable: false, do: 'Fix the syntax so the file parses as TypeScript or JavaScript.' },
  { id: 'TB-G1', title: 'malformed waiver, gap citation or register row', severity: 'blocking', appliesTo: ['spec', 'support', 'register'], waivable: false, do: 'Write `// achilles-allow TB-<id> -- <the actual obstacle, 15+ characters> [gap: FG-<n>]` on its own line directly above the one statement it excuses (at most 2 per test, never for an unwaivable rule), and cite only open rows that cover the call.' },
];

const DO_ROW = 'A row lists only methods of the no-equivalent table (TB-A2b); a method with a Steps equivalent is a version gap or a rewrite, and a method in neither table needs the person\'s decision before it gets a row.';

function covers(entry, m) {
  if (!entry.methods.includes(m.method)) return false;
  if (m.recv && !entry.on.includes(m.recv)) return false;
  if (m.args && (!entry.args || !m.args.every((a) => entry.args.includes(a)))) return false;
  return true;
}

export function visitors(project) {
  const eq = project.equivalents;
  return {
    parseError(file, e) {
      const line = e.loc ? e.loc.line : 1;
      project.findings.push({
        rule: 'TB-G0', severity: 'blocking', file: file.rel, line, column: e.loc ? e.loc.column + 1 : 1, region: 'module',
        message: `does not parse: ${String(e.message).replace(/\s*\(\d+:\d+\)$/, '')}`, do: RULES[0].do, why: 'skills/achilles-orchestrator/references/test-baseline.md#tb-g0',
        test: null, stmtLine: line, waived: false,
      });
    },
    projectEnd(p) {
      const push = (file, line, message, extra = {}) => p.findings.push({ rule: 'TB-G1', severity: 'blocking', file, line, column: 1, region: 'module', message, do: extra.do || RULES[1].do, why: 'skills/achilles-orchestrator/references/test-baseline.md#tb-g1', test: extra.test || null, waived: false });
      const testAt = (f, line) => { const t = f.tests.find((x) => line >= x.line && line <= x.endLine); return t ? { title: t.title, id: t.id, line: t.line } : null; };
      for (const f of p.files) {
        for (const w of f.waivers || []) for (const msg of w.problems) push(f.rel, w.line, `waiver: ${msg}`, { test: testAt(f, w.line) });
        const rows = new Map(p.register.rows.map((r) => [r.id, r]));
        for (const c of f.citations || []) {
          const problems = [...c.problems];
          if (!c.ownLine) problems.push('a citation sits on its own line directly above the call');
          if (c.row) {
            const row = rows.get(c.row);
            if (!row) problems.push(`${c.row} is not a row of the framework-gap register`);
            else if (row.fixedIn) problems.push(`${c.row} is marked ${row.status}: upgrade and use the Steps method`);
            else {
              let target = c.line + 1;
              while (f.commentLines.has(target)) target++;
              const calls = (f.facts.noEq || []).filter((x) => x.stmtLine === target);
              if (!calls.length) problems.push(`no call from the no-equivalent table follows the citation of ${c.row}`);
              else if (!calls.some((x) => x.row === c.row)) problems.push(`${c.row} does not cover \`${calls[0].kind}.${calls[0].method}\`${calls[0].row ? ` (that is ${calls[0].row})` : ''}`);
            }
          }
          for (const msg of problems) push(f.rel, c.line, `framework-gap citation: ${msg}`, { test: testAt(f, c.line) });
        }
      }
      if (p.register.file) {
        const noEq = eq.noEquivalent;
        const hasEquivalent = (m) => !!(eq.methods[m.method] || eq.http[m.method] || eq.evaluate.methods.includes(m.method));
        for (const r of p.register.rows) {
          if (!r.methods.length) { push(REGISTER, r.line, `register row ${r.id} lists no raw methods`, { do: DO_ROW }); continue; }
          for (const m of r.methods) {
            if (m.hatch || noEq.some((e) => covers(e, m))) continue;
            const name = `${m.recv ? `${m.recv}.` : ''}${m.method}`;
            push(REGISTER, r.line, hasEquivalent(m)
              ? `register row ${r.id} names \`${name}\`, which has a Steps equivalent`
              : `register row ${r.id} names \`${name}\`, which is in neither the equivalence table nor the no-equivalent table: a new row needs the person's decision`, { do: DO_ROW });
          }
        }
      }
    },
  };
}
