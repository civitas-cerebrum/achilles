import type { Engine as EngineInterface } from 'claude-code/testing'
import { expect, mock, test } from 'claude-code/testing'

import { ROOT, START, engine, notes, spawnExpert, startRun, type Harness } from './harness'

// Converted from the 0.2.x specs 51 and 66 (ledger write gates), 58 (integrity chain) and 61
// (append-only progress files). Every former deny is a note to the writing loop now; the write
// always lands. Separation of duties is the agents' write scope and has no test here.

const LEDGER = `${ROOT}/tests/e2e/docs/onboarding-status.json`
const PERF = `${ROOT}/tests/perf/docs/perf-onboarding-status.json`
const NAMES = ['Scaffold', 'Groundwork', 'Happy-path', 'Journey-mapping', 'Coverage-expansion', 'Bug-discovery', 'Secrets-sweep', 'Report']
const PERF_NAMES = ['Scaffold', 'Readiness', 'Scenario-model', 'Baseline', 'Load-run', 'Threshold-gate', 'Report']

type L = Record<string, unknown> & { phases: Record<string, unknown>[] }
const fresh = (names = NAMES): L => ({
  schemaVersion: 1,
  pipelineVersion: '0.4.0',
  runMode: 'standard',
  modeAuthorizer: 'user chose standard mode',
  startedAt: '2026-05-17T09:00:00Z',
  currentPhase: 1,
  currentSubStage: null,
  status: 'in-progress',
  phases: names.map((name, i) => ({ id: i + 1, name, status: i === 0 ? 'in-progress' : 'pending', reviewerVerdict: 'pending', reviewerCycles: 0, deliverables: [] })),
  approvedDeviations: [],
})
const edit = (l: L, fn: (l: L) => void): L => {
  const c = JSON.parse(JSON.stringify(l)) as L
  fn(c)
  return c
}
const completed = (l: L, id: number) =>
  edit(l, c => {
    Object.assign(c.phases[id - 1]!, { status: 'completed', handoverEnvelope: { role: 'closing', cycle: 1, status: 'complete', 'next-action': 'advance' } })
    c.currentPhase = id
  })

async function setup($: EngineInterface, h: Harness) {
  // The schema check runs in a node child; this stands for it: a ledger without phases fails.
  h.procs.push((argv, init) => {
    if (!argv.some(a => a.endsWith('validate.mjs'))) return undefined
    try {
      const doc = JSON.parse(init?.stdin ?? '') as { phases?: unknown; runMode?: unknown }
      if (!Array.isArray(doc.phases)) return JSON.stringify({ ok: false, errors: ["/ must have required property 'phases'"] })
      if (doc.runMode !== undefined && !['standard', 'depth', 'breadth'].includes(String(doc.runMode))) return JSON.stringify({ ok: false, errors: ['/runMode must be equal to one of the allowed values'] })
      return JSON.stringify({ ok: true })
    } catch {
      return JSON.stringify({ ok: false, parse: 'not JSON' })
    }
  })
  await $.session.start(START)
  const orchestrator = await startRun($, h)
  const reviewer = await spawnExpert($, h, 'reviewer', orchestrator)
  return { orchestrator, reviewer }
}

const write = ($: EngineInterface, agentId: string, content: unknown, path = LEDGER) =>
  $.tool.call({ tool: 'Write', file_path: path, content: typeof content === 'string' ? content : JSON.stringify(content, null, 2), agentId })

test('a clean ledger write says nothing; schema, parse and transition problems land as one note each write, never a refusal', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { orchestrator } = await setup($, h)
  expect((await write($, orchestrator, fresh())).deny).toBeUndefined()
  expect(notes(session, orchestrator).length).toBe(0)

  for (const [content, says] of [
    ['not-json-at-all', 'parseable JSON'],
    [{ schemaVersion: 1, currentPhase: 1 }, 'fails schema validation'],
    [edit(fresh(), c => (c.runMode = 'yolo')), 'fails schema validation'],
  ] as const) {
    h.write(LEDGER, JSON.stringify(fresh()))
    expect((await write($, orchestrator, content)).deny).toBeUndefined()
    expect(notes(session, orchestrator).at(-1)).toContain(says)
  }
})

