import { Type } from 'typebox';
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { resolveSkill, listSkills, parseSections, findSection, parentOf, childrenOf, addressOf, subsectionsOf, skillPreamble, tableOfContents, type SkillSection } from './skills.ts';
import { log } from './log.ts';
import { fullBelow, piDepth, piVerbose, sectionMax, skillHeadMax } from './env.ts';

const wrap = (name: string, path: string, text: string, view?: string) =>
  `<skill name="${name}" path="${path}"${view ? ` view="${view}"` : ''}>\n${text.trim()}\n</skill>`;

/** Where a required block's own text stops short of the whole block: the map would otherwise read as
 * the complete rule set. achilles-protocol's `## 🚨 ABSOLUTE RULES` carries 290 chars of own text
 * ("These rules are non-negotiable.") in front of 22,283 chars of rules held in its subsections. */
function continuesNote(skill: string, s: SkillSection, subs: number): string {
  return `\n[achilles] this rule block continues in ${subs} subsection${subs === 1 ? '' : 's'} (${s.text.length} chars total) — fetch Skill { skill: "${skill}", section: "${s.heading}" } before acting.`;
}

export const PENDING_HEADER = '── required, not included in full here: fetch each before you act ──';

/** A required block's line in the pending list; `partial` when its own rules are inlined above. */
function pendingLine(s: SkillSection, partial: boolean): string {
  return `  - ${'#'.repeat(s.level)} ${s.heading} (${s.text.length} chars)${partial ? ' — its own rules are inlined above; its subsections are not' : ''}`;
}

/**
 * The map of a large skill: its preamble, the always-required rule blocks that fit the budget, and a
 * table of contents. A required block is never cut in half — a half-rule reads as a different rule —
 * so one that does not fit is listed as mandatory reading to fetch instead, and one whose rules live
 * in subsections is BOTH inlined and listed, so an inlined stub can never pass for the whole block.
 * The table of contents absorbs the hard cap: it is the only part the budget may cut.
 */
export function skillMap(name: string, body: string, headMax = skillHeadMax()): { text: string; sections: SkillSection[] } {
  const sections = parseSections(body);
  const preamble = skillPreamble(body);
  const lead = `[achilles] Map of a ${body.trim().length}-char skill: its opening, the rules that always apply, and its sections. Fetch a section with Skill { skill: "${name}", section: "<heading>" } before acting on it.`;
  const parts = [lead, preamble];
  let used = lead.length + preamble.length + tableOfContents(sections, name).length + 200; // 200: the joins and the two markers below
  const included: string[] = [];
  const pending: Array<{ s: SkillSection; partial: boolean }> = [];
  for (const s of sections.filter((x) => x.required)) {
    // ownText, not text: a required `## ` heading's nested subsections are sections of their own and
    // are fetched by name; the required block is the rule text the heading itself carries.
    const subs = subsectionsOf(sections, s).length;
    const block = subs ? s.ownText + continuesNote(name, s, subs) : s.ownText;
    if (used + block.length <= headMax) {
      included.push(block);
      used += block.length;
      // Inlined but incomplete: it stays on the fetch-before-you-act list as well.
      if (subs) { pending.push({ s, partial: true }); used += pendingLine(s, true).length; }
    } else { pending.push({ s, partial: false }); used += pendingLine(s, false).length; }
  }
  if (included.length) parts.push(`── always required ──\n${included.join('\n\n')}`);
  if (pending.length) parts.push(`${PENDING_HEADER}\n${pending.map((p) => pendingLine(p.s, p.partial)).join('\n')}`);
  // Hard cap: whatever room the rule blocks left goes to the table of contents, and it is cut to fit.
  const room = headMax - (parts.join('\n\n').length + 2);
  parts.push(capTableOfContents(tableOfContents(sections, name), room, name));
  return { text: parts.join('\n\n'), sections };
}

