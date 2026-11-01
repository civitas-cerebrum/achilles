import type { EngineInterface, On } from 'claude-code'

import { afterContent, exists, hashText, isDisabled, listDir, note, placeFile, readLedgerHashes, readText, validateDoc, who, writeLedgerHash } from './context'

// Hook 2, the pipeline ledger model: a Write or Edit of a pipeline ledger or progress file is
// checked as a state transition, and every finding is a note to the writing loop; nothing is
// refused (a malformed ledger is recoverable and visible). Separation of duties is the agents'
// write scope. The last ledger content written through the tools is hashed in $.state, so a
// change made out of band (a shell, an editor) is named at the next write.

export const ONBOARDING = 'tests/e2e/docs/onboarding-status.json'
export const PERF = 'tests/perf/docs/perf-onboarding-status.json'
const CYCLE_STATE = 'tests/e2e/docs/.phase4-cycle-state.json'
const COVERAGE_STATE = 'tests/e2e/docs/coverage-expansion-state.json'
const STATE_REF = 'skills/achilles-orchestrator/references/state-files.md'

export type Phase = {
  id?: number
  name?: string
  status?: string
  reviewerVerdict?: string | null
  reviewerCycles?: number
  handoverEnvelope?: unknown
  subStages?: { id?: string; status?: string; reviewerVerdict?: string | null; reviewerCycles?: number }[]
}
export type Ledger = { currentPhase?: number; currentSubStage?: string | null; status?: string; runMode?: string; modeAuthorizer?: string; phases?: Phase[]; approvedDeviations?: { phase?: number; authorizer?: string }[] }

const phasesOf = (l: Ledger | undefined): Phase[] => (Array.isArray(l?.phases) ? l!.phases!.filter(p => p !== null && typeof p === 'object') : [])
const phaseOf = (l: Ledger | undefined, id: number) => phasesOf(l).find(p => p.id === id)
const authorised = (l: Ledger, id: number) => (Array.isArray(l.approvedDeviations) ? l.approvedDeviations : []).some(d => d.phase === id && typeof d.authorizer === 'string' && d.authorizer !== '')

/** The transition findings of one ledger write, `prior` absent on the first write. */
export function transitionFindings(prior: Ledger | undefined, next: Ledger): string[] {
  const out: string[] = []
  const from = prior?.currentPhase ?? 0
  const to = next.currentPhase ?? 0
  if (prior && to > from + 1) {
    for (let id = from + 1; id < to; id++) {
      const st = phaseOf(next, id)?.status ?? 'pending'
      if (st === 'pending' || st === 'in-progress')
        out.push(`Out-of-order ledger transition: currentPhase jumped ${from} → ${to} while phase ${id} is still "${st}". Complete phase ${id}, or mark it skipped with an approvedDeviations[] entry carrying the authorizer's verbatim quote.`)
    }
  }
  for (const p of phasesOf(next)) {
    if (p.reviewerVerdict === 'approved' && (p.handoverEnvelope === null || p.handoverEnvelope === undefined))
      out.push(`Phase ${p.id} has reviewerVerdict "approved" but handoverEnvelope is null; record the closing expert's envelope in the same write.`)
    const before = phaseOf(prior, p.id ?? -1)
    const pv = before?.reviewerVerdict ?? undefined
    const nv = p.reviewerVerdict ?? undefined
    if (nv === undefined) continue
    if (p.status === 'skipped' && authorised(next, p.id ?? -1)) continue
    const pc = before?.reviewerCycles ?? 0
    const nc = p.reviewerCycles ?? 0
    if (prior && nv !== pv && nc !== pc + 1)
      out.push(`Phase ${p.id} reviewerVerdict changed ("${pv ?? '<unset>'}" → "${nv}") without incrementing reviewerCycles by exactly 1 (was ${pc}, now ${nc}); each verdict is one review round and the 3-round cap keys on the counter.`)
    if (nc === 3 && nv === 'rejected')
      out.push(`Phase ${p.id} is "rejected" at reviewerCycles 3: the third rejection escalates (reviewerVerdict "escalate" or "escalated-to-user", the same verdict, and the pipeline status "blocked").`)
  }
  if (next.runMode !== undefined) {
    const auth = next.modeAuthorizer ?? ''
    if (!prior && auth === '') out.push(`runMode "${next.runMode}" is set without a modeAuthorizer field quoting the user's choice.`)
    else if (prior && prior.runMode !== next.runMode && (auth === '' || auth === prior.modeAuthorizer)) out.push(`runMode changed ("${prior.runMode ?? '<unset>'}" → "${next.runMode}") without a fresh modeAuthorizer quote in the same write.`)
    else if (prior && prior.modeAuthorizer && auth === '') out.push('modeAuthorizer cleared while runMode remains set; the authorisation is the audit trail of the mode.')
  }
  return out
}

