// claude-code/register.js against a temp HOME and a temp project: no real settings file is touched.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRequire } from 'node:module';

const { register, merge, scope, PLUGIN } = createRequire(import.meta.url)('../../claude-code/register.js');

// A consumer project with the package installed under node_modules, and a home of its own.
function world() {
  const root = mkdtempSync(join(tmpdir(), 'ach-reg-'));
  const home = join(root, 'home');
  const project = join(root, 'project');
  const packageDir = join(project, 'node_modules', '@civitas-cerebrum', 'achilles');
  mkdirSync(home, { recursive: true });
  mkdirSync(packageDir, { recursive: true });
  writeFileSync(join(project, 'package.json'), '{"name":"consumer"}');
  const lines = [];
  const log = (l) => lines.push(l);
  const noClaude = () => ({ status: 1, stdout: '', stderr: '' });
  return { home, project, packageDir, lines, log, noClaude };
}

const local = (w, extra = {}) => ({ INIT_CWD: w.project, npm_config_global: 'false', ...extra });
const read = (f) => JSON.parse(readFileSync(f, 'utf8'));

test('scope: a registry install under node_modules is local; -g is global; the checkout itself is skipped', () => {
  const w = world();
  assert.deepEqual(scope({ env: local(w), packageDir: w.packageDir }), { isGlobal: false, isOwnCheckout: false, projectRoot: w.project, packageDir: w.packageDir });
  assert.equal(scope({ env: { npm_config_global: 'true' }, packageDir: w.packageDir }).isGlobal, true);
  assert.equal(scope({ env: { INIT_CWD: w.project }, packageDir: w.project }).isOwnCheckout, true);
  assert.equal(scope({ env: {}, packageDir: w.project }).isOwnCheckout, true);
});

test('scope: the project is the path up to the first node_modules segment: a pnpm store and a hoisted workspace both resolve to it, and stay local', () => {
  const w = world();
  const pnpm = join(w.project, 'node_modules', '.pnpm', '@civitas-cerebrum+achilles@0.3.0', 'node_modules', '@civitas-cerebrum', 'achilles');
  mkdirSync(pnpm, { recursive: true });
  const viaPnpm = scope({ env: { INIT_CWD: w.project }, packageDir: pnpm });
  assert.equal(viaPnpm.projectRoot, w.project);
  assert.equal(viaPnpm.isGlobal, false, 'a .pnpm layout never reads as a global install');
  assert.equal(viaPnpm.isOwnCheckout, false);

  const app = join(w.project, 'packages', 'app');
  mkdirSync(app, { recursive: true });
  const hoisted = scope({ env: { INIT_CWD: app }, packageDir: w.packageDir });
  assert.equal(hoisted.projectRoot, w.project, 'the workspace root that holds node_modules, not the package npm ran in');
  assert.equal(hoisted.isGlobal, false);
  assert.equal(register({ env: { INIT_CWD: app }, home: w.home, packageDir: w.packageDir, exec: w.noClaude, log: w.log }).file, join(w.project, '.claude', 'settings.local.json'));
});

test('a local install declares the marketplace and enables the plugin in the project’s settings.local.json, once', () => {
  const w = world();
  const file = join(w.project, '.claude', 'settings.local.json');
  const first = register({ env: local(w), home: w.home, packageDir: w.packageDir, exec: w.noClaude, log: w.log });
  assert.equal(first.status, 'written');
  assert.deepEqual(read(file), {
    extraKnownMarketplaces: { achilles: { source: { source: 'directory', path: w.packageDir } } },
    enabledPlugins: { [PLUGIN]: true },
  });
  assert.ok(!existsSync(join(w.home, '.claude')), 'a local install writes nothing under HOME');
  assert.ok(w.lines.some((l) => l.includes('claude plugin marketplace add')), 'the manual command is printed when claude is absent');

  const again = register({ env: local(w), home: w.home, packageDir: w.packageDir, exec: w.noClaude, log: w.log });
  assert.equal(again.status, 'present');
  assert.deepEqual(read(file).enabledPlugins, { [PLUGIN]: true });
});

