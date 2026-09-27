// Shadow transcript: the three transcript-reading hooks, run for real against a shadow the module wrote.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { shadowPath, appendShadow, pruneShadows, KEEP_SHADOWS, toolUseEntry, assistantTextEntry, userPromptEntry, assistantText, sessionStateDir, shadowLiveWindow, SHADOW_LIVE_WINDOW_MS } from '../extensions/achilles/transcript.ts';
import { claudeToolInput } from '../extensions/achilles/payload.ts';
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
    tool(piName, input) { assert.ok(appendShadow(file, toolUseEntry(piName, `tc-${++n}`, claudeToolInput(piName, input)))); },
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
  assert.deepEqual(toolUseEntry('read', 't1', claudeToolInput('read', { path: '/p/SKILL.md' })),
    { type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', id: 't1', name: 'Read', input: { file_path: '/p/SKILL.md' } }] } });
  assert.deepEqual(toolUseEntry('Skill', 't2', { skill: 'journey-mapping' }).message.content[0], { type: 'tool_use', id: 't2', name: 'Skill', input: { skill: 'journey-mapping' } });
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

// ── round 2: shadow transcripts are pruned ───────────────────────────────────────────────────────
/** A state dir holding `n` shadows (oldest first by mtime), named s0..s<n-1>. */
function shadowDir(n) {
  const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'shadows-'));
  const dir = path.join(stateDir, 'pi-transcripts');
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  for (let i = 0; i < n; i++) {
    const f = path.join(dir, `s${i}.jsonl`);
    fs.writeFileSync(f, '{"type":"user"}\n');
    fs.utimesSync(f, 1, 1000 + i); // s0 oldest, s<n-1> newest
  }
  return { stateDir, dir };
}
const names = (dir) => fs.readdirSync(dir).sort();

test('pruneShadows keeps the newest 40 shadows and removes the rest', () => {
  const { stateDir, dir } = shadowDir(50);
  assert.equal(pruneShadows(stateDir), 10);
  assert.equal(fs.readdirSync(dir).length, KEEP_SHADOWS);
  assert.ok(!fs.existsSync(path.join(dir, 's9.jsonl')), 'the 10 oldest are gone');
  assert.ok(fs.existsSync(path.join(dir, 's10.jsonl')) && fs.existsSync(path.join(dir, 's49.jsonl')));
  // Idempotent: a second run has nothing left to do.
  assert.equal(pruneShadows(stateDir), 0);
});
test('pruneShadows spares a live session\'s shadow and the file it is told to keep', () => {
  const { stateDir, dir } = shadowDir(50);
  fs.writeFileSync(path.join(stateDir, 's0.active'), ''); // the live-session marker
  // shadowDir writes mtimes at epoch+1000s..+1049s; "now" just after the newest keeps them all inside
  // the liveness window, so the marker is what decides — as it did before the window existed.
  assert.equal(pruneShadows(stateDir, path.join(dir, 's1.jsonl'), KEEP_SHADOWS, 1_049_000), 8);
  assert.ok(fs.existsSync(path.join(dir, 's0.jsonl')), 'live session kept');
  assert.ok(fs.existsSync(path.join(dir, 's1.jsonl')), 'keepFile kept');
  assert.ok(!fs.existsSync(path.join(dir, 's2.jsonl')));
});

// ── I5: a marker alone is not evidence of a live session ─────────────────────────────────────────
/** A shadow dir whose files have explicit ages (ms before `now`) and optional `.active` markers. */
function agedShadows(spec, now) {
  const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'shadows-'));
  after(() => fs.rmSync(stateDir, { recursive: true, force: true }));
  const dir = path.join(stateDir, 'pi-transcripts');
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  for (const [name, ageMs, marker] of spec) {
    const f = path.join(dir, `${name}.jsonl`);
    fs.writeFileSync(f, '{"type":"user"}\n');
    const t = (now - ageMs) / 1000;
    fs.utimesSync(f, t, t);
    if (marker) fs.writeFileSync(path.join(stateDir, `${name}.active`), '');
  }
  return { stateDir, dir };
}
const DAY = 24 * 60 * 60 * 1000;

