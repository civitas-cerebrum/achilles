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

/**
 * Starts a subagent's shadow as a byte copy of its parent's, the way older Claude Code builds kept
 * sidechain entries in the main session file: PreToolUse hooks in the child (the journey-mapping
 * preread gate, the evidence floor's fd- dispatch signal) need the parent's history, and the child's
 * own calls are appended after it. Only when the child shadow does not exist yet, so a re-fired
 * session_start never re-seeds. Cost: each child holds a full copy of the parent shadow at spawn
 * (copyFileSync, no parse), so disk use grows with parent history times dispatch count.
 * Returns false when there was nothing to copy or the copy failed; never throws.
 */
export function seedShadow(file: string, parentFile: string): boolean {
  try {
    if (fs.existsSync(file) || !fs.existsSync(parentFile)) return false;
    fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    fs.copyFileSync(parentFile, file, fs.constants.COPYFILE_EXCL);
    fs.chmodSync(file, 0o600);
    return true;
  } catch {
    return false;
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
