// Self-test of scripts/validate-schema-fixtures.mjs: each case runs the runner on a
// temporary copy of schemas/ with one fixture added, so the repository is never touched.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { cpSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const ROOT = new URL('../../', import.meta.url).pathname;
const RETURNS = 'schemas/subagent-returns/fixtures';
const VALID = readFileSync(join(ROOT, RETURNS, 'platform-reviewer-valid.yaml'), 'utf8');

function copy() {
  const d = mkdtempSync(join(tmpdir(), 'vsf-'));
  cpSync(join(ROOT, 'schemas'), join(d, 'schemas'), { recursive: true });
  cpSync(join(ROOT, 'scripts'), join(d, 'scripts'), { recursive: true });
  symlinkSync(join(ROOT, 'node_modules'), join(d, 'node_modules'), 'dir');
  return d;
}

function run(add = {}) {
  const d = copy();
  for (const [rel, text] of Object.entries(add)) writeFileSync(join(d, rel), text);
  const r = spawnSync(process.execPath, ['scripts/validate-schema-fixtures.mjs'], { cwd: d, encoding: 'utf8' });
  rmSync(d, { recursive: true, force: true });
  return { status: r.status, out: `${r.stdout}${r.stderr}` };
}

test('the unchanged fixtures pass', () => {
  const r = run();
  assert.equal(r.status, 0, r.out);
});

test('a fixture that matches no naming convention fails the run', () => {
  const r = run({ [`${RETURNS}/platform-reviewr-valid.yaml`]: VALID });
  assert.equal(r.status, 1, r.out);
  assert.match(r.out, /platform-reviewr-valid\.yaml matches no fixture convention/);
});

test('a <role>-valid-<case>.yaml must validate', () => {
  const ok = run({ [`${RETURNS}/platform-reviewer-valid-phase-two.yaml`]: VALID.replace('platform-reviewer-phase4', 'platform-reviewer-phase2').replace(/^phase: 4$/m, 'phase: 2') });
  assert.equal(ok.status, 0, ok.out);
  assert.match(ok.out, /OK: {3}\S+platform-reviewer-valid-phase-two\.yaml validates against platform-reviewer\.schema\.json/);

  const bad = run({ [`${RETURNS}/platform-reviewer-valid-phase-mismatch.yaml`]: VALID.replace(/^phase: 4$/m, 'phase: 5') });
  assert.equal(bad.status, 1, bad.out);
  assert.match(bad.out, /FAIL: \S+platform-reviewer-valid-phase-mismatch\.yaml did not validate/);
});

test('a <role>-invalid-<case>.yaml that validates fails the run', () => {
  const r = run({ [`${RETURNS}/platform-reviewer-invalid-not-really.yaml`]: VALID });
  assert.equal(r.status, 1, r.out);
  assert.match(r.out, /FAIL: \S+platform-reviewer-invalid-not-really\.yaml unexpectedly validated/);
});

test('dotfiles in the fixtures dir are ignored', () => {
  const r = run({ [`${RETURNS}/.DS_Store`]: 'not a fixture' });
  assert.equal(r.status, 0, r.out);
  assert.doesNotMatch(r.out, /\.DS_Store/);
});

test('a factory-rules valid-*.patch.json must validate', () => {
  const patch = (value) => JSON.stringify({ base: 'factory-rules.example.json', patch: [{ op: 'replace', path: '/contexts/iphone/server', value }] });
  const ok = run({ 'schemas/factory-rules.fixtures/valid-self-test.patch.json': patch('https://appium.example.test/wd/hub') });
  assert.equal(ok.status, 0, ok.out);
  const bad = run({ 'schemas/factory-rules.fixtures/valid-self-test.patch.json': patch('http://127.0.0.1:4723/wd/hub') });
  assert.equal(bad.status, 1, bad.out);
  assert.match(bad.out, /FAIL: \S+valid-self-test\.patch\.json did not validate/);
});
