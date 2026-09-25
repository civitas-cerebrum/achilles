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
type CompiledEntry = { entry: ManifestEntry; match: (name: string) => boolean };

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

/** Compile every entry's matcher once, up front, so a bad regex surfaces as one named session_start
 * failure instead of throwing out of a live event handler on whichever event hits it first. */
export function compileManifest(manifest: ManifestEntry[]): CompiledEntry[] {
  return manifest.map((entry) => {
    try {
      return { entry, match: compileMatcher(entry.matcher) };
    } catch (err) {
      throw new Error(`invalid matcher ${JSON.stringify(entry.matcher)} for ${entry.file} (${entry.event}): ${String(err)}`);
    }
  });
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

  // Serialize before touching the filesystem/process table: an unserializable payload (e.g. a
  // stray BigInt from a tool's input) must fail closed as a normal HookRun, never throw out of
  // runHook and up into a pi.on handler.
  let payloadJson: string;
  try {
    payloadJson = JSON.stringify(o.payload) ?? 'null';
  } catch (err) {
    return Promise.resolve({ file, exitCode: 127, stdout: '', stderr: `[achilles] cannot serialize payload: ${String(err)}`, timedOut: false, ms: Date.now() - started });
  }

  return new Promise((resolve) => {
    let stdout = '', stderr = '', timedOut = false, done = false, exitedCode: number | null = null;
    let overallTimer: NodeJS.Timeout;
    let graceTimer: NodeJS.Timeout | undefined;
    let lastResortTimer: NodeJS.Timeout | undefined;

    const clearTimers = () => {
      clearTimeout(overallTimer);
      if (graceTimer) clearTimeout(graceTimer);
      if (lastResortTimer) clearTimeout(lastResortTimer);
    };
    const finish = (exitCode: number | null) => {
      if (done) return; done = true;
      clearTimers();
      resolve({ file, exitCode, stdout, stderr, timedOut, ms: Date.now() - started });
    };

    let child;
    try { child = spawn(o.bash, [o.hookPath], { cwd: o.cwd, env: o.env, stdio: ['pipe', 'pipe', 'pipe'], detached: true }); }
    catch (err) { stderr = String(err); return finish(127); }

    // detached: true makes the hook the leader of its own process group, so a forced kill reaches
    // the whole group (bash + any grandchildren it spawned, e.g. `sleep 3 &`), not just bash itself.
    const killGroup = () => {
      try { if (child.pid) process.kill(-child.pid, 'SIGKILL'); } catch { /* group already gone */ }
      try { child.kill('SIGKILL'); } catch { /* already dead */ }
    };

    overallTimer = setTimeout(() => {
      if (done) return;
      timedOut = true;
      killGroup();
      try { child.stdout.destroy(); } catch { /* already gone */ }
      try { child.stderr.destroy(); } catch { /* already gone */ }
      // Destroying the streams should make 'close' fire almost immediately; settle anyway if it
      // somehow doesn't, so a stuck kernel-level pipe can never hang the bridge indefinitely.
      lastResortTimer = setTimeout(() => finish(exitedCode), 100);
    }, o.timeoutMs);

    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    child.on('error', (err) => { stderr += String(err); finish(127); });

    // The hook process exiting does not mean its stdio pipes are drained — a backgrounded
    // grandchild (e.g. `sleep 3 &`) can keep holding them open, and 'exit' can even fire before the
    // kernel has finished delivering buffered stdout/stderr. Give the OS a short, bounded grace
    // window to deliver 'close' (fully drained) naturally; only if that window expires — because
    // something is still holding the pipes — do we force the issue.
    child.on('exit', (code) => {
      exitedCode = code;
      if (done) return;
      const remaining = o.timeoutMs - (Date.now() - started);
      const graceMs = Math.max(0, Math.min(250, remaining));
      graceTimer = setTimeout(() => {
        if (done) return;
        killGroup();
        try { child.stdout.destroy(); } catch { /* already gone */ }
        try { child.stderr.destroy(); } catch { /* already gone */ }
      }, graceMs);
    });

    // 'close' fires once the process has exited AND all stdio streams are fully drained/closed — the
    // only point at which stdout/stderr are guaranteed complete. This is the sole settlement path;
    // the two forced-kill branches above exist only to bound how long we wait for it.
    child.on('close', (code) => { finish(code); });

    child.stdin.on('error', () => {});
    child.stdin.end(payloadJson);
  });
}