/**
 * `toc` cut to `room` chars on line boundaries, with a line naming how many sections it left out and
 * how to ask for one by number. Cutting the table of contents is always preferable to cutting a rule,
 * so the map's floor is its lead, its preamble and its required blocks — a headMax below that floor
 * cannot be honoured and this returns the shortest useful listing instead.
 */
export function capTableOfContents(toc: string, room: number, skill: string): string {
  if (toc.length <= room) return toc;
  const [head, ...lines] = toc.split('\n');
  const more = (n: number) => `  … ${n} more section${n === 1 ? '' : 's'} not listed — ask by number: Skill { skill: "${skill}", section: "<n>" }.`;
  const reserve = more(lines.length).length;
  if (room < head.length + 1 + reserve) return more(lines.length);
  const kept: string[] = [];
  let used = head.length;
  for (const l of lines) {
    if (used + 1 + l.length + 1 + reserve > room) break;
    kept.push(l); used += 1 + l.length;
  }
  const left = lines.length - kept.length;
  return [head, ...kept, ...(left ? [more(left)] : [])].join('\n');
}

/**
 * A fetched section, bounded. One fetch could still be enormous: journey-mapping's discovery-cycles
 * section is 37,222 chars — 69% of the whole skill — and failure-diagnosis's pipeline is 51,651. Over
 * ACHILLES_PI_SECTION_MAX a section comes back as its own prose plus a table of contents of its
 * immediate subsections, each addressed the way round 3's ambiguity reply addresses a candidate, so
 * the printed move resolves on the retry.
 *
 * TWO kinds of section are never split, and the reply says which case it is rather than truncating:
 *  - one with no subsections, because there is nothing to split into and cutting prose mid-sentence
 *    is how a rule becomes a different rule;
 *  - an ALWAYS-REQUIRED rule block, because splitting one is exactly the fault round 3 fixed twice.
 *    achilles-protocol's `## 🚨 ABSOLUTE RULES` carries 290 chars of own text over 22,283 chars of
 *    rules held in 17 subsections, none of whose headings match REQUIRED_HEADING; a bounded view of it
 *    would read as the complete rule set while containing none of the rules. The model asked for the
 *    rules, so it gets the rules.
 *
 * A required subsection of a split section is BOTH marked in the listing and repeated under the
 * fetch-before-you-act header, the same contract the map uses for a required block that did not fit.
 */
export function sectionView(
  skill: string,
  s: SkillSection,
  sections: SkillSection[],
  max = sectionMax(),
): { text: string; bounded: boolean } {
  const kids = childrenOf(sections, s);
  if (s.text.length <= max) return { text: s.text, bounded: false };
  if (s.required) {
    return { text: `${s.text}

[achilles] this section is ${s.text.length} chars, over the ${max}-char section budget, and it is an always-required rule block: it is returned whole rather than split, because a part of a rule block reads as a different rule.`, bounded: false };
  }
  if (!kids.length) {
    return { text: `${s.text}

[achilles] this section is ${s.text.length} chars, over the ${max}-char section budget, but it has no subsections to split into, so it is returned whole rather than truncated.`, bounded: false };
  }
  const req = subsectionsOf(sections, s).filter((x) => x.required);
  // Each line prints the query that fetches that subsection, verified against findSection, not its
  // bare heading: several skills repeat a subsection heading, and a listing that offers a name which
  // resolves to a sibling is worse than no listing.
  const listing = kids.map((k, i) => {
    const nestedReq = subsectionsOf(sections, k).some((x) => x.required);
    const mark = k.required || nestedReq ? ' [required reading]' : '';
    return `${String(i + 1).padStart(2)}. "${addressOf(sections, k)}" (${k.text.length} chars)${mark}`;
  });
  const parts = [
    s.ownText,
    `[achilles] NOT the whole section. "${s.heading}" is ${s.text.length} chars, over the ${max}-char section budget (ACHILLES_PI_SECTION_MAX); its own text is above and its ${kids.length} subsection${kids.length === 1 ? '' : 's'} ${kids.length === 1 ? 'is' : 'are'} listed below, not included. Fetch each one you need before you act on it.`,
    `Subsections — fetch one with Skill { skill: "${skill}", section: "<one of the quoted names below, verbatim>" }:\n${listing.join('\n')}`,
  ];
  if (req.length) {
    parts.push(`${PENDING_HEADER}\n${req.map((x) => `  - ${'#'.repeat(x.level)} ${x.heading} (${x.text.length} chars) — Skill { skill: "${skill}", section: "${addressOf(sections, x)}" }`).join('\n')}`);
  }
  return { text: parts.join('\n\n'), bounded: true };
}

