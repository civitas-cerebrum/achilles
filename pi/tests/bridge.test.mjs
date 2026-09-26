import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { makeFakePi, makeFakeCtx } from './fake-pi.mjs';
import { compileMatcher, parseDecision, resolveHooksDir, runHook, createBridge, claudePrompt } from '../extensions/achilles/bridge.ts';

const fx = path.join(import.meta.dirname, 'fixtures');
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'bridge-'));
const opts = () => ({ manifestPath: path.join(fx, 'manifest.json'), hooksDir: path.join(fx, 'hooks'), skillRoots: [path.join(fx, 'skills')], home: os.tmpdir(), stateDir: tmp() });
async function start(pi, ctx, o = opts()) { const b = createBridge(pi, o); await pi.fire('session_start', { type: 'session_start', reason: 'startup' }, ctx); return b; }
// Sets process.env.HOOK_RECORD_FILE for this test and restores it afterward via t.after, so test
// order never depends on a leftover value from a previous test.
function recordFile(t) {
  const rec = path.join(tmp(), 'rec');
  const prev = process.env.HOOK_RECORD_FILE;
  process.env.HOOK_RECORD_FILE = rec;
  t.after(() => { if (prev === undefined) delete process.env.HOOK_RECORD_FILE; else process.env.HOOK_RECORD_FILE = prev; });
  return rec;
}
// Sets process.env[key] for this test and restores the previous value (or deletes it) afterward.
function withEnv(t, key, value) {
  const prev = process.env[key];
  process.env[key] = value;
  t.after(() => { if (prev === undefined) delete process.env[key]; else process.env[key] = prev; });
}

