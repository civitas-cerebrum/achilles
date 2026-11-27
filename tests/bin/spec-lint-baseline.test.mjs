// The compliance baseline, the ratchet and the pre-commit check (achilles-spec-lint --init-baseline,
// --update-baseline [--ruleset-upgrade], --ratchet --base, --ci, --pre-commit, --install-hook), on throwaway
// git repositories. The pre-commit cases commit through git itself, so the installed hook is what runs.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync, unlinkSync } from 'node:fs';
import path from 'node:path';
import { makeAjv } from '../../scripts/lib/ajv.mjs';
import { REPO, tempRoot, writeProject } from './spec-lint-helpers.mjs';
import { ratchet, updateBaseline, checkCopy, recount, inferIdPattern, parseBaseline, serialize } from '../../bin/lib/spec-lint/baseline.mjs';
import { RULESETS, CURRENT_RULESET, promotedBetween } from '../../bin/lib/spec-lint/rulesets.mjs';
import { implementedRules, lintProject } from '../../bin/lib/spec-lint/engine.mjs';
import { hookScript, MARKER } from '../../bin/lib/spec-lint/hooks.mjs';

const BIN = path.join(REPO, 'bin', 'spec-lint.mjs');
const BASELINE = 'tests/compliance-baseline.json';
const validateBaseline = makeAjv().compile(JSON.parse(readFileSync(path.join(REPO, 'schemas', 'compliance-baseline.schema.json'), 'utf8')));
const GIT_ENV = { GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@example.invalid', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@example.invalid', GIT_CONFIG_NOSYSTEM: '1', HOME: '/nonexistent', CIVITAS_TEST_ID_PATTERN: '' };
const env = () => { const e = { ...process.env, ...GIT_ENV }; delete e.CLAUDE_PROJECT_DIR; delete e.GIT_INDEX_FILE; delete e.GIT_DIR; return e; };
const gitRaw = (root, ...a) => spawnSync('git', ['-C', root, ...a], { encoding: 'utf8', env: env() });
const git = (root, ...a) => { const r = gitRaw(root, ...a); assert.equal(r.status, 0, `git ${a.join(' ')}: ${r.stderr}`); return r.stdout; };
const run = (root, args) => spawnSync(process.execPath, [BIN, ...args], { cwd: root, encoding: 'utf8', env: { ...env(), CLAUDE_PROJECT_DIR: root } });
const read = (root, rel) => readFileSync(path.join(root, rel), 'utf8');
const write = (root, rel, text) => { mkdirSync(path.dirname(path.join(root, rel)), { recursive: true }); writeFileSync(path.join(root, rel), text); };
const baselineOf = (root) => { const b = JSON.parse(read(root, BASELINE)); assert.ok(validateBaseline(b), JSON.stringify(validateBaseline.errors)); return b; };
/** A commit through git, so the installed pre-commit hook runs: { status, out }. */
const commit = (root, msg, ...extra) => { const r = gitRaw(root, 'commit', '-q', '-m', msg, ...extra); return { status: r.status, out: `${r.stdout}${r.stderr}` }; };

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
const CLEAN_TEST = "\ntest('TCAB-0003 · third', async ({ steps }) => {\n  await steps.navigateTo('/three');\n  await steps.verifyPresence('heading', 'HomePage');\n});\n";
const BASE = "import { test as base } from '@playwright/test';\nexport const test = base;\n";

/** A repository with the suite committed; `link` puts this package where the hook looks for it. */
function repo(files = {}, { link = true } = {}) {
  const root = tempRoot();
  writeProject(root, { '.gitignore': 'node_modules/\n', 'tests/e2e/fixtures/base.ts': BASE, 'tests/e2e/a.spec.ts': SPEC, ...files });
  if (link) { mkdirSync(path.join(root, 'node_modules', '@civitas-cerebrum'), { recursive: true }); symlinkSync(REPO, path.join(root, 'node_modules', '@civitas-cerebrum', 'achilles')); }
  git(root, 'init', '-q', '-b', 'main');
  git(root, 'add', '-A');
  git(root, 'commit', '-q', '-m', 'base');
  return root;
}

/** A repository with the baseline recorded and committed as the init says. */
function optedIn(files, opts) {
  const root = repo(files, opts);
  const r = run(root, ['--init-baseline']);
  assert.equal(r.status, 0, r.stderr);
  git(root, 'add', BASELINE, '.githooks/');
  const c = commit(root, 'chore(test): compliance baseline');
  assert.equal(c.status, 0, c.out);
  return root;
}

const done = (root) => rmSync(root, { recursive: true, force: true });

// ── --init-baseline ───────────────────────────────────────────────────────

