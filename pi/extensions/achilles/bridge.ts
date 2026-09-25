import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import type { ExtensionAPI, ExtensionContext } from '@earendil-works/pi-coding-agent';
import { claudeToolName, claudeToolInput, claudeToolResponse, type Content } from './payload.ts';
import { steer as steerText } from './messages.ts';
import { skillRoots, PACKAGE_DIR } from './skills.ts';
import { log } from './log.ts';

export interface ManifestEntry { file: string; event: string; matcher: string | null; timeout?: number; async?: boolean }
export interface HookRun { file: string; exitCode: number | null; stdout: string; stderr: string; timedOut: boolean; ms: number }
export interface Decision { file: string; block: boolean; reason?: string; systemMessage?: string; additionalContext?: string }
export interface BridgeOptions { manifestPath?: string; hooksDir?: string; home?: string; bash?: string; skillRoots?: string[]; stateDir?: string }
export interface Bridge {
  readonly enabled: boolean;
  disable(reason: string): void;
  runEvent(event: string, payload: Record<string, unknown>, toolName?: string, ctx?: ExtensionContext): Promise<Decision[]>;
  steer(text: string): string;
}

type Rec = Record<string, unknown>;

export function loadManifest(p: string): ManifestEntry[] {
  return JSON.parse(fs.readFileSync(p, 'utf8')) as ManifestEntry[];
}

/** Claude's rule: a `|`-separated list of plain names is exact-match; anything else is a regex. */
export function compileMatcher(m: string | null): (name: string) => boolean {
  if (m === null || m === '' || m === '*') return () => true;
  if (/^[A-Za-z0-9_|]+$/.test(m)) { const set = new Set(m.split('|')); return (n) => set.has(n); }
  const re = new RegExp(m);
  return (n) => re.test(n);
}

export function resolveHooksDir(cwd: string, home: string, trusted: boolean): string {
  const project = path.join(cwd, '.claude', 'hooks');
  if (trusted && fs.existsSync(project)) return project;
  return path.join(home, '.claude', 'hooks');
}

function tryJson(text: string): Rec | undefined {
  const t = text.trim();
  if (!t.startsWith('{') || !t.endsWith('}')) return undefined;
  try { const v = JSON.parse(t); return v && typeof v === 'object' && !Array.isArray(v) ? (v as Rec) : undefined; } catch { return undefined; }
}

export function parseDecision(run: HookRun, event: string): Decision {
  const pre = event === 'PreToolUse';
  if (run.timedOut) return { file: run.file, block: pre, reason: `[achilles] hook ${run.file} timed out${pre ? '; call blocked (fail closed)' : ''}` };
  if (run.exitCode === 2) return { file: run.file, block: true, reason: run.stderr.trim() || `[achilles] hook ${run.file} exited 2` };
  if (run.exitCode !== 0) return { file: run.file, block: pre, reason: `[achilles] hook ${run.file} failed (exit ${run.exitCode}): ${run.stderr.trim().slice(0, 500)}` };
  const j = tryJson(run.stdout);
  if (!j) return { file: run.file, block: false };
  const hso = (j.hookSpecificOutput ?? {}) as Rec;
  const d: Decision = { file: run.file, block: false };
  if (typeof j.systemMessage === 'string') d.systemMessage = j.systemMessage;
  if (typeof hso.additionalContext === 'string') d.additionalContext = hso.additionalContext;
  if (hso.permissionDecision === 'deny') { d.block = true; d.reason = String(hso.permissionDecisionReason ?? 'blocked by hook'); }
  else if (j.decision === 'block') { d.block = true; d.reason = String(j.reason ?? 'blocked by hook'); }
  else if (j.continue === false) { d.block = true; d.reason = String(j.stopReason ?? 'stopped by hook'); }
  return d;
}

export function runHook(o: { bash: string; hookPath: string; payload: unknown; timeoutMs: number; cwd: string; env: NodeJS.ProcessEnv }): Promise<HookRun> {
  const file = path.basename(o.hookPath);
  const started = Date.now();
  return new Promise((resolve) => {
    let stdout = '', stderr = '', timedOut = false, done = false;
    const finish = (exitCode: number | null) => { if (done) return; done = true; resolve({ file, exitCode, stdout, stderr, timedOut, ms: Date.now() - started }); };
    let child;
    try { child = spawn(o.bash, [o.hookPath], { cwd: o.cwd, env: o.env, stdio: ['pipe', 'pipe', 'pipe'] }); }
    catch (err) { stderr = String(err); return finish(127); }
    const timer = setTimeout(() => { timedOut = true; child.kill('SIGKILL'); }, o.timeoutMs);
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    child.on('error', (err) => { stderr += String(err); clearTimeout(timer); finish(127); });
    child.on('close', (code) => { clearTimeout(timer); finish(code); });
    child.stdin.on('error', () => {});
    child.stdin.end(JSON.stringify(o.payload));
  });
}

function which(bin: string): boolean {
  return spawnSync(bin, ['--version'], { stdio: 'ignore' }).error === undefined;
}

