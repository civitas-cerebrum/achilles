import type { Engine as EngineInterface } from 'claude-code/testing'
import { expect, mock, test } from 'claude-code/testing'

import { receiptProblems } from '../hooks/signoff'
import { ROOT, START, ended, engine, notes, spawnExpert, startRun, type Harness } from './harness'

// Converted from the 0.2.x specs 69 (adversarial-verification receipt) and 70 (evidence bundle and
// its credential scan). A missing, incomplete, stale or hand-written receipt and a missing bundle
// are notes now; the one refusal is a bundle whose HAR or console log holds a live credential.

const RECEIPT_DIR = `${ROOT}/.achilles/adversarial-verification`
const EVI = `${ROOT}/apps/web/tests/evidence`
const GREEN = { negativeControl: { failed: 5, passed: 1, skipped: 0 }, review: { reviewer: 'probe reports', uiReviewed: true, coverageSufficient: true, scores: { R1: 3, R2: 2, R3: 2, R4: 2, R5: 2, R6: 2 }, total: 13 } }
const tracker = (agentId: string, state: unknown, id = 'ABC-1', tool = 'mcp__linear__save_issue') => ({ tool, state, id, agentId })

function bundle(h: Harness, name: string, extra: Record<string, string> = {}) {
  h.write(`${EVI}/${name}/summary.md`, '# Companion-mode evidence\n')
  h.write(`${EVI}/${name}/screenshots/01.png`, 'png')
  for (const [k, v] of Object.entries(extra)) h.write(`${EVI}/${name}/${k}`, v)
}

async function setup($: EngineInterface, h: Harness) {
  h.procs.push(argv => (argv.includes('--git-common-dir') ? `${ROOT}/.git\n` : argv.includes('--abbrev-ref') ? 'feat/widget-toggle\n' : undefined))
  h.write(`${ROOT}/tests/a.spec.ts`, "test('x', () => {})", 1_600_000_000_000)
  await $.session.start(START)
  const orchestrator = await startRun($, h)
  return { orchestrator }
}

/** A reviewer reports the receipt fields; the adapter records them at its turn end. */
async function review($: EngineInterface, h: Harness, orchestrator: string, receipt: unknown) {
  const reviewer = await spawnExpert($, h, 'reviewer', orchestrator, 'Read `.achilles/runs/x/briefs/probe.md` first; write your report to `.achilles/runs/x/reports/probe.md`.')
  await $.tool.call({ tool: 'Skill', skill: 'achilles:review', agentId: reviewer } as never)
  h.write(`${ROOT}/.achilles/runs/x/reports/probe.md`, `# Probe report\n\n\`\`\`json\n${JSON.stringify(receipt)}\n\`\`\`\n`)
  await $.turn.complete(ended(reviewer, 'DONE\nReceipt fields in the report.'))
}

test('a reviewer’s reported receipt fields are recorded by the adapter; a green, fresh receipt with a bundle signs off in silence', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { orchestrator } = await setup($, h)
  await review($, h, orchestrator, { ticket: 'ABC-1', ...GREEN })
  const receipt = JSON.parse(h.files.get(`${RECEIPT_DIR}/ABC-1.json`) ?? '{}')
  expect(receipt.review.uiReviewed).toBe(true)
  expect(receipt.recordedBy[0].agentId).toBe('reviewer-2')
  bundle(h, 'abc-1-widget-toggle-20260812-150715')
  expect((await $.tool.call(tracker(orchestrator, 'Done') as never)).deny).toBeUndefined()
  expect(notes(session, orchestrator)).toEqual([])
  // A second reviewer's fields merge into the same receipt.
  await review($, h, orchestrator, { ticket: 'ABC-1', review: { scores: { R7: 3 } } })
  expect(JSON.parse(h.files.get(`${RECEIPT_DIR}/ABC-1.json`)!).review.scores).toEqual({ ...GREEN.review.scores, R7: 3 })
})

