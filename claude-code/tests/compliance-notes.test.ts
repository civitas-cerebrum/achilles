import type { On } from 'claude-code'
import type { Engine as EngineInterface } from 'claude-code/testing'
import { expect, mock, test } from 'claude-code/testing'

import type { AchillesRun } from '../types'
import { capRows } from '../hooks/compliance-notes'
import { ROOT, START, cleanLint, ended, engine, fakeBlob, notes, spawnExpert, startRun, type Harness } from './harness'

// The write-time notes of the test baseline: a Write or Edit of a spec or support file by an Achilles
// agent runs the lint in write mode and notes only what the write added; every write is recorded in the
// run's touched list; a shell write is recorded without a note; an expert's hand-back lists the blocking
// findings in the tests it touched. Every case is an allow: nothing here refuses a call.

const BLOCKING = {
  rule: 'TB-F1',
  severity: 'blocking',
  file: 'tests/e2e/login.spec.ts',
  line: 3,
  message: '`if` whose branch performs an action or an assertion (test body)',
  do: 'Remove the branch: a fixture resolves the state, or a verb in a flow module owns the optional step.',
  why: 'skills/achilles-orchestrator/references/test-baseline.md#tb-f1',
  test: { title: 'TCLG-000001 · opens', id: 'TCLG-000001', line: 2 },
  waived: false,
}
const ADVISORY = { ...BLOCKING, rule: 'TB-R4', severity: 'advisory', line: 2, message: 'the test makes no assertion', why: 'skills/achilles-orchestrator/references/test-baseline.md#tb-r4' }

type Lint = { exitCode?: number; stdout?: string; stderr?: string } | 'throw'
type Case = {
  name: string
  /** Who writes: an Achilles author, the orchestrator, or the main session. */
  as: 'author' | 'orchestrator' | 'main'
  tool: 'Write' | 'Edit'
  file: string
  /** The file on disk before the call (an Edit needs it). */
  before?: string
  content: string
  /** The lint child's answer; omitted: the harness answers clean. */
  lint?: (findings: unknown[]) => Lint
  findings?: unknown[]
  expect: 'allow' | 'advise'
  messageContains?: string[]
  messageExcludes?: string[]
  /** The note is one line followed by its References block. */
  oneLine?: boolean
  /** The row the run records, or null for none. */
  touched?: { rel: string; top?: string; objectId?: 'any' | 'none'; kind?: string | null } | null
  /** True when the lint child must not run at all. */
  noLint?: boolean
}

const SPEC = 'tests/e2e/login.spec.ts'
const report = (path: string, findings: unknown[]) => JSON.stringify({ ...cleanLint(['--stdin'], JSON.stringify({ file: path, after: 'x' })), findings })

