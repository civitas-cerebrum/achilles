import type { EngineInterface, On } from 'claude-code'

import type { AchillesRun, AchillesStage } from '../types'
import { ENDED, currentStage, editRun, expertLabel, firstLine, isDisabled, placeFile, readJson, readRuns, slugOf, stageLine, who, type Who } from './context'
import { ONBOARDING, PERF, type Ledger } from './ledger'

// Progress, part of hook 8 (reporting): after the fact, never refusing. A run's stages are read
// from the pipeline ledger it writes (the onboarding or perf phases), else from the `plan` in its
// resume.json; with them the experts at work and the ones that handed back. The adapter holds
// this on the run in $.state (status line, pane) and writes it to .achilles/runs/<run>/progress.json
// for anyone who asks. When a write moves a stage to an end state while stages remain, the main
// session gets a short progress prompt to relay; the run's end is the hand-back's to tell.

const KEEP_FINISHED = 8

const PROGRESS_LEAD = (id: string) =>
  `Achilles progress (run ${id}). Tell the person in a line or two. This is not a hand-back: take no other action and do not re-delegate.`

/** A pipeline ledger's phases as stages, in ledger order. */
export function stagesOf(ledger: Ledger | undefined): AchillesStage[] | undefined {
  const phases = Array.isArray(ledger?.phases) ? ledger!.phases!.filter(p => p !== null && typeof p === 'object') : []
  if (phases.length === 0) return undefined
  return phases.map((p, i) => ({ name: p.name ?? `phase ${p.id ?? i + 1}`, status: typeof p.status === 'string' ? p.status : 'pending' }))
}

/** resume.json's `plan`: stage names, or `{ stage | name, status }` entries. */
export function planOf(plan: unknown): AchillesStage[] | undefined {
  if (!Array.isArray(plan)) return undefined
  const stages = plan.flatMap((s): AchillesStage[] => {
    if (typeof s === 'string' && s !== '') return [{ name: s, status: 'pending' }]
    if (s === null || typeof s !== 'object') return []
    const { stage, name, status } = s as Record<string, unknown>
    const label = typeof stage === 'string' ? stage : typeof name === 'string' ? name : ''
    return label === '' ? [] : [{ name: label, status: typeof status === 'string' ? status : 'pending' }]
  })
  return stages.length > 0 ? stages : undefined
}

/** The stages a refresh moved into an end state; none on the first sighting, so a resumed run does not replay its history. */
export function settled(prior: AchillesStage[] | undefined, next: AchillesStage[]): AchillesStage[] {
  if (!prior) return []
  return next.filter(s => ENDED.has(s.status) && prior.find(p => p.name === s.name)?.status !== s.status)
}

const iso = (ms: number | undefined) => (ms === undefined ? null : new Date(ms).toISOString())

export function progressDoc(run: AchillesRun, now: number, ended?: string) {
  const stages = run.stages ?? []
  const cur = ended ? undefined : currentStage(stages)
  return {
    run: run.id,
    task: run.task,
    updatedAt: iso(now),
    startedAt: iso(run.startedAt),
    ...(ended ? { ended } : {}),
    position: stageLine(run) ?? null,
    step: run.step ?? null,
    ledger: run.ledger ?? null,
    stages,
    current: cur?.name ?? null,
    done: stages.filter(s => ENDED.has(s.status)).map(s => (s.status === 'completed' ? s.name : `${s.name} (${s.status})`)),
    remaining: stages.filter(s => !ENDED.has(s.status) && s !== cur).map(s => s.name),
    experts: run.experts.map(x => ({ role: x.role, slug: slugOf(x.brief ?? x.report) ?? null, agentId: x.agentId, brief: x.brief ?? null, report: x.report ?? null, since: iso(x.since) })),
    finished: (run.finished ?? []).map(f => ({ ...f, at: iso(f.at) })),
    dispatched: run.dispatched ?? {},
  }
}

