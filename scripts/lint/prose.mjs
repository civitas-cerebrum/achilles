import { readFileSync } from 'node:fs';
import { walk, SKILLS_DIR } from './util.mjs';

const MANDATE_LEDGER = 'hooks/data/achilles-qa.kernel-mandate.md';
const MAX_DASHES_PER_100_LINES = 30;
const MIN_LINES = 40;
const TELLS = /\b(genuinely|robust\w*|seamless\w*|comprehensive|it'?s worth noting|stated plainly)\b/gi;

// Check 14 — prose stays terse: em dashes per 100 lines are capped per file,
// and a short list of stock phrases is banned.
export function run(report) {
  const files = [...walk(SKILLS_DIR, (f) => f.endsWith('.md')), MANDATE_LEDGER];
  const dense = [];
  const tells = [];
  for (const file of files) {
    const text = readFileSync(file, 'utf8');
    const lines = text.split('\n');
    const dashes = text.split('—').length - 1;
    if (lines.length >= MIN_LINES && dashes * 100 > MAX_DASHES_PER_100_LINES * lines.length) {
      dense.push(`${file}: ${dashes} em dashes in ${lines.length} lines (max ${MAX_DASHES_PER_100_LINES} per 100)`);
    }
    lines.forEach((line, i) => {
      for (const m of line.matchAll(TELLS)) tells.push(`${file}:${i + 1}: "${m[0]}"`);
    });
  }
  report(
    `em-dash density <= ${MAX_DASHES_PER_100_LINES} per 100 lines (${files.length} files)`,
    dense.length === 0,
    dense,
  );
  report('banned phrases absent (genuinely, robust, seamless, comprehensive, "it\'s worth noting", "stated plainly")', tells.length === 0, tells);
}