const CASES: Case[] = [
  { name: 'an author writes a clean spec: no note, the write is recorded with its object id', as: 'author', tool: 'Write', file: SPEC, content: "test('TCLG-000001 · opens', async () => {})", expect: 'allow', touched: { rel: SPEC, objectId: 'any', kind: 'spec' } },
  {
    name: 'an author writes a spec with a new blocking finding: a note naming the rule and its rulebook anchor',
    as: 'author',
    tool: 'Write',
    file: SPEC,
    content: 'if (x) await steps.click()',
    findings: [BLOCKING],
    lint: f => ({ exitCode: 1, stdout: report(SPEC, f) }),
    expect: 'advise',
    messageContains: ['[TB-F1]', 'test-baseline.md#tb-f1', 'blocking under the test baseline', `${SPEC}:3 TCLG-000001`, '→ Do: Remove the branch', 'References:\n  skills/achilles-orchestrator/references/test-baseline.md'],
    messageExcludes: ['refus', 'will block', 'gate'],
    touched: { rel: SPEC, objectId: 'any' },
  },
  {
    name: 'an advisory finding alone is a note that says advisory',
    as: 'author',
    tool: 'Write',
    file: SPEC,
    content: "test('TCLG-000001 · opens', async () => {})",
    findings: [ADVISORY],
    lint: f => ({ stdout: report(SPEC, f) }),
    expect: 'advise',
    messageContains: ['fix the advisory test-baseline finding this write added', '[TB-R4]', '(advisory)'],
    messageExcludes: ['blocking'],
    touched: { rel: SPEC, objectId: 'any' },
  },
  { name: 'an author edits a legacy spec without adding findings: no note', as: 'author', tool: 'Edit', file: SPEC, before: "test('TCLG-000001 · opens', async () => { if (x) await steps.click() })", content: 'await steps.click()', expect: 'allow', touched: { rel: SPEC, objectId: 'any' } },
  { name: 'a waived finding is no note', as: 'author', tool: 'Write', file: SPEC, content: 'x', findings: [{ ...BLOCKING, waived: true }], lint: f => ({ stdout: report(SPEC, f) }), expect: 'allow', touched: { rel: SPEC, objectId: 'any' } },
  { name: 'the orchestrator is an Achilles agent too', as: 'orchestrator', tool: 'Write', file: SPEC, content: 'x', findings: [BLOCKING], lint: f => ({ exitCode: 1, stdout: report(SPEC, f) }), expect: 'advise', messageContains: ['[TB-F1]'], touched: { rel: SPEC, objectId: 'any' } },
  { name: 'the main session writing a spec: no lint, no note, no record', as: 'main', tool: 'Write', file: SPEC, content: 'if (x) await steps.click()', findings: [BLOCKING], lint: f => ({ exitCode: 1, stdout: report(SPEC, f) }), expect: 'allow', touched: null, noLint: true },
  { name: 'a non-code file: no lint', as: 'author', tool: 'Write', file: 'tests/e2e/docs/app-context.md', content: 'notes', expect: 'allow', touched: null, noLint: true },
  { name: 'a code file the lint does not scope (no file in its report): no note, recorded as kind none', as: 'author', tool: 'Write', file: 'src/app.ts', content: 'export const x = 1', expect: 'allow', touched: { rel: 'src/app.ts', objectId: 'none', kind: 'none' } },
  {
    name: 'the lint cannot run (no Steps surface): one line, the write lands',
    as: 'author',
    tool: 'Write',
    file: SPEC,
    content: 'x',
    lint: () => ({ exitCode: 2, stderr: '[spec-lint] spec lint cannot run: no Steps surface for @civitas-cerebrum/element-interactions resolved\n→ Do: install the project dependencies\n' }),
    expect: 'advise',
    messageContains: ['could not check this write', 'no Steps surface', `npx achilles-spec-lint ${SPEC}`, 'test-baseline.md'],
    oneLine: true,
    touched: { rel: SPEC, objectId: 'none', kind: null },
  },
  { name: 'the lint runs past its budget (exit 3): one line', as: 'author', tool: 'Write', file: SPEC, content: 'x', lint: () => ({ exitCode: 3, stderr: '[spec-lint] the run went past its time budget\n' }), expect: 'advise', messageContains: ['time budget'], oneLine: true, touched: { rel: SPEC, objectId: 'none' } },
  { name: 'the lint child does not finish: one line', as: 'author', tool: 'Write', file: SPEC, content: 'x', lint: () => 'throw', expect: 'advise', messageContains: ['did not finish'], oneLine: true, touched: { rel: SPEC, objectId: 'none' } },
  { name: 'the lint crashes with no report: one line', as: 'author', tool: 'Write', file: SPEC, content: 'x', lint: () => ({ exitCode: 1, stdout: '' }), expect: 'advise', messageContains: ['printed no report'], oneLine: true, touched: { rel: SPEC, objectId: 'none' } },
  { name: 'a failing lint on a non-test code file still records it, with no kind', as: 'author', tool: 'Write', file: 'src/app.ts', content: 'x', lint: () => ({ exitCode: 2, stderr: '[spec-lint] boom' }), expect: 'advise', messageContains: ['boom'], oneLine: true, touched: { rel: 'src/app.ts', objectId: 'none', kind: null } },
]

/** The run registry as the adapter last wrote it, read off its state writes. */
function watchRuns(on: On) {
  let runs: AchillesRun[] = []
  on('state.set', (_, e, next) => {
    const w = e as unknown as { plugin?: string; key?: string; value?: unknown }
    if (w.plugin === 'achilles' && w.key === 'runs' && Array.isArray(w.value)) runs = w.value as AchillesRun[]
    return next(e)
  })
  return () => runs.flatMap(r => r.touched ?? [])
}

