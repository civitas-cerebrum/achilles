import os from 'node:os';
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { createBridge } from './bridge.ts';
import { registerSkillTool } from './skill-tool.ts';
import { registerAgentTool } from './agent-tool.ts';
import { skillRoots } from './skills.ts';
import { log } from './log.ts';

export default function achilles(pi: ExtensionAPI): void {
  pi.on('session_start', async (event, ctx) => {
    log('session_start', { reason: event.reason, cwd: ctx.cwd, sessionId: ctx.sessionManager.getSessionId(), depth: process.env.ACHILLES_PI_DEPTH ?? '0' });
  });
  const roots = skillRoots(os.homedir());
  const bridge = createBridge(pi);
  registerSkillTool(pi, { roots });
  registerAgentTool(pi, { bridge, roots });
}