test('transitions: a phase skip, an approval without an envelope, a verdict without a cycle bump and a third rejection are named', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { reviewer, orchestrator } = await setup($, h)
  // The prior state lands through the tool, so the out-of-band check stays quiet.
  const at = async (prior: L, next: L, who = orchestrator) => (await write($, who, prior), write($, who, next))

  await at(fresh(), edit(completed(fresh(), 1), c => ((c.currentPhase = 3), Object.assign(c.phases[0]!, { reviewerVerdict: 'approved', reviewerCycles: 1 }))))
  expect(notes(session, orchestrator).at(-1)).toContain('Out-of-order ledger transition: currentPhase jumped 1 → 3 while phase 2 is still "pending"')

  const p1 = edit(completed(fresh(), 1), c => Object.assign(c.phases[0]!, { reviewerVerdict: 'approved', reviewerCycles: 1 }))
  h.remove(LEDGER)
  await write($, orchestrator, p1)
  const before = notes(session, orchestrator).length
  await write($, orchestrator, edit(p1, c => ((c.currentPhase = 3), Object.assign(c.phases[1]!, { status: 'skipped', reviewerVerdict: 'approved', handoverEnvelope: {} }), (c.approvedDeviations = [{ phase: 2, deviation: 'pre-existing', authorizer: 'user said: groundwork already documented' }]))))
  expect(notes(session, orchestrator).length).toBe(before)

  await at(fresh(), edit(completed(fresh(), 1), c => Object.assign(c.phases[0]!, { reviewerVerdict: 'approved', reviewerCycles: 1, handoverEnvelope: null })), reviewer)
  expect(notes(session, reviewer).at(-1)).toContain('handoverEnvelope is null')

  await at(fresh(), edit(completed(fresh(), 1), c => Object.assign(c.phases[0]!, { reviewerVerdict: 'rejected' })), reviewer)
  expect(notes(session, reviewer).at(-1)).toContain('without incrementing reviewerCycles by exactly 1')

  const c2 = edit(completed(fresh(), 1), c => Object.assign(c.phases[0]!, { reviewerVerdict: 'rejected', reviewerCycles: 2 }))
  await at(c2, edit(c2, c => (c.phases[0]!.reviewerCycles = 3)), reviewer)
  expect(notes(session, reviewer).at(-1)).toContain('the third rejection escalates')
  const r = notes(session, reviewer).length
  await at(c2, edit(c2, c => (Object.assign(c.phases[0]!, { reviewerCycles: 3, reviewerVerdict: 'escalated-to-user' }), (c.status = 'blocked'))), reviewer)
  expect(notes(session, reviewer).length).toBe(r)
})

test('runMode needs its modeAuthorizer: on the first write, on a change, and it may not be cleared', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { orchestrator } = await setup($, h)
  const noAuth = edit(fresh(), c => delete c.modeAuthorizer)
  await write($, orchestrator, noAuth)
  expect(notes(session, orchestrator).at(-1)).toContain('without a modeAuthorizer field')
  await write($, orchestrator, fresh())
  await write($, orchestrator, edit(fresh(), c => ((c.runMode = 'depth'), delete c.modeAuthorizer)))
  expect(notes(session, orchestrator).at(-1)).toContain('without a fresh modeAuthorizer')
  await write($, orchestrator, fresh())
  await write($, orchestrator, noAuth)
  expect(notes(session, orchestrator).at(-1)).toContain('modeAuthorizer cleared')
  await write($, orchestrator, fresh())
  const n = notes(session, orchestrator).length
  await write($, orchestrator, edit(fresh(), c => ((c.runMode = 'depth'), (c.modeAuthorizer = 'user re-elected depth after pass 1'))))
  await write($, orchestrator, edit(fresh(), c => ((c.runMode = 'depth'), (c.modeAuthorizer = 'user re-elected depth after pass 1'), (c.phases[0]!.deliverables = ['playwright.config.ts']))))
  expect(notes(session, orchestrator).length).toBe(n)
})

