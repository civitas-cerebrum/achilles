#!/usr/bin/env node
// lint-doc-drift.mjs — fails the publish (prepack) when the human-authored
// doc surfaces drift out of sync with the machine-authoritative sources they
// describe. Ten independent checks; each reports pass/fail; the process
// exits non-zero if any check fails.
//
//   (1) skill-registry table  ↔  skills/*/ directories          (bijection)
//   (2) every relative .md link under skills/achilles-protocol/** resolves
//   (3) HOOK_MANIFEST (scripts/postinstall.js)  ↔  harness-hooks.md links
//   (4) every validated §4.4 description-prefix in subagent-return-schema.md
//       has a matching case in hooks/lib/schema-role-map.sh
//   (5) every deny/warn-capable hook's runtime messages carry a References:
//       block citing >=1 resolvable skills/ (or schemas/) path — the
//       methodology-pointer convention (contributing-to-achilles-protocol
//       SKILL.md §"Hook error message format — repo standard")
//   (6) hand-written hook / gate / skill counts in docs/*.html  ↔  the
//       filesystem (hooks/*.sh, hooks/*-gate.sh + *-guard.sh, skills/*/)
//   (7) the QA role ledger's role inventory  ↔  the QA mandate's roles
//       (role-name sets both ways, plus the count the ledger states in prose)
//   (8) every environment switch a hook or script reads  ↔  a row in opt-in-surfaces.md
//   (9) the QA workflow table  ↔  the QA mandate (scopes, imports, env, skills, dispatch, commands)
//   (10) skills/*/ directories  ↔  ACHILLES_SKILL_ALT (every skill activates the protocol)
//
// The lint is authored to the FINAL intended state of the surfaces other
// packages touch in parallel; where a surface has not yet converged it
// reports the specific drift rather than weakening the check.

import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';

const SKILLS_DIR = 'skills';
const EI_DIR = 'skills/achilles-protocol';
const REGISTRY = 'skills/achilles-protocol/references/skill-registry.md';
const HARNESS_HOOKS = 'skills/achilles-protocol/references/harness-hooks.md';
const POSTINSTALL = 'scripts/postinstall.js';
const RETURN_SCHEMA = 'skills/achilles-protocol/references/subagent-return-schema.md';
const ROLE_MAP = 'hooks/lib/schema-role-map.sh';
const DOCS_DIR = 'docs';
const QA_MANDATE = 'hooks/data/achilles-qa.kernel-mandate.json';
const QA_LEDGER = 'hooks/data/achilles-qa.kernel-mandate.md';

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
// Check 2 — relative .md links under skills/achilles-protocol/** resolve
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
    `skills/achilles-protocol/** relative .md links resolve (${checked} links across ${mdFiles.length} files)`,
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


