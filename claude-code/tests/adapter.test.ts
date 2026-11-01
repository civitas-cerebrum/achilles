import { expect, mock, test } from 'claude-code/testing'

import { DELEGATE, ROOT, START, ended, engine, notes, spawnExpert, startRun } from './harness'

const ORCHESTRATOR = 'achilles:achilles-orchestrator'
const INSPECTOR = 'achilles:achilles-inspector'
const AUTHOR = 'achilles:achilles-author'

// An expert spawn as the Agent tool raises it: from an orchestrator's loop, or from main.
const expertSpawn = (subagentType: string, parentAgentId?: string) => ({
  tool_use_id: 'tu-1',
  prompt: 'Your brief is .achilles/runs/x/briefs/b.md',
  description: 'inspect',
  subagentType,
  provider: { plugin: 'engine', tier: 'core' } as const,
  parentModel: 'm',
  background: false,
  fork: false,
  ...(parentAgentId === undefined ? {} : { parentAgentId }),
})

test('session.start registers delegate_qa in the prompt tool list, the command, and every agents/*.md as an agent type', async ($, on) => {
  const h = engine(on)
  const { tools, agents } = h
  await $.session.start(START)
  expect(tools.map(t => t.name)).toEqual(['delegate_qa'])
  expect(tools[0]?.isDeferred).toBe(false)
  expect(agents.map(a => a.name)).toEqual(['achilles-orchestrator', 'achilles-inspector', 'achilles-author', 'achilles-reviewer', 'achilles-doc-writer'])
  expect(agents[1]).toEqual({ name: 'achilles-inspector', description: 'The inspector.', prompt: 'You are the inspector.', tools: ['Read', 'Write', 'Edit', 'Bash'], effort: 'medium' })
  // The orchestrator and the judge (reviewer) name no effort: they take the session's.
  expect(agents.filter(a => 'effort' in a).map(a => a.name)).toEqual(['achilles-inspector', 'achilles-author', 'achilles-doc-writer'])
  expect(h.status()).toBeUndefined()
})

test('delegate_qa starts the orchestrator and answers RUNNING; its hand-back is submitted as a prompt of its own with the run summary', async ($, on) => {
  const h = engine(on)
  await $.session.start(START)

  const call = await $.tool.call({ tool: DELEGATE, task: 'verify the login flow', context: 'staging' } as never)
  expect(call.deny).toBeUndefined()
  expect(String(call.result)).toMatch(/^RUNNING qa-/)
  expect(h.spawns.map(s => s.subagentType)).toEqual([ORCHESTRATOR])
  expect(h.spawns[0]?.prompt).toMatch(/^\[achilles run=qa-[\w-]+\]\nRun qa-/)
  expect(h.spawns[0]?.prompt).toContain('verify the login flow')
  expect(h.spawns[0]?.prompt).toContain('staging')
  expect(h.status()).toBe('1 run · 0 experts running')

  // The orchestrator dispatches an expert with its Agent tool: counted, then released at its end.
  const expert = await $.agent.spawn(expertSpawn(INSPECTOR, 'orchestrator-1'))
  expect(expert.agentId).toBe('inspector-2')
  expect(h.status()).toBe('1 run · 1 expert running (inspector b)')
  await $.turn.complete(ended('inspector-2', 'DONE\nLooked.'))
  expect(h.status()).toBe('1 run · 0 experts running')
  expect(h.prompts.length).toBe(0)

  await $.turn.complete(ended('orchestrator-1', 'DONE\nLogin verified.'))
  expect(h.prompts.length).toBe(1)
  expect(h.prompts[0]).toMatch(/^Achilles hand-back \(run qa-[\w-]+\)\. Relay this to the person\. If it is NEEDS_CONTEXT, ask them the numbered questions and re-delegate only with their answers and run qa-[\w-]+\.\n\nTask: verify the login flow\n\nDONE\nLogin verified\.\n\nRun summary: experts dispatched: inspector ×1\.$/)
  expect(h.status()).toBeUndefined()
})

test('delegate_qa with run resumes that run: same id and directory, resume.json read first; a run with no resume file, a bad id or one still running is refused', async ($, on) => {
  const h = engine(on, { files: { [`${ROOT}/.achilles/runs/qa-old/resume.json`]: '{"run-id":"qa-old"}' } })
  await $.session.start(START)

  const missing = await $.tool.call({ tool: DELEGATE, task: 'go on', run: 'qa-none' } as never)
  expect(String(missing.result)).toBe('NEEDS_CONTEXT\nRun qa-none has no .achilles/runs/qa-none/resume.json to resume from.')
  const bad = await $.tool.call({ tool: DELEGATE, task: 'go on', run: '../etc' } as never)
  expect(String(bad.result)).toMatch(/^NEEDS_CONTEXT\n"\.\.\/etc" is not a run id/)
  expect(h.spawns.length).toBe(0)

  const call = await $.tool.call({ tool: DELEGATE, task: '', run: 'qa-old', context: 'the model server is back' } as never)
  expect(String(call.result)).toMatch(/^RUNNING qa-old\n/)
  expect(h.spawns[0]?.prompt).toMatch(/^\[achilles run=qa-old\]\nResume run qa-old: read \.achilles\/runs\/qa-old\/resume\.json before anything else/)
  expect(h.spawns[0]?.prompt).toContain('Task: resume run qa-old')
  expect(h.spawns[0]?.prompt).toContain('the model server is back')

  const twice = await $.tool.call({ tool: DELEGATE, task: 'again', run: 'qa-old' } as never)
  expect(String(twice.result)).toBe('BLOCKED\nRun qa-old is still running; its hand-back arrives on its own.')
  expect((await $.command.run({ command: 'achilles', args: 'resume qa-old again' } as never)).text).toMatch(/^BLOCKED\nRun qa-old is still running/)
  expect(h.spawns.length).toBe(1)
  await $.turn.complete(ended('orchestrator-1', 'DONE\nResumed.'))
  expect((await $.command.run({ command: 'achilles', args: 'resume qa-old  answers: 1 yes' } as never)).text).toMatch(/^RUNNING qa-old\n/)
  expect(h.spawns[1]?.prompt).toContain('Task: answers: 1 yes')
})

