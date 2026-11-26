// The Steps surface chain of achilles-spec-lint (worktree node_modules, then the main checkout, then the
// shipped snapshot for the pinned version), the declaration reader and the version helper.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { cpSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { resolveSurface, classMembers, SurfaceError, shippedVersions, SURFACES_DIR } from '../../bin/lib/spec-lint/surface.mjs';
import { checkShippedTables, EQUIVALENTS_FILE } from '../../bin/lib/spec-lint/equivalents.mjs';
import { parserFor, parseDts } from '../../bin/lib/spec-lint/ast.mjs';
import * as semver from '../../bin/lib/spec-lint/semver.mjs';
import { lintProject } from '../../bin/lib/spec-lint/engine.mjs';
import { REPO, tempRoot, writeProject } from './spec-lint-helpers.mjs';

const parser = parserFor(REPO);
const DTS = `
import { Base } from './Base';
export declare class Steps extends Base {
  private page;
  protected repo: unknown;
  readonly platform: string;
  get driverName(): string;
  constructor(repo: unknown);
  click(elementName: string, pageName: string): Promise<void>;
  static create(): Steps;
}`;
const BASE = 'export declare class Base { navigateTo(url: string): Promise<void>; private secret; }';

function fakePackage(root, version, { dts = DTS } = {}) {
  const dir = 'node_modules/@civitas-cerebrum/element-interactions';
  writeProject(root, {
    [`${dir}/package.json`]: JSON.stringify({ name: '@civitas-cerebrum/element-interactions', version }),
    [`${dir}/dist/steps/CommonSteps.d.ts`]: dts,
    [`${dir}/dist/steps/Base.d.ts`]: BASE,
  });
}

test('classMembers reads public methods, properties, private names', () => {
  const m = classMembers(parseDts(parser, DTS), 'Steps');
  assert.deepEqual(m.methods, ['click']);
  assert.deepEqual(m.properties, ['driverName', 'platform']);
  assert.deepEqual(m.privates, ['page', 'repo']);
  assert.equal(m.superClass, 'Base');
});

