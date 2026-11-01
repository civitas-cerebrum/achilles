import type { Engine as EngineInterface } from 'claude-code/testing'
import { expect, mock, test } from 'claude-code/testing'

import { ROOT, START, ended, engine, notes, startRun, type Harness } from './harness'

// Converted from the 0.2.x specs 48 (schema pointer in the brief), 49 (first-pass and cycle-1
// dispatch shape), 50 and 65 (dispatch order against the ledger) and 53 (reviewer brief). Every
// former deny is a note to the orchestrator; every dispatch starts, with the preamble prepended.

const SKILLS: Record<string, string> = {
  'section-auth': 'journey-mapping',
  composer: 'test-composer',
  'probe-review': 'review',
}

async function setup($: EngineInterface, h: Harness) {
  h.write(`${ROOT}/schemas/canonical-sections.txt`, '# vocabulary\nauth\ncatalog\ncart\norder\nprofile\n')
  await $.session.start(START)
  return startRun($, h)
}

function spawn($: EngineInterface, parentAgentId: string, role: string, prompt: string, extra: Record<string, unknown> = {}) {
  return $.agent.spawn({ tool_use_id: `tu-${role}-${prompt.length}`, prompt, description: `${role} task`, subagentType: `achilles-${role}`, provider: { plugin: 'engine', tier: 'core' }, parentModel: 'm', background: false, fork: false, parentAgentId, ...extra } as never)
}

const brief = (h: Harness, slug: string, body: string) => {
  h.write(`${ROOT}/.achilles/runs/x/briefs/${slug}.md`, body)
  return `Read \`.achilles/runs/x/briefs/${slug}.md\` first; write your report to \`.achilles/runs/x/reports/${slug}.md\`.`
}

test('a well-formed dispatch starts with the preamble prepended and says nothing; the schema the brief names is pointed at', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  // The plugin's own root holds the schemas; the harness's plugin root is wherever the kit loads it from.
  const orchestrator = await setup($, h)
  const prompt = brief(h, 'composer', `# Brief\nLoad the \`${SKILLS.composer}\` skill.\nReturn per schemas/subagent-returns/composer.schema.json.\n`)
  const r = await spawn($, orchestrator, 'author', prompt)
  expect(r.deny).toBeUndefined()
  const spawned = h.spawns.at(-1)!
  expect(spawned.prompt.startsWith('[achilles author] Read your brief first (.achilles/runs/x/briefs/composer.md). Write your report to .achilles/runs/x/reports/composer.md before your final message, and start that message with DONE, DONE_WITH_CONCERNS, NEEDS_CONTEXT or BLOCKED. Your return opens with the handover envelope and validates against schemas/subagent-returns/composer.schema.json.')).toBe(true)
  expect(spawned.prompt.endsWith(prompt)).toBe(true)
  expect(notes(session, orchestrator)).toEqual([])
})

test('a background dispatch runs in the foreground; a missing brief, report or skill, a foreign schema and a resumed reviewer are named', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const orchestrator = await setup($, h)
  const last = () => notes(session, orchestrator).at(-1) ?? ''
  await spawn($, orchestrator, 'inspector', brief(h, 'section-auth', 'Load `journey-mapping`.'), { background: true })
  expect(h.spawns.at(-1)?.background).toBe(false)
  expect(last()).toContain('runs in the foreground')
  await spawn($, orchestrator, 'author', 'Write some tests for login.')
  expect(notes(session, orchestrator).slice(-2).join('\n')).toContain('names no brief file')
  expect(last()).toContain('names no report path')
  await spawn($, orchestrator, 'author', 'Read `.achilles/runs/x/briefs/missing.md` first; write your report to `.achilles/runs/x/reports/missing.md`.')
  expect(notes(session, orchestrator).join('\n')).toContain('the brief .achilles/runs/x/briefs/missing.md does not exist')
  await spawn($, orchestrator, 'author', brief(h, 'no-skill', '# Brief\nWrite the login tests.\n'))
  expect(notes(session, orchestrator).join('\n')).toContain('names no skill for the author to load')
  await spawn($, orchestrator, 'author', brief(h, 'wrong-schema', 'Load `test-composer`. Return per reviewer-inloop.schema.json.'))
  expect(notes(session, orchestrator).join('\n')).toContain('reviewer-inloop.schema.json, which is not a return shape of the author')
  await spawn($, orchestrator, 'reviewer', brief(h, 'probe-review', 'Load `review`.'), { resume: { agentId: 'reviewer-old' } })
  expect(notes(session, orchestrator).join('\n')).toContain('a reviewer is resumed rather than dispatched fresh')
})

