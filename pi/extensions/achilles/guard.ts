import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { listSkills, resolveSkill } from './skills.ts';
import { resolveToCwd } from './edit-match.ts';

/** A subagent-only skill's directory in one skill root. */
export interface SubagentOnlyDir { name: string; dir: string }

/** Every subagent-only skill directory across ALL roots (a name shadowed in an earlier root still
 * has its later copies listed, so reading any copy is caught). */
export function subagentOnlyDirs(roots: string[]): SubagentOnlyDir[] {
  const out: SubagentOnlyDir[] = [];
  for (const name of listSkills(roots)) {
    for (const root of roots) {
      const s = resolveSkill(name, [root]);
      if (s?.subagentOnly) out.push({ name, dir: canonical(s.dir) });
    }
  }
  return out;
}

function canonical(p: string): string {
  try { return fs.realpathSync(p); } catch { return path.resolve(p); }
}

function expand(p: string, cwd: string, home: string): string {
  // Resolve exactly as pi's read tool does (`@x`, `~/x`, `file://x`, Unicode spaces), so no path
  // spelling pi accepts can slip past the guard.
  let abs: string;
  try { abs = resolveToCwd(p, cwd, home); } catch { abs = path.resolve(cwd, p); }
  // realpath the deepest existing ancestor so a symlinked root (e.g. ~/.agents/skills) still matches.
  let head = abs; const tail: string[] = [];
  while (!fs.existsSync(head) && path.dirname(head) !== head) { tail.unshift(path.basename(head)); head = path.dirname(head); }
  return path.join(canonical(head), ...tail);
}

function inside(file: string, dir: string): boolean {
  const rel = path.relative(dir, file);
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}

/** The subagent-only skill a path falls under, if any. */
export function subagentOnlySkillFor(p: string, dirs: SubagentOnlyDir[], cwd: string, home = os.homedir()): string | undefined {
  const file = expand(p, cwd, home);
  return dirs.find((d) => inside(file, d.dir))?.name;
}

const READER = /(^|[\s;&|(`$])(cat|sed|head|tail|less|more|awk|bat|nl|tac)(\s|$)/;

/** Path-looking words of a shell command, quotes stripped. Coarse by design: it only needs to spot
 * a file argument of a cat/sed/head-style reader. Each word is then resolved like a read path
 * (subagentOnlySkillFor → expand), so a leading `@` or `file://` is stripped too. */
function words(command: string): string[] {
  return command.split(/[\s;&|()<>`]+/).map((w) => w.replace(/^['"]+|['"]+$/g, '')).filter((w) => w.includes('/') || w.endsWith('.md'));
}

export function blockedSkillRead(toolName: string, input: Record<string, unknown>, dirs: SubagentOnlyDir[], cwd: string, home = os.homedir()): string | undefined {
  if (dirs.length === 0) return undefined;
  if (toolName === 'read' && typeof input.path === 'string') return subagentOnlySkillFor(input.path, dirs, cwd, home);
  if (toolName === 'bash' && typeof input.command === 'string' && READER.test(input.command)) {
    for (const w of words(input.command)) { const hit = subagentOnlySkillFor(w, dirs, cwd, home); if (hit) return hit; }
  }
  return undefined;
}

export function delegateInstruction(name: string): string {
  return `[achilles] "${name}" is a subagent-only skill; the orchestrator must not read its files. Delegate it: Agent { skill: "${name}", description: "<role-prefix>: <what>", prompt: "<brief>" }.`;
}

// ── Large reference reads ────────────────────────────────────────────────────────────────────────
// The heavy methodology text is not only in SKILL.md: a skill's references/*.md run to 46-53k chars
// (api-reference, depth-mode-pipeline, anti-rationalizations). An orchestrator that reads one has
// spent a third of a 32k window on text it needed for one dispatch. The read is never blocked — the
// orchestrator sometimes does need a passage — but the result carries a note steering the next one.

/** A skill's `references/` directory. */
export interface ReferenceDir { skill: string; dir: string }

/** Every skill's `references/` directory across all roots (subagent-only skills excluded: reading
 * anything of theirs is already blocked, so their references never reach a result). */
export function referenceDirs(roots: string[]): ReferenceDir[] {
  const out: ReferenceDir[] = [];
  for (const name of listSkills(roots)) {
    for (const root of roots) {
      const s = resolveSkill(name, [root]);
      if (!s || s.subagentOnly) continue;
      const dir = path.join(s.dir, 'references');
      try { if (fs.lstatSync(dir).isDirectory()) out.push({ skill: name, dir: canonical(dir) }); } catch { /* no references/ */ }
    }
  }
  return out;
}

export interface LargeRef { path: string; chars: number; skill: string }

/** The skill reference a read targets when it is bigger than `max` chars; undefined otherwise.
 * Reuses the reader detection of blockedSkillRead, so `cat`/`sed`/`head` on one counts too. */
export function largeReferenceRead(
  toolName: string,
  input: Record<string, unknown>,
  refs: ReferenceDir[],
  cwd: string,
  home = os.homedir(),
  max = 8000,
): LargeRef | undefined {
  if (refs.length === 0) return undefined;
  const candidates = toolName === 'read' && typeof input.path === 'string' ? [input.path]
    : toolName === 'bash' && typeof input.command === 'string' && READER.test(input.command) ? words(input.command)
    : [];
  for (const c of candidates) {
    const file = expand(c, cwd, home);
    const hit = refs.find((r) => inside(file, r.dir));
    if (!hit) continue;
    try {
      const st = fs.statSync(file);
      if (st.isFile() && st.size > max) return { path: file, chars: st.size, skill: hit.skill };
    } catch { /* unreadable: nothing to steer about */ }
  }
  return undefined;
}

/** The steer note appended to a large reference's result (the content still comes back in full). */
export function referenceNote(ref: LargeRef): string {
  return `[achilles] ${ref.path} is ${ref.chars} chars. At depth 0 prefer delegating work that needs it: Agent { skill: "${ref.skill}", description: "<role-prefix>: <what>", prompt: "<brief>" }. To read it here anyway, ask for the part you need.`;
}
