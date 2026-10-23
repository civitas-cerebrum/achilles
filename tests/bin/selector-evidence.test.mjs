import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const CLI = new URL('../../bin/selector-evidence.mjs', import.meta.url).pathname;

test('the repository default comes from rules["selectors.evidence"].repository', () => {
  const d = mkdtempSync(join(tmpdir(), 'se-'));
  writeFileSync(join(d, 'achilles-factory-rules.json'), JSON.stringify({ rules: { 'selectors.evidence': { repository: 'custom/repo.json', evidenceDir: 'ev' } } }));
  const r = spawnSync(process.execPath, [CLI, '--page', 'P', '--element', 'e', '--base-url', 'https://x.example.test', '--anonymous'], { cwd: d, encoding: 'utf8', env: { ...process.env, CLAUDE_PROJECT_DIR: d } });
  assert.equal(r.status, 2);
  assert.match(r.stderr + r.stdout, /custom\/repo\.json/);
});

test('--help exits 0', () => assert.equal(spawnSync(process.execPath, [CLI, '--help'], { encoding: 'utf8' }).status, 0));