test('sign-off without a receipt, with a hand-written, incomplete or stale one, or without a bundle is a note; the call goes through', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { orchestrator } = await setup($, h)
  const last = () => notes(session, orchestrator).at(-1) ?? ''
  const signOff = async (state = 'Done', id = 'ABC-1') => {
    const n = notes(session, orchestrator).length
    expect((await $.tool.call(tracker(orchestrator, state, id) as never)).deny).toBeUndefined()
    return notes(session, orchestrator).length > n ? last() : ''
  }
  const none = await signOff()
  expect(none).toContain('no sign-off receipt')
  expect(none).toContain('no evidence bundle for ABC-1')
  expect(none).toContain('One ticket, one run of the verify-change workflow')
  expect(await signOff('Completed')).toContain('no sign-off receipt')
  expect(await signOff({ name: 'Resolved' } as never)).toContain('no sign-off receipt')

  bundle(h, 'abc-1-widget-toggle-20260812-150715')
  h.write(`${RECEIPT_DIR}/ABC-1.json`, JSON.stringify({ ticket: 'ABC-1', ...GREEN }))
  expect(await signOff()).toContain('was not recorded by the adapter')

  await review($, h, orchestrator, { ticket: 'ABC-1', ...GREEN, review: { ...GREEN.review, uiReviewed: false, coverageSufficient: false, scores: { R1: 0 } } })
  const partial = await signOff()
  expect(partial).toContain('did not review the UI')
  expect(partial).toContain('did not conclude the coverage is sufficient')
  expect(partial).toContain('R1 scored 0')

  await review($, h, orchestrator, { ticket: 'ABC-1', ...GREEN })
  expect(await signOff()).toBe('')
  h.write(`${ROOT}/tests/a.spec.ts`, "test('y', () => {})", 1_800_000_000_000)
  expect(await signOff()).toContain('OLDER than the most recently edited spec')
  h.write(`${RECEIPT_DIR}/ABC-1.json`, `${h.files.get(`${RECEIPT_DIR}/ABC-1.json`)} `, 1_900_000_000_000)
  expect(await signOff()).toContain('changed after the adapter recorded it')
})

test('only completing transitions and verdict-shaped comments are sign-off; reads, other states and non-QA closures say nothing', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { orchestrator } = await setup($, h)
  for (const state of ['In Progress', 'QA Testing', 'Backlog', "Closed - Won't Do", 'Closed - Duplicate', 'Cancelled', 'Resolved - Invalid'])
    await $.tool.call(tracker(orchestrator, state) as never)
  await $.tool.call({ tool: 'mcp__linear__get_issue', id: 'ABC-1', agentId: orchestrator } as never)
  await $.tool.call({ tool: 'mcp__slack__send_message', text: 'shipped', agentId: orchestrator } as never)
  await $.tool.call({ tool: 'mcp__linear__save_comment', body: 'rebased onto main, retriggering CI', id: 'ABC-1', agentId: orchestrator } as never)
  expect(notes(session, orchestrator)).toEqual([])
  await $.tool.call({ tool: 'mcp__linear__save_comment', body: 'QA Test Report: all AC-1 checks pass', id: 'ABC-1', agentId: orchestrator } as never)
  expect(notes(session, orchestrator).at(-1)).toContain('verdict-shaped comment')
  // The main loop is never touched.
  expect((await $.tool.call({ tool: 'mcp__linear__save_issue', state: 'Done', id: 'ABC-1' } as never)).deny).toBeUndefined()
  expect(notes(session, orchestrator).length).toBe(1)
})

test('a receipt and a bundle belong to one ticket: exact keys, UUIDs through the recorded ticket or the summary, degenerate keys named', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { orchestrator } = await setup($, h)
  await review($, h, orchestrator, { ticket: 'ABC-15', ...GREEN })
  bundle(h, 'abc-15-other-thing-20260812-162000')
  const last = () => notes(session, orchestrator).at(-1) ?? ''
  const n0 = notes(session, orchestrator).length
  await $.tool.call(tracker(orchestrator, 'Done', 'ABC-15') as never)
  expect(notes(session, orchestrator).length).toBe(n0)
  await $.tool.call(tracker(orchestrator, 'Done', 'ABC-1') as never)
  expect(last()).toContain('no sign-off receipt')
  expect(last()).toContain('no evidence bundle for ABC-1')
  const uuid = '9f8e7d6c-1234-4abc-9def-0123456789ab'
  await review($, h, orchestrator, { ticket: uuid, ...GREEN })
  bundle(h, 'abc-7-dated-20260812')
  h.write(`${EVI}/abc-7-dated-20260812/summary.md`, `# s\n${uuid}\n`)
  const n1 = notes(session, orchestrator).length
  await $.tool.call(tracker(orchestrator, 'Done', uuid) as never)
  expect(notes(session, orchestrator).length).toBe(n1)
  await $.tool.call(tracker(orchestrator, 'Done', '00000000-0000-4000-8000-000000000000') as never)
  expect(last()).toContain('no sign-off receipt')
  for (const key of ['json', 'ab', '---']) {
    await $.tool.call(tracker(orchestrator, 'Done', key) as never)
    expect(last()).toContain('no usable ticket key')
  }
})

