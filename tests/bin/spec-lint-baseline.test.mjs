// The compliance baseline, the ratchet and the pre-commit check (achilles-spec-lint --init-baseline,
// --update-baseline [--ruleset-upgrade], --ratchet --base, --ci, --pre-commit, --install-hook), on throwaway
// git repositories. The pre-commit cases commit through git itself, so the installed hook is what runs.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, linkSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync, unlinkSync } from 'node:fs';
import path from 'node:path';
import { makeAjv } from '../../scripts/lib/ajv.mjs';
import { REPO, tempRoot, writeProject } from './spec-lint-helpers.mjs';
import { ratchet, updateBaseline, checkCopy, recount, inferIdPattern, parseBaseline, serialize } from '../../bin/lib/spec-lint/baseline.mjs';
import { RULESETS, CURRENT_RULESET, promotedBetween, validateRulesets } from '../../bin/lib/spec-lint/rulesets.mjs';
import { implementedRules, lintProject } from '../../bin/lib/spec-lint/engine.mjs';
import { hookScript, MARKER, SHARED_LINE } from '../../bin/lib/spec-lint/hooks.mjs';

const BIN = path.join(REPO, 'bin', 'spec-lint.mjs');
const BASELINE = 'tests/compliance-baseline.json';
const validateBaseline = makeAjv().compile(JSON.parse(readFileSync(path.join(REPO, 'schemas', 'compliance-baseline.schema.json'), 'utf8')));
// every git and lint call runs with a throwaway HOME and global configuration, and no system configuration:
// the installer must never reach a real repository or a real user's settings
const SANDBOX = tempRoot();
const GLOBAL = path.join(SANDBOX, 'gitconfig');
writeFileSync(GLOBAL, '');
process.on('exit', () => rmSync(SANDBOX, { recursive: true, force: true }));
const GIT_ENV = { GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@example.invalid', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@example.invalid', GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_SYSTEM: '/dev/null', GIT_CONFIG_GLOBAL: GLOBAL, HOME: SANDBOX, CIVITAS_TEST_ID_PATTERN: '' };
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

