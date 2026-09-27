import { Type } from 'typebox';
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { resolveSkill, listSkills, parseSections, findSection, parentOf, subsectionsOf, skillPreamble, tableOfContents, type SkillSection } from './skills.ts';
import { log } from './log.ts';
import { piDepth, piVerbose, skillFullBelow, skillHeadMax } from './env.ts';

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

/** The response when `section` matches nothing or several headings: the map plus the candidates. */
function ambiguous(name: string, body: string, query: string, candidates: SkillSection[], sections: SkillSection[]): string {
  const where = (c: SkillSection) => { const p = parentOf(sections, c); return p ? `"${c.heading}" (under "${p.heading}")` : `"${c.heading}"`; };
  const head = candidates.length
    ? `[achilles] section "${query}" matches ${candidates.length} headings: ${candidates.map(where).join(', ')}. Ask for one heading exactly, for the section it sits under, or for its number in the list below.`
    : `[achilles] no section of "${name}" matches "${query}". Pick one from the list below, by heading or by number.`;
  return `${head}\n\n${skillMap(name, body).text}`;
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
      // A child holds only its own skill, so it gets the whole body; so does a small skill, and so
      // does every call under ACHILLES_PI_VERBOSE=1 (it turns every context compaction off).
      const sectioned = piDepth() === 0 && !piVerbose() && body.length >= skillFullBelow();
      if (!sectioned) {
        log('skill', { skill: s.name, chars: body.length, view: 'full' });
        return { content: [{ type: 'text', text: wrap(s.name, s.file, body) + args }], details: { skill: s.name, path: s.file, view: 'full', chars: body.length } };
      }
      if (params.section) {
        const all = parseSections(body);
        const { section, candidates } = findSection(all, params.section);
        const text = section ? section.text : ambiguous(s.name, body, params.section, candidates, all);
        log('skill', { skill: s.name, section: params.section, matched: section?.heading, candidates: candidates.length, chars: text.length, view: 'section' });
        return {
          content: [{ type: 'text', text: wrap(s.name, s.file, text, section ? 'section' : 'map') + args }],
          details: { skill: s.name, path: s.file, view: section ? 'section' : 'map', section: section?.heading, candidates: candidates.map((c) => c.heading), chars: text.length },
        };
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