test('a live credential in the bundle’s HAR or console log refuses the sign-off on every surface; redacted and ordinary values pass', async ($, on) => {
  const h = engine(on)
  const { orchestrator } = await setup($, h)
  await review($, h, orchestrator, { ticket: 'ABC-1', ...GREEN })
  const B = 'abc-1-widget-toggle-20260812-150715'
  const har = (entries: unknown) => JSON.stringify({ log: { entries } })
  const withFile = async (file: string, body: string) => {
    bundle(h, B, { [file]: body })
    const r = await $.tool.call(tracker(orchestrator, 'Done') as never)
    h.remove(`${EVI}/${B}/${file}`)
    return r.deny
  }
  const leak = await withFile('network.har', har([{ request: { headers: [{ name: 'authorization', value: 'REDACTED' }, { name: 'x-deployment-protection-bypass', value: 'aB3xQ9zzLiveValue' }] } }]))
  expect(leak).toContain('still holds a live credential')
  expect(leak).toContain('x-deployment-protection-bypass')
  expect(leak).not.toContain('aB3xQ9zzLiveValue')
  for (const hdr of ['x-auth-token', 'x-csrf-token', 'x-amz-security-token', 'x-api-key'])
    expect(await withFile('network.har', har([{ request: { headers: [{ name: hdr, value: 'LIVEvalue12345' }] } }]))).toContain(hdr)
  expect(await withFile('network.har', har([{ request: { cookies: [{ name: 'app_jwt', value: 'eyJhbGciLIVE' }] } }]))).toContain('app_jwt')
  expect(await withFile('network.har', har([{ request: { queryString: [{ name: 'access_token', value: 'LIVEqueryValue' }] } }]))).toContain('access_token')
  expect(await withFile('network.har', JSON.stringify({ log: { entries: [{ request: { headers: { authorization: 'Bearer LIVEmapValue' } } }] } }))).toContain('authorization')
  expect(await withFile('network.har', har([{ response: { content: { text: '{"access_token":"eyJhbGciLIVE1234"}' } } }]))).toContain('request/response body')
  expect(await withFile('network.har', '{"log":{"entries":[{"request":{"headers":[{"name":"authorization","value":"tr')).toContain('unparseable')
  expect(await withFile('console.log', 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload\n')).toContain('console.log')
  expect(await withFile('console.log', 'password=LIVEpassword1\n')).toContain('console.log')
  expect(await withFile('console.log', '[{"authorization":"Bearer [REDACTED]"},{"api_key":"LIVEVALUE1"}]\n')).toContain('console.log')
  expect(await withFile('preview/network.har', har([{ request: { headers: [{ name: 'authorization', value: 'Bearer LIVEsubdirValue' }] } }]))).toContain('preview/network.har')

  expect(await withFile('network.har', har([{ request: { headers: [{ name: 'x-session-id', value: 'anon-abc123' }, { name: 'user-agent', value: 'Mozilla/5.0' }], cookies: [{ name: 'sessionCartId', value: 'cart-7' }] } }]))).toBeUndefined()
  expect(await withFile('network.har', har([{ request: { headers: [{ name: 'authorization', value: 'REDACTED' }, { name: 'x-deployment-protection-bypass', value: '[REDACTED]' }] } }]))).toBeUndefined()
  expect(await withFile('network.har', '{"log":{"entries":[{"request":{"headers":[{"name":"accept-lang')).toBeUndefined()
  expect(await withFile('console.log', 'Authorization: Bearer [REDACTED]\n[log] rendered 12 rows\n')).toBeUndefined()
  expect(await withFile('console.log', '[error] request failed: api_key= is required\n')).toBeUndefined()
  expect(await withFile('console.log', '[log] endpoint expects authorization: bearer <token>\n')).toBeUndefined()

  bundle(h, B, { 'network.har': har([{ request: { headers: [{ name: 'authorization', value: 'Bearer LIVE' }] } }]) })
  expect((await $.tool.call({ tool: 'mcp__linear__save_comment', body: 'Verdict: PASSED', id: 'ABC-1', agentId: orchestrator } as never)).deny).toContain('live credential')
})

test('gh pr create|ready is sign-off bound to the branch; drafts, reads and mentions are not', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { orchestrator } = await setup($, h)
  const bash = (command: string) => $.tool.call({ tool: 'Bash', command, agentId: orchestrator })
  const last = () => notes(session, orchestrator).at(-1) ?? ''
  for (const c of ['gh pr create --title x --body y', 'gh pr ready 12', 'env gh pr create --fill', "sh -c 'gh pr create --fill'", 'OUT=`gh pr create --title x`', 'gh pr create --title "add -d flag support" --body x', 'gh pr create --draft=False --fill', 'npm test && gh pr ready']) {
    const n = notes(session, orchestrator).length
    expect((await bash(c)).deny).toBeUndefined()
    expect(notes(session, orchestrator).length).toBe(n + 1)
    expect(last()).toContain('binds the bundle to the BRANCH')
    expect(last()).toContain('feat-widget-toggle')
  }
  const n = notes(session, orchestrator).length
  for (const c of ['gh pr create --draft --title wip', 'gh pr create -d --title wip', 'gh pr create --draft=True --fill', 'gh pr view 42', 'gh pr list', 'gh pr checkout 42', 'echo gh pr create', 'grep -r "gh pr create" .', 'git status'])
    expect((await bash(c)).deny).toBeUndefined()
  expect(notes(session, orchestrator).length).toBe(n)
  await review($, h, orchestrator, { ticket: 'feat-widget-toggle', ...GREEN })
  bundle(h, 'feat-widget-toggle-20260812-180000')
  await bash('gh pr create --fill')
  expect(notes(session, orchestrator).length).toBe(n)
})

test('receipt rules: a review must name its reviewer, look at the UI, judge coverage sufficient, score no zero and total above 12', () => {
  expect(receiptProblems({ ticket: 'A', ...GREEN })).toEqual([])
  expect(receiptProblems({ ticket: 'A' })).toEqual(['it has no negativeControl result', 'it has no review block'])
  expect(receiptProblems({ negativeControl: {}, review: { ...GREEN.review, reviewer: '' } })).toEqual(['no reviewer is named'])
  expect(receiptProblems({ negativeControl: {}, review: { ...GREEN.review, total: 12 } })[0]).toContain('at or below 12')
})

// Defect confirmation (verify-change step 7a): a reproducer's verdict is recorded by the adapter;
// a defect filing and a sign-off that reports defects are refused without one.

const CONFIRM_DIR = `${ROOT}/.achilles/defect-confirmations`
const BUG = { ticket: 'ABC-1', 'defect-id': 'ABC-1-D1', verdict: 'bug', reproduction: { attempts: 4, observed: 4 }, expected: 'the address in its own blank', actual: 'the address in the birth-month blank', evidence: ['.achilles/runs/x/repro/04.png'] }
const file = (agentId: string, fields: Record<string, unknown>, tool = 'mcp__atlassian__createJiraIssue') => ({ tool, agentId, projectKey: 'ABC', ...fields })

/** A reproducer reports its verdict; the adapter records it at its turn end. */
async function reproduce($: EngineInterface, h: Harness, orchestrator: string, verdict: unknown, slug = 'repro-d1') {
  const reproducer = await spawnExpert($, h, 'reproducer', orchestrator, `Read \`.achilles/runs/x/briefs/${slug}.md\` first; write your report to \`.achilles/runs/x/reports/${slug}.md\`.`)
  await $.tool.call({ tool: 'Skill', skill: 'achilles:defect-confirmation', agentId: reproducer } as never)
  h.write(`${ROOT}/.achilles/runs/x/reports/${slug}.md`, `# Reproduction\n\n\`\`\`json\n${JSON.stringify(verdict)}\n\`\`\`\n`)
  await $.turn.complete(ended(reproducer, 'DONE\nVerdict in the report.'))
  return reproducer
}

test('a reproducer’s verdict is recorded as the defect’s confirmation; a defect filing needs a recorded bug verdict and says to dispatch the reproducer', async ($, on) => {
  const h = engine(on)
  mock.session(on)
  const { orchestrator } = await setup($, h)
  const create = (fields: Record<string, unknown>) => $.tool.call(file(orchestrator, fields) as never)

  const none = await create({ issueType: 'Rework', parent: 'ABC-1', summary: 'Address lands in the wrong blank', description: 'Steps …' })
  expect(none.deny).toContain('cites no confirmed defect id')
  expect(none.deny).toContain('Dispatch an achilles-reproducer')
  expect((await create({ issueType: 'Bug', summary: 'ABC-1-D1 address in the wrong blank' })).deny).toContain('no recorded confirmation')

  await reproduce($, h, orchestrator, BUG)
  const record = JSON.parse(h.files.get(`${CONFIRM_DIR}/ABC-1/ABC-1-D1.json`) ?? '{}')
  expect(record.verdict).toBe('bug')
  expect(record.recordedBy.agentId).toMatch(/^reproducer-/)
  expect((await create({ issueType: 'Rework', parent: 'ABC-1', summary: 'Address lands in the wrong blank', description: 'Confirmed as ABC-1-D1.' })).deny).toBeUndefined()

  // Adjacent traffic: a story, a task without a defect type, and a fields-shaped create of another type go through.
  expect((await create({ issueType: 'Story', summary: 'Save the template' })).deny).toBeUndefined()
  expect((await create({ fields: { issuetype: { name: 'Task' }, summary: 'Tidy the fixtures' } })).deny).toBeUndefined()
  // The main session is never bound: the user's own decision files.
  expect((await $.tool.call(file('main-session', { issueType: 'Bug', summary: 'Filed on the user’s decision' }) as never)).deny).toBeUndefined()
})

test('a filing citing a non-bug verdict or a hand-written confirmation is refused; a verdict without a live observation is not recorded', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { orchestrator } = await setup($, h)
  const create = (summary: string) => $.tool.call(file(orchestrator, { issueType: 'Bug', summary }) as never)

  await reproduce($, h, orchestrator, { ...BUG, 'defect-id': 'ABC-1-D2', verdict: 'not-a-bug' }, 'repro-d2')
  expect((await create('ABC-1-D2 wording')).deny).toContain('verdict is `not-a-bug`, not `bug`')

  h.write(`${CONFIRM_DIR}/ABC-1/ABC-1-D3.json`, JSON.stringify({ ...BUG, 'defect-id': 'ABC-1-D3' }))
  expect((await create('ABC-1-D3 forged')).deny).toContain('was not recorded by the adapter')

  await reproduce($, h, orchestrator, { ...BUG, 'defect-id': 'ABC-1-D4', reproduction: { attempts: 2, observed: 0 } }, 'repro-d4')
  expect(h.files.has(`${CONFIRM_DIR}/ABC-1/ABC-1-D4.json`)).toBe(false)
  expect(notes(session, orchestrator).join('\n')).toContain('a bug verdict with no live observation')
  expect((await create('ABC-1-D4 never seen')).deny).toContain('no recorded confirmation')
})

