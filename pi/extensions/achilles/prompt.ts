// pi/extensions/achilles/prompt.ts — compact the achilles entries in pi's skill listing.
//
// pi lists every discovered skill in the system prompt with its full frontmatter description. The
// achilles descriptions are long trigger lists written for Claude Code's skill router (8k+ tokens for
// the 24 skills), which a small local model pays for on every turn, in the orchestrator and in every
// subagent. At before_agent_start this rewrites each achilles entry's description in the mutable
// systemPromptOptions (pi re-renders the prompt from them) to one short line. Other skills are untouched.
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

export function compactDescription(name: string, description: string, subagentOnly: boolean, depth: number): string {
  return subagentOnly && depth === 0 ? delegateLine(name) : firstSentence(description);
}

interface ListedSkill { name: string; description: string }

export interface PromptCompactor {
  /** Rewrites achilles entries in place; returns how many were compacted. */
  compact(skills: ListedSkill[], depth?: number): number;
}

/** `root` is the achilles skills directory: it defines which names are achilles skills and which of
 * them are subagent-only. Results are cached per (depth, name, original description). */
export function createPromptCompactor(root = path.join(PACKAGE_DIR, 'skills')): PromptCompactor {
  let names: Set<string> | undefined;
  const subOnly = new Map<string, boolean>();
  const cache = new Map<string, string>();
  return {
    compact(skills, depth = piDepth()) {
      names ??= new Set(listSkills([root]));
      let n = 0;
      for (const s of skills) {
        if (!names.has(s.name) || typeof s.description !== 'string') continue;
        const key = `${depth}\0${s.name}\0${s.description}`;
        let out = cache.get(key);
        if (out === undefined) {
          if (!subOnly.has(s.name)) subOnly.set(s.name, resolveSkill(s.name, [root])?.subagentOnly ?? false);
          out = compactDescription(s.name, s.description, subOnly.get(s.name) ?? false, depth);
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

export function registerPromptCompaction(pi: ExtensionAPI, root?: string): void {
  const compactor = createPromptCompactor(root);
  pi.on('before_agent_start', async (event) => {
    try {
      const skills = event.systemPromptOptions?.skills;
      const compacted = Array.isArray(skills) ? compactor.compact(skills) : 0;
      if (process.env.ACHILLES_PI_LOG) {
        const sp = event.systemPrompt;
        log('prompt_size', { depth: String(piDepth()), chars: sp.length, skillsChars: skillsSection(sp).length, compacted, skills: (skills ?? []).map((s) => s.name) });
      }
    } catch (err) {
      log('handler_error', { event: 'before_agent_start', error: String(err) });
    }
    return undefined;
  });
}
