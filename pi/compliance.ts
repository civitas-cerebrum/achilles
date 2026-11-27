// The write-time notes of the test baseline on pi: the Claude Code adapter's lint child
// (claude-code/hooks/spec-lint-child.ts) on a write, an edit and the shell writes the Bash judge sees.
// A write or edit of a code file gets the findings it added appended to its tool result; every such
// write, and every shell write, appends one row to .achilles/runs/<run>/touched.jsonl
// ({ role, pid, rel, top, objectId, kind, base, via, at }; scope is decided when the rows are read). The
// orchestrator's Agent tool adds a short Compliance paragraph to an author's hand-back from the rows its
// process wrote. Every lint is bounded by a timer of its own. Notes only: nothing is refused.
import { appendFileSync, mkdirSync, readFileSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import { join } from 'node:path'
import type { EngineInterface } from 'claude-code'
import { resolve } from '../claude-code/hooks/posix'
import {
  BASELINE_REF,
  TOUCHED_WAIT_MS,
  WAIT_MS,
  blockingInTouched,
  failNote,
  findingLines,
  headOf,
  lintPaths,
  lintTouched,
  lintWrite,
  lintable,
  objectIdOf,
  placeInTree,
  topOf,
  touchedFailNote,
  writeNote,
  type LintFinding,
  type LintRun,
} from '../claude-code/hooks/spec-lint-child'

export type TouchedRow = { role: string; pid: number; rel: string; top: string; objectId?: string; kind?: string; base?: string; via: 'write' | 'shell'; at: number }

/** What a tool call left to do once its result is in: record rows, and the notes to append. */
export type Settle = (failed: boolean) => Promise<string[]>

const touchedFile = (cwd: string, run: string) => join(cwd, '.achilles', 'runs', run, 'touched.jsonl')

/** A lint run that never holds a tool result past `ms`, whatever the child (or a grandchild holding its pipes) does. */
function bounded(p: Promise<LintRun>, ms: number): Promise<LintRun> {
  let timer: ReturnType<typeof setTimeout> | undefined
  const late = new Promise<LintRun>(done => {
    timer = setTimeout(() => done({ ok: false, why: `it did not finish within ${Math.round(ms / 1000)} s` }), ms)
    timer.unref?.()
  })
  return Promise.race([p.catch((err: unknown) => ({ ok: false as const, why: `it did not finish (${err instanceof Error ? err.message : String(err)})` })), late]).finally(() => clearTimeout(timer))
}

// The HEAD of each work tree when this process first wrote there: the base its hand-back is linted against.
const bases = new Map<string, Promise<string | undefined>>()
const baseOf = ($: EngineInterface, top: string) => {
  if (!bases.has(top)) bases.set(top, headOf($, top).catch(() => undefined))
  return bases.get(top)!
}

async function record($: EngineInterface, cwd: string, run: string, row: Omit<TouchedRow, 'objectId' | 'base'>, blob: string | undefined) {
  const objectId = (await objectIdOf($, row.top, row.rel).catch(() => undefined)) ?? blob
  const base = await baseOf($, row.top)
  try {
    mkdirSync(join(cwd, '.achilles', 'runs', run), { recursive: true })
    appendFileSync(touchedFile(cwd, run), `${JSON.stringify({ ...row, ...(objectId ? { objectId } : {}), ...(base ? { base } : {}) })}\n`)
  } catch {
    /* a row that cannot be written never touches the call */
  }
}

/** The rows of a run's touched.jsonl, the unreadable ones skipped. */
export function touchedRows(cwd: string, run: string): TouchedRow[] {
  let text = ''
  try {
    text = readFileSync(touchedFile(cwd, run), 'utf8')
  } catch {
    return []
  }
  const out: TouchedRow[] = []
  for (const line of text.split('\n')) {
    try {
      if (line.trim() !== '') out.push(JSON.parse(line) as TouchedRow)
    } catch {
      /* skip */
    }
  }
  return out
}

/** A write or edit of `abs` that will leave `after`: the before text is read now and the lint started; the settle records the row and returns the note. */
export async function writeRecorder($: EngineInterface, cwd: string, run: string, role: string, abs: string, after: string): Promise<Settle | undefined> {
  if (!lintable(abs)) return undefined
  const place = await placeInTree($, abs, cwd)
  if (!place) return undefined
  const before = await readFile(abs, 'utf8').catch(() => null)
  void baseOf($, place.top)
  const lint = bounded(lintWrite($, place.top, place.rel, before, after), WAIT_MS + 500)
  return async failed => {
    if (failed) return []
    const r = await lint
    const file = r.ok ? r.files.find(f => f.path === place.rel) : undefined
    const kind = r.ok ? (file?.kind ?? 'none') : undefined
    await record($, cwd, run, { role, pid: process.pid, rel: place.rel, top: place.top, ...(kind ? { kind } : {}), via: 'write', at: Date.now() }, file?.blob)
    if (!r.ok) return [failNote(place.rel, r.why)]
    const note = kind === 'none' ? undefined : writeNote(place.rel, r.findings.filter(f => f.file === place.rel))
    return note ? [note] : []
  }
}

/** A Bash call whose command writes `paths`: once it ran, the code files are recorded with their object ids and kinds. No note. */
export function shellRecorder($: EngineInterface, cwd: string, run: string, role: string, paths: readonly string[]): Settle | undefined {
  const code = paths.filter(lintable)
  if (code.length === 0) return undefined
  return async failed => {
    if (failed) return []
    const byTop = new Map<string, string[]>()
    for (const p of code) {
      const abs = resolve(cwd, p)
      if (!(await $.fs.exists(abs).catch(() => false))) continue
      const place = await placeInTree($, abs, cwd)
      if (place) byTop.set(place.top, [...new Set([...(byTop.get(place.top) ?? []), place.rel])])
    }
    for (const [top, rels] of byTop) {
      const r = await bounded(lintPaths($, top, rels), WAIT_MS + 500)
      for (const rel of rels) {
        const file = r.ok ? r.files.find(f => f.path === rel) : undefined
        const kind = r.ok ? (file?.kind ?? 'none') : undefined
        await record($, cwd, run, { role, pid: process.pid, rel, top, ...(kind ? { kind } : {}), via: 'shell', at: Date.now() }, file?.blob)
      }
    }
    return []
  }
}

/**
 * The Compliance paragraph for an author's hand-back: the files its process (`pid`) recorded, linted with the
 * lint's touched-test semantics against the commit HEAD named at dispatch (`dispatchHead`, in the session's
 * work tree; elsewhere, when the process first wrote there); undefined when it touched no file in scope.
 */
export async function complianceParagraph($: EngineInterface, cwd: string, run: string, pid: number | undefined, dispatchHead?: string): Promise<string | undefined> {
  if (pid === undefined) return undefined
  const rows = touchedRows(cwd, run).filter(r => r.pid === pid && r.kind !== 'none')
  if (rows.length === 0) return undefined
  const here = (await topOf($, cwd)) ?? cwd
  const groups = new Map<string, { top: string; base: string; rels: Set<string> }>()
  for (const r of rows) {
    const base = (r.top === here && dispatchHead) || r.base || 'HEAD'
    const key = `${r.top}\0${base}`
    const g = groups.get(key) ?? { top: r.top, base, rels: new Set<string>() }
    g.rels.add(r.rel)
    groups.set(key, g)
  }
  const found: LintFinding[] = []
  const failed: string[] = []
  for (const { top, base, rels: set } of groups.values()) {
    const rels: string[] = []
    for (const rel of set) if (await $.fs.exists(`${top}/${rel}`).catch(() => false)) rels.push(rel)
    if (rels.length === 0) continue
    const r = await bounded(lintTouched($, top, base, rels), TOUCHED_WAIT_MS + 500)
    if (!r.ok) failed.push(touchedFailNote(base, rels, top === here ? '' : ` in ${top}`, 'this author', r.why).replace(/\n\nReferences:[\s\S]*$/, ''))
    else for (const f of blockingInTouched(r.findings, new Set(rels))) found.push(top === here ? f : { ...f, file: `${top}/${f.file}` })
  }
  const files = [...new Set(rows.map(r => (r.top === here ? r.rel : `${r.top}/${r.rel}`)))]
  const touched = `${files.length} file${files.length === 1 ? '' : 's'} touched (${files.slice(0, 5).join(', ')}${files.length > 5 ? ', …' : ''})`
  const refs = `\n\nReferences:\n  ${BASELINE_REF}`
  if (found.length > 0)
    return `Compliance: re-dispatch the author with these quoted (or have them fixed) before review: ${found.length === 1 ? 'a finding' : `${found.length} findings`} blocking under the test baseline in the tests it touched (${touched}; counted against the commit its dispatch started from).\n${findingLines(found)}${failed.length ? `\n${failed.join('\n')}` : ''}${refs}`
  if (failed.length > 0) return `Compliance: ${failed.join('\n')} (${touched})${refs}`
  return `Compliance: nothing to fix; no finding blocking under the test baseline in the tests the author touched (${touched}).`
}
