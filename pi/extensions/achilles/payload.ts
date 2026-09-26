import fs from 'node:fs';
import path from 'node:path';

export type Content = Array<{ type: string; text?: string }>;
type Rec = Record<string, unknown>;

const CLAUDE_NAMES: Record<string, string> = { bash: 'Bash', read: 'Read', write: 'Write', edit: 'Edit', grep: 'Grep', find: 'Glob' };

export function claudeToolName(piName: string): string {
  return CLAUDE_NAMES[piName] ?? piName;
}

function defined(obj: Rec): Rec {
  return Object.fromEntries(Object.entries(obj).filter(([, v]) => v !== undefined));
}

export function claudeToolInput(piName: string, input: Rec, cwd: string = process.cwd()): Rec {
  switch (piName) {
    case 'read':
      return defined({ file_path: input.path, offset: input.offset, limit: input.limit });
    case 'write':
      return { file_path: input.path, content: input.content };
    case 'edit': {
      const edits = Array.isArray(input.edits) ? (input.edits as Array<{ oldText?: unknown; newText?: unknown }>) : [];
      const mapped = edits.map((e) => ({ old_string: String(e.oldText ?? ''), new_string: String(e.newText ?? '') }));
      if (mapped.length === 1) return { file_path: input.path, old_string: mapped[0].old_string, new_string: mapped[0].new_string };
      // Hooks understand one old_string/new_string pair. Present several disjoint replacements as the one
      // equivalent whole-file Edit, so content-validating gates judge the real end state.
      const whole = wholeFileEdit(String(input.path ?? ''), mapped, cwd);
      if (whole) return { file_path: input.path, ...whole };
      return {
        file_path: input.path,
        old_string: mapped.map((e) => e.old_string).join('\n'),
        new_string: mapped.map((e) => e.new_string).join('\n'),
      };
    }
    default:
      return input;
  }
}

export function contentText(content: Content): string {
  return content.filter((c) => c.type === 'text' && typeof c.text === 'string').map((c) => c.text as string).join('\n');
}

export function claudeToolResponse(piName: string, input: Rec, content: Content, isError: boolean, details?: unknown): Rec {
  // The Agent tool caps its model-facing content; hooks must judge the subagent's full return,
  // which the tool keeps in details.text.
  const full = piName === 'Agent' && details && typeof (details as Rec).text === 'string' ? (details as Rec).text as string : undefined;
  const text = full ?? contentText(content);
  if (piName === 'bash') return { stdout: text, stderr: '', interrupted: false };
  if (piName === 'write') return { filePath: input.path, success: !isError };
  return { content: text, output: text, isError };
}

/** Apply pi's disjoint replacements (each must occur exactly once in the original) by position.
 *  Returns undefined when the file cannot be read or any replacement cannot apply; pi rejects that edit too. */
function wholeFileEdit(filePath: string, edits: Array<{ old_string: string; new_string: string }>, cwd: string): { old_string: string; new_string: string } | undefined {
  let original: string;
  try { original = fs.readFileSync(path.resolve(cwd, filePath), 'utf8'); } catch { return undefined; }
  const spans: Array<{ at: number; e: { old_string: string; new_string: string } }> = [];
  for (const e of edits) {
    if (!e.old_string) return undefined;
    const at = original.indexOf(e.old_string);
    if (at < 0 || original.indexOf(e.old_string, at + 1) >= 0) return undefined;
    spans.push({ at, e });
  }
  spans.sort((a, b) => a.at - b.at);
  for (let i = 1; i < spans.length; i++) if (spans[i].at < spans[i - 1].at + spans[i - 1].e.old_string.length) return undefined;
  let out = original;
  for (const { at, e } of [...spans].reverse()) out = out.slice(0, at) + e.new_string + out.slice(at + e.old_string.length);
  return { old_string: original, new_string: out };
}
