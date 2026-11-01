import type { Engine as EngineInterface } from 'claude-code/testing'
import { expect, mock, test } from 'claude-code/testing'

import { derivedSlug } from '../hooks/bash-judge'
import { ROOT, START, ended, engine, notes, spawnExpert, startRun, type Harness } from './harness'

// Converted from the 0.2.x specs 80 (archiver: the hook half; the backstop's own cases are in
// tests/lib/archive) and 44 (session cleanup, now per expert). The run summary line is asserted
// in adapter.test.ts.

async function setup($: EngineInterface, h: Harness) {
  await $.session.start(START)
  const orchestrator = await startRun($, h)
  const author = await spawnExpert($, h, 'author', orchestrator)
  return { orchestrator, author }
}

const archiveRuns = (h: Harness) => h.ran.filter(r => r.argv.some(a => a.endsWith('archive-run.mjs')))

test('a playwright run by an achilles loop calls the archive backstop with what the command names; other commands and the main loop do not', async ($, on) => {
  const h = engine(on)
  const { author } = await setup($, h)
  h.write(`${ROOT}/package.json`, JSON.stringify({ scripts: { 'test:e2e': 'playwright test --reporter=list', lint: 'eslint .' } }))
  const bash = (command: string) => $.tool.call({ tool: 'Bash', command, agentId: author })
  await bash('npx playwright test tests/e2e/login.spec.ts --output=cli-out')
  expect(archiveRuns(h).at(-1)?.argv.slice(2)).toEqual([ROOT, '--output', 'cli-out', '--trigger', 'author'])
  await bash('PLAYWRIGHT_JSON_OUTPUT_NAME=reports/custom.json npx playwright test')
  expect(archiveRuns(h).at(-1)?.argv).toContain('reports/custom.json')
  await bash('npm run test:e2e')
  expect(archiveRuns(h).length).toBe(3)
  for (const c of ['ls -la test-results/', 'npx playwright show-report', 'npx playwright show-trace x/trace.zip', 'npx playwright-cli -s=composer-j-x-1-c1 open', 'echo "npx playwright test"', 'npm ci --ignore-scripts', 'npm run lint']) await bash(c)
  await $.tool.call({ tool: 'Bash', command: 'npx playwright test' })
  expect(archiveRuns(h).length).toBe(3)
})

test('the backstop’s outcome: an archive counts toward the run summary, skips and prunes are named, a failure says copy the evidence out', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  let answer = '{"archived":true,"runId":"20261023T120000Z","files":4,"skipped":[{"path":"x/trace.zip"}],"pruned":["20261001T000000Z"],"incomplete":false}'
  h.procs.push(argv => (argv.some(a => a.endsWith('archive-run.mjs')) ? (answer === 'fail' ? { exitCode: 1, stderr: 'EACCES' } : answer) : undefined))
  const { author, orchestrator } = await setup($, h)
  await $.tool.call({ tool: 'Bash', command: 'npx playwright test', agentId: author })
  const said = notes(session, author).at(-1)!
  expect(said).toContain('archived under .achilles/runs/20261023T120000Z/')
  expect(said).toContain('1 trace/video file(s) were skipped over ACHILLES_ARTIFACT_MAX_MB')
  expect(said).toContain('older runs pruned past ACHILLES_ARTIFACT_RETAIN: 20261001T000000Z')
  answer = '{"archived":false,"why":"already archived by the reporter"}'
  const n = notes(session, author).length
  await $.tool.call({ tool: 'Bash', command: 'npx playwright test', agentId: author })
  expect(notes(session, author).length).toBe(n)
  answer = 'fail'
  await $.tool.call({ tool: 'Bash', command: 'npx playwright test', agentId: author })
  expect(notes(session, author).at(-1)).toContain('could not be archived (EACCES)')
  await $.turn.complete(ended(author, 'DONE\nran'))
  await $.turn.complete(ended(orchestrator, 'DONE\nall green'))
  expect(h.prompts.at(-1)).toContain('playwright runs archived under .achilles/runs/: 1')
})

test('an expert’s own playwright-cli sessions close when its turn ends; an expert that opened none runs nothing', async ($, on) => {
  const h = engine(on)
  const { orchestrator } = await setup($, h)
  const inspector = await spawnExpert($, h, 'inspector', orchestrator)
  await $.tool.call({ tool: 'Bash', command: 'npx playwright-cli -s=phase1-root open http://app', agentId: inspector })
  await $.tool.call({ tool: 'Bash', command: 'npx playwright-cli open http://app/settings', agentId: inspector })
  await $.turn.complete(ended(inspector, 'DONE\nmapped'))
  const close = h.ran.filter(r => r.argv[0] === 'sh')
  expect(close.length).toBe(1)
  expect(close[0]!.argv[2]).toBe(`npx --no-install playwright-cli -s=phase1-root close >/dev/null 2>&1; npx --no-install playwright-cli -s=${derivedSlug('inspector', inspector)} close >/dev/null 2>&1`)
  const reviewer = await spawnExpert($, h, 'reviewer', orchestrator)
  await $.turn.complete(ended(reviewer, 'DONE\nreviewed'))
  expect(h.ran.filter(r => r.argv[0] === 'sh').length).toBe(1)
})
