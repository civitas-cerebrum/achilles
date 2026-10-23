import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { AGENTS_DIR, AGENT_ROLES, HARNESS_DOC, frontmatterName } from './util.mjs';

// Check 10 — agents/*.md ↔ the five roles, and ↔ the Agents table.
// Exactly one hand-authored definition per role, frontmatter `name` equal to
// the file name, no extra files (a leftover generated role file would be
// registered by the adapter). The Tools column of the "Agents and scopes"
// table in docs/harness/claude-code.md must list exactly each agent's
// frontmatter `tools` (order-insensitive), so the doc cannot drift from the
// definitions. When agents/ is absent this checkout predates the adapter
// slice; say so and pass.

function frontmatterTools(file) {
  const fm = readFileSync(file, 'utf8').match(/^---\n([\s\S]*?)\n---/);
  if (!fm) return null;
  const m = fm[1].match(/^tools:\s*(.*)$/m);
  if (!m) return null;
  return m[1].replace(/^\[|\]$/g, '').split(',').map((s) => s.trim()).filter(Boolean);
}

function tableTools() {
  if (!existsSync(HARNESS_DOC)) return null;
  const text = readFileSync(HARNESS_DOC, 'utf8');
  const section = text.split(/^## /m).find((s) => s.startsWith('Agents and scopes'));
  if (!section) return null;
  const rows = new Map();
  for (const line of section.split('\n')) {
    const m = line.match(/^\| `(achilles-[a-z-]+)` \| ([^|]+) \|/);
    if (m) rows.set(m[1], m[2].split(',').map((s) => s.trim()).filter(Boolean));
  }
  return rows;
}

const same = (a, b) => a.length === b.length && [...a].sort().join(',') === [...b].sort().join(',');

export function run(report) {
  if (!existsSync(AGENTS_DIR)) {
    report(`agents/*.md ↔ roles (agents/ absent in this checkout; written by the adapter slice)`, true, []);
    return;
  }
  const detail = [];
  const files = readdirSync(AGENTS_DIR).filter((f) => f.endsWith('.md'));
  const names = files.map((f) => f.replace(/\.md$/, ''));
  for (const r of AGENT_ROLES) if (!names.includes(r)) detail.push(`agents/${r}.md is missing`);
  for (const n of names) {
    if (!AGENT_ROLES.includes(n)) detail.push(`agents/${n}.md is not one of the five roles`);
    const fm = frontmatterName(join(AGENTS_DIR, `${n}.md`));
    if (fm !== n && fm !== null) detail.push(`agents/${n}.md frontmatter name is "${fm}"`);
  }
  report(`agents/*.md ↔ roles (${files.length} files)`, detail.length === 0, detail);

  const table = tableTools();
  const tdetail = [];
  if (!table) {
    tdetail.push(`${HARNESS_DOC} has no "## Agents and scopes" table`);
  } else {
    for (const n of names.filter((x) => AGENT_ROLES.includes(x))) {
      const fmTools = frontmatterTools(join(AGENTS_DIR, `${n}.md`));
      const row = table.get(n);
      if (!fmTools) { tdetail.push(`agents/${n}.md has no tools: line`); continue; }
      if (!row) { tdetail.push(`${HARNESS_DOC}: no Agents-table row for \`${n}\``); continue; }
      if (!same(fmTools, row)) tdetail.push(`${n}: table lists "${row.join(', ')}", frontmatter has "${fmTools.join(', ')}"`);
    }
    for (const n of table.keys()) if (!names.includes(n)) tdetail.push(`${HARNESS_DOC}: Agents-table row \`${n}\` has no agents/${n}.md`);
  }
  report(`agents/*.md tools ↔ ${HARNESS_DOC} Agents table (${table ? table.size : 0} rows)`, tdetail.length === 0, tdetail);
}