test('an orchestrator turn that is not a hand-back keeps the run live; the next terminal turn hands back once, with the task text whole', async ($, on) => {
  const h = engine(on)
  await $.session.start(START)
  const task = 'Mechanism check, verify-only: in the repo at /private/tmp/some/very/long/path/that/used/to/be/cut/mid-word/0123456789abcdef-0123456789abcdef confirm the login flow still works'
  const orchestrator = await startRun($, h, task)

  await $.turn.complete(ended(orchestrator, 'The inspector is dispatched and running in the background; I am waiting for it.'))
  expect(h.prompts.length).toBe(0)
  expect(h.status()).toBe('1 run · 0 experts running')

  await $.turn.complete(ended(orchestrator, '\nDONE_WITH_CONCERNS\nVerified, one concern.'))
  expect(h.prompts.length).toBe(1)
  expect(h.prompts[0]).toContain(`Task: ${task}\n\n`)
  expect(h.prompts[0]).toContain('DONE_WITH_CONCERNS\nVerified, one concern.')
  expect(h.status()).toBeUndefined()

  await $.turn.complete(ended(orchestrator, 'DONE\nagain'))
  expect(h.prompts.length).toBe(1)
})

test('an orchestrator run that is interrupted or dies hands back one line naming it, not its last words', async ($, on) => {
  const h = engine(on)
  await $.session.start(START)
  await $.tool.call({ tool: DELEGATE, task: 'audit checkout' } as never)
  await $.turn.complete(ended('orchestrator-1', 'half a thought', 'aborted'))
  expect(h.prompts[0]).toContain("BLOCKED\nThe orchestrator's run ended by an interruption before it handed back; its state is under .achilles/runs/qa-")
  expect(h.prompts[0]).not.toContain('half a thought')
  expect(h.status()).toBeUndefined()

  await $.tool.call({ tool: DELEGATE, task: 'audit cart' } as never)
  await $.turn.complete(ended('orchestrator-2', '', 'error'))
  expect(h.prompts[1]).toContain('ended by an API error before it handed back')
})

test('a bare achilles-<role> type is rewritten to the plugin’s name; an expert spawned outside an orchestrator still starts, and the spawning loop gets a note', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  await $.session.start(START)

  const fromMain = await $.agent.spawn(expertSpawn('achilles-author'))
  expect(fromMain.deny).toBeUndefined()
  expect(fromMain.agentId).toBe('author-1')
  expect(h.spawns[0]?.subagentType).toBe(AUTHOR)
  expect(notes(session).length).toBe(1)
  expect(session.appended().filter(r => r.door === 'note')[0]?.agentId).toBeUndefined()
  expect(notes(session)[0]).toMatch(/better routed through delegate_qa/)

  const fromOther = await $.agent.spawn(expertSpawn(INSPECTOR, 'some-other-agent'))
  expect(fromOther.deny).toBeUndefined()
  expect(notes(session, 'some-other-agent').length).toBe(1)

  await $.agent.spawn(expertSpawn('Explore'))
  expect(h.spawns[2]?.subagentType).toBe('Explore')
  expect(notes(session).length).toBe(2)
  expect(h.status()).toBeUndefined()
})

test('ACHILLES_DISABLE=1 keeps the registrations and switches every other hook off', async ($, on) => {
  const h = engine(on, { env: { ACHILLES_DISABLE: '1' } })
  const session = mock.session(on)
  await $.session.start(START)

  const call = await $.tool.call({ tool: DELEGATE, task: 'verify the login flow' } as never)
  expect(String(call.result)).toMatch(/^BLOCKED\nAchilles is switched off/)
  expect(h.spawns.length).toBe(0)
  expect((await $.command.run({ command: 'achilles', args: 'verify' } as never)).text).toMatch(/switched off/)

  const spawned = await $.agent.spawn(expertSpawn('achilles-author'))
  expect(spawned.deny).toBeUndefined()
  expect(h.spawns[0]?.subagentType).toBe('achilles-author')
  expect(notes(session).length).toBe(0)
  expect((await $.tool.call({ tool: 'Bash', command: 'git push --force origin main', agentId: 'author-1' })).deny).toBeUndefined()
  expect((await $.tool.call({ tool: 'Write', file_path: `${ROOT}/tests/e2e/docs/onboarding-status.json`, content: 'x', agentId: 'author-1' })).deny).toBeUndefined()
  expect(h.status()).toBeUndefined()
})

test('an expert spawned by the orchestrator is counted by role for the run summary', async ($, on) => {
  const h = engine(on)
  await $.session.start(START)
  const orchestrator = await startRun($, h)
  const a1 = await spawnExpert($, h, 'author', orchestrator)
  const r1 = await spawnExpert($, h, 'reviewer', orchestrator)
  await $.turn.complete(ended(a1, 'DONE\nwrote'))
  await $.turn.complete(ended(r1, 'DONE\ngreenlight'))
  await $.turn.complete(ended(orchestrator, 'DONE\nall good'))
  expect(h.prompts[0]).toContain('Run summary: experts dispatched: author ×1, reviewer ×1.')
})