test('--init-baseline records the suite at HEAD, pins the house default it uses, installs the hook and says what to commit', () => {
  const root = repo();
  try {
    const r = run(root, ['--init-baseline']);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /chore\(test\): compliance baseline/);
    assert.match(r.stdout, /git add tests\/compliance-baseline\.json \.githooks\//);
    const b = baselineOf(root);
    assert.equal(b.ruleset, CURRENT_RULESET);
    assert.equal(b.idPattern, 'house-default');
    assert.equal(b.createdFrom, git(root, 'rev-parse', 'HEAD').trim());
    assert.deepEqual(b.files['tests/e2e/a.spec.ts'].counts, { 'TB-A2': 2 });
    assert.deepEqual(b.files['tests/e2e/a.spec.ts'].tests, { 'TCAB-0001': { 'TB-A2': 1 }, 'TCAB-0002': { 'TB-A2': 1 } });
    assert.deepEqual(b.totals, { 'TB-A2': 2 });
    assert.deepEqual(b.hook, { mode: 'githooks', path: '.githooks/pre-commit' });
    assert.equal(git(root, 'config', '--get', 'core.hooksPath').trim(), '.githooks');
    const hook = path.join(root, '.githooks', 'pre-commit');
    assert.ok(statSync(hook).mode & 0o100, 'the hook is executable');
    assert.ok(read(root, '.githooks/pre-commit').includes(MARKER));
  } finally { done(root); }
});

test('--init-baseline reads HEAD only: an uncommitted finding and an untracked spec are not recorded', () => {
  const root = repo();
  try {
    write(root, 'tests/e2e/a.spec.ts', SPEC.replace("await page.goto('/two');", "await page.goto('/two');\n  await page.reload();"));
    write(root, 'tests/e2e/new.spec.ts', "import { test } from './fixtures/base';\ntest('TCAB-0009 · n', async ({ page }) => { await page.goto('/n'); });\n");
    const r = run(root, ['--init-baseline']);
    assert.equal(r.status, 0, r.stderr);
    const b = baselineOf(root);
    assert.deepEqual(b.totals, { 'TB-A2': 2 });
    assert.deepEqual(Object.keys(b.files), ['tests/e2e/a.spec.ts']);
  } finally { done(root); }
});

test('--init-baseline pins the id pattern the titles use, and counts the tests without one', () => {
  const spec = "import { test } from './fixtures/base';\ntest('LGN-01 · signs in', async ({ steps }) => { await steps.navigateTo('/'); });\ntest('LGN-02 · signs out', async ({ steps }) => { await steps.navigateTo('/'); });\ntest('no id here', async ({ steps }) => { await steps.navigateTo('/'); });\n";
  const root = repo({ 'tests/e2e/a.spec.ts': spec });
  try {
    const r = run(root, ['--init-baseline']);
    assert.equal(r.status, 0, r.stderr);
    const b = baselineOf(root);
    assert.notEqual(b.idPattern, 'house-default');
    assert.match('LGN-01 · signs in', new RegExp(b.idPattern));
    assert.doesNotMatch('TCAB-0001 · x', new RegExp(b.idPattern));
    assert.deepEqual(b.files['tests/e2e/a.spec.ts'].tests, { 'no id here#1': { 'TB-I1': 1 } });
  } finally { done(root); }
});

test('inferIdPattern: the house default when most titles use it or none has an id; a pattern over the prefixes in use otherwise', () => {
  const house = /^\s*[[(]?(TC[A-Z]{0,3}-\d{4,6})[\])]?(?=[\s:·—|-]|$)/;
  assert.equal(inferIdPattern(['plain title', 'another'], house), 'house-default');
  assert.equal(inferIdPattern(['TCAB-0001 · a', 'TCAB-0002 · b', 'LGN-01 · c'], house), 'house-default');
  const p = new RegExp(inferIdPattern(['LGN-01 · a', 'SIGNUP-104 · b'], house));
  assert.equal(p.exec('SIGNUP-104 · b')[1], 'SIGNUP-104');
  assert.equal(p.exec('LGN-01 · a')[1], 'LGN-01');
  const multi = new RegExp(inferIdPattern(['TCP-AND-0001 · a', 'TCP-IOS-0002 · b'], house));
  assert.equal(multi.exec('TCP-AND-0001 · a')[1], 'TCP-AND-0001');
});

test('--init-baseline is refused when the baseline exists, and when it existed in an ancestor commit', () => {
  const root = optedIn();
  try {
    const again = run(root, ['--init-baseline']);
    assert.equal(again.status, 2);
    assert.match(again.stderr, /exists already/);
    git(root, 'rm', '-q', BASELINE);
    assert.equal(commit(root, 'drop the baseline', '--no-verify').status, 0);
    const r = run(root, ['--init-baseline']);
    assert.equal(r.status, 2);
    assert.match(r.stderr, /existed in an ancestor commit/);
    assert.match(r.stderr, /git log --diff-filter=D -- tests\/compliance-baseline\.json/);
    assert.ok(!existsSync(path.join(root, BASELINE)));
  } finally { done(root); }
});

// ── --pre-commit through git ──────────────────────────────────────────────

