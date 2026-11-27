// Per-rule fixtures of achilles-spec-lint: every fixture under tests/bin/fixtures/spec-lint/<rule-id>/ and
// bindings/ produces exactly the findings its markers name (see spec-lint-helpers.mjs for the grammar).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { lintProject } from '../../bin/lib/spec-lint/engine.mjs';
import { FIXTURES, REPO, loadFixture, compare, tempRoot, writeProject } from './spec-lint-helpers.mjs';
import { ruleKinds, DEFERRED } from '../../scripts/lint/test-baseline.mjs';
import { rmSync } from 'node:fs';

const dirs = readdirSync(FIXTURES).filter((d) => /^TB-|^bindings$/.test(d) && statSync(path.join(FIXTURES, d)).isDirectory()).sort();

// The mechanical rules of the rulebook the engine implements (every Kind that is mechanical in whole or in
// part, except the deferred ones): each needs at least two compliant and two non-compliant fixtures.
const MECHANICAL = ruleKinds(readFileSync(path.join(REPO, 'skills/achilles-orchestrator/references/test-baseline.md'), 'utf8'))
  .filter((r) => /mechanical/.test(r.kind || '') && !DEFERRED[r.id]).map((r) => r.id);

test('no fixture is stored with a code extension (TypeScript tooling over the repository must not load them)', () => {
  const walk = (d) => readdirSync(d).flatMap((f) => (statSync(path.join(d, f)).isDirectory() ? walk(path.join(d, f)) : [path.join(d, f)]));
  assert.deepEqual(walk(FIXTURES).filter((f) => /\.(?:[cm]?[jt]sx?)$/.test(f)).map((f) => path.relative(FIXTURES, f)), []);
});

