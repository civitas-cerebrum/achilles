import type { EngineInterface, On, TurnCompleteInput } from 'claude-code'

import {
  checkoutRoot,
  editRun,
  findDirs,
  hashText,
  isDisabled,
  listDir,
  isSpecPath,
  newestSpec,
  note,
  readJson,
  readReceiptHashes,
  readText,
  run,
  walk,
  who,
  writeReceiptHash,
  type Who,
} from './context'
import { basename } from './posix'
import { consoleFinding, harFindings } from './secrets'
import { commands, nestedCommand } from './shell'

// Hook 3, sign-off: a ticket transition to a completed state and a non-draft `gh pr create|ready`
// are the moments a verdict leaves the run. The adapter records the reviewers' sign-off receipt
// itself (from their reports, keyed on their agent id, so no author writes it) and, at sign-off,
// advises when the receipt or the evidence bundle for that ticket is missing, incomplete or older
// than the newest spec. The refusals: a bundle whose HAR or console log still holds a live
// credential, on every sign-off surface, because a published credential cannot be unpublished; and
// a defect that reaches the tracker without an independent confirmation. A reproducer's verdict (the
// standard defect evidence, its defect-repro JSON block) is recorded by the adapter at the
// reproducer's turn end; a bug or rework filing must cite a defect id recorded as `bug`, and a
// sign-off is refused while a sentinel of the ticket, or a verdict comment reporting defects, has
// no recorded confirmation. The main session is never bound, so a user's own decision still files.

const REF = 'skills/achilles-orchestrator/workflows/verify-change.md'
const RECEIPTS = '.achilles/adversarial-verification'
const TRANSITION = /save_issue|transitionJiraIssue|update_issue|editJiraIssue/
const COMMENT = /save_comment|addCommentToJiraIssue|create_comment/
const DONE = /done|complete|closed|resolved|shipped|released|merged|accepted/i
const NOT_QA = /won'?t ?do|wontfix|duplicate|superseded|abandoned|cancell?ed|obsolete|invalid|not ?a ?bug/i
const VERDICTISH = /qa (test )?report|acceptance criteri|verdict|sign.?off|AC-[0-9]/i
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const DEGENERATE = new Set(['', '-', '.', '..', 'evidence', 'json', 'head'])
const MAX_READ = 4 * 1024 * 1024
const CONFIRMATIONS = '.achilles/defect-confirmations'
const CONFIRM_REF = 'skills/achilles-orchestrator/references/verify-change/phase-7a-defect-confirmation.md'
const CREATE = /createJiraIssue|create_issue|createIssue/
const SEARCH = /search|jql|query|list_?issues|getJiraIssue|get_issue|getIssue/i
const DEDUPE_REF = 'skills/bug-report/SKILL.md'
const DEFECT_TYPE = /\b(bug|rework|defect)\b/i
const DEFECT_ID = /\b([A-Za-z][A-Za-z0-9_]*-[0-9]+-D[0-9]+)\b/g
const REPORTS_DEFECTS = /\bdefects?\b|\bbugs?\b|known.?defect|\brework\b/i
const VERDICTS = new Set(['bug', 'real-in-source', 'spec-ambiguity', 'not-a-bug'])
const DISPATCH_REPRODUCER = 'Dispatch an achilles-reproducer for it (verify-change step 7a, the defect-confirmation skill): its report ends with the defect-repro JSON block, which the adapter records under'

type Receipt = { ticket?: unknown; negativeControl?: unknown; review?: { reviewer?: unknown; uiReviewed?: unknown; coverageSufficient?: unknown; scores?: Record<string, unknown>; total?: unknown } }

const str = (v: unknown) => (typeof v === 'string' ? v : typeof v === 'number' ? String(v) : typeof v === 'object' && v !== null ? String((v as { name?: unknown; id?: unknown }).name ?? (v as { id?: unknown }).id ?? '') : '')

function stateOf(args: Record<string, unknown>): string {
  const f = (args.fields ?? {}) as Record<string, unknown>
  return [args.state, args.status, args.stateId, args.transition, f.status, f.state].map(str).filter(Boolean).join(' ')
}

