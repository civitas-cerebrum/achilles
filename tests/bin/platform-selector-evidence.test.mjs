// achilles-selector-evidence --platform <android|ios>: offline evidence from the page source and screenshot an expert
// captured with `npx wdio session`. Fixtures are fake XCUITest / UiAutomator2 sources; every value is invented.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const CLI = new URL('../../bin/selector-evidence.mjs', import.meta.url).pathname;
const FIX = new URL('./fixtures/platform-evidence/', import.meta.url).pathname;
const C6 = ['selector', 'platform', 'capabilities', 'screen', 'resolved count', 'class', 'accessibility id', 'id', 'label', 'source snippet', 'screenshot', 'source'];
// A valid PNG signature is all the tool checks; the bytes after it are never decoded.
const PNG = Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), Buffer.from('fake-png-body')]);
const FAKE_UDID = '00000000-0000000000000000';

// Any attempt to load a browser driver fails loudly: the platform mode must never start Chromium.
const GUARD = `const M = require('module'); const load = M._load;
M._load = function (req, ...rest) {
  if (/^(@playwright\\/test|playwright|playwright-core|@civitas-cerebrum\\/element-repository)(\\/|$)/.test(req)) throw new Error('CHROMIUM_GUARD: ' + req);
  return load.call(this, req, ...rest);
};`;

/** A throwaway project: one repository, capability files, the captured inspection material. */
function project(pages, { caps = { platformName: 'iOS', 'appium:automationName': 'XCUITest', 'appium:udid': FAKE_UDID } } = {}) {
  const d = mkdtempSync(join(tmpdir(), 'pse-'));
  mkdirSync(join(d, 'tests/e2e'), { recursive: true });
  mkdirSync(join(d, 'tests/capabilities'), { recursive: true });
  mkdirSync(join(d, 'inspect'), { recursive: true });
  writeFileSync(join(d, 'tests/e2e/page-repository.json'), JSON.stringify({ pages }, null, 2));
  writeFileSync(join(d, 'tests/capabilities/phone.json'), JSON.stringify(caps));
  writeFileSync(join(d, 'tests/capabilities/android.json'), JSON.stringify({ platformName: 'Android', 'appium:automationName': 'UiAutomator2', 'appium:udid': FAKE_UDID }));
  copyFileSync(join(FIX, 'ios-source.xml'), join(d, 'inspect/ios.xml'));
  copyFileSync(join(FIX, 'android-source.xml'), join(d, 'inspect/android.xml'));
  writeFileSync(join(d, 'inspect/shot.png'), PNG);
  writeFileSync(join(d, 'guard.cjs'), GUARD);
  return d;
}

function run(d, args) {
  const r = spawnSync(process.execPath, ['--require', join(d, 'guard.cjs'), CLI, ...args], {
    cwd: d,
    encoding: 'utf8',
    env: { ...process.env, CLAUDE_PROJECT_DIR: d, FACTORY_RULES: '' },
  });
  return { ...r, out: r.stdout + r.stderr };
}

const ios = (page, element, extra = []) => ['--platform', 'ios', '--page', page, '--element', element, '--capabilities', 'tests/capabilities/phone.json', '--screen', 'Settings', '--source', 'inspect/ios.xml', '--screenshot', 'inspect/shot.png', ...extra];
const android = (page, element, extra = []) => ['--platform', 'android', '--page', page, '--element', element, '--capabilities', 'tests/capabilities/android.json', '--screen', 'Settings', '--source', 'inspect/android.xml', '--screenshot', 'inspect/shot.png', ...extra];
const iosPage = (elements) => ({ name: 'SettingsPage', platform: 'ios', elements });
const androidPage = (elements) => ({ name: 'SettingsPage', platform: 'android', elements });
const el = (elementName, selector, more = {}) => ({ elementName, selector, ...more });

/** The note as [field, value] pairs, the heading dropped. */
function fields(text) {
  return text.trim().split('\n').slice(1).map((l) => {
    const m = /^- ([a-z ]+): (.*)$/.exec(l);
    assert.ok(m, `not a field line: ${l}`);
    return [m[1], m[2]];
  });
}
const note = (d, file) => readFileSync(join(d, 'docs/evidence/selectors', file), 'utf8');

