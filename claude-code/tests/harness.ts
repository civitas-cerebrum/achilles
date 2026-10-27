import type { FsEntry, On, ProcessRunResult } from 'claude-code'
import type { Engine as EngineInterface, MockClock } from 'claude-code/testing'
import { mock } from 'claude-code/testing'

// The world beneath the plugin, for every hook test: an in-memory project at ROOT, a table of
// host commands, the agent registry the adapter reads, and the spawns, prompts and status
// lines the adapter writes. Nothing here is the engine; each hook stands for it.

export const ROOT = '/proj'
export const DELEGATE = 'mcp__achilles__delegate_qa'
export const START = { cwd: ROOT, surface: 'terminal', isInteractive: true } as const

const AGENT_FILES: Record<string, string> = Object.fromEntries(
  ['orchestrator', 'inspector', 'author', 'reviewer', 'doc-writer'].map(role => [
    `achilles-${role}.md`,
    `---\nname: achilles-${role}\ndescription: The ${role}.\ntools: Read, Write, Edit, Bash\n---\nYou are the ${role}.`,
  ]),
)

export type Proc = (argv: readonly string[], init: { cwd?: string; stdin?: string; env?: Record<string, string> } | undefined) => Partial<ProcessRunResult> | string | undefined

export type Harness = {
  files: Map<string, string>
  mtimes: Map<string, number>
  write: (path: string, content: string, mtimeMs?: number) => void
  remove: (path: string) => void
  procs: Proc[]
  ran: { argv: string[]; stdin?: string; cwd?: string }[]
  spawns: { subagentType: string; prompt: string; agentId: string; description: string; background: boolean }[]
  prompts: string[]
  status: () => string | undefined
  written: () => string[]
  tools: { name: string; isDeferred?: unknown }[]
  agents: Record<string, unknown>[]
  clock: MockClock
}

const parentDirs = (path: string) => {
  const out: string[] = []
  let p = path
  while (p.includes('/')) {
    p = p.slice(0, p.lastIndexOf('/'))
    out.push(p === '' ? '/' : p)
  }
  return out
}

export function engine(on: On, opts: { env?: Record<string, string>; files?: Record<string, string>; now?: number } = {}): Harness {
  const clock = mock.clock(on, { now: opts.now ?? 1_700_000_000_000 })
  mock.env(on, opts.env ?? {})
  const files = new Map<string, string>()
  const mtimes = new Map<string, number>()
  const writtenPaths: string[] = []
  const write = (path: string, content: string, mtimeMs = 1_600_000_000_000) => {
    files.set(path, content)
    mtimes.set(path, mtimeMs)
  }
  const remove = (path: string) => {
    files.delete(path)
    mtimes.delete(path)
  }
  for (const [p, c] of Object.entries(opts.files ?? {})) write(p, c)
  const dirs = () => {
    const d = new Set<string>([ROOT])
    for (const f of files.keys()) for (const p of parentDirs(f)) d.add(p)
    return d
  }
  const spawns: Harness['spawns'] = []
  const prompts: string[] = []
  const ran: Harness['ran'] = []
  const procs: Proc[] = []
  let status: string | undefined
  let n = 0

  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: ROOT }))
  const tools: Harness['tools'] = []
  const agents: Harness['agents'] = []
  on('tool.register', (_, e) => (tools.push(e), { value: { tool: DELEGATE } }))
  on('agent.register', (_, e) => (agents.push(e), { value: { agent: `achilles:${e.name}` } }))
  on('command.register', (_, e) => ({ value: { command: e.name } }))
  on('ui.status', (_, e) => ((status = e.text), { value: undefined }))
  on('ui.toast', () => ({ value: undefined }))
  on('turn.complete', (_, e) => ({ text: e.answer }))
  on('prompt.submit', (_, e) => (prompts.push(e.text), { text: e.text }))
  // The built-in file tools land what they were asked to, so a later read sees it.
  on('tool.call', (_, e) => {
    const t = e as unknown as { tool: string; file_path?: string; content?: string; old_string?: string; new_string?: string; replace_all?: boolean }
    if (t.tool === 'Write' && t.file_path) write(t.file_path, t.content ?? '', 1_700_000_000_000)
    if (t.tool === 'Edit' && t.file_path && files.has(t.file_path) && t.old_string) {
      const before = files.get(t.file_path)!
      const parts = before.split(t.old_string)
      if (parts.length === 2 || (parts.length > 2 && t.replace_all)) write(t.file_path, parts.join(t.new_string ?? ''), 1_700_000_000_000)
    }
    return { result: { ok: true } }
  })
  on('agent.spawn', (_, e) => {
    const subagentType = e.subagentType ?? (e as { subagent_type?: string }).subagent_type ?? ''
    const agentId = `${subagentType.replace('achilles:achilles-', '')}-${++n}`
    spawns.push({ subagentType, prompt: e.prompt, agentId, description: e.description, background: e.background })
    return { model: 'm', agentId }
  })
  on('fs.read', (_, e, next) => {
    if (e.path.endsWith('/agents') || /\/agents\/achilles-[a-z-]+\.md$/.test(e.path)) {
      const name = e.path.slice(e.path.lastIndexOf('/') + 1)
      return { value: AGENT_FILES[name] ?? '' }
    }
    // A file the plugin ships (its schemas) is served from the project fixture of the same relative path.
    const shipped = e.path.includes('/schemas/') && !e.path.startsWith(`${ROOT}/`) ? files.get(`${ROOT}${e.path.slice(e.path.indexOf('/schemas/'))}`) : undefined
    const held = files.get(e.path) ?? shipped
    return held === undefined ? next(e) : { value: held }
  })
  on('fs.write', (_, e) => {
    write(e.path, e.text, 1_700_000_000_000)
    writtenPaths.push(e.path)
    return { value: undefined }
  })
  on('fs.exists', (_, e) => ({ value: files.has(e.path) || dirs().has(e.path) }))
  on('fs.stat', (_, e, next) => {
    if (files.has(e.path)) return { value: { kind: 'file' as const, size: files.get(e.path)!.length, mtimeMs: mtimes.get(e.path) ?? 0, isLink: false, realPath: e.path } }
    if (dirs().has(e.path)) return { value: { kind: 'dir' as const, size: 0, mtimeMs: 0, isLink: false, realPath: e.path } }
    return next(e)
  })
  on('fs.list', (_, e) => {
    const dir = (e.path ?? ROOT).replace(/\/$/, '')
    if (dir.endsWith('/agents')) return { value: Object.keys(AGENT_FILES).map(name => ({ name, kind: 'file' as const, size: 1, mtimeMs: 0, isLink: false })) }
    const seen = new Map<string, FsEntry>()
    for (const [f, c] of files) {
      if (!f.startsWith(`${dir}/`)) continue
      const rest = f.slice(dir.length + 1)
      const name = rest.split('/')[0]!
      if (seen.has(name)) continue
      seen.set(name, rest.includes('/') ? { name, kind: 'dir', size: 0, mtimeMs: 0, isLink: false } : { name, kind: 'file', size: c.length, mtimeMs: mtimes.get(f) ?? 0, isLink: false })
    }
    return { value: [...seen.values()] }
  })
  on('process.run', (_, e) => {
    ran.push({ argv: [...e.argv], stdin: e.init?.stdin, cwd: e.init?.cwd })
    for (const p of procs) {
      const r = p(e.argv, e.init)
      if (r === undefined) continue
      const full = typeof r === 'string' ? { stdout: r } : r
      return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false, ...full } }
    }
    // The plugin's own node scanners answer clean unless a test answers them first.
    const clean = e.argv.some(a => a.endsWith('test-id-scan.js')) ? '{"untagged":[],"duplicates":[]}' : e.argv.some(a => a.endsWith('import-boundary-scan.js')) ? '{"scope":"tests","offenders":[]}' : e.argv.some(a => a.endsWith('validate.mjs')) ? '{"ok":true}' : e.argv.some(a => a.endsWith('archive-run.mjs')) ? '{"archived":false,"why":"no artefacts on disk"}' : undefined
    if (clean !== undefined) return { value: { exitCode: 0, stdout: clean, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    return { value: { exitCode: 127, stdout: '', stderr: `not mocked: ${e.argv.join(' ')}`, isStdoutTruncated: false, isStderrTruncated: false } }
  })
  return { files, mtimes, write, remove, procs, ran, spawns, prompts, status: () => status, written: () => writtenPaths, tools, agents, clock }
}

