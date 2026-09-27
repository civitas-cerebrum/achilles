import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import type { ExtensionAPI, ExtensionContext } from '@earendil-works/pi-coding-agent';
import { claudeToolName, claudeToolInput, claudeToolResponse, type Content } from './payload.ts';
import { resolveToCwd } from './edit-match.ts';
import { steer as steerText, createMessageCompactor, withOperatorStop, operatorOnly, OPERATOR_STOP, WARNING_TRUNCATED, type NoteKind } from './messages.ts';
import { skillRoots, PACKAGE_DIR } from './skills.ts';
import { log } from './log.ts';
import { piDepth, refMax } from './env.ts';
import { subagentOnlyDirs, blockedSkillRead, delegateInstruction, referenceDirs, largeReferenceRead, referenceNote, type SubagentOnlyDir, type ReferenceDir } from './guard.ts';
import { sessionStateDir, shadowPath, appendShadow, seedShadow, pruneShadows, KEEP_SHADOWS, toolUseEntry, assistantTextEntry, userPromptEntry, assistantText } from './transcript.ts';

export interface ManifestEntry { file: string; event: string; matcher: string | null; timeout?: number; async?: boolean }
export interface HookRun { file: string; exitCode: number | null; stdout: string; stderr: string; timedOut: boolean; ms: number }
export interface Decision { file: string; block: boolean; ask?: boolean; reason?: string; systemMessage?: string; additionalContext?: string }
export interface BridgeOptions { manifestPath?: string; hooksDir?: string; home?: string; bash?: string; skillRoots?: string[]; stateDir?: string }
export interface Bridge {
  readonly enabled: boolean;
  /** Tool calls whose pre-edit translation is held for PostToolUse (for tests). */
  readonly pendingTranslations: number;
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

/** The project's hooks dir: the nearest `.claude/hooks` walking up from cwd, stopping at the
 * filesystem root or at the first directory that contains `.git` (the repo root, inclusive). Used
 * only when pi trusts the project; otherwise, or when none is found, `~/.claude/hooks`. */
export function resolveHooksDir(cwd: string, home: string, trusted: boolean): string {
  if (trusted) {
    let dir = path.resolve(cwd);
    for (;;) {
      const candidate = path.join(dir, '.claude', 'hooks');
      if (fs.existsSync(candidate)) return candidate;
      const parent = path.dirname(dir);
      if (fs.existsSync(path.join(dir, '.git')) || parent === dir) break;
      dir = parent;
    }
  }
  return path.join(home, '.claude', 'hooks');
}

/** Distinct manifest files that are not present in hooksDir. */
export function missingHooks(manifest: ManifestEntry[], hooksDir: string): { missing: string[]; total: number } {
  const files = [...new Set(manifest.map((e) => e.file))];
  return { missing: files.filter((f) => !fs.existsSync(path.join(hooksDir, f))), total: files.length };
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
  else if (hso.permissionDecision === 'ask') { d.ask = true; d.reason = String(hso.permissionDecisionReason ?? 'hook asks for confirmation'); }
  else if (j.decision === 'block') { d.block = true; d.reason = String(j.reason ?? 'blocked by hook'); }
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

    // Decode as UTF-8 streams so a multi-byte character split across chunks is not mangled.
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
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

/** pi invokes a skill as `/skill:<name>`; Claude's hooks expect the slash command `/<name>`. */
export function claudePrompt(text: string): string {
  return text.replace(/^\/skill:([a-z0-9][a-z0-9-]*)(?=\s|$)/, '/$1');
}

/** True when the translation depends on the file as it was before the tool ran: several edits, or a
 * single edit whose Claude form differs from the model's text (CRLF, fuzzy match, BOM). */
function preEditDependent(piName: string, input: Rec, claudeInput: Rec): boolean {
  if (piName !== 'edit') return false;
  const edits = Array.isArray(input.edits) ? (input.edits as Array<{ oldText?: unknown; newText?: unknown }>) : [];
  if (edits.length > 1) return true;
  return edits.length === 1 && (claudeInput.old_string !== String(edits[0].oldText ?? '') || claudeInput.new_string !== String(edits[0].newText ?? ''));
}

/** Whether the file now contains `text`; an unreadable file counts as not containing it. */
function postEditHas(filePath: string, text: string, cwd: string): boolean {
  try { return fs.readFileSync(resolveToCwd(filePath, cwd), 'utf8').includes(text); } catch { return false; }
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
  // Claude-shaped tool input per in-flight tool call whose translation depends on the pre-edit file,
  // set at tool_call (only when the call is allowed) and consumed at tool_result.
  const translated = new Map<string, Rec>();
  let subOnly: SubagentOnlyDir[] = [];
  let refDirs: ReferenceDir[] = [];
  // Paths already steered about this session: the note is a nudge, not a drumbeat.
  const refNoted = new Set<string>();
  let lastAssistant = '';
  let subagentWarned = false;

  const steer = (t: string) => steerText(t, { roots, packageDir: PACKAGE_DIR });
  // Per-session dedupe of hook text on its way to the model (messages.ts); reset at session_start.
  const compact = createMessageCompactor();
  const denyText = (hook: string, reason: string, steered = true) => {
    const out = compact.deny(hook, reason);
    if (out !== reason) log('hook_text_compacted', { hook, kind: 'deny', text: reason });
    // The stop line goes last, after steer's "Under pi:" hints, on the first deny and every repeat.
    return steered ? withOperatorStop(reason, steer(out)) : out;
  };
  const noteText = (hook: string, text: string, kind: NoteKind) => {
    const out = compact.note(hook, text, kind);
    // Non-blocking hook output always reaches the log in full, whatever the model is shown.
    log('hook_note', { hook, kind, text, compacted: out !== text });
    return out;
  };
  /** This session's Claude-shaped shadow transcript (see transcript.ts); the hooks' transcript_path. */
  const shadowFor = (ctx: ExtensionContext) => shadowPath(ctx.sessionManager.getSessionId(), opts.stateDir ?? sessionStateDir(home));
  const record = (ctx: ExtensionContext, entry: Rec) => { if (enabled && !appendShadow(shadowFor(ctx), entry)) log('shadow_write_failed', { file: shadowFor(ctx) }); };
  const disable = (reason: string, ctx?: ExtensionContext) => {
    enabled = false;
    log('disabled', { reason });
    ctx?.ui.notify(`[achilles] hooks disabled: ${reason}`, 'warning');
  };

  // pi runs the tool calls of one assistant message in parallel, so their tool_call / tool_result
  // handlers overlap. Claude Code never runs two hook invocations at once, and hooks rely on that:
  // ledger-integrity-chain.sh read-modify-writes one sidecar for several files, so two overlapping
  // PostToolUse runs lose a record and the next sanctioned write is denied as an out-of-band mutation.
  // Every runEvent call therefore waits for the previous one to finish (a promise chain, in call
  // order). The lock is released in `finally`, so a throw or a timed-out hook never wedges the queue.
  // A hung hook does hold the queue for its whole timeout (runHook bounds that), so parallel calls
  // behind it wait: fail-closed serialisation is the deliberate tradeoff against a corrupted ledger.
  let hookQueue: Promise<void> = Promise.resolve();
  function runEvent(event: string, payload: Rec, toolName?: string, ctx?: ExtensionContext): Promise<Decision[]> {
    const prev = hookQueue;
    let release!: () => void;
    hookQueue = new Promise<void>((resolve) => { release = resolve; });
    return (async () => {
      await prev; // never rejects: every link resolves through `release`
      try { return await runEventNow(event, payload, toolName, ctx); } finally { release(); }
    })();
  }

  async function runEventNow(event: string, payload: Rec, toolName?: string, ctx?: ExtensionContext): Promise<Decision[]> {
    if (!enabled) return [];
    const depth = piDepth();
    const sessionId = ctx?.sessionManager.getSessionId();
    const common: Rec = {
      hook_event_name: event,
      session_id: sessionId,
      ...(ctx ? { transcript_path: shadowFor(ctx) } : {}),
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
      if (!fs.existsSync(hookPath)) { log('hook_missing', { event, tool: toolName, hook: e.file, hooksDir }); continue; }
      const args = { bash, hookPath, payload: full, timeoutMs: (e.timeout ?? 10) * 1000, cwd: common.cwd as string, env: process.env };
      // async hooks are fire-and-forget by design (nothing waits for their output), so they are
      // EXEMPT from the queue above: routing them through it would let a slow reporting hook delay
      // the blocking gates behind it. An async hook must therefore not read-modify-write state any
      // other hook touches — today only playwright-cli-cleanup-on-stop is async, and it writes none.
      if (e.async) { void runHook(args); continue; }
      const run = await runHook(args);
      const d = parseDecision(run, event);
      log('hook', { event, tool: toolName, hook: e.file, exit: run.exitCode, timedOut: run.timedOut, block: d.block, ms: run.ms, depth: String(piDepth()), agentType: process.env.ACHILLES_PI_AGENT_TYPE ?? undefined });
      out.push(d);
    }
    return out;
  }

  pi.on('session_start', async (_event, ctx) => guarded('session_start', ctx, undefined, async () => {
    stopHookActive = false;
    compact.reset();
    translated.clear();
    // A subagent's shadow inherits its parent's context signals (transcript.ts seedShadow).
    const parentShadow = process.env.ACHILLES_PI_PARENT_SHADOW;
    if (piDepth() >= 1 && parentShadow) {
      const seeded = seedShadow(shadowFor(ctx), parentShadow, opts.stateDir ?? sessionStateDir(home));
      log('shadow_seeded', { from: parentShadow, to: shadowFor(ctx), seeded });
    }
    // Nothing else prunes the shadow transcripts: one 8-phase run left 23 files and 2.5 MB of prompts
    // and tool inputs behind. The orchestrator's session start is the moment to tidy up; a child's is
    // not, since its siblings' shadows are still in use.
    if (piDepth() === 0) {
      const stateDir = opts.stateDir ?? sessionStateDir(home);
      const removed = pruneShadows(stateDir, shadowFor(ctx));
      if (removed > 0) log('shadow_pruned', { dir: path.join(stateDir, 'pi-transcripts'), removed, kept: KEEP_SHADOWS });
    }
    // The subagent-only read guard is achilles' own policy, not a hook, so it holds even when hook
    // execution ends up disabled below.
    subOnly = subagentOnlyDirs(roots);
    refDirs = referenceDirs(roots);
    refNoted.clear();
    const manifestPath = opts.manifestPath ?? path.join(PACKAGE_DIR, 'hooks', 'manifest.json');
    let loaded: ManifestEntry[];
    try { loaded = loadManifest(manifestPath); } catch (err) { return disable(`cannot read ${manifestPath}: ${String(err)}`, ctx); }
    let compiledNow: CompiledEntry[];
    try { compiledNow = compileManifest(loaded); } catch (err) { return disable(String(err instanceof Error ? err.message : err), ctx); }
    if (!opts.hooksDir) hooksDir = resolveHooksDir(ctx.cwd, home, ctx.isProjectTrusted());
    const { missing, total } = missingHooks(loaded, hooksDir);
    if (missing.length === total && total > 0) return disable(`none of the ${total} achilles hooks are installed in ${hooksDir}; reinstall @civitas-cerebrum/achilles (its postinstall copies them there)`, ctx);
    if (missing.length > 0) {
      log('hooks_missing', { hooksDir, missing, total });
      ctx.ui.notify(`[achilles] ${missing.length} of ${total} hooks are missing from ${hooksDir} and will not run: ${missing.join(', ')}. Reinstall @civitas-cerebrum/achilles to restore them.`, 'warning');
    }
    if (!which(bash)) return disable(`bash not found (${bash}); install bash to enable the achilles gates`, ctx);
    const jqBundled = fs.existsSync(path.join(hooksDir, 'bin', 'jq'));
    if (!jqBundled && !which('jq')) return disable(`jq not found at ${path.join(hooksDir, 'bin', 'jq')} or on PATH; reinstall @civitas-cerebrum/achilles or install jq`, ctx);
    // Enforcement is on unless the operator turns it off explicitly. A tool name is no evidence that
    // another extension really runs these hooks, so a `subagent` tool only earns a warning.
    if (process.env.ACHILLES_PI_HOOKS === 'off') return disable('ACHILLES_PI_HOOKS=off is set; achilles runs none of its hooks this session', ctx);
    if (!subagentWarned && pi.getAllTools().some((t) => t.name === 'subagent')) {
      subagentWarned = true;
      log('subagent_tool_present', {});
      ctx.ui.notify('[achilles] a `subagent` tool is loaded: another extension (pi-code or similar) may also run the settings.json hooks, so some gates could run twice. achilles hooks stay ON; set ACHILLES_PI_HOOKS=off to disable achilles\' copy.', 'warning');
    }
    manifest = loaded;
    compiled = compiledNow;
    enabled = true;
    log('bridge_ready', { hooksDir, hooks: manifest.length });
  }));

  // pi's compaction (and moving within the session tree) can drop the earlier full message a dedupe
  // pointer refers to, so the dedupe state starts over there too.
  pi.on('session_compact', async (_event, ctx) => guarded('session_compact', ctx, undefined, async () => { compact.reset(); return undefined; }));
  pi.on('session_tree', async (_event, ctx) => guarded('session_tree', ctx, undefined, async () => { compact.reset(); return undefined; }));

  pi.on('input', async (event, ctx) => guarded('input', ctx, undefined, async () => {
    stopHookActive = false;
    record(ctx, userPromptEntry(event.text));
    const ds = await runEvent('UserPromptSubmit', { prompt: claudePrompt(event.text) }, undefined, ctx);
    for (const d of ds) if (d.systemMessage) ctx.ui.notify(d.systemMessage, 'warning');
    return undefined;
  }));

  pi.on('tool_call', async (event, ctx) => guarded('tool_call', ctx, { block: true, reason: steer('[achilles] internal error handling tool_call; call blocked (fail closed)') }, async () => {
    const name = claudeToolName(event.toolName);
    // The cache entry survives only when the call is allowed to run; every blocked or failed path drops it.
    let keep = false;
    let claudeInput: Rec = {};
    try {
      if (enabled) {
        // Translate once, against the file as it is before the tool runs. A multi-part or normalised
        // edit can only be reconstructed from the pre-edit file, so PostToolUse reuses it.
        claudeInput = claudeToolInput(event.toolName, event.input as Rec, ctx.cwd);
        if (preEditDependent(event.toolName, event.input as Rec, claudeInput)) translated.set(event.toolCallId, claudeInput);
        // Record the call first, exactly as Claude's transcript would hold it, so a PreToolUse hook that
        // reads transcript_path sees its own call.
        record(ctx, toolUseEntry(event.toolName, event.toolCallId, claudeInput));
      }
      // The orchestrator must delegate subagent-only skills, not read them into its own context.
      if (piDepth() === 0) {
        const skill = blockedSkillRead(event.toolName, event.input as Rec, subOnly, ctx.cwd, home);
        if (skill) { log('skill_read_blocked', { skill, tool: name }); return { block: true, reason: delegateInstruction(skill) }; }
      }
      if (!enabled) return undefined;
      const ds = await runEvent('PreToolUse', { tool_name: name, tool_input: claudeInput, tool_use_id: event.toolCallId }, name, ctx);
      for (const d of ds) if (d.systemMessage) ctx.ui.notify(d.systemMessage, 'warning');
      const blocked = ds.find((d) => d.block);
      if (blocked) return { block: true, reason: denyText(blocked.file, blocked.reason ?? 'blocked by achilles hook') };
      // permissionDecision "ask": Claude asks the operator. With a dialog-capable UI (and only in the
      // orchestrator) so do we; with no UI (print/json mode, every child) nobody can answer, so block.
      const asked = ds.find((d) => d.ask);
      if (asked) {
        const reason = asked.reason ?? 'achilles hook asks for confirmation';
        const canAsk = ctx.hasUI && piDepth() === 0;
        const approved = canAsk ? await ctx.ui.confirm(`[achilles] ${asked.file} asks for confirmation`, reason) : false;
        log('ask', { hook: asked.file, tool: name, prompted: canAsk, approved });
        if (!approved) return { block: true, reason: denyText(asked.file, reason) };
      }
      keep = true;
      return undefined;
    } finally {
      if (!keep) translated.delete(event.toolCallId);
    }
  }));

  pi.on('tool_result', async (event, ctx) => guarded('tool_result', ctx, undefined, async () => {
    const name = claudeToolName(event.toolName);
    let input = translated.get(event.toolCallId);
    translated.delete(event.toolCallId);
    // Parallel edits to the same file: pi serialises them per file, so an edit translated at tool_call
    // may have run against a file another call changed first. If its new text is not in the file now,
    // the cached translation is stale; fall back to translating against the current file.
    if (input && typeof input.new_string === 'string' && !postEditHas(String(input.file_path ?? ''), input.new_string, ctx.cwd)) input = undefined;
    input ??= claudeToolInput(event.toolName, event.input as Rec, ctx.cwd);
    const ds = await runEvent('PostToolUse', { tool_name: name, tool_input: input, tool_response: claudeToolResponse(event.toolName, event.input as Rec, event.content as Content, event.isError, (event as { details?: unknown }).details, ctx.cwd), tool_use_id: event.toolCallId }, name, ctx);
    const notes: string[] = [];
    for (const d of ds) {
      // The UI always gets the full text; the model gets the compacted form (messages.ts).
      if (d.systemMessage) { notes.push(noteText(d.file, d.systemMessage, 'systemMessage')); ctx.ui.notify(d.systemMessage, 'warning'); }
      if (d.additionalContext) {
        const shown = noteText(d.file, d.additionalContext, 'additionalContext');
        notes.push(shown);
        // Cut for the model: the full text goes to the UI (and the log, in noteText).
        if (shown.endsWith(WARNING_TRUNCATED)) ctx.ui.notify(d.additionalContext, 'info');
      }
      if (d.block && d.reason) notes.push(denyText(d.file, d.reason, false));
      else if (!d.block && d.reason) { notes.push(noteText(d.file, d.reason, 'reason')); ctx.ui.notify(d.reason, 'warning'); }
    }
    // A big skill reference read at depth 0: the content comes back whole, with one note steering the
    // next such read towards a dispatch. Once per path per session (see refNoted).
    if (piDepth() === 0) {
      const ref = largeReferenceRead(event.toolName, event.input as Rec, refDirs, ctx.cwd, home, refMax());
      if (ref && !refNoted.has(ref.path)) {
        refNoted.add(ref.path);
        log('ref_steer', { path: ref.path, bytes: ref.bytes, skill: ref.skill });
        notes.push(referenceNote(ref));
      }
    }
    if (notes.length === 0) return undefined;
    const stop = ds.some((d) => d.block && d.reason && operatorOnly(d.reason));
    const joined = `${steer(notes.join('\n'))}${stop ? `\n${OPERATOR_STOP}` : ''}`;
    return { content: [...event.content, { type: 'text', text: `\n${joined.startsWith('[achilles]') ? '' : '[achilles] '}${joined}` }] };
  }));

  // A call pi never finishes (aborted run) leaves no tool_result; drop its translation when the run ends.
  pi.on('agent_end', async (_event, ctx) => guarded('agent_end', ctx, undefined, async () => { translated.clear(); return undefined; }));

  pi.on('message_end', async (event, ctx) => guarded('message_end', ctx, undefined, async () => {
    const text = assistantText(event.message);
    if (text.trim()) { lastAssistant = text; record(ctx, assistantTextEntry(text)); }
    return undefined;
  }));

  pi.on('agent_before_settle', async (event, ctx) => guarded('agent_before_settle', ctx, undefined, async () => {
    if (event.outcome !== 'completed') return undefined;
    // A child session (depth >= 1) is a subagent finishing: Claude runs SubagentStop there, not Stop,
    // and honours its blocks the same way (the subagent keeps working).
    const sub = piDepth() >= 1;
    const ds = await runEvent(sub ? 'SubagentStop' : 'Stop', {
      stop_hook_active: stopHookActive,
      ...(lastAssistant ? { last_assistant_message: lastAssistant } : {}),
      ...(sub ? { agent_transcript_path: shadowFor(ctx) } : {}),
    }, undefined, ctx);
    for (const d of ds) {
      if (d.systemMessage) ctx.ui.notify(d.systemMessage, 'warning');
      if (!d.block && d.reason) ctx.ui.notify(d.reason, 'warning');
    }
    const blocked = ds.find((d) => d.block);
    if (!blocked) return undefined;
    stopHookActive = true;
    return { continue: true, entries: [{ type: 'custom_message', customType: sub ? 'achilles-subagent-stop-block' : 'achilles-stop-block', content: denyText(blocked.file, blocked.reason ?? 'stopped by achilles hook'), display: true }] };
  }));

  return { get enabled() { return enabled; }, get pendingTranslations() { return translated.size; }, disable: (r) => disable(r), runEvent, steer };
}