test('pre-commit: a touched test with a new blocking finding is refused; the commit names the finding', () => {
  const root = optedIn();
  try {
    write(root, 'tests/e2e/a.spec.ts', SPEC.replace("await page.goto('/two');", "await page.goto('/two');\n  await page.reload();"));
    git(root, 'add', 'tests/e2e/a.spec.ts');
    const c = commit(root, 'edit the second test');
    assert.notEqual(c.status, 0);
    assert.match(c.out, /\[TB-A2\] tests\/e2e\/a\.spec\.ts:9 TCAB-0002/);
    assert.match(c.out, /1 blocking in touched code|2 blocking in touched code/);
  } finally { done(root); }
});

test('pre-commit: a new clean test in a file with legacy findings passes', () => {
  const root = optedIn();
  try {
    write(root, 'tests/e2e/a.spec.ts', `${SPEC}${CLEAN_TEST}`);
    git(root, 'add', 'tests/e2e/a.spec.ts');
    const c = commit(root, 'add a clean test');
    assert.equal(c.status, 0, c.out);
    assert.match(c.out, /0 blocking in touched code, 2 legacy; 0 ratchet violation\(s\), 0 baseline-file problem\(s\)/);
  } finally { done(root); }
});

test('pre-commit: `git commit -a` (a temporary index) is checked on what it commits', () => {
  const root = optedIn();
  try {
    write(root, 'tests/e2e/a.spec.ts', SPEC.replace("await page.goto('/one');", "await page.goto('/one');\n  await page.reload();"));
    const c = commit(root, 'commit all', '-a');
    assert.notEqual(c.status, 0);
    assert.match(c.out, /\[TB-A2\] tests\/e2e\/a\.spec\.ts:5 TCAB-0001/);
  } finally { done(root); }
});

test('pre-commit: a generated data-table test stays blocked (TB-S1)', () => {
  const root = optedIn();
  try {
    write(root, 'tests/e2e/table.spec.ts', "import { test } from './fixtures/base';\nconst ROWS = [{ id: 'TCAB-0101', q: 'a' }, { id: 'TCAB-0102', q: 'b' }];\nfor (const row of ROWS) {\n  test(`${row.id} · search ${row.q}`, async ({ steps }) => {\n    await steps.navigateTo(`/search?q=${row.q}`);\n    await steps.verifyPresence('results', 'SearchPage');\n  });\n}\n");
    git(root, 'add', 'tests/e2e/table.spec.ts');
    const c = commit(root, 'a table');
    assert.notEqual(c.status, 0);
    assert.match(c.out, /\[TB-S1\] tests\/e2e\/table\.spec\.ts/);
  } finally { done(root); }
});

test('pre-commit: a legacy count rising in an untouched file is a ratchet violation', () => {
  const FX = "import { test as base } from '@playwright/test';\nexport const test = base.extend({ helper: async ({ steps }, use) => use(steps) });\n";
  const spec = "import { test } from './fixtures/base';\ntest('TCAB-0001 · first', async ({ helper }) => {\n  await helper.click('button', 'HomePage');\n});\n";
  const root = optedIn({ 'tests/e2e/fixtures/base.ts': FX, 'tests/e2e/a.spec.ts': spec });
  try {
    assert.deepEqual(baselineOf(root).totals, {});
    // the fixture now hands the page to the untouched spec: its call becomes a raw Playwright call
    write(root, 'tests/e2e/fixtures/base.ts', FX.replace('async ({ steps }, use) => use(steps)', 'async ({ page }, use) => use(page)'));
    git(root, 'add', 'tests/e2e/fixtures/base.ts');
    const c = commit(root, 'change the fixture');
    assert.notEqual(c.status, 0);
    assert.match(c.out, /\[ratchet\] tests\/e2e\/a\.spec\.ts test TCAB-0001 TB-A2: 1 now, 0 in the baseline at HEAD/);
  } finally { done(root); }
});

test('pre-commit: a hand-lowered, a raised and a deleted baseline are refused', () => {
  const root = optedIn();
  try {
    const b = baselineOf(root);
    const lowered = structuredClone(b);
    lowered.files['tests/e2e/a.spec.ts'].tests['TCAB-0002'] = undefined;
    delete lowered.files['tests/e2e/a.spec.ts'].tests['TCAB-0002'];
    lowered.files['tests/e2e/a.spec.ts'].counts['TB-A2'] = 1;
    lowered.totals['TB-A2'] = 1;
    write(root, BASELINE, serialize(lowered));
    git(root, 'add', BASELINE);
    let c = commit(root, 'lower by hand');
    assert.notEqual(c.status, 0);
    assert.match(c.out, /TCAB-0002 TB-A2 is recorded as 0, but the code has 1/);

    const raised = structuredClone(b);
    raised.files['tests/e2e/a.spec.ts'].tests['TCAB-0002']['TB-A2'] = 3;
    raised.files['tests/e2e/a.spec.ts'].counts['TB-A2'] = 4;
    raised.totals['TB-A2'] = 4;
    write(root, BASELINE, serialize(raised));
    git(root, 'add', BASELINE);
    c = commit(root, 'raise');
    assert.notEqual(c.status, 0);
    assert.match(c.out, /TCAB-0002 TB-A2 is recorded as 3, above the 1 in the baseline at HEAD/);

    const inconsistent = structuredClone(b);
    inconsistent.totals['TB-A2'] = 1;
    write(root, BASELINE, serialize(inconsistent));
    git(root, 'add', BASELINE);
    c = commit(root, 'totals');
    assert.notEqual(c.status, 0);
    assert.match(c.out, /totals do not equal the sum of the files/);

    git(root, 'rm', '-q', '-f', BASELINE);
    c = commit(root, 'delete');
    assert.notEqual(c.status, 0);
    assert.match(c.out, /the change deletes the baseline/);
  } finally { done(root); }
});

