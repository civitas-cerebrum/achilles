import type { Engine as EngineInterface } from 'claude-code/testing'
import { expect, mock, test } from 'claude-code/testing'

import { capabilityLiteral } from '../hooks/capabilities'
import { ROOT, START, engine, notes, spawnExpert, startRun, type Harness } from './harness'

// The capability-literal gate: capabilities live only in tests/capabilities/<device>.json, so a
// platform spec, a platform fixture, a platform JSON file or the platform config that spells one out
// gets a note naming the fix, and the write lands; the files under tests/capabilities/, docs, page repositories, every web file (the e2e
// fixtures included) and the main loop are not screened, and a capability key whose value is not a
// literal (a type, a rename, a variable) passes.

const ADVICE = /^achilles: Move the value into tests\/capabilities\/<device>\.json/

async function setup($: EngineInterface, h: Harness, session: ReturnType<typeof mock.session>) {
  await $.session.start(START)
  const orchestrator = await startRun($, h)
  const author = await spawnExpert($, h, 'author', orchestrator)
  const advice = (as: string) => notes(session, as).filter(n => ADVICE.test(n))
  // A write's result and the capability advice it drew (the write always lands).
  const writeAs = async (path: string, content: string, as = author) => {
    const before = advice(as).length
    const r = await $.tool.call({ tool: 'Write', file_path: `${ROOT}/${path}`, content, agentId: as })
    return { deny: r.deny, advice: advice(as).slice(before) }
  }
  return { orchestrator, author, writeAs, advice }
}

test('a capability literal in a platform spec, a fixture, a platform JSON file or the platform config gets a note naming the capabilities file; the write lands', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { writeAs, author, advice } = await setup($, h, session)
  for (const [path, content] of [
    ['tests/platform/login.spec.ts', "const caps = { 'appium:udid': '00000000-0000000000000000' }"],
    ['tests/platform/login.spec.ts', "const caps = { platformName: 'iOS' }"],
    ['tests/platform/fixtures/base.ts', 'baseFixture(base, repo, { session: { capabilities: { platformName: "iOS" } } })'],
    ['tests/platform/fixtures/base.ts', "export const opts = { automationName: 'XCUITest' }"],
    ['tests/platform/fixtures/base.ts', "export const opts = { session: { capabilities: process.env.E2E_CAPABILITIES ?? 'caps/iphone.json' } }"],
    ['tests/platform/page-repository.backup.json', '{ "platformName": "iOS" }'],
    ['tests/platform/data/page-repository.json', '{ "platformName": "iOS" }'],
    ['tests/platform/helpers/app.ts', '{ "appPackage": "com.example.shop", "appActivity": ".Main" }'],
    ['tests/platform/data/device.json', '{ "platformName": "Android", "udid": "x" }'],
    ['playwright.platform.config.ts', 'export default { use: { capabilities: { udid: "x" } } }'],
  ] as const) {
    const r = await writeAs(path, content)
    expect(r.deny).toBeUndefined()
    expect(r.advice.length).toBe(1)
    expect(r.advice[0]).toMatch(/capability literal|capabilities value/)
  }
  const before = advice(author).length
  const edit = await $.tool.call({ tool: 'Edit', file_path: `${ROOT}/tests/platform/login.spec.ts`, old_string: 'a', new_string: "{ 'appium:noReset': true }", agentId: author })
  expect(edit.deny).toBeUndefined()
  expect(advice(author).slice(before).join('\n')).toMatch(/capability literal/)
})