test('onboarding deliverables: a phase flipped to completed names what is missing on disk, and says nothing once it is there', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { orchestrator } = await setup($, h)
  const complete = async (id: number) => {
    await write($, orchestrator, edit(fresh(), c => ((c.currentPhase = id), (c.phases[id - 1]!.status = 'in-progress'))))
    const n = notes(session, orchestrator).length
    await write($, orchestrator, completed(fresh(), id))
    return notes(session, orchestrator).length === n ? '' : notes(session, orchestrator).at(-1)!
  }
  expect(await complete(4)).toContain('journey-map.md does not exist')
  h.write(`${ROOT}/tests/e2e/docs/journey-map.md`, '# hand-rolled')
  expect(await complete(4)).toContain('line-1 sentinel')
  h.write(`${ROOT}/tests/e2e/docs/journey-map.md`, '<!-- journey-mapping:generated -->\n# Map\n### j-alpha: A\n### j-beta: B\n')
  expect(await complete(4)).toContain('.phase4-cycle-state.json does not exist')
  h.write(`${ROOT}/tests/e2e/docs/.phase4-cycle-state.json`, JSON.stringify({ cycles: { '1': { 'dispatched-sections': ['a', 'b', 'c'], 'returned-sections': ['a', 'b'] } } }))
  const p4 = await complete(4)
  expect(p4).toContain('missing cycle-1 and/or cycle-2')
  expect(p4).toContain('Some section agents did not return')
  h.write(`${ROOT}/tests/e2e/docs/.phase4-cycle-state.json`, JSON.stringify({ cycles: { '1': { 'dispatched-sections': ['a'], 'returned-sections': ['a'] }, '2': { 'dispatched-sections': ['a'], 'returned-sections': ['a'] } } }))
  expect(await complete(4)).toBe('')

  expect(await complete(5)).toContain('coverage-expansion-state.json does not exist')
  const later = { kind: 'compositional', dispatches: [{ journey: 'j-alpha' }] }
  const pass = (p1: unknown) => JSON.stringify({ runMode: 'standard', passes: { '1': p1, '2': later, '3': later, '4': later, '5': later }, cleanup: { deduped: true } })
  h.write(`${ROOT}/tests/e2e/docs/coverage-expansion-state.json`, JSON.stringify({ runMode: 'standard', passes: { '1': { 'dispatched-journeys': ['j-alpha', 'j-beta'] } } }))
  expect(await complete(5)).toContain('full five-pass run')
  // A breadth run records pass 1 alone.
  h.write(`${ROOT}/tests/e2e/docs/coverage-expansion-state.json`, JSON.stringify({ passes: { '1': { 'dispatched-journeys': ['j-alpha', 'j-beta'] } } }))
  expect(await complete(5)).toBe('')
  // The documented layout: "pass-<N>" keys, journeys in dispatches[], deferrals at the top level.
  const documented = { 'pass-2': later, 'pass-3': later, 'pass-4': later, 'pass-5': later }
  h.write(`${ROOT}/tests/e2e/docs/coverage-expansion-state.json`, JSON.stringify({ runMode: 'standard', passes: { 'pass-1': { kind: 'compositional', dispatches: [{ journey: 'j-alpha' }] }, ...documented }, cleanup: {}, deferredJourneys: [{ journey: 'j-beta', reason: 'blocked-on-app-bug:BUG-7' }] }))
  expect(await complete(5)).toBe('')
  h.write(`${ROOT}/tests/e2e/docs/coverage-expansion-state.json`, JSON.stringify({ runMode: 'standard', passes: { 'pass-1': {}, ...documented }, cleanup: {} }))
  expect(await complete(5)).toContain('no pass-1 record')
  h.write(`${ROOT}/tests/e2e/docs/coverage-expansion-state.json`, pass({ 'dispatched-journeys': ['j-alpha'] }))
  expect(await complete(5)).toContain('silently missing')
  h.write(`${ROOT}/tests/e2e/docs/coverage-expansion-state.json`, pass({ 'dispatched-journeys': ['j-alpha'], deferredJourneys: [{ journey: 'j-beta', reason: 'budget-cap' }] }))
  expect(await complete(5)).toContain('neither a structural reason prefix')
  h.write(`${ROOT}/tests/e2e/docs/coverage-expansion-state.json`, pass({ 'dispatched-journeys': ['j-alpha'], deferredJourneys: [{ journey: 'j-beta', reason: 'session-length', authorizer: 'user said: defer it' }] }))
  expect(await complete(5)).toBe('')

  expect(await complete(6)).toContain('adversarial-findings.md does not exist')
  h.write(`${ROOT}/tests/e2e/docs/adversarial-findings.md`, '# Adversarial Findings\n')
  expect(await complete(6)).toContain('0 per-journey section blocks')
  h.write(`${ROOT}/tests/e2e/docs/adversarial-findings.md`, '# Adversarial Findings\n\n### j-alpha\nclean\n')
  expect(await complete(6)).toBe('')
  expect(await complete(7)).toContain('.env.example does not exist')
  h.write(`${ROOT}/.env.example`, 'BASE_URL=\n')
  expect(await complete(7)).toBe('')
  h.write(`${ROOT}/qa-summary-deck.html`, '<html></html>')
  expect(await complete(8)).toContain('qa-summary-deck.pdf')
  h.write(`${ROOT}/qa-summary-deck.pdf`, '%PDF')
  expect(await complete(8)).toBe('')
})

