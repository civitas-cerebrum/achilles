import { expect, mock, test } from 'claude-code/testing'

import { ROOT, START, engine, notes, spawnExpert, startRun } from './harness'

// The repository-evidence gate (selectors.evidence, hook 6) on platform pages (A4: page `platform` android | ios).
// A platform entry is backed by <evidenceDir>/<Page>.<element>.<platform>.md, the note
// `achilles-selector-evidence --platform` writes; a positional xpath the note flags needs a fallback or a
// known-issues row. Every finding is a note, as for web entries; every write lands.

const RULES = JSON.stringify({ version: 1, rules: { 'selectors.evidence': { repository: 'tests/e2e/page-repository.json', doc: 'skills/achilles-protocol/references/factory-gates.md#selectors.evidence' } } })
const SCHEMA = JSON.stringify({ $defs: { selectorsEvidence: { properties: { evidenceDir: { default: 'docs/evidence/selectors' } } } } })
const REPO = `${ROOT}/tests/e2e/page-repository.json`
const EV = `${ROOT}/docs/evidence/selectors`

const page = (platform: string | undefined, elements: unknown[]) => ({ name: 'SettingsPage', ...(platform ? { platform } : {}), elements })
const repo = (...pages: unknown[]) => JSON.stringify({ pages }, null, 2)
const platformNote = (selector: unknown, platform: string, count = '1') =>
  [
    `# SettingsPage.row (${platform})`,
    `- selector: ${JSON.stringify(selector)}`,
    `- platform: ${platform}`,
    '- capabilities: tests/capabilities/phone.json',
    '- screen: Settings',
    `- resolved count: ${count}`,
    '- class: XCUIElementTypeCell',
    '- accessibility id: example.row',
    '- id: example.row',
    '- label: "Row"',
    '- source snippet: `<XCUIElementTypeCell name="example.row"/>`',
    `- screenshot: SettingsPage.row.${platform}.png`,
    '- source: live (wdio session page source)',
  ].join('\n') + '\n'

type Args = Parameters<Parameters<typeof test>[1]>

async function writeRepo($: Args[0], on: Args[1], files: Record<string, string>, content: string): Promise<string> {
  {
    const h = engine(on, { files: { [`${ROOT}/achilles-factory-rules.json`]: RULES, [`${ROOT}/schemas/factory-rules.schema.json`]: SCHEMA, [REPO]: repo(), ...files } })
    const session = mock.session(on)
    await $.session.start(START)
    const author = await spawnExpert($, h, 'author', await startRun($, h))
    const r = await $.tool.call({ tool: 'Write', file_path: REPO, content, agentId: author } as never)
    expect(r.deny).toBeUndefined()
    return notes(session, author).filter(n => n.includes('[selectors.evidence]')).join('\n')
  }
}

const IOS_SEL = { 'accessibility id': 'example.row' }

test('a platform entry with its platform note is accepted', async ($, on) => {
  const said = await writeRepo($, on, { [`${EV}/SettingsPage.row.ios.md`]: platformNote(IOS_SEL, 'ios') }, repo(page('ios', [{ elementName: 'row', selector: IOS_SEL }])))
  expect(said).toBe('')
})

test('a platform entry without evidence is noted like a web entry, naming the platform note path', async ($, on) => {
  const said = await writeRepo($, on, {}, repo(page('android', [{ elementName: 'row', selector: { id: 'com.example.app:id/row' } }])))
  expect(said).toContain('Repository entry SettingsPage.row (android) has no evidence note')
  expect(said).toContain('docs/evidence/selectors/SettingsPage.row.android.md')
})

test('a web note carrying the platform selector does not count for the platform page', async ($, on) => {
  const files = { [`${EV}/SettingsPage.row.md`]: '# SettingsPage.row\n- selector: {"accessibility id":"example.row"}\n- source: live\n' }
  const said = await writeRepo($, on, files, repo(page('ios', [{ elementName: 'row', selector: IOS_SEL }])))
  expect(said).toContain('Repository entry SettingsPage.row (ios) has no evidence note')
})

test('beside a noted web page of the same name, a platform note naming another platform is refused', async ($, on) => {
  const files = {
    [`${EV}/SettingsPage.row.md`]: '# SettingsPage.row\n- selector: {"css":"#row"}\n- source: live\n',
    [`${EV}/SettingsPage.row.ios.md`]: platformNote(IOS_SEL, 'android'),
  }
  const said = await writeRepo($, on, files, repo(page(undefined, [{ elementName: 'row', selector: { css: '#row' } }]), page('ios', [{ elementName: 'row', selector: IOS_SEL }])))
  expect(said).toContain('SettingsPage.row.ios.md is not an ios note')
  expect(said).not.toContain('SettingsPage.row.md')
})

test('a stale platform note is refused; a provisional platform entry needs no note', async ($, on) => {
  const files = { [`${EV}/SettingsPage.row.ios.md`]: platformNote({ 'accessibility id': 'example.old' }, 'ios') }
  const said = await writeRepo($, on, files, repo(page('ios', [{ elementName: 'row', selector: IOS_SEL }, { elementName: 'later', selector: { 'accessibility id': 'x' }, provisional: true }])))
  expect(said).toContain('SettingsPage.row.ios.md is stale')
  expect(said).not.toContain('later')
})

test('a positional xpath the note flags is noted unless the selector has a fallback or the known-issues file names the entry', async ($, on) => {
  const sel = { xpath: '(//XCUIElementTypeCell)[2]' }
  const flagged = platformNote(sel, 'ios', '1 (positional: needs a "fallback" or a known-issues row)')
  const said = await writeRepo($, on, { [`${EV}/SettingsPage.row.ios.md`]: flagged }, repo(page('ios', [{ elementName: 'row', selector: sel }])))
  expect(said).toContain('SettingsPage.row (ios) enters the repository with a positional xpath')
  expect(said).toContain('fallback')
})

test('a positional xpath with a fallback, or with a known-issues row, is accepted', async ($, on) => {
  const sel = { xpath: '(//XCUIElementTypeCell)[2]', fallback: { 'accessibility id': 'example.row' } }
  const flagged = platformNote(sel, 'ios', '1 (positional: needs a "fallback" or a known-issues row)')
  const said = await writeRepo($, on, { [`${EV}/SettingsPage.row.ios.md`]: flagged }, repo(page('ios', [{ elementName: 'row', selector: sel }])))
  expect(said).toBe('')
})

test('a positional xpath named in the known-issues file is accepted', async ($, on) => {
  const sel = { xpath: '(//XCUIElementTypeCell)[2]' }
  const flagged = platformNote(sel, 'ios', '1 (positional: needs a "fallback" or a known-issues row)')
  const files = { [`${EV}/SettingsPage.row.ios.md`]: flagged, [`${ROOT}/tests/platform/docs/known-issues.md`]: '| SettingsPage.row (ios) | positional xpath | no accessibility id yet |\n' }
  const said = await writeRepo($, on, files, repo(page('ios', [{ elementName: 'row', selector: sel }])))
  expect(said).toBe('')
})
