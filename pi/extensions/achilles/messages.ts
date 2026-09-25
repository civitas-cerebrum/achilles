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
  // Unlike skill refs, a schema ref has no lookup step to gate on (no resolveSchema), so it is
  // rewritten unconditionally: hook texts may reference a schema by its full relative path
  // (e.g. "schemas/subagent-returns/workflow-reviewer.schema.json", which exists under
  // packageDir today) or by a bare filename directly under schemas/; either way the caller
  // wants the packageDir-rooted absolute path, whether or not that exact path exists on disk.
  out = out.replace(SCHEMA_REF, (_whole, rel: string) => path.join(opts.packageDir, 'schemas', rel));
  if (seen.size === 0) return out;
  const hints = [...seen].map(([name, sub]) => sub
    ? `Delegate it: Agent { skill: "${name}", description: "<role-prefix>: <what>", prompt: "<brief>" } — this skill is subagent-only and must not be loaded into the orchestrator.`
    : `Load it: Skill { skill: "${name}" }`);
  return `${out}\n\nUnder pi:\n  ${hints.join('\n  ')}`;
}
