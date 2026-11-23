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
const NOTE_FIELDS = ['selector', 'platform', 'capabilities', 'screen', 'resolved count', 'class', 'accessibility id', 'id', 'label', 'source snippet', 'screenshot', 'source'];
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
const UNRESOLVED_ACTION = 'Mark the entry provisional with a row in tests/platform/docs/known-issues.md, or use a selector the offline resolver covers';

/** A form the offline resolver does not cover is refused: exit 1, the action first, the reason named, nothing written. */
function assertUnresolved(d, args, base, why) {
  const r = run(d, args);
  assert.equal(r.status, 1, `${base}: ${r.out}`);
  assert.match(r.stderr, new RegExp(`^\\[selectors\\.evidence\\] ${UNRESOLVED_ACTION.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`), base);
  if (why) assert.match(r.out, why, base);
  assert.equal(existsSync(join(d, 'docs/evidence/selectors', `${base}.md`)), false, base);
  assert.equal(existsSync(join(d, 'docs/evidence/selectors', `${base}.png`)), false, base);
  return r;
}

test('ios accessibility id: count 1 writes the note with every field in order and copies the screenshot', () => {
  const d = project([{ name: 'SettingsPage', elements: [el('networkRow', { css: '#web-only' })] }, iosPage([el('networkRow', { 'accessibility id': 'example.row.network' })])]);
  const r = run(d, ios('SettingsPage', 'networkRow'));
  assert.equal(r.status, 0, r.out);
  const text = note(d, 'SettingsPage.networkRow.ios.md');
  assert.equal(text.split('\n')[0], '# SettingsPage.networkRow (ios)');
  const f = fields(text);
  assert.deepEqual(f.map(([k]) => k), NOTE_FIELDS);
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
  assert.equal(v.source, 'wdio-page-source');
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

test('xpath: attribute predicates resolve; a positional xpath resolves and is flagged; an expression outside the subset is refused', () => {
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

  assertUnresolved(d, ios('SettingsPage', 'byAxis'), 'SettingsPage.byAxis.ios', /outside the offline subset/);
});

test('forms the offline resolver does not cover are refused with nothing written, never given a count', () => {
  const d = project([iosPage([el('orPredicate', { predicate: "label == 'Sound' OR label == 'Network'" })]), androidPage([el('scrollable', { uiautomator: 'new UiScrollable(new UiSelector().scrollable(true)).scrollIntoView(new UiSelector().text("Save"))' })])]);
  assertUnresolved(d, ios('SettingsPage', 'orPredicate'), 'SettingsPage.orPredicate.ios', /OR is outside/);
  assertUnresolved(d, android('SettingsPage', 'scrollable'), 'SettingsPage.scrollable.android', /UiScrollable/);
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
    assert.match(r.out, /--capabilities is not a path under tests\/capabilities\//, p);
    assert.doesNotMatch(r.out, /caps\.json/, 'the value is never echoed');
  }
  for (const v of ['platformName:iOS', 'appium:udid=' + FAKE_UDID, "'iOS'", 'tests/capabilities/a b.json', '"tests/capabilities/phone.json"']) {
    const r = run(d, withCaps(v));
    assert.equal(r.status, 2, v);
    assert.match(r.out, /capability values inline/, v);
    assert.doesNotMatch(r.out, new RegExp(FAKE_UDID));
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

test('no Chromium: the platform mode requires none of @playwright/test, playwright, playwright-core or element-repository; the web mode trips the same require guard', () => {
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
  assert.match(noSource.out, /npx wdio session -s <slug> source --path /);
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
    phone: { platform: 'ios', capabilities: 'tests/capabilities/phone.json', server: '${FAKE_APPIUM_URL}' },
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

test('over the 1 MB cap the screenshot is refused and the hint asks for the element screenshot', () => {
  const d = project([iosPage([el('networkRow', { 'accessibility id': 'example.row.network' })])]);
  writeFileSync(join(d, 'inspect/big.png'), Buffer.concat([PNG, Buffer.alloc(1024 * 1024 + 1)]));
  const r = run(d, ios('SettingsPage', 'networkRow').map((a) => (a === 'inspect/shot.png' ? 'inspect/big.png' : a)));
  assert.equal(r.status, 1, r.out);
  assert.match(r.out, /screenshot <ref> --path /);
  assert.equal(existsSync(join(d, 'docs/evidence/selectors')), false);
});

test('web mode looks up the web page of a name even when a platform page of that name is listed first', () => {
  const d = project([iosPage([el('onlyIos', { 'accessibility id': 'example.row.network' })]), { name: 'SettingsPage', elements: [el('webOnly', { css: '#x' })] }]);
  const web = (e) => run(d, ['--page', 'SettingsPage', '--element', e, '--base-url', 'https://shop.example.test', '--anonymous']);
  const missing = web('onlyIos');
  assert.equal(missing.status, 2);
  assert.match(missing.out, /Unknown repository entry SettingsPage\.onlyIos/);
  const found = web('webOnly');
  assert.match(found.out, /CHROMIUM_GUARD/, 'the web entry was found and the tool went on to load Playwright');
});

test('xpath != needs the attribute present; predicate booleans resolve only unquoted', () => {
  const d = project([iosPage([
    el('noValue', { xpath: '//XCUIElementTypeCell[@value!="x"]' }),
    el('disabledEdit', { predicate: "type == 'XCUIElementTypeButton' AND enabled == false" }),
    el('quotedBool', { predicate: "type == 'XCUIElementTypeButton' AND enabled == 'false'" }),
  ])]);
  const nv = run(d, ios('SettingsPage', 'noValue'));
  assert.equal(nv.status, 1, nv.out);
  assert.match(nv.out, /resolved to 0 elements/);
  assert.equal(run(d, ios('SettingsPage', 'disabledEdit')).status, 0);
  assert.equal(Object.fromEntries(fields(note(d, 'SettingsPage.disabledEdit.ios.md')))['resolved count'], '1');
  assertUnresolved(d, ios('SettingsPage', 'quotedBool'), 'SettingsPage.quotedBool.ios', /boolean attribute enabled with a quoted string/);
});

test('positional forms the resolver does not cover are refused and the refusal says they are positional', () => {
  const d = project([iosPage([
    el('xpPosition', { xpath: '//XCUIElementTypeCell[position()=2]' }),
    el('chainIndex', { 'class chain': '**/XCUIElementTypeCell[2]' }),
    el('chainNegative', { 'class chain': '**/XCUIElementTypeCell[-1]' }),
    el('chainDescendant', { 'class chain': '**/XCUIElementTypeCell[$name == "Network"$]' }),
  ]), androidPage([el('instance', { uiautomator: 'new UiSelector().className("android.widget.TextView").instance(1)' })])]);
  for (const name of ['xpPosition', 'chainIndex', 'chainNegative']) assertUnresolved(d, ios('SettingsPage', name), `SettingsPage.${name}.ios`, /positional/);
  assertUnresolved(d, android('SettingsPage', 'instance'), 'SettingsPage.instance.android', /positional/);
  const desc = assertUnresolved(d, ios('SettingsPage', 'chainDescendant'), 'SettingsPage.chainDescendant.ios', /descendant predicate \[\$…\$\]/);
  assert.doesNotMatch(desc.out, /positional/);
});

test('role + name gets its own message; a predicate never matches the application node; android short ids follow the app package, then android:id/', () => {
  const d = project([
    iosPage([el('roleName', { role: 'button', name: 'Save' }), el('app', { predicate: "label == 'Example'" })]),
    androidPage([el('title', { id: 'title' }), el('save', { id: 'save' })]),
  ]);
  assertUnresolved(d, ios('SettingsPage', 'roleName'), 'SettingsPage.roleName.ios', /role \+ name/);
  const app = run(d, ios('SettingsPage', 'app'));
  assert.equal(app.status, 1, app.out);
  assert.match(app.out, /resolved to 0 elements/);
  assert.equal(run(d, android('SettingsPage', 'title')).status, 0);
  assert.equal(Object.fromEntries(fields(note(d, 'SettingsPage.title.android.md'))).id, 'android:id/title');
  const save = run(d, android('SettingsPage', 'save'));
  assert.equal(save.status, 0, save.out);
  assert.equal(Object.fromEntries(fields(note(d, 'SettingsPage.save.android.md'))).id, 'com.example.app:id/save');
});

test('--name=value is accepted; an inline capabilities value is never printed, whatever the flag spelling or mode', () => {
  const d = project([iosPage([el('networkRow', { 'accessibility id': 'example.row.network' })]), { name: 'HomePage', elements: [el('x', { css: '#x' })] }]);
  const ok = run(d, ['--platform=ios', '--page=SettingsPage', '--element=networkRow', '--capabilities=tests/capabilities/phone.json', '--screen=Settings', '--source=inspect/ios.xml', '--screenshot=inspect/shot.png']);
  assert.equal(ok.status, 0, ok.out);
  const secret = 'FAKE-SECRET-UDID-0000';
  const inline = `{"appium:udid":"${secret}"}`;
  for (const args of [
    ['--platform', 'ios', '--page', 'SettingsPage', '--element', 'networkRow', `--capabilities=${inline}`],
    ['--platform=ios', '--page', 'SettingsPage', '--element', 'networkRow', `--caps=${inline}`],
    ['--page', 'HomePage', '--element', 'x', `--capabilities=${inline}`],
    ['--page', 'HomePage', '--element', 'x', `--caps=${inline}`],
  ]) {
    const r = run(d, args);
    assert.equal(r.status, 2, args.join(' '));
    assert.doesNotMatch(r.stdout, new RegExp(secret), args.join(' '));
    assert.doesNotMatch(r.stderr, new RegExp(secret), args.join(' '));
  }
});

test('a value that is not a plain name or path is "(not shown)" in every message that names a flag value', () => {
  const d = project([iosPage([el('networkRow', { 'accessibility id': 'example.row.network' })]), { name: 'HomePage', elements: [el('x', { css: '#x' })] }]);
  writeFileSync(join(d, 'achilles-factory-rules.json'), JSON.stringify({ version: 1, contexts: { phone: { platform: 'ios', capabilities: 'tests/capabilities/phone.json', server: '${FAKE_APPIUM_URL}' }, north: { baseUrl: 'https://shop.example.test' } } }));
  const secret = 'FAKE-SECRET-MARKER-0000';
  const v = `{"appium:udid":"${secret}"}`;
  const kv = `udid=${secret}`;
  const swap = (args, from, to) => args.map((a) => (a === from ? to : a));
  const cases = {
    'unknown --platform': ['--platform', v, '--page', 'SettingsPage', '--element', 'networkRow'],
    'not a platform context': ['--platform', 'ios', '--context', v, '--page', 'SettingsPage', '--element', 'networkRow'],
    'contradicts context': ['--context', 'phone', '--platform', kv, '--page', 'SettingsPage', '--element', 'networkRow'],
    'missing --source': swap(ios('SettingsPage', 'networkRow'), 'inspect/ios.xml', v),
    'missing --screenshot': swap(ios('SettingsPage', 'networkRow'), 'inspect/shot.png', kv),
    'unknown page': swap(ios('SettingsPage', 'networkRow'), 'SettingsPage', v),
    'web unknown context': ['--page', 'HomePage', '--element', 'x', '--context', v],
    'web base url': ['--page', 'HomePage', '--element', 'x', '--base-url', v, '--anonymous'],
  };
  for (const [slot, args] of Object.entries(cases)) {
    const r = run(d, args);
    assert.equal(r.status, 2, `${slot}: ${r.out}`);
    assert.doesNotMatch(r.out, new RegExp(secret), slot);
    assert.match(r.out, /\(not shown\)/, slot);
  }
  const plain = run(d, ['--platform', 'tvos', '--page', 'SettingsPage', '--element', 'networkRow']);
  assert.match(plain.out, /Unknown --platform tvos/, 'a plain value is still named');
});

test('capabilities files are flat: a wrapper (alwaysMatch, firstMatch, capabilities) is refused, and so is a file without a string platformName', () => {
  const d = project([androidPage([el('save', { id: 'save' })])]);
  const withCaps = (file) => android('SettingsPage', 'save').map((a) => (a === 'tests/capabilities/android.json' ? file : a));
  const wrapped = {
    'always.json': { platformName: 'Android', alwaysMatch: { 'appium:appPackage': 'com.example.other' } },
    'first.json': { platformName: 'Android', firstMatch: [{}] },
    'wrapper.json': { capabilities: { platformName: 'Android' } },
  };
  for (const [file, caps] of Object.entries(wrapped)) {
    writeFileSync(join(d, 'tests/capabilities', file), JSON.stringify(caps));
    const r = run(d, withCaps(`tests/capabilities/${file}`));
    assert.equal(r.status, 2, file);
    assert.match(r.out, /capabilities files are flat: top-level keys, no alwaysMatch\/firstMatch wrapper/, file);
  }
  writeFileSync(join(d, 'tests/capabilities/noname.json'), JSON.stringify({ 'appium:automationName': 'UiAutomator2' }));
  const noName = run(d, withCaps('tests/capabilities/noname.json'));
  assert.equal(noName.status, 2);
  assert.match(noName.out, /no string platformName/);
  writeFileSync(join(d, 'tests/capabilities/flat.json'), JSON.stringify({ platformName: 'Android', 'appium:appPackage': 'com.example.other' }));
  assert.equal(run(d, withCaps('tests/capabilities/flat.json')).status, 0);
  assert.equal(Object.fromEntries(fields(note(d, 'SettingsPage.save.android.md'))).id, 'com.example.other:id/save');
  assert.equal(existsSync(join(d, 'docs/evidence/selectors/SettingsPage.save.android.png')), true);
});

test('a plain value with spaces (a repository name) is still shown', () => {
  const d = project([iosPage([el('networkRow', { 'accessibility id': 'example.row.network' })])]);
  const r = run(d, ['--platform', 'ios', '--page', 'Settings Page', '--element', 'networkRow', '--capabilities', 'tests/capabilities/phone.json', '--screen', 'Settings', '--source', 'inspect/ios.xml', '--screenshot', 'inspect/shot.png']);
  assert.equal(r.status, 2);
  assert.match(r.out, /Page "Settings Page" has no entry/);
});

test('web mode: a flag missing its value names the flag, not the next argument', () => {
  const d = project([{ name: 'HomePage', elements: [el('x', { css: '#x' })] }]);
  const r = run(d, ['--page', 'HomePage', '--element', '--base-url']);
  assert.equal(r.status, 2);
  assert.match(r.out, /Option --element needs a value/);
  assert.doesNotMatch(r.out, /got /);
});

test('a short android id prefers the appium:appPackage of the capabilities file, else the package owning most nodes', () => {
  const d = project([androidPage([el('save', { id: 'save' })])]);
  writeFileSync(join(d, 'tests/capabilities/other.json'), JSON.stringify({ platformName: 'Android', 'appium:appPackage': 'com.example.other' }));
  assert.equal(run(d, android('SettingsPage', 'save')).status, 0);
  assert.equal(Object.fromEntries(fields(note(d, 'SettingsPage.save.android.md'))).id, 'com.example.app:id/save');
  const r = run(d, android('SettingsPage', 'save').map((a) => (a === 'tests/capabilities/android.json' ? 'tests/capabilities/other.json' : a)));
  assert.equal(r.status, 0, r.out);
  const v = Object.fromEntries(fields(note(d, 'SettingsPage.save.android.md')));
  assert.equal(v.id, 'com.example.other:id/save');
  assert.equal(v.capabilities, 'tests/capabilities/other.json');
  assert.doesNotMatch(note(d, 'SettingsPage.save.android.md'), /appPackage/);
});

test('an element not visible at capture is refused with the swipe-and-re-capture action first, and nothing is written', () => {
  const d = project([iosPage([el('sound', { 'accessibility id': 'example.row.sound' }), el('network', { 'accessibility id': 'example.row.network' })]), androidPage([el('save', { id: 'save' })])]);
  const iosXml = readFileSync(join(d, 'inspect/ios.xml'), 'utf8').replace('name="example.row.sound" label="Sound" enabled="true" visible="true"', 'name="example.row.sound" label="Sound" enabled="true" visible="false"');
  writeFileSync(join(d, 'inspect/ios.xml'), iosXml);
  const andXml = readFileSync(join(d, 'inspect/android.xml'), 'utf8').replace(/(resource-id="com\.example\.app:id\/save"[^>]*displayed=)"true"/, '$1"false"');
  writeFileSync(join(d, 'inspect/android.xml'), andXml);
  for (const [args, base] of [[ios('SettingsPage', 'sound'), 'SettingsPage.sound.ios'], [android('SettingsPage', 'save'), 'SettingsPage.save.android']]) {
    const r = run(d, args);
    assert.equal(r.status, 1, r.out);
    const element = base.split('.').slice(0, 2).join('.');
    assert.match(r.stderr, new RegExp(`^\\[selectors\\.evidence\\] Swipe ${element.replace('.', '\\.')} into view, re-capture the source and screenshot, then re-run`));
    assert.equal(existsSync(join(d, 'docs/evidence/selectors', `${base}.md`)), false, base);
    assert.equal(existsSync(join(d, 'docs/evidence/selectors', `${base}.png`)), false, base);
  }
  assert.equal(run(d, ios('SettingsPage', 'network')).status, 0);
  assert.equal(Object.fromEntries(fields(note(d, 'SettingsPage.network.ios.md')))['resolved count'], '1');
});

test('--help states the platform --repository default', () => {
  const h = spawnSync(process.execPath, [CLI, '--help'], { encoding: 'utf8' });
  assert.match(h.stdout, /tests\/e2e\/page-repository\.json if it exists, else tests\/platform\/page-repository\.json/);
});

test('a string operator on a boolean attribute is named as the cause, before the quoting', () => {
  const d = project([iosPage([el('opOnBool', { predicate: "enabled CONTAINS 'true'" })])]);
  assertUnresolved(d, ios('SettingsPage', 'opOnBool'), 'SettingsPage.opOnBool.ios', /applies CONTAINS to the boolean attribute enabled/);
});

test('a strategy of the other platform is refused and the message gives the preference order', () => {
  const d = project([androidPage([el('pred', { predicate: "label == 'Save'" })])]);
  const r = run(d, android('SettingsPage', 'pred'));
  assert.equal(r.status, 1);
  assert.match(r.out, /accessibility id, then id/);
});