const keyOf = (args: Record<string, unknown>) => str(args.identifier ?? args.key ?? args.issueIdOrKey ?? args.issue ?? args.issueId ?? args.id)

/** The receipt's own problems, or none. */
export function receiptProblems(r: Receipt): string[] {
  const out: string[] = []
  if (r.negativeControl === undefined) out.push('it has no negativeControl result')
  const rv = r.review
  if (!rv || typeof rv !== 'object') return [...out, 'it has no review block']
  if (typeof rv.reviewer !== 'string' || rv.reviewer === '') out.push('no reviewer is named')
  if (rv.uiReviewed !== true) out.push('the reviewers did not review the UI')
  if (rv.coverageSufficient !== true) out.push('the reviewers did not conclude the coverage is sufficient')
  const zero = Object.entries(rv.scores ?? {}).filter(([, v]) => v === 0).map(([k]) => k)
  if (zero.length > 0) out.push(`dimension${zero.length > 1 ? 's' : ''} ${zero.join(', ')} scored 0`)
  if (typeof rv.total === 'number' && rv.total <= 12) out.push(`the total (${rv.total}) is at or below 12; rework before the report ships`)
  return out
}

async function findReceipt($: EngineInterface, top: string, key: string): Promise<{ path: string; receipt: Receipt } | undefined> {
  const exact = `${top}/${RECEIPTS}/${key}.json`
  const direct = await readJson<Receipt>($, exact)
  if (direct) return { path: exact, receipt: direct }
  for (const entry of await listDir($, `${top}/${RECEIPTS}`)) {
    if (!entry.name.endsWith('.json')) continue
    const path = `${top}/${RECEIPTS}/${entry.name}`
    const r = await readJson<Receipt>($, path)
    if (r && str(r.ticket) === key) return { path, receipt: r }
  }
  return undefined
}

async function bundleArtifacts($: EngineInterface, dir: string): Promise<{ har: string[]; console: string[]; any: boolean }> {
  const har: string[] = []
  const cons: string[] = []
  let any = false
  const visit = async (d: string, level: number) => {
    for (const e of await listDir($, d)) {
      const full = `${d}/${e.name}`
      if (e.kind === 'file') {
        if (e.name.endsWith('.har')) (har.push(full), (any = true))
        else if (e.name === 'console.log') (cons.push(full), (any = true))
        else if (e.name === 'video.webm' || e.name === 'trace.zip') any = true
      } else if (e.kind === 'dir') {
        if (e.name === 'screenshots') {
          if ((await listDir($, full)).length > 0) any = true
        } else if (level === 0) await visit(full, 1)
      }
    }
  }
  await visit(dir, 0)
  return { har, console: cons, any }
}

async function findBundle($: EngineInterface, top: string, key: string): Promise<string | undefined> {
  const k = key.toLowerCase()
  const extra = await $.env.get('ACHILLES_EVIDENCE_DIR').catch(() => undefined)
  const roots = [...(extra ? [extra] : []), ...(await findDirs($, top, 'evidence'))]
  for (const root of roots) {
    const level1 = (await listDir($, root)).filter(e => e.kind === 'dir').map(e => `${root}/${e.name}`)
    const candidates = [...level1]
    for (const d of level1) for (const e of await listDir($, d)) if (e.kind === 'dir') candidates.push(`${d}/${e.name}`)
    for (const d of candidates) {
      const base = basename(d).toLowerCase()
      const named = base === k || (base.startsWith(k) && /[-_.]/.test(base[k.length] ?? ''))
      const summary = named || UUID.test(key) ? await readText($, `${d}/summary.md`) : undefined
      if (summary === undefined) continue
      if (!named && !summary.toLowerCase().includes(k)) continue
      if ((await bundleArtifacts($, d)).any) return d
    }
  }
  return undefined
}