async function setup($: EngineInterface, h: Harness) {
  await $.session.start(START)
  const orchestrator = await startRun($, h)
  const author = await spawnExpert($, h, 'author', orchestrator)
  return { orchestrator, author }
}

const lintRuns = (h: Harness) => h.ran.filter(r => r.argv.some(a => a.endsWith('/bin/spec-lint.mjs')))

for (const c of CASES) {
  test(`write-time note: ${c.name}`, async ($, on) => {
    const h = engine(on)
    const touched = watchRuns(on)
    const session = mock.session(on)
    if (c.before !== undefined) h.write(`${ROOT}/${c.file}`, c.before)
    if (c.lint)
      h.procs.push(argv => {
        if (!argv.some(a => a.endsWith('/bin/spec-lint.mjs'))) return undefined
        const r = c.lint!(c.findings ?? [])
        if (r === 'throw') throw new Error('timed out after 8000 ms')
        return r
      })
    const { orchestrator, author } = await setup($, h)
    const agentId = c.as === 'author' ? author : c.as === 'orchestrator' ? orchestrator : undefined
    const before = notes(session).length
    const input = c.tool === 'Write' ? { tool: 'Write', file_path: `${ROOT}/${c.file}`, content: c.content } : { tool: 'Edit', file_path: `${ROOT}/${c.file}`, old_string: 'if (x) await steps.click()', new_string: c.content }
    const r = await $.tool.call({ ...input, ...(agentId ? { agentId } : {}) } as never)
    expect(r.deny).toBeUndefined()
    const said = notes(session).slice(before)
    if (c.expect === 'allow') expect(said).toEqual([])
    else {
      expect(said.length).toBe(1)
      for (const s of c.messageContains ?? []) expect(said[0]).toContain(s)
      for (const s of c.messageExcludes ?? []) expect(said[0]!.replace(/^achilles: /, '')).not.toContain(s)
      if (c.oneLine) {
        const [head, refs] = said[0]!.split('\n\nReferences:\n')
        expect(head).not.toContain('\n')
        expect(refs).toBe('  skills/achilles-orchestrator/references/test-baseline.md')
      }
    }
    if (c.noLint) expect(lintRuns(h)).toEqual([])
    const rows = touched()
    if (c.touched === null) expect(rows).toEqual([])
    else if (c.touched) {
      expect(rows.length).toBe(1)
      expect(rows[0]!.rel).toBe(c.touched.rel)
      expect(rows[0]!.top).toBe(c.touched.top ?? ROOT)
      expect(rows[0]!.agentId).toBe(agentId!)
      expect(rows[0]!.via).toBe('write')
      if (c.touched.objectId === 'any') expect(rows[0]!.objectId).toMatch(/^[0-9a-f]{40}$/)
      if (c.touched.objectId === 'none') expect(rows[0]!.objectId).toBeUndefined()
      if (c.touched.kind !== undefined) expect(rows[0]!.kind).toBe(c.touched.kind ?? undefined)
    }
  })
}

test('write mode gets the before text of an existing file and null for a new one, from the file\'s own work tree', async ($, on) => {
  const h = engine(on)
  const touched = watchRuns(on)
  mock.session(on)
  h.write(`${ROOT}/${SPEC}`, 'old text if (x) await steps.click()')
  const { author } = await setup($, h)
  await $.tool.call({ tool: 'Edit', file_path: `${ROOT}/${SPEC}`, old_string: 'if (x) await steps.click()', new_string: 'await steps.click()', agentId: author } as never)
  await $.tool.call({ tool: 'Write', file_path: `${ROOT}/tests/e2e/new.spec.ts`, content: 'new', agentId: author } as never)
  const [edit, write] = lintRuns(h)
  expect(JSON.parse(edit!.stdin!)).toEqual({ file: SPEC, before: 'old text if (x) await steps.click()', after: 'old text await steps.click()' })
  expect(JSON.parse(write!.stdin!)).toEqual({ file: 'tests/e2e/new.spec.ts', before: null, after: 'new' })
  expect(edit!.argv).toContain('--stdin')
  expect(edit!.argv).toContain('--budget-ms')
  expect(edit!.cwd).toBe(ROOT)
})

