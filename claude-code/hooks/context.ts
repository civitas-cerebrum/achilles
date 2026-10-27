import type { EngineInterface, FsEntry, ProcessRunResult } from 'claude-code'
import { update } from 'claude-code'

import type { AchillesExpert, AchillesRun, AchillesStage } from '../types'
import { basename, isAbsolute, normalize, relTo, resolve } from './posix'

// What every hook shares: the run registry in $.state, the agent → role lookup, the advisory
// note, file access and the factory rule file. The kill switch is read once per load at
// session.start (hooks.ts) and consulted by every hook through isDisabled().

const RUNS = { plugin: 'achilles', key: 'runs' } as const

let disabled = false
export const setDisabled = (v: boolean) => (disabled = v)
export const isDisabled = () => disabled

export const ROLES = ['inspector', 'author', 'reviewer', 'doc-writer'] as const
export const agentType = (role: (typeof ROLES)[number] | 'orchestrator') => `achilles:achilles-${role}`
export const ORCHESTRATOR = agentType('orchestrator')
export const EXPERTS: readonly string[] = ROLES.map(agentType)
export const roleOf = (type: string) => type.replace(/^achilles:achilles-/, '')

export type Who = { run: AchillesRun; role: string; expert?: AchillesExpert }

export async function readRuns($: EngineInterface): Promise<AchillesRun[]> {
  const { value = [] } = await $.state.get(RUNS)
  return value
}

// ── progress: the stage a run is in and the experts at work, for the status line, the pane and progress.json ──

/** The stage statuses that end a stage; anything else is still to go. */
export const ENDED = new Set(['completed', 'skipped', 'blocked', 'failed'])
const ACTIVE = new Set(['in-progress', 'active', 'running'])

/** The stage a run is in: the first one marked active, else the first not yet ended. */
export const currentStage = (stages: AchillesStage[] = []) => stages.find(s => ACTIVE.has(s.status)) ?? stages.find(s => !ENDED.has(s.status))

/** "stage 2/8 Groundwork", the resume step when the run has no stages yet, or undefined. */
export function stageLine(run: AchillesRun): string | undefined {
  const stages = run.stages ?? []
  if (stages.length === 0) return run.step ? `step ${run.step}` : undefined
  const cur = currentStage(stages)
  return cur ? `stage ${stages.indexOf(cur) + 1}/${stages.length} ${cur.name}` : `${stages.filter(s => ENDED.has(s.status)).length}/${stages.length} stages ended`
}

/** The name a brief or report path gives its dispatch: `.achilles/runs/<run>/briefs/p2-groundwork.md` → `p2-groundwork`. */
export const slugOf = (path?: string) => (path ? basename(path).replace(/\.md$/, '') : undefined)

export const expertLabel = (x: AchillesExpert) => `${x.role} ${slugOf(x.brief ?? x.report) ?? x.agentId}`

export async function writeRuns($: EngineInterface, change: (runs: AchillesRun[]) => AchillesRun[]) {
  const runs = await update($, RUNS, (runs = []) => change(runs))
  const experts = runs.flatMap(r => r.experts)
  const judge = runs.find(r => (r.judge?.consecutive ?? 0) > 0)
  const extra = [
    ...runs.map(stageLine).filter(Boolean),
    judge ? `judge loop open ${judge.judge!.consecutive}/3` : '',
    runs.some(r => r.selector) ? `selector ${runs.map(r => r.selector).filter(Boolean).map(s => `${s!.scope} ${s!.steps.length}/8`).join(', ')}` : '',
  ].filter(Boolean)
  // Two experts are named by brief; more are counted by role, so the line stays one line.
  const roles = new Map<string, number>()
  for (const x of experts) roles.set(x.role, (roles.get(x.role) ?? 0) + 1)
  const working = experts.length === 0 ? '' : ` (${experts.length <= 2 ? experts.map(expertLabel).join(', ') : [...roles].map(([r, n]) => (n === 1 ? r : `${r} ×${n}`)).join(', ')})`
  // The engine shows the line under the plugin's name, so it carries no "achilles:" of its own.
  $.ui.status(
    runs.length === 0
      ? undefined
      : `${runs.length} run${runs.length === 1 ? '' : 's'} · ${experts.length} expert${experts.length === 1 ? '' : 's'} running${working}${extra.length ? ` · ${extra.join(' · ')}` : ''}`,
  )
  return runs
}

