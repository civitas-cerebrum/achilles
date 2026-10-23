import type { EngineInterface, On, TurnCompleteInput } from 'claude-code'

import { editExpert, editRun, exists, firstLine, isDisabled, note, readText, validateDoc, who, type Who } from './context'

// Hook 5, return review: when an expert's turn ends with an answer, its report (or its final
// message, when it named none) is read back against the return contract: the status word, the
// report file, the schema its brief named, the spill files it cites, the evidence an approval
// cites, the skill its brief named, and the judge loop's verdict count. Nothing is rewritten;
// the orchestrator's loop gets one note naming the gaps.

const CONTRACT = 'skills/achilles-orchestrator/references/controller-contract.md'
const STATUS = /^(DONE|DONE_WITH_CONCERNS|NEEDS_CONTEXT|BLOCKED)\b/
const SPILL = /tests\/e2e\/docs\/\.subagent-returns\/[^\s`'")\]]+\.md/g
const PATHISH = /(?:^|[\s`'"(])((?:tests|src|app|skills|schemas|scripts|docs)\/[A-Za-z0-9_.\/-]+[A-Za-z0-9_])/g
const SKILLS = ['journey-mapping', 'evidence-capture', 'bug-discovery', 'test-composer', 'failure-diagnosis', 'contract-testing', 'database-testing', 'performance-testing', 'agents-vs-agents', 'secrets-sweep', 'selector-development', 'test-data-conventions', 'review', 'qa-reporting', 'bug-report']

/** The judge verdict a reviewer's return records, anchored on its status line. */
export function judgeVerdict(text: string): 'satisfied' | 'not-satisfied' | undefined {
  const m = /(?:^|\n)\s*"?status"?\s*:\s*"?(greenlight|improvements-needed)\b/.exec(text)
  return m ? (m[1] === 'greenlight' ? 'satisfied' : 'not-satisfied') : undefined
}

/** The on-disk paths an approval cites, and the ones that do not exist. */
export function citedPaths(text: string): string[] {
  return [...new Set([...text.matchAll(PATHISH)].map(m => m[1]!.replace(/[.:,;]+$/, '')))]
}

export async function reviewReturn($: EngineInterface, w: Who, e: TurnCompleteInput) {
  const x = w.expert
  if (!x || e.reason !== 'answer') return
  const root = await $.session.cwd()
  const gaps: string[] = []
  if (!STATUS.test(firstLine(e.answer))) gaps.push('its final message does not open with DONE, DONE_WITH_CONCERNS, NEEDS_CONTEXT or BLOCKED')
  const report = x.report ? await readText($, `${root}/${x.report}`) : undefined
  if (x.report && report === undefined) gaps.push(`it wrote no report at ${x.report}`)
  const text = report ?? e.answer
  if (x.schema && text.trim() !== '') {
    const v = await validateDoc($, `subagent-returns/${x.schema}`, text)
    if ('unavailable' in v) gaps.push(`its return could not be checked against ${x.schema}.schema.json (${v.unavailable})`)
    else if (!v.ok) gaps.push(`its return does not validate against schemas/subagent-returns/${x.schema}.schema.json: ${v.parse ? `not parseable (${v.parse})` : (v.errors ?? []).join('; ')}`)
  }
  for (const spill of new Set(text.match(SPILL) ?? [])) if (!(await exists($, `${root}/${spill}`))) gaps.push(`it cites the spill file ${spill}, which does not exist`)
  if (w.role === 'reviewer' && /verdict"?\s*:\s*"?approve\b/.test(text)) {
    const cited = citedPaths(text)
    if (cited.length === 0) gaps.push('its approval cites no on-disk evidence (a path under tests/, docs/, src/ …)')
    else {
      const missing: string[] = []
      for (const p of cited) if (!(await exists($, `${root}/${p}`))) missing.push(p)
      if (missing.length > 0) gaps.push(`its approval cites paths that do not exist: ${missing.join(', ')}`)
    }
  }
  if (x.brief) {
    const brief = (await readText($, `${root}/${x.brief}`)) ?? ''
    const named = SKILLS.filter(s => new RegExp(`(^|[^a-z-])${s}([^a-z-]|$)`).test(brief))
    const loaded = x.skills ?? []
    if (named.length > 0 && !named.some(s => loaded.some(l => l === s || l.endsWith(`:${s}`)))) gaps.push(`its brief names ${named.join(', ')} and it never loaded ${named.length > 1 ? 'any of them' : 'it'}`)
  }
  if (w.role === 'reviewer') {
    const verdict = judgeVerdict(text)
    if (verdict) {
      const consecutive = verdict === 'satisfied' ? 0 : (w.run.judge?.consecutive ?? 0) + 1
      await editRun($, w.run.id, r => ({ ...r, judge: { last: verdict, consecutive } }))
      if (consecutive >= 3) gaps.push('this is the third consecutive improvements-needed verdict: escalate to the user rather than a fourth cycle')
      else if (consecutive > 0) gaps.push(`the judge loop is open (${consecutive} of 3): fix the must-fix findings and re-review with a fresh reviewer before handing back`)
    }
  }
  if (gaps.length > 0) await note($, w.run.agentId, `the ${w.role} ${x.agentId} handed back with ${gaps.length === 1 ? 'a gap' : `${gaps.length} gaps`} in its return:\n- ${gaps.join('\n- ')}\nRe-dispatch once with the gap quoted, or rule on it in the state file (${CONTRACT} §"Worker statuses").`)
}

export function registerReturnTracking(on: On) {
  // Which skills each expert loaded, for the return review's check against its brief.
  on('tool.call', { tool: 'Skill' }, async ($, e, next) => {
    if (isDisabled()) return next(e)
    const w = await who($, e.agentId)
    const skill = (e as unknown as { skill?: unknown }).skill
    if (w?.expert && typeof skill === 'string') await editExpert($, w.run.id, w.expert.agentId, x => ({ ...x, skills: [...new Set([...(x.skills ?? []), skill])] }))
    return next(e)
  })
}
