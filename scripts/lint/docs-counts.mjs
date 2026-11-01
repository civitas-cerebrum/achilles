import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { HARNESS_DOC, AGENT_ROLES, skillDirs } from './util.mjs';

const DOCS_DIR = 'docs';

// Check 6 — hand-written counts in docs/*.html ↔ the tree.
// The pages quote figures ("8 hooks", "5 agents", "17 Agent Skills"). Skills
// are counted from the filesystem; hooks from the hook table in
// docs/harness/claude-code.md (one row per hook, the adapter's contract);
// agents from util.mjs. Each pattern captures the number the page claims.
export function run(report) {
  const detail = [];
  if (!existsSync(DOCS_DIR)) { report('docs/*.html hand-written counts ↔ tree (docs/ absent)', true, []); return; }

  const skills = skillDirs().length;
  const harness = existsSync(HARNESS_DOC) ? readFileSync(HARNESS_DOC, 'utf8') : '';
  const hooks = (harness.match(/^\| \d+ \| [^|]+ \| /gm) || []).length;

  const RULES = [
    ['agent skills', skills, /(\d+)\s+Agent Skills/g],
    ['agent skills', skills, /(\d+)\s+skills? under/g],
    ['hooks', hooks, /(\d+)\s+hooks?\b(?! scripts)/g],
    ['hooks', hooks, /(\d+)\s+hook scripts/g],
    ['agents', AGENT_ROLES.length, /(\d+)\s+(?:hand-authored )?agents\b/g],
  ];

  let asserted = 0;
  const pages = readdirSync(DOCS_DIR).filter((f) => f.endsWith('.html'));
  for (const page of pages) {
    const html = readFileSync(join(DOCS_DIR, page), 'utf8');
    for (const [label, actual, re] of RULES) {
      for (const m of html.matchAll(re)) {
        asserted++;
        if (Number(m[1]) !== actual) detail.push(`docs/${page}: claims ${m[1]} ${label}, tree has ${actual} — "${m[0]}"`);
      }
    }
  }
  report(`docs/*.html hand-written counts ↔ tree (${asserted} figures across ${pages.length} pages; ${hooks} hooks in ${HARNESS_DOC})`, detail.length === 0, detail);
}
