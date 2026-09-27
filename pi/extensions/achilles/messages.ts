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

// ── Operator-only denies ─────────────────────────────────────────────────────────────────────────
// Some denies can only be cleared by a person (a tampered hash chain, a deleted ledger). A small model
// otherwise tries to work around them: it reads the hook source, recomputes the hash, or retries the
// write through the shell. Every such deny, first or repeated, ends with one line telling it to stop.
// The phrases are the ones hooks use when recovery is the operator's alone. Broader phrases ("in their
// own terminal", "operator action") also appear in denies the agent CAN fix itself (the bash guard's
// "use the Write/Edit tool", the progress-state monotonicity guard), so they do not trigger it.
export const OPERATOR_STOP = '[achilles] Stop here: report this to the user and wait. Do not read hook sources, recompute hashes, or retry through the shell.';
const OPERATOR_ONLY = /surface this to the user|recovery is an operator action|the agent cannot self-clear|only a person may|until the operator confirms|not an agent action/i;

/** True when the deny's recovery is a human action the agent cannot take. */
export const operatorOnly = (reason: string): boolean => OPERATOR_ONLY.test(reason);

/** `text` with the stop line appended when `reason` is operator-only (and not already there). */
export function withOperatorStop(reason: string, text: string): string {
  if (!operatorOnly(reason) || text.trimEnd().endsWith(OPERATOR_STOP)) return text;
  return `${text}\n${OPERATOR_STOP}`;
}

// ── Hook message compaction ──────────────────────────────────────────────────────────────────────
// Hooks are written for Claude Code, where a repeated notice costs little. Under pi on a small local
// model every repeat is context, so per bridge session: the session-scope notice is shown once, an
// identical deny collapses to one line after the first, and a non-blocking warning reaches the model in
// full (capped at 1,200 chars) the first time and as one line on a repeat (the UI and log get it all).
// ACHILLES_PI_VERBOSE=1 turns all of this off.

const SCOPE_BLOCK = /── achilles session-scope ─*[\s\S]*?(?:their call, not yours\.\)|$)/;
export const SCOPE_POINTER = '(achilles session-scope notice applies — see the first block this session.)';
// hooks/lib/no-skip-messaging.sh rides on most onboarding-pipeline warnings and denies: ~900 fixed
// chars of contract text, unchanged every time. Measured: 12 of 17 Agent returns in one run drew a
// warning carrying it. The first sighting steers; later ones are a pointer, like the scope notice.
// The match REQUIRES the canonical closing `Reference: skills/onboarding/SKILL.md` line: with `$` as an
// alternative closer, a 344-char deny that merely said "the onboarding contract" mid-text had its own
// `Fix:` line and `References:` block replaced by the pointer instead.
const NO_SKIP_BLOCK = /(?:[─━═]{3,}\r?\n)?[^\n]*(?:No-skip|no-skip messaging|onboarding contract)[^\n]*\r?\n[\s\S]{0,2000}?Reference: skills\/onboarding\/SKILL\.md[^\n]*/;
export const NO_SKIP_POINTER = '(achilles no-skip onboarding contract applies — see the first block this session.)';
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

/** Key for "the same warning again": the hook plus its WHOLE text, normalised so that only per-run
 * noise differs: `.achilles/runs/<id>` masked and digit runs (timestamps, counts) folded. Hooks such as
 * subagent-return-schema-guard use a constant first line, so a first-line key would merge different
 * problems; a whole-text key keeps a second, different issue list visible. */
export const warnKey = (hook: string, text: string) =>
  `${hook}\0${text.replace(/\.achilles\/runs\/[^\s/]+/g, '.achilles/runs/<id>').replace(/\d+/g, '#').replace(/\s+/g, ' ').trim()}`;

const FIX_CAP = 300;

/** The deny's own fix: a "Fix:" / "Fix (…):" / "Do this instead:" / "Do this instead — <what>:" line
 * and the lines under it, up to the next blank line (box-drawing separator lines skipped), joined onto
 * one line and capped at 300 chars; "" when there is none. */
export function fixLines(text: string): string {
  const lines = text.split(/\r?\n/);
  const i = lines.findIndex((l) => /^\s*(?:Fix\b[^:\n]{0,30}|Do this instead\b[^:\n]{0,80}):/i.test(l));
  if (i < 0) return '';
  const block: string[] = [];
  for (const l of lines.slice(i)) {
    if (!l.trim()) break;
    if (/^[\s─━═—-]+$/.test(l)) continue; // a "────" rule under the heading
    block.push(l.trim().replace(/\s+/g, ' '));
  }
  return clipTo(block.join(' '), FIX_CAP);
}

