// pi/tests/agent-tool.test.mjs
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { makeFakePi, makeFakeCtx } from './fake-pi.mjs';
import { registerAgentTool } from '../extensions/achilles/agent-tool.ts';
const fx = path.join(import.meta.dirname, 'fixtures');
const child = path.join(fx, 'fake-pi-child.mjs');
const cleanup = [];
after(() => { for (const p of cleanup) fs.rmSync(p, { recursive: true, force: true }); });
const tmp = () => { const d = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-')); cleanup.push(d); return d; };
/** Run fn with env vars set (undefined = unset), restoring the previous values afterwards. */
async function withEnv(vars, fn) {
  const saved = Object.fromEntries(Object.keys(vars).map((k) => [k, process.env[k]]));
  for (const [k, v] of Object.entries(vars)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
  try { return await fn(); }
  finally { for (const [k, v] of Object.entries(saved)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; } }
}
function setup(over = {}) {
  const calls = [];
  const bridge = { enabled: true, async runEvent(event, payload) { calls.push({ event, payload }); return []; }, steer: (t) => t, disable() {} };
  const pi = makeFakePi();
  registerAgentTool(pi, { bridge, roots: [path.join(fx, 'skills')], stateDir: over.stateDir ?? tmp(), invocation: (args) => ({ command: process.execPath, args: [child, ...args] }), ...over });
  return { tool: pi.tools.find((t) => t.name === 'Agent'), calls };
}
/** Runs the tool with a clean achilles env; keeps the transcript copy (so tests can read the child header) unless keep=false. */
async function run(tool, params, ctxOver = {}, { keep = true } = {}) {
  const r = await withEnv({ ACHILLES_PROTOCOL: undefined, ACHILLES_PI_DEPTH: undefined, ACHILLES_PI_AGENT_TYPE: undefined, ACHILLES_PI_KEEP_TRANSCRIPTS: keep ? '1' : undefined },
    () => tool.execute('a', params, undefined, undefined, makeFakeCtx(ctxOver)));
  if (r.details.transcriptCopy) cleanup.push(r.details.transcriptCopy);
  return r;
}
const header = (r) => JSON.parse(fs.readFileSync(r.details.transcriptCopy, 'utf8').split('\n')[0]);

test('registers Agent with Claude fields', () => {
  const { tool } = setup();
  for (const k of ['description', 'prompt', 'subagent_type', 'skill']) assert.ok(tool.parameters.properties[k], k);
});
test('runs a child, returns its final text, fires SubagentStop with a transcript', async () => {
  const { tool, calls } = setup();
  const r = await run(tool, { description: 'scout: x', prompt: 'do it' });
  assert.equal(r.content[0].text, 'child says hi');
  assert.equal(r.details.childSessionId, 'child-1');
  const stop = calls.find((c) => c.event === 'SubagentStop');
  assert.ok(stop); assert.equal(stop.payload.session_id, 'child-1'); assert.equal(stop.payload.stop_hook_active, false);
  assert.equal(stop.payload.last_assistant_message, 'child says hi');
});
test('the child transcript handed on is the child shadow under the shared state dir', async () => {
  const stateDir = tmp();
  const { tool, calls } = setup({ stateDir });
  const r = await run(tool, { description: 'scout: x', prompt: 'do it' });
  const want = path.join(stateDir, 'pi-transcripts', 'child-1.jsonl');
  assert.equal(r.details.shadowTranscript, want);
  assert.equal(calls.find((c) => c.event === 'SubagentStop').payload.transcript_path, want);
});
test('passes ACHILLES_PROTOCOL=1 only when the parent marker exists; increments depth; passes --skill', async () => {
  const stateDir = tmp(); fs.writeFileSync(path.join(stateDir, 'sid-1.active'), '');
  const { tool } = setup({ stateDir });
  const h = header(await run(tool, { description: 'd', prompt: 'p', skill: 'orch-skill' }));
  assert.equal(h.protocol, '1'); assert.equal(h.depth, '1');
  assert.ok(h.args.includes('--skill')); assert.ok(h.args[h.args.indexOf('--skill') + 1].endsWith('orch-skill'));
  assert.ok(h.args.includes('--session-dir')); assert.ok(h.args.includes('--mode'));
  const { tool: t2 } = setup();
  assert.equal(header(await run(t2, { description: 'd', prompt: 'p' })).protocol, '');
});
test('loads this extension explicitly in the child; passes -a only when the project is trusted', async () => {
  const { tool } = setup();
  const h = header(await run(tool, { description: 'd', prompt: 'p' }, { trusted: true }));
  const ext = h.args[h.args.indexOf('-e') + 1];
  assert.ok(path.isAbsolute(ext) && ext.endsWith(path.join('pi', 'extensions', 'achilles', 'index.ts')), ext);
  assert.ok(fs.existsSync(ext));
  assert.ok(h.args.includes('-a'));
  const tools = h.args[h.args.indexOf('--tools') + 1].split(',');
  assert.ok(tools.includes('Skill'), 'children can load skills'); assert.ok(!tools.includes('Agent'), 'children cannot dispatch');
  assert.ok(!header(await run(tool, { description: 'd', prompt: 'p' }, { trusted: false })).args.includes('-a'));
});
test('ACHILLES_PI_AGENT_TYPE: subagent_type wins, else the description role prefix', async () => {
  const { tool } = setup();
  assert.equal(header(await run(tool, { description: 'scout: x', prompt: 'p', subagent_type: 'general-purpose' })).agentType, 'general-purpose');
  assert.equal(header(await run(tool, { description: 'workflow-reviewer-phase1: review', prompt: 'p' })).agentType, 'workflow-reviewer-phase1');
  assert.equal(header(await run(tool, { description: '  explorer  ', prompt: 'p' })).agentType, 'explorer');
});
test('child failure surfaces stderr', async () => {
  await withEnv({ FAKE_PI_FAIL: '1' }, () =>
    assert.rejects(() => setup().tool.execute('a4', { description: 'd', prompt: 'p' }, undefined, undefined, makeFakeCtx()), /exit 3.*boom from child/s));
});
test('depth cap', async () => {
  await withEnv({ ACHILLES_PI_DEPTH: '2' }, () =>
    assert.rejects(() => setup().tool.execute('a5', { description: 'd', prompt: 'p' }, undefined, undefined, makeFakeCtx()), /nesting/));
});
test('model-facing text is capped at 16 KB, full text in details', async () => {
  const { tool } = setup();
  const r = await withEnv({ FAKE_PI_LONG: '1' }, () => run(tool, { description: 'd', prompt: 'p' }));
  assert.ok(r.content[0].text.length <= 16 * 1024 + 200);
  assert.match(r.content[0].text, /truncated/);
  assert.equal(r.details.text, 'y'.repeat(40 * 1024));
});
test('long prompt goes by file', async () => {
  const { tool } = setup();
  const h = header(await run(tool, { description: 'd', prompt: 'x'.repeat(100 * 1024) }));
  assert.ok(h.args.some((a) => a.startsWith('@')));
});
test('no transcript copy unless ACHILLES_PI_KEEP_TRANSCRIPTS=1', async () => {
  const before = new Set(fs.readdirSync(os.tmpdir()).filter((f) => /^achilles-agent-.*\.jsonl$/.test(f)));
  const { tool } = setup();
  const r = await run(tool, { description: 'd', prompt: 'p' }, {}, { keep: false });
  assert.equal(r.details.transcriptCopy, undefined);
  const created = fs.readdirSync(os.tmpdir()).filter((f) => /^achilles-agent-.*\.jsonl$/.test(f) && !before.has(f));
  assert.deepEqual(created, []);
});