/**
 * The response when `section` matches nothing or several headings: the map plus the candidates, each
 * written in a form that resolves on the retry. Five coverage-expansion subsections share the heading
 * `Hard rules — kernel-resident`, so "ask for the heading exactly" was not a move the model could
 * make; `"<parent> > <child>"` is, and findSection accepts it.
 */
function ambiguous(name: string, body: string, query: string, candidates: SkillSection[], sections: SkillSection[]): string {
  const where = (c: SkillSection) => { const p = parentOf(sections, c); return p ? `"${p.heading} > ${c.heading}"` : `"${c.heading}"`; };
  const head = candidates.length
    ? `[achilles] section "${query}" matches ${candidates.length} headings. Ask for one of these exactly, as written:\n${candidates
        .map((c) => `  - Skill { skill: "${name}", section: ${where(c)} }  (${c.text.length} chars)`)
        .join('\n')}`
    : `[achilles] no section of "${name}" matches "${query}". Pick one from the list below, by heading, by number, or as "<parent> > <child>".`;
  return `${head}\n\n${skillMap(name, body).text}`;
}

/** Why a `section` argument did not narrow the response, for a skill returned whole anyway. */
function droppedSectionNote(query: string, candidates: number, chars: number): string {
  const why = candidates ? `matches ${candidates} headings` : 'matches no heading';
  return `[achilles] section "${query}" ${why} of this skill; it is ${chars} chars, so here it is whole. Fetch one section by its exact heading, or as "<parent> > <child>".`;
}