test('--init-baseline pins the id pattern the titles use, says how to change it, and counts the tests without one', () => {
  const ids = Array.from({ length: 10 }, (_, i) => `test('LGN-${String(i + 1).padStart(2, '0')} · case ${i}', async ({ steps }) => { await steps.navigateTo('/'); });`);
  const spec = `import { test } from './fixtures/base';\n${ids.join('\n')}\ntest('no id here', async ({ steps }) => { await steps.navigateTo('/'); });\n`;
  const root = repo({ 'tests/e2e/a.spec.ts': spec });
  try {
    const r = run(root, ['--init-baseline']);
    assert.equal(r.status, 0, r.stderr);
    const b = baselineOf(root);
    assert.equal(b.idPattern, '^\\s*[[(]?([A-Z]{2,5}-[0-9]{2,4})[\\])]?(?=[\\s:·—|]|$)', 'the documented pattern, which every id fits');
    assert.match(r.stdout, /\(inferred from 10 of 11 titles\)/);
    assert.equal(new RegExp(b.idPattern).exec('LGN-01234 · x'), null, 'a longer id is not read as a shorter one');
    assert.match(r.stdout, /to pin another before you commit it: delete tests\/compliance-baseline\.json and run `CIVITAS_TEST_ID_PATTERN=/);
    assert.deepEqual(b.files['tests/e2e/a.spec.ts'].tests, { 'no id here#1': { 'TB-I1': 1 } });
  } finally { done(root); }
});

test('--init-baseline pins a consistent lowercase multi-segment convention, and the house default for a mixed suite', () => {
  const names = ['j-cart-manage-1-01', 'j-cart-manage-1-02', 'j-checkout-2-01', 'j-checkout-flow-3-11', 'j-search-4-01'];
  const spec = `import { test } from './fixtures/base';\n${names.map((n) => `test('${n} adds an item', async ({ steps }) => { await steps.navigateTo('/'); });`).join('\n')}\n`;
  const root = repo({ 'tests/e2e/a.spec.ts': spec });
  try {
    assert.equal(run(root, ['--init-baseline']).status, 0);
    const b = baselineOf(root);
    assert.notEqual(b.idPattern, 'house-default');
    const re = new RegExp(b.idPattern);
    for (const n of names) assert.equal(re.exec(`${n} adds an item`)[1], n);
    assert.equal(re.exec('j-orders-12-104 lists orders')[1], 'j-orders-12-104', 'ordinary growth fits');
    assert.equal(re.exec('adds an item'), null);
    assert.deepEqual(b.totals, {}, 'every test already carries its id');
  } finally { done(root); }
  const mixed = ['LGN-01 · a', 'j-cart-1-01 b', 'TCAB-0001 · c', 'plain title', 'SGN-02 · e'];
  const m = repo({ 'tests/e2e/a.spec.ts': `import { test } from './fixtures/base';\n${mixed.map((t) => `test('${t}', async ({ steps }) => { await steps.navigateTo('/'); });`).join('\n')}\n` });
  try {
    assert.equal(run(m, ['--init-baseline']).status, 0);
    assert.equal(baselineOf(m).idPattern, 'house-default');
  } finally { done(m); }
});

test('inferIdPattern: one shape held by at least 90% of the titles, widened for ordinary growth; else the house default', () => {
  const house = /^\s*[[(]?(TC[A-Z]{0,3}-\d{4,6})[\])]?(?=[\s:·—|-]|$)/;
  const pin = (titles) => inferIdPattern(titles, house).pattern;
  assert.equal(pin(['plain title', 'another']), 'house-default');
  assert.equal(pin(['TCAB-0001 · a', 'TCAB-0002 · b', 'TCLG-000003 · c']), 'house-default');
  assert.equal(pin(['LGN-01 · a', 'SGN-02 · b', 'LGN-03 · c']), '^\\s*[[(]?([A-Z]{2,5}-[0-9]{2,4})[\\])]?(?=[\\s:·—|]|$)');
  assert.equal(new RegExp(pin(['LGN-01 · a', 'SGN-02 · b'])).exec('LGN-01234 · x'), null);
  // a bracketed id counts as a hit, and the pinned pattern reads it
  const bracketed = new RegExp(pin(['[LGN-12] signs in', '[LGN-13] signs out', 'LGN-14 · resets']));
  assert.equal(bracketed.exec('[LGN-12] signs in')[1], 'LGN-12');
  assert.equal(bracketed.exec('(SGN-7001) x')[1], 'SGN-7001');
  // hyphenated words ending in digits are not a lowercase id convention
  assert.equal(pin(['covid-19 spikes', 'top-10 lists', 'mp3-128 plays', 'h-1 heading']), 'house-default');
  // never narrower than the observed ids
  const wide = new RegExp(pin(['SIGNUPX-10404 · b', 'LGN-01 · a']));
  assert.equal(wide.exec('SIGNUPX-10404 · b')[1], 'SIGNUPX-10404');
  assert.equal(wide.exec('AB-01 · c')[1], 'AB-01', 'two-letter prefixes fit');
  const multi = new RegExp(pin(['TCP-AND-0001 · a', 'TCP-IOS-0002 · b']));
  assert.equal(multi.exec('TCP-AND-0001 · a')[1], 'TCP-AND-0001');
  // below the threshold: the house default
  assert.equal(pin(['LGN-01 · a', 'LGN-02 · b', 'plain', 'plainer']), 'house-default');
  const r = inferIdPattern(['LGN-01 · a', 'LGN-02 · b'], house);
  assert.deepEqual([r.matched, r.of], [2, 2]);
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
    assert.match(r.stderr, new RegExp(`last held by commit ${git(root, 'rev-parse', 'HEAD~1').trim().slice(0, 12)}`), 'the last commit that had it, not the deleting one');
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

test('pre-commit: under a recorded house default, a test without an id is told about the house default', () => {
  const root = optedIn();
  try {
    write(root, 'tests/e2e/a.spec.ts', `${SPEC}\ntest('adds an item', async ({ steps }) => { await steps.navigateTo('/'); });\n`);
    git(root, 'add', 'tests/e2e/a.spec.ts');
    const c = commit(root, 'no id');
    assert.notEqual(c.status, 0);
    assert.match(c.out, /\[TB-I1\][^\n]*the house default recorded in tests\/compliance-baseline\.json/);
    assert.doesNotMatch(c.out, /the pinned pattern \(tests\/compliance-baseline\.json idPattern\)/);
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

test('pre-commit: a count written under a key the code does not produce gets one clear message', () => {
  const root = optedIn();
  try {
    const b = baselineOf(root);
    b.files['tests/e2e/a.spec.ts'].tests['TCAB-9999'] = { 'TB-A2': 1 };
    b.files['tests/e2e/a.spec.ts'].counts['TB-A2'] = 3;
    b.totals['TB-A2'] = 3;
    write(root, BASELINE, serialize(b));
    git(root, 'add', BASELINE);
    const c = commit(root, 'invented key');
    assert.notEqual(c.status, 0);
    assert.match(c.out, /test TCAB-9999 TB-A2 is recorded as 1, but neither the baseline at HEAD nor the code has any there/);
    assert.equal((c.out.match(/\[baseline\]/g) || []).length, 1);
    assert.match(c.out, /0 protected input change\(s\) \(0 weakening, 0 refused\)/);
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

test('--ci reads the rule inputs from the merge-base: a change that weakens one fails, and its own setting is not used', () => {
  const table = "import { test } from './fixtures/base';\nconst ROWS = [{ id: 'TCAB-0101', q: 'a' }, { id: 'TCAB-0102', q: 'b' }];\nfor (const row of ROWS) {\n  test(`${row.id} · search ${row.q}`, async ({ steps }) => {\n    await steps.navigateTo(`/search?q=${row.q}`);\n  });\n}\n";
  const root = optedIn();
  try {
    git(root, 'checkout', '-q', '-b', 'feature');
    write(root, 'achilles-factory-rules.json', JSON.stringify({ rules: { 'specs.constant-table-tests': { allowed: true } } }));
    write(root, 'tests/e2e/table.spec.ts', table);
    const r = run(root, ['--ci', '--base', 'main', '--json']);
    assert.equal(r.status, 1);
    const rep = JSON.parse(r.stdout);
    assert.ok(rep.protectedInputs.some((c) => c.input === 'achilles-factory-rules.json' && c.weakens));
    assert.ok(rep.lint.findings.some((f) => f.rule === 'TB-S1' && f.touched), 'the data table is linted under the merge-base rules');
    const human = run(root, ['--ci', '--base', 'main']);
    assert.match(human.stderr, /\[ci\] protected input changed: achilles-factory-rules\.json: rule specs\.constant-table-tests added \(weakens\)/);
  } finally { done(root); }
  const env = optedIn();
  try {
    git(env, 'checkout', '-q', '-b', 'feature');
    write(env, '.env', 'CIVITAS_TEST_ID_PATTERN=^\\s*(.+)\n');
    write(env, 'tests/e2e/b.spec.ts', "import { test } from './fixtures/base';\ntest('no id here', async ({ steps }) => { await steps.navigateTo('/'); });\n");
    const r = run(env, ['--ci', '--base', 'main']);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /protected input changed: \.env: CIVITAS_TEST_ID_PATTERN changed/);
    assert.match(r.stderr, /\[TB-I1\] tests\/e2e\/b\.spec\.ts/, 'the recorded pattern still applies');
  } finally { done(env); }
  const reg = optedIn();
  try {
    git(reg, 'checkout', '-q', '-b', 'feature');
    write(reg, 'tests/e2e/docs/framework-gaps.md', '| Row | Missing capability | Raw methods | Status |\n|---|---|---|---|\n| FG-9 | everything | goto | open |\n');
    // rule inputs alone: the ratchet passes, and the change is reported for the owner's review
    const r = run(reg, ['--ci', '--base', 'main', '--json']);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(JSON.parse(r.stdout).review, "protected input changed: needs the owner's review");
    assert.match(r.stderr, /protected input changed: needs the owner's review: the change touches only rule inputs \(tests\/e2e\/docs\/framework-gaps\.md: row FG-9 added, weakens\)/);
    // the same with test code is refused
    write(reg, 'tests/e2e/a.spec.ts', `${SPEC}${CLEAN_TEST}`);
    const mixed = run(reg, ['--ci', '--base', 'main']);
    assert.equal(mixed.status, 1);
    assert.match(mixed.stderr, /\[ci\] protected input changed: tests\/e2e\/docs\/framework-gaps\.md: row FG-9 added \(weakens\)/);
  } finally { done(reg); }
});

test('--ci: an added factory rule is a weakening, so a permissive one cannot ride along with test code', () => {
  const permissive = JSON.stringify({ rules: { 'specs.shape': { titleIdPattern: '^(?:TC[A-Z]+-[0-9]{4}|no)' } } });
  const noId = "import { test } from './fixtures/base';\ntest('no · id at all', async ({ steps }) => { await steps.navigateTo('/'); });\n";
  // M6: the new rule mixed with test code is refused
  const mixed = optedIn();
  try {
    git(mixed, 'checkout', '-q', '-b', 'feature');
    write(mixed, 'achilles-factory-rules.json', permissive);
    write(mixed, 'tests/e2e/b.spec.ts', noId);
    const r = run(mixed, ['--ci', '--base', 'main']);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /protected input changed: achilles-factory-rules\.json: rule specs\.shape added \(weakens\)/);
    assert.match(r.stderr, /\[TB-I1\] tests\/e2e\/b\.spec\.ts/, 'the test is checked under the base pattern');
  } finally { done(mixed); }
  // M7: alone it goes to the owner's review, marked as weakening; only once merged does a later change rely on it
  const alone = optedIn();
  try {
    git(alone, 'checkout', '-q', '-b', 'rules');
    write(alone, 'achilles-factory-rules.json', permissive);
    const r = run(alone, ['--ci', '--base', 'main']);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stderr, /needs the owner's review: the change touches only rule inputs \(achilles-factory-rules\.json: rule specs\.shape added, weakens\)/);
  } finally { done(alone); }
});

test('--ci compares the configs\' evaluated test selection at the merge-base, subdirectories included', () => {
  const cfg = (ignore) => `import { defineConfig } from '@playwright/test';\nconst IGNORED = [\n  '**/legacy/**',\n${ignore}];\nexport default defineConfig({ testDir: './tests/e2e', testIgnore: IGNORED });\n`;
  const root = optedIn({ 'playwright.config.ts': cfg(''), 'tools/playwright.config.ts': "export default { testDir: '../tests/e2e' };\n" });
  try {
    git(root, 'checkout', '-q', '-b', 'feature');
    // a constant entry added on its own line, far from the testIgnore key
    write(root, 'playwright.config.ts', cfg("  '**/a.spec.ts',\n"));
    let r = run(root, ['--ci', '--base', 'main']);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stderr, /needs the owner's review: the change touches only rule inputs \(playwright\.config\.ts: its test selection changed \(testIgnore\), weakens\)/);
    // mixed with test code it is refused
    write(root, 'tests/e2e/a.spec.ts', `${SPEC}${CLEAN_TEST}`);
    r = run(root, ['--ci', '--base', 'main']);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /\[ci\] protected input changed: playwright\.config\.ts: its test selection changed \(testIgnore\) \(weakens\)/);
    // the config in a subdirectory is protected too
    write(root, 'playwright.config.ts', cfg(''));
    write(root, 'tools/playwright.config.ts', "export default { testDir: '../tests/e2e', grepInvert: /TCAB/ };\n");
    r = run(root, ['--ci', '--base', 'main']);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /\[ci\] protected input changed: tools\/playwright\.config\.ts: its test selection changed \(grepInvert\)/);
  } finally { done(root); }
});

test('pre-commit reads the rule inputs from HEAD: a working-tree setting does not relax the check, and the change is named', () => {
  const root = optedIn();
  try {
    write(root, 'achilles-factory-rules.json', JSON.stringify({ rules: { 'specs.constant-table-tests': { allowed: true } } }));
    write(root, 'tests/e2e/table.spec.ts', "import { test } from './fixtures/base';\nconst ROWS = ['a', 'b'];\nfor (const q of ROWS) {\n  test(`TCAB-01${q} · search ${q}`, async ({ steps }) => { await steps.navigateTo(`/s?q=${q}`); });\n}\n");
    git(root, 'add', '-A');
    const c = commit(root, 'allow tables');
    assert.notEqual(c.status, 0);
    assert.match(c.out, /\[TB-S1\]/);
    assert.match(c.out, /\[pre-commit\] protected input changed: achilles-factory-rules\.json/);
  } finally { done(root); }
});

test('--ci: a baseline re-created where an ancestor held one fails; a shallow clone is asked for full history', () => {
  const root = optedIn();
  try {
    // on main, a direct push adds a finding and deletes the baseline
    write(root, 'tests/e2e/a.spec.ts', SPEC.replace("await page.goto('/two');", "await page.goto('/two');\n  await page.reload();"));
    git(root, 'rm', '-q', BASELINE);
    git(root, 'add', '-A');
    assert.equal(commit(root, 'direct push', '--no-verify').status, 0);
    git(root, 'checkout', '-q', '-b', 'feature');
    // a fresh count written by hand (the init refuses here), committed on the branch
    const fresh = tempRoot();
    try {
      writeProject(fresh, { 'tests/e2e/fixtures/base.ts': BASE, 'tests/e2e/a.spec.ts': read(root, 'tests/e2e/a.spec.ts') });
      git(fresh, 'init', '-q', '-b', 'main');
      git(fresh, 'add', '-A');
      git(fresh, 'commit', '-q', '-m', 'x');
      assert.equal(run(fresh, ['--init-baseline']).status, 0);
      write(root, BASELINE, read(fresh, BASELINE));
    } finally { done(fresh); }
    git(root, 'add', BASELINE);
    assert.equal(commit(root, 're-create', '--no-verify').status, 0);
    const r = run(root, ['--ci', '--base', 'main']);
    assert.equal(r.status, 1, r.stdout);
    assert.match(r.stderr, /records a new baseline, but commit [0-9a-f]{12} held one that was deleted since/);
    // a shallow clone of the branch cannot tell: exit 2
    const shallow = tempRoot();
    try {
      rmSync(shallow, { recursive: true, force: true });
      const cl = gitRaw(SANDBOX, 'clone', '-q', '--depth', '1', '--no-local', '--branch', 'feature', `file://${root}`, shallow);
      assert.equal(cl.status, 0, cl.stderr);
      git(shallow, 'fetch', '-q', '--depth', '1', 'origin', 'main:main');
      const s2 = run(shallow, ['--ci', '--base', 'main']);
      assert.equal(s2.status, 2, s2.stderr);
      assert.match(s2.stderr, /shallow clone|merge-base/);
      assert.equal(run(shallow, ['--init-baseline']).status, 2);
    } finally { done(shallow); }
  } finally { done(root); }
});