test('ios accessibility id: count 1 writes the note with every C6 field in order and copies the screenshot', () => {
  const d = project([{ name: 'SettingsPage', elements: [el('networkRow', { css: '#web-only' })] }, iosPage([el('networkRow', { 'accessibility id': 'example.row.network' })])]);
  const r = run(d, ios('SettingsPage', 'networkRow'));
  assert.equal(r.status, 0, r.out);
  const text = note(d, 'SettingsPage.networkRow.ios.md');
  assert.equal(text.split('\n')[0], '# SettingsPage.networkRow (ios)');
  const f = fields(text);
  assert.deepEqual(f.map(([k]) => k), C6);
  const v = Object.fromEntries(f);
  assert.deepEqual(JSON.parse(v.selector), { 'accessibility id': 'example.row.network' });
  assert.equal(v.platform, 'ios');
  assert.equal(v.capabilities, 'tests/capabilities/phone.json');
  assert.equal(v.screen, 'Settings');
  assert.equal(v['resolved count'], '1');
  assert.equal(v.class, 'XCUIElementTypeCell');
  assert.equal(v['accessibility id'], 'example.row.network');
  assert.equal(v.id, 'example.row.network');
  assert.equal(v.label, '"Network"');
  assert.match(v['source snippet'], /^`<XCUIElementTypeCell type="XCUIElementTypeCell" name="example\.row\.network"/);
  assert.equal(v.screenshot, 'SettingsPage.networkRow.ios.png');
  assert.match(v.source, /^live/);
  assert.deepEqual(readFileSync(join(d, 'docs/evidence/selectors/SettingsPage.networkRow.ios.png')), PNG);
  assert.doesNotMatch(text, new RegExp(FAKE_UDID), 'no capability value is copied into the note');
  assert.doesNotMatch(text, /XCUITest"|automationName/);
});

test('android id (full and short resource-id), uiautomator and text resolve; fields come from the UiAutomator2 attributes', () => {
  const d = project([androidPage([
    el('save', { id: 'com.example.app:id/save' }),
    el('saveShort', { id: 'save' }),
    el('soundRow', { uiautomator: 'new UiSelector().text("Sound")' }),
    el('networkRow', { text: 'Network' }),
    el('networkDesc', { 'accessibility id': 'row-network' }),
  ])]);
  for (const name of ['save', 'saveShort', 'soundRow', 'networkRow', 'networkDesc']) assert.equal(run(d, android('SettingsPage', name)).status, 0, name);
  const v = Object.fromEntries(fields(note(d, 'SettingsPage.save.android.md')));
  assert.equal(v.platform, 'android');
  assert.equal(v.capabilities, 'tests/capabilities/android.json');
  assert.equal(v['resolved count'], '1');
  assert.equal(v.class, 'android.widget.Button');
  assert.equal(v.id, 'com.example.app:id/save');
  assert.equal(v['accessibility id'], '—');
  assert.equal(v.label, '"Save"');
  assert.equal(Object.fromEntries(fields(note(d, 'SettingsPage.saveShort.android.md'))).id, 'com.example.app:id/save');
  assert.equal(Object.fromEntries(fields(note(d, 'SettingsPage.soundRow.android.md'))).label, '"Sound"');
  const desc = Object.fromEntries(fields(note(d, 'SettingsPage.networkDesc.android.md')));
  assert.equal(desc['accessibility id'], 'row-network');
  assert.equal(desc.label, '"Network"');
});

test('ios predicate, class chain, text and class name resolve against the page source', () => {
  const d = project([iosPage([
    el('soundByPredicate', { predicate: "label == 'Sound' AND type == 'XCUIElementTypeCell'" }),
    el('networkByChain', { 'class chain': '**/XCUIElementTypeCell[`name == "example.row.network"`]' }),
    el('supportByText', { text: 'Support & Help' }),
    el('tableByClass', { 'class name': 'XCUIElementTypeTable' }),
  ])]);
  for (const name of ['soundByPredicate', 'networkByChain', 'supportByText', 'tableByClass']) {
    const r = run(d, ios('SettingsPage', name));
    assert.equal(r.status, 0, `${name}: ${r.out}`);
    assert.equal(Object.fromEntries(fields(note(d, `SettingsPage.${name}.ios.md`)))['resolved count'], '1', name);
  }
  assert.equal(Object.fromEntries(fields(note(d, 'SettingsPage.supportByText.ios.md'))).label, '"Support & Help"');
});

test('count 0 is refused with no file written', () => {
  const d = project([iosPage([el('ghost', { 'accessibility id': 'example.row.missing' })])]);
  const r = run(d, ios('SettingsPage', 'ghost'));
  assert.equal(r.status, 1, r.out);
  assert.match(r.out, /SettingsPage\.ghost resolved to 0 elements on screen Settings/);
  assert.equal(existsSync(join(d, 'docs/evidence/selectors/SettingsPage.ghost.ios.md')), false);
});

test('count many is refused with the candidates named; a "list": true entry accepts many', () => {
  const d = project([iosPage([el('edit', { 'accessibility id': 'Edit' }), el('cells', { 'class name': 'XCUIElementTypeCell' }, { list: true })])]);
  const r = run(d, ios('SettingsPage', 'edit'));
  assert.equal(r.status, 1, r.out);
  assert.match(r.out, /resolved to 2 elements/);
  assert.match(r.out, /candidates: XCUIElementTypeButton "Edit"/);
  assert.equal(existsSync(join(d, 'docs/evidence/selectors/SettingsPage.edit.ios.md')), false);
  const l = run(d, ios('SettingsPage', 'cells'));
  assert.equal(l.status, 0, l.out);
  assert.equal(Object.fromEntries(fields(note(d, 'SettingsPage.cells.ios.md')))['resolved count'], '3 (list entry)');
});

test('xpath: attribute predicates resolve; a positional xpath resolves and is flagged; an expression outside the subset is "unresolved offline"', () => {
  const d = project([iosPage([
    el('byAttr', { xpath: '//XCUIElementTypeCell[@name="example.row.sound"]' }),
    el('byIndex', { xpath: '(//XCUIElementTypeCell)[2]' }),
    el('byStepIndex', { xpath: '//XCUIElementTypeTable/XCUIElementTypeCell[1]' }),
    el('byAxis', { xpath: '//XCUIElementTypeCell[following-sibling::XCUIElementTypeButton]' }),
  ])]);
  assert.equal(run(d, ios('SettingsPage', 'byAttr')).status, 0);
  const attr = Object.fromEntries(fields(note(d, 'SettingsPage.byAttr.ios.md')));
  assert.equal(attr['resolved count'], '1');
  assert.equal(attr['accessibility id'], 'example.row.sound');

  assert.equal(run(d, ios('SettingsPage', 'byIndex')).status, 0);
  const idx = Object.fromEntries(fields(note(d, 'SettingsPage.byIndex.ios.md')));
  assert.match(idx['resolved count'], /^1 \(positional\b/);
  assert.equal(idx['accessibility id'], 'example.row.sound');

  assert.equal(run(d, ios('SettingsPage', 'byStepIndex')).status, 0);
  const step = Object.fromEntries(fields(note(d, 'SettingsPage.byStepIndex.ios.md')));
  assert.match(step['resolved count'], /^1 \(positional\b/);
  assert.equal(step['accessibility id'], 'example.row.network');

  const ax = run(d, ios('SettingsPage', 'byAxis'));
  assert.equal(ax.status, 0, ax.out);
  const axis = Object.fromEntries(fields(note(d, 'SettingsPage.byAxis.ios.md')));
  assert.match(axis['resolved count'], /^unresolved offline \(/);
  assert.equal(axis.class, '—');
  assert.match(ax.stderr, /unresolved offline/);
});

test('forms outside the offline subset are recorded as "unresolved offline", never with a count', () => {
  const d = project([iosPage([el('orPredicate', { predicate: "label == 'Sound' OR label == 'Network'" })]), androidPage([el('scrollable', { uiautomator: 'new UiScrollable(new UiSelector().scrollable(true)).scrollIntoView(new UiSelector().text("Save"))' })])]);
  assert.equal(run(d, ios('SettingsPage', 'orPredicate')).status, 0);
  assert.match(Object.fromEntries(fields(note(d, 'SettingsPage.orPredicate.ios.md')))['resolved count'], /^unresolved offline/);
  assert.equal(run(d, android('SettingsPage', 'scrollable')).status, 0);
  assert.match(Object.fromEntries(fields(note(d, 'SettingsPage.scrollable.android.md')))['resolved count'], /^unresolved offline/);
});

test('capabilities: inline values are refused, a path outside tests/capabilities/ is refused, a mismatched platformName is refused', () => {
  const d = project([iosPage([el('networkRow', { 'accessibility id': 'example.row.network' })])]);
  const base = ios('SettingsPage', 'networkRow');
  const withCaps = (c) => base.map((a, i) => (base[i - 1] === '--capabilities' ? c : a));
  const inline = run(d, withCaps(JSON.stringify({ platformName: 'iOS', 'appium:udid': FAKE_UDID })));
  assert.equal(inline.status, 2);
  assert.match(inline.out, /capability values inline/);
  assert.doesNotMatch(inline.out, new RegExp(FAKE_UDID));
  writeFileSync(join(d, 'caps.json'), '{}');
  for (const p of ['caps.json', 'tests/capabilities/../../caps.json', join(d, 'caps.json')]) {
    const r = run(d, withCaps(p));
    assert.equal(r.status, 2, p);
    assert.match(r.out, /outside tests\/capabilities\//, p);
  }
  const mismatch = run(d, withCaps('tests/capabilities/android.json'));
  assert.equal(mismatch.status, 2);
  assert.match(mismatch.out, /platformName/);
  assert.equal(existsSync(join(d, 'docs/evidence/selectors')), false);
});

test('macos and windows are declared but not implemented yet; an unknown platform is a usage error', () => {
  const d = project([iosPage([el('networkRow', { 'accessibility id': 'example.row.network' })])]);
  for (const p of ['macos', 'windows']) {
    const r = run(d, ['--platform', p, '--page', 'SettingsPage', '--element', 'networkRow']);
    assert.equal(r.status, 2, p);
    assert.match(r.out, new RegExp(`${p}.*declared but not implemented yet`));
  }
  const r = run(d, ['--platform', 'tvos', '--page', 'SettingsPage', '--element', 'networkRow']);
  assert.equal(r.status, 2);
  assert.match(r.out, /android \| ios/);
});

test('no Chromium: the platform mode loads no browser package, while the web mode trips the same guard', () => {
  const d = project([iosPage([el('networkRow', { 'accessibility id': 'example.row.network' })]), { name: 'HomePage', elements: [el('x', { css: '#x' })] }]);
  const p = run(d, ios('SettingsPage', 'networkRow'));
  assert.equal(p.status, 0, p.out);
  assert.doesNotMatch(p.out, /CHROMIUM_GUARD/);
  const w = run(d, ['--page', 'HomePage', '--element', 'x', '--base-url', 'https://shop.example.test', '--anonymous']);
  assert.equal(w.status, 2);
  assert.match(w.out, /CHROMIUM_GUARD/);
});

test('lookup is per platform: a page with no entry for the platform, and missing inspection files, are usage errors', () => {
  const d = project([{ name: 'SettingsPage', elements: [el('networkRow', { css: '#x' })] }]);
  const r = run(d, ios('SettingsPage', 'networkRow'));
  assert.equal(r.status, 2);
  assert.match(r.out, /has no entry for platform "ios"/);
  const d2 = project([iosPage([el('networkRow', { 'accessibility id': 'example.row.network' })])]);
  const noSource = run(d2, ios('SettingsPage', 'networkRow').map((a) => (a === 'inspect/ios.xml' ? 'inspect/missing.xml' : a)));
  assert.equal(noSource.status, 2);
  assert.match(noSource.out, /wdio session -s <slug> source/);
  writeFileSync(join(d2, 'inspect/not.png'), 'text');
  const notPng = run(d2, ios('SettingsPage', 'networkRow').map((a) => (a === 'inspect/shot.png' ? 'inspect/not.png' : a)));
  assert.equal(notPng.status, 2);
  assert.match(notPng.out, /not a PNG/);
});

test('personal data in an observed field is redacted; --help documents the platform mode', () => {
  const d = project([iosPage([el('sound', { 'accessibility id': 'example.row.sound' })])]);
  const xml = readFileSync(join(d, 'inspect/ios.xml'), 'utf8').replace('label="Sound"', 'label="someone@example.test"');
  writeFileSync(join(d, 'inspect/ios.xml'), xml);
  assert.equal(run(d, ios('SettingsPage', 'sound')).status, 0);
  const text = note(d, 'SettingsPage.sound.ios.md');
  assert.doesNotMatch(text.split('\n').filter((l) => !l.startsWith('- selector:')).join('\n'), /@/);
  assert.match(text, /<redacted-email>/);
  const h = spawnSync(process.execPath, [CLI, '--help'], { encoding: 'utf8' });
  assert.equal(h.status, 0);
  assert.match(h.stdout, /--platform <android\|ios>/);
});

test('a platform context supplies the platform and the capabilities file; its server is never read or printed; a web context keeps the web mode', () => {
  const d = project([iosPage([el('networkRow', { 'accessibility id': 'example.row.network' })]), { name: 'HomePage', elements: [el('x', { css: '#x' })] }]);
  writeFileSync(join(d, 'achilles-factory-rules.json'), JSON.stringify({ version: 1, contexts: {
    phone: { platform: 'ios', capabilities: 'tests/capabilities/phone.json', server: 'env:FAKE_APPIUM_URL' },
    north: { baseUrl: 'https://shop.example.test', storageState: 'tests/data/.auth/a.json' },
  } }));
  const r = run(d, ['--context', 'phone', '--page', 'SettingsPage', '--element', 'networkRow', '--screen', 'Settings', '--source', 'inspect/ios.xml', '--screenshot', 'inspect/shot.png']);
  assert.equal(r.status, 0, r.out);
  assert.doesNotMatch(r.out, /FAKE_APPIUM_URL/);
  const v = Object.fromEntries(fields(note(d, 'SettingsPage.networkRow.ios.md')));
  assert.equal(v.capabilities, 'tests/capabilities/phone.json');
  assert.equal(v.platform, 'ios');
  const clash = run(d, ['--context', 'phone', '--platform', 'android', '--page', 'SettingsPage', '--element', 'networkRow']);
  assert.equal(clash.status, 2);
  assert.match(clash.out, /contradicts context phone/);
  const web = run(d, ['--context', 'north', '--page', 'HomePage', '--element', 'x']);
  assert.equal(web.status, 2);
  assert.match(web.out, /storage state|CHROMIUM_GUARD/i, 'a web context stays on the web path');
});
