import os from 'node:os';
import { fileURLToPath } from 'node:url';
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { createBridge } from './bridge.ts';
import { registerSkillTool } from './skill-tool.ts';
import { registerAgentTool } from './agent-tool.ts';
import { skillRoots } from './skills.ts';
import { log } from './log.ts';
import { piDepth } from './env.ts';

/** Process-wide claim: the entry path of the achilles copy that registered in this pi runtime. */
const LOADED = Symbol.for('achilles.pi.loaded');
const SELF = fileURLToPath(import.meta.url);

export default function achilles(pi: ExtensionAPI): void {
  // Two installed copies (say a global package and a project package) would each register the
  // gates, the Skill tool and the Agent tool, running every hook twice. The first copy claims the
  // runtime; a different copy then registers nothing. The same copy re-running (pi reloads and
  // session replacements re-run extension factories) is not a duplicate, and the claim is released
  // at session_shutdown so the next runtime starts clean.
  const g = globalThis as unknown as Record<symbol, unknown>;
  const owner = g[LOADED];
  if (typeof owner === 'string' && owner !== SELF) {
    log('duplicate_instance', { self: SELF, owner });
    return;
  }
  g[LOADED] = SELF;
  pi.on('session_shutdown', async () => { if (g[LOADED] === SELF) delete g[LOADED]; });

  pi.on('session_start', async (event, ctx) => {
    log('session_start', { reason: event.reason, cwd: ctx.cwd, sessionId: ctx.sessionManager.getSessionId(), depth: String(piDepth()) });
  });
  const roots = skillRoots(os.homedir());
  createBridge(pi);
  registerSkillTool(pi, { roots });
  registerAgentTool(pi, { roots });
}
