// pi/extensions/achilles/prompt.ts — compact the achilles entries in pi's skill listing.
//
// pi lists every discovered skill in the system prompt with its full frontmatter description. The
// achilles descriptions are long trigger lists written for Claude Code's skill router (8k+ tokens for
// the 24 skills), which a small local model pays for on every turn, in the orchestrator and in every
// subagent. At before_agent_start this rewrites each achilles entry's description in the mutable
// systemPromptOptions (pi re-renders the prompt from them) to one short line: the skill's hand-written
// `pi-description:` routing line when it has one, else the first sentence. Other skills are untouched.
import path from 'node:path';
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { listSkills, resolveSkill, PACKAGE_DIR } from './skills.ts';
import { piDepth } from './env.ts';
import { log } from './log.ts';

export const DESCRIPTION_CAP = 160;

/** A leading "Subagent-only." / "Subagent-only skill." sentence carries no routing information once
 * the skill is being described inside a subagent, so the first-sentence form skips it. */
const SUBAGENT_ONLY_LEAD = /^Subagent-only(?: skill)?\.\s+/i;

/** Strip YAML fold indicators and markdown emphasis (`**x**`, `__x__`, `*x*`); keep backticks. */
function plain(text: string): string {
  return text
    .replace(/^[>|][-+]?\s*/, '')
    .replace(/\*\*([^*]+)\*\*/g, '$1')
    .replace(/__([^_]+)__/g, '$1')
    .replace(/(^|[\s(])\*([^*\s][^*]*)\*/g, '$1$2')
    .replace(/\s+/g, ' ')
    .trim();
}

/** Cut at a word boundary to at most `cap` chars, ending in "…" when anything was cut. */
function clip(text: string, cap: number): string {
  if (text.length <= cap) return text;
  const room = text.slice(0, cap - 1);
  const sp = room.lastIndexOf(' ');
  return `${(sp > cap / 2 ? room.slice(0, sp) : room).replace(/[\s,;:—–-]+$/, '')}…`;
}

/** The first sentence of a skill description, emphasis stripped, capped at `cap` chars. A sentence
 * ends at . ! or ? followed by whitespace and a capital (or the end), so "e.g. foo" does not end one. */
export function firstSentence(description: string, cap = DESCRIPTION_CAP): string {
  const text = plain(description).replace(SUBAGENT_ONLY_LEAD, '');
  const m = text.match(/^[\s\S]*?[.!?](?=\s+[A-Z"'`(\[]|\s*$)/);
  return clip((m ? m[0] : text).trim(), cap);
}

export function delegateLine(name: string): string {
  return `Subagent-only — delegate with Agent { skill: "${name}" }; do not read it here.`;
}

export const PI_DESCRIPTION_CAP = 200;
export const DISPATCHED_PREFIX = 'Your dispatched methodology — read this skill before starting: ';

/** A subagent-only routing line without its delegate wording ("Subagent-only — …: delegate with
 * Agent { … }."), leaving what the skill is for. */
export function stripDelegate(line: string): string {
  const t = line
    .replace(/^Subagent-only(?: skill)?\s*[—–:-]?\s*/i, '')
    .replace(/[\s:;,—–-]*delegate (?:it )?with Agent \{[^}]*\}[^.]*\.?/i, '')
    .replace(/[\s;,]*do not read it here\.?/i, '')
    .trim()
    .replace(/[\s:;,—–-]+$/, '');
  return t && !/[.!?]$/.test(t) ? `${t}.` : t;
}

/**
 * The listing line for one achilles skill. `piDescription` (the skill's hand-written `pi-description:`
 * routing line) wins over the first sentence of the Claude Code description.
 * - depth 0, subagent-only: the routing line (it carries the delegate instruction), else the bare delegate line.
 * - depth 0, other skills: the routing line, else the first sentence.
 * - depth >= 1, any skill: this child was dispatched to run it (under --no-skills it is the only
 *   achilles skill listed), so "Your dispatched methodology — read this skill before starting: …".
 */
export function compactDescription(name: string, description: string, subagentOnly: boolean, depth: number, piDescription?: string): string {
  const routing = piDescription ? clip(plain(piDescription), PI_DESCRIPTION_CAP) : undefined;
  if (depth === 0) return subagentOnly ? routing ?? delegateLine(name) : routing ?? firstSentence(description);
  // Inside a subagent the child runs with --no-skills, so the only achilles skill listed is the one it
  // was dispatched with: tell it to read that skill first, whatever its class.
  const what = (routing && stripDelegate(routing)) || firstSentence(description);
  return `${DISPATCHED_PREFIX}${what}`;
}

interface ListedSkill { name: string; description: string }

export interface PromptCompactor {
  /** Rewrites achilles entries in place; returns how many were compacted. */
  compact(skills: ListedSkill[], depth?: number): number;
  /** True for an achilles skill carrying `pi-listing: off`. False for every non-achilles skill —
   * this adapter compacts other people's skills but never removes them. */
  isHidden(name: string): boolean;
}

/** `root` is the achilles skills directory: it defines which names are achilles skills and which of
 * them are subagent-only. Results are cached per (depth, name, original description). */
export function createPromptCompactor(root = path.join(PACKAGE_DIR, 'skills')): PromptCompactor {
  let names: Set<string> | undefined;
  const info = new Map<string, { subagentOnly: boolean; piDescription?: string; piHidden?: boolean }>();
  const cache = new Map<string, string>();
  return {
    isHidden(name: string) {
      if (!names) names = new Set(listSkills([root]));
      if (!names.has(name)) return false;   // never touch a non-achilles skill
      if (!info.has(name)) { const r = resolveSkill(name, [root]); info.set(name, { subagentOnly: r?.subagentOnly ?? false, piDescription: r?.piDescription, piHidden: r?.piHidden ?? false }); }
      return info.get(name)!.piHidden === true;
    },
    compact(skills, depth = piDepth()) {
      names ??= new Set(listSkills([root]));
      let n = 0;
      for (const s of skills) {
        if (!names.has(s.name) || typeof s.description !== 'string') continue;
        const key = `${depth}\0${s.name}\0${s.description}`;
        let out = cache.get(key);
        if (out === undefined) {
          if (!info.has(s.name)) { const r = resolveSkill(s.name, [root]); info.set(s.name, { subagentOnly: r?.subagentOnly ?? false, piDescription: r?.piDescription, piHidden: r?.piHidden ?? false }); }
          const i = info.get(s.name)!;
          out = compactDescription(s.name, s.description, i.subagentOnly, depth, i.piDescription);
          cache.set(key, out);
        }
        s.description = out;
        n++;
      }
      return n;
    },
  };
}

/** The skills block of a rendered system prompt (pi's formatSkillsForPrompt output), or "". */
export function skillsSection(systemPrompt: string): string {
  const start = systemPrompt.indexOf('The following skills provide specialized instructions');
  const end = systemPrompt.indexOf('</available_skills>');
  return start >= 0 && end > start ? systemPrompt.slice(start, end + '</available_skills>'.length) : '';
}

/**
 * Drop `pi-listing: off` skills from the ORCHESTRATOR's listing, in place.
 *
 * Depth 0 only. A dispatched child's listing already holds just the skill it was sent with, and
 * removing that would leave it with nothing to follow. The skill stays resolvable by name through
 * the Skill tool at either depth, so this hides a standing advertisement, not a capability.
 */
export function hideUnlisted(skills: Array<{ name: string }>, isHidden: (name: string) => boolean): string[] {
  const dropped: string[] = [];
  for (let i = skills.length - 1; i >= 0; i--) {
    if (isHidden(skills[i].name)) { dropped.push(skills[i].name); skills.splice(i, 1); }
  }
  return dropped.reverse();
}

export function registerPromptCompaction(pi: ExtensionAPI, root?: string): void {
  const compactor = createPromptCompactor(root);
  pi.on('before_agent_start', async (event) => {
    try {
      const skills = event.systemPromptOptions?.skills;
      const hidden = Array.isArray(skills) && piDepth() === 0
        ? hideUnlisted(skills, (n) => compactor.isHidden(n))
        : [];
      const compacted = Array.isArray(skills) ? compactor.compact(skills) : 0;
      if (process.env.ACHILLES_PI_LOG) {
        const sp = event.systemPrompt;
        log('prompt_size', { depth: String(piDepth()), chars: sp.length, skillsChars: skillsSection(sp).length, compacted, hidden, skills: (skills ?? []).map((s) => s.name) });
      }
    } catch (err) {
      log('handler_error', { event: 'before_agent_start', error: String(err) });
    }
    return undefined;
  });
}