/** The live credentials a bundle's HARs and console logs hold, by file (values withheld). */
async function bundleSecrets($: EngineInterface, bundle: string): Promise<string[]> {
  const { har, console: cons } = await bundleArtifacts($, bundle)
  const out: string[] = []
  for (const f of [...har, ...cons]) {
    const label = f.slice(bundle.length + 1)
    const st = await $.fs.stat(f).catch(() => undefined)
    if (st && st.size > MAX_READ) {
      out.push(`${label}: ${Math.round(st.size / 1048576)} MB, too large to verify (a HAR that size still carries response bodies)`)
      continue
    }
    const text = (await readText($, f)) ?? ''
    if (f.endsWith('.har')) for (const x of harFindings(text)) out.push(`${label}: ${x}`)
    else {
      const x = consoleFinding(text)
      if (x) out.push(`${label}: ${x}`)
    }
  }
  return out
}

type Surface = { kind: 'transition' | 'comment' | 'pr'; key: string; branchBound: boolean; body?: string }

export type Confirmation = { ticket?: unknown; 'defect-id'?: unknown; verdict?: unknown; recordedBy?: unknown }

/** The adapter-recorded confirmation of one defect id, or why there is none. */
export async function confirmationOf($: EngineInterface, top: string, defectId: string): Promise<{ verdict: string; path: string } | { missing: string }> {
  const ticket = defectId.replace(/-D[0-9]+$/, '')
  const path = `${top}/${CONFIRMATIONS}/${ticket}/${defectId}.json`
  const text = await readText($, path)
  if (text === undefined) return { missing: `${defectId}: no recorded confirmation (${CONFIRMATIONS}/${ticket}/${defectId}.json)` }
  const recorded = (await readReceiptHashes($))[path]
  if (recorded === undefined) return { missing: `${defectId}: the confirmation was not recorded by the adapter from a reproducer's report in this session` }
  if (recorded !== hashText(text)) return { missing: `${defectId}: the confirmation changed after the adapter recorded it` }
  let c: Confirmation = {}
  try {
    c = JSON.parse(text) as Confirmation
  } catch {
    return { missing: `${defectId}: the confirmation is not readable JSON` }
  }
  return { verdict: str(c.verdict), path }
}

/** The ticket's defect ids its sentinels cite: `[SENTINEL <KEY>-D<n>]` in any spec under the checkout. */
async function sentinelIds($: EngineInterface, top: string, key: string): Promise<string[]> {
  const re = new RegExp(`\\[SENTINEL (${key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}-D[0-9]+)\\]`, 'g')
  const ids = new Set<string>()
  for (const f of await walk($, top, { depth: 8, max: 3000, skip: /^(node_modules|\.git|\.achilles|dist|build)$/ })) {
    if (!isSpecPath(f)) continue
    for (const m of ((await readText($, f)) ?? '').matchAll(re)) ids.add(m[1]!)
  }
  return [...ids]
}

/** What makes a sign-off report defects nobody confirmed: sentinels without a `bug` verdict, a defect-reporting comment with no confirmation at all. */
async function unconfirmedForSignoff($: EngineInterface, top: string, key: string, surface: Surface): Promise<string[]> {
  const out: string[] = []
  for (const id of await sentinelIds($, top, key)) {
    const c = await confirmationOf($, top, id)
    if ('missing' in c) out.push(`the sentinel [SENTINEL ${id}]: ${c.missing}`)
    else if (c.verdict !== 'bug') out.push(`the sentinel [SENTINEL ${id}]: the reproducer's verdict is \`${c.verdict}\`, not \`bug\``)
  }
  if (surface.kind === 'comment' && surface.body && REPORTS_DEFECTS.test(surface.body)) {
    const cited = [...surface.body.matchAll(DEFECT_ID)].map(m => m[1]!)
    const held = (await listDir($, `${top}/${CONFIRMATIONS}/${key}`)).filter(e => e.name.endsWith('.json'))
    if (cited.length === 0 && held.length === 0) out.push(`this comment reports defects for ${key}, and no defect of ${key} has a recorded confirmation`)
    for (const id of cited) {
      const c = await confirmationOf($, top, id)
      if ('missing' in c) out.push(`the comment cites ${c.missing}`)
    }
  }
  return out
}

