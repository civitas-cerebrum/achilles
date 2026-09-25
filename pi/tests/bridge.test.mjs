import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { makeFakePi, makeFakeCtx } from './fake-pi.mjs';
import { compileMatcher, parseDecision, resolveHooksDir, runHook, createBridge } from '../extensions/achilles/bridge.ts';

const fx = path.join(import.meta.dirname, 'fixtures');
const opts = () => ({ manifestPath: path.join(fx, 'manifest.json'), hooksDir: path.join(fx, 'hooks'), skillRoots: [path.join(fx, 'skills')], home: os.tmpdir() });
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'bridge-'));
async function start(pi, ctx, o = opts()) { const b = createBridge(pi, o); await pi.fire('session_start', { type: 'session_start', reason: 'startup' }, ctx); return b; }

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
});
test('tool_call: deny with steered reason', async () => {
  const pi = makeFakePi(); const ctx = makeFakeCtx(); await start(pi, ctx);
  const r = await pi.fire('tool_call', { type: 'tool_call', toolCallId: 't1', toolName: 'bash', input: { command: 'ls' } }, ctx);
  assert.equal(r.block, true);
  assert.match(r.reason, /\[BLOCKED\] nope/);
  assert.match(r.reason, /Load it: Skill \{ skill: "orch-skill" \}/);
  assert.match(r.reason, new RegExp(path.join(fx, 'skills', 'orch-skill', 'SKILL.md').replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
});
test('tool_call: plain text stdout allows; payload is Claude-shaped', async () => {
  const rec = path.join(tmp(), 'rec'); process.env.HOOK_RECORD_FILE = rec;
  const pi = makeFakePi(); const ctx = makeFakeCtx({ sessionFile: '/s/file.jsonl' }); await start(pi, ctx);
  const r = await pi.fire('tool_call', { type: 'tool_call', toolCallId: 't2', toolName: 'edit', input: { path: 'a.md', edits: [{ oldText: 'o', newText: 'n' }] } }, ctx);
  assert.equal(r, undefined);
  const p = JSON.parse(fs.readFileSync(rec, 'utf8').trim());
  assert.equal(p.hook_event_name, 'PreToolUse'); assert.equal(p.tool_name, 'Edit');
  assert.deepEqual(p.tool_input, { file_path: 'a.md', old_string: 'o', new_string: 'n' });
  assert.equal(p.session_id, 'sid-1'); assert.equal(p.transcript_path, '/s/file.jsonl'); assert.equal(p.cwd, ctx.cwd); assert.equal(p.tool_use_id, 't2');
});
test('tool_call: exit 2 stderr is the reason; timeout blocks', async () => {
  const pi = makeFakePi(); const ctx = makeFakeCtx(); await start(pi, ctx);
  const r = await pi.fire('tool_call', { type: 'tool_call', toolCallId: 't3', toolName: 'mcp__jira__create', input: {} }, ctx);
  assert.equal(r.block, true); assert.match(r.reason, /stderr reason/);
  const t = await pi.fire('tool_call', { type: 'tool_call', toolCallId: 't4', toolName: 'Agent', input: { description: 'd', prompt: 'p' } }, ctx);
  assert.equal(t.block, true); assert.match(t.reason, /timed out/);
});
test('tool_result: systemMessage and additionalContext reach the model and the UI', async () => {
  const pi = makeFakePi(); const ctx = makeFakeCtx(); await start(pi, ctx);
  const r = await pi.fire('tool_result', { type: 'tool_result', toolCallId: 't5', toolName: 'bash', input: { command: 'ls' }, content: [{ type: 'text', text: 'out' }], isError: false }, ctx);
  const text = r.content.map((c) => c.text).join('\n');
  assert.match(text, /^out/); assert.match(text, /careful/); assert.match(text, /ctx-note/);
  assert.ok(ctx.notices.some((n) => /careful/.test(n.m)));
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
test('input runs UserPromptSubmit with prompt', async () => {
  const rec = path.join(tmp(), 'rec'); process.env.HOOK_RECORD_FILE = rec;
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
test('runEvent SubagentStop reaches the record hook', async () => {
  const rec = path.join(tmp(), 'rec'); process.env.HOOK_RECORD_FILE = rec;
  const pi = makeFakePi(); const ctx = makeFakeCtx(); const b = await start(pi, ctx);
  await b.runEvent('SubagentStop', { session_id: 'c1', transcript_path: '/x.jsonl', cwd: '/p', stop_hook_active: false }, undefined, ctx);
  assert.equal(JSON.parse(fs.readFileSync(rec, 'utf8').trim()).hook_event_name, 'SubagentStop');
});
