// Per-rule fixtures of achilles-spec-lint: every fixture under tests/bin/fixtures/spec-lint/<rule-id>/ and
// bindings/ produces exactly the findings its markers name (see spec-lint-helpers.mjs for the grammar).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, statSync } from 'node:fs';
import path from 'node:path';
import { lintProject } from '../../bin/lib/spec-lint/engine.mjs';
import { FIXTURES, loadFixture, compare, tempRoot, writeProject } from './spec-lint-helpers.mjs';
import { rmSync } from 'node:fs';

const dirs = readdirSync(FIXTURES).filter((d) => /^TB-|^bindings$/.test(d) && statSync(path.join(FIXTURES, d)).isDirectory()).sort();

// The mechanical rules of this engine: each needs at least two compliant and two non-compliant fixtures.
const MECHANICAL = ['TB-A1', 'TB-A2', 'TB-A2b', 'TB-A3', 'TB-A4', 'TB-A5', 'TB-A7', 'TB-A9', 'TB-A10', 'TB-A11', 'TB-A12', 'TB-A13', 'TB-A14', 'TB-G0', 'TB-G1'];

test('no fixture is stored with a code extension (TypeScript tooling over the repository must not load them)', () => {
  const walk = (d) => readdirSync(d).flatMap((f) => (statSync(path.join(d, f)).isDirectory() ? walk(path.join(d, f)) : [path.join(d, f)]));
  assert.deepEqual(walk(FIXTURES).filter((f) => /\.(?:[cm]?[jt]sx?)$/.test(f)).map((f) => path.relative(FIXTURES, f)), []);
});

test('every mechanical rule has at least two compliant and two non-compliant fixtures', () => {
  for (const rule of MECHANICAL) {
    assert.ok(dirs.includes(rule), `fixture directory ${rule} missing`);
    const names = readdirSync(path.join(FIXTURES, rule));
    assert.ok(names.filter((n) => n.startsWith('ok-')).length >= 2, `${rule}: fewer than two compliant fixtures`);
    assert.ok(names.filter((n) => n.startsWith('bad-')).length >= 2, `${rule}: fewer than two non-compliant fixtures`);
  }
});

for (const dir of dirs) {
  for (const name of readdirSync(path.join(FIXTURES, dir)).filter((n) => /^(ok|bad)-/.test(n)).sort()) {
    test(`${dir}/${name}`, () => {
      const fx = loadFixture(path.join(FIXTURES, dir, name), dir);
      try {
        const report = lintProject({ root: fx.root });
        assert.deepEqual(compare(report, fx), []);
        if (name.startsWith('ok-')) {
          const blocking = report.findings.filter((f) => fx.rules.includes(f.rule) && f.severity === 'blocking' && !f.waived);
          assert.deepEqual(blocking.map((f) => `${f.rule} ${f.file}:${f.line}`), [], 'a compliant fixture has no unwaived blocking finding of its rules');
        }
      } finally { fx.cleanup(); }
    });
  }
}

