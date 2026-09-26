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
