import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { makeFakePi, makeFakeCtx } from './fake-pi.mjs';
import { compileMatcher, parseDecision, resolveHooksDir, runHook, createBridge } from '../extensions/achilles/bridge.ts';

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
test('tool_call: plain text stdout allows; payload is Claude-shaped', async (t) => {
  const rec = recordFile(t);
  const o = opts();
  const pi = makeFakePi(); const ctx = makeFakeCtx({ sessionFile: '/s/file.jsonl' }); await start(pi, ctx, o);
  const r = await pi.fire('tool_call', { type: 'tool_call', toolCallId: 't2', toolName: 'edit', input: { path: 'a.md', edits: [{ oldText: 'o', newText: 'n' }] } }, ctx);
  assert.equal(r, undefined);
  const p = JSON.parse(fs.readFileSync(rec, 'utf8').trim());
  assert.equal(p.hook_event_name, 'PreToolUse'); assert.equal(p.tool_name, 'Edit');
  assert.deepEqual(p.tool_input, { file_path: 'a.md', old_string: 'o', new_string: 'n' });
  assert.equal(p.session_id, 'sid-1'); assert.equal(p.cwd, ctx.cwd); assert.equal(p.tool_use_id, 't2');
  // transcript_path is the Claude-shaped shadow, not pi's own session file.
  assert.equal(p.transcript_path, path.join(o.stateDir, 'pi-transcripts', 'sid-1.jsonl'));
  // The call was recorded before the hook ran, exactly as Claude records it.
  const lines = fs.readFileSync(p.transcript_path, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  assert.deepEqual(lines.at(-1), { type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', id: 't2', name: 'Edit', input: { file_path: 'a.md', old_string: 'o', new_string: 'n' } }] } });
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
