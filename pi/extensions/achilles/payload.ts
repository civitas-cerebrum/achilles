import fs from 'node:fs';
import { applyPiEdits, minimalSpan, resolveToCwd } from './edit-match.ts';

export type Content = Array<{ type: string; text?: string }>;
type Rec = Record<string, unknown>;

const CLAUDE_NAMES: Record<string, string> = { bash: 'Bash', read: 'Read', write: 'Write', edit: 'Edit', grep: 'Grep', find: 'Glob' };

export function claudeToolName(piName: string): string {
  return CLAUDE_NAMES[piName] ?? piName;
}

/** pi's resolved absolute path for a tool's `path` argument; the raw value when it is not a string or
 * cannot be resolved (a malformed file:// URL, which pi rejects anyway). */
function hookPath(p: unknown, cwd: string): unknown {
  if (typeof p !== 'string') return p;
  try { return resolveToCwd(p, cwd); } catch { return p; }
}

function defined(obj: Rec): Rec {
  return Object.fromEntries(Object.entries(obj).filter(([, v]) => v !== undefined));
}

export function claudeToolInput(piName: string, input: Rec, cwd: string = process.cwd()): Rec {
  // pi resolves `@x`, `~/x` and `file://x` before touching the file; hooks match the literal string,
  // so they must see the resolved absolute path (Claude always sends absolute paths).
  const filePath = hookPath(input.path, cwd);
  switch (piName) {
    case 'read':
      return defined({ file_path: filePath, offset: input.offset, limit: input.limit });
    case 'write':
      return { file_path: filePath, content: input.content };
    case 'edit': {
      const edits = Array.isArray(input.edits) ? (input.edits as Array<{ oldText?: unknown; newText?: unknown }>) : [];
      const mapped = edits.map((e) => ({ old_string: String(e.oldText ?? ''), new_string: String(e.newText ?? '') }));
      // Hooks understand one old_string/new_string pair matched against the file's raw bytes. Compute
      // what pi will actually write (fuzzy matching, CRLF, BOM, several disjoint edits) and present
      // the smallest whole-line span of the file that changes, so content gates judge the real edit.
      const exact = wholeFileEdit(String(input.path ?? ''), mapped, cwd);
      if (exact) return { file_path: filePath, ...exact };
      // pi rejects this edit (it fails the call); hand hooks the model's own text.
      if (mapped.length === 1) return { file_path: filePath, old_string: mapped[0].old_string, new_string: mapped[0].new_string };
      return {
        file_path: filePath,
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

export function claudeToolResponse(piName: string, input: Rec, content: Content, isError: boolean, details?: unknown, cwd: string = process.cwd()): Rec {
  // The Agent tool caps its model-facing content; hooks must judge the subagent's full return,
  // which the tool keeps in details.text.
  const full = piName === 'Agent' && details && typeof (details as Rec).text === 'string' ? (details as Rec).text as string : undefined;
  const text = full ?? contentText(content);
  if (piName === 'bash') return { stdout: text, stderr: '', interrupted: false };
  if (piName === 'write') return { filePath: hookPath(input.path, cwd), success: !isError };
  return { content: text, output: text, isError };
}

/**
 * The Claude-shaped old_string/new_string for a pi edit, or undefined when pi would reject the edit
 * (unreadable file, empty oldText, text not found, duplicate, overlap, no change).
 * A single edit that already matches the raw file exactly once, and whose replacement is exactly
 * what pi writes, is passed through unchanged; everything else becomes the minimal covering span.
 */
export function wholeFileEdit(filePath: string, edits: Array<{ old_string: string; new_string: string }>, cwd: string): { old_string: string; new_string: string } | undefined {
  let original: string;
  try { original = fs.readFileSync(resolveToCwd(filePath, cwd), 'utf8'); } catch { return undefined; }
  let result: string;
  try { result = applyPiEdits(original, edits.map((e) => ({ oldText: e.old_string, newText: e.new_string })), filePath); } catch { return undefined; }
  if (result === original) return undefined;
  if (edits.length === 1) {
    const [{ old_string, new_string }] = edits;
    const at = original.indexOf(old_string);
    if (at >= 0 && original.indexOf(old_string, at + 1) < 0 && original.slice(0, at) + new_string + original.slice(at + old_string.length) === result) return { old_string, new_string };
  }
  return minimalSpan(original, result);
}