/** A defect filing (a bug, rework or defect-labelled issue an Achilles agent creates): refused unless it cites a defect id recorded as `bug`. */
export async function judgeFiling($: EngineInterface, text: string, w?: Who): Promise<{ deny?: string }> {
  if (w && (w.run.trackerSearches ?? 0) === 0)
    return { deny: `achilles: this files a defect before the run searched the tracker for an existing one. Search first: the ticket under test's sub-tasks and links, then open and recently closed bugs with the same screen, message or error text. File nothing new for a defect that already has a ticket; comment there with the new evidence (${DEDUPE_REF} §"Step 0b: search for an existing ticket before drafting a new one").` }
  const top = await checkoutRoot($, await $.session.cwd())
  const cited = [...new Set([...text.matchAll(DEFECT_ID)].map(m => m[1]!))]
  if (cited.length === 0)
    return { deny: `achilles: this files a defect that cites no confirmed defect id (<TICKET>-D<n>). ${DISPATCH_REPRODUCER} ${CONFIRMATIONS}/<ticket>/<defect-id>.json; then file it citing that id. A defect the reproducer did not call a bug is filed only on the user's decision, from the main session (${CONFIRM_REF}).` }
  const problems: string[] = []
  let bug = false
  for (const id of cited) {
    const c = await confirmationOf($, top, id)
    if ('missing' in c) problems.push(c.missing)
    else if (c.verdict === 'bug') bug = true
    else problems.push(`${id}: the reproducer's verdict is \`${c.verdict}\`, not \`bug\``)
  }
  if (bug) return {}
  return { deny: `achilles: this defect filing has no independently confirmed bug behind it:\n${problems.map(s => `  - ${s}`).join('\n')}\n${DISPATCH_REPRODUCER} ${CONFIRMATIONS}/<ticket>/<defect-id>.json. A defect with another verdict is filed only on the user's decision, from the main session (${CONFIRM_REF}).` }
}

async function judge($: EngineInterface, surface: Surface, agentId: string | undefined): Promise<{ deny?: string }> {
  const cwd = await $.session.cwd()
  const top = await checkoutRoot($, cwd)
  const key = surface.key
  if (DEGENERATE.has(key.toLowerCase()) || key.length < 3 || !/[a-z0-9]/i.test(key)) {
    if (surface.kind !== 'comment') await note($, agentId, `this sign-off names no usable ticket key ("${key}"), so its receipt and evidence bundle cannot be found (${REF}).`)
    return {}
  }
  const bundle = await findBundle($, top, key)
  if (bundle) {
    const secrets = await bundleSecrets($, bundle)
    if (secrets.length > 0)
      return { deny: `achilles: the evidence bundle ${bundle.slice(top.length + 1)} still holds a live credential, so this sign-off would publish it:\n${secrets.map(s => `  - ${s}`).join('\n')}\nRedact each value (keep the field, replace the value with [REDACTED]) or delete the file, record what was removed in the bundle's summary.md under "## Redactions", then sign off again.` }
  }
  const unconfirmed = await unconfirmedForSignoff($, top, key, surface)
  if (unconfirmed.length > 0)
    return { deny: `achilles: this sign-off reports defects that no independent reproducer confirmed:\n${unconfirmed.map(s => `  - ${s}`).join('\n')}\n${DISPATCH_REPRODUCER} ${CONFIRMATIONS}/${key}/<defect-id>.json. Sign off once every defect has a recorded verdict; remove the sentinel of any defect whose verdict is not \`bug\` (${CONFIRM_REF}).` }
  const problems: string[] = []
  const found = await findReceipt($, top, key)
  if (!found) problems.push(`no sign-off receipt ${RECEIPTS}/${key}.json under ${top}`)
  else {
    const own = receiptProblems(found.receipt)
    if (own.length > 0) problems.push(`the receipt ${found.path.slice(top.length + 1)} is incomplete: ${own.join('; ')}`)
    const recorded = (await readReceiptHashes($))[found.path]
    const text = (await readText($, found.path)) ?? ''
    if (recorded === undefined) problems.push('the receipt was not recorded by the adapter from a reviewer’s report in this session')
    else if (recorded !== hashText(text)) problems.push('the receipt changed after the adapter recorded it')
    const st = await $.fs.stat(found.path).catch(() => undefined)
    const newest = await newestSpec($, top)
    if (st && newest > st.mtimeMs) problems.push('the receipt is OLDER than the most recently edited spec')
  }
  if (!bundle) problems.push(`no evidence bundle for ${key} (an evidence/<${surface.branchBound ? 'branch' : 'ticket'}>-… directory with summary.md and a screenshot, video, trace or HAR)${surface.branchBound ? '; a PR with no ticket binds the bundle to the BRANCH' : ''}`)
  if (problems.length > 0) {
    const what = surface.kind === 'comment' ? 'this verdict-shaped comment reads as verified, but' : surface.kind === 'pr' ? 'this PR publishes the work as verified, but' : 'this transition signs the ticket off, but'
    await note($, agentId, `${what}:\n- ${problems.join('\n- ')}\nOne ticket, one run of the verify-change workflow: run the adversarial review for ${key} before signing off (${REF}).`)
  }
  return {}
}