test('the same could-not-run reason is said once per agent and work tree; a new reason is said again', async ($, on) => {
  const h = engine(on)
  const touched = watchRuns(on)
  const session = mock.session(on)
  let code = 2
  h.procs.push(argv => (argv.some(a => a.endsWith('/bin/spec-lint.mjs')) ? { exitCode: code, stderr: `[spec-lint] reason ${code}` } : undefined))
  const { author } = await setup($, h)
  for (const f of ['a', 'b']) await $.tool.call({ tool: 'Write', file_path: `${ROOT}/tests/e2e/once-${f}.spec.ts`, content: 'x', agentId: author } as never)
  expect(notes(session, author).filter(n => n.includes('could not check')).length).toBe(1)
  code = 3
  await $.tool.call({ tool: 'Write', file_path: `${ROOT}/tests/e2e/once-c.spec.ts`, content: 'x', agentId: author } as never)
  expect(notes(session, author).filter(n => n.includes('could not check')).length).toBe(2)
})

test('a write into a worktree is recorded against that worktree, and the lint runs there', async ($, on) => {
  const h = engine(on)
  const touched = watchRuns(on)
  mock.session(on)
  const WT = `${ROOT}/.claude/worktrees/wt`
  h.write(`${WT}/tests/e2e/keep.spec.ts`, 'x')
  h.procs.push((argv, init) => {
    if (argv[0] !== 'git' || !argv.includes('--show-toplevel')) return undefined
    const cwd = init?.cwd ?? ROOT
    return cwd.startsWith(WT) ? `${WT}\n${cwd === WT ? '' : `${cwd.slice(WT.length + 1)}/`}\n` : `${ROOT}\n${cwd === ROOT ? '' : `${cwd.slice(ROOT.length + 1)}/`}\n`
  })
  const { author } = await setup($, h)
  await $.tool.call({ tool: 'Write', file_path: `${WT}/tests/e2e/fresh/a.spec.ts`, content: 'x', agentId: author } as never)
  await $.tool.call({ tool: 'Write', file_path: `${ROOT}/${SPEC}`, content: 'y', agentId: author } as never)
  const rows = touched()
  expect(rows.map(r => [r.top, r.rel])).toEqual([
    [WT, 'tests/e2e/fresh/a.spec.ts'],
    [ROOT, SPEC],
  ])
  const run = lintRuns(h)[0]!
  expect(run.cwd).toBe(WT)
  expect(JSON.parse(run.stdin!).file).toBe('tests/e2e/fresh/a.spec.ts')
})

test('a second write of the same file by the same agent keeps one row with the latest object id', async ($, on) => {
  const h = engine(on)
  const touched = watchRuns(on)
  mock.session(on)
  const { author } = await setup($, h)
  await $.tool.call({ tool: 'Write', file_path: `${ROOT}/${SPEC}`, content: 'one', agentId: author } as never)
  await $.tool.call({ tool: 'Write', file_path: `${ROOT}/${SPEC}`, content: 'two', agentId: author } as never)
  const rows = touched()
  expect(rows.length).toBe(1)
  expect(rows[0]!.objectId).toBe(fakeBlob('two'))
})

// ── shell writes: recorded, never noted, never refused ──

type ShellCase = { command: string; as?: 'author' | 'main'; records: string[] }