test('a stale .active marker no longer exempts its shadow', () => {
  const now = Date.now();
  const { stateDir, dir } = agedShadows([['a', 1000], ['b', 2000], ['stale', 10 * DAY, true]], now);
  assert.equal(pruneShadows(stateDir, undefined, 2, now), 1);
  assert.ok(!fs.existsSync(path.join(dir, 'stale.jsonl')), 'a stranded marker pinned it forever');
  assert.ok(fs.existsSync(path.join(stateDir, 'stale.active')), 'the marker itself is not touched');
  // Idempotent, and the retained set is the keep count — not keep + one per historical run.
  assert.equal(pruneShadows(stateDir, undefined, 2, now), 0);
  assert.equal(fs.readdirSync(dir).length, 2);
});

test('a marker on a shadow written inside the window still spares it', () => {
  const now = Date.now();
  const { stateDir, dir } = agedShadows([['a', 1000], ['b', 2000], ['live', 3000, true], ['old', 10 * DAY]], now);
  assert.equal(pruneShadows(stateDir, undefined, 2, now), 1);
  assert.ok(fs.existsSync(path.join(dir, 'live.jsonl')), 'a running session must never lose its shadow');
  assert.ok(!fs.existsSync(path.join(dir, 'old.jsonl')));
});

test('ACHILLES_PI_SHADOW_LIVE_WINDOW moves the liveness window', (t) => {
  const prev = process.env.ACHILLES_PI_SHADOW_LIVE_WINDOW;
  t.after(() => { if (prev === undefined) delete process.env.ACHILLES_PI_SHADOW_LIVE_WINDOW; else process.env.ACHILLES_PI_SHADOW_LIVE_WINDOW = prev; });
  assert.equal(shadowLiveWindow(), SHADOW_LIVE_WINDOW_MS);
  for (const bad of ['0', '-1', 'x', '']) { process.env.ACHILLES_PI_SHADOW_LIVE_WINDOW = bad; assert.equal(shadowLiveWindow(), SHADOW_LIVE_WINDOW_MS, bad); }
  const now = Date.now();
  const { stateDir, dir } = agedShadows([['a', 1000], ['b', 2000], ['hour', 60 * 60 * 1000, true]], now);
  assert.equal(pruneShadows(stateDir, undefined, 2, now), 0, 'an hour old is live under the 6h default');
  process.env.ACHILLES_PI_SHADOW_LIVE_WINDOW = '60000'; // one minute
  assert.equal(shadowLiveWindow(), 60000);
  assert.equal(pruneShadows(stateDir, undefined, 2, now), 1);
  assert.ok(!fs.existsSync(path.join(dir, 'hour.jsonl')));
});

test('pruneShadows touches nothing else in the state dir and leaves non-jsonl files alone', () => {
  const { stateDir, dir } = shadowDir(45);
  fs.writeFileSync(path.join(stateDir, 'sid.active'), '');
  fs.writeFileSync(path.join(dir, 'notes.txt'), 'x');
  fs.mkdirSync(path.join(dir, 'sub'));
  pruneShadows(stateDir);
  assert.ok(fs.existsSync(path.join(stateDir, 'sid.active')));
  assert.ok(fs.existsSync(path.join(dir, 'notes.txt')));
  assert.ok(fs.existsSync(path.join(dir, 'sub')));
  assert.equal(names(dir).filter((n) => n.endsWith('.jsonl')).length, KEEP_SHADOWS);
});
test('pruneShadows on a missing or symlinked pi-transcripts does nothing and never throws', () => {
  const empty = fs.mkdtempSync(path.join(os.tmpdir(), 'shadows-'));
  assert.equal(pruneShadows(empty), -1);
  const { dir } = shadowDir(50);
  const other = fs.mkdtempSync(path.join(os.tmpdir(), 'shadows-'));
  fs.symlinkSync(dir, path.join(other, 'pi-transcripts'));
  assert.equal(pruneShadows(other), -1);
  assert.equal(fs.readdirSync(dir).length, 50, 'the symlink target is untouched');
});
test('a keep of 0 is honoured, and under the keep count nothing is removed', () => {
  const a = shadowDir(3);
  assert.equal(pruneShadows(a.stateDir, undefined, 10), 0);
  const b = shadowDir(3);
  assert.equal(pruneShadows(b.stateDir, undefined, 1), 2);
  assert.deepEqual(names(b.dir), ['s2.jsonl']);
});
