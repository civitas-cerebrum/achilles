import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { SKILLS_DIR, ORCHESTRATOR_SKILL, skillDirs, frontmatterName } from './util.mjs';

// Check 1 — the skill set is what the orchestrator routes to.
// Every skills/<name>/ has a SKILL.md whose frontmatter `name` is the directory
// name, and is reachable from the orchestrator skill or one of its workflows
// (a `../<name>/SKILL.md` link or a backticked `<name>`); every
// `../<name>/SKILL.md` link in those files resolves to a directory.
export function run(report) {
  const detail = [];
  const dirs = skillDirs();
  const workflowsDir = join(SKILLS_DIR, 'achilles-orchestrator', 'workflows');
  const workflows = existsSync(workflowsDir)
    ? readdirSync(workflowsDir).filter((f) => f.endsWith('.md')).map((f) => join(workflowsDir, f))
    : [];
  const text = [ORCHESTRATOR_SKILL, ...workflows].map((f) => readFileSync(f, 'utf8')).join('\n');

  for (const dir of dirs) {
    const skill = join(SKILLS_DIR, dir, 'SKILL.md');
    if (!existsSync(skill)) { detail.push(`skills/${dir}/ has no SKILL.md`); continue; }
    const name = frontmatterName(skill);
    if (name !== dir) detail.push(`skills/${dir}/SKILL.md frontmatter name is "${name}", expected "${dir}"`);
    if (dir === 'achilles-orchestrator') continue;
    if (!text.includes(`../${dir}/SKILL.md`) && !text.includes('`' + dir + '`')) {
      detail.push(`skills/${dir}/ is routed from nowhere in the orchestrator skill or its workflows`);
    }
  }
  for (const m of text.matchAll(/\.\.\/([a-z0-9-]+)\/SKILL\.md/g)) {
    if (!dirs.includes(m[1])) detail.push(`orchestrator cites skills/${m[1]}/SKILL.md, which does not exist`);
  }

  report(`skill set ↔ orchestrator routing (${dirs.length} skills, ${workflows.length} workflows)`, detail.length === 0, detail);
}
