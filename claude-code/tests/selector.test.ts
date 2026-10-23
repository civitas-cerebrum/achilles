import type { Engine as EngineInterface } from 'claude-code/testing'
import { expect, mock, test } from 'claude-code/testing'

import { stepOf } from '../hooks/selector'
import { ROOT, START, ended, engine, notes, spawnExpert, startRun, type Harness } from './harness'

// Converted from the 0.2.x specs 17 (inertness guard: the hook half; the validator's own cases
// are in tests/lib/selector-development), 18 (pipeline stepper, now observed state) and 19
// (revert on stop, now a note at the author's end).

const BUTTON = `${ROOT}/src/Button.tsx`
const BASE = 'export function Button({ label, onClick }) {\n  return <button className="btn-primary" onClick={onClick}>{label}</button>;\n}\n'
const INERT = BASE.replace('onClick={onClick}>', 'onClick={onClick} data-testid="submit-button">')

async function setup($: EngineInterface, h: Harness, brief = 'Load `selector-development`; add a stable selector to the submit button.') {
  // The validator runs in a node child; this stands for it: an inert edit adds exactly the attribute.
  h.procs.push((argv, init) => {
    if (!argv.some(a => a.endsWith('selector-diff-validator.js'))) return undefined
    const { before, after, expectedAttr } = JSON.parse(init?.stdin ?? '{}') as { before: string; after: string; expectedAttr: string }
    if (after.replace(/ [a-z-]+="[a-z0-9-]+"/, '') !== before) return JSON.stringify({ ok: false, reason: 'structural-change', detail: 'element tree differs' })
    if (!after.includes(` ${expectedAttr}=`)) return JSON.stringify({ ok: false, reason: 'wrong-attribute-name', detail: `Expected ${expectedAttr}` })
    return JSON.stringify({ ok: true, attrName: expectedAttr, attrValue: 'submit-button' })
  })
  h.write(BUTTON, BASE)
  await $.session.start(START)
  const orchestrator = await startRun($, h)
  h.write(`${ROOT}/.achilles/runs/x/briefs/submit-button.md`, brief)
  const author = await spawnExpert($, h, 'author', orchestrator, 'Read `.achilles/runs/x/briefs/submit-button.md` first; write your report to `.achilles/runs/x/reports/submit-button.md`.')
  return { orchestrator, author }
}

test('on a selector brief one added inert attribute passes; a structural change, a changed attribute and the wrong attribute name are refused', async ($, on) => {
  const h = engine(on)
  const { author } = await setup($, h)
  expect((await $.tool.call({ tool: 'Write', file_path: BUTTON, content: BASE.replace('<button', '<div><button'), agentId: author })).deny).toContain('structural-change')
  expect((await $.tool.call({ tool: 'Write', file_path: BUTTON, content: BASE.replace('btn-primary', 'btn-secondary'), agentId: author })).deny).toContain('one added inert test attribute')
  h.write(`${ROOT}/tests/e2e/.selector-development/.detected-convention`, 'data-cy\n')
  expect((await $.tool.call({ tool: 'Write', file_path: BUTTON, content: INERT, agentId: author })).deny).toContain('wrong-attribute-name')
  h.remove(`${ROOT}/tests/e2e/.selector-development/.detected-convention`)
  expect((await $.tool.call({ tool: 'Edit', file_path: BUTTON, old_string: 'onClick={onClick}>', new_string: 'onClick={onClick} data-testid="submit-button">', agentId: author })).deny).toBeUndefined()
  expect(h.files.get(BUTTON)).toBe(INERT)
})

test('the inertness check applies only to existing frontend source on a selector brief; tests, notes, new files and other briefs pass', async ($, on) => {
  const h = engine(on)
  const { author, orchestrator } = await setup($, h)
  const bad = BASE.replace('<button', '<div><button')
  expect((await $.tool.call({ tool: 'Write', file_path: `${ROOT}/tests/e2e/login.spec.ts`, content: 'x', agentId: author })).deny).toBeUndefined()
  expect((await $.tool.call({ tool: 'Write', file_path: `${ROOT}/docs/note.md`, content: 'x', agentId: author })).deny).toBeUndefined()
  expect((await $.tool.call({ tool: 'Write', file_path: `${ROOT}/src/New.tsx`, content: bad, agentId: author })).deny).toBeUndefined()
  h.write(`${ROOT}/.achilles/runs/x/briefs/compose.md`, 'Load `test-composer`.')
  const composer = await spawnExpert($, h, 'author', orchestrator, 'Read `.achilles/runs/x/briefs/compose.md` first; write your report to `.achilles/runs/x/reports/compose.md`.')
  expect((await $.tool.call({ tool: 'Write', file_path: BUTTON, content: bad, agentId: composer })).deny).toBeUndefined()
  expect((await $.tool.call({ tool: 'Write', file_path: BUTTON, content: bad })).deny).toBeUndefined()
})

