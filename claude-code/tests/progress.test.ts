import type { Engine as EngineInterface } from 'claude-code/testing'
import { expect, test } from 'claude-code/testing'

import { ROOT, START, ended, engine, spawnExpert, startRun, type Harness } from './harness'

// Progress (hook 8): the stages a run has done, is in and has to go, read from the pipeline
// ledger it writes or the plan in its resume.json; the experts at work; progress.json; and the
// short progress prompt the main session relays when a stage ends while stages remain.

const LEDGER = 'tests/e2e/docs/onboarding-status.json'
const NAMES = ['Scaffold', 'Groundwork', 'Happy-path', 'Journey-mapping', 'Coverage-expansion', 'Bug-discovery', 'Secrets-sweep', 'Report']

const ledger = (statuses: string[]) => ({
  schemaVersion: 1,
  runMode: 'standard',
  modeAuthorizer: 'the user asked for the full pipeline',
  currentPhase: Math.max(1, statuses.lastIndexOf('completed') + 2),
  status: 'in-progress',
  phases: NAMES.map((name, i) => ({ id: i + 1, name, status: statuses[i] ?? 'pending', reviewerVerdict: 'pending', reviewerCycles: 0, handoverEnvelope: statuses[i] === 'completed' ? { status: 'complete' } : null })),
  approvedDeviations: [],
})

const write = ($: EngineInterface, agentId: string, path: string, content: unknown) =>
  $.tool.call({ tool: 'Write', file_path: `${ROOT}/${path}`, content: JSON.stringify(content, null, 2), agentId } as never)

async function begin($: EngineInterface, h: Harness) {
  await $.session.start(START)
  const orchestrator = await startRun($, h, 'onboard the app')
  const run = /^\[achilles run=([\w-]+)\]/.exec(h.spawns[0]!.prompt)![1]!
  const progress = () => JSON.parse(h.files.get(`${ROOT}/.achilles/runs/${run}/progress.json`) ?? 'null')
  return { orchestrator, run, progress }
}

const brief = (run: string, slug: string) => `Read \`.achilles/runs/${run}/briefs/${slug}.md\` first; write your report to \`.achilles/runs/${run}/reports/${slug}.md\`.`

test('delegate_qa names progress.json and writes it at once; the ledger the run writes becomes its stages, in the status line and the file', async ($, on) => {
  const h = engine(on)
  const call = await $.tool.call({ tool: 'mcp__achilles__delegate_qa', task: 'onboard the app' } as never)
  expect(String(call.result)).toMatch(/read \.achilles\/runs\/qa-[\w-]+\/progress\.json/)
  const run = /^\[achilles run=([\w-]+)\]/.exec(h.spawns[0]!.prompt)![1]!
  expect(JSON.parse(h.files.get(`${ROOT}/.achilles/runs/${run}/progress.json`)!)).toMatchObject({ run, task: 'onboard the app', stages: [], current: null, experts: [] })
})

test('a stage that ends sends one progress prompt, from a timer and not from the write; experts at work and handed back are tracked', async ($, on) => {
  const h = engine(on)
  const { orchestrator, run, progress } = await begin($, h)

  await write($, orchestrator, LEDGER, ledger(['in-progress']))
  expect(h.status()).toBe('1 run · 0 experts running · stage 1/8 Scaffold')
  expect(progress()).toMatchObject({ ledger: LEDGER, current: 'Scaffold', done: [], remaining: NAMES.slice(1), position: 'stage 1/8 Scaffold' })

  const author = await spawnExpert($, h, 'author', orchestrator, brief(run, 'p1-scaffold'))
  expect(h.status()).toBe('1 run · 1 expert running (author p1-scaffold) · stage 1/8 Scaffold')
  expect(progress().experts).toEqual([
    expect.objectContaining({ role: 'author', slug: 'p1-scaffold', agentId: author, brief: `.achilles/runs/${run}/briefs/p1-scaffold.md`, since: expect.stringMatching(/^\d{4}-\d\d-\d\dT/) }),
  ])
  await $.turn.complete(ended(author, 'DONE\nScaffolded.'))
  expect(progress().experts).toEqual([])
  expect(progress().finished).toEqual([expect.objectContaining({ role: 'author', slug: 'p1-scaffold', status: 'DONE' })])

  await write($, orchestrator, LEDGER, ledger(['completed', 'in-progress']))
  expect(h.prompts).toEqual([])
  await h.clock.settle()
  expect(h.prompts.length).toBe(1)
  expect(h.prompts[0]).toBe(
    [
      `Achilles progress (run ${run}). Tell the person in a line or two. This is not a hand-back: take no other action and do not re-delegate.`,
      '',
      'Task: onboard the app',
      'Completed: stage 1/8 Scaffold.',
      'Now: stage 2/8 Groundwork.',
      `To go: ${NAMES.slice(2).join(', ')}.`,
      `Progress file: .achilles/runs/${run}/progress.json`,
    ].join('\n'),
  )
  expect(progress()).toMatchObject({ current: 'Groundwork', done: ['Scaffold'] })

  // A write that ends no stage says nothing more.
  await write($, orchestrator, LEDGER, ledger(['completed', 'in-progress']))
  await h.clock.settle()
  expect(h.prompts.length).toBe(1)
})

