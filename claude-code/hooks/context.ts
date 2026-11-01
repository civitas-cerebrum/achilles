import type { EngineInterface } from 'claude-code'
import { update } from 'claude-code'

import type { AchillesExpert, AchillesRun, AchillesStage } from '../types'
import { listDir, run, walk, isSpecPath } from './io'
import { basename, relTo, resolve } from './posix'

export * from './io'

// What every hook shares: the run registry in $.state, the agent → role lookup and the advisory
// note; the file, process and rule-file helpers live in io.ts and are re-exported here. The kill switch is read once per load at
// session.start (hooks.ts) and consulted by every hook through isDisabled().

const RUNS = { plugin: 'achilles', key: 'runs' } as const

let disabled = false
export const setDisabled = (v: boolean) => (disabled = v)
export const isDisabled = () => disabled

export const ORCHESTRATOR = 'achilles:achilles-orchestrator'
/** Every plugin agent named achilles-<role> other than the orchestrator is an expert (agents/*.md). */
export const isExpert = (type: string) => /^achilles:achilles-[\w-]+$/.test(type) && type !== ORCHESTRATOR
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
