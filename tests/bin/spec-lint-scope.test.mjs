// Which files achilles-spec-lint lints, and as what: spec roots and globs from every playwright*.config.*,
// Playwright's default testMatch and tests/**; spec, support, k6, bundle and excluded files.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
import { lintProject } from '../../bin/lib/spec-lint/engine.mjs';
import { tempRoot, writeProject } from './spec-lint-helpers.mjs';

const SPEC = "import { test } from './fixtures/base';\ntest('TC-1 · x', async ({ steps }) => { await steps.navigateTo('/'); });\n";
const RAW_SPEC = "import { test } from './fixtures/base';\ntest('TC-2 · x', async ({ page }) => { await page.goto('/'); });\n";
const kinds = (report) => Object.fromEntries(report.files.map((f) => [f.path, f.kind]));

function project(files) {
  const root = tempRoot();
  writeProject(root, files);
  return root;
}

test('config testDir, testMatch and testIgnore, unioned with tests/** and the default glob', () => {
  const root = project({
    'playwright.config.ts': "import { defineConfig } from '@playwright/test';\nexport default defineConfig({ testDir: './acceptance', testMatch: '**/*.check.ts', testIgnore: '**/legacy/**' });\n",
    'acceptance/login.check.ts': SPEC,
    'acceptance/legacy/old.check.ts': SPEC,
    'acceptance/legacy/notes.ts': 'export const n = 0;\n',
    'acceptance/helpers/api.ts': 'export const x = 1;\n',
    'tests/e2e/cart.spec.ts': SPEC,
    'tests/e2e/flows/cart-flow.ts': 'export async function open(steps) { await steps.click("a", "B"); }\n',
    'tests/e2e/misc/imported.ts': 'export const y = 2;\n',
    'tests/e2e/misc/unused.ts': 'export const z = 3;\n',
    'tests/e2e/uses-misc.spec.ts': `import { y } from './misc/imported';\n${SPEC}`,
    'tests/e2e/smoke.ts': SPEC,
  });
  try {
    const k = kinds(lintProject({ root, useGit: false }));
    assert.equal(k['acceptance/login.check.ts'], 'spec');
    assert.equal(k['acceptance/legacy/old.check.ts'], 'spec', 'an ignored file that declares tests is still a spec: testIgnore does not hide it from the lint');
    assert.equal(k['acceptance/legacy/notes.ts'], undefined, 'ignored non-test code nothing imports is not linted');
    assert.equal(k['acceptance/helpers/api.ts'], 'support');
    assert.equal(k['tests/e2e/cart.spec.ts'], 'spec');
    assert.equal(k['tests/e2e/flows/cart-flow.ts'], 'support');
    assert.equal(k['tests/e2e/misc/imported.ts'], 'support');
    assert.equal(k['tests/e2e/misc/unused.ts'], undefined, 'non-spec code nothing imports, outside the support folders, is not linted');
    assert.equal(k['tests/e2e/smoke.ts'], 'spec', 'a file calling test() on a test binding is a spec');
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('setup files are support only when a config project uses them as a setup project', () => {
  const root = project({
    'playwright.config.ts': "export default { testDir: 'tests', projects: [{ name: 'setup', testMatch: /auth\\.setup\\.ts/ }, { name: 'e2e', dependencies: ['setup'] }] };\n",
    'tests/e2e/auth.setup.ts': SPEC,
    'tests/e2e/seed.setup.ts': SPEC,
  });
  try {
    const k = kinds(lintProject({ root, useGit: false }));
    assert.equal(k['tests/e2e/auth.setup.ts'], 'support');
    assert.equal(k['tests/e2e/seed.setup.ts'], 'spec');
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('k6, bundles, inspect scripts, declarations and JSON', () => {
  const root = project({
    'tests/perf/load.js': "import http from 'k6/http';\nexport default function () { http.get('https://example.invalid/'); }\n",
    'tests/e2e/evidence/run-1/summary.md': '# run\n',
    'tests/e2e/evidence/run-1/probe.ts': "export const sel = '#raw';\n",
    'tests/e2e/evidence/run-2/summary.md': '# run\n',
    'tests/e2e/evidence/run-2/probe.spec.ts': RAW_SPEC,
    'tests/e2e/inspect/look.spec.ts': RAW_SPEC,
    'tests/e2e/types.d.ts': 'declare const x: number;\n',
    'tests/e2e/page-repository.json': '{}',
  });
  try {
    const report = lintProject({ root, useGit: false });
    const k = kinds(report);
    assert.equal(k['tests/perf/load.js'], 'k6');
    assert.equal(k['tests/e2e/evidence/run-1/probe.ts'], 'bundle');
    assert.equal(k['tests/e2e/evidence/run-2/probe.spec.ts'], 'spec', 'a bundle-shaped file a config would run is a spec');
    assert.equal(k['tests/e2e/inspect/look.spec.ts'], undefined);
    assert.equal(k['tests/e2e/types.d.ts'], undefined);
    assert.equal(k['tests/e2e/page-repository.json'], undefined);
    assert.ok(report.findings.some((f) => f.file === 'tests/e2e/evidence/run-2/probe.spec.ts' && f.rule === 'TB-A2'));
    assert.ok(!report.findings.some((f) => (f.file.startsWith('tests/perf/') && !/^TB-K/.test(f.rule)) || f.file.includes('/inspect/')));
    assert.deepEqual(report.findings.filter((f) => f.file.startsWith('tests/perf/')).map((f) => f.rule).sort(), ['TB-K1', 'TB-K2'], 'a k6 script gets only the k6 family');
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('a config the engine cannot evaluate is an advisory project finding; tests/** still applies', () => {
  const root = project({
    'playwright.config.ts': "export default { testDir: process.env.E2E_DIR, testMatch: makeGlob() };\n",
    'tests/e2e/cart.spec.ts': SPEC,
  });
  try {
    const report = lintProject({ root, useGit: false });
    assert.equal(kinds(report)['tests/e2e/cart.spec.ts'], 'spec');
    const scope = report.project.filter((p) => p.rule === 'scope');
    assert.equal(scope.length, 1);
    assert.equal(scope[0].severity, 'advisory');
    assert.equal(scope[0].file, 'playwright.config.ts');
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('path arguments restrict the linted files', () => {
  const root = project({ 'tests/e2e/a.spec.ts': RAW_SPEC, 'tests/e2e/b.spec.ts': RAW_SPEC });
  try {
    const report = lintProject({ root, paths: ['tests/e2e/b.spec.ts'], useGit: false });
    assert.deepEqual(report.files.map((f) => f.path), ['tests/e2e/b.spec.ts']);
    assert.ok(report.findings.every((f) => f.file === 'tests/e2e/b.spec.ts'));
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('a config-named globalSetup outside the spec roots is linted as support', () => {
  const root = project({
    'playwright.config.ts': "export default { testDir: 'tests/e2e', globalSetup: require.resolve('./global-setup'), globalTeardown: './global-teardown.ts' };\n",
    'global-setup.ts': "import { chromium } from '@playwright/test';\nexport default async function () { const b = await chromium.launch(); const p = await b.newPage(); await p.goto('/warm'); }\n",
    'global-teardown.ts': 'export default async function () {}\n',
    'tests/e2e/a.spec.ts': SPEC,
  });
  try {
    const report = lintProject({ root, useGit: false });
    const k = kinds(report);
    assert.equal(k['global-setup.ts'], 'support');
    assert.equal(k['global-teardown.ts'], 'support');
    assert.ok(report.findings.some((f) => f.file === 'global-setup.ts' && f.rule === 'TB-A12'), 'its raw calls are linted');
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('one project-level advisory counts the code files under the spec roots that are neither spec nor support', () => {
  const root = project({
    'tests/e2e/a.spec.ts': SPEC,
    'tests/e2e/misc/unused.ts': 'export const z = 3;\n',
    'tests/e2e/misc/also-unused.ts': 'export const w = 4;\n',
  });
  try {
    const report = lintProject({ root, useGit: false });
    const notes = report.project.filter((p) => p.rule === 'scope' && /neither a spec nor a support module/.test(p.message));
    assert.equal(notes.length, 1);
    assert.match(notes[0].message, /^2 code files under the spec roots are neither a spec nor a support module and are not linted: tests\/e2e\/misc\/also-unused\.ts, tests\/e2e\/misc\/unused\.ts$/);
    assert.equal(notes[0].severity, 'advisory');
  } finally { rmSync(root, { recursive: true, force: true }); }
});
