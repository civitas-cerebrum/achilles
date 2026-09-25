import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const post = require(path.resolve(import.meta.dirname, '..', '..', 'scripts', 'postinstall.js'));
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'achilles-pi-'));

test('detectPi: false when neither dir nor binary', () => {
  assert.equal(post.detectPi({ PATH: '/nonexistent' }, tmp()), false);
});
test('detectPi: true when ~/.pi/agent exists', () => {
  const home = tmp(); fs.mkdirSync(path.join(home, '.pi', 'agent'), { recursive: true });
  assert.equal(post.detectPi({ PATH: '/nonexistent' }, home), true);
});
test('detectPi: true when pi is on PATH', () => {
  const bin = tmp(); fs.writeFileSync(path.join(bin, 'pi'), '#!/bin/sh\n', { mode: 0o755 });
  assert.equal(post.detectPi({ PATH: bin }, tmp()), true);
});
test('registerPiPackage: creates settings and dedupes', () => {
  const dir = tmp(); const sp = path.join(dir, 'settings.json');
  assert.equal(post.registerPiPackage(sp, '/abs/pkg/pi'), true);
  assert.equal(post.registerPiPackage(sp, '/abs/pkg/pi'), false);
  assert.deepEqual(JSON.parse(fs.readFileSync(sp, 'utf8')).packages, ['/abs/pkg/pi']);
});
test('registerPiPackage: preserves existing entries and object-form sources', () => {
  const dir = tmp(); const sp = path.join(dir, 'settings.json');
  fs.writeFileSync(sp, JSON.stringify({ theme: 'dark', packages: [{ source: '/abs/pkg/pi', skills: [] }, 'npm:x'] }));
  assert.equal(post.registerPiPackage(sp, '/abs/pkg/pi'), false);
  const s = JSON.parse(fs.readFileSync(sp, 'utf8'));
  assert.equal(s.theme, 'dark'); assert.equal(s.packages.length, 2);
});
test('registerPiPackage: leaves malformed settings untouched', () => {
  const dir = tmp(); const sp = path.join(dir, 'settings.json');
  fs.writeFileSync(sp, '{ not json');
  assert.equal(post.registerPiPackage(sp, '/abs/pkg/pi'), false);
  assert.equal(fs.readFileSync(sp, 'utf8'), '{ not json');
});
test('installAgentSkills: copies every skill dir', () => {
  const home = tmp();
  const n = post.installAgentSkills(home);
  assert.ok(n > 10);
  assert.ok(fs.existsSync(path.join(home, '.agents', 'skills', 'onboarding', 'SKILL.md')));
});