function prPublishes(command: string): boolean {
  const lines = [command]
  for (const m of command.matchAll(/\$\(([^)]*)\)|`([^`]*)`/g)) lines.push(m[1] ?? m[2] ?? '')
  for (const line of lines) {
    for (const cmd of commands(line).commands) {
      const inner = nestedCommand(cmd.args)
      const all = inner === undefined ? [cmd] : commands(inner).commands
      for (const c of all) {
        const a = c.args
        if (a[0] !== 'gh') continue
        const words = a.slice(1).flatMap(w => w.split(/\s+/)).filter(Boolean)
        if (words[0] !== 'pr' || (words[1] !== 'create' && words[1] !== 'ready')) continue
        if (words[1] === 'ready') return true
        let draft = false
        for (let i = 2; i < a.length; i++) {
          const t = a[i]!
          if (t === '--title' || t === '-t' || t === '--body' || t === '-b' || t === '--base' || t === '-B') i++
          else if (t === '--draft' || t === '-d') draft = true
          else if (/^(--draft|-d)=/.test(t)) draft = /^(1|t|true)$/i.test(t.slice(t.indexOf('=') + 1))
        }
        if (!draft) return true
      }
    }
  }
  return false
}

async function branchKey($: EngineInterface): Promise<string> {
  const r = await run($, ['git', 'rev-parse', '--abbrev-ref', 'HEAD'], { timeoutMs: 3000 })
  return r.ok && r.exitCode === 0 ? r.stdout.trim().replace(/\//g, '-') : ''
}

/** A reviewer's report or hand-back may carry the receipt fields as a JSON block with a "ticket" key. */
function receiptBlocks(text: string): Record<string, unknown>[] {
  const out: Record<string, unknown>[] = []
  for (const m of text.matchAll(/```json\s*\n([\s\S]*?)```/g)) {
    try {
      const v = JSON.parse(m[1]!) as unknown
      const rec = (v as { signoff?: unknown }).signoff ?? v
      if (rec && typeof rec === 'object' && typeof (rec as { ticket?: unknown }).ticket === 'string') out.push(rec as Record<string, unknown>)
    } catch {
      /* not a receipt block */
    }
  }
  return out
}

/** Called at a reviewer's turn end (hooks.ts): merges the receipt fields it reported into the ticket's receipt. */
export async function recordReceipt($: EngineInterface, w: Who, e: TurnCompleteInput) {
  if (w.role !== 'reviewer' || !w.expert) return
  const cwd = await $.session.cwd()
  const report = w.expert.report ? await readText($, `${cwd}/${w.expert.report}`) : undefined
  const blocks = receiptBlocks(`${e.answer}\n${report ?? ''}`)
  if (blocks.length === 0) return
  const top = await checkoutRoot($, cwd)
  for (const block of blocks) {
    const ticket = String(block.ticket)
    if (!/^[A-Za-z0-9][A-Za-z0-9_.-]{2,}$/.test(ticket)) continue
    const path = `${top}/${RECEIPTS}/${ticket}.json`
    const held = (await readJson<Record<string, unknown>>($, path)) ?? {}
    const review = { ...((held.review as Record<string, unknown>) ?? {}), ...((block.review as Record<string, unknown>) ?? {}) }
    const scores = { ...(((held.review as { scores?: object })?.scores as object) ?? {}), ...(((block.review as { scores?: object })?.scores as object) ?? {}) }
    const recordedBy = [...((held.recordedBy as unknown[]) ?? []), { agentId: w.expert.agentId, run: w.run.id }]
    const merged = { ...held, ...block, review: { ...review, scores }, ranAt: new Date(await $.clock.now()).toISOString(), recordedBy }
    const text = `${JSON.stringify(merged, null, 2)}\n`
    await $.fs.write(path, text)
    await writeReceiptHash($, path, hashText(text))
  }
}

/** The defect-repro blocks a reproducer's report or hand-back carries: fenced json with a defect-id and a verdict. */
export function confirmationBlocks(text: string): Record<string, unknown>[] {
  const out: Record<string, unknown>[] = []
  for (const m of text.matchAll(/```json\s*\n([\s\S]*?)```/g)) {
    try {
      const v = JSON.parse(m[1]!) as Record<string, unknown>
      if (v && typeof v === 'object' && typeof v['defect-id'] === 'string' && typeof v.verdict === 'string') out.push(v)
    } catch {
      /* not a confirmation block */
    }
  }
  return out
}

/** Called at a reproducer's turn end (hooks.ts): records each verdict it reported as the defect's confirmation. */
export async function recordConfirmation($: EngineInterface, w: Who, e: TurnCompleteInput) {
  if (w.role !== 'reproducer' || !w.expert) return
  const cwd = await $.session.cwd()
  const report = w.expert.report ? await readText($, `${cwd}/${w.expert.report}`) : undefined
  const blocks = confirmationBlocks(`${e.answer}\n${report ?? ''}`)
  const top = await checkoutRoot($, cwd)
  const refused: string[] = []
  for (const block of blocks) {
    const id = String(block['defect-id'])
    const ticket = String(block.ticket ?? '')
    const verdict = String(block.verdict)
    if (!/^[A-Za-z0-9][A-Za-z0-9_.-]*-D[0-9]+$/.test(id) || id.replace(/-D[0-9]+$/, '') !== ticket) refused.push(`"${id}": the defect id must be <ticket>-D<n> for its ticket ("${ticket}")`)
    else if (!VERDICTS.has(verdict)) refused.push(`${id}: "${verdict}" is not a verdict (bug, real-in-source, spec-ambiguity, not-a-bug)`)
    else if (verdict === 'bug' && !(Number((block.reproduction as { observed?: unknown })?.observed) >= 1)) refused.push(`${id}: a bug verdict with no live observation (reproduction.observed < 1)`)
    else {
      const path = `${top}/${CONFIRMATIONS}/${ticket}/${id}.json`
      const record = { ...block, report: w.expert.report, recordedBy: { agentId: w.expert.agentId, run: w.run.id }, recordedAt: new Date(await $.clock.now()).toISOString() }
      const text = `${JSON.stringify(record, null, 2)}\n`
      await $.fs.write(path, text)
      await writeReceiptHash($, path, hashText(text))
    }
  }
  if (blocks.length === 0) refused.push('its return carries no defect-repro JSON block (defect-id, verdict)')
  if (refused.length > 0) await note($, w.run.agentId, `the reproducer ${w.expert.agentId} handed back a confirmation the adapter could not record:\n- ${refused.join('\n- ')}\nThe defect stays unconfirmed; re-dispatch a fresh reproducer with the gap quoted (${CONFIRM_REF}).`)
}

/** The issue type, labels and text a create call carries, for the defect-filing check. */
function filingOf(args: Record<string, unknown>): { defect: boolean; text: string } {
  const f = (args.fields ?? args.additional_fields ?? {}) as Record<string, unknown>
  const type = [args.issueType, args.issueTypeName, args.type, args.issuetype, f.issuetype, f.issueType].map(str).join(' ')
  const labels = [args.labels, f.labels].flatMap(l => (Array.isArray(l) ? l.map(str) : typeof l === 'string' ? [l] : [])).join(' ')
  const text = [args.summary, args.title, args.description, args.body, f.summary, f.description].filter((x): x is string => typeof x === 'string').join('\n')
  return { defect: DEFECT_TYPE.test(type) || DEFECT_TYPE.test(labels), text }
}

/** `gh issue create` with a bug, rework or defect label, and the title and body it carries. */
function ghFiling(command: string): { defect: boolean; text: string } | undefined {
  for (const cmd of commands(command).commands) {
    const a = cmd.args
    if (a[0] !== 'gh' || a[1] !== 'issue' || a[2] !== 'create') continue
    const val = (names: string[]) => a.flatMap((t, i) => (names.includes(t) ? [a[i + 1] ?? ''] : names.flatMap(n => (t.startsWith(`${n}=`) ? [t.slice(n.length + 1)] : []))))
    return { defect: val(['--label', '-l']).some(l => DEFECT_TYPE.test(l)), text: [...val(['--title', '-t']), ...val(['--body', '-b'])].join('\n') }
  }
  return undefined
}

export function registerSignoff(on: On) {
  on('tool.call', { tool: /^mcp__/ }, async ($, e, next) => {
    if (isDisabled()) return next(e)
    const name = e.tool.split('__').pop() ?? e.tool
    if (SEARCH.test(name) && !CREATE.test(name)) {
      const w = await who($, e.agentId)
      if (w) await editRun($, w.run.id, r => ({ ...r, trackerSearches: (r.trackerSearches ?? 0) + 1 }))
      return next(e)
    }
    if (!CREATE.test(e.tool)) return next(e)
    const w = await who($, e.agentId)
    if (!w) return next(e)
    const filing = filingOf(e as unknown as Record<string, unknown>)
    if (!filing.defect) return next(e)
    const r = await judgeFiling($, filing.text, w)
    return r.deny ? { deny: r.deny } : next(e)
  }).catch(($, e, next) => (next.called ? next(e) : { deny: 'achilles: its defect-filing check failed, so the tracker call is refused.' }))

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    if (isDisabled() || !/\bgh\b/.test(e.command) || !/\bissue\b/.test(e.command)) return next(e)
    const w = await who($, e.agentId)
    if (w && /\bgh\s+issue\s+(list|search|view)\b|\bgh\s+search\s+issues\b/.test(e.command)) {
      await editRun($, w.run.id, r => ({ ...r, trackerSearches: (r.trackerSearches ?? 0) + 1 }))
      return next(e)
    }
    const filing = w ? ghFiling(e.command) : undefined
    if (!filing?.defect) return next(e)
    const r = await judgeFiling($, filing.text, w)
    return r.deny ? { deny: r.deny } : next(e)
  }).catch(($, e, next) => (next.called ? next(e) : { deny: 'achilles: its defect-filing check failed, so the issue call is refused.' }))

  on('tool.call', { tool: /^mcp__/ }, async ($, e, next) => {
    if (isDisabled()) return next(e)
    const isTransition = TRANSITION.test(e.tool)
    const isComment = COMMENT.test(e.tool)
    if (!isTransition && !isComment) return next(e)
    const w = await who($, e.agentId)
    if (!w) return next(e)
    const args = e as unknown as Record<string, unknown>
    if (isTransition) {
      const state = stateOf(args)
      if (NOT_QA.test(state) || !DONE.test(state)) return next(e)
    } else {
      const body = [args.body, args.commentBody, args.comment, args.text].filter((x): x is string => typeof x === 'string').join('\n')
      if (!VERDICTISH.test(body)) return next(e)
    }
    const body = [args.body, args.commentBody, args.comment, args.text].filter((x): x is string => typeof x === 'string').join('\n')
    const r = await judge($, { kind: isTransition ? 'transition' : 'comment', key: keyOf(args), branchBound: false, body }, e.agentId)
    return r.deny ? { deny: r.deny } : next(e)
  }).catch(($, e, next) => (next.called ? next(e) : { deny: 'achilles: its sign-off check failed, so the tracker call is refused.' }))

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    if (isDisabled()) return next(e)
    if (!/\bgh\b/.test(e.command) || !/\bpr\b/.test(e.command)) return next(e)
    const w = await who($, e.agentId)
    if (!w || !prPublishes(e.command)) return next(e)
    const r = await judge($, { kind: 'pr', key: await branchKey($), branchBound: true }, e.agentId)
    return r.deny ? { deny: r.deny } : next(e)
  }).catch(($, e, next) => (next.called ? next(e) : { deny: 'achilles: its sign-off check failed, so the PR call is refused.' }))
}