test('pre-commit: fails open with a warning when the lint is not installed', () => {
  const root = optedIn({}, { link: false });
  try {
    write(root, 'tests/e2e/a.spec.ts', SPEC.replace("await page.goto('/two');", "await page.goto('/two');\n  await page.reload();"));
    git(root, 'add', 'tests/e2e/a.spec.ts');
    const c = commit(root, 'no lint here');
    assert.equal(c.status, 0, c.out);
    assert.match(c.out, /achilles-pre-commit: warning: the test-baseline check did not run/);
  } finally { done(root); }
});

test('--pre-commit fails open when the lint cannot run (outside a work tree)', () => {
  const root = tempRoot();
  try {
    writeProject(root, { 'tests/e2e/a.spec.ts': SPEC });
    const r = run(root, ['--pre-commit']);
    assert.equal(r.status, 0);
    assert.match(r.stderr, /warning: the test-baseline check could not run/);
  } finally { done(root); }
});

test('--pre-commit: a second run over the same content is answered from the cache', () => {
  const root = optedIn();
  try {
    write(root, 'tests/e2e/a.spec.ts', `${SPEC}${CLEAN_TEST}`);
    git(root, 'add', 'tests/e2e/a.spec.ts');
    const first = run(root, ['--pre-commit', '--json']);
    assert.equal(first.status, 0, first.stderr);
    assert.equal(JSON.parse(first.stdout).cache, 'miss');
    const second = run(root, ['--pre-commit', '--json']);
    assert.equal(JSON.parse(second.stdout).cache, 'hit');
    assert.deepEqual(JSON.parse(second.stdout).lint.findings, JSON.parse(first.stdout).lint.findings);
    assert.ok(existsSync(path.join(root, '.achilles', 'compliance', 'index.json')));
    assert.equal(git(root, 'status', '--porcelain', '--', '.achilles').trim(), '', 'the cache is ignored by git');
    write(root, 'tests/e2e/a.spec.ts', `${SPEC}${CLEAN_TEST.replace("navigateTo('/three')", "navigateTo('/four')")}`);
    git(root, 'add', 'tests/e2e/a.spec.ts');
    assert.equal(JSON.parse(run(root, ['--pre-commit', '--json']).stdout).cache, 'miss');
  } finally { done(root); }
});

// ── --update-baseline ─────────────────────────────────────────────────────

test('--update-baseline lowers what was fixed and never raises', () => {
  const root = optedIn();
  try {
    write(root, 'tests/e2e/a.spec.ts', SPEC.replace("  await page.goto('/one');\n", "  await steps.navigateTo('/one');\n"));
    git(root, 'add', 'tests/e2e/a.spec.ts');
    assert.equal(commit(root, 'fix the first test').status, 0);
    const r = run(root, ['--update-baseline']);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /updated tests\/compliance-baseline\.json: 1 count\(s\) lowered/);
    assert.deepEqual(baselineOf(root).files['tests/e2e/a.spec.ts'].tests, { 'TCAB-0002': { 'TB-A2': 1 } });
    // a finding added in the working tree is not absorbed
    write(root, 'tests/e2e/a.spec.ts', read(root, 'tests/e2e/a.spec.ts').replace("await page.goto('/two');", "await page.goto('/two');\n  await page.reload();"));
    const up = run(root, ['--update-baseline']);
    assert.equal(up.status, 1);
    assert.match(up.stderr, /\[ratchet\] tests\/e2e\/a\.spec\.ts test TCAB-0002 TB-A2: 2 now, 1 in the baseline/);
    assert.deepEqual(baselineOf(root).files['tests/e2e/a.spec.ts'].tests, { 'TCAB-0002': { 'TB-A2': 1 } });
  } finally { done(root); }
});