const SHELL: ShellCase[] = [
  { command: "sed -i 's/old/new/' tests/e2e/login.spec.ts", records: [SPEC] },
  { command: "sed -i.bak -e 's/a/b/' tests/e2e/login.spec.ts tests/e2e/other.spec.ts", records: [SPEC, 'tests/e2e/other.spec.ts'] },
  { command: "sed 's/old/new/' tests/e2e/login.spec.ts", records: [] },
  { command: "sed -i 's/old/new/' README.md", records: [] },
  { command: "sed -i '' 's/old/new/' tests/e2e/login.spec.ts", records: [SPEC] },
  { command: "sed -i 's/old/new/' src/app.ts", records: ['src/app.ts'] },
  { command: "echo 'x' > tests/e2e/login.spec.ts", records: [SPEC] },
  { command: 'cat tests/e2e/login.spec.ts > /tmp/copy.ts', records: [] },
  { command: 'git checkout HEAD~1 -- tests/e2e/login.spec.ts', records: [SPEC] },
  { command: 'git checkout main', records: [] },
  { command: "node -e \"require('fs').writeFileSync('tests/e2e/login.spec.ts', 'x')\"", records: [SPEC] },
  { command: "node -e \"console.log(require('fs').readFileSync('tests/e2e/login.spec.ts', 'utf8'))\"", records: [] },
  { command: 'cd tests/e2e && cp login.spec.ts other.spec.ts', records: ['tests/e2e/other.spec.ts'] },
  { command: "sed -i 's/old/new/' tests/e2e/login.spec.ts", as: 'main', records: [] },
]

for (const c of SHELL) {
  test(`shell write by ${c.as ?? 'an author'}: \`${c.command}\` records ${c.records.length === 0 ? 'nothing' : c.records.join(', ')}`, async ($, on) => {
    const h = engine(on)
    const touched = watchRuns(on)
    const session = mock.session(on)
    for (const f of [SPEC, 'tests/e2e/other.spec.ts', 'README.md', 'src/app.ts']) h.write(`${ROOT}/${f}`, 'x')
    const { author } = await setup($, h)
    const before = notes(session).length
    const r = await $.tool.call({ tool: 'Bash', command: c.command, ...(c.as === 'main' ? {} : { agentId: author }) } as never)
    expect(r.deny).toBeUndefined()
    expect(notes(session).slice(before)).toEqual([])
    const rows = touched()
    expect(rows.map(x => x.rel).sort()).toEqual([...c.records].sort())
    for (const row of rows) {
      expect(row.via).toBe('shell')
      expect(row.agentId).toBe(author)
      // scope is kept on the row and decided when the list is read
      expect(row.kind).toBe(row.rel.startsWith('tests/') ? 'spec' : 'none')
      if (row.kind === 'spec') expect(row.objectId).toMatch(/^[0-9a-f]{40}$/)
    }
  })
}

// ── the hand-back: blocking findings in touched tests, to the orchestrator ──

type TurnCase = { name: string; findings: unknown[]; wrote: boolean; lint?: Lint; expect: 'allow' | 'advise'; messageContains?: string[] }

const TURN: TurnCase[] = [
  { name: 'a blocking finding in a touched test is a note to the orchestrator', wrote: true, findings: [{ ...BLOCKING, touched: true }], expect: 'advise', messageContains: ['re-dispatch the author', '[TB-F1]', 'blocking under the test baseline', 'test-baseline.md#tb-f1', 'Counted in touched tests only', 'References:'] },
  { name: 'a legacy finding outside the touched tests is no note', wrote: true, findings: [{ ...BLOCKING, touched: false }], expect: 'allow' },
  { name: 'advisory findings are no note', wrote: true, findings: [{ ...ADVISORY, touched: true }], expect: 'allow' },
  { name: 'a finding in a file the expert did not write is no note', wrote: true, findings: [{ ...BLOCKING, file: 'tests/e2e/someone-else.spec.ts', touched: true }], expect: 'allow' },
  { name: 'an expert that wrote no test file: no lint at all', wrote: false, findings: [{ ...BLOCKING, touched: true }], expect: 'allow' },
  { name: 'the lint cannot run at hand-back: one line to the orchestrator', wrote: true, findings: [], lint: { exitCode: 2, stderr: '[spec-lint] the change cannot be read: no commits yet' }, expect: 'advise', messageContains: ['could not run', 'no commits yet', '--base HEAD', '\n\nReferences:\n  skills/achilles-orchestrator/references/test-baseline.md'] },
]

