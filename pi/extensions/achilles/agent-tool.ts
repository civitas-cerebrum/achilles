// pi/extensions/achilles/agent-tool.ts
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Type } from 'typebox';
import type { ExtensionAPI, ExtensionContext } from '@earendil-works/pi-coding-agent';
import { resolveSkill } from './skills.ts';
import { log } from './log.ts';
import { piDepth } from './env.ts';
import { shadowPath } from './transcript.ts';

const LEGACY_CAP = 16 * 1024;
const DEFAULT_RESULT_CAP = 8192;
const KILL_GRACE_MS = 5000;
/** Like Claude Code: subagents can load skills but cannot dispatch further subagents (the depth
 * cap stays as a backstop). The allowlist applies to extension tools too. */
const CHILD_TOOLS = 'read,bash,edit,write,grep,find,ls,Skill';

/** This extension's entry point, passed to every child with `-e` so the gates run inside it even
 * when the parent loaded the extension with `-e` rather than from settings. pi de-duplicates an
 * extension that is both in settings and passed with `-e` (verified: one session_start per process). */
const EXTENSION_ENTRY = path.join(path.dirname(fileURLToPath(import.meta.url)), 'index.ts');

export interface AgentToolOptions {
  roots: string[];
  stateDir?: string;
  maxDepth?: number;
  maxConcurrent?: number;
  invocation?: (args: string[]) => { command: string; args: string[] };
}

/** Same resolution the pi subagent example uses: re-run the current pi script under the current runtime. */
function defaultInvocation(args: string[]): { command: string; args: string[] } {
  const script = process.argv[1];
  if (script && fs.existsSync(script)) return { command: process.execPath, args: [script, ...args] };
  return { command: 'pi', args };
}

function parentActive(stateDir: string, sessionId: string): boolean {
  if (/^(1|true|on|active)$/i.test(process.env.ACHILLES_PROTOCOL ?? '')) return true;
  return fs.existsSync(path.join(stateDir, `${sessionId}.active`));
}

/** The child's agent_type for the hook payloads: `subagent_type` when given, otherwise the role
 * prefix of `description` (text before the first `:`), or the whole description when it has none. */
export function agentType(params: { description: string; subagent_type?: string }): string {
  const explicit = params.subagent_type?.trim();
  if (explicit) return explicit;
  const i = params.description.indexOf(':');
  return (i >= 0 ? params.description.slice(0, i) : params.description).trim();
}

/** The legacy model-facing cap, kept for ACHILLES_PI_VERBOSE=1 (the pre-compaction behaviour). */
function legacyCap(text: string): string {
  if (Buffer.byteLength(text, 'utf8') <= LEGACY_CAP) return text;
  return `${truncateBytes(text, LEGACY_CAP)}\n\n[achilles: output truncated for context; full text kept in tool details]`;
}

function truncateBytes(text: string, max: number): string {
  if (Buffer.byteLength(text, 'utf8') <= max) return text;
  // Slice by bytes and drop a trailing partial UTF-8 sequence (decoded as U+FFFD).
  return Buffer.from(text, 'utf8').subarray(0, max).toString('utf8').replace(/\uFFFD+$/, '');
}

/** ACHILLES_PI_AGENT_RESULT_CAP (bytes), default 8192; unparseable or non-positive values use the default. */
export function resultCap(): number {
  const n = Number(process.env.ACHILLES_PI_AGENT_RESULT_CAP);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : DEFAULT_RESULT_CAP;
}

export const verbose = (): boolean => process.env.ACHILLES_PI_VERBOSE === '1';

/** End index (exclusive) of the balanced JSON object starting at `start`, string-aware, or -1. */
function objectEnd(text: string, start: number): number {
  let depth = 0, inStr = false, esc = false;
  for (let i = start; i < text.length; i++) {
    const c = text[i];
    if (inStr) { if (esc) esc = false; else if (c === '\\') esc = true; else if (c === '"') inStr = false; continue; }
    if (c === '"') inStr = true;
    else if (c === '{') depth++;
    else if (c === '}') { depth--; if (depth === 0) return i + 1; }
  }
  return -1;
}

