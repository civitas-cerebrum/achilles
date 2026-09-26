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