for (const c of TURN) {
  test(`hand-back: ${c.name}`, async ($, on) => {
    const h = engine(on)
    const touched = watchRuns(on)
    const session = mock.session(on)
    const { orchestrator, author } = await setup($, h)
    if (c.wrote) await $.tool.call({ tool: 'Write', file_path: `${ROOT}/${SPEC}`, content: 'x', agentId: author } as never)
    h.procs.push(argv => {
      if (!argv.some(a => a.endsWith('/bin/spec-lint.mjs')) || !argv.includes('--base')) return undefined
      return c.lint === 'throw' ? undefined : (c.lint ?? { exitCode: 1, stdout: report(SPEC, c.findings) })
    })
    const before = notes(session, orchestrator).length
    await $.turn.complete(ended(author, 'DONE\nTests written.'))
    const said = notes(session, orchestrator).slice(before).filter(n => !n.includes('in its return'))
    const touchedRuns = lintRuns(h).filter(r => r.argv.includes('--base'))
    if (!c.wrote) expect(touchedRuns).toEqual([])
    else {
      expect(touchedRuns.length).toBe(1)
      expect(touchedRuns[0]!.argv).toEqual(expect.arrayContaining(['--base', 'HEAD', SPEC]))
    }
    if (c.expect === 'allow') expect(said).toEqual([])
    else {
      expect(said.length).toBe(1)
      for (const s of c.messageContains ?? []) expect(said[0]).toContain(s)
    }
  })
}

test('hand-back: the author is linted against the commit its dispatch started from, so its own commits count', async ($, on) => {
  const h = engine(on)
  mock.session(on)
  const DISPATCH = 'a'.repeat(40)
  let head = DISPATCH
  h.procs.push(argv => (argv[0] === 'git' && argv.includes('HEAD') && argv.includes('--verify') ? `${head}\n` : undefined))
  const { author } = await setup($, h)
  await $.tool.call({ tool: 'Write', file_path: `${ROOT}/${SPEC}`, content: 'x', agentId: author } as never)
  head = 'b'.repeat(40) // the author committed its work
  await $.turn.complete(ended(author, 'DONE\nTests written and committed.'))
  const run = lintRuns(h).find(r => r.argv.includes('--base'))!
  expect(run.argv).toEqual(expect.arrayContaining(['--base', DISPATCH, SPEC]))
})

test('hand-back: only an author is checked; a reviewer or a reproducer that wrote a file is not', async ($, on) => {
  const h = engine(on)
  mock.session(on)
  await $.session.start(START)
  const orchestrator = await startRun($, h)
  for (const role of ['reviewer', 'reproducer']) {
    const x = await spawnExpert($, h, role, orchestrator)
    await $.tool.call({ tool: 'Write', file_path: `${ROOT}/tests/e2e/${role}.spec.ts`, content: 'x', agentId: x } as never)
    await $.turn.complete(ended(x, 'DONE\nverdict'))
  }
  expect(lintRuns(h).filter(r => r.argv.includes('--base'))).toEqual([])
})

test('the object id is read from the file on disk after the write when git can say', async ($, on) => {
  const h = engine(on)
  const touched = watchRuns(on)
  mock.session(on)
  h.procs.push(argv => (argv[0] === 'git' && argv[1] === 'hash-object' ? `${'c'.repeat(40)}\n` : undefined))
  const { author } = await setup($, h)
  await $.tool.call({ tool: 'Write', file_path: `${ROOT}/${SPEC}`, content: 'x', agentId: author } as never)
  expect(touched()[0]!.objectId).toBe('c'.repeat(40))
})

test('rows are capped per agent: one agent writing many files never evicts another agent\'s rows', () => {
  const row = (agentId: string, i: number) => ({ agentId, rel: `tests/e2e/f-${i}.spec.ts`, top: ROOT, via: 'write' as const, at: i })
  const rows = [row('orchestrator-1', 0), ...Array.from({ length: 6 }, (_, i) => row('author-2', i + 1))]
  const kept = capRows(rows, 'author-2', 4)
  expect(kept.filter(r => r.agentId === 'author-2').map(r => r.at)).toEqual([3, 4, 5, 6])
  expect(kept.some(r => r.agentId === 'orchestrator-1')).toBe(true)
  expect(capRows(rows, 'orchestrator-1', 4)).toEqual(rows)
})
