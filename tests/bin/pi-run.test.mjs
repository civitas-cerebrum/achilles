// The pi guards' host process runner (pi/run.ts): the bound holds, and a child that exits first is reported
// with its own exit code. Loaded as TypeScript, so it runs where Node strips types (22.6 and later).
import { test } from 'node:test';
import assert from 'node:assert/strict';

const strips = !!(process.features && process.features.typescript);
const load = () => import('../../pi/run.ts');

test('an early exit with a large unread stdin and a grandchild holding the pipes is the exit, not a timeout', { skip: !strips && 'this Node does not load TypeScript' }, async () => {
  const { runProcess } = await load();
  const t0 = Date.now();
  const r = await runProcess(['sh', '-c', 'echo started; (sleep 5 &) ; exit 3'], { stdin: 'x'.repeat(8 * 1024 * 1024), timeoutMs: 4000 });
  assert.equal(r.exitCode, 3);
  assert.match(r.stdout, /started/);
  assert.ok(Date.now() - t0 < 2000, `resolved after ${Date.now() - t0} ms`);
});

test('a child that reads its stdin and exits cleanly returns its output', { skip: !strips && 'this Node does not load TypeScript' }, async () => {
  const { runProcess } = await load();
  const r = await runProcess(['sh', '-c', 'wc -c'], { stdin: 'abcdef', timeoutMs: 4000 });
  assert.equal(r.exitCode, 0);
  assert.equal(r.stdout.trim(), '6');
});

test('a child killed by a signal reads as 128 + the signal, never as exit 1', { skip: !strips && 'this Node does not load TypeScript' }, async () => {
  const { runProcess } = await load();
  const r = await runProcess(['sh', '-c', 'kill -TERM $$'], { timeoutMs: 4000 });
  assert.equal(r.exitCode, 143);
});

test('a child past its bound is killed and the call fails', { skip: !strips && 'this Node does not load TypeScript' }, async () => {
  const { runProcess } = await load();
  await assert.rejects(runProcess(['sh', '-c', 'sleep 5'], { timeoutMs: 300 }), /timed out after 300 ms/);
});