export function createBridge(pi: ExtensionAPI, opts: BridgeOptions = {}): Bridge {
  const home = opts.home ?? os.homedir();
  const bash = opts.bash ?? 'bash';
  const roots = opts.skillRoots ?? skillRoots(home);
  let manifest: ManifestEntry[] = [];
  let hooksDir = opts.hooksDir ?? path.join(home, '.claude', 'hooks');
  let enabled = true;
  let stopHookActive = false;

  const steer = (t: string) => steerText(t, { roots, packageDir: PACKAGE_DIR });
  const disable = (reason: string, ctx?: ExtensionContext) => {
    enabled = false;
    log('disabled', { reason });
    ctx?.ui.notify(`[achilles] hooks disabled: ${reason}`, 'warning');
  };

  async function runEvent(event: string, payload: Rec, toolName?: string, ctx?: ExtensionContext): Promise<Decision[]> {
    if (!enabled) return [];
    const common = {
      hook_event_name: event,
      session_id: ctx?.sessionManager.getSessionId(),
      ...(ctx?.sessionManager.getSessionFile() ? { transcript_path: ctx.sessionManager.getSessionFile() } : {}),
      cwd: ctx?.cwd ?? process.cwd(),
    };
    const full = { ...common, ...payload };
    const out: Decision[] = [];
    for (const e of manifest) {
      if (e.event !== event) continue;
      if (toolName !== undefined && !compileMatcher(e.matcher)(toolName)) continue;
      if (e.matcher !== null && toolName === undefined) continue;
      const hookPath = path.join(hooksDir, e.file);
      if (!fs.existsSync(hookPath)) continue;
      const args = { bash, hookPath, payload: full, timeoutMs: (e.timeout ?? 10) * 1000, cwd: common.cwd, env: process.env };
      if (e.async) { void runHook(args); continue; }
      const run = await runHook(args);
      const d = parseDecision(run, event);
      log('hook', { event, tool: toolName, hook: e.file, exit: run.exitCode, timedOut: run.timedOut, block: d.block, ms: run.ms, depth: process.env.ACHILLES_PI_DEPTH ?? '0' });
      out.push(d);
    }
    return out;
  }

  pi.on('session_start', async (_event, ctx) => {
    stopHookActive = false;
    const manifestPath = opts.manifestPath ?? path.join(PACKAGE_DIR, 'hooks', 'manifest.json');
    try { manifest = loadManifest(manifestPath); } catch (err) { return disable(`cannot read ${manifestPath}: ${String(err)}`, ctx); }
    if (!opts.hooksDir) hooksDir = resolveHooksDir(ctx.cwd, home, ctx.isProjectTrusted());
    if (!which(bash)) return disable(`bash not found (${bash}); install bash to enable the achilles gates`, ctx);
    const jqBundled = fs.existsSync(path.join(hooksDir, 'bin', 'jq'));
    if (!jqBundled && !which('jq')) return disable(`jq not found at ${path.join(hooksDir, 'bin', 'jq')} or on PATH; reinstall @civitas-cerebrum/achilles or install jq`, ctx);
    if (pi.getAllTools().some((t) => t.name === 'subagent')) return disable('another subagent extension (pi-code or similar) is loaded and already runs the settings.json hooks; achilles hook execution is off to avoid running every gate twice', ctx);
    enabled = true;
    log('bridge_ready', { hooksDir, hooks: manifest.length });
  });

  pi.on('input', async (event, ctx) => {
    stopHookActive = false;
    const ds = await runEvent('UserPromptSubmit', { prompt: event.text }, undefined, ctx);
    for (const d of ds) if (d.systemMessage) ctx.ui.notify(d.systemMessage, 'warning');
    return undefined;
  });

  pi.on('tool_call', async (event, ctx) => {
    const name = claudeToolName(event.toolName);
    const ds = await runEvent('PreToolUse', { tool_name: name, tool_input: claudeToolInput(event.toolName, event.input as Rec), tool_use_id: event.toolCallId }, name, ctx);
    for (const d of ds) if (d.systemMessage) ctx.ui.notify(d.systemMessage, 'warning');
    const blocked = ds.find((d) => d.block);
    if (blocked) return { block: true, reason: steer(blocked.reason ?? 'blocked by achilles hook') };
    return undefined;
  });

  pi.on('tool_result', async (event, ctx) => {
    const name = claudeToolName(event.toolName);
    const input = claudeToolInput(event.toolName, event.input as Rec);
    const ds = await runEvent('PostToolUse', { tool_name: name, tool_input: input, tool_response: claudeToolResponse(event.toolName, event.input as Rec, event.content as Content, event.isError), tool_use_id: event.toolCallId }, name, ctx);
    const notes: string[] = [];
    for (const d of ds) {
      if (d.systemMessage) { notes.push(d.systemMessage); ctx.ui.notify(d.systemMessage, 'warning'); }
      if (d.additionalContext) notes.push(d.additionalContext);
      if (d.block && d.reason) notes.push(d.reason);
    }
    if (notes.length === 0) return undefined;
    return { content: [...event.content, { type: 'text', text: `\n[achilles] ${steer(notes.join('\n'))}` }] };
  });

  pi.on('agent_before_settle', async (event, ctx) => {
    if (event.outcome !== 'completed') return undefined;
    const ds = await runEvent('Stop', { stop_hook_active: stopHookActive }, undefined, ctx);
    for (const d of ds) if (d.systemMessage) ctx.ui.notify(d.systemMessage, 'warning');
    const blocked = ds.find((d) => d.block);
    if (!blocked) return undefined;
    stopHookActive = true;
    return { continue: true, entries: [{ type: 'custom_message', customType: 'achilles-stop-block', content: steer(blocked.reason ?? 'stopped by achilles hook'), display: true }] };
  });

  return { get enabled() { return enabled; }, disable: (r) => disable(r), runEvent, steer };
}
