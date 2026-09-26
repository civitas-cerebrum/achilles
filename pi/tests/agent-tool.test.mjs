// pi/tests/agent-tool.test.mjs
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { makeFakePi, makeFakeCtx } from './fake-pi.mjs';
import { registerAgentTool, saveFullReturn, leanResult, shrinkJson } from '../extensions/achilles/agent-tool.ts';
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
    () => tool.execute('a', params, undefined, undefined, makeFakeCtx({ cwd: tmp(), ...ctxOver })));
  if (r.details.transcriptCopy) cleanup.push(path.dirname(r.details.transcriptCopy));
  return r;
}
const header = (r) => JSON.parse(fs.readFileSync(r.details.transcriptCopy, 'utf8').split('\n')[0]);

test('registers Agent with Claude fields', () => {
  const { tool } = setup();
  for (const k of ['description', 'prompt', 'subagent_type', 'skill']) assert.ok(tool.parameters.properties[k], k);
});
test('runs a child and returns its final text; the parent runs no SubagentStop (the child does, at its settle)', async () => {
  const { tool, calls } = setup();
  const r = await run(tool, { description: 'scout: x', prompt: 'do it' });
  assert.equal(r.content[0].text, 'child says hi');
  assert.equal(r.details.childSessionId, 'child-1');
  assert.equal(calls.length, 0);
});
test('the child transcript handed on is the child shadow under the shared state dir', async () => {
  const stateDir = tmp();
  const { tool } = setup({ stateDir });
  const r = await run(tool, { description: 'scout: x', prompt: 'do it' });
  const want = path.join(stateDir, 'pi-transcripts', 'child-1.jsonl');
  assert.equal(r.details.shadowTranscript, want);
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
test('every child runs with --no-skills; --skill <dir> only when a skill is given', async () => {
  const { tool } = setup();
  const plain = header(await run(tool, { description: 'd', prompt: 'p' })).args;
  assert.ok(plain.includes('--no-skills'));
  assert.ok(!plain.includes('--skill'));
  const withSkill = header(await run(tool, { description: 'd', prompt: 'p', skill: 'sub-flag' })).args;
  assert.ok(withSkill.includes('--no-skills'));
  assert.equal(withSkill.filter((a) => a === '--skill').length, 1);
  assert.equal(withSkill[withSkill.indexOf('--skill') + 1], path.join(fx, 'skills', 'sub-flag'));
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
test('ACHILLES_PI_PARENT_SHADOW: the child is told where the parent shadow lives', async () => {
  const stateDir = tmp();
  const { tool } = setup({ stateDir });
  assert.equal(header(await run(tool, { description: 'd', prompt: 'p' }, { sessionId: 'parent-7' })).parentShadow, path.join(stateDir, 'pi-transcripts', 'parent-7.jsonl'));
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
test('model-facing text is capped at 8 KB with a pointer to the full return; details.text is full', async () => {
  const cwd = tmp();
  const { tool } = setup();
  const r = await withEnv({ FAKE_PI_LONG: '1', ACHILLES_PI_AGENT_RESULT_CAP: undefined, ACHILLES_PI_VERBOSE: undefined }, () => run(tool, { description: 'd', prompt: 'p' }, { cwd }));
  const [body, pointer] = r.content[0].text.split('\n');
  assert.equal(body, 'y'.repeat(8192));
  assert.equal(pointer, `[achilles] full subagent return: ${path.join('.achilles', 'pi-agent-returns', 'child-1.md')} (last ${32 * 1024} chars cut)`);
  assert.equal(r.details.text, 'y'.repeat(40 * 1024));
  const file = path.join(cwd, '.achilles', 'pi-agent-returns', 'child-1.md');
  assert.equal(fs.readFileSync(file, 'utf8'), 'y'.repeat(40 * 1024));
  assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  assert.equal(fs.statSync(path.dirname(file)).mode & 0o777, 0o700);
});
test('ACHILLES_PI_AGENT_RESULT_CAP sets the cap in bytes', async () => {
  const cwd = tmp();
  const { tool } = setup();
  const r = await withEnv({ FAKE_PI_LONG: '1', ACHILLES_PI_AGENT_RESULT_CAP: '1000' }, () => run(tool, { description: 'd', prompt: 'p' }, { cwd }));
  assert.equal(r.content[0].text.split('\n')[0], 'y'.repeat(1000));
});
const HANDOVER = { handover: { role: 'workflow-reviewer-phase2', status: 'approved', 'next-action': 'advance' }, verdict: 'approve', checklist: [{ item: 'a {b} "c"', ok: true }] };
const pretty = JSON.stringify(HANDOVER, null, 2);
for (const [label, text] of [
  ['prose before the JSON', `Ledger verified. The review is complete; final return (conforming to {schema}):\n\n${pretty}`],
  ['a ```json fence after prose', `All evidence is in.\n\n\`\`\`json\n${pretty}\n\`\`\`\n\nDone.`],
]) {
  test(`the handover JSON is extracted from ${label}, compact, with the full return saved`, async () => {
    const cwd = tmp();
    const { tool } = setup();
    const r = await withEnv({ FAKE_PI_TEXT: text }, () => run(tool, { description: 'd', prompt: 'p' }, { cwd }));
    const [json, pointer, ...rest] = r.content[0].text.split('\n');
    assert.equal(json, JSON.stringify(HANDOVER));
    assert.deepEqual(rest, []);
    assert.match(pointer, /^\[achilles\] full subagent return: \.achilles\/pi-agent-returns\/child-1\.md \(\d+ chars of prose around the handover omitted\)$/);
    assert.equal(fs.readFileSync(path.join(cwd, pointer.split(': ')[1].split(' (')[0]), 'utf8'), text);
    assert.equal(r.details.text, text);
  });
}
test('a bare handover JSON is only re-serialised compactly: nothing dropped, no file, no pointer', async () => {
  const cwd = tmp();
  const { tool } = setup();
  const r = await withEnv({ FAKE_PI_TEXT: `\n\n${pretty}\n` }, () => run(tool, { description: 'd', prompt: 'p' }, { cwd }));
  assert.equal(r.content[0].text, JSON.stringify(HANDOVER));
  assert.ok(!fs.existsSync(path.join(cwd, '.achilles')));
});
test('text without a handover object passes through unchanged when under the cap', async () => {
  const cwd = tmp();
  const { tool } = setup();
  const text = 'Found {"x": 1} and {"y": {"handover": "nested, not top-level"}}.';
  const r = await withEnv({ FAKE_PI_TEXT: text }, () => run(tool, { description: 'd', prompt: 'p' }, { cwd }));
  assert.equal(r.content[0].text, text);
  assert.ok(!fs.existsSync(path.join(cwd, '.achilles')));
});
test('ACHILLES_PI_VERBOSE=1 bypasses extraction and the 8 KB cap (legacy 16 KB cap only)', async () => {
  const cwd = tmp();
  const { tool } = setup();
  const text = `Prose first.\n${pretty}`;
  const r = await withEnv({ FAKE_PI_TEXT: text, ACHILLES_PI_VERBOSE: '1' }, () => run(tool, { description: 'd', prompt: 'p' }, { cwd }));
  assert.equal(r.content[0].text, text);
  const long = await withEnv({ FAKE_PI_LONG: '1', ACHILLES_PI_VERBOSE: '1' }, () => run(tool, { description: 'd', prompt: 'p' }, { cwd }));
  assert.ok(long.content[0].text.startsWith('y'.repeat(16 * 1024)));
  assert.match(long.content[0].text, /truncated/);
  assert.ok(!fs.existsSync(path.join(cwd, '.achilles')));
});
test('every prompt goes by a 0600 @file, unchanged, and never as a raw argv word', async () => {
  const { tool } = setup();
  for (const prompt of ['--x', '@/etc/passwd', '- item', 'plain brief', 'x'.repeat(100 * 1024)]) {
    const h = header(await run(tool, { description: 'd', prompt }));
    assert.equal(h.prompt, prompt, JSON.stringify(prompt.slice(0, 20)));
    assert.equal(h.promptMode, 0o600);
    assert.equal(h.args.filter((a) => a.startsWith('@')).length, 1);
    assert.ok(!h.args.includes(prompt), 'raw prompt not in argv');
    assert.match(h.args.at(-1), /^@.*prompt\.md$/);
  }
});
test('no transcript copy unless ACHILLES_PI_KEEP_TRANSCRIPTS=1', async () => {
  const before = new Set(fs.readdirSync(os.tmpdir()).filter((f) => /^achilles-transcript-/.test(f)));
  const { tool } = setup();
  const r = await run(tool, { description: 'd', prompt: 'p' }, {}, { keep: false });
  assert.equal(r.details.transcriptCopy, undefined);
  const created = fs.readdirSync(os.tmpdir()).filter((f) => /^achilles-transcript-/.test(f) && !before.has(f));
  assert.deepEqual(created, []);
});
test('the kept transcript copy lives in its own mkdtemp dir with mode 0600', async () => {
  const { tool } = setup();
  const r = await run(tool, { description: 'd', prompt: 'p' });
  assert.match(path.basename(path.dirname(r.details.transcriptCopy)), /^achilles-transcript-/);
  assert.equal(path.dirname(path.dirname(r.details.transcriptCopy)), os.tmpdir());
  assert.equal(fs.statSync(r.details.transcriptCopy).mode & 0o777, 0o600);
  assert.equal(fs.statSync(path.dirname(r.details.transcriptCopy)).mode & 0o777, 0o700);
});
test('child stdout is decoded as UTF-8 across chunk boundaries', async () => {
  const { tool } = setup();
  const r = await withEnv({ FAKE_PI_UTF8: '1' }, () => run(tool, { description: 'd', prompt: 'p' }, {}, { keep: false }));
  assert.equal(r.details.text, '€'.repeat(150000));
});
test('NaN ACHILLES_PI_DEPTH counts as 0: the child gets depth 1', async () => {
  const { tool } = setup();
  const r = await withEnv({ ACHILLES_PI_KEEP_TRANSCRIPTS: '1', ACHILLES_PI_DEPTH: 'banana', ACHILLES_PROTOCOL: undefined },
    () => tool.execute('a', { description: 'd', prompt: 'p' }, undefined, undefined, makeFakeCtx()));
  cleanup.push(path.dirname(r.details.transcriptCopy));
  assert.equal(header(r).depth, '1');
});
test('a failing mkdtemp still releases the concurrency slot', async () => {
  const { tool } = setup({ maxConcurrent: 1 });
  await withEnv({ TMPDIR: '/nonexistent/achilles-no-such-dir' }, () =>
    assert.rejects(() => tool.execute('a', { description: 'd', prompt: 'p' }, undefined, undefined, makeFakeCtx()), /ENOENT/));
  const r = await Promise.race([
    run(tool, { description: 'd', prompt: 'p' }, {}, { keep: false }),
    new Promise((_, rej) => setTimeout(() => rej(new Error('slot leaked: second call never started')), 5000)),
  ]);
  assert.equal(r.content[0].text, 'child says hi');
});
test('saved returns are pruned to the newest 20 .md files by mtime; other files are left alone', () => {
  const cwd = tmp();
  const dir = path.join(cwd, '.achilles', 'pi-agent-returns');
  fs.mkdirSync(dir, { recursive: true });
  const base = Date.now() / 1000 - 10000;
  for (let i = 0; i < 25; i++) { const f = path.join(dir, `old-${i}.md`); fs.writeFileSync(f, String(i)); fs.utimesSync(f, base + i, base + i); }
  fs.writeFileSync(path.join(dir, 'notes.txt'), 'keep me'); fs.utimesSync(path.join(dir, 'notes.txt'), base - 100, base - 100);
  fs.mkdirSync(path.join(dir, 'sub.md'));
  const rel = saveFullReturn(cwd, 'newest', 'full text');
  assert.equal(rel, path.join('.achilles', 'pi-agent-returns', 'newest.md'));
  const md = fs.readdirSync(dir).filter((f) => f.endsWith('.md') && fs.statSync(path.join(dir, f)).isFile()).sort();
  assert.equal(md.length, 20);
  assert.ok(md.includes('newest.md'));
  // newest.md + the 19 most recent old files (old-6 .. old-24) survive; old-0 .. old-5 are gone.
  for (let i = 0; i < 6; i++) assert.ok(!md.includes(`old-${i}.md`), `old-${i}`);
  for (let i = 6; i < 25; i++) assert.ok(md.includes(`old-${i}.md`), `old-${i}`);
  assert.ok(fs.existsSync(path.join(dir, 'notes.txt')), 'non-.md files untouched');
  assert.ok(fs.statSync(path.join(dir, 'sub.md')).isDirectory(), 'directories untouched');
});
test('an over-cap handover stays valid JSON: top-level scalars kept, the longest values shortened, the pointer says so', async () => {
  const big = { handover: { role: 'workflow-reviewer-phase3', status: 'approved', 'next-action': 'advance to Phase 4' }, verdict: 'approve', phase: 3,
    summary: 's'.repeat(6000), checklist: Array.from({ length: 60 }, (_, i) => ({ item: `criterion ${i}`, evidence: 'e'.repeat(200), satisfied: true })) };
  const l = leanResult(`Review done.\n${JSON.stringify(big, null, 2)}`, 4096);
  assert.ok(Buffer.byteLength(l.text) <= 4096, String(Buffer.byteLength(l.text)));
  const parsed = JSON.parse(l.text);
  assert.deepEqual(parsed.handover, big.handover);
  assert.equal(parsed.verdict, 'approve'); assert.equal(parsed.phase, 3);
  assert.match(parsed.summary, /…\[truncated\]$/);
  assert.match(parsed.checklist.at(-1), /^…\[\d+ more items omitted\]$/);
  assert.ok(l.shortened > 0 && l.proseChars === 'Review done.'.length);
  const cwd = tmp();
  const { tool } = setup();
  const r = await withEnv({ FAKE_PI_TEXT: `Review done.\n${JSON.stringify(big, null, 2)}`, ACHILLES_PI_AGENT_RESULT_CAP: '4096' }, () => run(tool, { description: 'd', prompt: 'p' }, { cwd }));
  const [json, pointer] = r.content[0].text.split('\n');
  JSON.parse(json);
  assert.match(pointer, /\(12 chars of prose around the handover omitted; \d+ long values in the handover shortened\)$/);
});
test('shrinkJson: a fitting object is untouched; repeated array shrinking keeps one omitted-count marker', () => {
  assert.deepEqual(shrinkJson({ a: 1 }, 100), { json: '{"a":1}', shortened: 0 });
  const { json } = shrinkJson({ handover: {}, list: Array.from({ length: 200 }, (_, i) => i) }, 60);
  const list = JSON.parse(json).list;
  assert.equal(list.filter((x) => typeof x === 'string').length, 1);
  assert.equal(list.length - 1 + Number(/\d+/.exec(list.at(-1))[0]), 200);
});
test('plain text over the cap is cut at a line boundary', () => {
  const text = Array.from({ length: 400 }, (_, i) => `line ${i} ${'z'.repeat(40)}`).join('\n');
  const l = leanResult(text, 2000);
  assert.ok(Buffer.byteLength(l.text) <= 2000);
  assert.ok(text.startsWith(l.text) && text[l.text.length] === '\n');
  assert.equal(l.cutChars, text.length - l.text.length);
});
