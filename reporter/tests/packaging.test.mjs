// Packaging coverage. `files[]` in package.json governs the published tarball;
// a directory outside it is silently omitted, and a feature that is not in the
// tarball does not exist for consumers. These tests pack the real package and
// assert against the extracted tarball, so a future `files[]` or `exports` edit
// that drops the reporter fails here instead of after a release.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');

// The specifier the docs tell consumers to put in `reporter: [...]`.
const DOCUMENTED_SPECIFIER = '@civitas-cerebrum/achilles/reporter';

let packed = null;
function pack() {
  if (packed) return packed;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ach-pack-'));
  // --ignore-scripts mirrors the publish workflow, which packs with lifecycle
  // scripts disabled: whatever is in the tree is what ships, unbuilt.
  const result = spawnSync('npm', ['pack', '--ignore-scripts', '--pack-destination', dir], {
    cwd: repo, encoding: 'utf8',
  });
  assert.equal(result.status, 0, `npm pack failed: ${result.stderr}`);
  const tarball = fs.readdirSync(dir).find((n) => n.endsWith('.tgz'));
  assert.ok(tarball, 'npm pack produced a tarball');
  const extracted = path.join(dir, 'extracted');
  fs.mkdirSync(extracted);
  const untar = spawnSync('tar', ['-xzf', path.join(dir, tarball), '-C', extracted], { encoding: 'utf8' });
  assert.equal(untar.status, 0, `tar failed: ${untar.stderr}`);
  packed = { dir, pkg: path.join(extracted, 'package') };
  process.on('exit', () => { try { fs.rmSync(dir, { recursive: true, force: true }); } catch { /* best effort */ } });
  return packed;
}

test('the reporter is in the published tarball', () => {
  const { pkg } = pack();
  for (const file of ['reporter/index.js', 'reporter/lib/archive.js', 'reporter/lib/classify.js',
    'reporter/lib/format.js', 'reporter/lib/history.js', 'reporter/lib/paths.js', 'reporter/lib/safe.js']) {
    assert.ok(fs.existsSync(path.join(pkg, file)), `${file} missing from the tarball`);
  }
});

test('the reporter needs no build step to work from the tarball', () => {
  // The publish workflow runs `npm publish --ignore-scripts`, so nothing
  // compiles at release time. Requiring straight out of the tarball proves
  // the shipped files are the runnable ones.
  const { pkg } = pack();
  const probe = spawnSync(process.execPath, ['-e',
    `const R = require(${JSON.stringify(path.join(pkg, 'reporter', 'index.js'))});
     if (typeof R !== 'function') throw new Error('not a constructor');
     const r = new R({});
     if (typeof r.onTestEnd !== 'function') throw new Error('no onTestEnd');
     if (typeof r.printsToStdio !== 'function') throw new Error('no printsToStdio');
     process.stdout.write('ok');`], { encoding: 'utf8' });
  assert.equal(probe.status, 0, probe.stderr);
  assert.equal(probe.stdout, 'ok');
});

test('the documented specifier resolves from an installed package', () => {
  const { pkg } = pack();
  const consumer = fs.mkdtempSync(path.join(os.tmpdir(), 'ach-consumer-'));
  const target = path.join(consumer, 'node_modules', '@civitas-cerebrum', 'achilles');
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.cpSync(pkg, target, { recursive: true });
  fs.writeFileSync(path.join(consumer, 'package.json'), JSON.stringify({ name: 'consumer', version: '1.0.0' }));

  const probe = spawnSync(process.execPath, ['-e',
    `const R = require(${JSON.stringify(DOCUMENTED_SPECIFIER)});
     if (typeof R !== 'function') throw new Error('specifier did not resolve to the reporter');
     process.stdout.write('ok');`], { cwd: consumer, encoding: 'utf8' });
  assert.equal(probe.status, 0, `${DOCUMENTED_SPECIFIER} is not requirable: ${probe.stderr}`);
  assert.equal(probe.stdout, 'ok');
  fs.rmSync(consumer, { recursive: true, force: true });
});

test('adding exports did not make the shipped directories unreachable', () => {
  // An `exports` map is an allowlist: every subpath a consumer could previously
  // reach becomes unreachable unless it is mapped. These are the paths the
  // package ships and therefore the ones that must stay resolvable.
  const { pkg } = pack();
  const consumer = fs.mkdtempSync(path.join(os.tmpdir(), 'ach-consumer-'));
  const target = path.join(consumer, 'node_modules', '@civitas-cerebrum', 'achilles');
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.cpSync(pkg, target, { recursive: true });
  fs.writeFileSync(path.join(consumer, 'package.json'), JSON.stringify({ name: 'consumer', version: '1.0.0' }));

  const subpaths = [
    '@civitas-cerebrum/achilles/package.json',
    '@civitas-cerebrum/achilles/hooks/playwright-artifact-archiver.sh',
    '@civitas-cerebrum/achilles/skills/onboarding/SKILL.md',
    '@civitas-cerebrum/achilles/schemas/onboarding-status.schema.json',
    '@civitas-cerebrum/achilles/bin/show.mjs',
    '@civitas-cerebrum/achilles/scripts/postinstall.js',
  ];
  for (const specifier of subpaths) {
    const probe = spawnSync(process.execPath, ['-e',
      `require.resolve(${JSON.stringify(specifier)}); process.stdout.write('ok');`], { cwd: consumer, encoding: 'utf8' });
    assert.equal(probe.status, 0, `${specifier} became unreachable: ${probe.stderr}`);
  }
  fs.rmSync(consumer, { recursive: true, force: true });
});

test('the tarball ships the reporter without its test suite', () => {
  const { pkg } = pack();
  assert.ok(!fs.existsSync(path.join(pkg, 'reporter', 'tests')), 'dev-only tests must not ship');
});
