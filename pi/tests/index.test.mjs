import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { makeFakePi } from './fake-pi.mjs';
import achilles from '../extensions/achilles/index.ts';

const LOADED = Symbol.for('achilles.pi.loaded');
const SELF = path.resolve(import.meta.dirname, '..', 'extensions', 'achilles', 'index.ts');

test('a second, different copy registers nothing and logs duplicate_instance', (t) => {
  const logFile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'idx-')), 'log.jsonl');
  const prevLog = process.env.ACHILLES_PI_LOG; process.env.ACHILLES_PI_LOG = logFile;
  t.after(() => { delete globalThis[LOADED]; if (prevLog === undefined) delete process.env.ACHILLES_PI_LOG; else process.env.ACHILLES_PI_LOG = prevLog; });
  globalThis[LOADED] = '/other/install/node_modules/@civitas-cerebrum/achilles/pi/extensions/achilles/index.ts';
  const pi = makeFakePi();
  achilles(pi);
  assert.equal(pi.tools.length, 0);
  assert.equal(pi.handlers.size, 0);
  const line = JSON.parse(fs.readFileSync(logFile, 'utf8').trim());
  assert.equal(line.kind, 'duplicate_instance'); assert.equal(line.self, SELF);
});
test('the first copy claims the runtime; the same copy re-running (reload) registers again; shutdown releases the claim', async (t) => {
  t.after(() => { delete globalThis[LOADED]; });
  delete globalThis[LOADED];
  const a = makeFakePi(); achilles(a);
  assert.equal(globalThis[LOADED], SELF);
  assert.deepEqual(a.tools.map((x) => x.name).sort(), ['Agent', 'Skill']);
  const b = makeFakePi(); achilles(b);
  assert.deepEqual(b.tools.map((x) => x.name).sort(), ['Agent', 'Skill'], 'same copy is not a duplicate');
  await a.fire('session_shutdown', { type: 'session_shutdown', reason: 'reload' }, {});
  assert.equal(globalThis[LOADED], undefined);
});