export function registerSkillTool(pi: ExtensionAPI, opts: { roots: string[] }): void {
  pi.registerTool({
    name: 'Skill',
    label: 'Skill',
    description: 'Load an achilles methodology skill by name and return its instructions. A large skill comes back as a map (preamble, always-required rules, table of contents); pass `section` to get one section in full. Subagent-only skills are refused here: delegate them with the Agent tool instead.',
    promptSnippet: 'Skill: load an achilles skill by name ({ skill: "<name>" }), then one section of it ({ skill, section: "<heading>" })',
    parameters: Type.Object({
      skill: Type.String({ description: 'Skill name, e.g. "onboarding"' }),
      section: Type.Optional(Type.String({ description: 'A `## `/`### ` heading of the skill (substring, case-insensitive); returns that section in full' })),
      args: Type.Optional(Type.String({ description: 'Optional arguments appended as the user request' })),
    }),
    async execute(_id, params) {
      const s = resolveSkill(params.skill, opts.roots);
      if (!s) throw new Error(`Unknown skill "${params.skill}". Known skills: ${listSkills(opts.roots).join(', ')}`);
      // Only the orchestrator (depth 0) is refused a subagent-only skill; inside a subagent it is
      // exactly the skill the child was dispatched to load (e.g. workflow-reviewer).
      const refuse = s.subagentOnly && piDepth() === 0;
      if (refuse) {
        log('skill', { skill: s.name, refused: true });
        return {
          content: [{ type: 'text', text: `Skill "${s.name}" is subagent-only and must not be loaded into the orchestrator. Delegate it: Agent { skill: "${s.name}", description: "<role-prefix>: <what>", prompt: "<brief>" }.` }],
          details: { skill: s.name, refused: true },
        };
      }
      const body = s.body.trim();
      const args = params.args ? `\n\nUser request: ${params.args}` : '';
      // An explicit `section` is honoured at ANY depth and at any body size: asking for one section
      // can only narrow what comes back, and a child on a small model that asks for
      // achilles-protocol §subagent-return-schema must not be handed the whole 57k body instead.
      // ACHILLES_PI_VERBOSE=1 stays the one bypass — it turns every context compaction off — and the
      // response says so rather than dropping the argument in silence.
      if (params.section && !piVerbose()) {
        const all = parseSections(body);
        const { section, candidates } = findSection(all, params.section);
        if (section) {
          // Over ACHILLES_PI_SECTION_MAX a splittable section arrives as its own prose plus a listing
          // of its subsections, so one fetch is never 37k chars; a rule block and a childless section
          // still arrive whole (see sectionView).
          const view = sectionView(s.name, section, all);
          log('skill', { skill: s.name, section: params.section, matched: section.heading, candidates: 0, chars: view.text.length, sectionChars: section.text.length, bounded: view.bounded, view: 'section' });
          return {
            content: [{ type: 'text', text: wrap(s.name, s.file, view.text, 'section') + args }],
            details: { skill: s.name, path: s.file, view: 'section', section: section.heading, candidates: [], chars: view.text.length, sectionChars: section.text.length, bounded: view.bounded },
          };
        }
        // No unique match. For a skill small enough to return whole, the whole body IS the answer and
        // a map of it would be the bigger surprise — so it comes back full, with the miss named.
        if (body.length < fullBelow()) {
          const text = `${body}\n\n${droppedSectionNote(params.section, candidates.length, body.length)}`;
          log('skill', { skill: s.name, section: params.section, candidates: candidates.length, chars: body.length, view: 'full' });
          return {
            content: [{ type: 'text', text: wrap(s.name, s.file, text) + args }],
            details: { skill: s.name, path: s.file, view: 'full', candidates: candidates.map((c) => c.heading), chars: body.length, sectionDropped: params.section },
          };
        }
        const text = ambiguous(s.name, body, params.section, candidates, all);
        log('skill', { skill: s.name, section: params.section, candidates: candidates.length, chars: text.length, view: 'map' });
        return {
          content: [{ type: 'text', text: wrap(s.name, s.file, text, 'map') + args }],
          details: { skill: s.name, path: s.file, view: 'map', candidates: candidates.map((c) => c.heading), chars: text.length },
        };
      }
      // A child is dispatched for one job and holds only its own skill, so it gets a more generous
      // whole-body budget (ACHILLES_PI_SKILL_CHILD_FULL_BELOW) than the orchestrator — but not an
      // unbounded one: on a 32k-context model the six heaviest skills are 54k-89k chars (~13-22k
      // tokens) and would leave almost nothing for the work, so above that threshold a child gets the
      // same map, required rule blocks and all. ACHILLES_PI_VERBOSE=1 still returns every body whole.
      const sectioned = !piVerbose() && body.length >= fullBelow();
      if (!sectioned) {
        const note = params.section ? `\n\n[achilles] section "${params.section}" not applied: ACHILLES_PI_VERBOSE=1 returns every skill whole.` : '';
        log('skill', { skill: s.name, chars: body.length, view: 'full', ...(params.section ? { sectionDropped: params.section } : {}) });
        return { content: [{ type: 'text', text: wrap(s.name, s.file, body + note) + args }], details: { skill: s.name, path: s.file, view: 'full', chars: body.length, ...(params.section ? { sectionDropped: params.section } : {}) } };
      }
      const { text, sections } = skillMap(s.name, body);
      log('skill', { skill: s.name, chars: text.length, bodyChars: body.length, sections: sections.length, view: 'map' });
      return {
        content: [{ type: 'text', text: wrap(s.name, s.file, text, 'map') + args }],
        details: { skill: s.name, path: s.file, view: 'map', chars: text.length, bodyChars: body.length, sections: sections.filter((x) => x.level === 2).map((x) => x.heading) },
      };
    },
  });
}
