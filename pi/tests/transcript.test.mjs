// Shadow transcript: the three transcript-reading hooks, run for real against a shadow the module wrote.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { shadowPath, appendShadow, toolUseEntry, assistantTextEntry, userPromptEntry, assistantText, sessionStateDir } from '../extensions/achilles/transcript.ts';
import { runHook, parseDecision } from '../extensions/achilles/bridge.ts';

const REPO = path.resolve(import.meta.dirname, '..', '..');
const HOOKS = path.join(REPO, 'hooks');
const cleanup = [];
after(() => { for (const p of cleanup) fs.rmSync(p, { recursive: true, force: true }); });
const tmp = () => { const d = fs.mkdtempSync(path.join(os.tmpdir(), 'shadow-')); cleanup.push(d); return d; };

/** A fresh session: its own state dir, shadow path, and a helper to append pi-shaped events. */
function session(id = 'sess-1') {
  const stateDir = tmp();
  const file = shadowPath(id, stateDir);
  let n = 0;
  return {
    id, stateDir, file,
    tool(piName, input) { assert.ok(appendShadow(file, toolUseEntry(piName, input, `tc-${++n}`))); },
    say(text) { assert.ok(appendShadow(file, assistantTextEntry(text))); },
    user(text) { assert.ok(appendShadow(file, userPromptEntry(text))); },
  };
}
async function hook(s, file, payload, extraEnv = {}) {
  const run = await runHook({
    bash: 'bash', hookPath: path.join(HOOKS, file), timeoutMs: 15000, cwd: s.stateDir,
    payload: { session_id: s.id, transcript_path: s.file, cwd: s.stateDir, ...payload },
    env: { ...process.env, ACHILLES_PROTOCOL: '1', ACHILLES_SESSION_STATE_DIR: s.stateDir, ...extraEnv },
  });
  return { run, decision: parseDecision(run, payload.hook_event_name) };
}

test('shadow path lives under <stateDir>/pi-transcripts with private modes', () => {
  const s = session('a/b:c');
  assert.equal(s.file, path.join(s.stateDir, 'pi-transcripts', 'a_b_c.jsonl'));
  s.tool('read', { path: 'x.md' });
  assert.equal(fs.statSync(path.dirname(s.file)).mode & 0o777, 0o700);
  assert.equal(fs.statSync(s.file).mode & 0o777, 0o600);
});
test('sessionStateDir: ACHILLES_SESSION_STATE_DIR wins, else ~/.claude/achilles/sessions', () => {
  const prev = process.env.ACHILLES_SESSION_STATE_DIR;
  try {
    process.env.ACHILLES_SESSION_STATE_DIR = '/x/y';
    assert.equal(sessionStateDir('/h'), '/x/y');
    delete process.env.ACHILLES_SESSION_STATE_DIR;
    assert.equal(sessionStateDir('/h'), path.join('/h', '.claude', 'achilles', 'sessions'));
  } finally { if (prev === undefined) delete process.env.ACHILLES_SESSION_STATE_DIR; else process.env.ACHILLES_SESSION_STATE_DIR = prev; }
});
test('entries are Claude-shaped', () => {
  assert.deepEqual(toolUseEntry('read', { path: '/p/SKILL.md' }, 't1'),
    { type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', id: 't1', name: 'Read', input: { file_path: '/p/SKILL.md' } }] } });
  assert.deepEqual(toolUseEntry('Skill', { skill: 'journey-mapping' }, 't2').message.content[0], { type: 'tool_use', id: 't2', name: 'Skill', input: { skill: 'journey-mapping' } });
  assert.deepEqual(assistantTextEntry('hi'), { type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'hi' }] } });
  // User prompts carry string content, like Claude's, so hooks scanning content[] never read them as model text.
  assert.deepEqual(userPromptEntry('do it'), { type: 'user', message: { role: 'user', content: 'do it' } });
  assert.equal(assistantText({ role: 'assistant', content: [{ type: 'thinking', thinking: 'x' }, { type: 'text', text: 'a' }, { type: 'toolCall' }, { type: 'text', text: 'b' }] }), 'a\nb');
  assert.equal(assistantText({ role: 'user', content: [{ type: 'text', text: 'a' }] }), '');
});
test('achilles-activation transcript grep matches what the shadow records', async () => {
  // No ACHILLES_PROTOCOL: activation must come from the transcript scan alone. The hook under test is
  // the preread gate on a journey-map write, which denies only when the session is active.
  const check = async (fill) => {
    const s = session(); fill(s);
    const map = path.join(s.stateDir, 'tests', 'e2e', 'docs', 'journey-map.md');
    return hook(s, 'journey-mapping-skill-preread-gate.sh',
      { hook_event_name: 'PreToolUse', tool_name: 'Write', tool_input: { file_path: map, content: 'x' } },
      { ACHILLES_PROTOCOL: '' });
  };
  // Inactive (plain session): silent allow even without the preread.
  assert.equal((await check((s) => s.user('hello'))).decision.block, false);
  // "skill":"<name>" signature from a Skill tool_use of another achilles skill → active → deny.
  assert.equal((await check((s) => s.tool('Skill', { skill: 'onboarding' }))).decision.block, true);
  // <command-name>/<skill>< signature from a typed /skill:<name> prompt → active → deny.
  assert.equal((await check((s) => s.user('/skill:onboarding start'))).decision.block, true);
  // skills/<name>/SKILL.md signature from a read → active → deny.
  assert.equal((await check((s) => s.tool('read', { path: '/pkg/skills/test-composer/SKILL.md' }))).decision.block, true);
});

