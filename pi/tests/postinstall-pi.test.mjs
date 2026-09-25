import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';
const require = createRequire(import.meta.url);
const repoRoot = path.resolve(import.meta.dirname, '..', '..');
const postPath = path.join(repoRoot, 'scripts', 'postinstall.js');
const post = require(postPath);
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'achilles-pi-'));

// installPiHarness() reads module-scope globals resolved at require time
// (os.homedir(), process.env.npm_config_global, packageDir) — it can't be
// driven by passing arguments, so these tests spawn a fresh node process per
// case with a controlled env (HOME, PATH, npm_config_global,
// CIVITAS_SKIP_HOOK_INSTALL) and assert on what landed on disk. PATH is
// always pointed at a nonexistent dir so pi detection comes only from the
// fake ~/.pi/agent, never from the real `pi` this repo's dev env has on PATH.
function runInstallPiHarness(env) {
  return spawnSync(process.execPath, ['-e', `require(${JSON.stringify(postPath)}).installPiHarness();`], {
    env,
    encoding: 'utf8',
  });
}

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

test('installPiHarness: global install registers the package and copies skills', () => {
  const home = tmp();
  fs.mkdirSync(path.join(home, '.pi', 'agent'), { recursive: true });
  const result = runInstallPiHarness({ HOME: home, PATH: '/nonexistent', npm_config_global: 'true' });
  assert.equal(result.status, 0, result.stderr);
  const settingsPath = path.join(home, '.pi', 'agent', 'settings.json');
  const settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
  assert.ok(Array.isArray(settings.packages));
  assert.ok(settings.packages.includes(path.join(repoRoot, 'pi')));
  assert.ok(fs.existsSync(path.join(home, '.agents', 'skills', 'onboarding', 'SKILL.md')));
});

test('installPiHarness: CIVITAS_SKIP_HOOK_INSTALL=1 copies skills but skips settings write', () => {
  const home = tmp();
  fs.mkdirSync(path.join(home, '.pi', 'agent'), { recursive: true });
  const result = runInstallPiHarness({
    HOME: home, PATH: '/nonexistent', npm_config_global: 'true', CIVITAS_SKIP_HOOK_INSTALL: '1',
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(path.join(home, '.pi', 'agent', 'settings.json')), false);
  assert.ok(fs.existsSync(path.join(home, '.agents', 'skills', 'onboarding', 'SKILL.md')));
});

test('installPiHarness: no pi detected → nothing written', () => {
  const home = tmp();
  const result = runInstallPiHarness({ HOME: home, PATH: '/nonexistent' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(path.join(home, '.pi')), false);
  assert.equal(fs.existsSync(path.join(home, '.agents')), false);
});
