// Touched-test scope (--staged, --base), write mode (--stdin), import following and suite ids (--suite),
// the id index (--id-index [--check]) and TB-S8, through the CLI on throwaway git repositories.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import { makeAjv } from '../../scripts/lib/ajv.mjs';
import { REPO, tempRoot, writeProject } from './spec-lint-helpers.mjs';
import { parseDiff } from '../../bin/lib/spec-lint/touched.mjs';

const BIN = path.join(REPO, 'bin', 'spec-lint.mjs');
const validate = makeAjv().compile(JSON.parse(readFileSync(path.join(REPO, 'schemas', 'spec-lint-report.schema.json'), 'utf8')));
const GIT_ENV = { GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@example.invalid', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@example.invalid', GIT_CONFIG_NOSYSTEM: '1', HOME: '/nonexistent' };
const git = (root, ...a) => { const r = spawnSync('git', ['-C', root, ...a], { encoding: 'utf8', env: { ...process.env, ...GIT_ENV } }); assert.equal(r.status, 0, r.stderr); return r.stdout; };
const run = (root, args, input) => spawnSync(process.execPath, [BIN, ...args], { cwd: root, encoding: 'utf8', input, env: { ...process.env, CLAUDE_PROJECT_DIR: root, CIVITAS_TEST_ID_PATTERN: '' } });
const json = (r) => { const o = JSON.parse(r.stdout); assert.ok(validate(o), JSON.stringify(validate.errors)); return o; };

const SPEC = [
  "import { test } from './fixtures/base';",
  '',
  "test('TCAB-0001 · first', async ({ page, steps }) => {",
  "  await page.goto('/one');",
  "  await steps.verifyPresence('heading', 'HomePage');",
  '});',
  '',
  "test('TCAB-0002 · second', async ({ page, steps }) => {",
  "  await page.goto('/two');",
  "  await steps.verifyPresence('heading', 'HomePage');",
  '});',
  '',
].join('\n');

function repo(files, opts) {
  const root = tempRoot();
  writeProject(root, files, opts);
  git(root, 'init', '-q', '-b', 'main');
  git(root, 'add', '-A');
  git(root, 'commit', '-q', '-m', 'base');
  return root;
}

test('parseDiff reads new-side line ranges, new files, deletions and renames', () => {
  const d = parseDiff([
    'diff --git a/a.ts b/a.ts', '--- a/a.ts', '+++ b/a.ts', '@@ -3,0 +4,2 @@', '+x', '+y', '@@ -9 +11,0 @@', '-z',
    'diff --git a/n.ts b/n.ts', 'new file mode 100644', '--- /dev/null', '+++ b/n.ts', '@@ -0,0 +1 @@', '+n',
    'diff --git a/o.ts b/p.ts', 'similarity index 90%', 'rename from o.ts', 'rename to p.ts', '--- a/o.ts', '+++ b/p.ts', '@@ -1 +1 @@', '-a', '+b',
  ].join('\n'));
  assert.deepEqual([...d.get('a.ts').lines].sort((x, y) => x - y), [4, 5, 11, 12]);
  assert.equal(d.get('n.ts').lines, null);
  assert.equal(d.get('p.ts').status, 'R');
});