test('worktree node_modules wins, follows extends, and notes a release newer than the shipped table', () => {
  const root = tempRoot();
  try {
    writeProject(root, {}, { pin: '0.3.6' });
    fakePackage(root, '9.9.9');
    const s = resolveSurface(root, parser, { useGit: false });
    assert.equal(s.source, 'worktree');
    assert.equal(s.version, '9.9.9');
    assert.ok(s.methods.has('click') && s.methods.has('navigateTo'));
    assert.ok(s.privates.steps.has('secret') && s.privates.steps.has('page'));
    assert.match(s.notes.join(' '), /older than the installed 9\.9\.9/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('a linked worktree without node_modules uses the main checkout', () => {
  const main = tempRoot();
  const wt = `${main}-wt`;
  const git = (...a) => execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', '-c', 'commit.gpgsign=false', ...a], { cwd: main, stdio: 'ignore' });
  try {
    writeProject(main, { 'README.md': 'x' }, { pin: '0.3.6' });
    git('init', '-q');
    git('add', 'package.json', 'README.md');
    git('commit', '-q', '-m', 'init');
    git('worktree', 'add', '-q', wt);
    fakePackage(main, '0.3.12');
    const s = resolveSurface(wt, parser);
    assert.equal(s.source, 'checkout');
    assert.equal(s.version, '0.3.12');
  } finally {
    rmSync(wt, { recursive: true, force: true });
    rmSync(main, { recursive: true, force: true });
  }
});

test('no node_modules: the shipped snapshot for the pinned version, the lock file, or the highest range match', () => {
  const root = tempRoot();
  try {
    writeProject(root, {}, { pin: '0.3.6' });
    let s = resolveSurface(root, parser, { useGit: false });
    assert.equal(s.source, 'snapshot');
    assert.equal(s.version, '0.3.6');
    writeProject(root, { 'package.json': JSON.stringify({ dependencies: { '@civitas-cerebrum/element-interactions': '^0.3.5' } }) });
    s = resolveSurface(root, parser, { useGit: false });
    assert.equal(s.version, shippedVersions().filter((v) => semver.satisfies(v, '^0.3.5')).at(-1));
    writeProject(root, { 'package-lock.json': JSON.stringify({ packages: { 'node_modules/@civitas-cerebrum/element-interactions': { version: '0.3.7' } } }) });
    s = resolveSurface(root, parser, { useGit: false });
    assert.equal(s.version, '0.3.7');
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('nothing resolves: the error names every place tried, and the engine refuses to run', () => {
  const root = tempRoot();
  try {
    writeProject(root, { 'package.json': JSON.stringify({ name: 'bare' }) });
    assert.throws(() => resolveSurface(root, parser, { useGit: false }), (e) => e instanceof SurfaceError && /worktree: .*snapshot: no @civitas-cerebrum\/element-interactions dependency/.test(e.message));
    assert.throws(() => lintProject({ root, useGit: false }), SurfaceError);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('the shipped surfaces and equivalence table are well formed and agree', () => {
  assert.deepEqual(checkShippedTables(), []);
  assert.ok(shippedVersions().length >= 10);
});

test('a hand-edited table or a missing surface is refused', () => {
  const dir = tempRoot();
  try {
    cpSync(SURFACES_DIR, path.join(dir, 'surfaces'), { recursive: true });
    const eq = JSON.parse(readFileSync(EQUIVALENTS_FILE, 'utf8'));
    eq.methods.goto.targets[0].since = '0.3.9';
    writeFileSync(path.join(dir, 'equivalents.json'), JSON.stringify(eq));
    assert.match(checkShippedTables({ equivalentsFile: path.join(dir, 'equivalents.json'), surfacesDir: path.join(dir, 'surfaces') }).join(' '), /methods disagrees with the shipped surfaces/);
    rmSync(path.join(dir, 'surfaces', '0.3.12.json'));
    writeFileSync(path.join(dir, 'equivalents.json'), readFileSync(EQUIVALENTS_FILE));
    assert.match(checkShippedTables({ equivalentsFile: path.join(dir, 'equivalents.json'), surfacesDir: path.join(dir, 'surfaces') }).join(' '), /releases differ/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('semver: ranges npm writes', () => {
  assert.ok(semver.satisfies('0.3.12', '>=0.3.12 <1.0.0'));
  assert.ok(!semver.satisfies('0.4.0', '^0.3.7'));
  assert.ok(semver.satisfies('0.3.9', '~0.3.7'));
  assert.ok(semver.satisfies('0.3.9', '0.3.x'));
  assert.ok(semver.satisfies('1.2.3', '1.0.0 - 1.2.3'));
  assert.ok(semver.satisfies('0.2.1', '^0.3.0 || 0.2.1'));
  assert.equal(semver.maxSatisfying(['0.3.5', '0.3.10', '0.3.9'], '^0.3.5'), '0.3.10');
  assert.equal(semver.compare('0.3.10', '0.3.9'), 1);
  assert.equal(semver.compare('1.0.0-rc.1', '1.0.0'), -1);
});

test('the pinned surface decides what a method check sees (A10 per installed version)', () => {
  const root = tempRoot();
  try {
    writeProject(root, { 'tests/e2e/a.spec.ts': "import { test } from './fixtures/base';\ntest('TC-1 · x', async ({ steps }) => { await steps.getUrl(); });\n" }, { pin: '0.3.5' });
    const old = lintProject({ root, useGit: false });
    assert.equal(old.stepsSurface.version, '0.3.5');
    assert.equal(old.stepsSurface.source, 'snapshot');
    assert.ok(old.findings.some((f) => f.rule === 'TB-A10'));
    writeProject(root, { 'package.json': JSON.stringify({ dependencies: { '@civitas-cerebrum/element-interactions': '0.3.7' } }) });
    assert.ok(!lintProject({ root, useGit: false }).findings.some((f) => f.rule === 'TB-A10'));
  } finally { rmSync(root, { recursive: true, force: true }); }
});