export function editRun($: EngineInterface, id: string, fn: (run: AchillesRun) => AchillesRun) {
  return writeRuns($, runs => runs.map(r => (r.id === id ? fn(r) : r)))
}

export function editExpert($: EngineInterface, runId: string, agentId: string, fn: (x: AchillesExpert) => AchillesExpert) {
  return editRun($, runId, r => ({ ...r, experts: r.experts.map(x => (x.agentId === agentId ? fn(x) : x)) }))
}

/** The content hashes of the pipeline ledgers as of their last sanctioned write, by project-relative path. */
export async function readLedgerHashes($: EngineInterface): Promise<Record<string, string>> {
  const { value = {} } = await $.state.get({ plugin: 'achilles', key: 'ledgers' })
  return value
}

export async function writeLedgerHash($: EngineInterface, rel: string, hash: string) {
  await update($, { plugin: 'achilles', key: 'ledgers' }, (held = {}) => ({ ...held, [rel]: hash }))
}

export function whoIs(runs: AchillesRun[], agentId: string | undefined): Who | undefined {
  if (agentId === undefined) return undefined
  for (const run of runs) {
    if (run.agentId === agentId) return { run, role: 'orchestrator' }
    const expert = run.experts.find(x => x.agentId === agentId)
    if (expert) return { run, role: expert.role, expert }
  }
  return undefined
}

export async function who($: EngineInterface, agentId: string | undefined) {
  return whoIs(await readRuns($), agentId)
}

/** One advisory row in a loop's conversation: the model reads it, the person does not see it typed. */
export async function note($: EngineInterface, agentId: string | undefined, text: string) {
  await $.session
    .append({ ...(agentId === undefined ? {} : { agentId }), message: { type: 'user', content: [{ type: 'text', text: `achilles: ${text}` }] } })
    .catch(() => undefined)
}

export function readText($: EngineInterface, path: string): Promise<string | undefined> {
  return $.fs
    .read(path)
    .then(v => (typeof v === 'string' ? v : undefined))
    .catch(() => undefined)
}

export async function readJson<T = unknown>($: EngineInterface, path: string): Promise<T | undefined> {
  const text = await readText($, path)
  if (text === undefined) return undefined
  try {
    return JSON.parse(text) as T
  } catch {
    return undefined
  }
}

export function exists($: EngineInterface, path: string) {
  return $.fs.exists(path).catch(() => false)
}

export function listDir($: EngineInterface, path: string): Promise<FsEntry[]> {
  return $.fs.list(path).catch(() => [] as FsEntry[])
}

/** Every regular file under `dir`, project-relative to it, depth and count bounded so a hook never walks a whole tree. */
export async function walk($: EngineInterface, dir: string, opts: { depth?: number; max?: number; skip?: RegExp } = {}): Promise<string[]> {
  const { depth = 4, max = 2000, skip = /^(node_modules|\.git)$/ } = opts
  const out: string[] = []
  const queue: { path: string; depth: number }[] = [{ path: dir, depth: 0 }]
  while (queue.length > 0 && out.length < max) {
    const { path, depth: d } = queue.shift()!
    for (const entry of await listDir($, path)) {
      if (skip.test(entry.name)) continue
      const full = `${path}/${entry.name}`
      if (entry.kind === 'file') out.push(full)
      else if (entry.kind === 'dir' && d < depth) queue.push({ path: full, depth: d + 1 })
      if (out.length >= max) break
    }
  }
  return out
}

/** A file's path resolved against the project (the session cwd) and its project-relative spelling. */
export function placeFile(root: string, filePath: string): { abs: string; rel: string } {
  const abs = resolve(root, filePath)
  return { abs, rel: relTo(root, abs) }
}

export type FactoryRules = { path: string; rel: string; rules: Record<string, Record<string, unknown>> }

/** The project's achilles-factory-rules.json (or FACTORY_RULES), when the project opted into the factory rules. */
export async function factoryRules($: EngineInterface, root: string): Promise<FactoryRules | undefined> {
  const override = await $.env.get('FACTORY_RULES').catch(() => undefined)
  const path = override ? resolve(root, override) : `${root}/achilles-factory-rules.json`
  const doc = await readJson<{ rules?: unknown }>($, path)
  if (!doc || typeof doc !== 'object' || !doc.rules || typeof doc.rules !== 'object') return undefined
  return { path, rel: relTo(root, path), rules: doc.rules as FactoryRules['rules'] }
}