test('a register row\'s waiver cap counts every in-scope file, also when only some paths are linted', () => {
  const root = tempRoot();
  const waived = (id) => `import { test } from './fixtures/base';\ntest('${id} · x', async ({ page }) => {\n  // achilles-allow TB-A2 -- the bring-to-front call has no Steps form [gap: FG-8]\n  await page.bringToFront();\n});\n`;
  try {
    writeProject(root, {
      'tests/e2e/docs/framework-gaps.md': '| Row | Missing capability | Raw methods covered | Waiver cap | Status | Upstream issue |\n|---|---|---|---|---|---|\n| FG-8 | window focus | `page.emulateMedia` | 1 | open | |\n',
      'tests/e2e/a.spec.ts': waived('TC-1').replace('bringToFront()', "emulateMedia({ colorScheme: 'dark' })"),
      'tests/e2e/b.spec.ts': waived('TC-2').replace('bringToFront()', "emulateMedia({ colorScheme: 'dark' })"),
    });
    const report = lintProject({ root, paths: ['tests/e2e/b.spec.ts'], useGit: false });
    assert.ok(report.findings.some((f) => f.rule === 'TB-G1' && f.file === 'tests/e2e/b.spec.ts' && /allows 1 waiver/.test(f.message)), JSON.stringify(report.findings.map((f) => `${f.rule} ${f.file}:${f.line} ${f.message}`)));
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('every member call on a driver binding gets exactly one classification', async () => {
  const { classifyRaw } = await import('../../bin/lib/spec-lint/rules/framework.mjs');
  const { loadEquivalents } = await import('../../bin/lib/spec-lint/equivalents.mjs');
  const KNOWN = new Set(['locator', 'chain', 'accessor', 'sleep', 'eval', 'noeq', 'http', 'equiv', 'unlisted', 'computed']);
  const eq = loadEquivalents();
  const methods = new Set([...Object.keys(eq.methods), ...Object.keys(eq.http), ...eq.evaluate.methods, ...eq.noEquivalent.flatMap((e) => e.methods), 'locator', 'getByRole', 'first', 'context', 'waitForTimeout', 'emulateMedia', 'tap', 'fetch']);
  const kinds = ['page', 'frame', 'context', 'browser', 'request', 'locator', 'input'];
  const args = [[], [{ type: 'StringLiteral', value: 'popup' }], [{ type: 'StringLiteral', value: 'requestfailed' }], [{ type: 'Identifier', name: 'x' }]];
  for (const kind of kinds) for (const method of methods) for (const a of args) {
    const callee = { type: 'MemberExpression', object: { type: 'Identifier', name: 'drv' }, property: { type: 'Identifier', name: method }, computed: false };
    const ctx = { kind: (e) => (e && e.type === 'Identifier' && e.name === 'drv' ? kind : null), project: { equivalents: eq } };
    const c = classifyRaw({ type: 'CallExpression', callee, arguments: a }, ctx);
    assert.ok(c && KNOWN.has(c.cat), `${kind}.${method}(${a.map((x) => x.value || x.name).join()}) -> ${c && c.cat}`);
  }
});

test('a Playwright globalSetup module and a setup-named file declaring no tests are not specs', () => {
  const root = tempRoot();
  try {
    writeProject(root, {
      'playwright.config.ts': "export default { testDir: 'tests/e2e', globalSetup: './tests/e2e/playwright.setup.ts', globalTeardown: require.resolve('./tests/e2e/teardown.ts') };\n",
      'tests/e2e/playwright.setup.ts': "export default async function globalSetup() { process.env.READY = '1'; }\n",
      'tests/e2e/teardown.ts': 'export default async function () {}\n',
      'tests/e2e/seed.setup.ts': 'export const seed = 1;\n',
      'tests/e2e/a.spec.ts': "import { test } from './fixtures/base';\ntest('TC-1 · x', async ({ steps }) => { await steps.navigateTo('/'); });\n",
    });
    const kinds = Object.fromEntries(lintProject({ root, useGit: false }).files.map((f) => [f.path, f.kind]));
    assert.equal(kinds['tests/e2e/playwright.setup.ts'], 'support');
    assert.equal(kinds['tests/e2e/teardown.ts'], 'support');
    assert.equal(kinds['tests/e2e/seed.setup.ts'], undefined);
    assert.equal(kinds['tests/e2e/a.spec.ts'], 'spec');
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('messages name the normalised callee, the actual receiver and the installed Steps options', () => {
  const root = tempRoot();
  try {
    writeProject(root, {
      'tests/e2e/a.spec.ts': "import { test } from './fixtures/base';\ntest('TC-1 · x', async ({ page }) => {\n  const frame = page.mainFrame();\n  await page\n    .waitForResponse('**/api');\n  await frame.getByTestId('save').click();\n  await page.evaluate(() => window.scrollY);\n});\n",
    });
    const f = lintProject({ root, useGit: false }).findings;
    const msg = (rule, line) => (f.find((x) => x.rule === rule && x.line === line) || {}).message || '';
    assert.match(msg('TB-A2', 4), /`page\.waitForResponse`/);
    assert.match(msg('TB-A5', 6), /`frame\.getByTestId\(…\)`/);
    assert.match(msg('TB-A4', 7), /steps\.evaluateScript/);
    assert.doesNotMatch(msg('TB-A4', 7), /installed release has steps\.getLocalStorage/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