// ---------------------------------------------------------------------------
// Check 5 — hook runtime messages carry resolvable methodology References
// ---------------------------------------------------------------------------
// Convention: contributing-to-achilles-protocol/SKILL.md §"Hook error message
// format — repo standard". Every hook that can emit a user-facing decision at
// runtime (PreToolUse deny/ask, systemMessage warn, Stop decision:block, or a
// strict-mode exit-2 stderr block) must end those messages with a
// `References:` block of repo-relative canonical-rule paths. Mechanics of the
// check: full-line comments are stripped first, so the header's
// "Canonical reference" section can never satisfy it — the References must
// live in the message-producing region (strings, heredocs, echo lines).
// Every cited skills/….md or schemas/….json path (in ANY hook, emitting or
// not — including the vendored kernel) must resolve in the repo, so a skill
// rename cannot silently orphan a hook's pointers.
function checkHookReferences() {
  const detail = [];
  // hooks/kernel-mandate-role-gate.sh is vendored verbatim from
  // @civitas-cerebrum/kernel-mandate, and the obvious justification for
  // exempting it is not available: nothing in this repo keeps it in sync.
  // That package appears in neither `dependencies` nor `devDependencies`,
  // so scripts/sync-kernel-mandate.mjs finds no canonical source, prints
  // "canonical source not found … — skipping" and exits 0 — under `--check`
  // too. An edit to the vendored bytes would not be overwritten by the next
  // sync; it would just never be noticed by anything.
  //
  // What survives is a narrower exemption, from the References requirement
  // alone. A `References:` block points at THIS repo's methodology
  // (skills/…/SKILL.md); the kernel's deny messages cite the kernel's own
  // docs, which is the right pointer for a file achilles does not author.
  // The wrapper that registers it, achilles-kernel-activation-gate.sh, IS
  // achilles' own and is held to the convention.
  //
  // The other half of the check still applies to the vendored file, which is
  // why it is no longer filtered out of the sweep entirely: every skills/ or
  // schemas/ path it cites must resolve here, so renaming a skill in this
  // repo cannot silently orphan the vendored kernel's pointers.
  const REFERENCES_EXEMPT = new Set(['hooks/kernel-mandate-role-gate.sh']);
  const hooks = readdirSync('hooks')
    .filter((f) => f.endsWith('.sh'))
    .map((f) => join('hooks', f));

  let emitters = 0;
  let citedPaths = 0;

  for (const h of hooks) {
    const raw = readFileSync(h, 'utf8');
    // Strip full-line comments: the message-producing region is what remains.
    const code = raw
      .split('\n')
      .filter((l) => !/^\s*#/.test(l))
      .join('\n');

    const pathMatches = [...code.matchAll(/(?:skills|schemas)\/[A-Za-z0-9._/-]+\.(?:md|json)/g)].map((m) => m[0]);
    for (const cited of new Set(pathMatches)) {
      citedPaths++;
      if (!existsSync(cited)) {
        detail.push(`${h}: cited path does not resolve: ${cited}`);
      }
    }

    if (REFERENCES_EXEMPT.has(h)) continue;

    const emits = /permissionDecision|"decision"\s*:\s*"block"|systemMessage|^exit 2$/m.test(code);
    if (!emits) continue;
    emitters++;

    if (!/References:/.test(code)) {
      detail.push(`${h}: emits deny/warn/block but its runtime messages have no References: block`);
      continue;
    }
    if (pathMatches.length === 0) {
      detail.push(`${h}: emits deny/warn/block but cites no skills/ or schemas/ path in its runtime messages`);
    }
  }

  report(
    `hook runtime messages carry resolvable methodology References (${emitters} emitting hooks, ${citedPaths} cited paths)`,
    detail.length === 0,
    detail,
  );
}

// ---------------------------------------------------------------------------
// Check 6 — hand-written counts in docs/*.html  ↔  the filesystem
// ---------------------------------------------------------------------------
// The published pages quote concrete figures ("37 hooks ship with the
// package — 28 are enforcement gates", "24 Agent Skills"). Nothing else in
// this lint reads docs/, so those figures drifted silently twice before this
// check existed. Each pattern below captures the number the page claims; the
// check asserts it equals the number on disk.
function checkDocsCounts() {
  const detail = [];
  if (!existsSync(DOCS_DIR)) {
    report('docs/*.html hand-written counts ↔ filesystem (docs/ absent)', true, []);
    return;
  }

  const hookFiles = readdirSync('hooks').filter((f) => f.endsWith('.sh'));
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

// ---------------------------------------------------------------------------
// Check 7 — QA role ledger's role inventory ↔ QA mandate's roles
// ---------------------------------------------------------------------------
// The ledger (hooks/data/achilles-qa.kernel-mandate.md) is the human copy of
// the mandate (…kernel-mandate.json). Upstream it is rendered by
// `kernel-mandate doc`, which ships in @civitas-cerebrum/kernel-mandate — a
// package this repo does not depend on, so scripts/sync-kernel-mandate.mjs
// resolves no canonical source and exits 0 without comparing anything. The
// ledger's inventory is therefore hand-maintained, and this is what keeps it
// honest.
//
// Only the INVENTORY is comparable without the renderer: which roles exist,
// and how many the ledger says there are. Both files state that three times
// over — the manifest's `roles` keys, the ledger's "Roles at a glance" rows,
// and the ledger's one "### `<role>`" section per role — plus the count the
// ledger asserts in prose. The per-role GRANTS are not compared: reproducing
// how the renderer phrases a scope is not something a lint can claim to know.
// The ledger's cross-product sections (handovers, flowchart, review loops)
// are labelled in place as an unregenerated snapshot for the same reason.
function checkRoleLedgerInventory() {
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
// ---------------------------------------------------------------------------
// Check 8 — every env switch read by hooks/scripts has a row in opt-in-surfaces.md
// ---------------------------------------------------------------------------
const OPT_IN_DOC = 'skills/achilles-protocol/references/opt-in-surfaces.md';
const KNOWN_LIMITS_DOC = 'skills/achilles-protocol/references/known-limits.md';
function checkOptInSurfaces() {
  const detail = [];
  const sources = [
    ...walk('hooks', (p) => /\.(sh|js|cjs|mjs)$/.test(p) && !p.includes('/tests/') && !/\.bundle\.m?js$/.test(p)),
    ...readdirSync('scripts').filter((f) => /\.(js|mjs)$/.test(f) && f !== 'lint-doc-drift.mjs').map((f) => join('scripts', f)),
  ];
  // Operator-facing switch names: project prefixes plus the *_GATE/_GUARD/_OVERRIDE
  // suffixes the gates use. Ordinary environment is excluded by the deny-list.
  const switchShape = /^(ACHILLES_|CIVITAS_|KERNEL_MANDATE|SCHEMA_RETURN_GUARD|DECK_INSPECTION_GATE|FAKE_|DISABLE_|SKIP_)|(_GATE|_GUARD|_OVERRIDE)$/;
  const ordinaryEnv = /^(HOME|PATH|TMPDIR|CLAUDE_.*|XDG_.*|PLAYWRIGHT_(?!SKIP_).*|PWD|USER|SHELL|LANG)$/;
  const readShapes = [
    /\$\{([A-Z][A-Z0-9_]*):?[-=?+]/g, // ${NAME:-default}: a read with a default is how hooks consume env; bare $NAME is also a local
    /process\.env\.([A-Z][A-Z0-9_]*)/g,
    /process\.env\[['"]([A-Z][A-Z0-9_]*)['"]\]/g,
  ];
  const names = new Set();
  for (const f of sources) {
    const text = readFileSync(f, 'utf8');
    for (const re of readShapes)
      for (const m of text.matchAll(re)) if (switchShape.test(m[1]) && !ordinaryEnv.test(m[1])) names.add(m[1]);
  }
  const doc = existsSync(OPT_IN_DOC) ? readFileSync(OPT_IN_DOC, 'utf8') : '';
  const missing = [...names].filter((n) => !doc.includes('`' + n + '`')).sort();
  if (!doc) detail.push(`${OPT_IN_DOC} is missing`);
  if (missing.length) detail.push(`switches read in code with no row in ${OPT_IN_DOC}: ${missing.join(', ')}`);

  // Check 8b — a Detector cell naming a cases/NN-*.sh file must name a file that exists.
  const limits = existsSync(KNOWN_LIMITS_DOC) ? readFileSync(KNOWN_LIMITS_DOC, 'utf8') : '';
  if (!limits) detail.push(`${KNOWN_LIMITS_DOC} is missing`);
  for (const m of limits.matchAll(/`cases\/((?:kernel-mandate\/)?[\w.-]+\.sh)`/g))
    if (!existsSync(join('hooks/tests/cases', m[1]))) detail.push(`${KNOWN_LIMITS_DOC} names a missing detector: cases/${m[1]}`);

  report(`env switches read by hooks/scripts ↔ opt-in-surfaces.md; known-limits detectors exist (${names.size} switches read)`, detail.length === 0, detail);
}
// ---------------------------------------------------------------------------
// Check 9 — workflow table ↔ QA mandate parity (stands in for `kernel-mandate derive --check`)
// ---------------------------------------------------------------------------
const QA_WORKFLOW = 'hooks/data/achilles-qa.workflow.json';
function checkQaMandateParity() {
  const detail = [];
  const wf = JSON.parse(readFileSync(QA_WORKFLOW, 'utf8'));
  const md = JSON.parse(readFileSync(QA_MANDATE, 'utf8'));
  const S = (a) => new Set(a ?? []);
  const eq = (a, b) => a.size === b.size && [...a].every((x) => b.has(x));
  const show = (s) => [...s].sort().join(', ') || '∅';
  const union = (st, k) => new Set(st.flatMap((s) => s[k] ?? []));
  const tRoles = S(Object.keys(wf.roles)); const mRoles = S(Object.keys(md.roles));
  if (!eq(tRoles, mRoles)) detail.push(`role sets differ — table: ${show(tRoles)}; mandate: ${show(mRoles)}`);
  const byRole = {};
  for (const s of wf.stages) (byRole[s.role] ??= []).push(s);
  for (const role of [...mRoles].sort()) {
    const st = byRole[role] ?? []; const m = md.roles[role];
    if (!st.length) { detail.push(`${role}: no stage in ${QA_WORKFLOW}`); continue; }
    const W = union(st, 'writes'); const WA = S(m.write?.allow);
    if (!eq(W, WA)) detail.push(`${role}: write.allow {${show(WA)}} ≠ stage writes {${show(W)}}`);
    const WD = S(m.write?.deny);
    for (const d of union(st, 'writesDeny')) if (!WD.has(d)) detail.push(`${role}: writesDeny '${d}' absent from write.deny`);
    const CI = S(wf.roles[role]?.codeImports); const MCI = S(m.write?.codeImports);
    if (!eq(CI, MCI)) detail.push(`${role}: codeImports table {${show(CI)}} ≠ mandate {${show(MCI)}}`);
    const E = union(st, 'env'); const ME = S(m.bash?.env);
    if (!eq(E, ME)) detail.push(`${role}: bash.env {${show(ME)}} ≠ stage env {${show(E)}}`);
    const RA = S(m.read?.allow);
    for (const r of union(st, 'reads')) if (!RA.has(r)) detail.push(`${role}: stage read '${r}' absent from read.allow`);
    const SK = union(st, 'skills');
    if (SK.size && !eq(SK, S(m.skills?.allow))) detail.push(`${role}: skills.allow {${show(S(m.skills?.allow))}} ≠ stage skills {${show(SK)}}`);
    const DI = union(st, 'dispatches'); const MD = S(Array.isArray(m.dispatch) ? m.dispatch : m.dispatch?.allow);
    if (DI.size && !eq(DI, MD)) detail.push(`${role}: dispatch {${show(MD)}} ≠ stage dispatches {${show(DI)}}`);
    const res = (m.bash?.groups ?? []).flatMap((g) => md.commandGroups?.[g] ?? []).map((p) => new RegExp(p));
    for (const cmd of union(st, 'runs')) if (!res.some((re) => re.test(cmd))) detail.push(`${role}: stage runs '${cmd}' matches none of its command groups`);
  }
  report(`achilles-qa workflow table ↔ mandate parity (${mRoles.size} roles, ${wf.stages.length} stages)`, detail.length === 0, detail);
}
// Check 10 — every skill directory activates the protocol, unless excluded on purpose
const ACTIVATION_LIB = 'hooks/lib/achilles-activation.sh';
const ACTIVATION_EXCLUDED = new Set(['mandate-designer']); // generic kernel tool; must not switch on QA gates
function checkActivationCoverage() {
  const src = readFileSync(ACTIVATION_LIB, 'utf8');
  const m = src.match(/^ACHILLES_SKILL_ALT='([^']+)'/m);
  const alt = new Set(m ? m[1].split('|') : []);
  const dirs = readdirSync('skills', { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name);
  const missing = dirs.filter((d) => !alt.has(d) && !ACTIVATION_EXCLUDED.has(d)).sort();
  report(`skills/*/ ↔ ACHILLES_SKILL_ALT (${dirs.length} skills, ${ACTIVATION_EXCLUDED.size} excluded)`,
    Boolean(m) && missing.length === 0,
    [...(!m ? [`ACHILLES_SKILL_ALT not found in ${ACTIVATION_LIB}`] : []), ...(missing.length ? [`skills that activate nothing: ${missing.join(', ')}`] : [])]);
}
checkRegistryBijection();
checkRelativeLinks();
checkHookManifest();
checkRoleMapCoverage();
checkHookReferences();
checkDocsCounts();
checkRoleLedgerInventory();
checkOptInSurfaces();
checkQaMandateParity();
checkActivationCoverage();

if (anyFail) {
  console.error('\nlint-doc-drift: drift detected (see [FAIL] lines above).');
  process.exit(1);
}
console.log('\nlint-doc-drift: all checks passed.');