/** The one-line stand-in for an identical repeat of a block. It stays usable on its own (pi may have
 * compacted the earlier message away): it carries the block's first line and its fix lines. */
export function repeatBlockLine(hook: string, reason: string): string {
  const head = firstLine(reason).replace(/[.\s]+$/, '');
  const fix = fixLines(reason);
  return `[achilles] ${hook}: same block as before — ${head}. ${fix ? fix : 'Apply the fix from the earlier message.'}`;
}

/** Hooks whose warning body is a fixed shape around a variable issue list: a repeat is worth one line.
 * subagent-return-schema-guard.sh is the only one in the manifest today (9 of 17 Agent returns in one
 * measured run drew a PARSE_FAIL/SCHEMA_FAIL warning; the orchestrator acted on none of them). */
const SHAPED_WARN_HOOK = /subagent-return-schema(?:-return)?-guard/;

/** The role a schema-guard warning names ("Role:        reviewer"), or '?'. */
export function warnRole(text: string): string {
  const m = /^\s*Role:\s*(\S.*?)\s*$/m.exec(text) ?? /^\s*Description:\s*"?([^"\n]+)"?\s*$/m.exec(text);
  return m ? clipTo(m[1].trim(), LINE_CAP) : '?';
}

/** The first concrete error a schema-guard warning reports: a PARSE_FAIL / SCHEMA_FAIL line, an
 * instance-path line, or the first bullet of its issue list; '' when it names none. */
export function firstError(text: string): string {
  const m = /^\s*((?:PARSE_FAIL|SCHEMA_FAIL):.*)$/m.exec(text)
    ?? /^\s*-\s*(\/\S+.*)$/m.exec(text)
    ?? /^\s*-\s*(\S.*)$/m.exec(text);
  return m ? clipTo(m[1].trim(), LINE_CAP) : '';
}

/** The one-line stand-in for a second and later warning from a shaped-warning hook. */
export function shapedWarnLine(hook: string, text: string): string {
  const err = firstError(text);
  return `[achilles] ${hook}: ${warnRole(text)} return failed validation again${err ? ` — ${err}` : ''}. Same return-shape rules as the first warning this session; the full text is in the UI/log.`;
}

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
  let noSkipSeen = false;
  const denies = new Map<string, string>();
  const warnings = new Set<string>();
  const shapedSeen = new Set<string>();
  const self: MessageCompactor = {
    reset() { scopeSeen = false; noSkipSeen = false; denies.clear(); warnings.clear(); shapedSeen.clear(); },
    scope(text) {
      if (verboseMessages()) return text;
      let out = text;
      if (SCOPE_BLOCK.test(out)) {
        if (scopeSeen) out = out.replace(SCOPE_BLOCK, SCOPE_POINTER);
        else scopeSeen = true;
      }
      if (NO_SKIP_BLOCK.test(out)) {
        if (noSkipSeen) out = out.replace(NO_SKIP_BLOCK, NO_SKIP_POINTER);
        else noSkipSeen = true;
      }
      return out;
    },
    deny(hook, reason) {
      if (verboseMessages()) return reason;
      // Keyed by (hook, first line); collapsed only when the body (the fixed blocks aside) is identical
      // to the last one under that key, so a repeat with new details (another schema error) still shows.
      const key = `${hook}\0${firstLine(reason)}`;
      const body = reason.replace(SCOPE_BLOCK, '').replace(NO_SKIP_BLOCK, '').trim();
      if (denies.get(key) === body) return repeatBlockLine(hook, reason);
      denies.set(key, body);
      return self.scope(reason);
    },
    note(hook, text, kind) {
      if (verboseMessages()) return text;
      const key = warnKey(hook, text);
      if (warnings.has(key)) return `[achilles] ${hook}: repeated warning (see earlier).`;
      warnings.add(key);
      // A shaped-warning hook (the schema guard) says the same thing every time around a different
      // issue list: the first one carries the rules, later ones carry the role and the first error.
      if (SHAPED_WARN_HOOK.test(hook)) {
        if (shapedSeen.has(hook)) return shapedWarnLine(hook, text);
        shapedSeen.add(hook);
      }
      if (kind === 'additionalContext') return capAtLine(self.scope(text), CONTEXT_CAP);
      // First sight: the whole warning (it steers the model, e.g. a schema guard's issue list), capped.
      return capAtLine(self.scope(text));
    },
  };
  return self;
}
