import type { Engine as EngineInterface } from 'claude-code/testing'
import { expect, mock, test } from 'claude-code/testing'

import { ROOT, START, engine, notes, spawnExpert, startRun, type Harness } from './harness'

// Converted from the 0.2.x specs 74 (test IDs: the hook half; the scanner's own cases are in
// tests/lib/test-id), 86 (import boundary: the hook half; tests/lib/import-boundary), 81 (evidence
// floor) and 55 (journey-map sentinel). The factory intake / inline-selector / repository-evidence
// rules run in factory.test.ts. Every finding is a note; every write lands.

const SPEC = `${ROOT}/tests/e2e/login.spec.ts`

async function setup($: EngineInterface, h: Harness, brief = 'Load `test-composer`.') {
  await $.session.start(START)
  const orchestrator = await startRun($, h)
  h.write(`${ROOT}/.achilles/runs/x/briefs/a.md`, brief)
  const author = await spawnExpert($, h, 'author', orchestrator, 'Read `.achilles/runs/x/briefs/a.md` first; write your report to `.achilles/runs/x/reports/a.md`.')
  return { orchestrator, author }
}

const write = ($: EngineInterface, agentId: string, file_path: string, content: string) => $.tool.call({ tool: 'Write', file_path, content, agentId })

test('test IDs: what the scanner reports on a spec write is one note naming the titles; the pattern source is handed to it', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const seen: (Record<string, string> | undefined)[] = []
  h.procs.push((argv, init) => {
    if (!argv.some(a => a.endsWith('test-id-scan.js'))) return undefined
    seen.push(init?.env)
    const after = (JSON.parse(init?.stdin ?? '{}') as { after?: string }).after ?? ''
    return after.includes('no id') ? '{"untagged":["no id here"],"duplicates":[{"id":"TCLG-000001","titles":["a","b"]}]}' : '{"untagged":[],"duplicates":[]}'
  })
  const { author } = await setup($, h)
  expect((await write($, author, SPEC, "test('no id here', () => {})")).deny).toBeUndefined()
  const said = notes(session, author).join('\n')
  expect(said).toContain('adds 1 test case without a stable test ID: no ID: "no id here"')
  expect(said).toContain('duplicate ID TCLG-000001')
  expect(said).toContain('the house shape is TC')
  expect(seen.at(-1)).toBeUndefined()
  const n = notes(session, author).length
  await write($, author, SPEC, "test('TCLG-000001 · ok', () => {})")
  await write($, author, `${ROOT}/tests/e2e/fixtures/base.ts`, "export const x = 'no id'")
  await write($, author, `${ROOT}/tests/e2e/notes.md`, "test('no id', () => {})")
  expect(notes(session, author).length).toBe(n)
  h.write(`${ROOT}/achilles-factory-rules.json`, JSON.stringify({ version: 1, rules: { 'specs.shape': { titleIdPattern: '^[A-Z]{2,5}-\\d{2,3}[a-z]? — ', scope: ['tests/e2e/**'], scenarioDocs: ['docs/scenarios.md'] } } }))
  await write($, author, `${ROOT}/tests/e2e/old.spec.ts`, "test('no id', () => {})")
  expect(seen.at(-1)).toEqual({ CIVITAS_TEST_ID_PATTERN: '^[A-Z]{2,5}-\\d{2,3}[a-z]? — ' })
  expect(notes(session, author).join('\n')).toContain('this project pins its own ID pattern')
})

test('import boundary: offenders from the scanner are a note; a scanner that cannot run falls open with a note; files out of scope are not screened', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  let mode = 'offend'
  h.procs.push(argv => {
    if (!argv.some(a => a.endsWith('import-boundary-scan.js'))) return undefined
    if (mode === 'timeout') return { exitCode: 3, stderr: 'budget' }
    return mode === 'offend' ? '{"scope":"tests","offenders":["import \\"../../src/app\\" — resolves outside tests/"]}' : '{"scope":"tests","offenders":[]}'
  })
  const { author } = await setup($, h)
  await write($, author, `${ROOT}/tests/e2e/fixtures/x.ts`, 'import "../../src/app"')
  expect(notes(session, author).at(-1)).toContain('reaches outside tests/: import "../../src/app" — resolves outside tests/')
  await write($, author, `${ROOT}/playwright.config.ts`, 'export default { testDir: "." }')
  expect(notes(session, author).at(-1)).toContain('playwright.config.ts reaches outside tests/')
  mode = 'timeout'
  await write($, author, `${ROOT}/tests/e2e/fixtures/y.ts`, 'export {}')
  expect(notes(session, author).at(-1)).toContain('its time budget ran out')
  mode = 'clean'
  const n = notes(session, author).length
  await write($, author, `${ROOT}/tests/e2e/fixtures/z.ts`, 'export {}')
  await write($, author, `${ROOT}/src/x.ts`, 'import "../../etc"')
  await write($, author, `${ROOT}/tests/e2e/docs/app-context.md`, 'Most pages require login.')
  expect(notes(session, author).length).toBe(n)
  const ran = h.ran.filter(r => r.argv.some(a => a.endsWith('import-boundary-scan.js')))
  expect(ran.some(r => r.argv.includes(`${ROOT}/src/x.ts`))).toBe(false)
  expect(JSON.parse(ran.at(-1)!.stdin!).tool_name).toBe('Write')
})