test('a second author while one is running is named; read-only experts beside an author are not', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const orchestrator = await setup($, h)
  await spawn($, orchestrator, 'author', brief(h, 'a1', 'Load `test-composer`.'))
  await spawn($, orchestrator, 'inspector', brief(h, 'i1', 'Load `journey-mapping`.'))
  await spawn($, orchestrator, 'reviewer', brief(h, 'r1', 'Load `review`.'))
  expect(notes(session, orchestrator)).toEqual([])
  await spawn($, orchestrator, 'author', brief(h, 'a2', 'Load `test-composer`.'))
  expect(notes(session, orchestrator).at(-1)).toContain('at most one author edits shared fixtures at a time')
})

test('the ledger orders dispatches: a completed phase awaiting review asks for the reviewer first; a fourth review round is named', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const orchestrator = await setup($, h)
  const ledger = (phases: unknown[]) => h.write(`${ROOT}/tests/e2e/docs/onboarding-status.json`, JSON.stringify({ currentPhase: 2, phases }))
  ledger([{ id: 1, name: 'Scaffold', status: 'completed', reviewerVerdict: 'pending', reviewerCycles: 0 }])
  const p2 = await spawn($, orchestrator, 'author', brief(h, 'p2', 'Load `test-composer`.'))
  expect(notes(session, orchestrator).at(-1)).toContain('phase 1 (Scaffold) is completed with reviewerVerdict "pending"')
  await $.turn.complete(ended(p2.agentId!, 'DONE\nstopped'))
  const n = notes(session, orchestrator).length
  await spawn($, orchestrator, 'reviewer', brief(h, 'rv1', 'Load `review`.'))
  expect(notes(session, orchestrator).length).toBe(n)
  ledger([{ id: 1, name: 'Scaffold', status: 'completed', reviewerVerdict: 'approved', reviewerCycles: 1 }])
  await spawn($, orchestrator, 'author', brief(h, 'p2b', 'Load `test-composer`.'))
  expect(notes(session, orchestrator).length).toBe(n)
  ledger([{ id: 1, name: 'Scaffold', status: 'completed', reviewerVerdict: 'rejected', reviewerCycles: 3 }])
  await spawn($, orchestrator, 'reviewer', brief(h, 'rv4', 'Load `review`.'))
  expect(notes(session, orchestrator).at(-1)).toContain('three review rounds')
})

test('journey-mapping cycle 1 is per section: one inspector naming three sections is named, per-section and later-cycle dispatches are not', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const orchestrator = await setup($, h)
  h.write(`${ROOT}/tests/e2e/docs/onboarding-status.json`, JSON.stringify({ currentPhase: 4, phases: [] }))
  await spawn($, orchestrator, 'inspector', brief(h, 'walk', 'Load `journey-mapping`. Map auth, catalog and cart.'))
  expect(notes(session, orchestrator).at(-1)).toContain('names 3 sections (auth, catalog, cart)')
  const n = notes(session, orchestrator).length
  await spawn($, orchestrator, 'inspector', brief(h, 'section-auth', 'Load `journey-mapping`. Map the auth section.'))
  await spawn($, orchestrator, 'inspector', brief(h, 'coord', 'Load `journey-mapping`. Coordinate j-auth, j-cart and j-order.'))
  await spawn($, orchestrator, 'author', brief(h, 'map', 'Load `journey-mapping`. Author the journey-map.'))
  expect(notes(session, orchestrator).slice(n).join('\n')).toContain('journey-map author is dispatched before cycle 1 has two section returns')
  h.write(`${ROOT}/tests/e2e/docs/.phase4-cycle-state.json`, JSON.stringify({ cycles: { '1': { 'dispatched-sections': ['auth', 'catalog', 'cart'] } } }))
  const m = notes(session, orchestrator).length
  await spawn($, orchestrator, 'inspector', brief(h, 'cycle2', 'Load `journey-mapping`. Revisit auth, catalog and cart.'))
  expect(notes(session, orchestrator).length).toBe(m)
  h.write(`${ROOT}/tests/e2e/docs/.phase4-cycle-state.json`, JSON.stringify({ cycleStrictness: 'depth', cycles: { '1': { 'dispatched-sections': ['auth', 'catalog', 'cart'] } } }))
  await spawn($, orchestrator, 'inspector', brief(h, 'cycle2d', 'Load `journey-mapping`. Revisit auth, catalog and cart.'))
  expect(notes(session, orchestrator).at(-1)).toContain('one inspector per section')
})

test('a spawn that is not the orchestrator’s is not given the preamble', async ($, on) => {
  const h = engine(on)
  await $.session.start(START)
  await spawn($, 'some-other-agent', 'author', 'just do it')
  expect(h.spawns.at(-1)?.prompt).toBe('just do it')
})