test('every fixture file is committable (none is ignored by the repository) and stored dot-paths materialise', () => {
  const walk = (d) => readdirSync(d).flatMap((f) => (statSync(path.join(d, f)).isDirectory() ? walk(path.join(d, f)) : [path.join(d, f)]));
  const files = walk(FIXTURES).map((f) => path.relative(REPO, f));
  const r = spawnSync('git', ['-C', REPO, 'check-ignore', '--stdin'], { input: files.join('\n'), encoding: 'utf8' });
  if (r.status !== 128) assert.equal(r.stdout.trim(), '', 'fixture files the repository ignores (they would be missing from a clean checkout)');
  for (const name of ['bad-2-unresolvable', 'ok-2-path-anchor-and-defect-id']) {
    const fx = loadFixture(path.join(FIXTURES, 'TB-I4', name), 'TB-I4');
    try { assert.ok(existsSync(path.join(fx.root, '.achilles', 'defect-confirmations')), `${name}: .achilles/defect-confirmations is materialised`); } finally { fx.cleanup(); }
  }
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
        const report = lintProject({ root: fx.root, ...fx.options });
        assert.deepEqual(compare(report, fx), []);
        if (name.startsWith('ok-')) {
          const blocking = report.findings.filter((f) => fx.rules.includes(f.rule) && f.severity === 'blocking' && !f.waived && f.touched !== false);
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
      'tests/e2e/a.spec.ts': "import { test } from './fixtures/base';\ntest('TC-1 · x', async ({ page }) => {\n  const frame = page.mainFrame();\n  await page\n    .waitForResponse('**/api');\n  await frame.getByTestId('save').click();\n  await page.evaluate(() => window.scrollY);\n  await page.evaluate(() => document.body.scrollHeight > 10);\n  await page.evaluate(() => localStorage.getItem('k'));\n});\n",
    });
    const f = lintProject({ root, useGit: false }).findings;
    const msg = (rule, line) => (f.find((x) => x.rule === rule && x.line === line) || {}).message || '';
    assert.match(msg('TB-A2', 4), /`page\.waitForResponse`/);
    assert.match(msg('TB-A5', 6), /`frame\.getByTestId\(…\)`/);
    assert.match(msg('TB-A4', 7), /steps\.getWindowProperty/);
    assert.match(msg('TB-A4', 8), /has steps\.evaluateScript$/);
    assert.doesNotMatch(msg('TB-A4', 8), /getLocalStorage|getWindowProperty|getAttribute/);
    assert.match(msg('TB-A4', 9), /has steps\.getLocalStorage$/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('TB-F7 marks the narrow form: the result is discarded and no later check reads the same element', () => {
  const root = tempRoot();
  try {
    writeProject(root, { 'tests/e2e/a.spec.ts': [
      "import { test } from './fixtures/base';",
      "test('TCAB-0701 · optional members', async ({ steps }) => {",
      "  await steps.clickIfPresent('acceptCookies', 'HomePage');",
      "  await steps.clickIfPresent('promoClose', 'HomePage');",
      "  const shown = await steps.clickIfPresent('survey', 'HomePage');",
      "  await steps.on('banner', 'HomePage').ifVisible().click();",
      "  await steps.waitForState('toast', 'HomePage', 'visible', { optional: true });",
      "  if (shown) await steps.click('surveyClose', 'HomePage');",
      "  await steps.verifyAbsence('promoClose', 'HomePage');",
      "  await steps.on('banner', 'HomePage').text.toBe('');",
      '});',
      '',
    ].join('\n') });
    const report = lintProject({ root, useGit: false });
    const f7 = Object.fromEntries(report.findings.filter((f) => f.rule === 'TB-F7').map((f) => [f.line, f]));
    assert.deepEqual(Object.keys(f7).map(Number), [3, 4, 5, 6, 7]);
    assert.ok(Object.values(f7).every((f) => f.severity === 'advisory'));
    assert.deepEqual(Object.entries(f7).filter(([, f]) => f.data && f.data.narrow).map(([l]) => Number(l)), [3, 7], 'discarded and never checked again');
    assert.match(f7[3].message, /no later check reads `acceptCookies` on `HomePage` \(the narrow form, advisory: unmeasured\)$/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('TB-X4: only an exit guarded by a counter the loop steps, or by a deadline, bounds a forever loop', () => {
  const root = tempRoot();
  try {
    writeProject(root, { 'tests/e2e/flows/f.ts': [
      "import type { Steps } from '@civitas-cerebrum/element-interactions';",
      'export async function a(steps: Steps, limit: number) {',
      '  let n = 0;',
      "  while (true) { if (n++ >= limit) throw new Error('x'); await steps.click('b', 'P'); }",
      '}',
      'export async function b(steps: Steps) {',
      '  const started = performance.now();',
      "  do { await steps.click('b', 'P'); if (performance.now() - started > 9000) break; } while (true);",
      '}',
      'export async function c(steps: Steps) {',
      "  for (;;) { for (const x of [1, 2]) { if (x > 1) break; } await steps.click('b', 'P'); }",
      '}',
      'export async function d(steps: Steps, maxTries: number) {',
      "  while (1) { if (maxTries > 2) break; await steps.click('b', 'P'); }",
      '}',
      '',
    ].join('\n') });
    const report = lintProject({ root, useGit: false });
    const x4 = report.findings.filter((f) => f.rule === 'TB-X4');
    assert.deepEqual(x4.map((f) => f.line), [11, 14], x4.map((f) => f.message).join('\n'));
    assert.ok(x4.every((f) => f.severity === 'advisory' && f.data.shape === 'forever'));
    assert.match(x4[0].message, /^`for \(;;\)` without a counter or deadline that ends it/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('TB-X4: x = x ± k steps a counter; += 0, a reset counter or a reset deadline do not; a deadline helper guards; a state-only for is reported', () => {
  const root = tempRoot();
  try {
    writeProject(root, { 'tests/e2e/flows/g.ts': [
      "import type { Steps } from '@civitas-cerebrum/element-interactions';",
      "function assertBefore(deadline: number) { if (Date.now() > deadline) throw new Error('late'); }",
      'const expired = (deadline: number) => Date.now() > deadline;',
      'export async function stepped(steps: Steps) {',
      "  let n = 0; while (true) { n = n + 1; if (n > 5) throw new Error('x'); await steps.click('b', 'P'); }",
      '}',
      'export async function zero(steps: Steps) {',
      "  let n = 0; while (true) { n += 0; if (n > 5) break; await steps.click('b', 'P'); }",
      '}',
      'export async function reset(steps: Steps) {',
      "  let n = 0; while (true) { n++; if (n > 5) break; n = 0; await steps.click('b', 'P'); }",
      '}',
      'export async function movingDeadline(steps: Steps) {',
      "  let end = Date.now() + 5000; while (true) { end = Date.now() + 5000; if (Date.now() > end) break; await steps.click('b', 'P'); }",
      '}',
      'export async function helper(steps: Steps) {',
      "  const end = Date.now() + 5000; while (true) { assertBefore(end); await steps.click('b', 'P'); }",
      '}',
      'export async function guardHelper(steps: Steps) {',
      "  const end = Date.now() + 5000; while (true) { if (expired(end)) break; await steps.click('b', 'P'); }",
      '}',
      'export async function stateFor(steps: Steps) {',
      "  for (; await steps.isVisible('more', 'P');) await steps.click('more', 'P');",
      '}',
      '',
    ].join('\n') });
    const report = lintProject({ root, useGit: false });
    const x4 = report.findings.filter((f) => f.rule === 'TB-X4').map((f) => [f.line, f.data.shape]);
    assert.deepEqual(x4, [[8, 'forever'], [11, 'forever'], [14, 'forever'], [23, 'state']], JSON.stringify(report.findings.filter((f) => f.rule === 'TB-X4').map((f) => f.message)));
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('TB-A6 reads the repository only inside the work tree, as a bounded regular file, and never echoes foreign content', async () => {
  const { symlinkSync, mkdirSync, writeFileSync } = await import('node:fs');
  const outer = tempRoot();
  // a decoy outside the project: its names must never appear in a message
  const decoy = path.join(outer, 'outside');
  mkdirSync(decoy, { recursive: true });
  writeFileSync(path.join(decoy, 'x.json'), JSON.stringify({ pages: [{ name: 'DecoyPage', elements: [{ elementName: 'decoyElementName' }] }] }));
  const spec = "import { test } from './fixtures/base';\ntest('TCAB-0801 · x', async ({ steps }) => { await steps.click('decoyElementNam', 'DecoyPage'); });\n";
  const base = (arg, extra = '') => `import { test as base } from '@playwright/test';\nimport { baseFixture } from '@civitas-cerebrum/element-interactions';\n${extra}export const test = baseFixture(base, ${arg});\n`;
  const lint = (files, prep) => {
    const root = path.join(outer, `p${Math.random().toString(36).slice(2)}`);
    writeProject(root, { 'tests/e2e/a.spec.ts': spec, ...files });
    if (prep) prep(root);
    const r = lintProject({ root, useGit: false });
    return { a6: r.findings.filter((f) => f.rule === 'TB-A6'), project: r.project.filter((p) => p.rule === 'TB-A6').map((p) => p.message), all: JSON.stringify(r) };
  };
  try {
    const cases = [
      [{ 'tests/e2e/fixtures/base.ts': base("'../outside/x.json'") }, null, /leaves the work tree/],
      [{ 'tests/e2e/fixtures/base.ts': base(`'${path.join(decoy, 'x.json')}'`) }, null, /leaves the work tree/],
      [{ 'tests/e2e/fixtures/base.ts': base("'tests/e2e/repo.json'") }, (r) => symlinkSync(path.join(decoy, 'x.json'), path.join(r, 'tests/e2e/repo.json')), /leaves the work tree through a symbolic link/],
      [{ 'tests/e2e/fixtures/base.ts': base('pages', "import pages from '../../../../outside/x.json';\n") }, null, /leaves the work tree/],
      [{ 'tests/e2e/fixtures/base.ts': base("'tests/e2e/repo.json'") }, (r) => mkdirSync(path.join(r, 'tests/e2e/repo.json')), /is not a regular file/],
      [{ 'tests/e2e/fixtures/base.ts': base("'tests/e2e/repo.json'"), 'tests/e2e/repo.json': ' '.repeat(9 * 1024 * 1024) }, null, /larger than 8 MB/],
      [{ 'tests/e2e/fixtures/base.ts': base("'tests/e2e/repo.json'"), 'tests/e2e/repo.json': '{"pages": [ {"name": "SecretishPage", oops' }, null, /^tests\/e2e\/fixtures\/base\.ts: the page repository tests\/e2e\/repo\.json is not valid JSON( \(at position \d+\))?; /],
    ];
    for (const [files, prep, want] of cases) {
      const r = lint(files, prep);
      assert.deepEqual(r.a6, [], 'nothing is checked against it');
      assert.equal(r.project.length, 1, JSON.stringify(r.project));
      assert.match(r.project[0], want);
      assert.doesNotMatch(r.all, /decoyElementName|SecretishPage|oops/, 'no content of the file appears in the report');
    }
  } finally { rmSync(outer, { recursive: true, force: true }); }
});