/** Starts a run through delegate_qa; the orchestrator's agent id is `orchestrator-<n>`. */
export async function startRun($: EngineInterface, h: Harness, task = 'verify the login flow'): Promise<string> {
  await $.tool.call({ tool: DELEGATE, task } as never)
  return h.spawns[h.spawns.length - 1]!.agentId
}

const SKILL_OF: Record<string, string> = { inspector: 'journey-mapping', author: 'test-composer', reviewer: 'review', 'doc-writer': 'qa-reporting' }

/** An expert spawn as the orchestrator's Agent tool raises it; the brief the prompt names is written first unless the test wrote one. */
export async function spawnExpert($: EngineInterface, h: Harness, role: string, parentAgentId: string, prompt = 'Read `.achilles/runs/x/briefs/b.md` first; write your report to `.achilles/runs/x/reports/b.md`.'): Promise<string> {
  const brief = /\.achilles\/runs\/[^\s`]+\/briefs\/[^\s`]+\.md/.exec(prompt)?.[0]
  if (brief && !h.files.has(`${ROOT}/${brief}`)) h.write(`${ROOT}/${brief}`, `# Brief\n\nLoad the \`${SKILL_OF[role] ?? 'review'}\` skill.\n`)
  const r = await $.agent.spawn({
    tool_use_id: `tu-${h.spawns.length + 1}`,
    prompt,
    description: `${role} task`,
    subagentType: `achilles-${role}`,
    provider: { plugin: 'engine', tier: 'core' },
    parentModel: 'm',
    background: false,
    fork: false,
    parentAgentId,
  } as never)
  return r.agentId ?? ''
}

export const ended = (agentId: string, answer: string, reason: 'answer' | 'aborted' | 'error' = 'answer') =>
  ({ answer, agentId, durationMs: 1, isAborted: reason === 'aborted', turnId: `t-${agentId}-${answer.length}`, reason }) as const

/** The advisory notes the adapter appended, by loop. */
export const notes = (session: { appended: () => readonly { door: string; agentId?: string; message: { content: unknown } }[] }, agentId?: string) =>
  session
    .appended()
    .filter(r => r.door === 'note' && (agentId === undefined || r.agentId === agentId))
    .map(r => (Array.isArray(r.message.content) ? r.message.content : []).map(b => (b as { text?: string }).text ?? '').join('\n'))
