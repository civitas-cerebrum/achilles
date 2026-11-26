import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { baselineFindings, normalise, ruleSections } from '../../scripts/lint/test-baseline.mjs';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const BASELINE = 'skills/achilles-orchestrator/references/test-baseline.md';

const RULEBOOK = `# Test baseline

## Waivers

Waiver grammar.

<a id="tb-a1"></a>
#### TB-A1 No raw locators

A spec reaches elements only by repository name through the Steps API, never through \`page.locator()\` on a driver binding. A second sentence.

- **Severity** blocking

#### TB-A2

A spec makes no member call on a driver binding unless the method is listed.

See [TB-A1](#tb-a1) and [waivers](#waivers).
`;

// A throwaway repo tree: { relative path: contents }.
function tree(files) {
  const root = mkdtempSync(join(tmpdir(), 'tb-lint-'));
  for (const [rel, text] of Object.entries(files)) {
    mkdirSync(dirname(join(root, rel)), { recursive: true });
    writeFileSync(join(root, rel), text);
  }
  return root;
}

test('rule sections: id, anchor and the first sentence (periods inside backticks do not end it)', () => {
  const rules = ruleSections(RULEBOOK);
  assert.deepEqual(rules.map((r) => r.id), ['A1', 'A2']);
  assert.equal(rules[0].normative, 'A spec reaches elements only by repository name through the Steps API, never through `page.locator()` on a driver binding.');
});

test('normalise drops case, punctuation, backticks and line breaks', () => {
  assert.equal(normalise('A spec, `never`\n  through   Page.Locator().'), 'a spec never through page locator');
});

test('a clean tree passes both checks', () => {
  const root = tree({
    [BASELINE]: RULEBOOK,
    'skills/test-composer/SKILL.md': 'Raw locators: [`test-baseline.md`](../achilles-orchestrator/references/test-baseline.md#tb-a1).\n',
    'docs/harness/claude-code.md': 'See test-baseline.md#tb-a2 and test-baseline.md#waivers.\n',
  });
  const f = baselineFindings(root);
  assert.deepEqual(f.citations, []);
  assert.deepEqual(f.restated, []);
  assert.deepEqual(f.rules, []);
});

test('a citation of a missing anchor fails with file and line', () => {
  const root = tree({
    [BASELINE]: RULEBOOK,
    'skills/review/SKILL.md': 'line one\nCheck [TB-A9](../achilles-orchestrator/references/test-baseline.md#tb-a9).\n',
  });
  const f = baselineFindings(root);
  assert.equal(f.citations.length, 1);
  assert.match(f.citations[0], /skills\/review\/SKILL\.md:2: .*#tb-a9/);
});

test('an in-file link to a missing anchor fails', () => {
  const root = tree({ [BASELINE]: RULEBOOK + '\nSee [TB-Z1](#tb-z1).\n' });
  const f = baselineFindings(root);
  assert.equal(f.citations.length, 1);
  assert.match(f.citations[0], /#tb-z1/);
});

test('a rule heading whose slug is longer than tb-<id> and has no explicit anchor fails', () => {
  const root = tree({ [BASELINE]: RULEBOOK + '\n#### TB-A3 No web-first assertions\n\nAssertions about pages go through the Steps verification methods only.\n' });
  const f = baselineFindings(root);
  assert.equal(f.rules.length, 1);
  assert.match(f.rules[0], /TB-A3.*tb-a3/);
});

test('a normative sentence shorter than six words fails', () => {
  const root = tree({ [BASELINE]: RULEBOOK + '\n<a id="tb-a4"></a>\n#### TB-A4 No scripting\n\nNo page scripting.\n' });
  const f = baselineFindings(root);
  assert.equal(f.rules.length, 1);
  assert.match(f.rules[0], /TB-A4.*six words/);
});

test('a normative sentence restated in another skill fails, whatever its case, punctuation or wrapping', () => {
  const root = tree({
    [BASELINE]: RULEBOOK,
    'skills/test-composer/SKILL.md': 'Rules:\n- a spec makes no member call on a driver binding,\n  unless the method is LISTED!\n',
  });
  const f = baselineFindings(root);
  assert.equal(f.restated.length, 1);
  assert.match(f.restated[0], /skills\/test-composer\/SKILL\.md.*TB-A2/);
});

test('the restated check covers skills/ only; other trees may quote a rule', () => {
  const root = tree({
    [BASELINE]: RULEBOOK,
    'docs/harness/claude-code.md': 'A spec makes no member call on a driver binding unless the method is listed.\n',
  });
  assert.deepEqual(baselineFindings(root).restated, []);
});

test('an absent rulebook is a finding, not a crash', () => {
  const root = tree({ 'skills/review/SKILL.md': 'See test-baseline.md#tb-a1.\n' });
  const f = baselineFindings(root);
  assert.equal(f.rules.length, 1);
  assert.match(f.rules[0], /not found/);
});

test('this repository passes both checks', () => {
  const f = baselineFindings(REPO);
  assert.deepEqual(f.rules, []);
  assert.deepEqual(f.citations, []);
  assert.deepEqual(f.restated, []);
  const ids = ruleSections(readFileSync(join(REPO, BASELINE), 'utf8')).map((r) => r.id);
  const range = (f, n) => Array.from({ length: n }, (_, i) => `${f}${i + (f === 'G' ? 0 : 1)}`);
  const expected = [...range('A', 14), 'A2b', ...range('F', 7), ...range('S', 9), 'S2a', ...range('I', 4), ...range('R', 8),
    ...range('D', 5), ...range('W', 2), ...range('X', 4), ...range('P', 3), ...range('N', 4), ...range('K', 4), ...range('G', 3)];
  assert.deepEqual([...ids].sort(), [...expected].sort());
});
