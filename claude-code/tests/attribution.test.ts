import type { Engine as EngineInterface } from 'claude-code/testing'
import { expect, mock, test } from 'claude-code/testing'

import { ROOT, START, engine, notes, spawnExpert, startRun, type Harness } from './harness'

// No AI signature on anything that leaves the run (skills/achilles-orchestrator/references/outbound-text.md):
// commits, pull requests, issues and comments (the Bash judge), outbound MCP writes and report
// documents (hooks/attribution.ts). Every deny carries adjacent-traffic allows.

async function setup($: EngineInterface, h: Harness, role = 'doc-writer') {
  await $.session.start(START)
  const orchestrator = await startRun($, h)
  const agentId = await spawnExpert($, h, role, orchestrator)
  return { orchestrator, agentId }
}

const SIGNATURES = [
  'Steps …\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>',
  'Steps …\n\nClaude-Session: https://claude.ai/code/session_017Z',
  'Steps …\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)',
]

test('an outbound MCP write (ticket, comment, page, message) with an AI signature is refused; clean text, reads and the main loop pass', async ($, on) => {
  const h = engine(on)
  mock.session(on)
  const { orchestrator, agentId } = await setup($, h)
  const call = (tool: string, args: Record<string, unknown>, as = agentId) => $.tool.call({ tool, agentId: as, ...args } as never)
  for (const body of SIGNATURES) {
    expect((await call('mcp__atlassian__createJiraIssue', { summary: 'Address in the wrong blank', description: body })).deny).toContain('AI signature')
    expect((await call('mcp__atlassian__addOrEditJiraIssueComment', { issueIdOrKey: 'ABC-1', commentBody: body }, orchestrator)).deny).toContain('AI signature')
  }
  expect((await call('mcp__slack__slack_send_message', { channel: 'qa', text: SIGNATURES[2] })).deny).toContain('AI signature')
  expect((await call('mcp__atlassian__editJiraIssue', { fields: { description: { nested: [SIGNATURES[0]] } } })).deny).toContain('AI signature')
  // Adjacent traffic: clean text, a human co-author, a read that returns a signature-shaped body, the main loop.
  expect((await call('mcp__atlassian__createJiraIssue', { summary: 'Address in the wrong blank', description: 'Steps to reproduce …' })).deny).toBeUndefined()
  expect((await call('mcp__atlassian__addOrEditJiraIssueComment', { commentBody: 'Paired with\n\nCo-Authored-By: Jane Doe <jane@example.com>' })).deny).toBeUndefined()
  expect((await call('mcp__atlassian__getJiraIssue', { issueIdOrKey: 'ABC-1', note: SIGNATURES[0] })).deny).toBeUndefined()
  expect((await call('mcp__atlassian__searchJiraIssuesUsingJql', { jql: 'text ~ "Generated with Claude Code"' })).deny).toBeUndefined()
  expect((await $.tool.call({ tool: 'mcp__atlassian__createJiraIssue', summary: 'x', description: SIGNATURES[0] } as never)).deny).toBeUndefined()
})

test('agent framing in an outbound message is a note, not a refusal', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { agentId } = await setup($, h)
  const r = await $.tool.call({ tool: 'mcp__atlassian__addOrEditJiraIssueComment', agentId, commentBody: 'Confirmed by a separate AI QA agent that did not see our tests.' } as never)
  expect(r.deny).toBeUndefined()
  expect(notes(session, agentId).join('\n')).toContain('reads as an agent')
  const n = notes(session, agentId).length
  await $.tool.call({ tool: 'mcp__atlassian__addOrEditJiraIssueComment', agentId, commentBody: 'Confirmed by an independent second QA pass.' } as never)
  expect(notes(session, agentId).length).toBe(n)
})

test('a report document with an AI signature is refused; other files, clean reports and the main loop pass', async ($, on) => {
  const h = engine(on)
  mock.session(on)
  const { agentId } = await setup($, h)
  const write = (file_path: string, content: string) => $.tool.call({ tool: 'Write', file_path, content, agentId } as never)
  expect((await write(`${ROOT}/docs/qa/report.md`, `# QA report\n\n${SIGNATURES[2]}`)).deny).toContain('in the report docs/qa/report.md')
  expect((await write(`${ROOT}/tests/e2e/evidence/abc-1-run/summary.md`, `# Evidence\n\n${SIGNATURES[1]}`)).deny).toContain('AI signature')
  expect((await $.tool.call({ tool: 'Edit', file_path: `${ROOT}/tests/e2e/docs/qa-summary.md`, old_string: 'x', new_string: SIGNATURES[0], agentId } as never)).deny).toContain('AI signature')
  expect((await write(`${ROOT}/docs/qa/report.md`, '# QA report\n\nAll ACs pass.')).deny).toBeUndefined()
  expect((await write(`${ROOT}/.achilles/runs/x/reports/b.md`, `notes\n${SIGNATURES[0]}`)).deny).toBeUndefined()
  expect((await $.tool.call({ tool: 'Write', file_path: `${ROOT}/docs/qa/report.md`, content: SIGNATURES[0] } as never)).deny).toBeUndefined()
})

test('gh issue create|comment and gh pr comment|review with AI attribution are denied; clean bodies and reads pass', async ($, on) => {
  const h = engine(on)
  const { agentId } = await setup($, h, 'author')
  const bash = (command: string) => $.tool.call({ tool: 'Bash', command, agentId } as never)
  h.write('/tmp/sig', 'Steps\n\nClaude-Session: https://claude.ai/code/session_1\n')
  expect((await bash("gh issue create --title 'x' --body 'Steps\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)'")).deny).toMatch(/AI-attribution in an issue/)
  expect((await bash('gh issue comment 12 --body-file /tmp/sig')).deny).toMatch(/AI-attribution in a comment/)
  expect((await bash("gh pr comment 7 --body 'LGTM\n\nCo-Authored-By: Claude <noreply@anthropic.com>'")).deny).toMatch(/AI-attribution in a comment/)
  expect((await bash("gh pr review 7 --approve --body 'see https://claude.ai/code'")).deny).toMatch(/AI-attribution in a comment/)
  expect((await bash("git commit -m 'test(j-x): fix' -m 'Claude-Session: https://claude.ai/code/session_1'")).deny).toMatch(/AI-attribution in a commit/)
  expect((await bash("gh issue create --title 'Address in the wrong blank' --body 'Steps to reproduce'")).deny).toBeUndefined()
  expect((await bash("gh pr comment 7 --body 'Verified on staging.'")).deny).toBeUndefined()
  expect((await bash('gh issue view 12')).deny).toBeUndefined()
})