// --- journey-mapping-skill-preread-gate.sh (hooks/tests/cases/56-*) -----------------------------
const preread = async (fill) => {
  const s = session(); fill(s);
  const map = path.join(s.stateDir, 'tests', 'e2e', 'docs', 'journey-map.md');
  s.tool('write', { path: map, content: '<!-- journey-mapping:generated -->' }); // the bridge records the call before hooks run
  return hook(s, 'journey-mapping-skill-preread-gate.sh',
    { hook_event_name: 'PreToolUse', tool_name: 'Write', tool_input: { file_path: map, content: '<!-- journey-mapping:generated -->' } });
};
test('preread gate: denies a journey-map write when the skill was never loaded', async () => {
  const { decision } = await preread((s) => {
    s.user('map the app');
    s.say("I'll write the map directly.");
    s.tool('read', { path: '/proj/tests/e2e/docs/app-context.md' });
  });
  assert.equal(decision.block, true);
  assert.match(decision.reason, /requires the journey-mapping skill/);
});
test('preread gate: allows after Skill{journey-mapping} plus a read of its SKILL.md', async () => {
  const { decision } = await preread((s) => {
    s.tool('Skill', { skill: 'journey-mapping' });
    s.tool('read', { path: '/home/u/.agents/skills/journey-mapping/SKILL.md' });
  });
  assert.equal(decision.block, false, decision.reason);
});
test('preread gate: either signal alone is enough (Skill, or a read of SKILL.md)', async () => {
  assert.equal((await preread((s) => s.tool('Skill', { skill: 'journey-mapping' }))).decision.block, false);
  assert.equal((await preread((s) => s.tool('read', { path: '/pkg/skills/journey-mapping/SKILL.md' }))).decision.block, false);
});