test('perf deliverables: each perf phase names its own missing artefact', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { orchestrator } = await setup($, h)
  const complete = async (id: number) => {
    await write($, orchestrator, edit(fresh(PERF_NAMES), c => ((c.currentPhase = id), (c.phases[id - 1]!.status = 'in-progress'))), PERF)
    const n = notes(session, orchestrator).length
    await write($, orchestrator, completed(fresh(PERF_NAMES), id), PERF)
    return notes(session, orchestrator).length === n ? '' : notes(session, orchestrator).at(-1)!
  }
  const p1 = await complete(1)
  expect(p1).toContain('perf-onboarding.config.json does not exist')
  expect(p1).toContain('tests/perf/lib/ does not exist or is empty')
  h.write(`${ROOT}/tests/perf/perf-onboarding.config.json`, '{}')
  h.write(`${ROOT}/tests/perf/lib/auth.js`, '')
  expect(await complete(1)).toBe('')
  expect(await complete(2)).toContain('readiness.md does not exist')
  h.write(`${ROOT}/tests/perf/docs/scenario-model.md`, '# model')
  expect(await complete(3)).toContain('<!-- perf-onboarding:scenario-model -->')
  h.write(`${ROOT}/tests/perf/docs/scenario-model.md`, '<!-- perf-onboarding:scenario-model -->\n')
  h.write(`${ROOT}/tests/perf/scenarios/load.js`, '')
  expect(await complete(3)).toBe('')
  expect(await complete(4)).toContain('baseline files')
  expect(await complete(5)).toContain('result files')
  h.write(`${ROOT}/tests/perf/docs/threshold-verdict.json`, '{"deliberateBreach":[]}')
  expect(await complete(6)).toContain('deliberateBreach')
  h.write(`${ROOT}/tests/perf/docs/threshold-verdict.json`, '{"deliberateBreach":[{"threshold":"p95"}]}')
  expect(await complete(6)).toBe('')
  expect(await complete(7)).toContain('perf-report.md does not exist')
})

