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
 * - depth >= 1, subagent-only: this child was dispatched to run it, so a positive line, not a prohibition.
 */
export function compactDescription(name: string, description: string, subagentOnly: boolean, depth: number, piDescription?: string): string {
  const routing = piDescription ? clip(plain(piDescription), PI_DESCRIPTION_CAP) : undefined;
  if (subagentOnly && depth === 0) return routing ?? delegateLine(name);
  if (subagentOnly) {
    const what = (routing && stripDelegate(routing)) || firstSentence(description);
    return `${DISPATCHED_PREFIX}${what}`;
  }
  return routing ?? firstSentence(description);
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
  const info = new Map<string, { subagentOnly: boolean; piDescription?: string }>();
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
          if (!info.has(s.name)) { const r = resolveSkill(s.name, [root]); info.set(s.name, { subagentOnly: r?.subagentOnly ?? false, piDescription: r?.piDescription }); }
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
