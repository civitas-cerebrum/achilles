#!/usr/bin/env node
// lint-doc-drift.mjs — fails the publish (prepack) when the human-authored
// doc surfaces drift out of sync with the machine-authoritative sources they
// describe. Six independent checks; each reports pass/fail; the process
// exits non-zero if any check fails.
//
//   (1) skill-registry table  ↔  skills/*/ directories          (bijection)
//   (2) every relative .md link under skills/achilles-protocol/** resolves
//   (3) HOOK_MANIFEST (hooks/manifest.json)  ↔  harness-hooks.md links
//   (4) every validated §4.4 description-prefix in subagent-return-schema.md
//       has a matching case in hooks/lib/schema-role-map.sh
//   (5) every deny/warn-capable hook's runtime messages carry a References:
//       block citing >=1 resolvable skills/ (or schemas/) path — the
//       methodology-pointer convention (contributing-to-achilles-protocol
//       SKILL.md §"Hook error message format — repo standard")
//   (6) every `skills/<name>/<file>.md §"<heading>"` section citation
//       emitted anywhere under hooks/ (including hooks/lib/) names a
//       heading that actually exists in the cited file — check 5 resolves
//       the PATH half of a citation; this resolves the §SECTION half, so a
//       heading rename (or a heading that never existed) can't silently
//       orphan a hook's pointer the way check 5 alone would miss.
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

  const manifestPath = join('hooks', 'manifest.json');
  const manifestFiles = new Set(JSON.parse(readFileSync(manifestPath, 'utf8')).map((e) => e.file));

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
// not) must resolve in the repo, so a skill rename cannot silently orphan a
// hook's pointers.
function checkHookReferences() {
  const detail = [];
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
// Check 6 — hook §SECTION citations resolve to a real heading
// ---------------------------------------------------------------------------
// Companion to check 5: a `skills/<name>/<file>.md §"<heading>"` citation
// can have a resolvable PATH while the §SECTION half points at a heading
// that was renamed or never existed (the no-skip-messaging.sh bug this
// check was added to catch: it cited skills/onboarding/SKILL.md
// §"Hard rules — kernel-resident", a heading that file never had).
//
// Mechanics: walk every hooks/**/*.sh file (hooks/tests/** excluded — those
// are test cases, not runtime hook messages), strip full-line comments (the
// message-producing region convention from check 5), then scan the
// remaining text for `skills/<name>/<file>.md` path mentions. For each
// path mention, look at the text between it and the NEXT "*.md"-looking
// mention (a bare filename.md counts too, even without a skills/ prefix —
// it still marks "this citation's path has ended," so a heading just past
// it doesn't get mis-attributed to the earlier, unrelated skills/ path) for
// one or more `§"<heading>"` citations (quoted headings only — bare `§4.4`
// / `§Bash`-style citations aren't section-heading citations and are out of
// scope here).
//
// A citation resolves if the target file has a markdown heading (`#`..`######`)
// whose text, tokenized to bare lowercase words (punctuation, backticks,
// and numbering all treated as separators), contains the citation's token
// sequence as a contiguous run. That tolerates the two conventions already
// in wide use across this repo: citing only a heading's core phrase while
// dropping a leading label/number ("20. Universality — ..." cited as
// "Universality — ...") or a trailing parenthetical ("Two valid exits —
// read this before anything else" cited as "Two valid exits"), on top of
// the case-insensitivity and trailing-period tolerance the task asked for
// (both fall out of the same tokenization for free).
function checkHookSectionReferences() {
  const detail = [];
  const files = walk('hooks', (f) => f.endsWith('.sh') && !f.startsWith(join('hooks', 'tests') + '/'));

  const pathRe = /skills\/[A-Za-z0-9._/-]+\.md/g;
  const anyMdRe = /\b[A-Za-z0-9._-]+\.md\b/g;
  const headingRe = /§\s*\\?"([^"]*?)\\?"/g;
  const headingCache = new Map(); // path -> array of raw heading lines

  function tokenize(s) {
    return s
      .toLowerCase()
      .replace(/`/g, '')
      .split(/[^a-z0-9]+/)
      .filter(Boolean);
  }

  function headingsFor(path) {
    if (headingCache.has(path)) return headingCache.get(path);
    let headings = [];
    if (existsSync(path)) {
      const text = readFileSync(path, 'utf8');
      headings = [...text.matchAll(/^#{1,6}\s*(.+)$/gm)].map((m) => m[1]);
    }
    headingCache.set(path, headings);
    return headings;
  }

  let citations = 0;

  for (const file of files) {
    const rawFull = readFileSync(file, 'utf8');
    const code = rawFull
      .split('\n')
      .map((l) => (/^\s*#/.test(l) ? '' : l))
      .join('\n');

    const paths = [...code.matchAll(pathRe)].map((m) => ({ idx: m.index, val: m[0] }));
    if (paths.length === 0) continue;
    const anyMdEnds = [...code.matchAll(anyMdRe)].map((m) => m.index + m[0].length);

    for (let i = 0; i < paths.length; i++) {
      const p = paths[i];
      const pathEnd = p.idx + p.val.length;
      const nextPathIdx = i + 1 < paths.length ? paths[i + 1].idx : code.length;
      const nextMdEnd = anyMdEnds.find((end) => end > pathEnd);
      const boundedByAnyMd = nextMdEnd !== undefined ? nextMdEnd - p.val.length : code.length;
      const windowEnd = Math.min(nextPathIdx, Math.max(pathEnd, boundedByAnyMd), pathEnd + 600);
      const segment = code.slice(pathEnd, windowEnd);

      headingRe.lastIndex = 0;
      let hm;
      while ((hm = headingRe.exec(segment)) !== null) {
        const citedHeading = hm[1].trim();
        if (!citedHeading) continue;
        citations++;
        if (!existsSync(p.val)) continue; // check 5 already reports the dead path

        const headings = headingsFor(p.val);
        const citTokens = tokenize(citedHeading);
        const resolved =
          citTokens.length > 0 &&
          headings.some((h) => {
            const hTokens = tokenize(h);
            for (let start = 0; start + citTokens.length <= hTokens.length; start++) {
              if (citTokens.every((t, k) => hTokens[start + k] === t)) return true;
            }
            return false;
          });

        if (!resolved) {
          const lineNo = rawFull.slice(0, pathEnd + hm.index).split('\n').length;
          detail.push(`${file}:${lineNo}: unresolved section citation: ${p.val} §"${citedHeading}"`);
        }
      }
    }
  }

  report(
    `hook §SECTION citations resolve to a real heading (${citations} citations checked)`,
    detail.length === 0,
    detail,
  );
}

checkRegistryBijection();
checkRelativeLinks();
checkHookManifest();
checkRoleMapCoverage();
checkHookReferences();
checkHookSectionReferences();

if (anyFail) {
  console.error('\nlint-doc-drift: drift detected (see [FAIL] lines above).');
  process.exit(1);
}
console.log('\nlint-doc-drift: all checks passed.');