/** The phases this write flips to completed. */
export const newlyCompleted = (prior: Ledger | undefined, next: Ledger) =>
  phasesOf(next).filter(p => p.status === 'completed' && phaseOf(prior, p.id ?? -1)?.status !== 'completed').map(p => p.id ?? 0)

type Files = { root: string; read: (rel: string) => Promise<string | undefined>; has: (rel: string) => Promise<boolean>; list: (rel: string) => Promise<string[]> }

const firstLineOf = (s: string | undefined) => (s ?? '').split('\n')[0]!.trim()
const roster = (map: string | undefined) => [...(map ?? '').matchAll(/^###?#? (j-[a-z0-9-]+)/gm)].map(m => m[1]!)
const STRUCTURAL = /^(blocked-on-app-bug:|test-data-prerequisite:|user-authorised:)/

type Cycle = { kind?: string; 'dispatched-sections'?: string[]; 'returned-sections'?: string[] }
type Deferral = { journey?: string; reason?: string; authorizer?: string }
type Pass = { 'dispatched-journeys'?: string[]; 'returned-journeys'?: string[]; dispatches?: { journey?: string }[]; deferredJourneys?: Deferral[] }
// A pass record is keyed "pass-<N>" (state-files.md) or the bare "<N>"; an empty object is no record.
const passOf = (passes: Record<string, Pass>, n: number): Pass | undefined => {
  const p = passes[`pass-${n}`] ?? passes[String(n)]
  return p !== null && typeof p === 'object' && Object.keys(p).length > 0 ? p : undefined
}

/** What a completed onboarding phase must have on disk. */
export async function onboardingDeliverables(id: number, f: Files): Promise<string[]> {
  const out: string[] = []
  if (id === 4) {
    const map = await f.read('tests/e2e/docs/journey-map.md')
    if (map === undefined) return ['Phase 4 completed but tests/e2e/docs/journey-map.md does not exist.']
    if (firstLineOf(map) !== '<!-- journey-mapping:generated -->') out.push('Phase 4 completed but journey-map.md is missing the line-1 sentinel `<!-- journey-mapping:generated -->`.')
    const state = await f.read(CYCLE_STATE)
    if (state === undefined) return [...out, 'Phase 4 completed but tests/e2e/docs/.phase4-cycle-state.json does not exist.']
    let cycles: Record<string, Cycle> = {}
    try {
      cycles = (JSON.parse(state) as { cycles?: Record<string, Cycle> }).cycles ?? {}
    } catch {
      return [...out, '.phase4-cycle-state.json is not JSON.']
    }
    if (!cycles['1'] || !cycles['2']) out.push('Phase 4 completed but the cycle state is missing cycle-1 and/or cycle-2 (discovery and the edge probe).')
    for (const [n, c] of Object.entries(cycles)) {
      const d = new Set(c['dispatched-sections'] ?? [])
      const r = new Set(c['returned-sections'] ?? [])
      if ([...d].some(x => !r.has(x))) out.push(`Cycle ${n}: dispatched(${d.size}) ≠ returned(${r.size}). Some section agents did not return.`)
    }
  } else if (id === 5) {
    const state = await f.read(COVERAGE_STATE)
    if (state === undefined) return ['Phase 5 completed but tests/e2e/docs/coverage-expansion-state.json does not exist.']
    let doc: { runMode?: string; passes?: Record<string, Pass> & { cleanup?: unknown }; cleanup?: unknown; deferredJourneys?: Deferral[] } = {}
    try {
      doc = JSON.parse(state)
    } catch {
      return ['coverage-expansion-state.json is not JSON.']
    }
    const passes = doc.passes ?? {}
    const p1 = passOf(passes, 1)
    if (!p1) return ['Phase 5 completed but the coverage state has no pass-1 record.']
    // Breadth runs one pass; standard and depth run five plus the cross-pass cleanup.
    const fullRun = doc.runMode === 'standard' || doc.runMode === 'depth'
    if (fullRun && ([2, 3, 4, 5].some(n => !passOf(passes, n)) || (doc.cleanup ?? passes.cleanup) === undefined))
      out.push('Phase 5 completed without a full five-pass run (passes 1-5 and the cross-pass cleanup recorded).')
    const journeys = roster(await f.read('tests/e2e/docs/journey-map.md'))
    const deferred = [...(p1.deferredJourneys ?? []), ...(doc.deferredJourneys ?? [])]
    if (journeys.length > 0) {
      const dispatched = [...(p1['dispatched-journeys'] ?? []), ...(p1.dispatches ?? []).map(d => d.journey ?? '')]
      const covered = new Set([...dispatched, ...deferred.map(d => d.journey ?? '')])
      const missing = journeys.filter(j => !covered.has(j))
      if (missing.length > 0) out.push(`Phase 5 completed with ${missing.length} of ${journeys.length} journeys silently missing from pass 1 (${missing.slice(0, 5).join(', ')}); dispatch them or defer them with a reason.`)
    }
    for (const d of deferred)
      if (!STRUCTURAL.test(d.reason ?? '') && !(typeof d.authorizer === 'string' && d.authorizer !== ''))
        out.push(`Deferral of ${d.journey} cites "${d.reason}", which is neither a structural reason prefix (blocked-on-app-bug:, test-data-prerequisite:, user-authorised:) nor carries an authorizer quote.`)
  } else if (id === 6) {
    const findings = await f.read('tests/e2e/docs/adversarial-findings.md')
    if (findings === undefined) return ['Phase 6 completed but tests/e2e/docs/adversarial-findings.md does not exist.']
    if (!/^### j-/m.test(findings)) out.push('Phase 6 completed but the findings ledger has 0 per-journey section blocks (### j-<slug>).')
  } else if (id === 7) {
    if (!(await f.has('.env.example'))) out.push('Phase 7 completed but .env.example does not exist.')
  } else if (id === 8) {
    for (const ext of ['html', 'pdf']) if (!(await f.has(`qa-summary-deck.${ext}`))) out.push(`Phase 8 completed but qa-summary-deck.${ext} does not exist.`)
  }
  return out
}

/** What a completed performance-pipeline phase must have on disk. */
export async function perfDeliverables(id: number, f: Files): Promise<string[]> {
  const some = async (dir: string, ext: string) => (await f.list(dir)).some(n => n.endsWith(ext))
  const sentinel = async (rel: string, line: string, phase: number) => {
    const text = await f.read(rel)
    if (text === undefined) return [`Phase ${phase} completed but ${rel} does not exist.`]
    return firstLineOf(text) === line ? [] : [`${rel} is missing the line-1 sentinel \`${line}\`.`]
  }
  switch (id) {
    case 1: {
      const out: string[] = []
      if (!(await f.has('tests/perf/perf-onboarding.config.json'))) out.push('Phase 1 completed but tests/perf/perf-onboarding.config.json does not exist.')
      if ((await f.list('tests/perf/lib')).length === 0) out.push('Phase 1 completed but tests/perf/lib/ does not exist or is empty.')
      return out
    }
    case 2:
      return (await f.has('tests/perf/docs/readiness.md')) ? [] : ['Phase 2 completed but tests/perf/docs/readiness.md does not exist.']
    case 3:
      return [...(await sentinel('tests/perf/docs/scenario-model.md', '<!-- perf-onboarding:scenario-model -->', 3)), ...((await some('tests/perf/scenarios', '.js')) ? [] : ['Phase 3 completed but no *.js scenario files are under tests/perf/scenarios/.'])]
    case 4:
      return (await some('tests/perf/baselines', '.json')) ? [] : ['Phase 4 completed but no *.json baseline files are under tests/perf/baselines/.']
    case 5:
      return (await some('tests/perf/results', '.json')) ? [] : ['Phase 5 completed but no *.json result files are under tests/perf/results/.']
    case 6: {
      const text = await f.read('tests/perf/docs/threshold-verdict.json')
      if (text === undefined) return ['Phase 6 completed but tests/perf/docs/threshold-verdict.json does not exist.']
      try {
        const b = (JSON.parse(text) as { deliberateBreach?: unknown }).deliberateBreach
        return Array.isArray(b) && b.length > 0 ? [] : ['threshold-verdict.json has no deliberateBreach entry; the threshold gate proves itself with at least one.']
      } catch {
        return ['threshold-verdict.json is not JSON.']
      }
    }
    case 7:
      return sentinel('tests/perf/docs/perf-report.md', '<!-- perf-onboarding:report -->', 7)
    default:
      return []
  }
}

/** Progress files only grow: a cycle's or pass's dispatched and returned rosters never lose an entry. */
export function monotonicFindings(rel: string, prior: unknown, next: unknown): string[] {
  const [group, dispatched, returned] = rel.endsWith('.phase4-cycle-state.json') ? ['cycles', 'dispatched-sections', 'returned-sections'] : ['passes', 'dispatched-journeys', 'returned-journeys']
  const of = (doc: unknown) => ((doc as Record<string, unknown> | undefined)?.[group] ?? {}) as Record<string, Record<string, string[] | undefined>>
  const out: string[] = []
  const nextGroups = of(next)
  if (prior === undefined) {
    for (const [n, g] of Object.entries(nextGroups)) if ((g[returned] ?? []).length > 0) out.push(`The first write of this file already records returns for ${group === 'cycles' ? 'cycle' : 'pass'} ${n}; returns predate their dispatch.`)
    return out
  }
  for (const [n, g] of Object.entries(of(prior))) {
    for (const key of [dispatched, returned]) {
      const lost = (g[key] ?? []).filter(x => !(nextGroups[n]?.[key] ?? []).includes(x))
      if (lost.length > 0) out.push(`This write shrinks or rewrites ${group === 'cycles' ? 'cycle' : 'pass'} ${n}'s ${key} (drops ${lost.join(', ')}); the progress record is append-only.`)
    }
  }
  return out
}

const parse = (text: string | undefined): unknown => {
  if (text === undefined) return undefined
  try {
    return JSON.parse(text)
  } catch {
    return undefined
  }
}

export function registerLedger(on: On) {
  on('tool.call', { tool: ['Write', 'Edit'] }, async ($, e, next) => {
    if (isDisabled()) return next(e)
    const w = await who($, e.agentId)
    if (!w) return next(e)
    const root = await $.session.cwd()
    const { abs, rel } = placeFile(root, e.file_path)
    const isLedger = rel === ONBOARDING || rel === PERF
    const isProgress = rel === CYCLE_STATE || rel === COVERAGE_STATE
    if (!isLedger && !isProgress) return next(e)
    const findings: string[] = []
    const synth = await afterContent($, e, abs)
    const diskText = await readText($, abs)
    if (isLedger) {
      const held = (await readLedgerHashes($))[rel]
      if (held !== undefined && diskText === undefined) findings.push(`${rel} was deleted out of band since its last write through the tools; a reset of a pipeline ledger is an operator decision.`)
      else if (held !== undefined && hashText(diskText ?? '') !== held) findings.push(`${rel} changed out of band since its last write through the tools (a shell or an editor); this write builds on the changed content.`)
    }
    if ('error' in synth) findings.push(`the ${e.tool} of ${rel} could not be applied to the file on disk (${synth.error}), so the ledger checks did not run on it.`)
    else if (isLedger) {
      const nextDoc = parse(synth.after) as Ledger | undefined
      if (nextDoc === undefined || typeof nextDoc !== 'object') findings.push(`${rel} would not be parseable JSON after this write.`)
      else {
        const verdict = await validateDoc($, rel === PERF ? 'perf-onboarding-status' : 'onboarding-status', synth.after)
        if ('unavailable' in verdict) findings.push(`the ledger schema could not be checked (${verdict.unavailable}).`)
        else if (!verdict.ok) findings.push(`${rel} fails schema validation: ${(verdict.errors ?? [verdict.parse ?? '']).join('; ')}.`)
        const priorDoc = parse(diskText) as Ledger | undefined
        findings.push(...transitionFindings(priorDoc, nextDoc))
        const files: Files = {
          root,
          read: r => readText($, `${root}/${r}`),
          has: r => exists($, `${root}/${r}`),
          list: async r => (await listDir($, `${root}/${r}`)).map(x => x.name),
        }
        for (const id of newlyCompleted(priorDoc, nextDoc)) findings.push(...(await (rel === PERF ? perfDeliverables(id, files) : onboardingDeliverables(id, files))))
      }
    } else {
      const nextDoc = parse(synth.after)
      if (nextDoc === undefined) findings.push(`${rel} would not be parseable JSON after this write.`)
      else findings.push(...monotonicFindings(rel, parse(diskText), nextDoc))
    }
    const ran = await next(e)
    if (isLedger && ran.deny === undefined && !('error' in synth)) await writeLedgerHash($, rel, hashText(synth.after))
    if (findings.length > 0) await note($, e.agentId, `the ${rel} write landed with ${findings.length === 1 ? 'one problem' : `${findings.length} problems`} to fix in a follow-up write:\n- ${findings.join('\n- ')}\n(${STATE_REF})`)
    return ran
  })
}