export const ruleOf = (rules: FactoryRules | undefined, id: string): Record<string, unknown> | undefined => {
  const r = rules?.rules[id]
  return r && typeof r === 'object' ? r : undefined
}

export const strings = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string' && x !== '') : [])

/** The factory three-line message: what happened, what to do, where it is written down. */
export function threeLine(id: string, what: string, action: string | undefined, doc: string | undefined): string {
  return `[${id}] ${what}\n→ Do: ${action ?? 'see the rule file'}\n→ Why/how: ${doc ?? `achilles-factory-rules.json#${id}`}`
}

/** The content of a file after an Edit: Edit-tool semantics (one occurrence, or every one with replace_all). */
export function applyEdit(before: string, edit: { old_string: string; new_string: string; replace_all?: boolean }): { text: string } | { error: string } {
  if (edit.old_string === '') return { error: 'old_string is empty' }
  const parts = before.split(edit.old_string)
  if (parts.length < 2) return { error: 'old_string does not occur in the file' }
  if (edit.replace_all) return { text: parts.join(edit.new_string) }
  if (parts.length > 2) return { error: 'old_string occurs more than once and replace_all is not set' }
  return { text: `${parts[0]}${edit.new_string}${parts[1]}` }
}

/** The content a Write or Edit lands, read from disk when an Edit needs its before-text. */
export async function afterContent(
  $: EngineInterface,
  e: { tool: string; file_path: string; content?: string; old_string?: string; new_string?: string; replace_all?: boolean },
  abs: string,
): Promise<{ before: string; after: string } | { before: string; error: string }> {
  const before = (await readText($, abs)) ?? ''
  if (e.tool === 'Write') return { before, after: e.content ?? '' }
  const r = applyEdit(before, { old_string: e.old_string ?? '', new_string: e.new_string ?? '', replace_all: e.replace_all })
  return 'text' in r ? { before, after: r.text } : { before, error: r.error }
}

/** The text an Edit or Write adds, for a content screen that judges only what the call writes. */
export const writtenText = (e: { tool: string; content?: string; new_string?: string }) => (e.tool === 'Write' ? (e.content ?? '') : (e.new_string ?? ''))

