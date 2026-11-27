// The since-label check of lint-doc-drift (scripts/lint/since-labels.mjs): every "<version>+" label of the
// Steps API reference names the first published release of the Steps methods it labels.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { firstReleases, sinceLabels, sinceProblems, API_REFERENCE } from '../../scripts/lint/since-labels.mjs';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const first = firstReleases(REPO);

test('the first releases come from the published surfaces', () => {
  assert.equal(first.get('getUrl'), '0.3.7');
  assert.equal(first.get('waitForUrl'), '0.3.7');
  for (const m of ['waitForLoadState', 'dispatchEvent', 'getPageText', 'getBoundingBox', 'evaluateScript', 'getWindowProperty', 'requestGet', 'pressKeys', 'verifyPageTitle']) assert.equal(first.get(m), '0.3.8', m);
  assert.equal(first.get('getLocalStorage'), '0.3.5');
  assert.equal(first.get('forPage'), '0.3.12');
});

test('the shipped API reference has no since label that disagrees with the surfaces', () => {
  assert.deepEqual(sinceProblems(readFileSync(join(REPO, API_REFERENCE), 'utf8'), first), []);
});

test('labels attach to the line\'s calls, a comment\'s block, a heading\'s section and backticked names', () => {
  const doc = [
    '## Navigation (0.3.8+)',
    '',
    '```ts',
    'await steps.waitForLoadState(\'load\');',
    'await steps.navigateTo(\'/\');',
    '```',
    '',
    '## Other',
    '',
    '```ts',
    'const url = steps.getUrl(); // 0.3.7+',
    '// URL getters (0.3.7+)',
    '// a second comment line',
    'steps.getUrl();',
    'steps.getCurrentPath();',
    '',
    'steps.forPage(p);',
    '```',
    '',
    '**`dispatchEvent` (0.3.8+).** prose',
  ].join('\n');
  assert.deepEqual(sinceLabels(doc).map((l) => [l.line, l.label, l.methods]), [
    [1, '0.3.8', ['waitForLoadState', 'navigateTo']],
    [11, '0.3.7', ['getUrl']],
    [12, '0.3.7', ['getUrl', 'getCurrentPath']],
    [20, '0.3.8', ['dispatchEvent']],
  ]);
  assert.deepEqual(sinceProblems(doc, first), []);
});

test('a wrong label and a label on an option are refused', () => {
  const doc = [
    '```ts',
    'const url = steps.getUrl();          // 0.3.9+',
    'await steps.navigateTo(\'/\', { waitUntil: \'load\' }); // 0.3.7+',
    'await steps.navigateTo(\'/\', { waitUntil: \'load\' }); // waitUntil from 0.3.7',
    '```',
    '> **`"list": true` entries (0.3.12+).**',
  ].join('\n');
  const p = sinceProblems(doc, first, 'api.md');
  assert.equal(p.length, 3, p.join('\n'));
  assert.match(p[0], /^api\.md:2: labelled 0\.3\.9\+, but the newest of its methods \(getUrl 0\.3\.7\) first shipped in 0\.3\.7$/);
  assert.match(p[1], /^api\.md:3: labelled 0\.3\.7\+, but .*navigateTo 0\.1\.1/);
  assert.match(p[2], /^api\.md:6: the since label 0\.3\.12\+ names no Steps method/);
});
