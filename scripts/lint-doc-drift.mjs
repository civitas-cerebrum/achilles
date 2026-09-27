#!/usr/bin/env node
// lint-doc-drift.mjs — fails the publish (prepack) when the human-authored
// doc surfaces drift out of sync with the machine-authoritative sources they
// describe. Eight independent checks; each reports pass/fail; the process
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
//   (7) every `pi-kernel:` entry in a skill's frontmatter names one real
//       heading of that same skill — the frontmatter line that tells the pi
//       adapter which sections must stay in a dispatched child's working
//       memory. An entry that names nothing (or several headings) is a
//       silent no-op at runtime, which is exactly how a rule stops
//       travelling with its skill.
//   (8) the role-derivation convention, BOTH directions: a heading that owns
//       a dispatch role's contract prints that role token in backticks, so
//       the pi Agent tool can derive the child's start section from its
//       description prefix. Every pinned (skill, role) pair still resolves,
//       and every heading that prints a role token is pinned — the second
//       direction catches a heading the adapter cannot parse, not just one
//       that moved.
//
// The lint is authored to the FINAL intended state of the surfaces other
// packages touch in parallel; where a surface has not yet converged it
// reports the specific drift rather than weakening the check.

import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

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

// The dispatch-role stems the harness knows about — the single source of truth
// for "is this token a role prefix" in checks 4 and 8. Extracted from the
// case globs of hooks/lib/schema-role-map.sh: single globs (`composer-*)`) and
// alternation lines that pack several onto one case label
// (`process-validator-*|phase1-*|cleanup-*)`).
function roleStems(roleMapPath) {
  const sh = readFileSync(roleMapPath, 'utf8');
  const stems = [];
  for (const m of sh.matchAll(/^\s*([a-z0-9-]+\*(?:\|[a-z0-9-]+\*)*)\)/gm)) {
    for (const glob of m[1].split('|')) {
      const stem = glob.replace(/\*$/, '');
      if (stem) stems.push(stem);
    }
  }
  return stems;
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

  const caseStems = roleStems(ROLE_MAP);

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
// Shared heading resolver (checks 6, 7, 8)
// ---------------------------------------------------------------------------
// One matcher for every "this text names that heading" question in this file.
// A citation/declaration resolves against a heading when its words appear in
// the heading's words as a contiguous run, where "words" are bare lowercase
// tokens (punctuation, backticks, em dashes and numbering are all
// separators). That tolerates the two conventions already in wide use across
// this repo: citing only a heading's core phrase while dropping a leading
// label/number ("20. Universality — ..." cited as "Universality — ...") or a
// trailing parenthetical ("Two valid exits — read this before anything else"
// cited as "Two valid exits"), and it makes case and trailing periods free.
//
// resolveHeadingRef adds the ladder the pi adapter's findSection uses
// (pi/extensions/achilles/skills.ts): a `"<parent> > <child>"` path first,
// then an exact match, then a unique containment match — and it reports
// SEVERAL matches as candidates rather than picking one, because a
// declaration that silently pins a sibling rule block is worse than one the
// author is asked to disambiguate. Check 6 keeps the looser "any heading
// matches" rule it was written with: a hook's prose pointer is human-read.

const headingCache = new Map(); // path -> [{ level, text }]