test('a run seen first with stages already ended (a resume) replays nothing; a skipped stage is named with its status', async ($, on) => {
  const h = engine(on)
  const { orchestrator, progress } = await begin($, h)
  await write($, orchestrator, LEDGER, ledger(['completed', 'completed', 'in-progress']))
  await h.clock.settle()
  expect(h.prompts).toEqual([])
  await write($, orchestrator, LEDGER, ledger(['completed', 'completed', 'skipped', 'in-progress']))
  await h.clock.settle()
  expect(h.prompts.length).toBe(1)
  expect(h.prompts[0]).toContain('Ended skipped: stage 3/8 Happy-path.')
  expect(progress().done).toEqual(['Scaffold', 'Groundwork', 'Happy-path (skipped)'])
})

test('without a pipeline ledger the plan in resume.json is the stages; the last stage ending is left to the hand-back, which closes progress.json', async ($, on) => {
  const h = engine(on)
  const { orchestrator, run, progress } = await begin($, h)
  const resume = `.achilles/runs/${run}/resume.json`
  await write($, orchestrator, resume, { step: 'inspect', plan: [{ stage: 'Inspect', status: 'in-progress' }, 'Author', { name: 'Review' }] })
  expect(h.status()).toContain('stage 1/3 Inspect')
  expect(progress()).toMatchObject({ step: 'inspect', ledger: null, remaining: ['Author', 'Review'] })

  await write($, orchestrator, resume, { step: 'review', plan: [{ stage: 'Inspect', status: 'completed' }, { stage: 'Author', status: 'completed' }, { stage: 'Review', status: 'in-progress' }] })
  await h.clock.settle()
  expect(h.prompts.length).toBe(1)
  expect(h.prompts[0]).toContain('Completed: stage 1/3 Inspect.\nCompleted: stage 2/3 Author.\nNow: stage 3/3 Review.')

  await write($, orchestrator, resume, { step: 'done', plan: [{ stage: 'Inspect', status: 'completed' }, { stage: 'Author', status: 'completed' }, { stage: 'Review', status: 'completed' }] })
  await h.clock.settle()
  expect(h.prompts.length).toBe(1)

  await $.turn.complete(ended(orchestrator, 'DONE\nAll three stages done.'))
  expect(h.prompts.length).toBe(2)
  expect(h.prompts[1]).toMatch(/^Achilles hand-back/)
  expect(progress()).toMatchObject({ ended: 'DONE', current: null, done: ['Inspect', 'Author', 'Review'], remaining: [] })
})

test('writes by loops outside a run, and other files, move nothing', async ($, on) => {
  const h = engine(on)
  const { orchestrator, run, progress } = await begin($, h)
  await write($, 'someone-else', LEDGER, ledger(['in-progress']))
  expect(progress().stages).toEqual([])
  await write($, orchestrator, `.achilles/runs/${run}/notes.json`, { plan: ['A'] })
  expect(progress().stages).toEqual([])
  expect(h.status()).toBe('1 run · 0 experts running')
})

test('the pane draws the stage checklist, the experts at work and the last expert hand-backs', async ($, on) => {
  const h = engine(on)
  const { orchestrator, run } = await begin($, h)
  await write($, orchestrator, LEDGER, ledger(['completed', 'in-progress']))
  const reviewer = await spawnExpert($, h, 'reviewer', orchestrator, brief(run, 'p1-review'))
  await $.turn.complete(ended(reviewer, 'DONE\napproved'))
  await spawnExpert($, h, 'author', orchestrator, brief(run, 'p2-groundwork'))
  const ui = await $.ui.mount({
    plugin: 'achilles',
    component: 'Pane',
    requestId: 'achilles',
    surface: 'terminal',
    props: { title: 'Achilles', isFocused: false, bodyColumns: 100, placement: 'dock', scroll: { offset: 0, bodyRows: 40 }, view: {} },
  } as never)
  expect((await ui.find({ type: 'Text', text: /^ {2}stage 2\/8 Groundwork$/ }))?.text).toBeDefined()
  expect((await ui.find({ type: 'Text', text: /✓ Scaffold/ }))?.text).toBe('  ✓ Scaffold')
  expect((await ui.find({ type: 'Text', text: /▸ Groundwork/ }))?.text).toBe('  ▸ Groundwork')
  expect((await ui.find({ type: 'Text', text: /· Report/ }))?.text).toBe('  · Report')
  expect((await ui.find({ type: 'Text', text: /author author-\d+ .*p2-groundwork\.md · since \d\d:\d\d$/ }))?.text).toBeDefined()
  expect((await ui.find({ type: 'Text', text: /handed back/ }))?.text).toBe('  handed back: reviewer p1-review DONE')
  await ui.unmount()
})

test('more than two experts at work are counted by role in the status line', async ($, on) => {
  const h = engine(on)
  const { orchestrator, run } = await begin($, h)
  for (const section of ['auth', 'cart', 'catalog']) await spawnExpert($, h, 'inspector', orchestrator, brief(run, `p4-c1-${section}`))
  await spawnExpert($, h, 'reviewer', orchestrator, brief(run, 'p4-c1-review'))
  expect(h.status()).toBe('1 run · 4 experts running (inspector ×3, reviewer)')
})
