import os from 'node:os';
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { createBridge } from './bridge.ts';
import { log } from './log.ts';
import { registerSkillTool } from './skill-tool.ts';
import { skillRoots } from './skills.ts';

export default function achilles(pi: ExtensionAPI): void {
  pi.on('session_start', async (event, ctx) => {
    log('session_start', { reason: event.reason, cwd: ctx.cwd, sessionId: ctx.sessionManager.getSessionId(), depth: process.env.ACHILLES_PI_DEPTH ?? '0' });
  });
  createBridge(pi);
  registerSkillTool(pi, { roots: skillRoots(os.homedir()) });
}