// --- compliance-sweep-exit-gate.sh (hooks/tests/cases/76-*) --------------------------------------
const stop = (s, event = 'Stop', active = false) => hook(s, 'compliance-sweep-exit-gate.sh', { hook_event_name: event, stop_hook_active: active });
test('compliance sweep: blocks the stop when a spec was written and no sweep followed', async () => {
  const s = session();
  s.say('Writing the login scenario.');
  s.tool('write', { path: '/repo/tests/e2e/login/login.spec.ts', content: 'x' });
  s.say('Test passes 3x.');
  for (const ev of ['Stop', 'SubagentStop']) {
    const { run, decision } = await stop(s, ev);
    assert.equal(run.exitCode, 2, `${ev}: ${run.stderr}`);
    assert.equal(decision.block, true);
    assert.match(decision.reason, /compliance sweep never ran/);
  }
});
test('compliance sweep: an edit after an earlier sweep still blocks; a sweep after the write allows', async () => {
  const s = session();
  s.say('**API Compliance Review** — clean for the previous scenario.');
  s.tool('edit', { path: '/repo/tests/e2e/login/login.spec.ts', edits: [{ oldText: 'a', newText: 'b' }] });
  assert.equal((await stop(s)).decision.block, true);
  s.say('**API Compliance Review**\n\nReviewed: tests/e2e/login/login.spec.ts — no issues found.');
  assert.equal((await stop(s)).decision.block, false);
});
test('compliance sweep: the user asking for a sweep is not the model running one', async () => {
  const s = session();
  s.tool('write', { path: '/repo/tests/e2e/a.spec.ts', content: 'x' });
  s.user('please run the compliance sweep');
  assert.equal((await stop(s)).decision.block, true);
});
test('compliance sweep: no spec written, or stop_hook_active → allow', async () => {
  const s = session();
  s.tool('write', { path: '/repo/tests/e2e/fixtures/base.ts', content: 'x' });
  assert.equal((await stop(s)).decision.block, false);
  s.tool('write', { path: '/repo/tests/e2e/b.spec.ts', content: 'x' });
  assert.equal((await stop(s, 'Stop', true)).decision.block, false);
});

// --- failure-diagnosis-evidence-floor-gate.sh (hooks/tests/cases/71-*) --------------------------
const floor = (s, file = '/repo/tests/e2e/checkout.spec.ts') => {
  s.tool('write', { path: file, content: 'x' });
  return hook(s, 'failure-diagnosis-evidence-floor-gate.sh', { hook_event_name: 'PreToolUse', tool_name: 'Write', tool_input: { file_path: file, content: 'x' } });
};
test('evidence floor: denies a spec write from an fd context with no evidence opened', async () => {
  const s = session();
  s.user('the nightly failed');
  s.tool('Skill', { skill: 'failure-diagnosis' });
  s.tool('bash', { command: 'gh run view 123 --job 456 --log-failed' });
  s.tool('read', { path: '/repo/apps/e2e/docs/app-context.md' });
  const { decision } = await floor(s);
  assert.equal(decision.block, true);
  assert.match(decision.reason, /Evidence-floor violation/);
});
test('evidence floor: fd context from a SKILL.md read also enforces; page-repository is gated too', async () => {
  const s = session();
  s.tool('read', { path: '/repo/node_modules/@civitas-cerebrum/achilles/skills/failure-diagnosis/SKILL.md' });
  assert.equal((await floor(s, '/repo/tests/e2e/page-repository.json')).decision.block, true);
});
test('evidence floor: one evidence read (trace) or bash (show-trace) allows', async () => {
  const a = session();
  a.tool('Skill', { skill: 'failure-diagnosis' });
  a.tool('read', { path: '/repo/test-results/checkout-guest/error-context.md' });
  assert.equal((await floor(a)).decision.block, false);
  const b = session();
  b.tool('Skill', { skill: 'failure-diagnosis' });
  b.tool('bash', { command: 'npx playwright show-trace test-results/x/trace.zip' });
  assert.equal((await floor(b)).decision.block, false);
});
test('evidence floor: no fd context (composer) → allow', async () => {
  const s = session();
  s.tool('Skill', { skill: 'test-composer' });
  s.tool('Agent', { description: 'composer-j-login:', prompt: 'compose the login journey' });
  assert.equal((await floor(s)).decision.block, false);
});
