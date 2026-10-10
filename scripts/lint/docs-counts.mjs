import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { SKILLS_DIR } from './util.mjs';

const DOCS_DIR = 'docs';

// Check 6 — hand-written counts in docs/*.html  ↔  the filesystem
// The published pages quote concrete figures ("37 hooks ship with the
// package — 28 are enforcement gates", "24 Agent Skills"). Nothing else in
// this lint reads docs/, so without this check the figures drift silently. Each pattern below captures the number the page claims; the
// check asserts it equals the number on disk.
export function run(report) {
  const detail = [];
  if (!existsSync(DOCS_DIR)) {
    report('docs/*.html hand-written counts ↔ filesystem (docs/ absent)', true, []);
    return;
  }

  const factoryFiles = existsSync('hooks/factory') ? readdirSync('hooks/factory').filter((f) => f.endsWith('.sh')) : [];
  const hookFiles = [...readdirSync('hooks').filter((f) => f.endsWith('.sh')), ...factoryFiles];
  const gateFiles = hookFiles.filter((f) => f.endsWith('-gate.sh') || f.endsWith('-guard.sh'));
  const skillDirs = readdirSync(SKILLS_DIR).filter((d) => statSync(join(SKILLS_DIR, d)).isDirectory());

  // [ human label, actual value, /regex with one capturing group for the number/ ]
  const RULES = [
    ['hook scripts', hookFiles.length, /(\d+)\s+hooks?\s+ship with the package/g],
    ['hook scripts', hookFiles.length, /(\d+)\+?\s+hook scripts/g],
    ['enforcement gates', gateFiles.length, /(\d+)\s+are enforcement gates/g],
    ['enforcement gates', gateFiles.length, /The\s+(\d+)\s+enforcement gates/g],
    ['enforcement gates', gateFiles.length, /\((\d+)\+?\s+enforcement gates\)/g],
    ['agent skills', skillDirs.length, /(\d+)\s+Agent Skills/g],
  ];

  let asserted = 0;
  const pages = readdirSync(DOCS_DIR).filter((f) => f.endsWith('.html'));
  for (const page of pages) {
    const html = readFileSync(join(DOCS_DIR, page), 'utf8');
    for (const [label, actual, re] of RULES) {
      for (const m of html.matchAll(re)) {
        asserted += 1;
        if (Number(m[1]) !== actual) {
          detail.push(`docs/${page}: claims ${m[1]} ${label}, filesystem has ${actual} — "${m[0]}"`);
        }
      }
    }
  }

  report(
    `docs/*.html hand-written counts ↔ filesystem (${asserted} figures across ${pages.length} pages)`,
    detail.length === 0,
    detail,
  );
}
