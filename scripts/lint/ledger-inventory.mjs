import { readFileSync } from 'node:fs';

const QA_MANDATE = 'hooks/data/achilles-qa.kernel-mandate.json';
const QA_LEDGER = 'hooks/data/achilles-qa.kernel-mandate.md';

// Check 7 — QA role ledger's role inventory ↔ QA mandate's roles
// The ledger (hooks/data/achilles-qa.kernel-mandate.md) is the human copy of
// the mandate (…kernel-mandate.json). Achilles vendors the kernel runtime,
// not the `kernel-mandate doc` renderer, so the ledger is hand-maintained and
// this is what holds its inventory to the manifest.
//
// Only the INVENTORY is comparable without the renderer: which roles exist,
// and how many the ledger says there are. Both files state that three times
// over — the manifest's `roles` keys, the ledger's "Roles at a glance" rows,
// and the ledger's one "### `<role>`" section per role — plus the count the
// ledger asserts in prose. The per-role GRANTS are not compared: reproducing
// how the renderer phrases a scope is not something a lint can claim to know.
// The ledger's cross-product sections (handovers, flowchart, review loops)
// are labelled in place as an unregenerated snapshot for the same reason.
export function run(report) {
  const detail = [];
  const mandate = JSON.parse(readFileSync(QA_MANDATE, 'utf8'));
  const manifestRoles = new Set(Object.keys(mandate.roles ?? {}));

  const ledger = readFileSync(QA_LEDGER, 'utf8');
  const md = ledger.split('\n');

  // Rows of the "Roles at a glance" table: "| **<role>** | …" (the main
  // session row carries a "<br>*(main session)*" suffix inside the bold).
  const tableRoles = new Set();
  // One section per role: "### `<role>`" under "## Each role, …".
  const sectionRoles = new Set();
  let region = null;
  for (const line of md) {
    if (/^## Roles at a glance\b/.test(line)) { region = 'table'; continue; }
    if (/^## Each role\b/.test(line)) { region = 'sections'; continue; }
    if (region && /^##\s/.test(line)) { region = null; continue; }
    if (region === 'table') {
      const m = line.match(/^\|\s*\*\*([a-z0-9-]+)\*\*/);
      if (m) tableRoles.add(m[1]);
    } else if (region === 'sections') {
      const m = line.match(/^###\s+`([a-z0-9-]+)`/);
      if (m) sectionRoles.add(m[1]);
    }
  }

  const missing = (a, b) => [...a].filter((x) => !b.has(x)).sort();
  const noRow = missing(manifestRoles, tableRoles);
  const orphanRow = missing(tableRoles, manifestRoles);
  const noSection = missing(manifestRoles, sectionRoles);
  const orphanSection = missing(sectionRoles, manifestRoles);

  if (noRow.length) detail.push(`in the mandate but no "Roles at a glance" row in the ledger: ${noRow.join(', ')}`);
  if (orphanRow.length) detail.push(`a "Roles at a glance" row with no role in the mandate: ${orphanRow.join(', ')}`);
  if (noSection.length) detail.push(`in the mandate but no "### \`<role>\`" section in the ledger: ${noSection.join(', ')}`);
  if (orphanSection.length) detail.push(`a "### \`<role>\`" section with no role in the mandate: ${orphanSection.join(', ')}`);

  // The count the ledger states in prose ("… **20 roles**, each with its own
  // tools …"). A ledger that lists the right roles and miscounts them aloud
  // is still wrong about the thing a reader takes away.
  const stated = ledger.match(/\*\*(\d+) roles\*\*/);
  if (!stated) detail.push('the ledger states no "**<n> roles**" count — the prose assertion this check pins is gone');
  else if (Number(stated[1]) !== manifestRoles.size) {
    detail.push(`the ledger says "**${stated[1]} roles**" but the mandate declares ${manifestRoles.size}`);
  }

  report(
    `achilles-qa role ledger ↔ mandate role inventory (${manifestRoles.size} mandate roles, ${tableRoles.size} glance rows, ${sectionRoles.size} ledger sections)`,
    detail.length === 0,
    detail,
  );
}