/** The markdown headings of `path`, with their level, in document order. */
function headingsOf(path) {
  if (headingCache.has(path)) return headingCache.get(path);
  let headings = [];
  if (existsSync(path)) {
    headings = [...readFileSync(path, 'utf8').matchAll(/^(#{1,6})\s*(.+)$/gm)]
      .map((m) => ({ level: m[1].length, text: m[2].trim() }));
  }
  headingCache.set(path, headings);
  return headings;
}

function tokenize(s) {
  return s.toLowerCase().replace(/`/g, '').split(/[^a-z0-9]+/).filter(Boolean);
}

/** Indexes of the headings whose token run contains `ref`'s token run. */
function matchHeadings(headings, ref) {
  const want = tokenize(ref);
  if (!want.length) return [];
  const out = [];
  headings.forEach((h, i) => {
    const got = tokenize(h.text);
    for (let start = 0; start + want.length <= got.length; start++) {
      if (want.every((t, k) => got[start + k] === t)) { out.push(i); return; }
    }
  });
  return out;
}

/** The nearest enclosing heading of headings[i] — the one above it at a lower level. */
function enclosingHeading(headings, i) {
  for (let k = i - 1; k >= 0; k--) if (headings[k].level < headings[i].level) return k;
  return undefined;
}

/** Exactly-one resolution of `ref`, or the candidates it matched. */
function uniqueHeadingMatch(headings, ref) {
  const hits = matchHeadings(headings, ref);
  const want = tokenize(ref).join(' ');
  const exact = hits.filter((i) => tokenize(headings[i].text).join(' ') === want);
  if (exact.length === 1) return { index: exact[0], candidates: [] };
  const rest = exact.length > 1 ? exact : hits;
  return rest.length === 1 ? { index: rest[0], candidates: [] } : { index: undefined, candidates: rest };
}

/** The one heading `ref` names, mirroring the adapter's findSection ladder. */
function resolveHeadingRef(headings, ref) {
  const terms = ref.split('>').map((t) => t.trim()).filter(Boolean);
  if (terms.length >= 2) {
    const [parent, child] = terms.slice(-2);
    const hits = matchHeadings(headings, child).filter((i) => {
      const e = enclosingHeading(headings, i);
      return e !== undefined && matchHeadings([headings[e]], parent).length > 0;
    });
    if (hits.length) return hits.length === 1 ? { index: hits[0], candidates: [] } : { index: undefined, candidates: hits };
  }
  const direct = uniqueHeadingMatch(headings, ref);
  if (direct.index !== undefined || direct.candidates.length || terms.length < 2) return direct;
  return uniqueHeadingMatch(headings, terms[terms.length - 1]);
}

/** The skill directories under `skillsDir` that hold a SKILL.md, sorted. */
function skillDirs(skillsDir) {
  return readdirSync(skillsDir)
    .filter((n) => {
      try { return statSync(join(skillsDir, n)).isDirectory() && existsSync(join(skillsDir, n, 'SKILL.md')); }
      catch { return false; }
    })
    .sort();
}

/** One frontmatter value of a SKILL.md, unquoted, or undefined when the key is absent.
 * The same naive single-line `key: value` read the pi adapter does (parseFrontmatter +
 * unquote in pi/extensions/achilles/skills.ts) — deliberately, so this check sees exactly
 * what the adapter sees rather than what a full YAML parser would make of it. */
function frontmatterValue(file, key) {
  const m = readFileSync(file, 'utf8').match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!m) return undefined;
  const line = m[1].split(/\r?\n/).find((l) => l.startsWith(`${key}:`));
  if (line === undefined) return undefined;
  const v = line.slice(key.length + 1).trim();
  if (v.length >= 2 && v.startsWith("'") && v.endsWith("'")) return v.slice(1, -1).replace(/''/g, "'");
  if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) return v.slice(1, -1).replace(/\\(["\\])/g, '$1');
  return v;
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

        const resolved = matchHeadings(headingsOf(p.val), citedHeading).length > 0;

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

// ---------------------------------------------------------------------------
// Check 7 — every `pi-kernel:` entry names one real heading of its skill
// ---------------------------------------------------------------------------
// `pi-kernel:` is the frontmatter line a skill author writes to declare which
// of the skill's sections must stay in a dispatched child's working memory
// (pi/extensions/achilles/skills.ts). The pi adapter resolves each entry with
// findSection and DROPS one that resolves to nothing or to several headings —
// it has to, because the Skill tool must still answer a skill whose
// frontmatter has a typo. That makes a stale entry silent at runtime: the
// section quietly stops travelling with the skill, which is the exact failure
// the declaration exists to prevent. This is where an author is told instead.
//
// A heading rename is the common way it breaks, so the message names the
// skill, the entry, and what to write instead.
const KERNEL_DELIMITER = '|'; // mirrors KERNEL_DELIMITER in pi/extensions/achilles/skills.ts

function checkPiKernelEntries(skillsDir = SKILLS_DIR) {
  const detail = [];
  let entries = 0;
  let annotated = 0;

  for (const name of skillDirs(skillsDir)) {
    const file = join(skillsDir, name, 'SKILL.md');
    const declared = frontmatterValue(file, 'pi-kernel');
    if (declared === undefined) continue;
    annotated++;
    const headings = headingsOf(file);
    const list = [...new Set(declared.split(KERNEL_DELIMITER).map((e) => e.trim()).filter(Boolean))];
    if (list.length === 0) {
      detail.push(`${file}: pi-kernel: is present but names nothing — delete the line or name a section`);
      continue;
    }
    const taken = new Map(); // heading index -> the entry that claimed it
    for (const entry of list) {
      entries++;
      const { index, candidates } = resolveHeadingRef(headings, entry);
      if (index === undefined) {
        detail.push(candidates.length
          ? `${file}: pi-kernel entry "${entry}" matches ${candidates.length} headings (${candidates.map((i) => `"${headings[i].text}"`).join(', ')}) — the adapter declares NEITHER; name one as "<parent> > <child>"`
          : `${file}: pi-kernel entry "${entry}" names no heading of this skill — the adapter drops it silently, so that section stops travelling with the skill (entries are separated by "${KERNEL_DELIMITER}"; an entry is a heading, a unique part of one, or "<parent> > <child>")`);
        continue;
      }
      if (taken.has(index)) {
        detail.push(`${file}: pi-kernel entries "${taken.get(index)}" and "${entry}" both name "${headings[index].text}" — one of them is dead weight`);
      } else taken.set(index, entry);
    }
  }

  return {
    label: `pi-kernel: entries name a real heading of their own skill (${entries} entries across ${annotated} skills)`,
    ok: detail.length === 0,
    detail,
  };
}

// ---------------------------------------------------------------------------
// Check 8 — the role-derivation convention holds, both directions
// ---------------------------------------------------------------------------
// The methodology writes the dispatch role prefix into the heading of that
// role's contract, in backticks: "### Phase 5 — Coverage-expansion
// (`workflow-reviewer-phase5`)", "### Per-section-agent contract
// (`phase4-cycle-<N>-section-<id>:`)". The pi Agent tool reads that
// convention (roleSection in pi/extensions/achilles/agent-tool.ts): a child
// dispatched with `workflow-reviewer-phase5:` is handed that section inline
// instead of the whole skill and a guess. Nothing else enforces the
// convention, so a heading rename that drops the backticked token silently
// stops the derivation — and until this check existed the only thing that
// noticed was the pi adapter's own test suite, which is a strange place for a
// methodology author to find out.
//
// BOTH directions, and the second is the one that earns its keep:
//   - every pinned (skill, role) pair still has its heading (a rename or a
//     deletion fails here, named);
//   - every heading that prints a role token is pinned, and prints it
//     UNIQUELY within the skill — an ambiguous token is one roleSection
//     refuses to resolve, so a new heading the adapter cannot parse fails
//     here rather than degrading in silence.
//
// The role STEMS are derived from hooks/lib/schema-role-map.sh, never
// hand-copied (roleStems above). The pairs below are the pin: re-derive them
// with the enumeration in pi/tests/agent-tool.test.mjs
// ("every role token a skill heading prints is derivable"), which asserts the
// adapter really does resolve each one to that very heading. A token
// containing `*` is a family banner ("Perf-onboarding pipeline reviewer
// (`perf-reviewer-*`)"), not a role a dispatch can carry, and is out of scope.
const ROLE_HEADING_PINS = [
  ['journey-mapping', 'phase4-cycle-<N>-section-<id>:'],
  ['journey-mapping', 'phase4-prioritise-author:'],
  ['ticket-driven-testing', 'probe-rigour'],
  ['workflow-reviewer', 'workflow-reviewer-phase1'],
  ['workflow-reviewer', 'workflow-reviewer-phase2'],
  ['workflow-reviewer', 'workflow-reviewer-phase3'],
  ['workflow-reviewer', 'workflow-reviewer-phase4'],
  ['workflow-reviewer', 'workflow-reviewer-phase5'],
  ['workflow-reviewer', 'workflow-reviewer-phase6'],
  ['workflow-reviewer', 'workflow-reviewer-phase7'],
  ['workflow-reviewer', 'workflow-reviewer-phase8'],
  ['workflow-reviewer', 'workflow-reviewer-pass<N>'],
  ['workflow-reviewer', 'workflow-reviewer-cycle<N>'],
  ['workflow-reviewer', 'perf-reviewer-phase1'],
  ['workflow-reviewer', 'perf-reviewer-phase2'],
  ['workflow-reviewer', 'perf-reviewer-phase3'],
  ['workflow-reviewer', 'perf-reviewer-phase4'],
  ['workflow-reviewer', 'perf-reviewer-phase5'],
  ['workflow-reviewer', 'perf-reviewer-phase6'],
  ['workflow-reviewer', 'perf-reviewer-phase7'],
  ['workflow-reviewer', 'perf-reviewer-pass-<load|stress|spike|soak>'],
];

function checkRoleHeadingConvention(skillsDir = SKILLS_DIR, roleMapPath = ROLE_MAP, pins = ROLE_HEADING_PINS) {
  const detail = [];
  const stems = roleStems(roleMapPath);
  const found = new Map(); // "<skill>\t<token>" -> { heading, contains }

  for (const name of skillDirs(skillsDir)) {
    const headings = headingsOf(join(skillsDir, name, 'SKILL.md'));
    for (const h of headings) {
      for (const m of h.text.matchAll(/`([^`]+)`/g)) {
        const token = m[1];
        if (token.includes('*') || !stems.some((st) => token.startsWith(st))) continue;
        const key = `${name}\t${token}`;
        // roleSection accepts only an unambiguous resolution, so what matters is how many of
        // the skill's headings CONTAIN the token, not how many print it in backticks.
        const contains = headings.filter((o) => o.text.toLowerCase().includes(token.toLowerCase()));
        if (found.has(key)) continue;
        found.set(key, { heading: h.text, contains: contains.length });
      }
    }
  }

  for (const [skill, token] of pins) {
    const key = `${skill}\t${token}`;
    if (!found.has(key)) {
      detail.push(`skills/${skill}/SKILL.md: no heading prints the dispatch role token \`${token}\` any more — a child dispatched with that prefix loses its start section (convention: the heading that owns a role's contract prints the role token in backticks; see roleSection in pi/extensions/achilles/agent-tool.ts)`);
    }
  }
  for (const [key, { heading, contains }] of found) {
    const [skill, token] = key.split('\t');
    if (!pins.some(([s, t]) => s === skill && t === token)) {
      detail.push(`skills/${skill}/SKILL.md: heading "${heading}" prints the dispatch role token \`${token}\` but the pair is not pinned — check pi/tests/agent-tool.test.mjs derives it, then add ['${skill}', '${token}'] to ROLE_HEADING_PINS`);
    }
    if (contains > 1) {
      detail.push(`skills/${skill}/SKILL.md: ${contains} headings contain the role token \`${token}\` — roleSection resolves only an unambiguous match, so the derivation is dead for that role`);
    }
  }

  return {
    label: `skill headings print their dispatch role token (${pins.length} pinned roles, ${found.size} found, ${stems.length} role stems)`,
    ok: detail.length === 0,
    detail,
  };
}

// Checks 7 and 8 RETURN their result rather than reporting it themselves, so a
// test can point them at a fixture tree and assert on the message (checks 1-6
// predate that and keep their own report() call).
export { checkPiKernelEntries, checkRoleHeadingConvention, ROLE_HEADING_PINS };

function main() {
  checkRegistryBijection();
  checkRelativeLinks();
  checkHookManifest();
  checkRoleMapCoverage();
  checkHookReferences();
  checkHookSectionReferences();
  for (const r of [checkPiKernelEntries(), checkRoleHeadingConvention()]) report(r.label, r.ok, r.detail);

  if (anyFail) {
    console.error('\nlint-doc-drift: drift detected (see [FAIL] lines above).');
    process.exit(1);
  }
  console.log('\nlint-doc-drift: all checks passed.');
}

// Run only as a script: importing this file (pi/tests/lint-doc-drift.test.mjs does)
// must not lint the repo or exit the process.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
