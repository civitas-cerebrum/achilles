// The write-time notes of the test baseline on pi: the Claude Code adapter's lint child
// (claude-code/hooks/spec-lint-child.ts) on a write, an edit and the shell writes the Bash judge sees.
// A write or edit of a spec or support file gets the findings it added appended to its tool result;
// every such write, and every shell write, appends one row to .achilles/runs/<run>/touched.jsonl
// ({ role, pid, rel, objectId, top, via, at }); the orchestrator's Agent tool adds a short Compliance
// paragraph to an expert's hand-back from the rows its process wrote. Notes only: nothing is refused.
import { appendFileSync, mkdirSync, readFileSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import { join } from 'node:path'
import type { EngineInterface } from 'claude-code'
import { isSpecPath } from '../claude-code/hooks/io'
import { resolve } from '../claude-code/hooks/posix'
import {
  BASELINE_REF,
  blockingInTouched,
  failNote,
  findingLines,
  lintPaths,
  lintTouched,
  lintWrite,
  lintable,
  placeInTree,
  topOf,
  writeNote,
  type LintFinding,
} from '../claude-code/hooks/spec-lint-child'

export type TouchedRow = { role: string; pid: number; rel: string; top: string; objectId?: string; via: 'write' | 'shell'; at: number }

/** What a tool call left to do once its result is in: record rows, and the notes to append. */
export type Settle = (failed: boolean) => Promise<string[]>

const testish = (rel: string) => rel.startsWith('tests/') || isSpecPath(rel)
const touchedFile = (cwd: string, run: string) => join(cwd, '.achilles', 'runs', run, 'touched.jsonl')

function append(cwd: string, run: string, row: TouchedRow) {
  try {
    mkdirSync(join(cwd, '.achilles', 'runs', run), { recursive: true })
    appendFileSync(touchedFile(cwd, run), `${JSON.stringify(row)}\n`)
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
  const lint = lintWrite($, place.top, place.rel, before, after)
  return async failed => {
    const r = await lint
    if (failed) return []
    const row = { role, pid: process.pid, rel: place.rel, top: place.top, via: 'write' as const, at: Date.now() }
    if (!r.ok) {
      if (testish(place.rel)) append(cwd, run, row)
      return [failNote(place.rel, r.why)]
    }
    const file = r.files.find(f => f.path === place.rel)
    if (!file) return []
    append(cwd, run, { ...row, objectId: file.blob })
    const note = writeNote(place.rel, r.findings.filter(f => f.file === place.rel))
    return note ? [note] : []
  }
}

/** A Bash call whose command writes `paths`: once it ran, the in-scope ones are recorded with their object ids. No note. */
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
      const r = await lintPaths($, top, rels)
      for (const rel of rels) {
        const file = r.ok ? r.files.find(f => f.path === rel) : undefined
        if (r.ok ? !file : !testish(rel)) continue
        append(cwd, run, { role, pid: process.pid, rel, top, ...(file ? { objectId: file.blob } : {}), via: 'shell', at: Date.now() })
      }
    }
    return []
  }
}

/**
 * The Compliance paragraph for an expert's hand-back: the files its process (`pid`) recorded, linted against
 * HEAD with the lint's touched-test semantics; undefined when it touched no test file.
 */
export async function complianceParagraph($: EngineInterface, cwd: string, run: string, pid: number | undefined): Promise<string | undefined> {
  if (pid === undefined) return undefined
  const rows = touchedRows(cwd, run).filter(r => r.pid === pid)
  if (rows.length === 0) return undefined
  const byTop = new Map<string, Set<string>>()
  for (const r of rows) byTop.set(r.top, (byTop.get(r.top) ?? new Set()).add(r.rel))
  const found: LintFinding[] = []
  const failed: string[] = []
  const here = (await topOf($, cwd)) ?? cwd
  for (const [top, set] of byTop) {
    const rels: string[] = []
    for (const rel of set) if (await $.fs.exists(`${top}/${rel}`).catch(() => false)) rels.push(rel)
    if (rels.length === 0) continue
    const r = await lintTouched($, top, rels)
    if (!r.ok) failed.push(`run \`npx achilles-spec-lint --base HEAD ${rels.join(' ')}\`${top === here ? '' : ` in ${top}`} before review: the check could not run (${r.why}).`)
    else for (const f of blockingInTouched(r.findings, new Set(rels))) found.push(top === here ? f : { ...f, file: `${top}/${f.file}` })
  }
  const files = [...new Set(rows.map(r => (r.top === here ? r.rel : `${r.top}/${r.rel}`)))]
  const head = `Compliance: ${files.length} test file${files.length === 1 ? '' : 's'} touched (${files.slice(0, 5).join(', ')}${files.length > 5 ? ', …' : ''}).`
  const parts = [head, ...failed]
  if (found.length > 0) parts.push(`Re-dispatch with these quoted (or have them fixed) before review: ${found.length === 1 ? 'a finding' : `${found.length} findings`} blocking under the test baseline in the touched tests (counted against HEAD):\n${findingLines(found)}\n(${BASELINE_REF})`)
  else if (failed.length === 0) parts.push('No blocking finding under the test baseline in the touched tests.')
  return parts.join('\n')
}
