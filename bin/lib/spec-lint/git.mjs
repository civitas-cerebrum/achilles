// The one way the spec lint runs git: no stdin, no pager, no credential or terminal prompt, no optional
// index locks, and a timeout, so a git subprocess can never hold the run.
import { execFileSync } from 'node:child_process';

export const GIT_TIMEOUT_MS = 30000;
const ENV = { GIT_PAGER: 'cat', PAGER: 'cat', GIT_TERMINAL_PROMPT: '0', GIT_OPTIONAL_LOCKS: '0', GIT_ASKPASS: '', SSH_ASKPASS: '' };

/** Runs `git -C <root> <args>` and returns stdout. Throws on a non-zero exit or the timeout. */
export function gitSync(root, args, { stderr = 'pipe', timeoutMs = GIT_TIMEOUT_MS } = {}) {
  return execFileSync('git', ['--no-pager', '-C', root, ...args], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', stderr], maxBuffer: 64 * 1024 * 1024, timeout: timeoutMs, killSignal: 'SIGKILL',
    env: { ...process.env, ...ENV },
  });
}
