import { readFileSync, existsSync } from 'node:fs';
import { dirname, join, normalize } from 'node:path';
import { walk, SKILLS_DIR } from './util.mjs';

// Check 11 — every `<path> §"Heading"` citation in hooks, hook libs and skills
// names a heading that exists in the cited file. In Markdown a heading is
// `#… Heading` or a bold lead-in `**Heading.**`, ignoring symbols, a section number or `Pattern:` before the first letter
// and a trailing `{#anchor}`; in a test case it is a `section "Heading"` line. A citation may
// be a prefix of the heading up to a delimiter (`§"Mode selection"` cites
// `## Mode selection (the orchestrator decides)`). The path is resolved
// repo-relative or citing-file-relative, else by unique tail (`references/x.md`
// from a sibling skill); any file it resolves to may hold the heading.
const CITATION = /([\w./-]+\.(?:md|sh|json))[\s`)*(#>]*§"([^"]+)"/g;

const headingsCache = new Map();
function headingsOf(file) {
  if (!headingsCache.has(file)) {
    const out = [];
    for (const line of readFileSync(file, 'utf8').split('\n')) {
      const m = line.match(/^(?:- |\d+\. )?\*\*(.+?)[.:]?\*\*/) ?? line.match(/^#+\s+(?:[^\p{L}\p{N}\s`*"'(]+\s*|\d+(?:\.\d+)*\.?\s+|Pattern:\s+)*(.*?)\s*(?:\{#[^}]*\})?\s*$/u) ?? line.match(/^section "(.*)"\s*$/);
      if (m) out.push(m[1].replace(/`/g, ''));
    }
    headingsCache.set(file, out);
  }
  return headingsCache.get(file);
}

function matches(heading, cited) {
  return heading === cited || (heading.startsWith(cited) && /^[\s—:(,.-]/.test(heading.slice(cited.length)));
}

export function run(report) {
  const detail = [];
  const sources = [
    ...walk('hooks', (p) => p.endsWith('.sh') && !p.includes('/tests/')),
    ...walk(SKILLS_DIR, (p) => p.endsWith('.md')),
  ];
  const known = [...walk('hooks', () => true), ...walk(SKILLS_DIR, () => true), ...walk('docs', () => true)];
  let checked = 0;

  for (const file of sources) {
    const text = readFileSync(file, 'utf8');
    for (const m of text.matchAll(CITATION)) {
      const [, cited, raw] = m;
      if (cited.startsWith('/')) continue; // `<skill>/SKILL.md` placeholder tail
      const heading = raw.replace(/\s*\n\s*#?\s*/g, ' ').replace(/`/g, '').replace(/^Pattern:\s+/, '');
      const direct = [normalize(cited), normalize(join(dirname(file), cited))].filter((p) => existsSync(p));
      const tail = cited.replace(/^(?:\.{0,2}\/)+/, '');
      const targets = direct.length ? direct : known.filter((p) => p.endsWith('/' + tail));
      checked++;
      const where = `${file}:${text.slice(0, m.index).split('\n').length}`;
      if (!targets.length) detail.push(`${where}: cited file not found: ${cited} §"${heading}"`);
      else if (!targets.some((t) => headingsOf(t).some((h) => matches(h, heading)))) detail.push(`${where}: no heading "${heading}" in ${cited}`);
    }
  }

  report(`cited §"Heading" anchors resolve (${checked} citations)`, detail.length === 0, detail);
}
