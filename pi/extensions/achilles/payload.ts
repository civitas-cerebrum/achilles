export type Content = Array<{ type: string; text?: string }>;
type Rec = Record<string, unknown>;

const CLAUDE_NAMES: Record<string, string> = { bash: 'Bash', read: 'Read', write: 'Write', edit: 'Edit', grep: 'Grep', find: 'Glob' };

export function claudeToolName(piName: string): string {
  return CLAUDE_NAMES[piName] ?? piName;
}

function defined(obj: Rec): Rec {
  return Object.fromEntries(Object.entries(obj).filter(([, v]) => v !== undefined));
}

export function claudeToolInput(piName: string, input: Rec): Rec {
  switch (piName) {
    case 'read':
      return defined({ file_path: input.path, offset: input.offset, limit: input.limit });
    case 'write':
      return { file_path: input.path, content: input.content };
    case 'edit': {
      const edits = Array.isArray(input.edits) ? (input.edits as Array<{ oldText?: unknown; newText?: unknown }>) : [];
      const mapped = edits.map((e) => ({ old_string: String(e.oldText ?? ''), new_string: String(e.newText ?? '') }));
      if (mapped.length === 1) return { file_path: input.path, old_string: mapped[0].old_string, new_string: mapped[0].new_string };
      return {
        file_path: input.path,
        old_string: mapped.map((e) => e.old_string).join('\n'),
        new_string: mapped.map((e) => e.new_string).join('\n'),
        edits: mapped,
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
