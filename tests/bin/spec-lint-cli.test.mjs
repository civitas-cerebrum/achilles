// The achilles-spec-lint CLI: exit codes, the three-line human format, --json against its schema, --quiet,
// usage and configuration errors, the time budget.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync, rmSync } from 'node:fs';
import path from 'node:path';
import { makeAjv } from '../../scripts/lib/ajv.mjs';
import { REPO, tempRoot, writeProject } from './spec-lint-helpers.mjs';

const BIN = path.join(REPO, 'bin', 'spec-lint.mjs');
const run = (root, args = []) => spawnSync(process.execPath, [BIN, ...args], { cwd: root, encoding: 'utf8', env: { ...process.env, CLAUDE_PROJECT_DIR: root } });
const validate = makeAjv().compile(JSON.parse(readFileSync(path.join(REPO, 'schemas', 'spec-lint-report.schema.json'), 'utf8')));

const CLEAN = "import { test } from './fixtures/base';\ntest('TCAB-0001 · x', async ({ steps }) => { await steps.navigateTo('/'); await steps.verifyPresence('heading', 'HomePage'); });\n";
const PINNED = { 'tests/compliance-baseline.json': '{ "idPattern": "house-default" }\n' };
const RAW = "import { test } from './fixtures/base';\ntest('TCAB-0002 · x', async ({ page }) => {\n  await page.goto('/');\n});\n";

function withProject(files, fn, opts) {
  const root = tempRoot();
  try { writeProject(root, files, opts); return fn(root); } finally { rmSync(root, { recursive: true, force: true }); }
}

test('a clean project exits 0 and prints the summary line', () => withProject({ ...PINNED, 'tests/e2e/a.spec.ts': CLEAN }, (root) => {
  const r = run(root);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /^spec-lint: 1 file\(s\), 0 blocking, 0 advisory/m);
  assert.equal(r.stderr, '');
}));

test('a blocking finding exits 1 with three lines: rule, location and test id; Do; Why/how', () => withProject({ 'tests/e2e/a.spec.ts': RAW }, (root) => {
  const r = run(root);
  assert.equal(r.status, 1);
  const lines = r.stderr.trim().split('\n');
  assert.match(lines[0], /^\[TB-A2\] tests\/e2e\/a\.spec\.ts:3 TCAB-0002: /);
  assert.match(lines[1], /^→ Do: .*steps\.navigateTo/);
  assert.equal(lines[2], '→ Why/how: skills/achilles-orchestrator/references/test-baseline.md#tb-a2');
}));

test('--json prints a report that validates against schemas/spec-lint-report.schema.json', () => withProject({ 'tests/e2e/a.spec.ts': RAW, 'tests/e2e/b.spec.ts': CLEAN }, (root) => {
  const r = run(root, ['--json']);
  assert.equal(r.status, 1);
  const report = JSON.parse(r.stdout);
  assert.ok(validate(report), JSON.stringify(validate.errors));
  assert.equal(report.ok, false);
  assert.deepEqual(report.stepsSurface, { package: '@civitas-cerebrum/element-interactions', version: '0.3.12', source: 'snapshot' });
  const f = report.files.find((x) => x.path === 'tests/e2e/a.spec.ts');
  assert.match(f.blob, /^[0-9a-f]{40}$/);
  assert.deepEqual(f.tests.map((t) => t.id), ['TCAB-0002']);
  const finding = report.findings.find((x) => x.rule === 'TB-A2');
  assert.equal(finding.region, 'test');
  assert.equal(finding.test.id, 'TCAB-0002');
}));

test('--quiet drops the summary line; findings still print', () => withProject({ 'tests/e2e/a.spec.ts': RAW }, (root) => {
  const r = run(root, ['--quiet']);
  assert.equal(r.status, 1);
  assert.equal(r.stdout, '');
  assert.match(r.stderr, /\[TB-A2\]/);
}));

test('an unknown option, a missing path and an unresolvable surface exit 2', () => withProject({ 'tests/e2e/a.spec.ts': CLEAN }, (root) => {
  let r = run(root, ['--bogus']);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /unknown option --bogus/);
  r = run(root, ['tests/e2e/nope.spec.ts']);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /not found/);
  writeProject(root, { 'package.json': '{"name":"bare"}' });
  r = run(root);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /no Steps surface/);
  assert.match(r.stderr, /→ Do: /);
}));

test('a file that runs past the time budget exits 3', () => withProject({ 'tests/e2e/a.spec.ts': CLEAN }, (root) => {
  const r = run(root, ['--budget-ms', '0']);
  assert.equal(r.status, 3);
  assert.match(r.stderr, /time budget/);
}));

test('a waived finding does not fail the run and is reported as waived', () => withProject({
  'tests/e2e/a.spec.ts': "import { test } from './fixtures/base';\ntest('TC-3 · x', async ({ page }) => {\n  // achilles-allow TB-A4 -- the theme flag must exist before any page script runs\n  await page.addInitScript(() => localStorage.setItem('theme', 'dark'));\n});\n",
}, (root) => {
  const r = run(root, ['--json']);
  assert.equal(r.status, 0, r.stdout);
  const report = JSON.parse(r.stdout);
  const f = report.findings.find((x) => x.rule === 'TB-A4');
  assert.equal(f.waived, true);
  assert.match(f.waiver.reason, /theme flag/);
}));

test('a run that is not --stdin never reads standard input: an open, never-closed pipe does not hold it', async () => {
  const { spawn } = await import('node:child_process');
  const root = tempRoot();
  try {
    writeProject(root, { 'tests/e2e/a.spec.ts': RAW });
    const code = await new Promise((resolve) => {
      const p = spawn(process.execPath, [BIN, '--json'], { cwd: root, env: { ...process.env, CLAUDE_PROJECT_DIR: root }, stdio: ['pipe', 'pipe', 'pipe'] });
      p.stdout.resume(); p.stderr.resume();
      const kill = setTimeout(() => { p.kill('SIGKILL'); resolve('timeout'); }, 30000);
      p.on('exit', (c) => { clearTimeout(kill); p.stdin.destroy(); resolve(c); });
    });
    assert.equal(code, 1);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