test('a validator that cannot run lets the edit through with a note to review the diff', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  h.procs.push(argv => (argv.some(a => a.endsWith('selector-diff-validator.js')) ? { exitCode: 2, stderr: 'parser missing' } : undefined))
  const { author } = await setup($, h)
  expect((await $.tool.call({ tool: 'Write', file_path: BUTTON, content: BASE.replace('<button', '<div><button'), agentId: author })).deny).toBeUndefined()
  expect(notes(session, author).at(-1)).toContain('the inertness check of src/Button.tsx could not run (parser missing)')
})

test('the eight steps are observed in order and shown in the status line; an out-of-order step is a note', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { author } = await setup($, h)
  const bash = (command: string) => $.tool.call({ tool: 'Bash', command, agentId: author })
  await bash('npx tsc --noEmit')
  expect(notes(session, author).at(-1)).toContain('typecheck ran before before_snapshot, patch_applied')
  await bash('npx playwright-cli -s=selector-ab12cd screenshot tests/e2e/.selector-development/before/submit-button.png')
  await $.tool.call({ tool: 'Write', file_path: BUTTON, content: INERT, agentId: author })
  const n = notes(session, author).length
  for (const c of ['npx tsc --noEmit', 'npm run test:unit', 'npx playwright test tests/e2e/login.spec.ts', 'npx playwright-cli -s=selector-ab12cd screenshot tests/e2e/.selector-development/after/submit-button.png', 'node node_modules/@civitas-cerebrum/achilles/claude-code/lib/visual-diff.js before.png after.png']) await bash(c)
  expect(notes(session, author).length).toBe(n)
  expect(h.status()).toContain('selector submit-button 8/8')
})

test('an author that ends between the patch and the visual diff leaves the orchestrator a revert note; a completed scope says nothing', async ($, on) => {
  const h = engine(on)
  const session = mock.session(on)
  const { author, orchestrator } = await setup($, h)
  await $.tool.call({ tool: 'Bash', command: 'npx playwright-cli -s=selector-ab12cd screenshot tests/e2e/.selector-development/before/submit-button.png', agentId: author })
  await $.tool.call({ tool: 'Write', file_path: BUTTON, content: INERT, agentId: author })
  await $.turn.complete(ended(author, 'BLOCKED\ntypecheck failed'))
  expect(notes(session, orchestrator).join('\n')).toContain('git checkout -- src/Button.tsx')
  expect(h.status()).not.toContain('selector')

  h.write(BUTTON, BASE)
  const second = await spawnExpert($, h, 'author', orchestrator, 'Read `.achilles/runs/x/briefs/submit-button.md` first; write your report to `.achilles/runs/x/reports/submit-button.md`.')
  const before = notes(session, orchestrator).length
  await $.tool.call({ tool: 'Write', file_path: BUTTON, content: INERT, agentId: second })
  for (const c of ['npx tsc --noEmit', 'npx vitest run', 'npx playwright test x.spec.ts', 'node visual-diff.js a.png b.png', 'git add src/Button.tsx']) await $.tool.call({ tool: 'Bash', command: c, agentId: second })
  await $.turn.complete(ended(second, 'DONE\nstaged'))
  expect(notes(session, orchestrator).slice(before).join('\n')).not.toContain('git checkout --')
})

test('step detection reads the parsed command, not its text', () => {
  expect(stepOf('npx playwright-cli -s=x screenshot tests/e2e/.selector-development/before/a.png')).toBe('before_snapshot')
  expect(stepOf('npm run typecheck')).toBe('typecheck')
  expect(stepOf('pnpm vitest run')).toBeUndefined()
  expect(stepOf('npx jest')).toBe('unit_tests')
  expect(stepOf('cd app && npx playwright test x.spec.ts')).toBe('e2e')
  expect(stepOf('git add src/Button.tsx')).toBe('stage')
  expect(stepOf('echo "npx playwright test"')).toBeUndefined()
  expect(stepOf('git commit -m "git add"')).toBeUndefined()
})