test('a rename carries the entry: the moved file keeps its legacy counts and --update-baseline writes them under the new path', () => {
  const root = optedIn();
  try {
    git(root, 'mv', 'tests/e2e/a.spec.ts', 'tests/e2e/cart.spec.ts');
    const c = commit(root, 'rename');
    assert.equal(c.status, 0, c.out);
    assert.match(c.out, /0 ratchet violation/);
    const r = run(root, ['--update-baseline']);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /1 renamed file\(s\) carried/);
    const b = baselineOf(root);
    assert.deepEqual(Object.keys(b.files), ['tests/e2e/cart.spec.ts']);
    assert.deepEqual(b.totals, { 'TB-A2': 2 });
  } finally { done(root); }
});

test('buckets: describe-scope and file-scope findings are recorded apart from tests', () => {
  const spec = [
    "import { test } from './fixtures/base';",
    "test.describe.configure({ mode: 'serial' });",
    "test.describe('cart', () => {",
    "  test.describe.configure({ mode: 'serial' });",
    "  test('TCAB-0001 · adds', async ({ steps }) => { await steps.navigateTo('/'); });",
    '});',
    '',
  ].join('\n');
  const root = repo({ 'tests/e2e/a.spec.ts': spec });
  try {
    assert.equal(run(root, ['--init-baseline']).status, 0);
    const f = baselineOf(root).files['tests/e2e/a.spec.ts'];
    assert.deepEqual(f.describes, { cart: { 'TB-S7': 1 } });
    assert.deepEqual(f.fileScope, { 'TB-S7': 1 });
    assert.deepEqual(f.tests, {});
    assert.deepEqual(f.counts, { 'TB-S7': 2 });
  } finally { done(root); }
});

// ── --ratchet --base and --ci ─────────────────────────────────────────────

test('--ratchet --base compares with the baseline at the merge-base: a branch that raises its own copy still fails', () => {
  const FX = "import { test as base } from '@playwright/test';\nexport const test = base.extend({ helper: async ({ steps }, use) => use(steps) });\n";
  const spec = "import { test } from './fixtures/base';\ntest('TCAB-0001 · first', async ({ helper }) => {\n  await helper.click('button', 'HomePage');\n});\n";
  const root = optedIn({ 'tests/e2e/fixtures/base.ts': FX, 'tests/e2e/a.spec.ts': spec });
  try {
    git(root, 'checkout', '-q', '-b', 'feature');
    write(root, 'tests/e2e/fixtures/base.ts', FX.replace('async ({ steps }, use) => use(steps)', 'async ({ page }, use) => use(page)'));
    const b = baselineOf(root);
    b.files['tests/e2e/a.spec.ts'] = { counts: { 'TB-A2': 1 }, waived: {}, tests: { 'TCAB-0001': { 'TB-A2': 1 } }, describes: {}, fileScope: {} };
    b.totals = { 'TB-A2': 1 };
    write(root, BASELINE, serialize(b));
    git(root, 'add', '-A');
    assert.equal(commit(root, 'raise in the branch', '--no-verify').status, 0);
    const r = run(root, ['--ratchet', '--base', 'main']);
    assert.equal(r.status, 1, r.stdout);
    assert.match(r.stderr, /\[ratchet\] tests\/e2e\/a\.spec\.ts test TCAB-0001 TB-A2: 1 now, 0 in the baseline at the merge-base/);
    assert.match(r.stderr, /is recorded as 1, above the 0 in the baseline at the merge-base/);
    // the same branch with the copy untouched still fails on the ratchet
    git(root, 'checkout', '-q', 'main', '--', BASELINE);
    assert.equal(run(root, ['--ratchet', '--base', 'main']).status, 1);
  } finally { done(root); }
});

test('--ratchet --base passes a clean change and a lowered baseline that matches the code', () => {
  const root = optedIn();
  try {
    git(root, 'checkout', '-q', '-b', 'feature');
    write(root, 'tests/e2e/a.spec.ts', SPEC.replace("  await page.goto('/one');\n", "  await steps.navigateTo('/one');\n"));
    assert.equal(run(root, ['--update-baseline']).status, 0);
    const r = run(root, ['--ratchet', '--base', 'main', '--json']);
    assert.equal(r.status, 0, r.stderr);
    const rep = JSON.parse(r.stdout);
    assert.equal(rep.ok, true);
    assert.deepEqual(rep.baseline.violations, []);
    assert.deepEqual(rep.baseline.problems, []);
  } finally { done(root); }
});

test('--ci: a deleted baseline fails; deleted test ids and waiver changes are listed', () => {
  const root = optedIn();
  try {
    git(root, 'checkout', '-q', '-b', 'feature');
    write(root, 'tests/e2e/a.spec.ts', SPEC.split('\n').slice(0, 7).join('\n'));
    unlinkSync(path.join(root, BASELINE));
    const r = run(root, ['--ci', '--base', 'main', '--json']);
    assert.equal(r.status, 1);
    const rep = JSON.parse(r.stdout);
    assert.equal(rep.mode, 'ci');
    assert.deepEqual(rep.deletedTests, ['TCAB-0002']);
    assert.ok(rep.baseline.problems.some((p) => p.kind === 'deleted'));
    const human = run(root, ['--ci', '--base', 'main']);
    assert.match(human.stderr, /\[ci\] deleted test: TCAB-0002/);
    assert.match(human.stderr, /the change deletes the baseline/);
  } finally { done(root); }
});

