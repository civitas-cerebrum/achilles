// Waivers, framework-gap citations and the project's framework-gap register (test-baseline.md §Waivers,
// §Framework gaps and version gaps).
//
//   // achilles-allow TB-<id> -- <reason of at least 15 characters> [gap: FG-<n>]
//   // framework-gap: FG-<n>
//
// A waiver sits on its own comment line in the contiguous comment block directly above the statement it
// excuses. The engine marks the one finding it excuses as waived; TB-G1 reports every malformed waiver.
// Which rules are unwaivable comes from each rule family's metadata (`waivable: false`).
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

export const REGISTER = 'tests/e2e/docs/framework-gaps.md';
const STOCK = /^(?:needed|necessary|required|temporary|temp|todo|fixme|workaround|hack|legacy|flaky|known issue|framework gap|gap|see above|n\/a|none|ok|later|tbd|no steps equivalent|no equivalent)\.?$/i;

/** The seed rows a register starts with; used when the project has no register file. */
export const SEED_ROWS = [
  { id: 'FG-1', methods: [{ recv: 'context', method: 'cookies' }, { method: 'addCookies' }, { method: 'clearCookies' }] },
  { id: 'FG-2', methods: [{ method: 'route' }, { method: 'unroute' }, { method: 'unrouteAll' }] },
  { id: 'FG-3', methods: [{ recv: 'page', method: 'on', args: ['console', 'pageerror', 'request'] }] },
  { id: 'FG-4', methods: [{ recv: 'locator', method: 'focus' }] },
  { id: 'FG-5', methods: [{ recv: 'page', method: 'on', args: ['dialog'] }] },
  { id: 'FG-6', methods: [{ recv: 'browser', method: 'newContext' }, { method: 'newPage' }, { method: 'close' }] },
].map((r) => ({ ...r, cap: null, status: 'open', line: null, seed: true }));

const ownLine = (lines, c) => lines[c.loc.start.line - 1].slice(0, c.loc.start.column).trim() === '';

/** Parses every waiver and citation comment of a file. */
export function collectComments(ast, lines, knownIds, unwaivable = new Set()) {
  const waivers = [];
  const citations = [];
  for (const c of ast.comments || []) {
    const v = c.value;
    const line = c.loc.start.line;
    if (/\bachilles-allow\b/.test(v)) {
      const w = { line, endLine: c.loc.end.line, rule: null, reason: null, gap: null, problems: [], valid: false };
      if (c.type !== 'CommentLine') w.problems.push('a waiver is a line comment (`// achilles-allow …`)');
      if (!ownLine(lines, c)) w.problems.push('a waiver sits on its own line directly above the statement it excuses, not after code');
      const m = /^\s*achilles-allow\s+(\S+)(.*)$/.exec(v);
      if (!m) w.problems.push('the waiver names no rule id');
      else {
        w.rule = m[1];
        if (!/^TB-[A-Z]\d+[a-z]?$/.test(w.rule) || (knownIds && !knownIds.has(w.rule))) w.problems.push(`${w.rule} is not a rule id of test-baseline.md`);
        else if (unwaivable.has(w.rule)) w.problems.push(`${w.rule} is unwaivable`);
        const rest = /^\s+--\s+(.*?)\s*$/.exec(m[2]);
        if (!rest) w.problems.push('the reason follows ` -- ` after the rule id');
        else {
          const g = /\s*\[gap:\s*(FG-\d+)\]\s*$/.exec(rest[1]);
          w.gap = g ? g[1] : null;
          w.reason = (g ? rest[1].slice(0, g.index) : rest[1]).trim();
          if (/\[gap:/.test(w.reason)) w.problems.push('the gap token is `[gap: FG-<n>]` at the end of the line');
          if (w.reason.length < 15) w.problems.push(`the reason "${w.reason}" is shorter than 15 characters`);
          else if (STOCK.test(w.reason)) w.problems.push(`the reason "${w.reason}" is a stock word, not the obstacle`);
        }
      }
      w.valid = w.problems.length === 0;
      waivers.push(w);
    } else if (/^\s*framework-gap\s*:/.test(v)) {
      const m = /^\s*framework-gap:\s*(FG-\d+)\s*$/.exec(v);
      citations.push({ line, row: m ? m[1] : null, problems: m ? [] : ['a citation is `// framework-gap: FG-<n>` and nothing else'], ownLine: ownLine(lines, c) });
    }
  }
  return { waivers, citations };
}

/** Lines of the contiguous comment block directly above `line` (comment-only lines). */
export function blockAbove(line, commentOnlyLines) {
  const out = [];
  for (let l = line - 1; l > 0 && commentOnlyLines.has(l); l--) out.push(l);
  return out;
}

/** A backticked method in a register cell: `page.on('console' | 'pageerror')`, `context.cookies`, `addCookies`. */
function parseMethod(s) {
  const m = /^(?:(\w+)\.)?([\w$]+)(?:\((.*)\))?$/.exec(s.trim());
  if (!m) return null;
  const args = m[3] ? [...m[3].matchAll(/'([^']+)'|"([^"]+)"/g)].map((x) => x[1] || x[2]) : undefined;
  return { recv: m[1] || undefined, method: m[2], args: args && args.length ? args : undefined };
}

/** The project's register rows, or the seed rows when it has none. */
export function readRegister(root) {
  const abs = path.join(root, REGISTER);
  if (!existsSync(abs)) return { file: null, rows: SEED_ROWS };
  const lines = readFileSync(abs, 'utf8').split(/\r?\n/);
  const rows = [];
  let cols = null;
  lines.forEach((raw, i) => {
    const l = raw.replace(/<!--.*?-->/g, '').trim();
    if (!l.startsWith('|')) { cols = null; return; }
    const cells = l.replace(/^\|/, '').replace(/\|$/, '').split('|').map((c) => c.trim());
    if (!cols) {
      if (cells.some((c) => /^row$/i.test(c))) cols = cells.map((c) => c.toLowerCase());
      return;
    }
    if (cells.every((c) => /^:?-+:?$/.test(c))) return;
    const cell = (name) => { const j = cols.findIndex((c) => c.startsWith(name)); return j === -1 ? '' : cells[j] || ''; };
    const id = cell('row');
    if (!/^FG-\d+$/.test(id)) return;
    const methods = [...cell('raw methods').matchAll(/`([^`]+)`/g)].map((m) => parseMethod(m[1])).filter(Boolean);
    const capText = cell('waiver cap');
    const status = cell('status').toLowerCase();
    rows.push({ id, methods, cap: /^\d+$/.test(capText) ? Number(capText) : null, status: status || 'open', fixedIn: /^fixed-in\b/.test(status), line: i + 1 });
  });
  return { file: REGISTER, rows };
}
