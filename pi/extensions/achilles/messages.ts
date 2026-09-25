import fs from 'node:fs';
import path from 'node:path';
import { resolveSkill } from './skills.ts';

const SKILL_REF = /\bskills\/([a-z0-9][a-z0-9-]*)\/([A-Za-z0-9_./-]+)/g;
const SCHEMA_REF = /\bschemas\/([A-Za-z0-9_./-]+\.json)\b/g;

/** Rewrite methodology references to absolute paths and append the right pi move per skill. */
export function steer(text: string, opts: { roots: string[]; packageDir: string }): string {
  const seen = new Map<string, boolean>(); // skill name -> subagentOnly
  let out = text.replace(SKILL_REF, (whole, name: string, rel: string) => {
    const skill = resolveSkill(name, opts.roots);
    if (!skill) return whole;
    seen.set(name, skill.subagentOnly);
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
  if (seen.size === 0) return out;
  const hints = [...seen].map(([name, sub]) => sub
    ? `Delegate it: Agent { skill: "${name}", description: "<role-prefix>: <what>", prompt: "<brief>" } — this skill is subagent-only and must not be loaded into the orchestrator.`
    : `Load it: Skill { skill: "${name}" }`);
  return `${out}\n\nUnder pi:\n  ${hints.join('\n  ')}`;
}