test('gh issue create with a bug label needs a confirmed defect id; other gh issue calls go through', async ($, on) => {
  const h = engine(on)
  mock.session(on)
  const { orchestrator } = await setup($, h)
  const bash = (command: string) => $.tool.call({ tool: 'Bash', command, agentId: orchestrator } as never)
  expect((await bash('gh issue create --title "Address in the wrong blank" --label bug --body "steps"')).deny).toContain('Dispatch an achilles-reproducer')
  expect((await bash('gh issue create --title "Add a dark mode" --label enhancement --body "idea"')).deny).toBeUndefined()
  expect((await bash('gh issue view 12')).deny).toBeUndefined()
  await reproduce($, h, orchestrator, BUG)
  expect((await bash('gh issue create --title "ABC-1-D1 address in the wrong blank" --label bug --body "steps"')).deny).toBeUndefined()
})

test('a sign-off is refused while a sentinel of the ticket or a defect-reporting comment has no confirmation; with them it goes through', async ($, on) => {
  const h = engine(on)
  mock.session(on)
  const { orchestrator } = await setup($, h)
  bundle(h, 'abc-1-widget-toggle-20260812-150715')
  const comment = (body: string) => $.tool.call({ tool: 'mcp__atlassian__addCommentToJiraIssue', issueIdOrKey: 'ABC-1', commentBody: body, agentId: orchestrator } as never)

  // Adjacent traffic first: a verdict with no sentinels and no defects, and an unrelated ticket's sentinel.
  h.write(`${ROOT}/tests/other.spec.ts`, "test('TC-1 · [SENTINEL XYZ-9-D1] x @known-defect', () => {})")
  expect((await comment('QA report: all acceptance criteria pass.')).deny).toBeUndefined()
  expect((await $.tool.call(tracker(orchestrator, 'Done') as never)).deny).toBeUndefined()

  h.write(`${ROOT}/tests/widget.spec.ts`, "test('TC-2 · [SENTINEL ABC-1-D1] the address sits in its blank @known-defect', () => {})")
  const refused = await $.tool.call(tracker(orchestrator, 'Done') as never)
  expect(refused.deny).toContain('[SENTINEL ABC-1-D1]')
  expect(refused.deny).toContain('Dispatch an achilles-reproducer')
  expect((await comment('QA report: AC1 passes; two defects found.')).deny).toContain('no recorded confirmation')

  await reproduce($, h, orchestrator, BUG)
  expect((await $.tool.call(tracker(orchestrator, 'Done') as never)).deny).toBeUndefined()
  expect((await comment('QA report: AC1 passes; defect ABC-1-D1 found.')).deny).toBeUndefined()
})