test('--ci: a corrupt baseline at the merge-base is compared through the last valid copy, so the repair can pass', () => {
  const root = optedIn();
  try {
    const good = read(root, BASELINE);
    write(root, BASELINE, '{ not json');
    git(root, 'add', BASELINE);
    assert.equal(commit(root, 'corrupt', '--no-verify').status, 0);
    git(root, 'checkout', '-q', '-b', 'repair');
    write(root, BASELINE, good);
    const r = run(root, ['--ci', '--base', 'main']);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stderr, /compared with the last valid copy/);
  } finally { done(root); }
});

test('moving a legacy test into another file touches it there: the move fails until the test is clean', () => {
  const root = optedIn();
  try {
    const lines = SPEC.split('\n');
    write(root, 'tests/e2e/a.spec.ts', lines.slice(0, 7).join('\n'));
    write(root, 'tests/e2e/b.spec.ts', `import { test } from './fixtures/base';\n\n${lines.slice(7).join('\n')}`);
    git(root, 'add', '-A');
    const c = commit(root, 'move the second test');
    assert.notEqual(c.status, 0);
    assert.match(c.out, /\[TB-A2\] tests\/e2e\/b\.spec\.ts:\d+ TCAB-0002/);
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

test('--install-hook chains into husky: the call goes first in .husky/pre-commit, which husky runs', () => {
  const root = repo({ '.husky/pre-commit': 'echo husky-ran\n', '.husky/_/pre-commit': '#!/bin/sh\nsh -e .husky/pre-commit\n' });
  try {
    git(root, 'config', 'core.hooksPath', '.husky/_');
    spawnSync('chmod', ['+x', path.join(root, '.husky/_/pre-commit')]);
    assert.equal(run(root, ['--install-hook']).status, 0);
    const text = read(root, '.husky/pre-commit');
    assert.ok(text.startsWith(`${MARKER}: the test-baseline check\n`), 'the check runs first');
    assert.ok(text.endsWith('echo husky-ran\n'), 'the existing hook is kept, last');
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
    assert.match(c.out, /\[TB-A2\]/);
  } finally { done(root); }
});

test('--install-hook chains into a custom hooks path: the check runs first and the hook keeps its own final status', () => {
  const root = repo({ '.hooks/pre-commit': '#!/bin/sh\necho custom-ran\n' });
  try {
    git(root, 'config', 'core.hooksPath', '.hooks');
    spawnSync('chmod', ['+x', path.join(root, '.hooks/pre-commit')]);
    assert.equal(run(root, ['--init-baseline']).status, 0);
    assert.match(read(root, '.hooks/pre-commit'), new RegExp(`^#!/bin/sh\\n${MARKER}: the test-baseline check\\n.*\\necho custom-ran\\n$`));
    git(root, 'add', '-A');
    let c = commit(root, 'baseline');
    assert.equal(c.status, 0, c.out);
    assert.match(c.out, /custom-ran/);
    write(root, 'tests/e2e/a.spec.ts', SPEC.replace("await page.goto('/two');", "await page.goto('/two');\n  await page.reload();"));
    git(root, 'add', 'tests/e2e/a.spec.ts');
    c = commit(root, 'bad');
    assert.notEqual(c.status, 0);
    assert.match(c.out, /\[TB-A2\]/);
  } finally { done(root); }
  // a hook whose last command fails (no `exit`) still fails the commit once chained
  const failing = repo({ '.hooks/pre-commit': '#!/bin/sh\necho lint-staged-ran\nfalse\n' });
  try {
    git(failing, 'config', 'core.hooksPath', '.hooks');
    spawnSync('chmod', ['+x', path.join(failing, '.hooks/pre-commit')]);
    assert.equal(run(failing, ['--install-hook']).status, 0);
    write(failing, 'tests/e2e/a.spec.ts', `${SPEC}${CLEAN_TEST}`);
    git(failing, 'add', 'tests/e2e/a.spec.ts');
    const c = commit(failing, 'clean, but the project hook fails');
    assert.notEqual(c.status, 0, c.out);
    assert.match(c.out, /lint-staged-ran/);
  } finally { done(failing); }
  // an early `&& exit 0` cannot skip the check
  const early = repo({ '.hooks/pre-commit': '#!/bin/sh\ntrue && exit 0\necho never\n' });
  try {
    git(early, 'config', 'core.hooksPath', '.hooks');
    spawnSync('chmod', ['+x', path.join(early, '.hooks/pre-commit')]);
    assert.equal(run(early, ['--init-baseline']).status, 0);
    git(early, 'add', '-A');
    assert.equal(commit(early, 'baseline').status, 0);
    write(early, 'tests/e2e/a.spec.ts', SPEC.replace("await page.goto('/two');", "await page.goto('/two');\n  await page.reload();"));
    git(early, 'add', 'tests/e2e/a.spec.ts');
    const c = commit(early, 'bad');
    assert.notEqual(c.status, 0);
    assert.match(c.out, /\[TB-A2\]/);
  } finally { done(early); }
});

test('--install-hook wraps a pre-commit that is not a shell script, and runs it after the check', () => {
  const root = repo({ '.hooks/pre-commit': "#!/usr/bin/env node\nconsole.log('node-hook-ran');\n" });
  try {
    git(root, 'config', 'core.hooksPath', '.hooks');
    spawnSync('chmod', ['+x', path.join(root, '.hooks/pre-commit')]);
    const r = run(root, ['--install-hook']);
    assert.match(r.stdout, /wrapped/);
    assert.equal(read(root, '.hooks/pre-commit.achilles-original'), "#!/usr/bin/env node\nconsole.log('node-hook-ran');\n");
    const text = read(root, '.hooks/pre-commit');
    run(root, ['--install-hook']);
    assert.equal(read(root, '.hooks/pre-commit'), text, 'idempotent');
    write(root, 'tests/e2e/a.spec.ts', `${SPEC}${CLEAN_TEST}`);
    git(root, 'add', '-A');
    const c = commit(root, 'clean');
    assert.equal(c.status, 0, c.out);
    assert.match(c.out, /node-hook-ran/);
  } finally { done(root); }
});

test('--install-hook never writes outside the repository: under a global or outside hooks path it installs the committed check and prints the line to add (exit 0)', () => {
  const outside = tempRoot();
  const root = repo();
  try {
    writeFileSync(GLOBAL, `[core]\n\thooksPath = ${outside}\n`);
    const r = run(root, ['--install-hook']);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /pre-commit check installed \(shared: \.githooks\/achilles-pre-commit\)/);
    assert.match(r.stdout, /set outside this repository/);
    assert.ok(r.stdout.includes(`installed the committed check; add this line to your shared hook: ${SHARED_LINE}`), r.stdout);
    assert.doesNotMatch(`${r.stdout}${r.stderr}`, /→ Do:/, 'not a usage error');
    assert.ok(existsSync(path.join(root, '.githooks', 'achilles-pre-commit')), 'the check is written into the repository');
    assert.deepEqual(readdirSync(outside), []);
    const again = run(root, ['--install-hook']);
    assert.equal(again.status, 0, again.stderr);
    assert.match(again.stdout, /already installed \(shared: /);
    // once the shared pre-commit calls it, the note says so
    writeFileSync(path.join(outside, 'pre-commit'), `#!/bin/sh\n${SHARED_LINE}\n`);
    assert.match(run(root, ['--install-hook']).stdout, /the shared pre-commit already calls it/);
    rmSync(path.join(outside, 'pre-commit'));
    // a relative global path is shared too: it would apply to every repository
    writeFileSync(GLOBAL, '[core]\n\thooksPath = .shared-hooks\n');
    assert.equal(run(root, ['--install-hook']).status, 0);
    assert.ok(!existsSync(path.join(root, '.shared-hooks')));
    writeFileSync(GLOBAL, '');
    // a local path outside the work tree
    git(root, 'config', 'core.hooksPath', outside);
    assert.equal(run(root, ['--install-hook']).status, 0);
    assert.deepEqual(readdirSync(outside), []);
    // the init records the baseline and the shared check, and says what to add and commit
    const init = run(root, ['--init-baseline']);
    assert.equal(init.status, 0, init.stderr);
    assert.doesNotMatch(init.stderr, /was not installed/);
    assert.ok(init.stdout.includes(SHARED_LINE));
    assert.match(init.stdout, /git add tests\/compliance-baseline\.json \.githooks\/achilles-pre-commit/);
    assert.deepEqual(baselineOf(root).hook, { mode: 'shared', path: '.githooks/achilles-pre-commit' });
    assert.deepEqual(readdirSync(outside), []);
  } finally { writeFileSync(GLOBAL, ''); done(root); done(outside); }
});

test('--install-hook: a second project of the same repository is refused where the committed script serves another one', () => {
  const shared = tempRoot();
  const pkg = (name) => JSON.stringify({ name, private: true, dependencies: { '@civitas-cerebrum/element-interactions': '0.3.12' } });
  const root = repo({ 'web/package.json': pkg('web'), 'web/tests/e2e/fixtures/base.ts': BASE, 'web/tests/e2e/a.spec.ts': SPEC, 'admin/package.json': pkg('admin'), 'admin/tests/e2e/fixtures/base.ts': BASE, 'admin/tests/e2e/a.spec.ts': SPEC });
  try {
    writeFileSync(GLOBAL, `[core]\n\thooksPath = ${shared}\n`);
    const web = path.join(root, 'web');
    const admin = path.join(root, 'admin');
    assert.equal(run(web, ['--install-hook']).status, 0);
    const text = read(root, '.githooks/achilles-pre-commit');
    const second = run(admin, ['--install-hook']);
    assert.equal(second.status, 2, second.stdout);
    assert.match(second.stderr, /\.githooks\/achilles-pre-commit already runs the check of the project in web/);
    assert.equal(read(root, '.githooks/achilles-pre-commit'), text, 'the first project keeps its check');
    // the same project again is idempotent
    const again = run(web, ['--install-hook']);
    assert.equal(again.status, 0, again.stderr);
    assert.match(again.stdout, /already installed/);
    // the init of the second project records its baseline and says why no check was installed
    const init = run(admin, ['--init-baseline']);
    assert.equal(init.status, 0, init.stderr);
    assert.match(init.stderr, /the pre-commit check was not installed: .*already runs the check of the project in web/);
    assert.equal(baselineOf(admin).hook, undefined);
    writeFileSync(GLOBAL, '');
    // the same refusal under a hooks path inside the work tree: .githooks/pre-commit serves the first project
    const local = repo({ 'web/package.json': pkg('web'), 'web/tests/e2e/a.spec.ts': SPEC, 'admin/package.json': pkg('admin'), 'admin/tests/e2e/a.spec.ts': SPEC });
    try {
      assert.equal(run(path.join(local, 'web'), ['--install-hook']).status, 0);
      const r = run(path.join(local, 'admin'), ['--install-hook']);
      assert.equal(r.status, 2);
      assert.match(r.stderr, /\.githooks\/pre-commit already runs the check of the project in web/);
      assert.match(read(local, '.githooks/pre-commit'), /^dir="\$top\/web"$/m);
    } finally { done(local); }
  } finally { writeFileSync(GLOBAL, ''); done(root); done(shared); }
});

test('--install-hook never follows a planted symbolic link out of the repository', () => {
  const outside = tempRoot();
  writeFileSync(path.join(outside, 'profile'), 'keep me\n');
  writeFileSync(path.join(outside, 'pre-commit'), '#!/bin/sh\necho outside\n');
  const untouched = () => {
    assert.equal(readFileSync(path.join(outside, 'profile'), 'utf8'), 'keep me\n');
    assert.equal(readFileSync(path.join(outside, 'pre-commit'), 'utf8'), '#!/bin/sh\necho outside\n');
    assert.deepEqual(readdirSync(outside).sort(), ['pre-commit', 'profile']);
  };
  try {
    // the hooks path names an in-repo directory that is a link to outside
    const r1 = repo();
    try {
      mkdirSync(path.join(r1, 'tools'));
      symlinkSync(outside, path.join(r1, 'tools', 'hooks'));
      git(r1, 'config', 'core.hooksPath', 'tools/hooks');
      const r = run(r1, ['--install-hook']);
      assert.equal(r.status, 2);
      assert.match(r.stderr, /is a symbolic link/);
      untouched();
    } finally { done(r1); }
    // the script the installer writes is a planted link to an outside file
    const r4 = repo({ 'tools/hooks/pre-commit': '#!/bin/sh\necho mine\n' });
    try {
      symlinkSync(path.join(outside, 'profile'), path.join(r4, 'tools', 'hooks', 'achilles-pre-commit'));
      git(r4, 'config', 'core.hooksPath', 'tools/hooks');
      assert.equal(run(r4, ['--install-hook']).status, 2);
      untouched();
    } finally { done(r4); }
    // husky's directory is a link to outside
    const r5 = repo();
    try {
      symlinkSync(outside, path.join(r5, '.husky'));
      git(r5, 'config', 'core.hooksPath', '.husky/_');
      assert.equal(run(r5, ['--install-hook']).status, 2);
      untouched();
    } finally { done(r5); }
  } finally { done(outside); }
});

test('--install-hook replaces a file rather than writing into it, so a hard link to an outside file is not followed', () => {
  const outside = tempRoot();
  writeFileSync(path.join(outside, 'target'), '#!/bin/sh\necho outside\n');
  const root = repo();
  try {
    mkdirSync(path.join(root, 'tools', 'hooks'), { recursive: true });
    linkSync(path.join(outside, 'target'), path.join(root, 'tools', 'hooks', 'pre-commit'));
    git(root, 'config', 'core.hooksPath', 'tools/hooks');
    const r = run(root, ['--install-hook']);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(readFileSync(path.join(outside, 'target'), 'utf8'), '#!/bin/sh\necho outside\n', 'the outside file is untouched');
    assert.ok(read(root, 'tools/hooks/pre-commit').includes(MARKER));
    assert.equal(statSync(path.join(root, 'tools', 'hooks', 'pre-commit')).nlink, 1);
  } finally { done(root); done(outside); }
});

test('--install-hook reads hook names case-insensitively where the file system does', () => {
  const root = repo({ '.githooks/PRE-COMMIT': '#!/bin/sh\necho upper\n' });
  try {
    const insensitive = existsSync(path.join(root, '.githooks', 'pre-commit'));
    const r = run(root, ['--install-hook']);
    if (insensitive) {
      assert.equal(r.status, 2, 'the dormant hook is seen, not overwritten');
      assert.match(r.stderr, /\.githooks holds pre-commit/);
      assert.equal(read(root, '.githooks/PRE-COMMIT'), '#!/bin/sh\necho upper\n');
    } else assert.equal(r.status, 0, 'on a case-sensitive file system the file is not a hook git runs');
  } finally { done(root); }
});

test('the committed hook is the same through a symbolic link to the project, and works in a clone elsewhere', () => {
  const root = repo();
  const links = tempRoot();
  const clone = path.join(tempRoot(), 'clone');
  try {
    const via = path.join(links, 'linked-project');
    symlinkSync(root, via);
    const r = spawnSync(process.execPath, [BIN, '--init-baseline'], { cwd: via, encoding: 'utf8', env: { ...env(), CLAUDE_PROJECT_DIR: via } });
    assert.equal(r.status, 0, r.stderr);
    const text = read(root, '.githooks/pre-commit');
    assert.match(text, /^dir="\$top"$/m, 'only the top level, no path through the link');
    assert.doesNotMatch(text, /\.\.\/|\/private\/|\/var\/|\/tmp\//);
    const again = run(root, ['--install-hook']);
    assert.match(again.stdout, /already installed \(githooks: \.githooks\/pre-commit\)/);
    assert.equal(read(root, '.githooks/pre-commit'), text, 'byte-identical through the real path');
    git(root, 'add', '-A');
    assert.equal(commit(root, 'baseline').status, 0);
    // a clone at another place, the first one moved away: the check runs there and blocks
    assert.equal(gitRaw(SANDBOX, 'clone', '-q', `file://${root}`, clone).status, 0);
    rmSync(root, { recursive: true, force: true });
    mkdirSync(path.join(clone, 'node_modules', '@civitas-cerebrum'), { recursive: true });
    symlinkSync(REPO, path.join(clone, 'node_modules', '@civitas-cerebrum', 'achilles'));
    assert.equal(run(clone, ['--install-hook']).status, 0);
    assert.equal(git(clone, 'status', '--porcelain').trim(), '', 'installing in the clone leaves the committed hook as it is');
    write(clone, 'tests/e2e/a.spec.ts', SPEC.replace("await page.goto('/two');", "await page.goto('/two');\n  await page.reload();"));
    git(clone, 'add', 'tests/e2e/a.spec.ts');
    const c = commit(clone, 'bad in the clone');
    assert.notEqual(c.status, 0, c.out);
    assert.match(c.out, /\[TB-A2\]/);
  } finally { done(root); done(links); done(path.dirname(clone)); }
});

test('a global hooks path: the committed check runs from one shared line, which skips repositories without it', () => {
  const shared = tempRoot();
  const plain = tempRoot();
  const root = repo({ 'app/package.json': JSON.stringify({ name: 'app', private: true, dependencies: { '@civitas-cerebrum/element-interactions': '0.3.12' } }), 'app/tests/e2e/fixtures/base.ts': BASE, 'app/tests/e2e/a.spec.ts': SPEC });
  try {
    writeFileSync(GLOBAL, `[core]\n\thooksPath = ${shared}\n`);
    const app = path.join(root, 'app');
    const init = run(app, ['--init-baseline']);
    assert.equal(init.status, 0, init.stderr);
    const line = /add this line to your shared hook: (.*)$/m.exec(init.stdout)[1];
    assert.equal(line, SHARED_LINE, 'no machine path in the printed line');
    assert.match(init.stdout, /git add tests\/compliance-baseline\.json \.githooks\/achilles-pre-commit/);
    assert.deepEqual(readdirSync(shared), [], 'nothing written in the shared directory');
    // the person adds the line to the shared pre-commit
    writeFileSync(path.join(shared, 'pre-commit'), `#!/bin/sh\n${line}\n`);
    spawnSync('chmod', ['+x', path.join(shared, 'pre-commit')]);
    // an unrelated repository without Achilles commits as before
    writeFileSync(path.join(plain, 'readme.txt'), 'x\n');
    git(plain, 'init', '-q', '-b', 'main');
    git(plain, 'add', '-A');
    assert.equal(commit(plain, 'unrelated').status, 0);
    // the subdirectory project: the baseline commit passes, a bad commit is refused
    git(root, 'add', '-A');
    let c = commit(root, 'baseline');
    assert.equal(c.status, 0, c.out);
    write(app, 'tests/e2e/a.spec.ts', SPEC.replace("await page.goto('/two');", "await page.goto('/two');\n  await page.reload();"));
    git(root, 'add', '-A');
    c = commit(root, 'bad');
    assert.notEqual(c.status, 0, c.out);
    assert.match(c.out, /\[TB-A2\] tests\/e2e\/a\.spec\.ts/);
  } finally { writeFileSync(GLOBAL, ''); done(root); done(shared); done(plain); }
});

test('a workspace package that declares no framework dependency of its own resolves through the workspace root, so the shared check blocks', () => {
  const shared = tempRoot();
  const root = repo({ 'package.json': JSON.stringify({ name: 'mono', private: true, workspaces: ['packages/*'], devDependencies: { '@civitas-cerebrum/element-interactions': '0.3.12' } }), 'packages/app/package.json': JSON.stringify({ name: 'app', private: true }), 'packages/app/tests/e2e/fixtures/base.ts': BASE, 'packages/app/tests/e2e/a.spec.ts': SPEC });
  try {
    writeFileSync(GLOBAL, `[core]\n\thooksPath = ${shared}\n`);
    const app = path.join(root, 'packages', 'app');
    const init = run(app, ['--init-baseline']);
    assert.equal(init.status, 0, init.stderr);
    assert.deepEqual(baselineOf(app).totals, { 'TB-A2': 2 });
    writeFileSync(path.join(shared, 'pre-commit'), `#!/bin/sh\n${SHARED_LINE}\n`);
    spawnSync('chmod', ['+x', path.join(shared, 'pre-commit')]);
    git(root, 'add', '-A');
    let c = commit(root, 'baseline');
    assert.equal(c.status, 0, c.out);
    write(app, 'tests/e2e/a.spec.ts', SPEC.replace("await page.goto('/two');", "await page.goto('/two');\n  await page.reload();"));
    git(root, 'add', '-A');
    c = commit(root, 'bad');
    assert.notEqual(c.status, 0, c.out);
    assert.match(c.out, /\[TB-A2\] tests\/e2e\/a\.spec\.ts/);
    assert.doesNotMatch(c.out, /could not run/);
  } finally { writeFileSync(GLOBAL, ''); done(root); done(shared); }
});

test('an activated dormant pre-commit keeps the same mode label on every run', () => {
  const root = repo({ '.githooks/pre-commit': '#!/bin/sh\necho mine\n' });
  try {
    const first = run(root, ['--install-hook', '--activate-hooks', 'pre-commit']);
    assert.equal(first.status, 0, first.stderr);
    assert.match(first.stdout, /\(githooks: \.githooks\/pre-commit\)/);
    const second = run(root, ['--install-hook']);
    assert.match(second.stdout, /already installed \(githooks: \.githooks\/pre-commit\)/);
  } finally { done(root); }
});

test('--install-hook does not switch on dormant hooks in .githooks unless they are named', () => {
  const root = repo({ '.githooks/commit-msg': '#!/bin/sh\necho dormant\n' });
  try {
    const r = run(root, ['--install-hook']);
    assert.equal(r.status, 2);
    assert.match(r.stderr, /\.githooks holds commit-msg, which git does not run today/);
    assert.equal(gitRaw(root, 'config', '--get', 'core.hooksPath').status, 1, 'no hooks path set');
    assert.ok(!existsSync(path.join(root, '.githooks/pre-commit')));
    const ok = run(root, ['--install-hook', '--activate-hooks', 'commit-msg']);
    assert.equal(ok.status, 0, ok.stderr);
    assert.equal(git(root, 'config', '--get', 'core.hooksPath').trim(), '.githooks');
  } finally { done(root); }
});

test('--install-hook chains into the default hooks directory instead of hiding an active hook there', () => {
  const lfs = repo();
  try {
    // an active hook of another name (a commit-msg, git-lfs's pre-push): a hooks path would switch it off
    const hooks = path.join(lfs, '.git', 'hooks');
    writeFileSync(path.join(hooks, 'pre-push'), '#!/bin/sh\necho lfs\n');
    spawnSync('chmod', ['+x', path.join(hooks, 'pre-push')]);
    const r = run(lfs, ['--install-hook']);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /chained/);
    assert.equal(gitRaw(lfs, 'config', '--get', 'core.hooksPath').status, 1, 'no hooks path set');
    assert.ok(readFileSync(path.join(hooks, 'pre-commit'), 'utf8').includes(MARKER));
    assert.equal(readFileSync(path.join(hooks, 'pre-push'), 'utf8'), '#!/bin/sh\necho lfs\n');
  } finally { done(lfs); }
  const root = repo();
  try {
    const hooks = path.join(root, '.git', 'hooks');
    writeFileSync(path.join(hooks, 'pre-commit'), '#!/bin/sh\necho local-ran\n');
    spawnSync('chmod', ['+x', path.join(hooks, 'pre-commit')]);
    const r = run(root, ['--install-hook']);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /chained/);
    assert.equal(gitRaw(root, 'config', '--get', 'core.hooksPath').status, 1, 'no hooks path set');
    assert.match(readFileSync(path.join(hooks, 'pre-commit'), 'utf8'), /^#!\/bin\/sh\n# achilles-pre-commit[\s\S]*echo local-ran\n$/);
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

test('--install-hook: an active hooks path (husky) wins over a lefthook configuration', () => {
  const root = repo({ 'lefthook.yml': 'pre-commit:\n  commands: {}\n', '.husky/pre-commit': 'echo husky-ran\n' });
  try {
    git(root, 'config', 'core.hooksPath', '.husky/_');
    const r = run(root, ['--install-hook']);
    assert.equal(r.status, 0, r.stderr);
    assert.ok(read(root, '.husky/pre-commit').includes(MARKER));
    assert.doesNotMatch(read(root, 'lefthook.yml'), /achilles/);
  } finally { done(root); }
});

test('the hook finds a hoisted install in a workspace root above the project', () => {
  const root = repo({ 'app/package.json': JSON.stringify({ name: 'app', private: true, dependencies: { '@civitas-cerebrum/element-interactions': '0.3.12' } }), 'app/tests/e2e/fixtures/base.ts': BASE, 'app/tests/e2e/a.spec.ts': SPEC });
  try {
    const app = path.join(root, 'app');
    const init = run(app, ['--init-baseline']);
    assert.equal(init.status, 0, init.stderr);
    git(root, 'add', '-A');
    assert.equal(commit(root, 'baseline').status, 0);
    write(app, 'tests/e2e/a.spec.ts', SPEC.replace("await page.goto('/two');", "await page.goto('/two');\n  await page.reload();"));
    git(root, 'add', '-A');
    const c = commit(root, 'bad');
    assert.notEqual(c.status, 0, c.out);
    assert.match(c.out, /\[TB-A2\] tests\/e2e\/a\.spec\.ts/);
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
const rsWiden = [...rs, { id: 'tb-3', blocking: ['TB-A1', 'TB-A2'], promoted: ['TB-A1'] }];
const fileOf = (tests) => {
  const counts = {};
  for (const c of Object.values(tests)) for (const [r, n] of Object.entries(c)) counts[r] = (counts[r] || 0) + n;
  return { counts, waived: {}, tests, describes: {}, fileScope: {} };
};
const bl = (ruleset, tests) => { const f = fileOf(tests); return { version: 1, ruleset, engine: 'x', createdFrom: 'a'.repeat(40), idPattern: 'house-default', totals: { ...f.counts }, files: { 'tests/e2e/a.spec.ts': f } }; };
const content = (tests) => { const f = fileOf(tests); return { totals: { ...f.counts }, files: { 'tests/e2e/a.spec.ts': f } }; };

test('ruleset upgrade: a promoted rule is held to the reference content until recorded; --ruleset-upgrade records it from the content', () => {
  const ref = bl('tb-1', { T1: { 'TB-A1': 2 } });
  const refContent = content({ T1: { 'TB-A1': 2, 'TB-A2': 3 } });
  const now = content({ T1: { 'TB-A1': 2, 'TB-A2': 3 } });
  // without the reference content the rule is not compared, and the note says so
  const blind = ratchet(ref, content({ T1: { 'TB-A1': 2, 'TB-A2': 9 } }), { rulesets: rs, current: 'tb-2' });
  assert.deepEqual(blind.violations, []);
  assert.match(blind.notes[0], /TB-A2 is not compared until `achilles-spec-lint --update-baseline --ruleset-upgrade`/);
  // with it, the promoted rule may not rise above what the reference commit had
  assert.deepEqual(ratchet(ref, now, { rulesets: rs, current: 'tb-2', refContent }).violations, []);
  const worse = ratchet(ref, content({ T1: { 'TB-A1': 2, 'TB-A2': 4 } }), { rulesets: rs, current: 'tb-2', refContent });
  assert.deepEqual(worse.violations.map((v) => [v.rule, v.baseline, v.now]), [['TB-A2', 3, 4]]);
  const plain = updateBaseline(ref, now, { rulesets: rs, current: 'tb-2' });
  assert.equal(plain.next.ruleset, 'tb-1');
  assert.deepEqual(plain.next.totals, { 'TB-A1': 2 });
  const up = updateBaseline(ref, now, { upgrade: true, rulesets: rs, current: 'tb-2' });
  assert.equal(up.next.ruleset, 'tb-2');
  assert.deepEqual(up.next.files['tests/e2e/a.spec.ts'].tests, { T1: { 'TB-A1': 2, 'TB-A2': 3 } });
  const parsed = parseBaseline(serialize(up.next), { rulesets: rs });
  assert.deepEqual(checkCopy(ref, parsed, now, { rulesets: rs, current: 'tb-2', refContent }), []);
  // a regression written in the same change is not absorbed: the ceiling is the reference content, not the change's
  const regressed = content({ T1: { 'TB-A1': 2, 'TB-A2': 5 } });
  const absorb = updateBaseline(ref, regressed, { upgrade: true, rulesets: rs, current: 'tb-2' });
  assert.deepEqual(checkCopy(ref, parseBaseline(serialize(absorb.next), { rulesets: rs }), regressed, { rulesets: rs, current: 'tb-2', refContent }).map((v) => [v.kind, v.baseline, v.recorded]), [['raised', 3, 5]]);
  // without the reference content nothing promoted may be recorded at all
  assert.deepEqual(checkCopy(ref, parsed, now, { rulesets: rs, current: 'tb-2' }).map((v) => v.kind), ['raised']);
  // once recorded, the promoted rule ratchets like any other
  assert.equal(ratchet(up.next, content({ T1: { 'TB-A1': 2, 'TB-A2': 4 } }), { rulesets: rs, current: 'tb-2' }).violations.length, 1);
  assert.deepEqual([...promotedBetween('tb-1', 'tb-2', rs)], ['TB-A2']);
  // a widened definition (TB-A1 in tb-3) is held to the reference content too
  assert.deepEqual([...promotedBetween('tb-2', 'tb-3', rsWiden)], ['TB-A1']);
});

test('rulesets: every ruleset after the first lists what it promotes, as an array', () => {
  assert.doesNotThrow(() => validateRulesets(RULESETS));
  assert.doesNotThrow(() => validateRulesets(rsWiden));
  assert.throws(() => validateRulesets([...rs, { id: 'tb-3', blocking: ['TB-A1', 'TB-A2'], promoted: null }]), /`promoted` must be an array/);
  assert.throws(() => validateRulesets([rs[0], { id: 'tb-2', blocking: ['TB-A1', 'TB-A2'], promoted: [] }]), /TB-A2 become blocking but are not listed/);
  assert.throws(() => promotedBetween('tb-1', 'tb-3', [...rs, { id: 'tb-3', blocking: ['TB-A1'] }]), /must be an array/);
});

test('copy check: a changed id pattern or recorded hook in the change\'s copy is a protected-input change', () => {
  const ref = { ...bl('tb-1', { T1: { 'TB-A1': 2 } }), hook: { mode: 'githooks', path: '.githooks/pre-commit' } };
  const now = content({ T1: { 'TB-A1': 2 } });
  const widened = { ...ref, idPattern: '^\\s*(.+)' };
  assert.deepEqual(checkCopy(ref, parseBaseline(serialize(widened), { rulesets: rs }), now, { rulesets: rs, current: 'tb-1' }).map((v) => v.kind), ['idPattern']);
  const moved = { ...ref, hook: { mode: 'chained', path: '.hooks/pre-commit' } };
  assert.deepEqual(checkCopy(ref, parseBaseline(serialize(moved), { rulesets: rs }), now, { rulesets: rs, current: 'tb-1' }).map((v) => v.kind), ['hook']);
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
