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

/** `git -C <root> <args>` with `input` on its stdin (the batch readers); returns stdout as a Buffer. */
export function gitInput(root, args, input, { timeoutMs = GIT_TIMEOUT_MS } = {}) {
  return execFileSync('git', ['--no-pager', '-C', root, ...args], {
    input, stdio: ['pipe', 'pipe', 'pipe'], maxBuffer: 256 * 1024 * 1024, timeout: timeoutMs, killSignal: 'SIGKILL',
    env: { ...process.env, ...ENV },
  });
}

/**
 * The text of several objects in one `git cat-file --batch` call. Specs name objects as `HEAD:<path>` or
 * `:<path>` (the index), with paths from the top level. Returns spec → text, or null when no blob is there.
 */
export function catBlobs(root, specs) {
  const out = new Map();
  if (!specs.length) return out;
  const buf = gitInput(root, ['cat-file', '--batch'], `${specs.join('\n')}\n`);
  let at = 0;
  for (const spec of specs) {
    const nl = buf.indexOf(10, at);
    const head = buf.subarray(at, nl).toString('utf8');
    at = nl + 1;
    const m = /^[0-9a-f]+ (\w+) (\d+)$/.exec(head);
    if (!m) { out.set(spec, null); continue; }
    const size = Number(m[2]);
    out.set(spec, m[1] === 'blob' ? buf.subarray(at, at + size).toString('utf8') : null);
    at += size + 1;
  }
  return out;
}
