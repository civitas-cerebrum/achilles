import fs from 'node:fs';
import path from 'node:path';
import { resolveSkill } from './skills.ts';
import { piDepth } from './env.ts';

const SKILL_REF = /\bskills\/([a-z0-9][a-z0-9-]*)\/([A-Za-z0-9_./-]+)/g;
const SCHEMA_REF = /\bschemas\/([A-Za-z0-9_./-]+\.json)\b/g;
/** A `§section` right after the path, on the same line (hooks align it with spaces). */
const SECTION_AFTER = /^[ \t]*§/;

export interface SteerOptions { roots: string[]; packageDir: string; depth?: number }

/**
 * Rewrite methodology references to absolute paths and append the right pi move per skill.
 *
 * - A hint is appended only for a bare `skills/<name>/SKILL.md` citation (the hook is pointing at
 *   the whole skill). `SKILL.md §section` and `references/*` citations point at something to read;
 *   the absolute path is enough and no hint is added.
 * - In a subagent (depth >= 1) every hint is "Load it": the child is where heavy skills belong.
 * - In the orchestrator (depth 0) a subagent-only skill's files are left as relative citations (the
 *   orchestrator must not read them; the bridge blocks such reads) and the hint is "Delegate it".
 */
export function steer(text: string, opts: SteerOptions): string {
  const depth = opts.depth ?? piDepth();
  const hinted = new Map<string, boolean>(); // skill name -> subagentOnly, bare SKILL.md citations only
  let out = text.replace(SKILL_REF, (whole: string, name: string, rel: string, offset: number, all: string) => {
    const skill = resolveSkill(name, opts.roots);
    if (!skill) return whole;
    const sectioned = SECTION_AFTER.test(all.slice(offset + whole.length));
    if (rel === 'SKILL.md' && !sectioned) hinted.set(name, skill.subagentOnly);
    if (skill.subagentOnly && depth === 0) return whole;
    const abs = path.join(skill.dir, rel);
    return fs.existsSync(abs) ? abs : whole;
  });
  // Hook texts always cite real on-disk schema paths (full relative path, e.g.
  // "schemas/subagent-returns/workflow-reviewer.schema.json"), so gate the rewrite on existence
  // just like skill refs — a reference to a schema that doesn't exist under packageDir is left
  // as-is rather than turned into a misleading absolute path.
  out = out.replace(SCHEMA_REF, (whole, rel: string) => {
    const abs = path.join(opts.packageDir, 'schemas', rel);
    return fs.existsSync(abs) ? abs : whole;
  });
  if (hinted.size === 0) return out;
  const hints = [...hinted].map(([name, sub]) => sub && depth === 0
    ? `Delegate it: Agent { skill: "${name}", description: "<role-prefix>: <what>", prompt: "<brief>" } — this skill is subagent-only and must not be loaded into the orchestrator.`
    : `Load it: Skill { skill: "${name}" }`);
  return `${out}\n\nUnder pi:\n  ${hints.join('\n  ')}`;
}

// ── Hook message compaction ──────────────────────────────────────────────────────────────────────
// Hooks are written for Claude Code, where a repeated notice costs little. Under pi on a small local
// model every repeat is context, so per bridge session: the session-scope notice is shown once, an
// identical deny collapses to one line after the first, and a non-blocking warning reaches the model in
// full (capped at 1,200 chars) the first time and as one line on a repeat (the UI and log get it all).
// ACHILLES_PI_VERBOSE=1 turns all of this off.

const SCOPE_BLOCK = /── achilles session-scope ─*[\s\S]*?(?:their call, not yours\.\)|$)/;
export const SCOPE_POINTER = '(achilles session-scope notice applies — see the first block this session.)';
const LINE_CAP = 200;
const CONTEXT_CAP = 1000;
const WARNING_CAP = 1200;
export const WARNING_TRUNCATED = '… [achilles] truncated; full text in the UI/log';

