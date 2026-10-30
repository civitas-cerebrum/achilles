// The test-ID scanner the spec-hygiene hook runs as a child process (stdin mode), against the
// cases of the 0.2.x spec 74: added untagged cases and new duplicates are reported; pre-existing
// untagged cases, describe/step titles, commented-out tests and in-body skips are not.
const { spawnSync } = require('child_process');
const path = require('path');

const scanner = path.join(__dirname, '../../../lib/test-id-scan.js');
const scan = (before, after, pattern) =>
  JSON.parse(spawnSync(process.execPath, [scanner, '--stdin'], { input: JSON.stringify({ before, after }), encoding: 'utf8', env: { ...process.env, CIVITAS_TEST_ID_PATTERN: pattern ?? '' } }).stdout);
const t = (title) => `test('${title}', async ({ steps }) => {});`;
const LEGACY = t('a case written before the convention existed');
const PROJECT = '^[A-Z]{2,5}-\\d{2,3}[a-z]? — ';

const cases = [
  ['new tagged case → clean', '', `${t('TCLG-000001 · valid credentials reach the dashboard')}\n${t('TCLG-000002 · MFA is offered')}`, undefined, [], []],
  ['bracketed ID → clean', '', t('[TCSG-000012] a decimal employee count is rejected'), undefined, [], []],
  ['describe and step titles are not cases', '', `test.describe('Login', () => { test.step('fill', async () => {}); ${t('TCLG-000001 · ok')} });`, undefined, [], []],
  ['commented-out untagged test', '', `// ${t('an idea we parked')}\n${t('TCLG-000001 · ok')}`, undefined, [], []],
  ['in-body test.skip(condition, reason)', '', `test('TCLG-000001 · ok', async () => { test.skip(browserName === 'firefox', 'not supported yet'); });`, undefined, [], []],
  ['legacy untagged case carried through an edit', LEGACY, `import { expect } from '@playwright/test';\n${LEGACY}`, undefined, [], []],
  ['appended untagged case', t('TCLG-000001 · ok'), `${t('TCLG-000001 · ok')}\n${t('a wrong password is rejected')}`, undefined, ['a wrong password is rejected'], []],
  ['untagged test.fail case', LEGACY, `${LEGACY}\ntest.fail('an unfiled defect reproduces', async () => {});`, undefined, ['an unfiled defect reproduces'], []],
  ['ID with no behaviour sentence', '', t('TCLG-000099'), undefined, ['TCLG-000099'], []],
  ['lowercase ID', '', t('tclg-000420 · a wrong password'), undefined, ['tclg-000420 · a wrong password'], []],
  ['3-digit ordinal', '', t('TCLG-042 · too few digits'), undefined, ['TCLG-042 · too few digits'], []],
  ['same ID twice', '', `${t('TCLG-000001 · a')}\n${t('TCLG-000001 · b')}`, undefined, [], ['TCLG-000001']],
  ['pinned pattern, matching ID', '', t('TCLG-000420 · a'), '^(TC[A-Z]{2}-[0-9]{4,6})', [], []],
  ['pinned pattern, ID the default would accept', '', t('TC-0042 · a'), '^(TC[A-Z]{2}-[0-9]{4,6})', ['TC-0042 · a'], []],
  ['unparseable pattern falls back to the default', '', t('TCLG-000420 · a'), '^(TC[A-Z', [], []],
  ['project titleIdPattern without a group', '', t('CHK-03 — Card: place an order'), PROJECT, [], []],
  ['project pattern, no id', '', t('place an order'), PROJECT, ['place an order'], []],
  ['project pattern matched, no behaviour sentence', '', t('CHK-03 — '), PROJECT, ['CHK-03 — '], []],
  ['duplicate id under a group-less pattern', '', `${t('CHK-03 — a')}\n${t('CHK-03 — b')}`, PROJECT, [], ['CHK-03']],
];

let failed = 0;
for (const [name, before, after, pattern, untagged, dups] of cases) {
  const r = scan(before, after, pattern);
  const ok = JSON.stringify(r.untagged) === JSON.stringify(untagged) && JSON.stringify(r.duplicates.map((d) => d.id)) === JSON.stringify(dups);
  if (!ok) failed++;
  console[ok ? 'log' : 'error'](`  ${ok ? '✓' : '✗'} ${name}${ok ? '' : ` — got ${JSON.stringify(r)}`}`);
}
console.log(`\n${cases.length - failed}/${cases.length} passed`);
process.exit(failed === 0 ? 0 : 1);