/** The last JSON object in `text` with a top-level `handover` key (bare, fenced in ```json, or after
 * prose), with its source span; undefined when there is none. */
export function extractHandover(text: string): { obj: Record<string, unknown>; start: number; end: number } | undefined {
  let found: { obj: Record<string, unknown>; start: number; end: number } | undefined;
  let i = text.indexOf('{');
  for (let tries = 0; i >= 0 && tries < 500; tries++) {
    const end = objectEnd(text, i);
    let obj: unknown;
    // An unbalanced "{" in prose never closes from here, but a later one still may: try the next.
    if (end > 0) { try { obj = JSON.parse(text.slice(i, end)); } catch { obj = undefined; } }
    if (obj && typeof obj === 'object' && !Array.isArray(obj)) {
      if (Object.prototype.hasOwnProperty.call(obj, 'handover')) found = { obj: obj as Record<string, unknown>, start: i, end };
      i = text.indexOf('{', end); // a parsed object's nested objects are not top-level candidates
    } else {
      i = text.indexOf('{', i + 1);
    }
  }
  return found;
}

export interface LeanResult { text: string; dropped: boolean; handover: boolean; truncated: boolean }

/** The model-facing form of a subagent's final text: the handover JSON alone (compact) when there is
 * one, capped at `cap` bytes. `dropped` says whether anything beyond whitespace was left out. */
export function leanResult(full: string, cap = resultCap()): LeanResult {
  const h = extractHandover(full);
  let text = full;
  let dropped = false;
  if (h) {
    text = JSON.stringify(h.obj);
    // Only whitespace around the object (and the object's own formatting) is not a loss.
    dropped = (full.slice(0, h.start) + full.slice(h.end)).trim() !== '';
  }
  const truncated = Buffer.byteLength(text, 'utf8') > cap;
  if (truncated) text = truncateBytes(text, cap);
  return { text, dropped: dropped || truncated, handover: !!h, truncated };
}

export const KEEP_RETURNS = 20;

/** Keep the newest KEEP_RETURNS `.md` files in `dir` by mtime (never `justWritten`); delete the rest.
 * Only regular `.md` files directly in `dir` are touched. Best-effort: a failure is logged, not thrown. */
export function pruneReturns(dir: string, justWritten?: string, keep = KEEP_RETURNS): void {
  try {
    const files = fs.readdirSync(dir, { withFileTypes: true })
      .filter((d) => d.isFile() && d.name.endsWith('.md'))
      .map((d) => { const p = path.join(dir, d.name); return { p, m: fs.statSync(p).mtimeMs }; })
      .sort((x, y) => y.m - x.m || (y.p === justWritten ? 1 : x.p === justWritten ? -1 : 0));
    for (const f of files.slice(keep)) if (f.p !== justWritten) fs.rmSync(f.p, { force: true });
  } catch (err) {
    log('agent_return_prune_failed', { dir, error: String(err) });
  }
}

/** Writes the full subagent return to <cwd>/.achilles/pi-agent-returns/<id>.md (dir 0700, file 0600)
 * and returns its path relative to cwd, or undefined when it could not be written. */
export function saveFullReturn(cwd: string, id: string, text: string): string | undefined {
  try {
    const dir = path.join(cwd, '.achilles', 'pi-agent-returns');
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    const safe = id.replace(/[^A-Za-z0-9._-]/g, '_') || `child-${Date.now()}`;
    const file = path.join(dir, `${safe}.md`);
    fs.writeFileSync(file, text, { mode: 0o600 });
    fs.chmodSync(file, 0o600);
    pruneReturns(dir, file);
    return path.relative(cwd, file) || file;
  } catch (err) {
    log('agent_return_save_failed', { cwd, id, error: String(err) });
    return undefined;
  }
}

/** Model-facing content for a subagent return (see leanResult); verbose mode keeps the old behaviour. */
export function modelFacing(full: string, cwd: string, childSessionId: string): string {
  if (verbose()) return legacyCap(full);
  const lean = leanResult(full);
  if (!lean.dropped) return lean.text;
  const rel = saveFullReturn(cwd, childSessionId || `child-${process.pid}-${Date.now()}`, full);
  return rel ? `${lean.text}\n[achilles] full subagent return: ${rel}` : `${lean.text}\n[achilles] subagent return shortened for context; the full text is in the tool details.`;
}

