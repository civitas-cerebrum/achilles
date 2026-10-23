import { readFileSync, readdirSync } from 'node:fs';

const ACTIVATION_LIB = 'hooks/lib/dispatch-prefix.sh';

export function run(report) {
  const src = readFileSync(ACTIVATION_LIB, 'utf8');
  const m = src.match(/^ACHILLES_SKILL_ALT='([^']+)'/m);
  const alt = new Set(m ? m[1].split('|') : []);
  const dirs = readdirSync('skills', { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name);
  const missing = dirs.filter((d) => !alt.has(d)).sort();
  report(`skills/*/ ↔ ACHILLES_SKILL_ALT (${dirs.length} skills)`,
    Boolean(m) && missing.length === 0,
    [...(!m ? [`ACHILLES_SKILL_ALT not found in ${ACTIVATION_LIB}`] : []), ...(missing.length ? [`skills that activate nothing: ${missing.join(', ')}`] : [])]);
}
