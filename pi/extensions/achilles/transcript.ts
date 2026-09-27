import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { claudeToolName } from './payload.ts';

/**
 * Claude-shaped shadow transcript.
 *
 * Several hooks read the session transcript with jq, expecting Claude Code's JSONL shape:
 *   {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":…}}]}}
 * pi's own session file uses a different shape ({"type":"message","message":{"content":[{"type":"toolCall",…}]}}),
 * so the bridge keeps a per-session shadow in Claude's shape and passes it as transcript_path.
 * The file is user-private (dir 0700, file 0600): it holds prompts and tool inputs.
 */

type Rec = Record<string, unknown>;

/** Same resolution as hooks/lib/achilles-activation.sh achilles__state_dir. */
export function sessionStateDir(home: string = os.homedir()): string {
  return process.env.ACHILLES_SESSION_STATE_DIR || path.join(home, '.claude', 'achilles', 'sessions');
}

/** `<stateDir>/pi-transcripts/<sessionId>.jsonl`; the id is reduced to a safe filename. */
export function shadowPath(sessionId: string, stateDir: string = sessionStateDir()): string {
  const safe = sessionId.replace(/[^A-Za-z0-9._-]/g, '_') || 'unknown';
  return path.join(stateDir, 'pi-transcripts', `${safe}.jsonl`);
}

/** Appends one JSON line. Never throws: a shadow write failure must not break a tool call. */
export function appendShadow(file: string, entry: Rec): boolean {
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    fs.appendFileSync(file, JSON.stringify(entry) + '\n', { mode: 0o600 });
    return true;
  } catch {
    return false;
  }
}

/** Parent lines a child inherits: the context signals hooks look for across a dispatch (which skill
 * the session loaded, which role it dispatched, what the user asked). */
function contextSignal(entry: unknown): boolean {
  const e = entry as { type?: unknown; message?: { content?: unknown } } | null;
  if (!e || typeof e !== 'object') return false;
  if (e.type === 'user') return true;
  if (e.type !== 'assistant' || !Array.isArray(e.message?.content)) return false;
  const blocks = e.message.content as Array<{ type?: unknown; name?: unknown; input?: { file_path?: unknown } }>;
  return blocks.length > 0 && blocks.every((c) => c?.type === 'tool_use' && (
    c.name === 'Skill' || c.name === 'Agent' ||
    (c.name === 'Read' && typeof c.input?.file_path === 'string' && /\/skills\/[^/]+\/SKILL\.md$/.test(c.input.file_path))));
}

/**
 * Starts a subagent's shadow with its parent's CONTEXT SIGNALS only: Skill and Agent tool_uses, Reads
 * of a skills/<name>/SKILL.md, and user prompts. PreToolUse hooks in the child need those (the
 * journey-mapping preread gate, the evidence floor's fd- dispatch signal), but not the parent's work:
 * a parent's evidence read must not satisfy the child's evidence floor, and a parent's spec write must
 * not trip the compliance sweep at the child's SubagentStop. Bash, other Reads, Write, Edit and
 * assistant text are dropped, as are malformed lines.
 *
 * Only when the child shadow does not exist yet (exclusive create, 0600), so a re-fired session_start
 * never re-seeds. The parent path is accepted only when it is a regular `.jsonl` file directly inside
 * `<stateDir>/pi-transcripts/` (it arrives through the environment). Cost: the parent shadow is read
 * and parsed once per dispatch; the copy is small, since only signal lines are kept.
 * Returns the number of lines written, or -1 when nothing was seeded; never throws.
 */
export function seedShadow(file: string, parentFile: string, stateDir: string): number {
  try {
    const dir = path.resolve(stateDir, 'pi-transcripts');
    const parent = path.resolve(parentFile);
    if (path.dirname(parent) !== dir || !parent.endsWith('.jsonl')) return -1;
    if (!fs.lstatSync(parent).isFile()) return -1;
    if (fs.existsSync(file)) return -1;
    const keep = fs.readFileSync(parent, 'utf8').split('\n').filter((line) => {
      if (!line.trim()) return false;
      try { return contextSignal(JSON.parse(line)); } catch { return false; }
    });
    fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    fs.writeFileSync(file, keep.map((l) => l + '\n').join(''), { mode: 0o600, flag: 'wx' });
    return keep.length;
  } catch {
    return -1;
  }
}

/** Claude records a tool call as an assistant message holding one tool_use block. `claudeInput` is the
 * caller's claudeToolInput translation, made against the right cwd before the tool runs. */
export function toolUseEntry(piToolName: string, toolCallId: string, claudeInput: Rec): Rec {
  return {
    type: 'assistant',
    message: { role: 'assistant', content: [{ type: 'tool_use', id: toolCallId, name: claudeToolName(piToolName), input: claudeInput }] },
  };
}

