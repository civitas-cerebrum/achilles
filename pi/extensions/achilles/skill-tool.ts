import { Type } from 'typebox';
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { resolveSkill, listSkills } from './skills.ts';
import { log } from './log.ts';

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
      if (!s) throw new Error(`Unknown skill "${params.skill}". Known skills: ${listSkills(opts.roots).join(', ')}`);
      // Only the orchestrator (depth 0) is refused a subagent-only skill; inside a subagent it is
      // exactly the skill the child was dispatched to load (e.g. workflow-reviewer).
      const refuse = s.subagentOnly && Number(process.env.ACHILLES_PI_DEPTH ?? '0') === 0;
      log('skill', { skill: s.name, refused: refuse });
      if (refuse) {
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