export function registerAgentTool(pi: ExtensionAPI, opts: AgentToolOptions): void {
  const stateDir = opts.stateDir ?? process.env.ACHILLES_SESSION_STATE_DIR ?? path.join(os.homedir(), '.claude', 'achilles', 'sessions');
  const maxDepth = opts.maxDepth ?? 2;
  const maxConcurrent = opts.maxConcurrent ?? 4;
  const invocation = opts.invocation ?? defaultInvocation;
  let running = 0;
  const waiters: Array<() => void> = [];
  const acquire = () => new Promise<void>((res) => { if (running < maxConcurrent) { running++; res(); } else waiters.push(() => { running++; res(); }); });
  const release = () => { running--; waiters.shift()?.(); };

  pi.registerTool({
    name: 'Agent',
    label: 'Agent',
    description: 'Dispatch a subagent with an isolated context. `description` is a short label that starts with the role prefix (e.g. "workflow-reviewer-phase1: ..."); `prompt` is the full brief; `skill` names an achilles skill the subagent should load.',
    promptSnippet: 'Agent: dispatch a subagent ({ description, prompt, skill? })',
    parameters: Type.Object({
      description: Type.String({ description: 'Short label; starts with the role prefix' }),
      prompt: Type.String({ description: 'The complete brief for the subagent' }),
      subagent_type: Type.Optional(Type.String({ description: 'Subagent role; defaults to the description role prefix' })),
      skill: Type.Optional(Type.String({ description: 'achilles skill to advertise in the subagent' })),
    }),
    async execute(_id, params, signal, onUpdate, ctx: ExtensionContext) {
      const depth = piDepth();
      if (depth >= maxDepth) throw new Error(`Agent nesting cap (${maxDepth}) reached; do this work inline instead of dispatching another subagent.`);
      let skillDir: string | undefined;
      if (params.skill) {
        const s = resolveSkill(params.skill, opts.roots);
        if (!s) throw new Error(`Unknown skill "${params.skill}" for Agent.skill`);
        skillDir = s.dir;
      }
      const type = agentType(params);
      const active = parentActive(stateDir, ctx.sessionManager.getSessionId());
      const env: NodeJS.ProcessEnv = {
        ...process.env,
        ACHILLES_PI_DEPTH: String(depth + 1),
        ...(type ? { ACHILLES_PI_AGENT_TYPE: type } : {}),
        ...(active ? { ACHILLES_PROTOCOL: '1' } : {}),
        // The child's shadow transcript is seeded with this one's context signals (transcript.ts
        // seedShadow), including this Agent tool_use, which the parent's bridge recorded at tool_call,
        // before execute runs.
        ACHILLES_PI_PARENT_SHADOW: shadowPath(ctx.sessionManager.getSessionId(), stateDir),
      };

      await acquire();
      let tmp: string | undefined;
      try {
        tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'achilles-agent-'));
        const sessionDir = path.join(tmp, 'session');
        // --no-skills: the child's system prompt lists only the skill it was given (--skill below), not every
        // discovered skill; the Skill tool still resolves any achilles skill from its own roots.
        const args = ['--mode', 'json', '-p', '--session-dir', sessionDir, '--no-skills', '--tools', CHILD_TOOLS, '-e', EXTENSION_ENTRY];
        if (ctx.isProjectTrusted()) args.push('-a');
        const model = process.env.ACHILLES_PI_SUBAGENT_MODEL ?? (ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : undefined);
        if (model) args.push('--model', model);
        if (ctx.thinkingLevel) args.push('--thinking', ctx.thinkingLevel);
        if (skillDir) args.push('--skill', skillDir);
        // The prompt always goes by @file: as a raw argv word, a brief starting with "--x", "@/etc/passwd"
        // or "- item" would be parsed by pi as a flag or a file include. The file is private (0600).
        const pf = path.join(tmp, 'prompt.md'); fs.writeFileSync(pf, params.prompt, { mode: 0o600 }); args.push(`@${pf}`);
        log('agent_spawn', { description: params.description, agentType: type, skill: params.skill, active, depth: depth + 1 });

        let lastText = '', stderr = '', childSessionId = '';
        const exitCode = await new Promise<number | null>((resolve) => {
          const inv = invocation(args);
          // stdin must be closed: `pi -p` reads piped stdin as extra prompt text and would wait on it.
          const child = spawn(inv.command, inv.args, { cwd: ctx.cwd, env, stdio: ['ignore', 'pipe', 'pipe'] });
          let buf = '';
          let killTimer: NodeJS.Timeout | undefined;
          const line = (l: string) => {
            if (!l.trim()) return;
            let ev: Record<string, unknown>; try { ev = JSON.parse(l); } catch { return; }
            if (ev.type === 'session' && typeof ev.id === 'string') childSessionId = ev.id;
            if (ev.type === 'message_end') {
              const m = ev.message as { role?: string; content?: Array<{ type: string; text?: string }> };
              if (m?.role === 'assistant') { const t = (m.content ?? []).filter((c) => c.type === 'text').map((c) => c.text ?? '').join('\n'); if (t.trim()) lastText = t; }
            }
            if (ev.type === 'tool_execution_end' && onUpdate) onUpdate({ content: [{ type: 'text', text: `… ${String(ev.toolName)} done` }], details: undefined });
          };
          const kill = () => {
            child.kill('SIGTERM');
            // child.killed only means a signal was sent; check for an actual exit before escalating.
            killTimer = setTimeout(() => { if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL'); }, KILL_GRACE_MS);
            killTimer.unref();
          };
          child.stdout.setEncoding('utf8');
          child.stderr.setEncoding('utf8');
          child.stdout.on('data', (d) => { buf += d; const parts = buf.split('\n'); buf = parts.pop() ?? ''; parts.forEach(line); });
          child.stderr.on('data', (d) => { stderr += d; });
          child.on('error', (e) => { stderr += String(e); resolve(127); });
          child.on('close', (code) => {
            if (killTimer) clearTimeout(killTimer);
            signal?.removeEventListener('abort', kill);
            if (buf) line(buf);
            resolve(code);
          });
          if (signal) { if (signal.aborted) kill(); else signal.addEventListener('abort', kill, { once: true }); }
        });
        const transcript = fs.existsSync(sessionDir) ? fs.readdirSync(sessionDir).filter((f) => f.endsWith('.jsonl')).map((f) => path.join(sessionDir, f))[0] : undefined;
        // SubagentStop hooks run inside the child at its own settle (bridge.ts), with blocks honoured;
        // nothing runs them again here. The child's bridge wrote its own Claude-shaped shadow under its
        // own session id: that, not pi's session file, is the transcript a hook understands.
        const childShadow = childSessionId ? shadowPath(childSessionId, stateDir) : undefined;
        log('agent_done', { description: params.description, exitCode, childSessionId, chars: lastText.length });
        if (exitCode !== 0 || !lastText) throw new Error(`Subagent "${params.description}" failed (exit ${exitCode}): ${stderr.trim().slice(-2000) || 'no output'}`);
        // Opt-in copy of the transcript for details/debugging (the temp dir is removed in finally).
        let transcriptCopy: string | undefined;
        if (transcript && process.env.ACHILLES_PI_KEEP_TRANSCRIPTS === '1') {
          // A private dir of its own (not a guessable name in the shared /tmp) and a 0600 file.
          const keepDir = fs.mkdtempSync(path.join(os.tmpdir(), 'achilles-transcript-'));
          transcriptCopy = path.join(keepDir, `${childSessionId || 'child'}.jsonl`);
          fs.copyFileSync(transcript, transcriptCopy);
          fs.chmodSync(transcriptCopy, 0o600);
        }
        return { content: [{ type: 'text', text: modelFacing(lastText, ctx.cwd, childSessionId) }], details: { description: params.description, exitCode, childSessionId, text: lastText, shadowTranscript: childShadow, transcriptCopy } };
      } finally {
        // release() must run even when mkdtemp or the cleanup itself throws, or the slot leaks.
        try { if (tmp) fs.rmSync(tmp, { recursive: true, force: true }); } catch (err) { log('agent_cleanup_failed', { tmp, error: String(err) }); }
        release();
      }
    },
  });
}