test('--ratchet on a project without a baseline is the touched lint alone', () => {
  const root = repo();
  try {
    git(root, 'checkout', '-q', '-b', 'feature');
    write(root, 'tests/e2e/a.spec.ts', `${SPEC}${CLEAN_TEST}`);
    const r = run(root, ['--ratchet', '--base', 'main']);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /no compliance baseline/);
  } finally { done(root); }
});

test('the baseline commands refuse paths and odd combinations (exit 2)', () => {
  const root = repo();
  try {
    for (const args of [['--ratchet'], ['--ci'], ['--init-baseline', 'tests/e2e/a.spec.ts'], ['--ruleset-upgrade'], ['--pre-commit', '--staged'], ['--update-baseline', '--base', 'main'], ['--init-baseline', '--pre-commit']]) {
      assert.equal(run(root, args).status, 2, args.join(' '));
    }
    assert.equal(run(root, ['--update-baseline']).status, 2, 'no baseline to update');
  } finally { done(root); }
});

// ── the hook installer ────────────────────────────────────────────────────

test('--install-hook on a fresh clone: .githooks with core.hooksPath; twice changes nothing', () => {
  const root = repo();
  try {
    const r = run(root, ['--install-hook']);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /installed \(githooks: \.githooks\/pre-commit\)/);
    const text = read(root, '.githooks/pre-commit');
    const again = run(root, ['--install-hook']);
    assert.match(again.stdout, /already installed/);
    assert.equal(read(root, '.githooks/pre-commit'), text);
  } finally { done(root); }
});

test('--install-hook chains into husky: one line appended to .husky/pre-commit, which husky runs', () => {
  const root = repo({ '.husky/pre-commit': 'echo husky-ran\n', '.husky/_/pre-commit': '#!/bin/sh\nsh -e .husky/pre-commit\n' });
  try {
    git(root, 'config', 'core.hooksPath', '.husky/_');
    spawnSync('chmod', ['+x', path.join(root, '.husky/_/pre-commit')]);
    assert.equal(run(root, ['--install-hook']).status, 0);
    const text = read(root, '.husky/pre-commit');
    assert.ok(text.startsWith('echo husky-ran\n'), 'the existing hook is kept');
    assert.equal(text.split(MARKER).length - 1, 1);
    assert.ok(existsSync(path.join(root, '.husky/achilles-pre-commit')));
    assert.equal(git(root, 'config', '--get', 'core.hooksPath').trim(), '.husky/_', 'the hooks path is left alone');
    run(root, ['--install-hook']);
    assert.equal(read(root, '.husky/pre-commit'), text, 'idempotent');
    // end to end: husky's hook runs the project's line, then the check, which refuses the finding
    assert.equal(run(root, ['--init-baseline']).status, 0);
    assert.equal(read(root, '.husky/pre-commit'), text, 'the init installs nothing twice');
    git(root, 'add', '-A');
    let c = commit(root, 'baseline');
    assert.equal(c.status, 0, c.out);
    assert.match(c.out, /husky-ran/);
    write(root, 'tests/e2e/a.spec.ts', SPEC.replace("await page.goto('/two');", "await page.goto('/two');\n  await page.reload();"));
    git(root, 'add', 'tests/e2e/a.spec.ts');
    c = commit(root, 'bad');
    assert.notEqual(c.status, 0);
    assert.match(c.out, /husky-ran[\s\S]*\[TB-A2\]/);
  } finally { done(root); }
});