test('the merge is add-only: other keys, a disabled plugin and a foreign marketplace entry survive', () => {
  const w = world();
  const file = join(w.project, '.claude', 'settings.local.json');
  mkdirSync(join(w.project, '.claude'));
  writeFileSync(file, JSON.stringify({
    permissions: { allow: ['Bash(npm test)'] },
    extraKnownMarketplaces: { other: { source: { source: 'github', repo: 'x/y' } } },
    enabledPlugins: { [PLUGIN]: false },
  }));
  const r = register({ env: local(w), home: w.home, packageDir: w.packageDir, exec: w.noClaude, log: w.log });
  assert.equal(r.status, 'written');
  assert.deepEqual(r.changed, ['extraKnownMarketplaces.achilles']);
  const s = read(file);
  assert.deepEqual(s.permissions, { allow: ['Bash(npm test)'] });
  assert.deepEqual(s.extraKnownMarketplaces.other, { source: { source: 'github', repo: 'x/y' } });
  assert.equal(s.enabledPlugins[PLUGIN], false, 'a plugin the person disabled stays disabled');
});

test('a global install writes ~/.claude/settings.json', () => {
  const w = world();
  const r = register({ env: { npm_config_global: 'true' }, home: w.home, packageDir: w.packageDir, exec: w.noClaude, log: w.log });
  assert.equal(r.status, 'written');
  assert.equal(r.file, join(w.home, '.claude', 'settings.json'));
  assert.equal(read(r.file).enabledPlugins[PLUGIN], true);
});

test('a settings file that does not parse, JSONC included, is left untouched and the manual command is printed', () => {
  for (const raw of ['{ not json', '{\n  // comments make this JSONC\n  "permissions": { "allow": [] },\n}\n']) {
    const w = world();
    const file = join(w.project, '.claude', 'settings.local.json');
    mkdirSync(join(w.project, '.claude'));
    writeFileSync(file, raw);
    const r = register({ env: local(w), home: w.home, packageDir: w.packageDir, exec: w.noClaude, log: w.log });
    assert.equal(r.status, 'unparsable');
    assert.equal(readFileSync(file, 'utf8'), raw, 'byte for byte as it was');
    assert.ok(w.lines.some((l) => l.includes('left untouched') && l.includes('claude plugin install achilles@achilles')));
  }
});

test('ACHILLES_SKIP_CLAUDE_REGISTRATION=1 writes nothing', () => {
  const w = world();
  const r = register({ env: local(w, { ACHILLES_SKIP_CLAUDE_REGISTRATION: '1' }), home: w.home, packageDir: w.packageDir, exec: w.noClaude, log: w.log });
  assert.equal(r.status, 'skipped');
  assert.ok(!existsSync(join(w.project, '.claude')));
});

test('with claude >= 2.1.287 on PATH the CLI registers (local scope, in the project); an older or failing CLI falls back to the settings write', () => {
  const w = world();
  const calls = [];
  const cli = (version, ok) => (cmd, args, options) => {
    calls.push([cmd, ...args, options?.cwd]);
    if (args[0] === '--version') return { status: 0, stdout: `${version} (Claude Code)` };
    return { status: ok ? 0 : 1, stdout: '', stderr: '' };
  };
  const viaCli = register({ env: local(w), home: w.home, packageDir: w.packageDir, exec: cli('2.1.300', true), log: w.log });
  assert.equal(viaCli.status, 'cli');
  assert.deepEqual(calls.slice(1), [
    ['claude', 'plugin', 'marketplace', 'add', w.packageDir, '--scope', 'local', w.project],
    ['claude', 'plugin', 'install', PLUGIN, '--scope', 'local', w.project],
  ]);
  assert.ok(!existsSync(join(w.project, '.claude')), 'the CLI route writes no settings itself');

  const old = register({ env: local(w), home: w.home, packageDir: w.packageDir, exec: cli('2.1.200', true), log: w.log });
  assert.equal(old.status, 'written');
  const w2 = world();
  const failing = register({ env: local(w2), home: w2.home, packageDir: w2.packageDir, exec: cli('2.1.300', false), log: w2.log });
  assert.equal(failing.status, 'written');
  const global = register({ env: { npm_config_global: 'true' }, home: w2.home, packageDir: w2.packageDir, exec: cli('2.1.300', true), log: w2.log });
  assert.equal(global.scope, 'user');
});

test('merge on a bare object adds exactly the two keys', () => {
  assert.deepEqual(merge({}, '/pkg'), ['extraKnownMarketplaces.achilles', `enabledPlugins["${PLUGIN}"]`]);
});