/** At most `cap` chars (marker included), cut at a line boundary, with the truncation marker. */
export function capAtLine(text: string, cap = WARNING_CAP): string {
  if (text.length <= cap) return text;
  const room = text.slice(0, cap - WARNING_TRUNCATED.length - 1);
  const nl = room.lastIndexOf('\n');
  return `${(nl > 0 ? room.slice(0, nl) : room).trimEnd()}\n${WARNING_TRUNCATED}`;
}

export const verboseMessages = (): boolean => process.env.ACHILLES_PI_VERBOSE === '1';

function clipTo(text: string, cap: number): string {
  return text.length <= cap ? text : `${text.slice(0, cap - 1).trimEnd()}…`;
}

/** First non-empty line, trimmed, at most 200 chars. */
export function firstLine(text: string): string {
  return clipTo((text.split(/\r?\n/).find((l) => l.trim()) ?? '').trim(), LINE_CAP);
}

/** The `References:` block's entries collapsed onto one line ("References: a; b"), or "". */
export function referencesLine(text: string): string {
  const lines = text.split(/\r?\n/);
  const i = lines.findIndex((l) => /^\s*References:\s*$/.test(l));
  if (i < 0) {
    const inline = lines.find((l) => /^\s*References?:\s*\S/.test(l));
    return inline ? inline.trim() : '';
  }
  const refs: string[] = [];
  for (const l of lines.slice(i + 1)) { if (!l.trim()) break; refs.push(l.trim()); }
  return refs.length ? `References: ${refs.join('; ')}` : '';
}

/** Key for "the same warning again": the hook plus its first line with digit runs (run ids,
 * timestamps, counts) folded, so the archiver's per-run message counts as a repeat. */
const warnKey = (hook: string, text: string) => `${hook}\0${firstLine(text).replace(/\d+/g, '#')}`;

export type NoteKind = 'systemMessage' | 'additionalContext' | 'reason';

export interface MessageCompactor {
  reset(): void;
  /** The session-scope notice kept the first time, a one-line pointer afterwards. */
  scope(text: string): string;
  /** A blocking reason (deny, PostToolUse/Stop block): full the first time per (hook, first line). */
  deny(hook: string, reason: string): string;
  /** Non-blocking hook output that reaches the model. */
  note(hook: string, text: string, kind: NoteKind): string;
}

export function createMessageCompactor(): MessageCompactor {
  let scopeSeen = false;
  const denies = new Map<string, string>();
  const warnings = new Set<string>();
  const self: MessageCompactor = {
    reset() { scopeSeen = false; denies.clear(); warnings.clear(); },
    scope(text) {
      if (verboseMessages() || !SCOPE_BLOCK.test(text)) return text;
      if (!scopeSeen) { scopeSeen = true; return text; }
      return text.replace(SCOPE_BLOCK, SCOPE_POINTER);
    },
    deny(hook, reason) {
      if (verboseMessages()) return reason;
      // Keyed by (hook, first line); collapsed only when the body (scope notice aside) is identical to
      // the last one under that key, so a repeat with new details (another schema error) still shows.
      const key = `${hook}\0${firstLine(reason)}`;
      const body = reason.replace(SCOPE_BLOCK, '').trim();
      if (denies.get(key) === body) return `[achilles] ${hook}: same block as before — ${firstLine(reason)}. Apply the fix from the earlier message.`;
      denies.set(key, body);
      return self.scope(reason);
    },
    note(hook, text, kind) {
      if (verboseMessages()) return text;
      const key = warnKey(hook, text);
      if (warnings.has(key)) return `[achilles] ${hook}: repeated warning (see earlier).`;
      warnings.add(key);
      if (kind === 'additionalContext') return clipTo(self.scope(text), CONTEXT_CAP);
      // First sight: the whole warning (it steers the model, e.g. a schema guard's issue list), capped.
      return capAtLine(self.scope(text));
    },
  };
  return self;
}
