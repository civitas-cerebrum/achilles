import { readFileSync } from 'node:fs';

const RETURN_SCHEMA = 'skills/achilles-protocol/references/subagent-return-schema.md';
const ROLE_MAP = 'hooks/lib/schema-role-map.sh';

// Check 4 — validated §4.4 prefixes ↔ schema-role-map.sh cases
export function run(report) {
  const detail = [];
  const md = readFileSync(RETURN_SCHEMA, 'utf8').split('\n');

  // Isolate the §4.4 routing table.
  let in44 = false;
  const rows = [];
  for (const line of md) {
    if (/^###\s+4\.4\b/.test(line)) { in44 = true; continue; }
    if (in44 && /^###\s+4\.5\b/.test(line)) break;
    if (in44 && /^\|/.test(line)) rows.push(line);
  }

  // Each data row: | `<prefix>` | <validation target> |. A row is
  // "validated" unless its target says "Silent allow" / "no validation".
  // We derive the literal stem of the prefix (text up to the first `<` or
  // `:`), then assert a matching `case` exists in schema-role-map.sh.
  const validatedStems = [];
  for (const row of rows) {
    const cells = row.split('|').map((c) => c.trim());
    // cells[0] === '' (leading pipe), cells[1] = prefix cell, cells[2] = target.
    if (cells.length < 3) continue;
    const prefixCell = cells[1];
    const target = cells[2];
    if (/^-+$/.test(prefixCell) || /Description prefix/i.test(prefixCell)) continue; // header/sep
    if (/silent allow|no validation|envelope-sanity/i.test(target)) continue; // unvalidated rows
    // A prefix cell can contain several `…` literals (e.g. "phase1- / stage2-").
    const literals = [...prefixCell.matchAll(/`([^`]+)`/g)].map((m) => m[1]);
    for (const lit of literals) {
      // Stem = text before the first '<' or ':'.
      const stem = lit.split(/[<:]/)[0];
      if (stem) validatedStems.push(stem);
    }
  }

  // Extract the case-glob stems from schema-role-map.sh. Handles single
  // globs (`composer-*)`) and alternation lines that pack several globs
  // onto one case label (`process-validator-*|phase1-*|cleanup-*)`).
  const sh = readFileSync(ROLE_MAP, 'utf8');
  const caseStems = [];
  for (const m of sh.matchAll(/^\s*([a-z0-9-]+\*(?:\|[a-z0-9-]+\*)*)\)/gm)) {
    for (const glob of m[1].split('|')) {
      const stem = glob.replace(/\*$/, '');
      if (stem) caseStems.push(stem);
    }
  }

  const uncovered = [];
  for (const stem of [...new Set(validatedStems)]) {
    // A stem is covered if any case-glob is a prefix of it (case globs
    // anchor at string start: e.g. "composer-" covers "composer-").
    const covered = caseStems.some((cs) => stem.startsWith(cs));
    if (!covered) uncovered.push(stem);
  }

  if (uncovered.length) {
    detail.push(`§4.4 validated prefixes with no schema-role-map.sh case: ${uncovered.join(', ')}`);
  }

  report(
    `subagent-return-schema.md §4.4 validated prefixes ↔ schema-role-map.sh (${new Set(validatedStems).size} validated prefixes, ${caseStems.length} cases)`,
    uncovered.length === 0,
    detail,
  );
}
