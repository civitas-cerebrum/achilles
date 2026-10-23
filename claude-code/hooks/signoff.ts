import type { EngineInterface, On, TurnCompleteInput } from 'claude-code'

import {
  checkoutRoot,
  findDirs,
  hashText,
  isDisabled,
  listDir,
  newestSpec,
  note,
  readJson,
  readReceiptHashes,
  readText,
  run,
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
// than the newest spec. The one refusal: a bundle whose HAR or console log still holds a live
// credential, on every sign-off surface, because a published credential cannot be unpublished.

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

type Surface = { kind: 'transition' | 'comment' | 'pr'; key: string; branchBound: boolean }

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

export function registerSignoff(on: On) {
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
    const r = await judge($, { kind: isTransition ? 'transition' : 'comment', key: keyOf(args), branchBound: false }, e.agentId)
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

