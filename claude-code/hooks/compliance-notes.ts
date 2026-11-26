import type { EngineInterface, On, TurnCompleteInput } from 'claude-code'

import type { AchillesTouched } from '../types'
import { afterContent, editRun, exists, isDisabled, note, readRuns, who, type Who } from './context'
import { resolve } from './posix'
import {
  BASELINE_REF,
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
} from './spec-lint-child'

// Write-time notes of the test baseline. A Write or Edit of a code file by an Achilles agent runs the lint
// in write mode on the before and after text and notes only the findings the write added. Every such
// write is recorded in the run's `touched` list (path in the file's own git work tree, the object id of
// the file on disk afterwards, and the kind the lint gave it, so scope is decided when the list is read).
// A shell write the Bash judge sees is recorded the same way, without a note. When an author hands back,
// the files it wrote are linted against the commit its dispatch started from and the orchestrator gets
// a note of the blocking findings in touched tests. All of it advises: nothing here refuses a call, and a
// lint that cannot run is a short note.

const CONTRACT_REF = 'skills/achilles-orchestrator/references/controller-contract.md'
/** Rows kept per agent: the oldest of that agent's rows go first, never another agent's. */
const MAX_ROWS_PER_AGENT = 500

// One "could not run" note per run, agent, work tree and reason, so a missing surface does not repeat on every write.
const said = new Set<string>()
async function noteOnce($: EngineInterface, agentId: string, key: string, text: string) {
  if (said.has(key)) return
  said.add(key)
  await note($, agentId, text)
}

export async function recordTouched($: EngineInterface, runId: string, row: AchillesTouched) {
  const prior = ((await readRuns($)).find(r => r.id === runId)?.touched ?? []).find(x => x.agentId === row.agentId && x.top === row.top && x.base !== undefined)
  // The base is the HEAD of the work tree when the agent first wrote there; a later write keeps it.
  const base = prior?.base ?? (await headOf($, row.top))
  const full: AchillesTouched = { ...row, ...(base ? { base } : {}) }
  const same = (x: AchillesTouched) => x.agentId === row.agentId && x.top === row.top && x.rel === row.rel
  await editRun($, runId, r => ({ ...r, touched: capRows([...(r.touched ?? []).filter(x => !same(x)), full], row.agentId) }))
}

/** The list with `agentId`'s oldest rows dropped beyond `max`; other agents' rows are never dropped. */
export function capRows(rows: AchillesTouched[], agentId: string, max = MAX_ROWS_PER_AGENT): AchillesTouched[] {
  const mine = rows.filter(x => x.agentId === agentId)
  const drop = new Set(mine.slice(0, Math.max(0, mine.length - max)))
  return rows.filter(x => !drop.has(x))
}

type WriteCall = { tool: string; file_path: string; content?: string; old_string?: string; new_string?: string; replace_all?: boolean; agentId?: string }

export function registerComplianceNotes(on: On) {
  on('tool.call', { tool: ['Write', 'Edit'] }, async ($, e, next) => {
    if (isDisabled()) return next(e)
    const call = e as unknown as WriteCall
    if (typeof call.file_path !== 'string' || !lintable(call.file_path) || call.agentId === undefined) return next(e)
    const w = await who($, call.agentId)
    if (!w) return next(e)
    const agentId = call.agentId
    const cwd = await $.session.cwd()
    const abs = resolve(cwd, call.file_path)
    const place = await placeInTree($, abs, cwd)
    if (!place) return next(e)
    const isNew = !(await exists($, abs))
    const synth = await afterContent($, call, abs)
    if ('error' in synth) return next(e)
    // The child runs while the write lands; its verdict is read once the write is known to have gone through.
    const lint = lintWrite($, place.top, place.rel, isNew ? null : synth.before, synth.after)
    const ran = await next(e)
    if (ran.deny !== undefined || ran.isError) return ran
    try {
      const r = await lint
      const at = await $.clock.now()
      const objectId = (await objectIdOf($, place.top, place.rel)) ?? (r.ok ? r.files.find(f => f.path === place.rel)?.blob : undefined)
      const kind = r.ok ? (r.files.find(f => f.path === place.rel)?.kind ?? 'none') : undefined
      await recordTouched($, w.run.id, { agentId, rel: place.rel, top: place.top, ...(objectId ? { objectId } : {}), ...(kind ? { kind } : {}), via: 'write', at })
      if (!r.ok) {
        await noteOnce($, agentId, `${w.run.id}\0${agentId}\0${place.top}\0${r.why}`, failNote(place.rel, r.why))
        return ran
      }
      const text = kind === 'none' ? undefined : writeNote(place.rel, r.findings.filter(f => f.file === place.rel))
      if (text) await note($, agentId, text)
    } catch {
      /* a note or a row that cannot be written never touches the write */
    }
    return ran
  }).catch(($, e, next) => next(e))
}