test('evidence floor: a diagnosing expert that writes a spec or the page repository before opening any failure evidence gets the note; any evidence read lifts it', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { author } = await setup($, h, 'Load `failure-diagnosis`; the login spec fails.')
  await write($, author, SPEC, 'await steps.waitForState(...)')
  expect(notes(session, author).at(-1)).toContain('Evidence-floor violation')
  expect(notes(session, author).at(-1)).toContain('gh run download')
  expect(notes(session, author).at(-1)).toContain('-retry1')
  await write($, author, `${ROOT}/tests/e2e/page-repository.json`, '{"pages":[]}')
  expect(notes(session, author).at(-1)).toContain('Evidence-floor violation')
  const n = notes(session, author).length
  await write($, author, `${ROOT}/tests/e2e/docs/app-context.md`, 'knowledge')
  await write($, author, `${ROOT}/tests/e2e/fixtures/StepFixture.ts`, 'export {}')
  expect(notes(session, author).length).toBe(n)
  await $.tool.call({ tool: 'Read', file_path: `${ROOT}/test-results/login-chromium/error-context.md`, agentId: author })
  await write($, author, SPEC, 'await steps.waitForState(...)')
  expect(notes(session, author).length).toBe(n)
})

test('evidence floor: a composer writing a spec is never gated; a diagnosis that unzipped the trace or downloaded the run is not either', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { author } = await setup($, h)
  await write($, author, SPEC, 'test')
  expect(notes(session, author)).toEqual([])
  const orchestrator = h.spawns[0]!.agentId
  h.write(`${ROOT}/.achilles/runs/x/briefs/fd.md`, 'Load `failure-diagnosis`.')
  for (const command of ['unzip -o -q /tmp/ci/test-results/x-retry1/trace.zip -d ./trace-x', 'gh run download 18234771 --dir /tmp/ci', 'npx playwright show-trace ./trace.zip']) {
    const fd = await spawnExpert($, h, 'author', orchestrator, 'Read `.achilles/runs/x/briefs/fd.md` first; write your report to `.achilles/runs/x/reports/fd.md`.')
    await $.tool.call({ tool: 'Bash', command, agentId: fd })
    await write($, fd, SPEC, 'test')
    expect(notes(session, fd).filter(n => n.includes('Evidence-floor'))).toEqual([])
  }
})

test('journey map: line 1 must be the sentinel and the cycle state must exist; an Edit of a sentinel-bearing map and the coverage matrix after it pass', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { author } = await setup($, h, 'Load `journey-mapping`.')
  const MAP = `${ROOT}/tests/e2e/docs/journey-map.md`
  const COV = `${ROOT}/tests/e2e/docs/journey-map-coverage.md`
  await write($, author, COV, '| Journey | Spec |')
  expect(notes(session, author).at(-1)).toContain('only be written after journey-map.md exists')
  await write($, author, MAP, '# Map\n## P0\n- j-signup')
  const said = notes(session, author).slice(-2).join('\n')
  expect(said).toContain('line 1 must be the literal sentinel')
  expect(said).toContain('.phase4-cycle-state.json does not exist')
  h.write(`${ROOT}/tests/e2e/docs/.phase4-cycle-state.json`, JSON.stringify({ cycles: { '1': { 'dispatched-sections': [] } } }))
  await write($, author, MAP, '<!-- journey-mapping:generated -->\n# Map')
  expect(notes(session, author).at(-1)).toContain('0 cycle-1 section dispatches')
  h.write(`${ROOT}/tests/e2e/docs/.phase4-cycle-state.json`, JSON.stringify({ cycles: { '1': { 'dispatched-sections': ['auth', 'cart'] } } }))
  const n = notes(session, author).length
  await write($, author, MAP, '<!-- journey-mapping:generated -->\n# Map\n- j-signup')
  await $.tool.call({ tool: 'Edit', file_path: MAP, old_string: 'j-signup', new_string: 'j-signup-v2', agentId: author })
  await write($, author, COV, '| Journey | Spec |')
  expect(notes(session, author).length).toBe(n)
})

test('the main loop is never screened', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  await setup($, h, 'Load `failure-diagnosis`.')
  await $.tool.call({ tool: 'Write', file_path: `${ROOT}/tests/e2e/docs/journey-map.md`, content: '# hand-rolled' })
  expect(notes(session).length).toBe(0)
})