export function progressPrompt(run: AchillesRun, moved: AchillesStage[]): string {
  const stages = run.stages ?? []
  const pos = (s: AchillesStage) => `${stages.findIndex(x => x.name === s.name) + 1}/${stages.length}`
  const cur = currentStage(stages)
  const rest = stages.filter(s => !ENDED.has(s.status) && s !== cur)
  const body = [
    `Task: ${run.task}`,
    ...moved.map(s => `${s.status === 'completed' ? 'Completed' : `Ended ${s.status}`}: stage ${pos(s)} ${s.name}.`),
    cur ? `Now: stage ${pos(cur)} ${cur.name}${run.experts.length > 0 ? `; at work: ${run.experts.map(expertLabel).join(', ')}` : ''}.` : '',
    rest.length > 0 ? `To go: ${rest.map(s => s.name).join(', ')}.` : '',
    `Progress file: ${run.dir}/progress.json`,
  ].filter(Boolean)
  return `${PROGRESS_LEAD(run.id)}\n\n${body.join('\n')}`
}

async function writeProgress($: EngineInterface, run: AchillesRun, ended?: string) {
  const root = await $.session.cwd()
  const doc = progressDoc(run, await $.clock.now(), ended)
  await $.fs.write(`${root}/${run.dir}/progress.json`, `${JSON.stringify(doc, null, 2)}\n`).catch(() => undefined)
}

/** Re-reads the run's stages from disk, writes progress.json, and tells the main session about stages that ended. */
export async function refreshProgress($: EngineInterface, runId: string, ledger?: string) {
  const root = await $.session.cwd()
  const held = (await readRuns($)).find(r => r.id === runId)
  if (!held) return
  const resume = await readJson<{ step?: unknown; plan?: unknown; 'state-file'?: unknown }>($, `${root}/${held.dir}/resume.json`)
  const named = resume?.['state-file']
  const source = ledger ?? held.ledger ?? (named === ONBOARDING || named === PERF ? named : undefined)
  const stages = (source ? stagesOf(await readJson<Ledger>($, `${root}/${source}`)) : undefined) ?? planOf(resume?.plan)
  const step = typeof resume?.step === 'string' && resume.step !== '' ? resume.step : undefined
  let moved: AchillesStage[] = []
  const runs = await editRun($, runId, r => {
    moved = stages ? settled(r.stages, stages) : []
    return { ...r, ...(source ? { ledger: source } : {}), ...(stages ? { stages } : {}), ...(step ? { step } : {}) }
  })
  const run = runs.find(r => r.id === runId)
  if (!run) return
  await writeProgress($, run)
  if (moved.length === 0 || currentStage(run.stages) === undefined) return
  // A submission waits for the main session to go idle, which a tool.call hook holding its own
  // turn may not do; a timer sends it as a dispatch of its own.
  const text = progressPrompt(run, moved)
  $.clock.after(0, () => void $.prompt.submit({ text }).catch(() => undefined))
}

/** An expert's turn end (hooks.ts): it joins the finished list with the status word it opened with. */
export async function recordFinished($: EngineInterface, w: Who, e: { reason: string; answer: string }) {
  if (!w.expert) return
  const word = e.reason === 'answer' ? (/^(DONE_WITH_CONCERNS|DONE|NEEDS_CONTEXT|BLOCKED)\b/.exec(firstLine(e.answer))?.[1] ?? 'no status word') : e.reason
  const done = { role: w.expert.role, ...(slugOf(w.expert.brief ?? w.expert.report) ? { slug: slugOf(w.expert.brief ?? w.expert.report)! } : {}), status: word, at: await $.clock.now() }
  await editRun($, w.run.id, r => ({ ...r, finished: [...(r.finished ?? []), done].slice(-KEEP_FINISHED) }))
  await refreshProgress($, w.run.id)
}

/** The hand-back (hooks.ts): progress.json keeps the run's last state and its status word. */
export async function closeProgress($: EngineInterface, run: AchillesRun, status: string) {
  await writeProgress($, run, status)
}

export function registerProgress(on: On) {
  // A write of the run's resume.json or of a pipeline ledger by one of its loops moves its stages.
  on('tool.call', { tool: ['Write', 'Edit'] }, async ($, e, next) => {
    if (isDisabled()) return next(e)
    const w = await who($, e.agentId)
    if (!w) return next(e)
    const { rel } = placeFile(await $.session.cwd(), e.file_path)
    const isLedger = rel === ONBOARDING || rel === PERF
    if (!isLedger && rel !== `${w.run.dir}/resume.json`) return next(e)
    const ran = await next(e)
    if (ran.deny === undefined) await refreshProgress($, w.run.id, isLedger ? rel : undefined)
    return ran
  })
}
