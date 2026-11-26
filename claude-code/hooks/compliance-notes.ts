import type { EngineInterface, On, TurnCompleteInput } from 'claude-code'

import type { AchillesTouched } from '../types'
import { afterContent, editRun, exists, isDisabled, isSpecPath, note, readRuns, who, type Who } from './context'
import { resolve } from './posix'
import { BASELINE_REF, blockingInTouched, failNote, findingLines, lintPaths, lintTouched, lintWrite, lintable, placeInTree, topOf, writeNote, type LintFinding } from './spec-lint-child'

// Write-time notes of the test baseline. A Write or Edit by an Achilles agent on a spec or support file
// (as the lint scopes them) runs the lint in write mode on the before and after text and notes only the
// findings the write added; the write is recorded in the run's `touched` list with the git object id it
// left, its path taken in the file's own git work tree. A shell write the Bash judge sees is recorded
// the same way, without a note. When an expert hands back, the tests it touched are linted against HEAD
// and the orchestrator gets a note of the blocking findings in them. All of it advises: nothing here
// refuses a call, and a lint that cannot run is a one-line note.

const CONTRACT_REF = 'skills/achilles-orchestrator/references/controller-contract.md'
const MAX_ROWS = 500

/** Under tests/ or named like a spec: recorded even when the lint could not say whether it is in scope. */
const testish = (rel: string) => rel.startsWith('tests/') || isSpecPath(rel)

// One "could not run" note per agent, work tree and reason, so a missing surface does not repeat on every write.
const said = new Set<string>()
async function noteOnce($: EngineInterface, agentId: string, key: string, text: string) {
  if (said.has(key)) return
  said.add(key)
  await note($, agentId, text)
}

export async function recordTouched($: EngineInterface, runId: string, row: AchillesTouched) {
  const same = (x: AchillesTouched) => x.agentId === row.agentId && x.top === row.top && x.rel === row.rel
  await editRun($, runId, r => ({ ...r, touched: [...(r.touched ?? []).filter(x => !same(x)), row].slice(-MAX_ROWS) }))
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
      if (!r.ok) {
        if (testish(place.rel)) await recordTouched($, w.run.id, { agentId, rel: place.rel, top: place.top, via: 'write', at })
        await noteOnce($, agentId, `${agentId}\0${place.top}\0${r.why}`, failNote(place.rel, r.why))
        return ran
      }
      const file = r.files.find(f => f.path === place.rel)
      if (!file) return ran
      await recordTouched($, w.run.id, { agentId, rel: place.rel, top: place.top, objectId: file.blob, via: 'write', at })
      const text = writeNote(place.rel, r.findings.filter(f => f.file === place.rel))
      if (text) await note($, agentId, text)
    } catch {
      /* a note that cannot be written never touches the write */
    }
    return ran
  }).catch(($, e, next) => next(e))
}

/** Records the in-scope files a Bash command of an Achilles agent wrote (after it ran), with the object ids they now have. */
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
      if (r.ok ? !file : !testish(rel)) continue
      await recordTouched($, w.run.id, { agentId, rel, top, ...(file ? { objectId: file.blob } : {}), via: 'shell', at })
    }
  }
}

/**
 * An expert's hand-back: the files it touched, linted against HEAD with the lint's touched-test semantics (a
 * finding counts only in a touched test, describe or file scope), and a note to the orchestrator listing the
 * blocking findings. The scope is the files this expert wrote, as recorded in the run's `touched` list; a
 * file it committed itself has no change against HEAD left and is not counted here.
 */
export async function complianceReturn($: EngineInterface, w: Who, e: TurnCompleteInput) {
  const x = w.expert
  if (!x || e.reason !== 'answer') return
  const run = (await readRuns($)).find(r => r.id === w.run.id) ?? w.run
  const rows = (run.touched ?? []).filter(t => t.agentId === x.agentId)
  if (rows.length === 0) return
  const cwd = await $.session.cwd()
  const here = (await topOf($, cwd)) ?? cwd
  const byTop = new Map<string, string[]>()
  for (const t of rows) if (await exists($, `${t.top}/${t.rel}`)) byTop.set(t.top, [...(byTop.get(t.top) ?? []), t.rel])
  const found: LintFinding[] = []
  const failed: string[] = []
  for (const [top, rels] of byTop) {
    const r = await lintTouched($, top, rels)
    if (!r.ok) {
      failed.push(`run \`npx achilles-spec-lint --base HEAD ${rels.join(' ')}\`${top === here ? '' : ` in ${top}`} before review: the test-baseline check of the files the ${w.role} ${x.agentId} touched could not run (${r.why}) (${BASELINE_REF}).`)
      continue
    }
    for (const f of blockingInTouched(r.findings, new Set(rels))) found.push(top === here ? f : { ...f, file: `${top}/${f.file}` })
  }
  for (const f of failed) await note($, w.run.agentId, f)
  if (found.length === 0) return
  const n = found.length
  await note(
    $,
    w.run.agentId,
    `re-dispatch the ${w.role} once with these quoted (or have them fixed) before review: ${x.agentId} handed back with ${n === 1 ? 'a finding' : `${n} findings`} blocking under the test baseline in the tests it touched.\n${findingLines(found)}\n(Counted in touched tests only: the files the ${w.role} wrote, against HEAD.)\n\nReferences:\n  ${BASELINE_REF}\n  ${CONTRACT_REF}`,
  )
}
