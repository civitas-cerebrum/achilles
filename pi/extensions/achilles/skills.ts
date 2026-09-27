import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export interface SkillInfo {
  name: string;
  dir: string;
  file: string;
  description: string;
  body: string;
  subagentOnly: boolean;
  /** The pi routing line (`pi-description:` frontmatter), when the skill has one. */
  piDescription?: string;
}

/** <package>/ is three levels above this file: pi/extensions/achilles/. fileURLToPath rather than
 * import.meta.dirname so the module resolves the same under pi's jiti loader and under node --test. */
export const PACKAGE_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

export function skillRoots(home: string): string[] {
  return [path.join(home, '.agents', 'skills'), path.join(PACKAGE_DIR, 'skills')];
}

function parseFrontmatter(text: string): { fm: Record<string, string>; body: string } {
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!m) return { fm: {}, body: text };
  const fm: Record<string, string> = {};
  let key = '';
  for (const line of m[1].split(/\r?\n/)) {
    const kv = line.match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
    if (kv) { key = kv[1]; fm[key] = kv[2].trim(); }
    else if (key && /^\s+\S/.test(line)) fm[key] += ' ' + line.trim();
  }
  return { fm, body: m[2] };
}

/** A YAML flow scalar's value: surrounding quotes removed ('' → ' in single quotes; \" and \\ in double). */
export function unquote(value: string): string {
  const v = value.trim();
  if (v.length >= 2 && v.startsWith("'") && v.endsWith("'")) return v.slice(1, -1).replace(/''/g, "'");
  if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) return v.slice(1, -1).replace(/\\(["\\])/g, '$1');
  return v;
}

/** Truthy YAML-ish flag: "true" or "yes", case-insensitive. */
function isFlagTrue(value: string | undefined): boolean {
  return /^(true|yes)$/i.test(value ?? '');
}

/**
 * A description is a YAML folded (`>`) scalar in most skills, so parseFrontmatter's naive
 * key: value capture leaves the fold indicator (">") as a leading token before the first
 * continuation line is appended. The subagent-only marker can be bold ("**Subagent-only.**",
 * e.g. failure-diagnosis, contributing-to-achilles-protocol) or plain text ("Subagent-only
 * skill.", e.g. workflow-reviewer) — both only ever appear at the very start of the folded
 * description. Anchoring on that start (past an optional fold indicator and optional bold
 * markers) classifies all three real subagent-only skills without false-positiving on skills
 * that merely mention "subagent-only" mid-description (e.g. achilles-protocol, describing
 * failure-diagnosis).
 */
const SUBAGENT_ONLY_MARKER = /^>?\s*\*{0,2}Subagent-only\b/i;

const SKILL_NAME_RE = /^[a-z0-9][a-z0-9-]*$/;

/** Sorted, de-duplicated names of skills (directories holding a SKILL.md) across all roots.
 * Mirrors resolveSkill's guarded-failure discipline: an unreadable root, a root that doesn't
 * exist, or a root that is a regular file must not throw — they are simply skipped. */
export function listSkills(roots: string[]): string[] {
  const names = new Set<string>();
  for (const root of roots) {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(root, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const d of entries) {
      if (!d.isDirectory() || !SKILL_NAME_RE.test(d.name)) continue;
      try {
        if (fs.existsSync(path.join(root, d.name, 'SKILL.md'))) names.add(d.name);
      } catch {
        continue;
      }
    }
  }
  return [...names].sort();
}

export function resolveSkill(name: string, roots: string[]): SkillInfo | undefined {
  if (!SKILL_NAME_RE.test(name)) return undefined;
  for (const root of roots) {
    const dir = path.join(root, name);
    const file = path.join(dir, 'SKILL.md');
    let text: string;
    try {
      // existsSync + readFileSync as one guarded step: a permission error, a TOCTOU race, or
      // SKILL.md being a directory rather than a file must not throw out of resolveSkill — it
      // would otherwise propagate through steer()'s String.replace callback and crash the
      // whole message rewrite. Treat any failure here as "unresolved in this root".
      if (!fs.existsSync(file)) continue;
      text = fs.readFileSync(file, 'utf8');
    } catch {
      continue;
    }
    const { fm, body } = parseFrontmatter(text);
    const description = fm.description ?? '';
    const subagentOnly =
      isFlagTrue(fm['disable-model-invocation']) ||
      SUBAGENT_ONLY_MARKER.test(description);
    const piDescription = fm['pi-description'] ? unquote(fm['pi-description']) : undefined;
    return { name, dir, file, description, body, subagentOnly, ...(piDescription ? { piDescription } : {}) };
  }
  return undefined;
}

// ── Section-addressable skill bodies ─────────────────────────────────────────────────────────────
// A large skill costs the orchestrator its whole body (coverage-expansion is 89k chars, ~23k tokens)
// for work that usually needs one section. Every large skill is written as 13-21 `## ` sections, so
// at depth 0 the Skill tool returns a MAP of the skill — preamble, the always-required rule blocks,
// and a table of contents — and the model fetches a section by name. A subagent (depth >= 1) is
// dispatched for one job and its window holds only its own skill, so it still gets the whole body.

/** A heading matching this is ALWAYS-REQUIRED: its text is in the map whatever the size costs, or,
 * when it does not fit the map budget, it is listed as mandatory reading the model must fetch.
 *
 * `Hard rules` / `kernel-resident` is this repo's own name for the category. coverage-expansion
 * §"Kernel-resident invariants — convention" states the doctrine: such a subsection lists the
 * invariants that must stay in working memory even when the reference itself is not loaded. Six
 * skills carry one, and journey-mapping's is the whole cycle protocol that
 * hooks/journey-mapping-skill-preread-gate.sh treats a bare `Skill{journey-mapping}` as proof of. */
export const REQUIRED_HEADING = /ABSOLUTE RULE|Absolute Rules|non-negotiable|No-skip contract|read this before|STOP AND READ|must read|Hard rules|kernel-resident/i;

/**
 * CONTENT signal for a binding rule, used ONLY as a fallback for a skill in which NO heading matched
 * REQUIRED_HEADING. `SkillSection.required` is decided by the heading TEXT, which is a proxy: 14 of
 * the 24 skills declare no required heading at all, so their map used to be a lead, a preamble and a
 * table of contents — not one binding rule. ticket-driven-testing is the worst case: 85,462 chars
 * whose `### The sign-off gate` carries "**You may not report a QA verdict until you have run the
 * negative control (§8)**", and a dispatched child never saw it.
 *
 * Two tiers, tried in order, and the FIRST tier that hits anything in a skill wins — the same ranking
 * as heading-beats-content, one level down. A skill that states a prohibition is not also searched for
 * the weaker obligation vocabulary, because `\bMUST\b` alone matches 7 sections of bug-discovery and
 * would bury the two that actually forbid something.
 *
 * Case matters, and the cased/anycase split is per alternative, measured rather than assumed:
 *  - `MUST NOT` screaming is always a directive to the reader. Case-INSENSITIVE `must not` is not:
 *    agents-vs-agents §Healthcare's "Category 3: Must not diagnose, recommend medications..." is a
 *    constraint on the system under test, and matching it would put four domain tables in four maps.
 *  - `do not proceed` is the opposite: every real instance is sentence-initial ("Do not proceed to
 *    Stage 6...", "Do NOT proceed on ACs you invented"), so a cased pattern would match none of them,
 *    and the phrase has no descriptive reading in this corpus. It is matched case-insensitively.
 *  - `never ship|report|claim|skip` needs the modal guard: ticket-driven-testing §Overview's "the code
 *    you are testing may never ship in the form you read" is a description, while "what static mode
 *    must never claim" is a prohibition. `may|might|could never` is epistemic, `must never` is binding.
 */
export interface RuleTextTier {
  /** How the map names the tier, so a model can tell an inferred block from a declared one. */
  label: string;
  /** Case-sensitive alternatives, then case-insensitive ones. A hit in either is a hit. */
  cased: RegExp;
  anycase: RegExp;
}

export const RULE_TEXT_TIERS: readonly RuleTextTier[] = [
  {
    label: 'prohibition',
    cased: /\bYou may not\b|\bMUST NOT\b|(?<!\b(?:may|might|could) )\bnever (?:report|ship|claim|skip)\b|\bnon-negotiable\b/,
    anycase: /\bdo not proceed\b/i,
  },
  {
    label: 'obligation',
    cased: /\bMUST\b|\*\*Never\b|\bmay not (?:be|start)\b/,
    anycase: /\bis not optional\b|\bcannot be skipped\b/i,
  },
];

/** Whether `text` carries this tier's rule wording. */
export function matchesTier(tier: RuleTextTier, text: string): boolean {
  return tier.cased.test(text) || tier.anycase.test(text);
}

export interface SkillSection {
  /** Heading text, hashes and surrounding whitespace removed. */
  heading: string;
  /** 2 for `## `, 3 for `### `, … */
  level: number;
  /** Heading line plus everything under it up to the next heading of the same or a higher level. */
  text: string;
  /** Heading line plus its own prose only, up to the next heading of ANY level. */
  ownText: string;
  required: boolean;
}

interface Head { line: number; level: number; heading: string }

/** Headings (`## ` … `###### `) of `body`, skipping fenced code blocks: several skills embed a
 * document template whose `## ` lines are sample output, not sections of the skill. */
function headings(lines: string[]): Head[] {
  const out: Head[] = [];
  let fence = false;
  lines.forEach((l, line) => {
    if (/^\s{0,3}(```|~~~)/.test(l)) { fence = !fence; return; }
    if (fence) return;
    const m = /^(#{2,6})\s+(\S.*?)\s*$/.exec(l);
    if (m) out.push({ line, level: m[1].length, heading: m[2] });
  });
  return out;
}

/** Everything before the first `## `, trimmed (the skill's title and its opening paragraphs). */
export function skillPreamble(body: string): string {
  const lines = body.split('\n');
  const first = headings(lines).find((h) => h.level === 2);
  return lines.slice(0, first ? first.line : lines.length).join('\n').trim();
}

/** Every heading of `body` as a section, in document order (all levels, nested ones included). */
export function parseSections(body: string): SkillSection[] {
  const lines = body.split('\n');
  const heads = headings(lines);
  return heads.map((h, i) => {
    const next = heads.slice(i + 1).find((o) => o.level <= h.level);
    const anyNext = heads[i + 1];
    return {
      heading: h.heading,
      level: h.level,
      text: lines.slice(h.line, next ? next.line : lines.length).join('\n').trim(),
      ownText: lines.slice(h.line, anyNext ? anyNext.line : lines.length).join('\n').trim(),
      required: REQUIRED_HEADING.test(h.heading),
    };
  });
}

/**
 * The sections whose OWN text states a binding rule, for a skill in which no HEADING declared one.
 *
 * A declared heading always outranks inferred text: a skill with even one `required` section returns
 * nothing here, so the 10 skills that already have required sections keep exactly the map they had.
 * `ownText`, not `text`, because a parent section's `text` swallows its children — `## The Contract`
 * would match on its `### The sign-off gate` child and the map would inline the parent's prose while
 * the prohibition itself stayed out of reach.
 */
export function inferredRuleSections(sections: SkillSection[]): { tier?: RuleTextTier; sections: SkillSection[] } {
  if (sections.some((s) => s.required)) return { sections: [] };
  for (const tier of RULE_TEXT_TIERS) {
    const hits = sections.filter((s) => matchesTier(tier, s.ownText));
    if (hits.length) return { tier, sections: hits };
  }
  return { sections: [] };
}

/** Whether `heading` answers `q` (already lowercased, hashes stripped): exactly, else as a substring. */
function headingMatches(heading: string, q: string): boolean {
  const h = heading.toLowerCase();
  return h === q || h.includes(q);
}

const normQuery = (q: string) => q.trim().toLowerCase().replace(/^#+\s*/, '');

/** One heading term: a table-of-contents number, else an exact match, else a unique substring match. */
function matchTerm(sections: SkillSection[], q: string): { section?: SkillSection; candidates: SkillSection[] } {
  if (!q) return { candidates: [] };
  // The map numbers the `## ` sections, so "15" is a legitimate way to ask for the 15th.
  if (/^\d{1,3}$/.test(q)) {
    const nth = sections.filter((s) => s.level === 2)[Number(q) - 1];
    if (nth) return { section: nth, candidates: [] };
  }
  const exact = sections.filter((s) => s.heading.toLowerCase() === q);
  if (exact.length === 1) return { section: exact[0], candidates: [] };
  const hits = exact.length > 1 ? exact : sections.filter((s) => s.heading.toLowerCase().includes(q));
  if (hits.length === 1) return { section: hits[0], candidates: [] };
  return { candidates: hits };
}

/**
 * The section a `section` argument asks for: a `"<parent> > <child>"` path, else a table-of-contents
 * number, else an exact heading match (case-insensitive), else a unique case-insensitive substring
 * match. Several matches return the candidates instead of guessing — a small model fetching the wrong
 * rule block is worse than a retry.
 *
 * The path form exists because five coverage-expansion subsections are all `### Hard rules —
 * kernel-resident`: no heading text can pick one out, so the map prints candidates as
 * `"<parent> > <child>"` and this accepts them back in that form. A query that is not a path, or
 * whose parent term matches nothing, falls back to matching the query whole and then its last term.
 */
export function findSection(sections: SkillSection[], query: string): { section?: SkillSection; candidates: SkillSection[] } {
  const whole = normQuery(query);
  if (!whole) return { candidates: [] };
  const path = query.split('>').map(normQuery).filter(Boolean);
  if (path.length >= 2) {
    const [parent, child] = [path[path.length - 2], path[path.length - 1]];
    const hits = sections.filter((s) => {
      if (!headingMatches(s.heading, child)) return false;
      const p = parentOf(sections, s);
      return !!p && headingMatches(p.heading, parent);
    });
    if (hits.length) return hits.length === 1 ? { section: hits[0], candidates: [] } : { candidates: hits };
  }
  const direct = matchTerm(sections, whole);
  if (direct.section || direct.candidates.length || path.length < 2) return direct;
  // A path whose parent named nothing: the child term alone is the best remaining reading.
  return matchTerm(sections, path[path.length - 1]);
}

/** The nearest enclosing section of `s` (the heading above it at a lower level), if any. Several
 * skills repeat a subsection heading ("Hard rules — kernel-resident"), so a candidate is only
 * identifiable through its parent. */
export function parentOf(sections: SkillSection[], s: SkillSection): SkillSection | undefined {
  for (let i = sections.indexOf(s) - 1; i >= 0; i--) if (sections[i].level < s.level) return sections[i];
  return undefined;
}

/** The immediate subsections of `s` — the nested sections whose nearest enclosing section is `s`. A
 * skill may skip a heading level (`## ` straight to `#### `), so this is "whose parent is s" rather
 * than "one level below s". */
export function childrenOf(sections: SkillSection[], s: SkillSection): SkillSection[] {
  return subsectionsOf(sections, s).filter((o) => parentOf(sections, o) === s);
}

/** The shortest `section` query that resolves back to `s`: its heading alone when that is
 * unambiguous, else `"<parent> > <heading>"`. Round 3's rule for the ambiguity reply — only offer a
 * move the model can actually make — applies to every address a reply prints, so this verifies the
 * short form against findSection before offering it rather than assuming it is unique. */
export function addressOf(sections: SkillSection[], s: SkillSection): string {
  if (findSection(sections, s.heading).section === s) return s.heading;
  const p = parentOf(sections, s);
  return p ? `${p.heading} > ${s.heading}` : s.heading;
}

/** The `## `-level table of contents, with each section's size and whether it is required reading. */
export function tableOfContents(sections: SkillSection[], skill: string): string {
  const top = sections.filter((s) => s.level === 2);
  const lines = top.map((s, i) => {
    const nested = sections.filter((o) => o.required && o.level > 2 && sectionOwns(sections, s, o));
    const mark = s.required || nested.length ? ' [required reading]' : '';
    return `${String(i + 1).padStart(2)}. ${s.heading} (${s.text.length} chars)${mark}`;
  });
  return `Sections — fetch one with Skill { skill: "${skill}", section: "<heading>" }:\n${lines.join('\n')}`;
}

/** The nested sections inside `s` — any level below it, in document order. A required `## ` block's
 * own text is what the map inlines, so this is what the map's continuation marker counts. */
export function subsectionsOf(sections: SkillSection[], s: SkillSection): SkillSection[] {
  return sections.filter((o) => o.level > s.level && sectionOwns(sections, s, o));
}

/** Whether `child` falls inside `parent`'s span (both from the same parseSections result). */
function sectionOwns(sections: SkillSection[], parent: SkillSection, child: SkillSection): boolean {
  const i = sections.indexOf(parent);
  const j = sections.indexOf(child);
  if (i < 0 || j <= i) return false;
  for (let k = i + 1; k < j; k++) if (sections[k].level <= parent.level) return false;
  return true;
}
