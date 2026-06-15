#!/usr/bin/env node
// lint-doc-drift.mjs — fails the publish (prepack) when the human-authored
// doc surfaces drift out of sync with the machine-authoritative sources they
// describe. Four independent checks; each reports pass/fail; the process
// exits non-zero if any check fails.
//
//   (1) skill-registry table  ↔  skills/*/ directories          (bijection)
//   (2) every relative .md link under skills/element-interactions/** resolves
//   (3) HOOK_MANIFEST (scripts/postinstall.js)  ↔  harness-hooks.md links
//   (4) every validated §4.4 description-prefix in subagent-return-schema.md
//       has a matching case in hooks/lib/schema-role-map.sh
//
// The lint is authored to the FINAL intended state of the surfaces other
// packages touch in parallel; where a surface has not yet converged it
// reports the specific drift rather than weakening the check.

import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';

const SKILLS_DIR = 'skills';
const EI_DIR = 'skills/element-interactions';
const REGISTRY = 'skills/element-interactions/references/skill-registry.md';
const HARNESS_HOOKS = 'skills/element-interactions/references/harness-hooks.md';
const POSTINSTALL = 'scripts/postinstall.js';
const RETURN_SCHEMA = 'skills/element-interactions/references/subagent-return-schema.md';
const ROLE_MAP = 'hooks/lib/schema-role-map.sh';

let anyFail = false;

function report(check, ok, detail) {
  const tag = ok ? 'PASS' : 'FAIL';
  console.log(`[${tag}] ${check}`);
  if (!ok) {
    anyFail = true;
    for (const line of detail) console.log(`        ${line}`);
  }
}

// Recursively collect files matching a predicate under a root dir.
function walk(root, pred, acc = []) {
  for (const name of readdirSync(root)) {
    const full = join(root, name);
    const st = statSync(full);
    if (st.isDirectory()) walk(full, pred, acc);
    else if (pred(full)) acc.push(full);
  }
  return acc;
}

// ---------------------------------------------------------------------------
// Check 1 — skill-registry table  ↔  skills/*/ directories (bijection)
// ---------------------------------------------------------------------------
function checkRegistryBijection() {
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

// ---------------------------------------------------------------------------
// Check 2 — relative .md links under skills/element-interactions/** resolve
// ---------------------------------------------------------------------------
function checkRelativeLinks() {
  const detail = [];
  const mdFiles = walk(EI_DIR, (f) => f.endsWith('.md'));
  // Markdown link target: ](path) — capture path, strip any #anchor.
  const linkRe = /\]\(([^)]+)\)/g;
  let checked = 0;

  for (const file of mdFiles) {
    const text = readFileSync(file, 'utf8');
    let m;
    while ((m = linkRe.exec(text)) !== null) {
      let target = m[1].trim();
      // Skip absolute URLs, anchors-only, and mailto.
      if (/^[a-z][a-z0-9+.-]*:\/\//i.test(target)) continue;
      if (target.startsWith('#')) continue;
      if (target.startsWith('mailto:')) continue;
      // Strip anchor fragment.
      const hash = target.indexOf('#');
      if (hash !== -1) target = target.slice(0, hash);
      if (target === '') continue;
      // Only validate relative links that point at a .md file.
      if (!target.endsWith('.md')) continue;
      checked++;
      const resolved = resolve(dirname(file), target);
      if (!existsSync(resolved)) {
        detail.push(`${file}: dead link → ${m[1]}`);
      }
    }
  }

  report(
    `skills/element-interactions/** relative .md links resolve (${checked} links across ${mdFiles.length} files)`,
    detail.length === 0,
    detail,
  );
}

// ---------------------------------------------------------------------------
// Check 3 — HOOK_MANIFEST  ↔  harness-hooks.md (both ways)
// ---------------------------------------------------------------------------
function checkHookManifest() {
  const detail = [];
  const post = readFileSync(POSTINSTALL, 'utf8');

  // Extract the HOOK_MANIFEST array body and pull each `file: '<name>.sh'`.
  const start = post.indexOf('const HOOK_MANIFEST = [');
  const end = post.indexOf('];', start);
  const body = post.slice(start, end);
  const manifestFiles = new Set(
    [...body.matchAll(/file:\s*'([a-z0-9-]+\.sh)'/g)].map((m) => m[1]),
  );

  // Documented hooks = markdown links of the form (.../hooks/<file>.sh).
  // Exclude hooks/lib/* (those are library files cited in prose, not
  // registered hooks).
  const hooksMd = readFileSync(HARNESS_HOOKS, 'utf8');
  const documented = new Set(
    [...hooksMd.matchAll(/\((?:\.\.\/)+hooks\/([a-z0-9-]+\.sh)\)/g)].map((m) => m[1]),
  );

  const undocumented = [...manifestFiles].filter((f) => !documented.has(f));
  const orphanDocs = [...documented].filter((f) => !manifestFiles.has(f));

  if (undocumented.length) detail.push(`in HOOK_MANIFEST but not documented in harness-hooks.md: ${undocumented.join(', ')}`);
  if (orphanDocs.length) detail.push(`documented in harness-hooks.md but not in HOOK_MANIFEST: ${orphanDocs.join(', ')}`);

  report(
    `HOOK_MANIFEST ↔ harness-hooks.md (${manifestFiles.size} manifest hooks, ${documented.size} documented)`,
    undocumented.length === 0 && orphanDocs.length === 0,
    detail,
  );
}

// ---------------------------------------------------------------------------
// Check 4 — validated §4.4 prefixes ↔ schema-role-map.sh cases
// ---------------------------------------------------------------------------
function checkRoleMapCoverage() {
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

checkRegistryBijection();
checkRelativeLinks();
checkHookManifest();
checkRoleMapCoverage();

if (anyFail) {
  console.error('\nlint-doc-drift: drift detected (see [FAIL] lines above).');
  process.exit(1);
}
console.log('\nlint-doc-drift: all checks passed.');