test('--staged: only the touched test is charged; the untouched one is legacy', () => {
  const root = repo({ 'tests/e2e/a.spec.ts': SPEC });
  try {
    writeFileSync(path.join(root, 'tests/e2e/a.spec.ts'), SPEC.replace("  await page.goto('/two');", "  await page.goto('/two');\n  await page.reload();"));
    git(root, 'add', 'tests/e2e/a.spec.ts');
    const r = run(root, ['--staged', '--json']);
    assert.equal(r.status, 1);
    const rep = json(r);
    const a2 = rep.findings.filter((f) => f.rule === 'TB-A2');
    assert.deepEqual(a2.map((f) => [f.line, f.touched]), [[4, false], [9, true], [10, true]]);
    assert.equal(rep.summary.blocking, 2);
    assert.equal(rep.summary.legacy, 1);
    assert.deepEqual(rep.change.files, ['tests/e2e/a.spec.ts']);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('--staged: a change confined to a clean test passes although the file has legacy findings; staged content is linted', () => {
  const clean = "test('TCAB-0003 · third', async ({ steps }) => {\n  await steps.navigateTo('/three');\n  await steps.verifyPresence('heading', 'HomePage');\n});\n";
  const root = repo({ 'tests/e2e/a.spec.ts': SPEC });
  try {
    writeFileSync(path.join(root, 'tests/e2e/a.spec.ts'), `${SPEC}${clean}`);
    git(root, 'add', 'tests/e2e/a.spec.ts');
    // an unstaged edit that would add a finding in the new test is not part of the staged change
    writeFileSync(path.join(root, 'tests/e2e/a.spec.ts'), `${SPEC}${clean.replace("await steps.navigateTo('/three');", "await page.goto('/three');")}`);
    const r = run(root, ['--staged']);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /0 blocking, .* 2 legacy; .*change: the index against HEAD/);
    assert.match(r.stderr, /legacy: not in a touched test/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('--staged: a version gap blocks in a touched test and stays advisory in an untouched one', () => {
  const old = SPEC.replace(/page\.goto\('\/(one|two)'\)/g, "page.evaluate(() => document.title.length > 0)");
  const root = repo({ 'tests/e2e/a.spec.ts': old }, { pin: '0.3.3' });
  try {
    writeFileSync(path.join(root, 'tests/e2e/a.spec.ts'), old.replace("test('TCAB-0002 · second'", "test('TCAB-0002 · second, reworded'"));
    git(root, 'add', '-A');
    const rep = json(run(root, ['--staged', '--json']));
    const a13 = rep.findings.filter((f) => f.rule === 'TB-A13').map((f) => [f.line, f.severity, f.touched]);
    assert.deepEqual(a13, [[4, 'advisory', false], [9, 'blocking', true]]);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('--staged: a top-level change touches the file scope; TB-S8 refuses a staged inspect script', () => {
  const root = repo({ 'tests/e2e/a.spec.ts': SPEC });
  try {
    writeFileSync(path.join(root, 'tests/e2e/a.spec.ts'), `import { test as raw } from '@playwright/test';\n${SPEC}`);
    writeProject(root, { 'tests/e2e/inspect/probe.spec.ts': "import { test } from '@playwright/test';\n" });
    git(root, 'add', '-A');
    const rep = json(run(root, ['--staged', '--json']));
    const a7 = rep.findings.find((f) => f.rule === 'TB-A7');
    assert.equal(a7.touched, true);
    assert.equal(rep.findings.filter((f) => f.rule === 'TB-A2').every((f) => f.touched === false), true, 'an import line touches no test');
    const s8 = rep.findings.find((f) => f.rule === 'TB-S8');
    assert.equal(s8.file, 'tests/e2e/inspect/probe.spec.ts');
    assert.equal(s8.severity, 'blocking');
    assert.equal(rep.ok, false);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('--base <ref>: the working tree and untracked files against the merge-base', () => {
  const root = repo({ 'tests/e2e/a.spec.ts': SPEC });
  try {
    git(root, 'checkout', '-q', '-b', 'feature');
    writeProject(root, { 'tests/e2e/b.spec.ts': "import { test } from './fixtures/base';\ntest('TCAB-0009 · new', async ({ page }) => {\n  await page.goto('/new');\n});\n" });
    const rep = json(run(root, ['--base', 'main', '--json']));
    assert.deepEqual(rep.files.map((f) => f.path), ['tests/e2e/b.spec.ts']);
    assert.ok(rep.findings.some((f) => f.rule === 'TB-A2' && f.touched === true));
    assert.equal(run(root, ['--base', 'no-such-ref']).status, 2);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('--staged outside a git work tree exits 2; --staged with --base is a usage error', () => {
  const root = tempRoot();
  try {
    writeProject(root, { 'tests/e2e/a.spec.ts': SPEC });
    const r = run(root, ['--staged']);
    assert.equal(r.status, 2);
    assert.match(r.stderr, /is not a git work tree/);
    assert.equal(run(root, ['--staged', '--base', 'main']).status, 2);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('--stdin reports only the findings new in "after"', () => {
  const root = tempRoot();
  try {
    writeProject(root, { 'tests/e2e/a.spec.ts': SPEC });
    const after = SPEC.replace("  await page.goto('/two');", "  await page.goto('/two');\n  await page.waitForTimeout(500);");
    const r = run(root, ['--stdin', '--json'], JSON.stringify({ file: 'tests/e2e/a.spec.ts', before: SPEC, after }));
    assert.equal(r.status, 1);
    const rep = json(r);
    assert.deepEqual(rep.findings.map((f) => `${f.rule}:${f.line}`), ['TB-F5:10']);
    const fresh = run(root, ['--stdin', '--json'], JSON.stringify({ file: 'tests/e2e/new.spec.ts', before: null, after: SPEC }));
    assert.ok(json(fresh).findings.filter((f) => f.rule === 'TB-A2').length === 2, 'a new file: every finding is new');
    assert.equal(run(root, ['--stdin'], 'not json').status, 2);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('--suite follows the imports of the linted specs and checks ids across files', () => {
  const root = tempRoot();
  try {
    writeProject(root, {
      'tests/e2e/a.spec.ts': "import { test } from './fixtures/base';\nimport { openCart } from './helpers/cart';\ntest('TCAB-0001 · a', async ({ steps }) => {\n  await openCart(steps);\n  await steps.verifyPresence('cart', 'CartPage');\n});\n",
      'tests/e2e/b.spec.ts': "import { test } from './fixtures/base';\ntest('TCAB-0001 · b', async ({ steps }) => {\n  await steps.verifyPresence('cart', 'CartPage');\n});\n",
      'tests/e2e/helpers/cart.ts': "import type { Steps } from '@civitas-cerebrum/element-interactions';\nexport async function openCart(steps: Steps) {\n  await (steps as any).page.goto('/cart');\n}\n",
    });
    const plain = json(run(root, ['tests/e2e/a.spec.ts', '--json']));
    assert.deepEqual(plain.files.map((f) => f.path), ['tests/e2e/a.spec.ts']);
    const rep = json(run(root, ['tests/e2e/a.spec.ts', '--suite', '--json']));
    assert.deepEqual(rep.files.map((f) => [f.path, f.followedFrom || null]), [['tests/e2e/a.spec.ts', null], ['tests/e2e/helpers/cart.ts', 'tests/e2e/a.spec.ts']]);
    assert.ok(rep.findings.some((f) => f.file === 'tests/e2e/helpers/cart.ts' && f.rule === 'TB-A14' && f.followedFrom === 'tests/e2e/a.spec.ts'));
    const i2 = rep.findings.filter((f) => f.rule === 'TB-I2');
    assert.deepEqual(i2.map((f) => [f.file, f.line]), [['tests/e2e/a.spec.ts', 3]]);
    assert.match(i2[0].message, /also used by tests\/e2e\/b\.spec\.ts:2/);
    assert.deepEqual(rep.ids.map((x) => x.id), ['TCAB-0001', 'TCAB-0001']);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('--id-index writes the index; --check passes when it lists every id and fails when one is missing', () => {
  const root = tempRoot();
  try {
    writeProject(root, {
      'tests/e2e/a.spec.ts': "import { test } from './fixtures/base';\ntest('TCAB-0001 · a', async ({ steps }) => {\n  await steps.verifyPresence('cart', 'CartPage');\n});\n",
      'tests/e2e/b.spec.ts': "import { test } from './fixtures/base';\ntest('TCAB-0002 · b | c', async ({ steps }) => {\n  await steps.verifyPresence('cart', 'CartPage');\n});\n",
    });
    assert.equal(run(root, ['--id-index', '--check']).status, 1, 'no index yet');
    const w = run(root, ['--id-index']);
    assert.equal(w.status, 0, w.stderr);
    const index = readFileSync(path.join(root, 'tests/e2e/docs/test-ids.md'), 'utf8');
    assert.match(index, /\| TCAB-0001 \| a \| `tests\/e2e\/a\.spec\.ts` \|/);
    assert.match(index, /\| TCAB-0002 \| b \\\| c \|/);
    assert.equal(run(root, ['--id-index', '--check']).status, 0);
    writeProject(root, { 'tests/e2e/c.spec.ts': "import { test } from './fixtures/base';\ntest('TCAB-0003 · c', async ({ steps }) => {\n  await steps.verifyPresence('cart', 'CartPage');\n});\n" });
    const c = run(root, ['--id-index', '--check']);
    assert.equal(c.status, 1);
    assert.match(c.stderr, /not listed: TCAB-0003/);
    const suite = json(run(root, ['--suite', '--json']));
    assert.ok(suite.findings.some((f) => f.rule === 'TB-I2' && f.file === 'tests/e2e/c.spec.ts' && /not in the id index/.test(f.message)));
    assert.ok(existsSync(path.join(root, 'tests/e2e/docs/test-ids.md')));
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('--staged: editing the table a loop iterates touches the tests it generates', () => {
  const spec = "import { test } from './fixtures/base';\nconst SIZES = ['S', 'M'];\nfor (const s of SIZES) {\n  test(`TCAB-01${s} · size ${s}`, async ({ steps }) => {\n    await steps.click(s, 'ProductPage');\n  });\n}\n";
  const root = repo({ 'tests/e2e/a.spec.ts': spec });
  try {
    writeFileSync(path.join(root, 'tests/e2e/a.spec.ts'), spec.replace("['S', 'M']", "['S', 'M', 'L']"));
    git(root, 'add', '-A');
    const s1 = json(run(root, ['--staged', '--json'])).findings.filter((f) => f.rule === 'TB-S1');
    assert.deepEqual(s1.map((f) => f.touched), [true]);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('--staged: a change outside the tests that takes no user away leaves a helper finding legacy', () => {
  const spec = "import { test } from './fixtures/base';\nasync function open(steps) {\n  await steps.click('a', 'HomePage');\n}\n\ntest('TCAB-0001 · one', async ({ steps }) => {\n  await open(steps);\n});\n";
  const root = repo({ 'tests/e2e/a.spec.ts': spec });
  try {
    writeFileSync(path.join(root, 'tests/e2e/a.spec.ts'), `// the header comment changed\n${spec}const ROWS = ['a'];\n`);
    git(root, 'add', '-A');
    const s2 = json(run(root, ['--staged', '--json'])).findings.filter((f) => f.rule === 'TB-S2');
    assert.deepEqual(s2.map((f) => [f.line, f.touched]), [[3, false]]);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('--staged: removing the second user of an in-spec helper charges the helper', () => {
  const spec = "import { test } from './fixtures/base';\nasync function open(steps) {\n  await steps.click('a', 'HomePage');\n}\n\ntest('TCAB-0001 · one', async ({ steps }) => {\n  await open(steps);\n});\n\ntest('TCAB-0002 · two', async ({ steps }) => {\n  await open(steps);\n});\n";
  const root = repo({ 'tests/e2e/a.spec.ts': spec });
  try {
    writeFileSync(path.join(root, 'tests/e2e/a.spec.ts'), spec.replace("\ntest('TCAB-0002 · two', async ({ steps }) => {\n  await open(steps);\n});\n", ''));
    git(root, 'add', '-A');
    const s2 = json(run(root, ['--staged', '--json'])).findings.filter((f) => f.rule === 'TB-S2');
    assert.deepEqual(s2.map((f) => [f.line, f.touched]), [[2, true]]);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('--stdin: a version gap in a new or edited test blocks; in an untouched test it is not reported', () => {
  const root = tempRoot();
  try {
    const old = SPEC.replace(/page\.goto\('\/(one|two)'\)/g, 'page.evaluate(() => document.title.length > 0)');
    writeProject(root, { 'tests/e2e/a.spec.ts': old }, { pin: '0.3.3' });
    const after = old.replace("  await steps.verifyPresence('heading', 'HomePage');\n});\n\ntest('TCAB-0002", "  await steps.verifyPresence('heading', 'HomePage');\n  await steps.verifyPresence('footer', 'HomePage');\n});\n\ntest('TCAB-0002");
    const rep = json(run(root, ['--stdin', '--json'], JSON.stringify({ file: 'tests/e2e/a.spec.ts', before: old, after })));
    assert.deepEqual(rep.findings.filter((f) => f.rule === 'TB-A13').map((f) => [f.line, f.severity]), [[4, 'blocking']]);
    assert.equal(rep.ok, false);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('--id-index keeps retired ids; --check accepts them and refuses one in use again', () => {
  const root = tempRoot();
  const one = (id) => `import { test } from './fixtures/base';\ntest('${id} · a', async ({ steps }) => {\n  await steps.verifyPresence('cart', 'CartPage');\n});\n`;
  try {
    writeProject(root, { 'tests/e2e/a.spec.ts': one('TCAB-0001'), 'tests/e2e/b.spec.ts': one('TCAB-0002') });
    assert.equal(run(root, ['--id-index']).status, 0);
    rmSync(path.join(root, 'tests/e2e/b.spec.ts'));
    assert.equal(run(root, ['--id-index', '--check']).status, 1, 'a listed id no longer in use must be retired');
    assert.equal(run(root, ['--id-index']).status, 0);
    const index = readFileSync(path.join(root, 'tests/e2e/docs/test-ids.md'), 'utf8');
    assert.match(index, /## Retired[\s\S]*\| TCAB-0002 \|/);
    assert.equal(run(root, ['--id-index', '--check']).status, 0, 'retired ids are accepted');
    writeProject(root, { 'tests/e2e/c.spec.ts': one('TCAB-0002') });
    const c = run(root, ['--id-index', '--check']);
    assert.equal(c.status, 1);
    assert.match(c.stderr, /retired ids in use again: TCAB-0002/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('--staged and --base without git on PATH say git was not found (exit 2)', () => {
  const root = tempRoot();
  try {
    writeProject(root, { 'tests/e2e/a.spec.ts': SPEC });
    const env = { ...process.env, CLAUDE_PROJECT_DIR: root, PATH: path.dirname(process.execPath) };
    for (const args of [['--staged'], ['--base', 'main']]) {
      const r = spawnSync(process.execPath, [BIN, ...args], { cwd: root, encoding: 'utf8', env });
      assert.equal(r.status, 2, r.stderr);
      assert.match(r.stderr, /git was not found on PATH/);
    }
  } finally { rmSync(root, { recursive: true, force: true }); }
});