/** Records the code files a Bash command of an Achilles agent wrote (after it ran), with the object ids they now have and the kind the lint gives them. */
export async function recordShellWrites($: EngineInterface, w: Who, agentId: string, paths: readonly string[]) {
  const cwd = await $.session.cwd()
  const byTop = new Map<string, string[]>()
  for (const abs of paths) {
    if (!lintable(abs) || !(await exists($, abs))) continue
    const place = await placeInTree($, abs, cwd)
    if (place) byTop.set(place.top, [...new Set([...(byTop.get(place.top) ?? []), place.rel])])
  }
  for (const [top, rels] of byTop) {
    const r = await lintPaths($, top, rels)
    const at = await $.clock.now()
    for (const rel of rels) {
      const file = r.ok ? r.files.find(f => f.path === rel) : undefined
      const objectId = (await objectIdOf($, top, rel)) ?? file?.blob
      const kind = r.ok ? (file?.kind ?? 'none') : undefined
      await recordTouched($, w.run.id, { agentId, rel, top, ...(objectId ? { objectId } : {}), ...(kind ? { kind } : {}), via: 'shell', at })
    }
  }
}

/**
 * An author's hand-back: the files it wrote, as recorded in the run's `touched` list, linted with the lint's
 * touched-test semantics (a finding counts only in a touched test, describe or file scope) against the
 * commit HEAD named when it was dispatched (in the session's work tree; elsewhere, when it first wrote
 * there), so work it committed itself is counted. The orchestrator gets a note of the blocking findings.
 */
export async function complianceReturn($: EngineInterface, w: Who, e: TurnCompleteInput) {
  const x = w.expert
  if (!x || e.reason !== 'answer' || w.role !== 'author') return
  const run = (await readRuns($)).find(r => r.id === w.run.id) ?? w.run
  const rows = (run.touched ?? []).filter(t => t.agentId === x.agentId && t.kind !== 'none')
  if (rows.length === 0) return
  const cwd = await $.session.cwd()
  const here = (await topOf($, cwd)) ?? cwd
  const groups = new Map<string, { top: string; base: string; rels: string[] }>()
  for (const t of rows) {
    if (!(await exists($, `${t.top}/${t.rel}`))) continue
    const base = (t.top === here && x.head) || t.base || 'HEAD'
    const key = `${t.top}\0${base}`
    const g = groups.get(key) ?? { top: t.top, base, rels: [] }
    g.rels.push(t.rel)
    groups.set(key, g)
  }
  const found: LintFinding[] = []
  for (const { top, base, rels } of groups.values()) {
    const r = await lintTouched($, top, base, rels)
    if (!r.ok) {
      await note($, w.run.agentId, touchedFailNote(base, rels, top === here ? '' : ` in ${top}`, `the ${w.role} ${x.agentId}`, r.why))
      continue
    }
    for (const f of blockingInTouched(r.findings, new Set(rels))) found.push(top === here ? f : { ...f, file: `${top}/${f.file}` })
  }
  if (found.length === 0) return
  const n = found.length
  await note(
    $,
    w.run.agentId,
    `re-dispatch the ${w.role} once with these quoted (or have them fixed) before review: ${x.agentId} handed back with ${n === 1 ? 'a finding' : `${n} findings`} blocking under the test baseline in the tests it touched.\n${findingLines(found)}\n(Counted in touched tests only: the files the ${w.role} wrote, against the commit its dispatch started from.)\n\nReferences:\n  ${BASELINE_REF}\n  ${CONTRACT_REF}`,
  )
}
