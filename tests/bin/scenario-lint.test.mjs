import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DEFAULT_ENUMS, lintScenarioText, normalise } from '../../bin/scenario-lint.mjs';

const CLI = new URL('../../bin/scenario-lint.mjs', import.meta.url).pathname;
const RULES = { rules: { 'specs.shape': { titleIdPattern: '^TC-\\d{4} — ' } } };
const GOOD = `#### TC-0001 — Guest checkout with one item

- **Contexts**: region-1
- **Type**: @e2e @checkout
- **Purpose**: A guest can buy one item.
- **Preconditions / test data**: an open shop with at least one item; env BASE_URL
- **Steps**:
  1. Add an item to the basket
  2. Check out as a guest
- **Expected**: the confirmation page shows "Thank you"
- **Oracle**: UI-only
- **Spend policy**: none
- **Status**: proposed
`;
const MISSING = GOOD.replace(/^- \*\*Spend policy\*\*:.*\n/m, '');

function project(block) {
  const d = mkdtempSync(join(tmpdir(), 'sl-'));
  mkdirSync(join(d, 'docs'));
  writeFileSync(join(d, 'achilles-factory-rules.json'), JSON.stringify(RULES));
  writeFileSync(join(d, 'docs/scenarios.md'), block);
  return d;
}
const run = (args, cwd) => spawnSync(process.execPath, [CLI, ...args], { cwd, encoding: 'utf8', env: { ...process.env, CLAUDE_PROJECT_DIR: cwd } });

test('a complete block passes', () => {
  const r = run(['docs/scenarios.md'], project(GOOD));
  assert.equal(r.status, 0, r.stderr);
});

test('a block missing a field is refused with the three-line message', () => {
  const r = run(['docs/scenarios.md'], project(MISSING));
  assert.equal(r.status, 1);
  assert.match(r.stderr, /\[specs\.shape\]/);
  assert.match(r.stderr, /→ Do:/);
  assert.match(r.stderr, /→ Why\/how:/);
});

test('file arguments resolve against the project root, not the cwd', () => {
  const d = project(GOOD);
  const r = spawnSync(process.execPath, [CLI, 'docs/scenarios.md'], { cwd: tmpdir(), encoding: 'utf8', env: { ...process.env, CLAUDE_PROJECT_DIR: d } });
  assert.equal(r.status, 0, r.stderr);
});

test('--json prints parseable findings', () => {
  const r = run(['--json', 'docs/scenarios.md'], project(MISSING));
  const out = JSON.parse(r.stdout);
  assert.equal(out.ok, false);
  assert.equal(out.blocks[0].id, 'TC-0001');
});

test('--id selects one scenario', () => {
  const d = project(GOOD);
  assert.equal(run(['--id', 'TC-0001', 'docs/scenarios.md'], d).status, 0);
  assert.equal(run(['--id', 'TC-9999', 'docs/scenarios.md'], d).status, 1);
});

test('an unknown flag is a usage error (exit 2)', () => assert.equal(run(['--nope'], project(GOOD)).status, 2));

test('a missing document is a usage error (exit 2)', () => assert.equal(run(['nope.md'], project(GOOD)).status, 2));

test('no rules file is a config error (exit 2)', () => {
  const d = mkdtempSync(join(tmpdir(), 'sl-'));
  assert.equal(run(['x.md'], d).status, 2);
});

test('normalise maps prose onto enum tokens', () => {
  assert.equal(normalise('red by design (reason)'), 'red-by-design-(reason)');
  assert.equal(normalise('green 3× (date)'), 'green-(date)');
  assert.ok(DEFAULT_ENUMS.status.includes(normalise('Proposed')));
});

test('lintScenarioText reports a block with no errors for a complete block and names the missing field otherwise', () => {
  process.env.CLAUDE_PROJECT_DIR = project(GOOD);
  assert.deepEqual(lintScenarioText(GOOD).blocks.map((b) => b.errors), [[]]);
  const [bad] = lintScenarioText(MISSING).blocks;
  assert.match(bad.errors[0].message, /Spend policy/);
});