test('the capabilities files, path references, non-literal keys, comments, docs, page repositories, web specs and the main loop pass', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { writeAs } = await setup($, h, session)
  for (const [path, content] of [
    ['tests/capabilities/iphone.json', JSON.stringify({ platformName: 'iOS', 'appium:automationName': 'XCUITest', 'appium:bundleId': 'com.example.shop' })],
    ['tests/platform/fixtures/base.ts', "baseFixture(base, 'tests/e2e/page-repository.json', { session: { capabilities: process.env.E2E_CAPABILITIES } })"],
    ['tests/platform/fixtures/base.ts', "export const opts = { session: { capabilities: 'tests/capabilities/iphone.json', reset: 'relaunch' } }"],
    ['tests/platform/fixtures/base.ts', "export const opts = { session: { capabilities: process.env.E2E_CAPABILITIES ?? 'tests/capabilities/iphone.json' } }"],
    ['tests/platform/fixtures/base.ts', 'export const opts = { session: { capabilities: process.env.E2E_CAPABILITIES! } }'],
    ['tests/platform/fixtures/base.ts', 'interface Options { capabilities: string; extra: Record<string, unknown> }\ntype Caps = { capabilities: { platformName: string } }'],
    ['tests/platform/fixtures/provider.ts', 'export const provider = { async start({ capabilities, server }) { return remote({ ...server, capabilities: capabilities }) } }'],
    ['tests/e2e/fixtures/base.ts', 'export type Opts = { capabilities: Record<string, unknown> }'],
    ['tests/platform/login.spec.ts', "test('login', async ({ steps }) => { await steps.click('submit', 'LoginPage') })"],
    ['tests/platform/helpers/device.ts', 'export function label(platformName: string, udid: string) { return `${platformName}:${udid}` }'],
    ['tests/platform/helpers/device.ts', 'const { platformName: name, bundleId: id } = driver.capabilities as Record<string, string>'],
    ['tests/platform/helpers/device.ts', 'const name = isIos ? platformName : fallbackName; const v = { platformName }'],
    ['tests/platform/helpers/device.ts', 'interface Device { platformName: string; udid?: string; bundleId: string }'],
    ['tests/platform/helpers/device.ts', "const id = driver.capabilities['appium:bundleId']"],
    ['tests/platform/helpers/device.ts', "// was { platformName: 'iOS' }\n/* { 'appium:udid': 'x' } */\nconst url = 'http://example.test/a'"],
    ['tests/platform/data/speakers.ts', "export const rooms = [{ deviceName: 'Kitchen speaker' }]"],
    ['tests/platform/docs/app-context.md', 'The app id is `appium:bundleId` in the capabilities file; platformName: iOS.'],
    ['tests/platform/docs/notes.json', JSON.stringify({ platformName: 'iOS' })],
    ['tests/platform/page-repository.json', JSON.stringify({ pages: [{ name: 'Login', platform: 'ios', elements: [{ elementName: 'submit', selector: { id: 'login' } }] }] })],
    ['tests/e2e/fixtures/base.ts', "const user = { platformName: 'web shop', udid: 'u-1' }"],
    ['tests/e2e/login.spec.ts', "const caps = { 'appium:udid': 'web spec is out of scope' }"],
  ] as const)
    expect((await writeAs(path, content)).advice).toEqual([])
  // The main loop is not screened.
  expect((await $.tool.call({ tool: 'Write', file_path: `${ROOT}/tests/platform/a.spec.ts`, content: "{ 'appium:udid': 'x' }" })).deny).toBeUndefined()
  expect(notes(session).filter(n => ADVICE.test(n))).toEqual([])
})

test('a web fixture that configures a cloud grid with its own capabilities passes, with or without a platform suite in the project', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { writeAs } = await setup($, h, session)
  const grid = [
    "export const test = base.extend({ capabilities: { browserName: 'chrome' } })",
    "const opts = { capabilities: { browserName: 'chrome', 'bstack:options': { os: 'Windows' } } }",
    "const caps = { 'appium:bundleId': 'com.example.shop', platformName: 'iOS' }",
  ]
  for (const content of grid) expect((await writeAs('tests/e2e/fixtures/base.ts', content)).advice).toEqual([])
  h.write(`${ROOT}/tests/capabilities/iphone.json`, JSON.stringify({ platformName: 'iOS' }))
  h.write(`${ROOT}/playwright.platform.config.ts`, 'export default {}')
  for (const content of grid) expect((await writeAs('tests/e2e/fixtures/base.ts', content)).advice).toEqual([])
  expect((await writeAs('playwright.config.ts', grid[0]!)).advice).toEqual([])
})

test('capabilityLiteral: what it matches and where', () => {
  expect(capabilityLiteral('tests/platform/a.spec.ts', 'const x = { platformName: "Android" }')).toContain('platformName')
  expect(capabilityLiteral('tests/platform/a.spec.ts', 'const x = { desiredCapabilities: { noReset: true } }')).toBeDefined()
  expect(capabilityLiteral('tests/platform/a.spec.ts', 'const x = { capabilities: {} }')).toBeUndefined()
  expect(capabilityLiteral('tests/platform/a.spec.ts', 'const x = { udid: 42 }')).toBeDefined()
  expect(capabilityLiteral('tests/platform/a.spec.ts', 'const x = { "appium:noReset": true }')).toBeDefined()
  expect(capabilityLiteral('tests/platform/a.spec.ts', "const platform = process.env.E2E_PLATFORM ?? 'ios'")).toBeUndefined()
  expect(capabilityLiteral('tests/capabilities/a.json', '{"platformName":"iOS"}')).toBeUndefined()
  expect(capabilityLiteral('tests/e2e/a.spec.ts', '{"platformName":"iOS"}')).toBeUndefined()
  expect(capabilityLiteral('src/app.ts', '{"platformName":"iOS"}')).toBeUndefined()
  expect(capabilityLiteral('tests/e2e/fixtures/base.ts', "{ capabilities: { browserName: 'chrome' } }")).toBeUndefined()
})