test('compileMatcher', () => {
  assert.ok(compileMatcher(null)('anything'));
  const we = compileMatcher('Write|Edit'); assert.ok(we('Write')); assert.ok(we('Edit')); assert.ok(!we('Bash')); assert.ok(!we('write'));
  const mcp = compileMatcher('mcp__.*'); assert.ok(mcp('mcp__jira__x')); assert.ok(!mcp('Bash'));
});
test('resolveHooksDir', () => {
  const home = tmp(); const proj = tmp();
  fs.mkdirSync(path.join(proj, '.claude', 'hooks'), { recursive: true });
  assert.equal(resolveHooksDir(proj, home, true), path.join(proj, '.claude', 'hooks'));
  assert.equal(resolveHooksDir(proj, home, false), path.join(home, '.claude', 'hooks'));
  assert.equal(resolveHooksDir(tmp(), home, true), path.join(home, '.claude', 'hooks'));
});
test('resolveHooksDir walks up from a subdirectory, stopping at the first dir holding .git', () => {
  const home = tmp(); const proj = tmp();
  fs.mkdirSync(path.join(proj, '.claude', 'hooks'), { recursive: true });
  fs.mkdirSync(path.join(proj, '.git'));
  const deep = path.join(proj, 'packages', 'app', 'src'); fs.mkdirSync(deep, { recursive: true });
  assert.equal(resolveHooksDir(deep, home, true), path.join(proj, '.claude', 'hooks'));
  assert.equal(resolveHooksDir(deep, home, false), path.join(home, '.claude', 'hooks'));
  // A nested repo (its own .git) with no hooks does not reach the outer project's hooks.
  const nested = path.join(proj, 'vendor', 'lib'); fs.mkdirSync(path.join(nested, '.git'), { recursive: true });
  assert.equal(resolveHooksDir(path.join(nested), home, true), path.join(home, '.claude', 'hooks'));
  // The first match wins: a closer .claude/hooks shadows the outer one.
  const inner = path.join(proj, 'packages', 'app'); fs.mkdirSync(path.join(inner, '.claude', 'hooks'), { recursive: true });
  assert.equal(resolveHooksDir(deep, home, true), path.join(inner, '.claude', 'hooks'));
});
test('session_start: some manifest hooks missing → notify + log, bridge stays enabled; runEvent logs hook_missing', async (t) => {
  const logFile = path.join(tmp(), 'log.jsonl'); withEnv(t, 'ACHILLES_PI_LOG', logFile);
  const dir = tmp(); const manifestPath = path.join(dir, 'm.json');
  fs.writeFileSync(manifestPath, JSON.stringify([
    { file: 'deny.sh', event: 'PreToolUse', matcher: 'Bash', timeout: 5 },
    { file: 'ghost.sh', event: 'PreToolUse', matcher: 'Bash', timeout: 5 },
    { file: 'ghost.sh', event: 'Stop', matcher: null, timeout: 5 },
  ]));
  const pi = makeFakePi(); const ctx = makeFakeCtx(); const b = await start(pi, ctx, { ...opts(), manifestPath });
  assert.equal(b.enabled, true);
  assert.ok(ctx.notices.some((n) => /1 of 2 hooks are missing/.test(n.m) && /ghost\.sh/.test(n.m)));
  const r = await pi.fire('tool_call', { type: 'tool_call', toolCallId: 'm1', toolName: 'bash', input: { command: 'ls' } }, ctx);
  assert.match(r.reason, /nope/, 'present hooks still run');
  const lines = fs.readFileSync(logFile, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  assert.ok(lines.some((l) => l.kind === 'hooks_missing' && l.missing.includes('ghost.sh') && l.total === 2));
  assert.ok(lines.some((l) => l.kind === 'hook_missing' && l.hook === 'ghost.sh' && l.event === 'PreToolUse'));
});
test('session_start: all manifest hooks missing → bridge disabled with a warning', async () => {
  const pi = makeFakePi(); const ctx = makeFakeCtx(); const b = await start(pi, ctx, { ...opts(), hooksDir: tmp() });
  assert.equal(b.enabled, false);
  assert.ok(ctx.notices.some((n) => /none of the \d+ achilles hooks are installed/.test(n.m)));
});
test('session_start without a hooksDir option resolves it from ctx.cwd (walk-up, trusted)', async (t) => {
  const logFile = path.join(tmp(), 'log.jsonl'); withEnv(t, 'ACHILLES_PI_LOG', logFile);
  const proj = tmp(); fs.mkdirSync(path.join(proj, '.git'));
  const hooks = path.join(proj, '.claude', 'hooks'); fs.mkdirSync(hooks, { recursive: true });
  for (const f of fs.readdirSync(path.join(fx, 'hooks'))) fs.copyFileSync(path.join(fx, 'hooks', f), path.join(hooks, f));
  const sub = path.join(proj, 'src'); fs.mkdirSync(sub);
  const o = opts(); delete o.hooksDir;
  const pi = makeFakePi(); const ctx = makeFakeCtx({ cwd: sub, trusted: true }); const b = await start(pi, ctx, o);
  assert.equal(b.enabled, true);
  assert.ok(fs.readFileSync(logFile, 'utf8').includes(`"hooksDir":${JSON.stringify(hooks)}`));
});
test('parseDecision', () => {
  const base = { file: 'h.sh', exitCode: 0, stdout: '', stderr: '', timedOut: false, ms: 1 };
  assert.equal(parseDecision(base, 'PreToolUse').block, false);
  assert.equal(parseDecision({ ...base, stdout: 'plain text' }, 'PreToolUse').block, false);
  const d = parseDecision({ ...base, stdout: '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"r"}}' }, 'PreToolUse');
  assert.equal(d.block, true); assert.equal(d.reason, 'r');
  assert.equal(parseDecision({ ...base, stdout: '{"decision":"block","reason":"s"}' }, 'Stop').reason, 's');
  assert.equal(parseDecision({ ...base, exitCode: 2, stderr: 'e' }, 'PreToolUse').reason, 'e');
  assert.equal(parseDecision({ ...base, timedOut: true, exitCode: null }, 'PreToolUse').block, true);
  assert.equal(parseDecision({ ...base, timedOut: true, exitCode: null }, 'Stop').block, false);
  assert.equal(parseDecision({ ...base, exitCode: 1, stderr: 'FATAL' }, 'PreToolUse').block, true);
  assert.equal(parseDecision({ ...base, exitCode: 1, stderr: 'FATAL' }, 'PostToolUse').block, false);
  assert.equal(parseDecision({ ...base, stdout: '{"systemMessage":"m"}' }, 'PostToolUse').systemMessage, 'm');
});
test('runHook pipes payload and enforces timeout', async () => {
  const rec = path.join(tmp(), 'rec');
  const r = await runHook({ bash: 'bash', hookPath: path.join(fx, 'hooks', 'record.sh'), payload: { a: 1 }, timeoutMs: 2000, cwd: os.tmpdir(), env: { ...process.env, HOOK_RECORD_FILE: rec } });
  assert.equal(r.exitCode, 0); assert.equal(fs.readFileSync(rec, 'utf8').trim(), '{"a":1}');
  const t = await runHook({ bash: 'bash', hookPath: path.join(fx, 'hooks', 'sleep.sh'), payload: {}, timeoutMs: 300, cwd: os.tmpdir(), env: process.env });
  assert.equal(t.timedOut, true);
  assert.ok(t.ms < 800, `expected settlement within timeoutMs+500 (800ms), got ${t.ms}ms`);
});
test('runHook does not wait on a backgrounded grandchild (bounded grace after exit, then forced close)', async () => {
  const r = await runHook({ bash: 'bash', hookPath: path.join(fx, 'hooks', 'bg.sh'), payload: {}, timeoutMs: 5000, cwd: os.tmpdir(), env: process.env });
  assert.equal(r.exitCode, 0);
  assert.equal(r.timedOut, false);
  assert.ok(r.ms < 1000, `expected settlement well under the 3s backgrounded sleep, got ${r.ms}ms`);
});
test('runHook settles on close, never truncating a large stdout (repeated)', async () => {
  for (let i = 0; i < 20; i++) {
    const r = await runHook({ bash: 'bash', hookPath: path.join(fx, 'hooks', 'bigdeny.sh'), payload: {}, timeoutMs: 5000, cwd: os.tmpdir(), env: process.env });
    assert.equal(r.exitCode, 0, `run ${i}: exitCode`);
    assert.equal(r.timedOut, false, `run ${i}: timedOut`);
    let parsed;
    assert.doesNotThrow(() => { parsed = JSON.parse(r.stdout); }, `run ${i}: stdout did not parse as JSON (len ${r.stdout.length})`);
    const reason = parsed.hookSpecificOutput.permissionDecisionReason;
    assert.equal(reason.length, 120000, `run ${i}: reason length`);
    assert.ok(/^x+$/.test(reason), `run ${i}: reason content`);
  }
});
test('tool_call: deny with steered reason', async () => {
  const pi = makeFakePi(); const ctx = makeFakeCtx(); await start(pi, ctx);
  const r = await pi.fire('tool_call', { type: 'tool_call', toolCallId: 't1', toolName: 'bash', input: { command: 'ls' } }, ctx);
  assert.equal(r.block, true);
  assert.match(r.reason, /\[BLOCKED\] nope/);
  assert.match(r.reason, /Load it: Skill \{ skill: "orch-skill" \}/);
  assert.match(r.reason, new RegExp(path.join(fx, 'skills', 'orch-skill', 'SKILL.md').replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
});
test('multi-part edit reaches hooks as one whole-file Edit, before and after the file changes', async (t) => {
  const rec = recordFile(t);
  const dir = tmp();
  fs.writeFileSync(path.join(dir, 'ledger.json'), '{"a":"o1","b":"o2"}');
  const pi = makeFakePi(); const ctx = makeFakeCtx({ cwd: dir }); await start(pi, ctx);
  const input = { path: 'ledger.json', edits: [{ oldText: '"o1"', newText: '"n1"' }, { oldText: '"o2"', newText: '"n2"' }] };
  assert.equal(await pi.fire('tool_call', { type: 'tool_call', toolCallId: 'm1', toolName: 'edit', input }, ctx), undefined);
  fs.writeFileSync(path.join(dir, 'ledger.json'), '{"a":"n1","b":"n2"}'); // pi applies the edit
  await pi.fire('tool_result', { type: 'tool_result', toolCallId: 'm1', toolName: 'edit', input, content: [{ type: 'text', text: 'ok' }], isError: false }, ctx);
  const [pre, post] = fs.readFileSync(rec, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  const expected = { file_path: path.join(dir, 'ledger.json'), old_string: '{"a":"o1","b":"o2"}', new_string: '{"a":"n1","b":"n2"}' };
  assert.equal(pre.hook_event_name, 'PreToolUse'); assert.deepEqual(pre.tool_input, expected);
  assert.equal(post.hook_event_name, 'PostToolUse'); assert.deepEqual(post.tool_input, expected);
});
test('tool_call: plain text stdout allows; payload is Claude-shaped', async (t) => {
  const rec = recordFile(t);
  const o = opts();
  const pi = makeFakePi(); const ctx = makeFakeCtx({ sessionFile: '/s/file.jsonl' }); await start(pi, ctx, o);
  const r = await pi.fire('tool_call', { type: 'tool_call', toolCallId: 't2', toolName: 'edit', input: { path: 'a.md', edits: [{ oldText: 'o', newText: 'n' }] } }, ctx);
  assert.equal(r, undefined);
  const p = JSON.parse(fs.readFileSync(rec, 'utf8').trim());
  assert.equal(p.hook_event_name, 'PreToolUse'); assert.equal(p.tool_name, 'Edit');
  assert.deepEqual(p.tool_input, { file_path: path.join(ctx.cwd, 'a.md'), old_string: 'o', new_string: 'n' });
  assert.equal(p.session_id, 'sid-1'); assert.equal(p.cwd, ctx.cwd); assert.equal(p.tool_use_id, 't2');
  // transcript_path is the Claude-shaped shadow, not pi's own session file.
  assert.equal(p.transcript_path, path.join(o.stateDir, 'pi-transcripts', 'sid-1.jsonl'));
  // The call was recorded before the hook ran, exactly as Claude records it.
  const lines = fs.readFileSync(p.transcript_path, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  assert.deepEqual(lines.at(-1), { type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', id: 't2', name: 'Edit', input: { file_path: path.join(ctx.cwd, 'a.md'), old_string: 'o', new_string: 'n' } }] } });
});
test('parseDecision: permissionDecision ask is neither allow nor deny', () => {
  const d = parseDecision({ file: 'h.sh', exitCode: 0, stdout: '{"hookSpecificOutput":{"permissionDecision":"ask","permissionDecisionReason":"sure?"}}', stderr: '', timedOut: false, ms: 1 }, 'PreToolUse');
  assert.equal(d.block, false); assert.equal(d.ask, true); assert.equal(d.reason, 'sure?');
});
const grepCall = { type: 'tool_call', toolCallId: 'g1', toolName: 'grep', input: { pattern: 'x' } };
test('ask: no UI (print/json mode) blocks with the steered reason and shows no dialog', async () => {
  const pi = makeFakePi(); const ctx = makeFakeCtx({ hasUI: false, confirmAnswer: true }); await start(pi, ctx);
  const r = await pi.fire('tool_call', grepCall, ctx);
  assert.equal(r.block, true); assert.match(r.reason, /\[ASK\] confirm/); assert.match(r.reason, /Load it: Skill \{ skill: "orch-skill" \}/);
  assert.equal(ctx.confirms.length, 0);
});
test('ask: with UI, the operator is asked; approve allows, decline blocks with the reason', async () => {
  const pi = makeFakePi(); const yes = makeFakeCtx({ hasUI: true, mode: 'tui', confirmAnswer: true }); await start(pi, yes);
  assert.equal(await pi.fire('tool_call', grepCall, yes), undefined);
  assert.equal(yes.confirms.length, 1); assert.match(yes.confirms[0].title, /ask\.sh/); assert.match(yes.confirms[0].message, /\[ASK\] confirm/);
  const no = makeFakeCtx({ hasUI: true, mode: 'tui', confirmAnswer: false });
  const r = await pi.fire('tool_call', grepCall, no);
  assert.equal(r.block, true); assert.match(r.reason, /\[ASK\] confirm/); assert.equal(no.confirms.length, 1);
});
test('ask: a child session (depth 1) blocks without a dialog even when a UI exists', async (t) => {
  withEnv(t, 'ACHILLES_PI_DEPTH', '1');
  const pi = makeFakePi(); const ctx = makeFakeCtx({ hasUI: true, confirmAnswer: true }); await start(pi, ctx);
  const r = await pi.fire('tool_call', grepCall, ctx);
  assert.equal(r.block, true); assert.equal(ctx.confirms.length, 0);
});
test('tool_call: exit 2 stderr is the reason; timeout blocks', async () => {
  const pi = makeFakePi(); const ctx = makeFakeCtx(); await start(pi, ctx);
  const r = await pi.fire('tool_call', { type: 'tool_call', toolCallId: 't3', toolName: 'mcp__jira__create', input: {} }, ctx);
  assert.equal(r.block, true); assert.match(r.reason, /stderr reason/);
  const t0 = Date.now();
  const t = await pi.fire('tool_call', { type: 'tool_call', toolCallId: 't4', toolName: 'Agent', input: { description: 'd', prompt: 'p' } }, ctx);
  const elapsed = Date.now() - t0;
  assert.equal(t.block, true); assert.match(t.reason, /timed out/);
  assert.ok(elapsed < 1500, `expected the 1s manifest timeout to bound wall time to <1500ms, got ${elapsed}ms`);
});
test('tool_result: systemMessage and additionalContext reach the model and the UI', async () => {
  const pi = makeFakePi(); const ctx = makeFakeCtx(); await start(pi, ctx);
  const r = await pi.fire('tool_result', { type: 'tool_result', toolCallId: 't5', toolName: 'bash', input: { command: 'ls' }, content: [{ type: 'text', text: 'out' }], isError: false }, ctx);
  const text = r.content.map((c) => c.text).join('\n');
  assert.match(text, /^out/); assert.match(text, /careful/); assert.match(text, /ctx-note/);
  assert.ok(ctx.notices.some((n) => /careful/.test(n.m)));
});
test('tool_result: non-blocking hook failure (exit 1) still surfaces to the model and the UI', async () => {
  const pi = makeFakePi(); const ctx = makeFakeCtx(); await start(pi, ctx);
  const r = await pi.fire('tool_result', { type: 'tool_result', toolCallId: 't7', toolName: 'write', input: { path: 'a.md', content: 'x' }, content: [{ type: 'text', text: 'ok' }], isError: false }, ctx);
  const text = r.content.map((c) => c.text).join('\n');
  assert.match(text, /fail\.sh/);
  assert.ok(ctx.notices.some((n) => /fail\.sh/.test(n.m) && n.t === 'warning'));
});
test('stop guard: block once, then allow; input resets', async () => {
  const pi = makeFakePi(); const ctx = makeFakeCtx(); await start(pi, ctx);
  const ev = () => ({ type: 'agent_before_settle', outcome: 'completed', entries: [], continue: false, context: {} });
  const r1 = await pi.fire('agent_before_settle', ev(), ctx);
  assert.equal(r1.continue, true); assert.equal(r1.entries[0].type, 'custom_message'); assert.match(r1.entries[0].content, /finish first/);
  const r2 = await pi.fire('agent_before_settle', ev(), ctx);
  assert.equal(r2, undefined);
  await pi.fire('input', { type: 'input', text: 'go', source: 'interactive' }, ctx);
  const r3 = await pi.fire('agent_before_settle', ev(), ctx);
  assert.equal(r3.continue, true);
  const aborted = await pi.fire('agent_before_settle', { ...ev(), outcome: 'aborted' }, ctx);
  assert.equal(aborted, undefined);
});
test('input runs UserPromptSubmit with prompt', async (t) => {
  const rec = recordFile(t);
  const pi = makeFakePi(); const ctx = makeFakeCtx(); await start(pi, ctx);
  await pi.fire('input', { type: 'input', text: 'hello', source: 'interactive' }, ctx);
  assert.equal(JSON.parse(fs.readFileSync(rec, 'utf8').trim()).prompt, 'hello');
});
test('pi-code conflict disables hooks with a warning', async () => {
  const pi = makeFakePi(); pi.registerTool({ name: 'subagent' }); const ctx = makeFakeCtx();
  const b = await start(pi, ctx);
  assert.equal(b.enabled, false); assert.ok(ctx.notices.some((n) => /subagent/.test(n.m)));
  assert.equal(await pi.fire('tool_call', { type: 'tool_call', toolCallId: 't6', toolName: 'bash', input: { command: 'ls' } }, ctx), undefined);
});
test('missing bash disables hooks with a warning', async () => {
  const pi = makeFakePi(); const ctx = makeFakeCtx();
  const b = await start(pi, ctx, { ...opts(), bash: '/nonexistent/bash' });
  assert.equal(b.enabled, false); assert.ok(ctx.notices.some((n) => /bash/.test(n.m)));
});
test('invalid regex matcher in manifest disables the bridge, naming the entry', async () => {
  const pi = makeFakePi(); const ctx = makeFakeCtx();
  const b = await start(pi, ctx, { ...opts(), manifestPath: path.join(fx, 'manifest-invalid-matcher.json') });
  assert.equal(b.enabled, false);
  assert.ok(ctx.notices.some((n) => /record\.sh/.test(n.m) && /matcher/.test(n.m)));
});
test('tool_call: unserializable payload (BigInt) does not throw and fails closed', async () => {
  const pi = makeFakePi(); const ctx = makeFakeCtx(); await start(pi, ctx);
  const r = await pi.fire('tool_call', { type: 'tool_call', toolCallId: 't8', toolName: 'bash', input: { command: 'ls', n: 1n } }, ctx);
  assert.equal(r.block, true);
  assert.match(r.reason, /cannot serialize/);
});
test('agent_id/agent_type are recorded at nonzero pi depth (subagent tool calls)', async (t) => {
  const rec = recordFile(t);
  withEnv(t, 'ACHILLES_PI_DEPTH', '1');
  withEnv(t, 'ACHILLES_PI_AGENT_TYPE', 'workflow-reviewer-phase1');
  const pi = makeFakePi(); const ctx = makeFakeCtx(); await start(pi, ctx);
  await pi.fire('tool_call', { type: 'tool_call', toolCallId: 't9', toolName: 'edit', input: { path: 'a.md', edits: [{ oldText: 'o', newText: 'n' }] } }, ctx);
  const p = JSON.parse(fs.readFileSync(rec, 'utf8').trim());
  assert.equal(p.agent_id, 'sid-1');
  assert.equal(p.agent_type, 'workflow-reviewer-phase1');
});
test('agent_id/agent_type are absent at pi depth 0', async (t) => {
  const rec = recordFile(t);
  const pi = makeFakePi(); const ctx = makeFakeCtx(); await start(pi, ctx);
  await pi.fire('tool_call', { type: 'tool_call', toolCallId: 't10', toolName: 'edit', input: { path: 'a.md', edits: [{ oldText: 'o', newText: 'n' }] } }, ctx);
  const p = JSON.parse(fs.readFileSync(rec, 'utf8').trim());
  assert.equal('agent_id' in p, false);
  assert.equal('agent_type' in p, false);
});
test('runEvent SubagentStop reaches the record hook', async (t) => {
  const rec = recordFile(t);
  const pi = makeFakePi(); const ctx = makeFakeCtx(); const b = await start(pi, ctx);
  await b.runEvent('SubagentStop', { session_id: 'c1', transcript_path: '/x.jsonl', cwd: '/p', stop_hook_active: false }, undefined, ctx);
  assert.equal(JSON.parse(fs.readFileSync(rec, 'utf8').trim()).hook_event_name, 'SubagentStop');
});

// --- shadow transcript end to end: real hooks, run by the bridge, against the shadow it wrote -------
const REPO_HOOKS = path.resolve(import.meta.dirname, '..', '..', 'hooks');
function realHooks(t) {
  const dir = tmp();
  const manifestPath = path.join(dir, 'manifest.json');
  fs.writeFileSync(manifestPath, JSON.stringify([
    { file: 'journey-mapping-skill-preread-gate.sh', event: 'PreToolUse', matcher: 'Write|Edit', timeout: 15 },
    { file: 'compliance-sweep-exit-gate.sh', event: 'Stop', matcher: null, timeout: 15 },
  ]));
  withEnv(t, 'ACHILLES_PROTOCOL', '1');
  const stateDir = path.join(dir, 'state');
  withEnv(t, 'ACHILLES_SESSION_STATE_DIR', stateDir);
  return { ...opts(), manifestPath, hooksDir: REPO_HOOKS, stateDir, cwd: dir };
}
const writeMap = (o, id) => ({ type: 'tool_call', toolCallId: id, toolName: 'write', input: { path: path.join(o.cwd, 'tests', 'e2e', 'docs', 'journey-map.md'), content: 'x' } });
test('shadow + real preread gate: journey-map write denied until Skill{journey-mapping} and its SKILL.md read', async (t) => {
  const o = realHooks(t);
  const pi = makeFakePi(); const ctx = makeFakeCtx({ cwd: o.cwd }); await start(pi, ctx, o);
  await pi.fire('input', { type: 'input', text: 'map the app', source: 'interactive' }, ctx);
  const denied = await pi.fire('tool_call', writeMap(o, 'w1'), ctx);
  assert.equal(denied?.block, true); assert.match(denied.reason, /requires the journey-mapping skill/);
  await pi.fire('tool_call', { type: 'tool_call', toolCallId: 's1', toolName: 'Skill', input: { skill: 'journey-mapping' } }, ctx);
  await pi.fire('tool_call', { type: 'tool_call', toolCallId: 'r1', toolName: 'read', input: { path: path.join(REPO_HOOKS, '..', 'skills', 'journey-mapping', 'SKILL.md') } }, ctx);
  assert.equal(await pi.fire('tool_call', writeMap(o, 'w2'), ctx), undefined);
});
test('shadow + real compliance sweep: Stop blocks after a spec write until assistant text announces the sweep', async (t) => {
  const o = realHooks(t);
  const pi = makeFakePi(); const ctx = makeFakeCtx({ cwd: o.cwd }); await start(pi, ctx, o);
  const settle = () => pi.fire('agent_before_settle', { type: 'agent_before_settle', outcome: 'completed', entries: [], continue: false, context: {} }, ctx);
  await pi.fire('tool_call', { type: 'tool_call', toolCallId: 'w1', toolName: 'write', input: { path: path.join(o.cwd, 'a.spec.ts'), content: 'x' } }, ctx);
  const blocked = await settle();
  assert.equal(blocked?.continue, true); assert.match(blocked.entries[0].content, /compliance sweep never ran/);
  await pi.fire('input', { type: 'input', text: 'go on', source: 'interactive' }, ctx); // resets the stop guard
  await pi.fire('message_end', { type: 'message_end', message: { role: 'assistant', content: [{ type: 'text', text: '**API Compliance Review**\n\nReviewed a.spec.ts — no issues found.' }] } }, ctx);
  assert.equal(await settle(), undefined);
});
test('message_end records assistant text only; user and tool-only messages add nothing', async () => {
  const o = opts();
  const pi = makeFakePi(); const ctx = makeFakeCtx(); await start(pi, ctx, o);
  await pi.fire('message_end', { type: 'message_end', message: { role: 'user', content: [{ type: 'text', text: 'u' }] } }, ctx);
  await pi.fire('message_end', { type: 'message_end', message: { role: 'assistant', content: [{ type: 'toolCall', name: 'read', arguments: {} }] } }, ctx);
  await pi.fire('message_end', { type: 'message_end', message: { role: 'assistant', content: [{ type: 'text', text: 'done' }] } }, ctx);
  const lines = fs.readFileSync(path.join(o.stateDir, 'pi-transcripts', 'sid-1.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  assert.deepEqual(lines, [{ type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'done' }] } }]);
});

// --- I4: the orchestrator may not read subagent-only skills --------------------------------------
const readCall = (p, id = 'rd') => ({ type: 'tool_call', toolCallId: id, toolName: 'read', input: { path: p } });
const bashCall = (command, id = 'bs') => ({ type: 'tool_call', toolCallId: id, toolName: 'bash', input: { command } });
const SUB = path.join(fx, 'skills', 'sub-flag');
test('depth 0: read of a subagent-only SKILL.md (absolute, relative, or any file under it) is blocked with the delegation line', async () => {
  const pi = makeFakePi(); const ctx = makeFakeCtx({ cwd: path.join(fx, 'skills') }); await start(pi, ctx);
  for (const p of [path.join(SUB, 'SKILL.md'), 'sub-flag/SKILL.md', path.join(SUB, 'references', 'anything.md'), path.join(fx, 'skills', 'sub-marker', 'SKILL.md')]) {
    const r = await pi.fire('tool_call', readCall(p), ctx);
    assert.equal(r?.block, true, p);
    assert.match(r.reason, /subagent-only skill.*Delegate it: Agent \{ skill: "sub-(flag|marker)"/, p);
    assert.equal(r.reason.split('\n').length, 1, 'one line');
  }
});
test('depth 0: a read through pi path prefixes (@relative, @absolute, file://) is blocked too', async () => {
  const pi = makeFakePi(); const ctx = makeFakeCtx({ cwd: path.join(fx, 'skills') }); await start(pi, ctx);
  for (const p of ['@sub-flag/SKILL.md', `@${path.join(SUB, 'SKILL.md')}`, `file://${path.join(SUB, 'SKILL.md')}`, `file://${path.join(SUB, 'references', 'x.md')}`]) {
    const r = await pi.fire('tool_call', readCall(p), ctx);
    assert.equal(r?.block, true, p);
    assert.match(r.reason, /Delegate it: Agent \{ skill: "sub-flag"/, p);
  }
});
test('depth 0: an orchestrator skill read is allowed', async () => {
  const pi = makeFakePi(); const ctx = makeFakeCtx(); await start(pi, ctx);
  assert.equal(await pi.fire('tool_call', readCall(path.join(fx, 'skills', 'orch-skill', 'SKILL.md')), ctx), undefined);
});
test('depth 1: a subagent may read a subagent-only skill', async (t) => {
  withEnv(t, 'ACHILLES_PI_DEPTH', '1');
  const pi = makeFakePi(); const ctx = makeFakeCtx(); await start(pi, ctx);
  assert.equal(await pi.fire('tool_call', readCall(path.join(SUB, 'SKILL.md')), ctx), undefined);
});
test('depth 0: bash cat/sed/head of a subagent-only skill file is blocked before hooks run; other bash is not', async () => {
  const pi = makeFakePi(); const ctx = makeFakeCtx(); await start(pi, ctx);
  for (const cmd of [`cat ${SUB}/SKILL.md`, `sed -n '1,40p' "${SUB}/SKILL.md"`, `head -50 ${SUB}/SKILL.md | less`]) {
    const r = await pi.fire('tool_call', bashCall(cmd), ctx);
    assert.match(r.reason, /Delegate it: Agent \{ skill: "sub-flag"/, cmd);
    assert.doesNotMatch(r.reason, /nope/, 'guard runs before the hooks');
  }
  // pi-style prefixes (`@`, `file://`) are resolved like a read path.
  for (const cmd of [`cat @${SUB}/SKILL.md`, `head "file://${SUB}/SKILL.md"`]) {
    const r = await pi.fire('tool_call', bashCall(cmd), ctx);
    assert.match(r.reason, /Delegate it: Agent \{ skill: "sub-flag"/, cmd);
  }
  // ls is not a reader: the guard stays out of it and the fixture Bash hook decides (it denies with "nope").
  const ls = await pi.fire('tool_call', bashCall(`ls ${SUB}`), ctx);
  assert.match(ls.reason, /nope/); assert.doesNotMatch(ls.reason, /subagent-only/);
});
test('depth 0: every skill root is checked, not just the first match', async () => {
  const other = tmp();
  fs.mkdirSync(path.join(other, 'sub-flag'), { recursive: true });
  fs.copyFileSync(path.join(SUB, 'SKILL.md'), path.join(other, 'sub-flag', 'SKILL.md'));
  const pi = makeFakePi(); const ctx = makeFakeCtx(); await start(pi, ctx, { ...opts(), skillRoots: [path.join(fx, 'skills'), other] });
  const r = await pi.fire('tool_call', readCall(path.join(other, 'sub-flag', 'SKILL.md')), ctx);
  assert.equal(r?.block, true);
});

// --- I5: a child session runs SubagentStop at settle, not Stop -----------------------------------
const settleEv = () => ({ type: 'agent_before_settle', outcome: 'completed', entries: [], continue: false, context: {} });
test('depth 1: settle runs SubagentStop (not Stop) with blocks honoured and the stop guard', async (t) => {
  const rec = recordFile(t);
  withEnv(t, 'ACHILLES_PI_DEPTH', '1');
  withEnv(t, 'ACHILLES_PI_AGENT_TYPE', 'workflow-reviewer-phase1');
  const o = opts();
  const pi = makeFakePi(); const ctx = makeFakeCtx(); await start(pi, ctx, o);
  await pi.fire('message_end', { type: 'message_end', message: { role: 'assistant', content: [{ type: 'text', text: 'verdict: approve' }] } }, ctx);
  const r1 = await pi.fire('agent_before_settle', settleEv(), ctx);
  assert.equal(r1.continue, true); assert.equal(r1.entries[0].type, 'custom_message');
  assert.match(r1.entries[0].content, /subagent: finish the review first/);
  assert.doesNotMatch(r1.entries[0].content, /finish first$/m, 'Stop hooks did not run');
  const p = JSON.parse(fs.readFileSync(rec, 'utf8').trim().split('\n')[0]);
  assert.equal(p.hook_event_name, 'SubagentStop');
  assert.equal(p.stop_hook_active, false);
  assert.equal(p.last_assistant_message, 'verdict: approve');
  assert.equal(p.agent_id, 'sid-1'); assert.equal(p.agent_type, 'workflow-reviewer-phase1');
  assert.equal(p.transcript_path, path.join(o.stateDir, 'pi-transcripts', 'sid-1.jsonl'));
  // Second settle in the same chain: stop_hook_active is true, the hook allows.
  assert.equal(await pi.fire('agent_before_settle', settleEv(), ctx), undefined);
  assert.equal(JSON.parse(fs.readFileSync(rec, 'utf8').trim().split('\n')[1]).stop_hook_active, true);
});
test('depth 0: settle runs Stop, never SubagentStop', async (t) => {
  const rec = recordFile(t);
  const pi = makeFakePi(); const ctx = makeFakeCtx(); await start(pi, ctx);
  const r = await pi.fire('agent_before_settle', settleEv(), ctx);
  assert.match(r.entries[0].content, /finish first/);
  assert.equal(fs.existsSync(rec), false, 'no SubagentStop record');
});

// --- I6: PostToolUse sees the Agent tool's full result, not the capped content -------------------
test('tool_result for Agent: tool_response is built from details.text (20 KB), not the capped content', async (t) => {
  const rec = recordFile(t);
  const dir = tmp();
  const manifestPath = path.join(dir, 'm.json');
  fs.writeFileSync(manifestPath, JSON.stringify([{ file: 'record.sh', event: 'PostToolUse', matcher: 'Agent', timeout: 5 }]));
  const pi = makeFakePi(); const ctx = makeFakeCtx(); await start(pi, ctx, { ...opts(), manifestPath });
  const full = 'r'.repeat(20 * 1024) + 'END';
  const capped = full.slice(0, 16 * 1024) + '\n\n[achilles: output truncated for context; full text kept in tool details]';
  await pi.fire('tool_result', { type: 'tool_result', toolCallId: 'ag1', toolName: 'Agent', input: { description: 'd', prompt: 'p' }, content: [{ type: 'text', text: capped }], details: { text: full }, isError: false }, ctx);
  const p = JSON.parse(fs.readFileSync(rec, 'utf8').trim());
  assert.equal(p.tool_name, 'Agent');
  assert.equal(p.tool_response.output, full); assert.equal(p.tool_response.content, full);
  // Without details.text it falls back to the content.
  fs.rmSync(rec);
  await pi.fire('tool_result', { type: 'tool_result', toolCallId: 'ag2', toolName: 'Agent', input: {}, content: [{ type: 'text', text: 'short' }], details: undefined, isError: false }, ctx);
  assert.equal(JSON.parse(fs.readFileSync(rec, 'utf8').trim()).tool_response.output, 'short');
});

// --- folded minors --------------------------------------------------------------------------
test('parseDecision: continue:false is not a block (only deny / decision:block / exit 2 are)', () => {
  const d = parseDecision({ file: 'h.sh', exitCode: 0, stdout: '{"continue":false,"stopReason":"halt"}', stderr: '', timedOut: false, ms: 1 }, 'PreToolUse');
  assert.equal(d.block, false);
});
test('UserPromptSubmit: a leading /skill:<name> becomes /<name>; other prompts are untouched', async (t) => {
  assert.equal(claudePrompt('/skill:onboarding go'), '/onboarding go');
  assert.equal(claudePrompt('/skill:onboarding'), '/onboarding');
  assert.equal(claudePrompt('run /skill:onboarding later'), 'run /skill:onboarding later');
  assert.equal(claudePrompt('/skill:Bad_Name x'), '/skill:Bad_Name x');
  const rec = recordFile(t);
  const pi = makeFakePi(); const ctx = makeFakeCtx(); await start(pi, ctx);
  await pi.fire('input', { type: 'input', text: '/skill:journey-mapping map the app', source: 'interactive' }, ctx);
  assert.equal(JSON.parse(fs.readFileSync(rec, 'utf8').trim()).prompt, '/journey-mapping map the app');
});
test('runHook decodes stdout as UTF-8 across chunk boundaries', async () => {
  const r = await runHook({ bash: 'bash', hookPath: path.join(fx, 'hooks', 'utf8.sh'), payload: {}, timeoutMs: 10000, cwd: os.tmpdir(), env: process.env });
  assert.equal(r.exitCode, 0);
  assert.equal(r.stdout, '€'.repeat(150000));
});
test('NaN ACHILLES_PI_DEPTH is depth 0: no agent_id', async (t) => {
  const rec = recordFile(t);
  withEnv(t, 'ACHILLES_PI_DEPTH', 'banana');
  const pi = makeFakePi(); const ctx = makeFakeCtx(); await start(pi, ctx);
  await pi.fire('tool_call', { type: 'tool_call', toolCallId: 'n1', toolName: 'edit', input: { path: 'a.md', edits: [{ oldText: 'o', newText: 'n' }] } }, ctx);
  assert.equal('agent_id' in JSON.parse(fs.readFileSync(rec, 'utf8').trim()), false);
});

// ---- multi-part edit translation cache (I3) ----
const REPO = path.resolve(import.meta.dirname, '..', '..');
function manifestOf(entries) { const p = path.join(tmp(), 'm.json'); fs.writeFileSync(p, JSON.stringify(entries)); return p; }
const multi = (p) => ({ path: p, edits: [{ oldText: '"o1"', newText: '"n1"' }, { oldText: '"o2"', newText: '"n2"' }] });

test('translation cache: a blocked multi-part edit leaves it empty; an allowed one is consumed at tool_result', async () => {
  const dir = tmp(); fs.writeFileSync(path.join(dir, 'l.json'), '{"a":"o1","b":"o2"}');
  const pi = makeFakePi(); const ctx = makeFakeCtx({ cwd: dir });
  const denying = await start(pi, ctx, { ...opts(), manifestPath: manifestOf([{ file: 'deny.sh', event: 'PreToolUse', matcher: 'Edit', timeout: 5 }]) });
  const r = await pi.fire('tool_call', { type: 'tool_call', toolCallId: 'b1', toolName: 'edit', input: multi('l.json') }, ctx);
  assert.equal(r.block, true);
  assert.equal(denying.pendingTranslations, 0);

  const pi2 = makeFakePi(); const b = await start(pi2, ctx);
  assert.equal(await pi2.fire('tool_call', { type: 'tool_call', toolCallId: 'a1', toolName: 'edit', input: multi('l.json') }, ctx), undefined);
  assert.equal(b.pendingTranslations, 1);
  // A single exact edit does not depend on the pre-edit file and is not cached.
  await pi2.fire('tool_call', { type: 'tool_call', toolCallId: 'a2', toolName: 'edit', input: { path: 'l.json', edits: [{ oldText: '"o1"', newText: '"x"' }] } }, ctx);
  assert.equal(b.pendingTranslations, 1);
  fs.writeFileSync(path.join(dir, 'l.json'), '{"a":"n1","b":"n2"}');
  await pi2.fire('tool_result', { type: 'tool_result', toolCallId: 'a1', toolName: 'edit', input: multi('l.json'), content: [], isError: false }, ctx);
  assert.equal(b.pendingTranslations, 0);
  // A call that never reaches tool_result is dropped at the next session_start.
  fs.writeFileSync(path.join(dir, 'l.json'), '{"a":"o1","b":"o2"}');
  await pi2.fire('tool_call', { type: 'tool_call', toolCallId: 'a3', toolName: 'edit', input: multi('l.json') }, ctx);
  assert.equal(b.pendingTranslations, 1);
  await pi2.fire('session_start', { type: 'session_start', reason: 'new' }, ctx);
  assert.equal(b.pendingTranslations, 0);
});
test('translation cache: agent_end drops entries whose tool_result never came', async () => {
  const dir = tmp(); fs.writeFileSync(path.join(dir, 'l.json'), '{"a":"o1","b":"o2"}');
  const pi = makeFakePi(); const ctx = makeFakeCtx({ cwd: dir }); const b = await start(pi, ctx);
  await pi.fire('tool_call', { type: 'tool_call', toolCallId: 'e1', toolName: 'edit', input: multi('l.json') }, ctx);
  assert.equal(b.pendingTranslations, 1);
  await pi.fire('agent_end', { type: 'agent_end', messages: [] }, ctx);
  assert.equal(b.pendingTranslations, 0);
});
test('translation cache: skipped while the bridge is disabled', async () => {
  const dir = tmp(); fs.writeFileSync(path.join(dir, 'l.json'), '{"a":"o1","b":"o2"}');
  const pi = makeFakePi(); const ctx = makeFakeCtx({ cwd: dir });
  const b = await start(pi, ctx, { ...opts(), hooksDir: tmp() });
  assert.equal(b.enabled, false);
  assert.equal(await pi.fire('tool_call', { type: 'tool_call', toolCallId: 'd1', toolName: 'edit', input: multi('l.json') }, ctx), undefined);
  assert.equal(b.pendingTranslations, 0);
});
test('translation cache: a stale entry (another edit changed the file first) is recomputed at tool_result', async (t) => {
  const rec = recordFile(t);
  const dir = tmp(); fs.writeFileSync(path.join(dir, 'l.json'), '{"a":"o1","b":"o2"}');
  const pi = makeFakePi(); const ctx = makeFakeCtx({ cwd: dir }); const b = await start(pi, ctx);
  await pi.fire('tool_call', { type: 'tool_call', toolCallId: 's1', toolName: 'edit', input: multi('l.json') }, ctx);
  fs.writeFileSync(path.join(dir, 'l.json'), '{"a":"zz","b":"zz"}'); // what landed is not what s1 was translated to
  await pi.fire('tool_result', { type: 'tool_result', toolCallId: 's1', toolName: 'edit', input: multi('l.json'), content: [], isError: true }, ctx);
  assert.equal(b.pendingTranslations, 0);
  const [pre, post] = fs.readFileSync(rec, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  assert.equal(pre.tool_input.new_string, '{"a":"n1","b":"n2"}');
  assert.equal(post.tool_input.old_string, '"o1"\n"o2"', 'recomputed against the current file');
});
test('client-term-guard (real hook): a two-part edit that adds no term is allowed although the file already holds one', async () => {
  const proj = tmp();
  fs.writeFileSync(path.join(proj, 'package.json'), JSON.stringify({ name: '@civitas-cerebrum/achilles' }));
  fs.mkdirSync(path.join(proj, '.achilles'));
  fs.writeFileSync(path.join(proj, '.achilles', 'client-terms.local.txt'), 'acmecorp\n');
  fs.mkdirSync(path.join(proj, 'docs'));
  const file = path.join(proj, 'docs', 'x.md');
  fs.writeFileSync(file, 'intro\nlegacy note: acmecorp\n\nsection one\nk1 value\n\nsection two\nk2 value\n');
  const pi = makeFakePi(); const ctx = makeFakeCtx({ cwd: proj });
  await start(pi, ctx, { ...opts(), hooksDir: path.join(REPO, 'hooks'), manifestPath: manifestOf([{ file: 'client-term-guard.sh', event: 'PreToolUse', matcher: 'Write|Edit', timeout: 10 }]) });
  const clean = { path: file, edits: [{ oldText: 'k1 value', newText: 'K1 value' }, { oldText: 'k2 value', newText: 'K2 value' }] };
  assert.equal(await pi.fire('tool_call', { type: 'tool_call', toolCallId: 'c1', toolName: 'edit', input: clean }, ctx), undefined);
  // Control: adding the term is still denied.
  const dirty = { path: file, edits: [{ oldText: 'k1 value', newText: 'acmecorp value' }, { oldText: 'k2 value', newText: 'K2 value' }] };
  const r = await pi.fire('tool_call', { type: 'tool_call', toolCallId: 'c2', toolName: 'edit', input: dirty }, ctx);
  assert.equal(r?.block, true); assert.match(r.reason, /acmecorp/);
});
test('onboarding-ledger-write-gate (real hook): a two-part ledger edit is synthesised and reaches schema validation', async (t) => {
  withEnv(t, 'ACHILLES_PROTOCOL', '1');
  withEnv(t, 'ACHILLES_SESSION_STATE_DIR', tmp());
  const proj = tmp(); const docs = path.join(proj, 'tests', 'e2e', 'docs'); fs.mkdirSync(docs, { recursive: true });
  const ledger = path.join(docs, 'onboarding-status.json');
  fs.copyFileSync(path.join(REPO, 'schemas', 'onboarding-status.fixtures', 'valid-mid-phase5.json'), ledger);
  const pi = makeFakePi(); const ctx = makeFakeCtx({ cwd: proj });
  await start(pi, ctx, { ...opts(), hooksDir: path.join(REPO, 'hooks'), manifestPath: manifestOf([{ file: 'onboarding-ledger-write-gate.sh', event: 'PreToolUse', matcher: 'Write|Edit', timeout: 30 }]) });
  // Two parts, far apart; the second makes runMode an invalid enum value so the schema must reject it.
  const input = { path: 'tests/e2e/docs/onboarding-status.json', edits: [
    { oldText: '"runMode": "depth"', newText: '"runMode": "yolo"' },
    { oldText: '"approvedDeviations": []', newText: '"approvedDeviations": [ ]' },
  ] };
  const r = await pi.fire('tool_call', { type: 'tool_call', toolCallId: 'g1', toolName: 'edit', input }, ctx);
  assert.equal(r?.block, true);
  assert.doesNotMatch(r.reason, /REPLACE_FAIL|could not be synthesised/);
  assert.match(r.reason, /runMode/);
  // The same ledger with CRLF endings and a multi-line part: pi matches it LF-normalised, so the bridge
  // must hand the gate an old_string that exists in the raw CRLF bytes.
  // (No final newline: the gate's $(...) strips only the trailing LF, and a stray CR fails its JSON parse.)
  fs.writeFileSync(ledger, fs.readFileSync(ledger, 'utf8').trimEnd().replace(/\n/g, '\r\n'));
  const crlf = { path: 'tests/e2e/docs/onboarding-status.json', edits: [
    { oldText: '"schemaVersion": 1,\n  "pipelineVersion": "0.4.0",\n  "runMode": "depth",', newText: '"schemaVersion": 1,\n  "pipelineVersion": "0.4.0",\n  "runMode": "yolo",' },
    { oldText: '"approvedDeviations": []', newText: '"approvedDeviations": [ ]' },
  ] };
  const r2 = await pi.fire('tool_call', { type: 'tool_call', toolCallId: 'g2', toolName: 'edit', input: crlf }, ctx);
  assert.equal(r2?.block, true);
  assert.doesNotMatch(r2.reason, /REPLACE_FAIL|could not be synthesised/);
  assert.match(r2.reason, /runMode/);
  // Hooks read old_string through $(...), which strips trailing newlines. A ledger whose phases end in
  // "status" puts `"status": "pending"` (last element) right below `"status": "pending",` lines; the
  // span must stay unique after stripping, or the gate fails with REPLACE_FAIL: matched 2 times.
  const fresh = JSON.parse(fs.readFileSync(path.join(REPO, 'schemas', 'onboarding-status.fixtures', 'valid-fresh-run.json'), 'utf8'));
  fresh.phases = fresh.phases.map(({ status, ...rest }) => ({ ...rest, status }));
  fs.writeFileSync(ledger, JSON.stringify(fresh, null, 2) + '\n');
  const tail = { path: 'tests/e2e/docs/onboarding-status.json', edits: [
    { oldText: '"pending"\n    }\n  ]', newText: '"skipped"\n    }\n  ]' },
    { oldText: '"schemaVersion": 1', newText: '"schemaVersion": 1' },
  ] };
  const r3 = await pi.fire('tool_call', { type: 'tool_call', toolCallId: 'g3', toolName: 'edit', input: tail }, ctx);
  assert.doesNotMatch(r3?.reason ?? '', /REPLACE_FAIL|could not be synthesised/);
});

// pi resolves `@x` and `~/x` before writing; path-matched gates must see the resolved path.
for (const [label, mkPath] of [['@-prefixed', () => '@tests/e2e/docs/onboarding-status.json'], ['~-prefixed', (home) => '~/proj/tests/e2e/docs/onboarding-status.json']]) {
  test(`onboarding-ledger-write-gate (real hook): a ${label} Write or Edit of a broken ledger is denied`, async (t) => {
    withEnv(t, 'ACHILLES_PROTOCOL', '1');
    withEnv(t, 'ACHILLES_SESSION_STATE_DIR', tmp());
    const home = tmp(); withEnv(t, 'HOME', home);
    const proj = path.join(home, 'proj'); fs.mkdirSync(path.join(proj, 'tests', 'e2e', 'docs'), { recursive: true });
    const pi = makeFakePi(); const ctx = makeFakeCtx({ cwd: proj });
    await start(pi, ctx, { ...opts(), hooksDir: path.join(REPO, 'hooks'), manifestPath: manifestOf([{ file: 'onboarding-ledger-write-gate.sh', event: 'PreToolUse', matcher: 'Write|Edit', timeout: 30 }]) });
    const r = await pi.fire('tool_call', { type: 'tool_call', toolCallId: 'w1', toolName: 'write', input: { path: mkPath(home), content: 'not json' } }, ctx);
    assert.equal(r?.block, true, `${label} path slipped the gate`);
    assert.match(r.reason, /onboarding-status\.json/);
    // An Edit is where a literal prefix really bites: the gate synthesises from the existing file, and
    // `[ -f "~/…" ]` / `[ -f "@…" ]` is false, so an unresolved path is silently allowed.
    fs.copyFileSync(path.join(REPO, 'schemas', 'onboarding-status.fixtures', 'valid-fresh-run.json'), path.join(proj, 'tests', 'e2e', 'docs', 'onboarding-status.json'));
    const e = await pi.fire('tool_call', { type: 'tool_call', toolCallId: 'w2', toolName: 'edit', input: { path: mkPath(home), edits: [{ oldText: '"schemaVersion": 1', newText: '"schemaVersion": 1 not json' }] } }, ctx);
    assert.equal(e?.block, true, `${label} edit slipped the gate`);
  });
}

// ---- child shadow inherits the parent's history (round 4) ----
/** Sets env vars for the rest of the test (undefined unsets), restoring them at t.after. */
function setEnv(t, vars) {
  const saved = Object.fromEntries(Object.keys(vars).map((k) => [k, process.env[k]]));
  for (const [k, v] of Object.entries(vars)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
  t.after(() => { for (const [k, v] of Object.entries(saved)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; } });
}
const shadowLines = (f) => fs.readFileSync(f, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
const toolUses = (f) => shadowLines(f).flatMap((e) => (Array.isArray(e.message?.content) ? e.message.content : [])).filter((c) => c.type === 'tool_use');
/** A parent (depth 0) and child (depth 1) bridge over one state dir, sharing a manifest and hooks dir. */
async function family(t, { hooksDir = path.join(fx, 'hooks'), manifest = [{ file: 'record.sh', event: 'SubagentStop', matcher: null, timeout: 5 }], cwd = tmp() } = {}) {
  const stateDir = tmp();
  const o = { ...opts(), stateDir, hooksDir, manifestPath: manifestOf(manifest) };
  setEnv(t, { ACHILLES_PI_DEPTH: undefined, ACHILLES_PI_PARENT_SHADOW: undefined, ACHILLES_PI_AGENT_TYPE: undefined });
  const parentPi = makeFakePi(); const parentCtx = makeFakeCtx({ cwd, sessionId: 'parent-1' });
  await start(parentPi, parentCtx, o);
  const parentShadow = path.join(stateDir, 'pi-transcripts', 'parent-1.jsonl');
  const spawnChild = async (agentType) => {
    process.env.ACHILLES_PI_DEPTH = '1';
    process.env.ACHILLES_PI_PARENT_SHADOW = parentShadow;
    if (agentType) process.env.ACHILLES_PI_AGENT_TYPE = agentType;
    const pi = makeFakePi(); const ctx = makeFakeCtx({ cwd, sessionId: 'child-1' });
    const bridge = await start(pi, ctx, o);
    return { pi, ctx, bridge, shadow: path.join(stateDir, 'pi-transcripts', 'child-1.jsonl') };
  };
  return { parentPi, parentCtx, parentShadow, spawnChild, cwd };
}
const agentCall = (description, id = 'ag') => ({ type: 'tool_call', toolCallId: id, toolName: 'Agent', input: { description, prompt: 'brief' } });

test('child shadow starts with the parent shadow, including the parent Agent tool_use; the child appends after it', async (t) => {
  const f = await family(t);
  await f.parentPi.fire('tool_call', readCall('/x/notes.md', 'p1'), f.parentCtx);
  await f.parentPi.fire('tool_call', agentCall('scout: look around'), f.parentCtx);
  const parentBytes = fs.readFileSync(f.parentShadow, 'utf8');
  const c = await f.spawnChild('scout');
  assert.equal(fs.readFileSync(c.shadow, 'utf8'), parentBytes, 'seeded as an exact copy');
  assert.equal(fs.statSync(c.shadow).mode & 0o777, 0o600);
  await c.pi.fire('tool_call', readCall('/x/child.md', 'c1'), c.ctx);
  const names = toolUses(c.shadow).map((u) => `${u.name}:${u.input.file_path ?? u.input.description}`);
  assert.deepEqual(names, ['Read:/x/notes.md', 'Agent:scout: look around', 'Read:/x/child.md']);
  assert.equal(fs.readFileSync(f.parentShadow, 'utf8'), parentBytes, 'the parent shadow is untouched');
  // A second session_start in the child does not re-seed.
  await c.pi.fire('session_start', { type: 'session_start', reason: 'reload' }, c.ctx);
  assert.equal(toolUses(c.shadow).length, 3);
});
test('SubagentStop carries agent_transcript_path (the child shadow) and transcript_path, which holds the parent history', async (t) => {
  const rec = recordFile(t);
  const f = await family(t);
  await f.parentPi.fire('tool_call', agentCall('workflow-reviewer-phase1: review'), f.parentCtx);
  const c = await f.spawnChild('workflow-reviewer-phase1');
  await c.pi.fire('message_end', { type: 'message_end', message: { role: 'assistant', content: [{ type: 'text', text: 'done' }] } }, c.ctx);
  await c.pi.fire('agent_before_settle', settleEv(), c.ctx);
  const p = JSON.parse(fs.readFileSync(rec, 'utf8').trim().split('\n')[0]);
  assert.equal(p.hook_event_name, 'SubagentStop');
  assert.equal(p.agent_transcript_path, c.shadow);
  assert.equal(p.transcript_path, c.shadow);
  assert.equal(p.agent_id, 'child-1'); assert.equal(p.agent_type, 'workflow-reviewer-phase1');
  assert.ok(toolUses(p.transcript_path).some((u) => u.name === 'Agent'), 'parent dispatch visible');
});
test('journey-mapping-skill-preread-gate (real hook): a child spill write is allowed when only the PARENT read the SKILL.md; denied when nobody did', async (t) => {
  setEnv(t, { ACHILLES_PROTOCOL: '1', ACHILLES_SESSION_STATE_DIR: tmp() });
  const manifest = [{ file: 'journey-mapping-skill-preread-gate.sh', event: 'PreToolUse', matcher: 'Write|Edit|Agent', timeout: 15 }];
  const spill = (cwd) => ({ type: 'tool_call', toolCallId: 'w', toolName: 'write', input: { path: path.join(cwd, 'tests/e2e/docs/.subagent-returns/phase4-cycle-1-section-auth.md'), content: '## auth\n' } });
  // Parent read the skill, then dispatched the section subagent.
  const a = await family(t, { hooksDir: path.join(REPO, 'hooks'), manifest });
  await a.parentPi.fire('tool_call', readCall(path.join(REPO, 'skills', 'journey-mapping', 'SKILL.md'), 'p1'), a.parentCtx);
  assert.equal(await a.parentPi.fire('tool_call', agentCall('phase4-cycle-1-section-auth: map auth'), a.parentCtx), undefined);
  const ca = await a.spawnChild('phase4-cycle-1-section-auth');
  assert.equal(await ca.pi.fire('tool_call', spill(a.cwd), ca.ctx), undefined);
  // Nobody read it: the child's spill write is denied.
  const b = await family(t, { hooksDir: path.join(REPO, 'hooks'), manifest });
  const cb = await b.spawnChild('phase4-cycle-1-section-auth');
  const r = await cb.pi.fire('tool_call', spill(b.cwd), cb.ctx);
  assert.equal(r?.block, true);
  assert.match(r.reason, /journey-mapping/);
});
test('failure-diagnosis-evidence-floor-gate (real hook): a child dispatched as fd- is gated on its own evidence reads', async (t) => {
  setEnv(t, { ACHILLES_PROTOCOL: '1', ACHILLES_SESSION_STATE_DIR: tmp() });
  const manifest = [{ file: 'failure-diagnosis-evidence-floor-gate.sh', event: 'PreToolUse', matcher: 'Write|Edit', timeout: 15 }];
  const f = await family(t, { hooksDir: path.join(REPO, 'hooks'), manifest });
  await f.parentPi.fire('tool_call', agentCall('fd-checkout: diagnose the checkout failure'), f.parentCtx);
  const c = await f.spawnChild('fd-checkout');
  const spec = (id) => ({ type: 'tool_call', toolCallId: id, toolName: 'write', input: { path: path.join(f.cwd, 'tests/e2e/checkout.spec.ts'), content: 'test()' } });
  const denied = await c.pi.fire('tool_call', spec('s1'), c.ctx);
  assert.equal(denied?.block, true);
  assert.match(denied.reason, /Evidence-floor violation/);
  await c.pi.fire('tool_call', readCall(path.join(f.cwd, 'test-results/checkout-guest/error-context.md'), 'e1'), c.ctx);
  assert.equal(await c.pi.fire('tool_call', spec('s2'), c.ctx), undefined);
});
