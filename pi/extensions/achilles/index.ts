import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { log } from './log.ts';

export default function achilles(pi: ExtensionAPI): void {
  pi.on('session_start', async (event, ctx) => {
    log('session_start', { reason: event.reason, cwd: ctx.cwd, sessionId: ctx.sessionManager.getSessionId() });
  });
}
