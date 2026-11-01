import type { AgentSpawnInput, EngineInterface } from 'claude-code'

import { SCHEMA_ROLES } from '../data/schema-role-map.mjs'
import type { AchillesExpert } from '../types'
import { dispatchPaths, listDir, readJson, readText, type Who } from './context'
import type { Ledger } from './ledger'

// Hook 4, dispatch discipline: an orchestrator's expert dispatch is checked against the
// controller contract and given its preamble; nothing is refused. hooks.ts calls dispatchAdvice
// before the spawn goes on, and records what it learnt on the expert.

const CONTRACT = 'skills/achilles-orchestrator/references/controller-contract.md'
const ROLE_SKILLS: Record<string, string[]> = {
  inspector: ['journey-mapping', 'evidence-capture', 'bug-discovery'],
  author: ['test-composer', 'bug-discovery', 'failure-diagnosis', 'evidence-capture', 'contract-testing', 'database-testing', 'performance-testing', 'agents-vs-agents', 'secrets-sweep', 'selector-development', 'test-data-conventions'],
  reviewer: ['review'],
  'doc-writer': ['journey-mapping', 'qa-reporting', 'bug-report'],
}
const SECTIONS_FILE = 'schemas/canonical-sections.txt'

export type Advice = { prompt: string; background?: false; notes: string[]; fields: Partial<AchillesExpert> }

const KIND: [RegExp, string][] = [
  [/failure-diagnosis/, 'diagnosis'],
  [/selector-development/, 'selector'],
  [/performance-testing/, 'perf'],
  [/\breview\b|skills\/review\//, 'review'],
  [/test-composer|bug-discovery|evidence-capture/, 'compose'],
]

async function sections($: EngineInterface): Promise<string[]> {
  const text = (await readText($, `${$.plugin.root}/${SECTIONS_FILE}`)) ?? ''
  return text.split('\n').map(l => l.trim()).filter(l => l !== '' && !l.startsWith('#'))
}

export async function dispatchAdvice($: EngineInterface, e: AgentSpawnInput, role: string, w: Who): Promise<Advice> {
  const root = await $.session.cwd()
  const notes: string[] = []
  const fields: Partial<AchillesExpert> = dispatchPaths(e.prompt)
  const briefText = fields.brief ? await readText($, `${root}/${fields.brief}`) : undefined
  const advice: Advice = { prompt: e.prompt, notes, fields }

  if (e.background) {
    advice.background = false
    notes.push(`the ${role} dispatch asked for the background; it runs in the foreground, so your turn waits for its hand-back (${CONTRACT}).`)
  }
  if (e.resume && role === 'reviewer') notes.push(`a reviewer is resumed rather than dispatched fresh; every review gets a new reviewer instance with no inherited context (${CONTRACT}).`)
  if (!fields.brief) notes.push(`the ${role} dispatch names no brief file; write it under ${w.run.dir}/briefs/<slug>.md and name it in the prompt (${CONTRACT}).`)
  else if (briefText === undefined) notes.push(`the brief ${fields.brief} does not exist; the ${role} starts without its five parts (${CONTRACT}).`)
  if (!fields.report) notes.push(`the ${role} dispatch names no report path (${w.run.dir}/reports/<slug>.md); the expert's report is its return (${CONTRACT}).`)

  const text = briefText ?? ''
  if (briefText !== undefined) {
    const skills = ROLE_SKILLS[role] ?? []
    if (skills.length > 0 && !skills.some(s => new RegExp(`(^|[^a-z-])${s}([^a-z-]|$)`).test(text)))
      notes.push(`the brief ${fields.brief} names no skill for the ${role} to load (one of ${skills.join(', ')}) (${CONTRACT} §"Briefs and reports are files").`)
    fields.kind = KIND.find(([re]) => re.test(text))?.[1] ?? 'other'
  }
  const roleSchemas = (SCHEMA_ROLES as Record<string, string[]>)[role] ?? []
  const cited = [...`${text}\n${e.prompt}`.matchAll(/([a-z0-9-]+)\.schema\.json/g)].map(m => m[1]!)
  const named = cited.find(s => roleSchemas.includes(s))
  if (named) fields.schema = named
  else if (cited.length > 0) notes.push(`the brief cites ${cited.map(c => `${c}.schema.json`).join(', ')}, which is not a return shape of the ${role} (${roleSchemas.join(', ') || 'none'}).`)

  // Concurrency: one author on shared fixtures at a time.
  const authors = w.run.experts.filter(x => x.role === 'author')
  if (role === 'author' && authors.length > 0) notes.push(`another author (${authors.map(a => a.agentId).join(', ')}) is still running in this run; at most one author edits shared fixtures at a time (${CONTRACT} §"Concurrency").`)

  // Pipeline order, read off the ledger: a phase that completed awaits its review before the next one starts.
  const ledger = await readJson<Ledger>($, `${root}/tests/e2e/docs/onboarding-status.json`)
  const phases = Array.isArray(ledger?.phases) ? ledger!.phases! : []
  const pending = phases.find(p => p.status === 'completed' && (p.reviewerVerdict ?? 'pending') === 'pending')
  if (pending && role !== 'reviewer') notes.push(`phase ${pending.id} (${pending.name}) is completed with reviewerVerdict "pending"; dispatch its review before any other expert.`)
  const capped = phases.find(p => (p.reviewerCycles ?? 0) >= 3 && p.reviewerVerdict === 'rejected')
  if (capped && role === 'reviewer') notes.push(`phase ${capped.id} already has three review rounds; the third rejection escalates to the user instead of a fourth review.`)

  // Journey-mapping cycle 1 is per section: a single dispatch that walks three sections collapses it.
  if ((ledger?.currentPhase ?? 0) === 4 || (await listDir($, `${root}/tests/e2e/docs`)).some(x => x.name === '.phase4-cycle-state.json')) {
    const state = await readJson<{ cycleStrictness?: string; cycles?: Record<string, { 'dispatched-sections'?: string[] }> }>($, `${root}/tests/e2e/docs/.phase4-cycle-state.json`)
    const cycle1 = new Set(state?.cycles?.['1']?.['dispatched-sections'] ?? [])
    const words = `${e.description}\n${text}`.replace(/\bj-[a-z0-9-]+/g, ' ').toLowerCase()
    const named = (await sections($)).filter(s => new RegExp(`(^|[^a-z0-9-])${s}([^a-z0-9-]|$)`).test(words))
    if (role === 'inspector' && named.length >= 3 && (cycle1.size === 0 || state?.cycleStrictness === 'depth'))
      notes.push(`this inspector dispatch names ${named.length} sections (${named.join(', ')}); a discovery cycle dispatches one inspector per section, in one message.`)
    if (role === 'author' && /journey-map/.test(text) && cycle1.size < 2) notes.push(`the journey-map author is dispatched before cycle 1 has two section returns (${cycle1.size} recorded).`)
  }

  const schema = fields.schema ? ` Your return opens with the handover envelope and validates against schemas/subagent-returns/${fields.schema}.schema.json.` : ''
  advice.prompt = `[achilles ${role}] Read your brief first${fields.brief ? ` (${fields.brief})` : ''}. Write your report${fields.report ? ` to ${fields.report}` : ''} before your final message, and start that message with DONE, DONE_WITH_CONCERNS, NEEDS_CONTEXT or BLOCKED.${schema}\n\n${e.prompt}`
  return advice
}
