import { existsSync, readFileSync } from 'node:fs';
import { ADAPTER_DIR, HARNESS_DOC, walk } from './util.mjs';

// Check 8 — env switches read by the adapter and the CLIs ↔ the first switches
// table in docs/harness/claude-code.md (the second table lists switches that
// arrive with the hook port and is not compared). A switch the code reads with
// no row is undocumented behaviour. Sources: claude-code/** (when present),
// bin/**, scripts/**, reporter/**; reads are `process.env.X`, `process.env['X']`
// `env.X` on a destructured environment object, and a switch name passed as a
// string literal to an env helper (`int('ACHILLES_HISTORY_RUNS', …)`).
const SWITCH_SHAPE = /^(ACHILLES_|CIVITAS_|FACTORY_|SPEND_|PLAYWRIGHT_SKIP_)/;
const TEST_ONLY = /^(FACTORY_JQ|FACTORY_NODE|FACTORY_SCHEMA|ACHILLES_SESSION_STATE_DIR|ACHILLES_JUDGE_STATE_DIR)$/;

export function run(report) {
  const detail = [];
  const sources = [
    ...walk(ADAPTER_DIR, (p) => /\.(ts|js|mjs|cjs)$/.test(p) && !p.includes('/node_modules/') && !p.includes('/tests/')),
    ...walk('bin', (p) => /\.(js|mjs|cjs)$/.test(p)),
    // scripts/install/ keeps only chromium.js in 0.3.0; the other install scripts leave with the bash runtime.
    ...walk('scripts', (p) => /\.(js|mjs)$/.test(p) && !p.includes('/lint') && (!p.includes('/install/') || p.endsWith('/chromium.js'))),
    ...walk('reporter', (p) => /\.(js|mjs|cjs)$/.test(p) && !p.includes('/tests/')),
  ];
  const names = new Set();
  for (const f of sources) {
    const text = readFileSync(f, 'utf8');
    for (const m of text.matchAll(/(?:process\.env|\benv)(?:\.([A-Z][A-Z0-9_]*)|\[['"]([A-Z][A-Z0-9_]*)['"]\])/g)) {
      const n = m[1] || m[2];
      if (SWITCH_SHAPE.test(n) && !TEST_ONLY.test(n)) names.add(n);
    }
    for (const m of text.matchAll(/['"]((?:ACHILLES|CIVITAS|FACTORY|SPEND|PLAYWRIGHT_SKIP)_[A-Z0-9_]+)['"]/g)) {
      if (!TEST_ONLY.test(m[1])) names.add(m[1]);
    }
  }
  const whole = existsSync(HARNESS_DOC) ? readFileSync(HARNESS_DOC, 'utf8') : '';
  if (!whole) detail.push(`${HARNESS_DOC} is missing`);
  // Only the first table (shipped switches) counts; the hook-port table follows the 'Arrives with the hook port' line.
  const doc = whole.split(/^Arrives with the hook port/m)[0];
  const missing = [...names].filter((n) => !doc.includes('`' + n)).sort();
  if (missing.length) detail.push(`switches read in code with no row in ${HARNESS_DOC}: ${missing.join(', ')}`);
  const note = existsSync(ADAPTER_DIR) ? '' : ' (claude-code/ absent in this checkout; CLIs only)';
  report(`env switches read in code ↔ ${HARNESS_DOC} (${names.size} switches read)${note}`, detail.length === 0, detail);
}
