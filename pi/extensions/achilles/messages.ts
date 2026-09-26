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
