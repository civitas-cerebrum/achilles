import type { Engine as EngineInterface } from 'claude-code/testing'
import { expect, mock, test } from 'claude-code/testing'

import { citedPaths, judgeVerdict } from '../hooks/returns'
import { ROOT, START, ended, engine, notes, spawnExpert, startRun, type Harness } from './harness'

// Converted from the 0.2.x specs 43 (return schema), 54 (reviewer attestation), 56 (skill
// loaded) and 77 (judge loop). The review never rewrites a return; it is one note to the
// orchestrator naming every gap.

async function setup($: EngineInterface, h: Harness) {
  // The schema check runs in a node child; this stands for it: a return without a handover envelope fails.
  h.procs.push((argv, init) => {
    if (!argv.some(a => a.endsWith('validate.mjs'))) return undefined
    return /handover/.test(init?.stdin ?? '') ? '{"ok":true}' : JSON.stringify({ ok: false, errors: ["/ must have required property 'handover'"] })
  })
  await $.session.start(START)
  return startRun($, h)
}

async function expert($: EngineInterface, h: Harness, orchestrator: string, role: string, brief: string, report?: string, skill?: string) {
  h.write(`${ROOT}/.achilles/runs/x/briefs/${role}.md`, brief)
  const agentId = await spawnExpert($, h, role, orchestrator, `Read \`.achilles/runs/x/briefs/${role}.md\` first; write your report to \`.achilles/runs/x/reports/${role}.md\`.`)
  if (skill) await $.tool.call({ tool: 'Skill', skill, agentId } as never)
  if (report !== undefined) h.write(`${ROOT}/.achilles/runs/x/reports/${role}.md`, report)
  return agentId
}

const GOOD_COMPOSER = 'handover:\n  role: composer-j-checkout-1-c1\n  cycle: 1\n  status: new-tests-landed\n  next-action: reviewer\njourney: j-checkout\ntests-added: 3\nsummary: Added three scenarios.\n'

test('a return that keeps its contract says nothing', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const orchestrator = await setup($, h)
  const a = await expert($, h, orchestrator, 'author', 'Load `test-composer`. Return per composer.schema.json.', GOOD_COMPOSER, 'achilles:test-composer')
  await $.turn.complete(ended(a, 'DONE\nThree scenarios; report written.'))
  expect(notes(session, orchestrator)).toEqual([])
})

test('a schema-invalid return, a missing report, a missing status word, a missing spill and an unloaded skill are one note', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const orchestrator = await setup($, h)
  const a = await expert($, h, orchestrator, 'author', 'Load `test-composer`. Return per composer.schema.json.', 'journey: j-x\ntests-added: 2\nsee tests/e2e/docs/.subagent-returns/composer-j-x.md\n')
  await $.turn.complete(ended(a, 'Finished the tests.'))
  const n = notes(session, orchestrator).at(-1)!
  expect(n).toContain('handed back with 4 gaps')
  expect(n).toContain('does not open with DONE')
  expect(n).toContain("does not validate against schemas/subagent-returns/composer.schema.json: / must have required property 'handover'")
  expect(n).toContain('the spill file tests/e2e/docs/.subagent-returns/composer-j-x.md, which does not exist')
  expect(n).toContain('its brief names test-composer and it never loaded it')
  const b = await expert($, h, orchestrator, 'inspector', 'Load `journey-mapping`.', undefined, 'journey-mapping')
  await $.turn.complete(ended(b, 'DONE\nMapped.'))
  expect(notes(session, orchestrator).at(-1)).toContain('it wrote no report at .achilles/runs/x/reports/inspector.md')
})

test('an approval must cite on-disk evidence that exists; a rejection and an approval citing real paths pass', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const orchestrator = await setup($, h)
  h.write(`${ROOT}/tests/e2e/docs/onboarding-status.json`, '{}')
  h.write(`${ROOT}/scripts/postinstall.js`, '// stub')
  const env = 'handover:\n  role: workflow-reviewer-phase1\n  cycle: 1\n  status: approved\n  next-action: orchestrator\n'
  const run = async (report: string) => {
    const r = await expert($, h, orchestrator, 'reviewer', 'Load `review`.', report, 'review')
    const n = notes(session, orchestrator).length
    await $.turn.complete(ended(r, 'DONE\nverdict recorded'))
    return notes(session, orchestrator).length > n ? notes(session, orchestrator).at(-1)! : ''
  }
  expect(await run(`${env}verdict: approve\nattestation: all checks passed\n`)).toContain('cites no on-disk evidence')
  expect(await run(`${env}verdict: approve\nattestation: verified tests/e2e/docs/nonexistent.json on disk\n`)).toContain('cites paths that do not exist: tests/e2e/docs/nonexistent.json')
  expect(await run(`${env}verdict: approve\nattestation: verified tests/e2e/docs/onboarding-status.json and scripts/postinstall.js on disk\n`)).toBe('')
  expect(await run(`${env}verdict: reject\nfindings:\n  - checklist-item: foo\n`)).toBe('')
})

test('the judge loop: consecutive improvements-needed verdicts are counted, greenlight closes it, the third escalates', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const orchestrator = await setup($, h)
  const judge = async (status: string) => {
    const r = await expert($, h, orchestrator, 'reviewer', 'Load `review`.', `handover:\n  role: judge\n  status: ${status}\n  next-action: orchestrator\n`, 'review')
    const n = notes(session, orchestrator).length
    await $.turn.complete(ended(r, 'DONE\nverdict'))
    return notes(session, orchestrator).length > n ? notes(session, orchestrator).at(-1)! : ''
  }
  expect(await judge('improvements-needed')).toContain('judge loop is open (1 of 3)')
  expect(h.status()).toContain('judge loop open 1/3')
  expect(await judge('greenlight')).toBe('')
  expect(await judge('improvements-needed')).toContain('(1 of 3)')
  expect(await judge('improvements-needed')).toContain('(2 of 3)')
  expect(await judge('improvements-needed')).toContain('escalate to the user')
  await $.turn.complete(ended(orchestrator, 'DONE_WITH_CONCERNS\nescalated'))
  expect(h.prompts.at(-1)).toContain('judge loop left open (3 consecutive improvements-needed)')
})

test('verdict and path parsing', () => {
  expect(judgeVerdict('status: greenlight — summary: resolved the prior improvements-needed cycle')).toBe('satisfied')
  expect(judgeVerdict('handover:\n  status: improvements-needed\n')).toBe('not-satisfied')
  expect(judgeVerdict('no recognisable verdict here')).toBeUndefined()
  expect(citedPaths('read tests/e2e/docs/onboarding-status.json and scripts/postinstall.js on disk.')).toEqual(['tests/e2e/docs/onboarding-status.json', 'scripts/postinstall.js'])
})