test('integrity: a ledger changed or deleted out of band since its last tool write is named at the next write; an untouched one is not', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { orchestrator } = await setup($, h)
  await write($, orchestrator, fresh())
  h.write(LEDGER, JSON.stringify(fresh(), null, 2))
  const n = notes(session, orchestrator).length
  await write($, orchestrator, edit(fresh(), c => (c.phases[0]!.deliverables = ['a'])))
  expect(notes(session, orchestrator).length).toBe(n)
  h.write(LEDGER, `${h.files.get(LEDGER)} `)
  await write($, orchestrator, fresh())
  expect(notes(session, orchestrator).at(-1)).toContain('changed out of band')
  h.remove(LEDGER)
  await write($, orchestrator, fresh())
  expect(notes(session, orchestrator).at(-1)).toContain('deleted out of band')
})

test('an Edit is judged on the content it lands; one whose old_string does not apply is named', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { orchestrator } = await setup($, h)
  h.write(LEDGER, JSON.stringify(fresh()))
  await $.tool.call({ tool: 'Edit', file_path: LEDGER, old_string: '"phases":[', new_string: '"phases":"nope","x":[', agentId: orchestrator })
  expect(notes(session, orchestrator).at(-1)).toContain('fails schema validation')
  await $.tool.call({ tool: 'Edit', file_path: LEDGER, old_string: 'THIS-DOES-NOT-OCCUR', new_string: 'x', agentId: orchestrator })
  expect(notes(session, orchestrator).at(-1)).toContain('does not occur in the file')
  await $.tool.call({ tool: 'Edit', file_path: LEDGER, old_string: '"reviewerCycles":0', new_string: '"reviewerCycles":1', agentId: orchestrator })
  expect(notes(session, orchestrator).at(-1)).toContain('occurs more than once')
})

test('progress files are append-only: a shrinking roster or returns on the first write are named; growth is not', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { orchestrator } = await setup($, h)
  const CYCLE = `${ROOT}/tests/e2e/docs/.phase4-cycle-state.json`
  const COV = `${ROOT}/tests/e2e/docs/coverage-expansion-state.json`
  await write($, orchestrator, { cycles: { '1': { 'dispatched-sections': ['a'], 'returned-sections': ['a'] } } }, CYCLE)
  expect(notes(session, orchestrator).at(-1)).toContain('returns predate their dispatch')
  h.write(CYCLE, JSON.stringify({ cycles: { '1': { 'dispatched-sections': ['a', 'b', 'c'], 'returned-sections': ['a', 'b'] } } }))
  await write($, orchestrator, { cycles: { '1': { 'dispatched-sections': ['a'], 'returned-sections': ['a'] } } }, CYCLE)
  expect(notes(session, orchestrator).at(-1)).toContain('drops b, c')
  h.write(COV, JSON.stringify({ passes: { '1': { 'dispatched-journeys': ['j-x', 'j-y'], 'returned-journeys': ['j-x'] } } }))
  await write($, orchestrator, { passes: { '1': { 'dispatched-journeys': ['j-x'], 'returned-journeys': ['j-x'] } } }, COV)
  expect(notes(session, orchestrator).at(-1)).toContain("pass 1's dispatched-journeys")
  const n = notes(session, orchestrator).length
  h.write(CYCLE, JSON.stringify({ cycles: { '1': { 'dispatched-sections': ['a', 'b'], 'returned-sections': [] } } }))
  await write($, orchestrator, { cycles: { '1': { 'dispatched-sections': ['a', 'b'], 'returned-sections': ['a', 'b'] } } }, CYCLE)
  h.remove(COV)
  await write($, orchestrator, { passes: { '1': { 'dispatched-journeys': ['j-x', 'j-y'], 'returned-journeys': [] } } }, COV)
  await write($, orchestrator, { anything: true }, `${ROOT}/tests/e2e/docs/app-context.json`)
  expect(notes(session, orchestrator).length).toBe(n)
})
