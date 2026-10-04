#!/usr/bin/env node
// lint-doc-drift.mjs — fails the publish (prepack) when the human-authored
// doc surfaces drift out of sync with the machine-authoritative sources they
// describe. Seven independent checks; each reports pass/fail; the process
// exits non-zero if any check fails.
//
//   (1) skill-registry table  ↔  skills/*/ directories          (bijection)
//   (2) every relative .md link under skills/achilles-protocol/** resolves
//   (3) HOOK_MANIFEST (scripts/postinstall.js)  ↔  harness-hooks.md links
//  (3b) FACTORY_MANIFEST  ↔  hooks/factory/*.sh  ↔  harness-hooks.md links
//   (4) every validated §4.4 description-prefix in subagent-return-schema.md
//       has a matching case in hooks/lib/schema-role-map.sh
//   (5) every deny/warn-capable hook's runtime messages carry a References:
//       block citing >=1 resolvable skills/ (or schemas/) path — the
//       methodology-pointer convention (contributing-to-achilles-protocol
//       SKILL.md §"Hook error message format — repo standard")
//   (6) the selectors.evidence `evidenceDir` default is the same string in
//       the schema, the gate, bin/evidence-note.mjs and both reference pages
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
// Check 3b — FACTORY_MANIFEST  ↔  hooks/factory/*.sh  ↔  harness-hooks.md
// ---------------------------------------------------------------------------
// Check 3's link regex is `(../+hooks/<name>.sh)`, which cannot see a path
// with a directory in it, so for a while every hooks/factory/ gate was
// invisible to this lint: seven gates shipped, none registered, and no check
// anywhere noticed. This one closes that hole on all three sides — a gate on
// disk that no manifest registers is as much a defect as a manifest entry
// with no gate, and either one with no documented entry drifts out of the
// reference the deny messages point readers at.
function checkFactoryManifest() {
  const detail = [];
  const post = readFileSync(POSTINSTALL, 'utf8');

  const start = post.indexOf('const FACTORY_MANIFEST = [');
  if (start === -1) {
    report('FACTORY_MANIFEST ↔ hooks/factory/ ↔ harness-hooks.md', false, [
      `${POSTINSTALL}: no FACTORY_MANIFEST — the hooks/factory/ gates are shipped but never installed or registered`,
    ]);
    return;
  }
  const body = post.slice(start, post.indexOf('];', start));
  const registered = new Set(
    [...body.matchAll(/file:\s*'([a-z0-9-]+\.sh)'/g)].map((m) => m[1]),
  );

  const onDisk = new Set(
    existsSync('hooks/factory') ? readdirSync('hooks/factory').filter((f) => f.endsWith('.sh')) : [],
  );

  // Documented gates = markdown links of the form (.../hooks/factory/<file>.sh).
  const hooksMd = readFileSync(HARNESS_HOOKS, 'utf8');
  const documented = new Set(
    [...hooksMd.matchAll(/\((?:\.\.\/)+hooks\/factory\/([a-z0-9-]+\.sh)\)/g)].map((m) => m[1]),
  );

  const unregistered = [...onDisk].filter((f) => !registered.has(f));
  const phantom = [...registered].filter((f) => !onDisk.has(f));
  const undocumented = [...registered].filter((f) => !documented.has(f));
  const orphanDocs = [...documented].filter((f) => !onDisk.has(f));

  if (unregistered.length) detail.push(`in hooks/factory/ but not in FACTORY_MANIFEST (shipped, never registered — every write would pass silently): ${unregistered.join(', ')}`);
  if (phantom.length) detail.push(`in FACTORY_MANIFEST but no such file under hooks/factory/: ${phantom.join(', ')}`);
  if (undocumented.length) detail.push(`in FACTORY_MANIFEST but not documented in harness-hooks.md: ${undocumented.join(', ')}`);
  if (orphanDocs.length) detail.push(`documented in harness-hooks.md but no such file under hooks/factory/: ${orphanDocs.join(', ')}`);

  report(
    `FACTORY_MANIFEST ↔ hooks/factory/ ↔ harness-hooks.md (${onDisk.size} gates on disk, ${registered.size} registered, ${documented.size} documented)`,
    detail.length === 0,
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
// not) must resolve in the repo, so a skill rename cannot silently orphan a
// hook's pointers.
function checkHookReferences() {
  const detail = [];
  // Vendored verbatim from @civitas-cerebrum/kernel-mandate by
  // scripts/sync-kernel-mandate.mjs (--check fails CI on drift). Its deny
  // messages cite the kernel's own docs, not this repo's methodology, and
  // an edit here would be overwritten on the next sync — so the References
  // convention is achilles' own hooks' to keep, and the wrapper that
  // registers the kernel (achilles-kernel-activation-gate.sh) is held to it.
  const VENDORED = new Set(['hooks/kernel-mandate-role-gate.sh']);
  const hooks = readdirSync('hooks')
    .filter((f) => f.endsWith('.sh'))
    .map((f) => join('hooks', f))
    .filter((h) => !VENDORED.has(h));

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
// Check 6 — the selectors.evidence `evidenceDir` default agrees everywhere
// ---------------------------------------------------------------------------
// `evidenceDir` is schema-OPTIONAL, which makes its default load-bearing for
// every project that omits the field — and that default was restated in five
// places, two of which disagreed. repository-evidence-gate.sh looked in
// `docs/evidence/selectors`; bin/selector-evidence.mjs wrote to
// `tests/e2e/docs/evidence/selectors`. For a project on the default that is a
// permanent deny loop with no way out from inside the session: the agent runs
// achilles-selector-evidence, the note lands where the gate never reads, the
// gate denies the same write again, and its action tells the agent to run the
// tool it has just run.
//
// The schema's declared `default` is the authoritative copy; everything else
// restates it and this check makes a restatement that drifts fail the publish.
const FACTORY_SCHEMA = 'hooks/data/factory-rules.schema.json';
const EVIDENCE_GATE = 'hooks/factory/repository-evidence-gate.sh';
const EVIDENCE_NOTE = 'bin/evidence-note.mjs';
const FACTORY_GATES_MD = 'skills/achilles-protocol/references/factory-gates.md';
const SELECTOR_EVIDENCE_MD = 'skills/achilles-protocol/references/selector-evidence.md';

function checkEvidenceDirDefault() {
  const detail = [];
  const schema = JSON.parse(readFileSync(FACTORY_SCHEMA, 'utf8'));
  const want = schema?.$defs?.selectorsEvidence?.properties?.evidenceDir?.default;

  if (typeof want !== 'string' || !want) {
    report('selectors.evidence evidenceDir default agrees across gate, tool and docs', false, [
      `${FACTORY_SCHEMA}: $defs.selectorsEvidence.properties.evidenceDir has no string "default" to be authoritative`,
    ]);
    return;
  }

  // The gate's own fallback: EVDIR="${EVDIR:-<default>}".
  const gateSrc = readFileSync(EVIDENCE_GATE, 'utf8');
  const gateMatch = gateSrc.match(/EVDIR="\$\{EVDIR:-([^}"]+)\}"/);
  if (!gateMatch) detail.push(`${EVIDENCE_GATE}: no \`EVDIR="\${EVDIR:-…}"\` fallback found — cannot confirm the gate's default`);
  else if (gateMatch[1] !== want) detail.push(`${EVIDENCE_GATE}: falls back to "${gateMatch[1]}", schema default is "${want}"`);

  // The tool's shared constant.
  const noteSrc = readFileSync(EVIDENCE_NOTE, 'utf8');
  const noteMatch = noteSrc.match(/export const DEFAULT_EVIDENCE_DIR = '([^']+)'/);
  if (!noteMatch) detail.push(`${EVIDENCE_NOTE}: no \`export const DEFAULT_EVIDENCE_DIR\` found — cannot confirm the tool's default`);
  else if (noteMatch[1] !== want) detail.push(`${EVIDENCE_NOTE}: DEFAULT_EVIDENCE_DIR is "${noteMatch[1]}", schema default is "${want}"`);

  // Both reference pages must quote the authoritative string and must not
  // quote a different evidence directory as "the default".
  for (const doc of [FACTORY_GATES_MD, SELECTOR_EVIDENCE_MD]) {
    const md = readFileSync(doc, 'utf8');
    if (!md.includes(want)) detail.push(`${doc}: never names the default evidence dir "${want}"`);
    for (const m of md.matchAll(/[Dd]efault[^\n.]{0,24}`([A-Za-z0-9._/-]*evidence\/selectors)`/g)) {
      if (m[1] !== want) detail.push(`${doc}: documents the default as "${m[1]}", schema default is "${want}"`);
    }
  }

  report(
    `selectors.evidence evidenceDir default agrees across gate, tool and docs ("${want}", 5 declarations)`,
    detail.length === 0,
    detail,
  );
}

checkRegistryBijection();
checkRelativeLinks();
checkHookManifest();
checkFactoryManifest();
checkRoleMapCoverage();
checkHookReferences();
checkEvidenceDirDefault();

if (anyFail) {
  console.error('\nlint-doc-drift: drift detected (see [FAIL] lines above).');
  process.exit(1);
}
console.log('\nlint-doc-drift: all checks passed.');