export function assistantTextEntry(text: string): Rec {
  return { type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text }] } };
}

/**
 * Claude stores a typed prompt as a user message with STRING content (so hooks that scan
 * `.message.content[]` arrays for assistant text never mistake the user's words for the model's).
 * A pi skill command (`/skill:<name> args`) is recorded the way Claude records a slash command,
 * `<command-name>/<name></command-name>`, which the activation watcher's transcript grep matches.
 */
export function userPromptEntry(text: string): Rec {
  const m = text.match(/^\/skill:([a-z0-9][a-z0-9-]*)(?:\s+([\s\S]*))?$/);
  const content = m
    ? `<command-message>${m[1]}</command-message>\n<command-name>/${m[1]}</command-name>\n<command-args>${(m[2] ?? '').trim()}</command-args>`
    : text;
  return { type: 'user', message: { role: 'user', content } };
}

/** Text blocks of an assistant message (pi AgentMessage), joined; '' when it has none. */
export function assistantText(message: unknown): string {
  const m = message as { role?: string; content?: unknown } | undefined;
  if (!m || m.role !== 'assistant') return '';
  if (typeof m.content === 'string') return m.content;
  if (!Array.isArray(m.content)) return '';
  return (m.content as Array<{ type?: string; text?: unknown }>)
    .filter((c) => c && c.type === 'text' && typeof c.text === 'string')
    .map((c) => c.text as string)
    .join('\n');
}

/** Shadow transcripts kept by pruneShadows. One 8-phase run left 23 files and 2.5 MB behind. */
export const KEEP_SHADOWS = 40;

/** How recently a shadow must have been written for its `.active` marker to count as live, in ms.
 * ACHILLES_PI_SHADOW_LIVE_WINDOW (ms) overrides it; unparseable or non-positive values use the default.
 *
 * A marker alone is not evidence of a live session: hooks/lib/achilles-activation.sh leaves one behind
 * per dispatch, so an 8-phase run strands ~9 of them, and a marker-spared shadow was spared regardless
 * of age. The retained set was therefore `40 + ~9 per historical run` and grew without limit. Pairing
 * the marker with a recent mtime keeps the double protection for a session that is actually running
 * (four hooks grep a live shadow) while letting an abandoned marker's shadow age out. */
export const SHADOW_LIVE_WINDOW_MS = 6 * 60 * 60 * 1000;

export function shadowLiveWindow(): number {
  const n = Number(process.env.ACHILLES_PI_SHADOW_LIVE_WINDOW);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : SHADOW_LIVE_WINDOW_MS;
}

/** True when `p` exists and is a directory itself, not a symlink to one. */
function realDir(p: string): boolean {
  try { return fs.lstatSync(p).isDirectory(); } catch { return false; }
}

/**
 * Prunes `<stateDir>/pi-transcripts`: keeps the newest `keep` `.jsonl` shadows by mtime, plus `keepFile`
 * and any shadow whose session is still live — an `<id>.active` marker in `stateDir` (the same marker
 * hooks/lib/achilles-activation.sh writes) AND an mtime inside `shadowLiveWindow()`. Nothing else in the
 * state dir is touched, and a symlinked pi-transcripts is refused so pruning cannot reach outside it.
 * Every dispatch leaves one shadow behind and they hold prompts and tool inputs, so an unbounded
 * directory is both clutter and exposure; the marker alone left a stale exemption per historical run,
 * so the real bound was not `keep` at all.
 * Returns the number of files removed, or -1 when it could not run; never throws.
 */
export function pruneShadows(stateDir: string, keepFile?: string, keep = KEEP_SHADOWS, now = Date.now()): number {
  const dir = path.join(stateDir, 'pi-transcripts');
  if (!realDir(dir)) return -1;
  try {
    const marked = new Set<string>();
    try {
      for (const name of fs.readdirSync(stateDir)) {
        if (name.endsWith('.active')) marked.add(`${name.slice(0, -'.active'.length)}.jsonl`);
      }
    } catch { /* no markers readable: mtime order alone decides */ }
    const window = shadowLiveWindow();
    const files = fs.readdirSync(dir, { withFileTypes: true })
      .filter((d) => d.isFile() && d.name.endsWith('.jsonl'))
      .map((d) => { const p = path.join(dir, d.name); return { p, name: d.name, m: fs.statSync(p).mtimeMs }; })
      .sort((x, y) => y.m - x.m);
    let removed = 0;
    for (const f of files.slice(keep)) {
      // A marker only exempts a shadow that has been written to recently: an abandoned marker from an
      // earlier run must not pin its shadow forever.
      if (f.p === keepFile || (marked.has(f.name) && now - f.m <= window)) continue;
      fs.rmSync(f.p, { force: true });
      removed++;
    }
    return removed;
  } catch {
    return -1;
  }
}