function which(bin: string): boolean {
  return spawnSync(bin, ['--version'], { stdio: 'ignore' }).error === undefined;
}

/** Runs `fn`; on a thrown error, logs + notifies + returns `fallback` instead of letting the
 * exception escape the pi.on handler. No handler this bridge registers is ever allowed to throw. */
async function guarded<T>(eventName: string, ctx: ExtensionContext | undefined, fallback: T, fn: () => Promise<T>): Promise<T> {
  try {
    return await fn();
  } catch (err) {
    log('handler_error', { event: eventName, error: String(err) });
    ctx?.ui.notify(`[achilles] internal error in ${eventName} handler: ${String(err)}`, 'warning');
    return fallback;
  }
}

export function createBridge(pi: ExtensionAPI, opts: BridgeOptions = {}): Bridge {
  const home = opts.home ?? os.homedir();
  const bash = opts.bash ?? 'bash';
  const roots = opts.skillRoots ?? skillRoots(home);
  let manifest: ManifestEntry[] = [];
  let compiled: CompiledEntry[] = [];
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
    const depth = Number(process.env.ACHILLES_PI_DEPTH ?? '0');
    const sessionId = ctx?.sessionManager.getSessionId();
    const common: Rec = {
      hook_event_name: event,
      session_id: sessionId,
      ...(ctx?.sessionManager.getSessionFile() ? { transcript_path: ctx.sessionManager.getSessionFile() } : {}),
      cwd: ctx?.cwd ?? process.cwd(),
      // Claude Code's ledger write-gates (pipeline_check_sod, e.g. hooks/lib/pipeline-gate.sh) deny
      // any reviewer-approved transition when agent_id is empty, because under Claude Code only
      // subagent tool calls carry it. pi has no equivalent field, so a subagent invocation (Task 7's
      // Agent tool) sets ACHILLES_PI_DEPTH in the child's env; mirror that into agent_id so the same
      // gates can tell a subagent call from a top-level one under pi too.
      ...(depth > 0 ? { agent_id: sessionId } : {}),
      ...(depth > 0 && process.env.ACHILLES_PI_AGENT_TYPE ? { agent_type: process.env.ACHILLES_PI_AGENT_TYPE } : {}),
    };
    const full = { ...common, ...payload };
    const out: Decision[] = [];
    for (const { entry: e, match } of compiled) {
      if (e.event !== event) continue;
      if (toolName !== undefined && !match(toolName)) continue;
      if (e.matcher !== null && toolName === undefined) continue;
      const hookPath = path.join(hooksDir, e.file);
      if (!fs.existsSync(hookPath)) continue;
      const args = { bash, hookPath, payload: full, timeoutMs: (e.timeout ?? 10) * 1000, cwd: common.cwd as string, env: process.env };
      if (e.async) { void runHook(args); continue; }
      const run = await runHook(args);
      const d = parseDecision(run, event);
      log('hook', { event, tool: toolName, hook: e.file, exit: run.exitCode, timedOut: run.timedOut, block: d.block, ms: run.ms, depth: process.env.ACHILLES_PI_DEPTH ?? '0' });
      out.push(d);
    }
    return out;
  }

  pi.on('session_start', async (_event, ctx) => guarded('session_start', ctx, undefined, async () => {
    stopHookActive = false;
    const manifestPath = opts.manifestPath ?? path.join(PACKAGE_DIR, 'hooks', 'manifest.json');
    let loaded: ManifestEntry[];
    try { loaded = loadManifest(manifestPath); } catch (err) { return disable(`cannot read ${manifestPath}: ${String(err)}`, ctx); }
    let compiledNow: CompiledEntry[];
    try { compiledNow = compileManifest(loaded); } catch (err) { return disable(String(err instanceof Error ? err.message : err), ctx); }
    if (!opts.hooksDir) hooksDir = resolveHooksDir(ctx.cwd, home, ctx.isProjectTrusted());
    if (!which(bash)) return disable(`bash not found (${bash}); install bash to enable the achilles gates`, ctx);
    const jqBundled = fs.existsSync(path.join(hooksDir, 'bin', 'jq'));
    if (!jqBundled && !which('jq')) return disable(`jq not found at ${path.join(hooksDir, 'bin', 'jq')} or on PATH; reinstall @civitas-cerebrum/achilles or install jq`, ctx);
    if (pi.getAllTools().some((t) => t.name === 'subagent')) return disable('another subagent extension (pi-code or similar) is loaded and already runs the settings.json hooks; achilles hook execution is off to avoid running every gate twice', ctx);
    manifest = loaded;
    compiled = compiledNow;
    enabled = true;
    log('bridge_ready', { hooksDir, hooks: manifest.length });
  }));

  pi.on('input', async (event, ctx) => guarded('input', ctx, undefined, async () => {
    stopHookActive = false;
    const ds = await runEvent('UserPromptSubmit', { prompt: event.text }, undefined, ctx);
    for (const d of ds) if (d.systemMessage) ctx.ui.notify(d.systemMessage, 'warning');
    return undefined;
  }));

  pi.on('tool_call', async (event, ctx) => guarded('tool_call', ctx, { block: true, reason: steer('[achilles] internal error handling tool_call; call blocked (fail closed)') }, async () => {
    const name = claudeToolName(event.toolName);
    const ds = await runEvent('PreToolUse', { tool_name: name, tool_input: claudeToolInput(event.toolName, event.input as Rec), tool_use_id: event.toolCallId }, name, ctx);
    for (const d of ds) if (d.systemMessage) ctx.ui.notify(d.systemMessage, 'warning');
    const blocked = ds.find((d) => d.block);
    if (blocked) return { block: true, reason: steer(blocked.reason ?? 'blocked by achilles hook') };
    return undefined;
  }));

  pi.on('tool_result', async (event, ctx) => guarded('tool_result', ctx, undefined, async () => {
    const name = claudeToolName(event.toolName);
    const input = claudeToolInput(event.toolName, event.input as Rec);
    const ds = await runEvent('PostToolUse', { tool_name: name, tool_input: input, tool_response: claudeToolResponse(event.toolName, event.input as Rec, event.content as Content, event.isError), tool_use_id: event.toolCallId }, name, ctx);
    const notes: string[] = [];
    for (const d of ds) {
      if (d.systemMessage) { notes.push(d.systemMessage); ctx.ui.notify(d.systemMessage, 'warning'); }
      if (d.additionalContext) notes.push(d.additionalContext);
      if (d.block && d.reason) notes.push(d.reason);
      else if (!d.block && d.reason) { notes.push(d.reason); ctx.ui.notify(d.reason, 'warning'); }
    }
    if (notes.length === 0) return undefined;
    return { content: [...event.content, { type: 'text', text: `\n[achilles] ${steer(notes.join('\n'))}` }] };
  }));

  pi.on('agent_before_settle', async (event, ctx) => guarded('agent_before_settle', ctx, undefined, async () => {
    if (event.outcome !== 'completed') return undefined;
    const ds = await runEvent('Stop', { stop_hook_active: stopHookActive }, undefined, ctx);
    for (const d of ds) {
      if (d.systemMessage) ctx.ui.notify(d.systemMessage, 'warning');
      if (!d.block && d.reason) ctx.ui.notify(d.reason, 'warning');
    }
    const blocked = ds.find((d) => d.block);
    if (!blocked) return undefined;
    stopHookActive = true;
    return { continue: true, entries: [{ type: 'custom_message', customType: 'achilles-stop-block', content: steer(blocked.reason ?? 'stopped by achilles hook'), display: true }] };
  }));

  return { get enabled() { return enabled; }, disable: (r) => disable(r), runEvent, steer };
}