test('--install-hook chains into a custom hooks path, and wraps a hook that exits early', () => {
  const root = repo({ '.hooks/pre-commit': '#!/bin/sh\necho custom-ran\n' });
  try {
    git(root, 'config', 'core.hooksPath', '.hooks');
    spawnSync('chmod', ['+x', path.join(root, '.hooks/pre-commit')]);
    assert.equal(run(root, ['--init-baseline']).status, 0);
    assert.match(read(root, '.hooks/pre-commit'), /^#!\/bin\/sh\necho custom-ran\n/);
    git(root, 'add', '-A');
    let c = commit(root, 'baseline');
    assert.equal(c.status, 0, c.out);
    assert.match(c.out, /custom-ran/);
    write(root, 'tests/e2e/a.spec.ts', SPEC.replace("await page.goto('/two');", "await page.goto('/two');\n  await page.reload();"));
    git(root, 'add', 'tests/e2e/a.spec.ts');
    c = commit(root, 'bad');
    assert.notEqual(c.status, 0);
    assert.match(c.out, /custom-ran[\s\S]*\[TB-A2\]/);
  } finally { done(root); }
  const early = repo({ '.hooks/pre-commit': '#!/bin/sh\necho early-ran\nexit 0\n' });
  try {
    git(early, 'config', 'core.hooksPath', '.hooks');
    spawnSync('chmod', ['+x', path.join(early, '.hooks/pre-commit')]);
    const r = run(early, ['--install-hook']);
    assert.match(r.stdout, /wrapped/);
    assert.equal(read(early, '.hooks/pre-commit.achilles-original'), '#!/bin/sh\necho early-ran\nexit 0\n');
    const text = read(early, '.hooks/pre-commit');
    run(early, ['--install-hook']);
    assert.equal(read(early, '.hooks/pre-commit'), text, 'idempotent');
    write(early, 'tests/e2e/a.spec.ts', `${SPEC}${CLEAN_TEST}`);
    git(early, 'add', '-A');
    const c = commit(early, 'clean');
    assert.equal(c.status, 0, c.out);
    assert.match(c.out, /early-ran/);
  } finally { done(early); }
});

test('--install-hook chains into the default hooks directory instead of hiding an active hook there', () => {
  const root = repo();
  try {
    const hooks = path.join(root, '.git', 'hooks');
    writeFileSync(path.join(hooks, 'pre-commit'), '#!/bin/sh\necho local-ran\n');
    spawnSync('chmod', ['+x', path.join(hooks, 'pre-commit')]);
    const r = run(root, ['--install-hook']);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /chained/);
    assert.equal(gitRaw(root, 'config', '--get', 'core.hooksPath').status, 1, 'no hooks path set');
    assert.match(readFileSync(path.join(hooks, 'pre-commit'), 'utf8'), /^#!\/bin\/sh\necho local-ran\n/);
  } finally { done(root); }
});

test('--install-hook adds a pre-commit command to a lefthook configuration, once', () => {
  const root = repo({ 'lefthook.yml': '# project hooks\npre-commit:\n  commands:\n    lint:\n      run: npm run lint\n' });
  try {
    const r = run(root, ['--install-hook']);
    assert.equal(r.status, 0, r.stderr);
    const text = read(root, 'lefthook.yml');
    assert.match(text, /# project hooks/);
    assert.match(text, /lint:\n\s+run: npm run lint/);
    assert.match(text, /achilles-test-baseline:\n\s+run: sh \.lefthook\/achilles-pre-commit/);
    run(root, ['--install-hook']);
    assert.equal(read(root, 'lefthook.yml'), text);
  } finally { done(root); }
});

test('the hook script fails open on any exit but 1, and runs the project-local install', () => {
  const s = hookScript('app');
  assert.match(s, /dir="\$top\/app"/);
  assert.match(s, /node_modules\/@civitas-cerebrum\/achilles\/bin\/spec-lint\.mjs/);
  assert.match(s, /if \[ "\$status" -eq 1 \]; then exit 1; fi/);
  assert.doesNotMatch(s, /^[^#\n]*\bnpx\b/m, 'never downloads: only the installed lint runs');
});

// ── rulesets and the pure checks ──────────────────────────────────────────

const rs = [
  { id: 'tb-1', blocking: ['TB-A1'], promoted: null },
  { id: 'tb-2', blocking: ['TB-A1', 'TB-A2'], promoted: ['TB-A2'] },
];
const fileOf = (tests) => {
  const counts = {};
  for (const c of Object.values(tests)) for (const [r, n] of Object.entries(c)) counts[r] = (counts[r] || 0) + n;
  return { counts, waived: {}, tests, describes: {}, fileScope: {} };
};
const bl = (ruleset, tests) => { const f = fileOf(tests); return { version: 1, ruleset, engine: 'x', createdFrom: 'a'.repeat(40), idPattern: 'house-default', totals: { ...f.counts }, files: { 'tests/e2e/a.spec.ts': f } }; };
const content = (tests) => { const f = fileOf(tests); return { totals: { ...f.counts }, files: { 'tests/e2e/a.spec.ts': f } }; };

test('ruleset upgrade: a rule a newer ruleset promotes is not compared until recorded; --ruleset-upgrade records it from the content', () => {
  const ref = bl('tb-1', { T1: { 'TB-A1': 2 } });
  const now = content({ T1: { 'TB-A1': 2, 'TB-A2': 3 } });
  const r = ratchet(ref, now, { rulesets: rs, current: 'tb-2' });
  assert.deepEqual(r.violations, []);
  assert.match(r.notes[0], /TB-A2 is not compared until `achilles-spec-lint --update-baseline --ruleset-upgrade`/);
  const plain = updateBaseline(ref, now, { rulesets: rs, current: 'tb-2' });
  assert.equal(plain.next.ruleset, 'tb-1');
  assert.deepEqual(plain.next.totals, { 'TB-A1': 2 });
  const up = updateBaseline(ref, now, { upgrade: true, rulesets: rs, current: 'tb-2' });
  assert.equal(up.next.ruleset, 'tb-2');
  assert.deepEqual(up.next.files['tests/e2e/a.spec.ts'].tests, { T1: { 'TB-A1': 2, 'TB-A2': 3 } });
  // the upgraded copy passes the copy check; padding the promoted rule above the content does not
  const parsed = parseBaseline(serialize(up.next), { rulesets: rs });
  assert.deepEqual(checkCopy(ref, parsed, now, { rulesets: rs, current: 'tb-2' }), []);
  const padded = structuredClone(up.next);
  padded.files['tests/e2e/a.spec.ts'].tests.T1['TB-A2'] = 5;
  padded.files['tests/e2e/a.spec.ts'].counts['TB-A2'] = 5;
  padded.totals['TB-A2'] = 5;
  assert.deepEqual(checkCopy(ref, parseBaseline(serialize(padded), { rulesets: rs }), now, { rulesets: rs, current: 'tb-2' }).map((v) => v.kind), ['raised']);
  // once recorded, the promoted rule ratchets like any other
  assert.equal(ratchet(up.next, content({ T1: { 'TB-A1': 2, 'TB-A2': 4 } }), { rulesets: rs, current: 'tb-2' }).violations.length, 1);
  assert.deepEqual([...promotedBetween('tb-1', 'tb-2', rs)], ['TB-A2']);
});

test('the shipped ruleset counts every rule the engine blocks on, except the ones decided per change', () => {
  const latest = new Set(RULESETS[RULESETS.length - 1].blocking);
  const blocking = implementedRules().filter((r) => r.severity === 'blocking').map((r) => r.id).filter((id) => id !== 'TB-S8');
  assert.deepEqual(blocking.filter((id) => !latest.has(id)), [], 'a rule promoted to blocking needs a new ruleset that lists it');
  const ids = new Set(implementedRules().map((r) => r.id));
  assert.deepEqual([...latest].filter((id) => !ids.has(id)), []);
  assert.equal(CURRENT_RULESET, RULESETS[RULESETS.length - 1].id);
});

test('recount: the seeded corpus records only counted rules, and its buckets add up', () => {
  const root = tempRoot();
  try {
    writeProject(root, { 'tests/e2e/a.spec.ts': `${SPEC}${CLEAN_TEST}`, 'tests/e2e/fixtures/base.ts': BASE });
    const report = lintProject({ root, useGit: false, suite: true });
    const c = recount(report);
    const b = { version: 1, ruleset: CURRENT_RULESET, engine: 'x', createdFrom: 'a'.repeat(40), idPattern: 'house-default', ...c };
    assert.ok(parseBaseline(serialize(b)).baseline, JSON.stringify(parseBaseline(serialize(b)).problems));
    assert.deepEqual(c.totals, { 'TB-A2': 2 });
  } finally { done(root); }
});

// ── the commit-gate budget ────────────────────────────────────────────────

test('budget: --pre-commit over a 200-spec suite (cold, then from the cache)', { timeout: 120000 }, (t) => {
  const files = {};
  for (let i = 0; i < 200; i++) {
    const tests = [];
    for (let j = 0; j < 6; j++) tests.push(`test('TCAB-${String(i * 10 + j).padStart(4, '0')} · case ${j}', async ({ steps }) => {\n  await steps.navigateTo('/p/${j}');\n  await steps.click('button${j}', 'HomePage');\n  await steps.fill('input', 'HomePage', 'v${j}');\n  await steps.verifyPresence('heading', 'HomePage');\n  await steps.verifyText('heading', 'HomePage', 'Title ${j}');\n});\n`);
    files[`tests/e2e/area${i % 10}/f${i}.spec.ts`] = `import { test } from '../fixtures/base';\n\ntest.describe('file ${i}', () => {\n${tests.join('\n')}});\n`;
  }
  const root = optedIn(files);
  try {
    write(root, 'tests/e2e/area0/f0.spec.ts', `${read(root, 'tests/e2e/area0/f0.spec.ts')}\ntest('TCAB-9999 · added', async ({ steps }) => { await steps.navigateTo('/x'); });\n`);
    git(root, 'add', '-A');
    const time = () => { const t0 = Date.now(); const r = run(root, ['--pre-commit', '--json']); assert.equal(r.status, 0, r.stderr); const o = JSON.parse(r.stdout); return { wall: Date.now() - t0, ms: o.elapsedMs, cache: o.cache }; };
    const cold = time();
    assert.equal(cold.cache, 'miss');
    const warm = [time(), time(), time()];
    for (const w of warm) assert.equal(w.cache, 'hit');
    const best = Math.min(...warm.map((w) => w.ms));
    // `ms` is measured inside the process from its start (module loading included); the wall time adds the
    // host's process start, which varies by seconds on a loaded machine
    t.diagnostic(`pre-commit over 201 files: cold ${cold.ms} ms (wall ${cold.wall} ms), from the cache ${best} ms (wall ${warm.map((w) => w.wall).join('/')} ms)`);
    assert.ok(best < 2000, `cached run ${best} ms`);
    assert.ok(cold.ms < 5000, `cold run ${cold.ms} ms`);
  } finally { done(root); }
});
