import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { SKILLS_DIR } from './util.mjs';

const REGISTRY = 'skills/achilles-protocol/references/skill-registry.md';

// Check 1 — skill-registry table  ↔  skills/*/ directories (bijection)
export function run(report) {
  const detail = [];
  const md = readFileSync(REGISTRY, 'utf8').split('\n');

  // Parse the registry table: rows between "## Registry" and the next "##".
  const registrySkills = new Set();
  let inRegistry = false;
  for (const line of md) {
    if (/^## Registry\b/.test(line)) { inRegistry = true; continue; }
    if (inRegistry && /^##\s/.test(line)) break;
    if (!inRegistry) continue;
    // Table rows start with "| `skill-name` |". Skip header/separator rows.
    const m = line.match(/^\|\s*`([^`]+)`\s*\|/);
    if (m) registrySkills.add(m[1]);
  }

  const dirSkills = new Set(
    readdirSync(SKILLS_DIR).filter((n) => {
      try { return statSync(join(SKILLS_DIR, n)).isDirectory(); }
      catch { return false; }
    }),
  );

  const missingDirs = [...registrySkills].filter((s) => !dirSkills.has(s));
  const missingRows = [...dirSkills].filter((s) => !registrySkills.has(s));

  if (missingDirs.length) detail.push(`in registry but no skills/<name>/ dir: ${missingDirs.join(', ')}`);
  if (missingRows.length) detail.push(`skills/<name>/ dir but no registry row: ${missingRows.join(', ')}`);

  report(
    `skill-registry.md ↔ skills/*/ bijection (${registrySkills.size} registry rows, ${dirSkills.size} dirs)`,
    missingDirs.length === 0 && missingRows.length === 0,
    detail,
  );
}
