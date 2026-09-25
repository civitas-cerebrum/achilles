import fs from 'node:fs';
import path from 'node:path';
import { Type } from 'typebox';
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { resolveSkill } from './skills.ts';
import { log } from './log.ts';

function knownSkills(roots: string[]): string[] {
  const names = new Set<string>();
  for (const root of roots) {
    if (!fs.existsSync(root)) continue;
    for (const d of fs.readdirSync(root, { withFileTypes: true })) if (d.isDirectory() && fs.existsSync(path.join(root, d.name, 'SKILL.md'))) names.add(d.name);
  }
  return [...names].sort();
}

export function registerSkillTool(pi: ExtensionAPI, opts: { roots: string[] }): void {
  pi.registerTool({
    name: 'Skill',
    label: 'Skill',
    description: 'Load an achilles methodology skill by name and return its instructions. Subagent-only skills are refused here: delegate them with the Agent tool instead.',
    promptSnippet: 'Skill: load an achilles skill by name ({ skill: "<name>" })',
    parameters: Type.Object({
      skill: Type.String({ description: 'Skill name, e.g. "onboarding"' }),
      args: Type.Optional(Type.String({ description: 'Optional arguments appended as the user request' })),
    }),
    async execute(_id, params) {
      const s = resolveSkill(params.skill, opts.roots);
      if (!s) throw new Error(`Unknown skill "${params.skill}". Known skills: ${knownSkills(opts.roots).join(', ')}`);
      log('skill', { skill: s.name, refused: s.subagentOnly });
      if (s.subagentOnly) {
        return {
          content: [{ type: 'text', text: `Skill "${s.name}" is subagent-only and must not be loaded into the orchestrator. Delegate it: Agent { skill: "${s.name}", description: "<role-prefix>: <what>", prompt: "<brief>" }.` }],
          details: { skill: s.name, refused: true },
        };
      }
      const text = `<skill name="${s.name}" path="${s.file}">\n${s.body.trim()}\n</skill>${params.args ? `\n\nUser request: ${params.args}` : ''}`;
      return { content: [{ type: 'text', text }], details: { skill: s.name, path: s.file } };
    },
  });
}