/** Best-effort comment masking for a content screen: block comments on one line, JSDoc body lines, `// …` tails. */
export const maskComments = (text: string) =>
  text
    .split('\n')
    .map(l => l.replace(/\/\*([^*]|\*+[^*/])*\*+\//g, '').replace(/^\s*(\/\*|\*).*$/, '').replace(/\/\/.*$/, ''))
    .join('\n')

/** A 64-bit content hash (two 32-bit halves), enough to notice a file changed; not a cryptographic digest. */
export function hashText(s: string): string {
  let h1 = 0xdeadbeef ^ s.length
  let h2 = 0x41c6ce57 ^ s.length
  for (let i = 0; i < s.length; i++) {
    const ch = s.charCodeAt(i)
    h1 = Math.imul(h1 ^ ch, 2654435761)
    h2 = Math.imul(h2 ^ ch, 1597334677)
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909)
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909)
  return `${(h2 >>> 0).toString(16).padStart(8, '0')}${(h1 >>> 0).toString(16).padStart(8, '0')}`
}

export type Ran = { ok: true; stdout: string; stderr: string; exitCode: number } | { ok: false; reason: string }

/** A host command with a bounded wait; a failure to start or a timeout is a value, never a throw. */
export async function run($: EngineInterface, argv: readonly string[], init: { cwd?: string; stdin?: string; timeoutMs?: number; env?: Record<string, string> } = {}): Promise<Ran> {
  try {
    const r: ProcessRunResult = await $.process.run(argv, { timeoutMs: 8000, ...init })
    return { ok: true, stdout: r.stdout, stderr: r.stderr, exitCode: r.exitCode }
  } catch (err) {
    return { ok: false, reason: err instanceof Error ? err.message : String(err) }
  }
}

export const firstLine = (s: string) => s.split('\n').find(l => l.trim() !== '')?.trim() ?? ''

export function scriptPath($: EngineInterface, rel: string) {
  return `${$.plugin.root}/claude-code/lib/${rel}`
}

export const isSpecPath = (p: string) => /\.(spec|test|setup)\.[cm]?[jt]sx?$/.test(basename(p)) || /\.(spec|test|setup)\./.test(basename(p))
export const isPageRepository = (p: string) => /page-repository[^/]*\.json$/.test(basename(p))
export const isFrontendSource = (p: string) =>
  /\.(tsx|jsx|vue|svelte|html)$/.test(p) || (/\.(ts|js)$/.test(p) && /(^|\/)(src|app|pages|components)\//.test(p) && !/(^|\/)tests?\//.test(p))

export { isAbsolute, normalize }

export type Validated = { ok: true } | { ok: false; parse?: string; errors?: string[] } | { unavailable: string }

/** Validates a document against schemas/<schema>.schema.json in a node child (the module cannot import Ajv). */
export async function validateDoc($: EngineInterface, schema: string, text: string, timeoutMs = 6000): Promise<Validated> {
  const r = await run($, ['node', `${$.plugin.root}/claude-code/lib/validate.mjs`, schema], { stdin: text, timeoutMs })
  if (!r.ok) return { unavailable: r.reason }
  try {
    const v = JSON.parse(r.stdout) as Validated
    return typeof v === 'object' && v !== null && 'ok' in v ? v : { unavailable: 'no verdict' }
  } catch {
    return { unavailable: firstLine(r.stderr) || `exit ${r.exitCode}` }
  }
}

export async function readReceiptHashes($: EngineInterface): Promise<Record<string, string>> {
  const { value = {} } = await $.state.get({ plugin: 'achilles', key: 'receipts' })
  return value
}

export async function writeReceiptHash($: EngineInterface, path: string, hash: string) {
  await update($, { plugin: 'achilles', key: 'receipts' }, (held = {}) => ({ ...held, [path]: hash }))
}

const SKIP_DIRS = /^(node_modules|\.git|dist|build|\.next|coverage|vendor|\.achilles)$/

/** Every directory under `dir` named `name`, breadth first, depth and count bounded. */
export async function findDirs($: EngineInterface, dir: string, name: string, opts: { depth?: number; max?: number } = {}): Promise<string[]> {
  const { depth = 6, max = 3000 } = opts
  const out: string[] = []
  const queue: { path: string; depth: number }[] = [{ path: dir, depth: 0 }]
  let seen = 0
  while (queue.length > 0 && seen < max) {
    const { path, depth: d } = queue.shift()!
    for (const entry of await listDir($, path)) {
      if (entry.kind !== 'dir' || SKIP_DIRS.test(entry.name)) continue
      seen++
      const full = `${path}/${entry.name}`
      if (entry.name === name) out.push(full)
      if (d < depth) queue.push({ path: full, depth: d + 1 })
    }
  }
  return out
}

/** The checkout that owns `.achilles/`: the main work tree of the session's repository (a worktree resolves to it), else the session directory. */
export async function checkoutRoot($: EngineInterface, cwd: string): Promise<string> {
  const r = await run($, ['git', 'rev-parse', '--path-format=absolute', '--git-common-dir'], { cwd, timeoutMs: 3000 })
  if (!r.ok || r.exitCode !== 0) return cwd
  const common = r.stdout.trim()
  return common.endsWith('/.git') ? common.slice(0, -5) : cwd
}

/** The newest modification time of any spec file under `dir` (0 when none). */
export async function newestSpec($: EngineInterface, dir: string): Promise<number> {
  let newest = 0
  for (const f of await walk($, dir, { depth: 8, max: 3000 })) {
    if (!isSpecPath(f)) continue
    const st = await $.fs.stat(f).catch(() => undefined)
    if (st && st.mtimeMs > newest) newest = st.mtimeMs
  }
  return newest
}

/** The brief and report paths a dispatch prompt names (`.achilles/runs/<run>/briefs/<slug>.md`, `…/reports/<slug>.md`). */
export function dispatchPaths(prompt: string): { brief?: string; report?: string } {
  const brief = /(?:^|[\s`'"(])((?:\.\/)?\.achilles\/(?:runs\/[^\s`'")]+\/)?briefs\/[^\s`'")]+\.md)/.exec(prompt)?.[1]
  const report = /(?:^|[\s`'"(])((?:\.\/)?\.achilles\/runs\/[^\s`'")]+\/reports\/[^\s`'")]+\.md)/.exec(prompt)?.[1]
  return { ...(brief ? { brief: brief.replace(/^\.\//, '') } : {}), ...(report ? { report: report.replace(/^\.\//, '') } : {}) }
}
