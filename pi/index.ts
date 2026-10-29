// The pi adapter: expert mode on pi. The main session delegates with delegate_qa or /achilles; the
// orchestrator and each expert run as their own `pi` process, set up from agents/achilles-<role>.md,
// the same definitions the Claude Code plugin registers. The orchestrator's process gets an Agent tool
// shaped like Claude Code's (subagent_type, prompt, description), so the skills read the same on both
// harnesses. Which tools a process registers follows ACHILLES_ROLE, set on every process this spawns;
// the orchestrator's and the experts' processes also run the guards (guards.ts).
import { spawn, type ChildProcess } from 'node:child_process'
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { Type } from '@earendil-works/pi-ai'
import type { ExtensionAPI, ExtensionContext } from '@earendil-works/pi-coding-agent'
import { registerGuards } from './guards'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const ORCHESTRATOR = 'achilles-orchestrator'
// Every other agents/achilles-<name>.md is an expert the orchestrator may dispatch.
const EXPERTS = readdirSync(join(ROOT, 'agents')).map(f => f.replace(/\.md$/, '')).filter(n => n.startsWith('achilles-') && n !== ORCHESTRATOR)
// Claude Code tool names in agents/*.md → pi's. Skills need no tool on pi: the model reads SKILL.md.
const TOOLS: Record<string, string[]> = { Read: ['read'], Write: ['write'], Edit: ['edit'], Bash: ['bash'], Grep: ['grep'], Glob: ['find', 'ls'], Agent: ['Agent'], Skill: [] }
const TERMINAL = /^(DONE|DONE_WITH_CONCERNS|NEEDS_CONTEXT|BLOCKED)\b/
const HANDBACK_LEAD = (id: string) =>
  `Achilles hand-back (run ${id}). Relay this to the person. If it is NEEDS_CONTEXT, ask them the numbered questions and re-delegate only with their answers and run ${id}.`

type Agent = { tools: string[]; skills: string[]; model?: string; effort?: string; prompt: string }

function agentFile(role: string): Agent {
  const m = readFileSync(join(ROOT, 'agents', `${role}.md`), 'utf8').match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/)
  if (!m) throw new Error(`agents/${role}.md has no frontmatter`)
  const field = (k: string) => m[1]!.match(new RegExp(`^${k}:\\s*(.*)$`, 'm'))?.[1]?.trim()
  const list = (k: string) => (field(k) ?? '').split(',').map(s => s.trim()).filter(Boolean)
  return { tools: list('tools').flatMap(t => TOOLS[t] ?? []), skills: list('skills'), model: field('model'), effort: field('effort'), prompt: m[2]!.trim() }
}

// The pi this process runs as, so a child uses the same install: pi's own CLI script under node,
// the compiled binary itself, else `pi` on PATH. Any other script is never re-run.
function piCommand(): [string, string[]] {
  const script = process.argv[1]
  if (script && /pi-coding-agent|[\\/]pi(\.[cm]?js)?$/.test(script) && existsSync(script)) return [process.execPath, [script]]
  return /^(node|bun)(\.exe)?$/.test(basename(process.execPath)) ? ['pi', []] : [process.execPath, []]
}

const children = new Set<ChildProcess>()
// The parent's thinking level, for an agent whose definition names no effort (set when the extension loads).
let parentThinking: () => string | undefined = () => undefined

/** Runs `role` on `prompt` in its own pi process and resolves to its final message, or a BLOCKED one. */
function runAgent(role: string, prompt: string, ctx: ExtensionContext, signal?: AbortSignal, run = process.env.ACHILLES_RUN): Promise<string> {
  const agent = agentFile(role)
  const dir = mkdtempSync(join(tmpdir(), 'achilles-pi-'))
  const system = join(dir, 'system.md')
  // A preloaded skill (the orchestrator's) goes into the system prompt whole, as Claude Code preloads it.
  const skills = agent.skills.map(s => readFileSync(join(ROOT, 'skills', s, 'SKILL.md'), 'utf8'))
  writeFileSync(system, [agent.prompt, ...skills].join('\n\n'), { mode: 0o600 })
  const model = agent.model && agent.model !== 'inherit' ? agent.model : ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : undefined
  // A child takes the parent's project-trust decision: print mode cannot ask, and an Achilles package
  // installed in the project loads only in a trusted one.
  const trust = ctx.isProjectTrusted() ? '--approve' : '--no-approve'
  // Thinking: the definition's effort (the experts other than the judge run at medium), else the
  // parent's level, so one run never mixes levels when the settings file changes under it.
  const thinking = agent.effort ?? parentThinking()
  const args = ['--mode', 'json', '-p', '--no-session', trust, '--tools', agent.tools.join(','), '--append-system-prompt', system, ...(model ? ['--model', model] : []), ...(thinking ? ['--thinking', thinking] : []), prompt]
  const [cmd, pre] = piCommand()
  return new Promise(resolve => {
    const proc = spawn(cmd, [...pre, ...args], { cwd: ctx.cwd, env: { ...process.env, ACHILLES_ROLE: role, ...(run ? { ACHILLES_RUN: run } : {}) }, stdio: ['ignore', 'pipe', 'pipe'] })
    children.add(proc)
    let text = ''
    let error = ''
    let stderr = ''
    let buffer = ''
    const line = (l: string) => {
      try {
        const e = JSON.parse(l)
        if (e.type !== 'message_end' || e.message?.role !== 'assistant') return
        const said = (e.message.content ?? []).filter((c: { type: string }) => c.type === 'text').map((c: { text: string }) => c.text).join('\n').trim()
        if (said) text = said
        if (e.message.errorMessage) error = String(e.message.errorMessage)
      } catch {}
    }
    proc.stdout!.on('data', d => {
      const lines = (buffer + d).split('\n')
      buffer = lines.pop() ?? ''
      lines.forEach(line)
    })
    proc.stderr!.on('data', d => { stderr = (stderr + d).slice(-2000) })
    const kill = () => proc.kill('SIGTERM')
    signal?.addEventListener('abort', kill, { once: true })
    proc.on('close', code => {
      if (buffer) line(buffer)
      children.delete(proc)
      signal?.removeEventListener('abort', kill)
      rmSync(dir, { recursive: true, force: true })
      resolve(code === 0 && text ? text : `BLOCKED\n${role} ended without a final message (${signal?.aborted ? 'aborted' : error || `exit code ${code}`}).${text ? `\nLast message:\n${text}` : ''}${stderr.trim() ? `\n${stderr.trim()}` : ''}`)
    })
    // A pi that cannot start (not on PATH, not executable) emits no close: answer here.
    proc.on('error', err => {
      children.delete(proc)
      rmSync(dir, { recursive: true, force: true })
      resolve(`BLOCKED\n${role} could not start: ${err.message}`)
    })
  })
}

// In the TUI and RPC modes the run goes on in the background and its hand-back arrives as a message
// of its own; print and JSON modes end with the prompt, so there the tool waits for the hand-back.
// A resumed run keeps its id and directory: the orchestrator reads its resume.json first.
const RUN_ID = /^[A-Za-z0-9][\w-]{0,63}$/
const active = new Set<string>()

async function delegate(pi: ExtensionAPI, ctx: ExtensionContext, task: string, context?: string, resume?: string): Promise<string> {
  if (task.trim() === '' && !resume) return 'NEEDS_CONTEXT\nNo task was given.'
  if (resume !== undefined) {
    if (!RUN_ID.test(resume)) return `NEEDS_CONTEXT\n"${resume}" is not a run id; pass the qa-… id a hand-back names.`
    if (active.has(resume)) return `BLOCKED\nRun ${resume} is still running; its hand-back arrives on its own.`
    if (!existsSync(join(ctx.cwd, '.achilles', 'runs', resume, 'resume.json'))) return `NEEDS_CONTEXT\nRun ${resume} has no .achilles/runs/${resume}/resume.json to resume from.`
  }
  const id = resume ?? `qa-${Date.now().toString(36)}`
  const dir = `.achilles/runs/${id}`
  if (task.trim() === '') task = `resume run ${id}`
  const lead = resume ? `Resume run ${id}: read ${dir}/resume.json before anything else and continue from where it stopped, in the same state directory.\n` : ''
  const prompt = `[achilles run=${id}]\n${lead}Run ${id}. State directory: ${dir}/ (briefs/<slug>.md, reports/<slug>.md, resume.json).\n\nTask: ${task}${context ? `\n\nContext:\n${context}` : ''}`
  active.add(id)
  const run = runAgent(ORCHESTRATOR, prompt, ctx, undefined, id).then(text => {
    active.delete(id)
    ctx.ui.setStatus('achilles', undefined)
    return `${HANDBACK_LEAD(id)}\n\nTask: ${task}\n\n${TERMINAL.test(text) ? text : `BLOCKED\nThe orchestrator ended without a hand-back word.\n${text}`}`
  })
  if (ctx.mode === 'print' || ctx.mode === 'json') return run
  ctx.ui.setStatus('achilles', `achilles ${id}: running`)
  void run.then(handback => pi.sendUserMessage(handback, { deliverAs: 'followUp' }))
  return `RUNNING ${id}\nThe Achilles orchestrator is working in the background (state under ${dir}/). Its hand-back arrives as a message of its own; there is nothing to wait on.`
}

export default function (pi: ExtensionAPI) {
  if (process.env.ACHILLES_DISABLE === '1') return
  parentThinking = () => pi.getThinkingLevel()
  const role = process.env.ACHILLES_ROLE || undefined
  pi.on('session_shutdown', () => children.forEach(c => c.kill('SIGTERM')))
  // A spawned orchestrator or expert ends with its parent: a parent killed outright (a signal, a
  // crash) runs no session_shutdown, and an orphan would go on working with nobody to hand back to.
  if (role !== undefined) {
    const parent = process.ppid
    pi.on('session_start', () => {
      setInterval(() => {
        try { process.kill(parent, 0) } catch { children.forEach(c => c.kill('SIGTERM')); process.exit(1) }
      }, 5000).unref()
    })
  }
  if (role !== undefined) registerGuards(pi, role, ROOT)

  if (role === undefined) {
    pi.registerTool({
      name: 'delegate_qa',
      label: 'Achilles',
      description: 'Delegate a quality-assurance task (verify, test, audit, repair, document) to the Achilles orchestrator. In an interactive session it returns at once and the hand-back arrives as a message of its own.',
      parameters: Type.Object({
        task: Type.String({ description: 'The QA task, in one or two sentences.' }),
        context: Type.Optional(Type.String({ description: 'Optional background: files, tickets, constraints, answers to earlier NEEDS_CONTEXT questions.' })),
        run: Type.Optional(Type.String({ description: 'Optional: resume an earlier run by the id its hand-back names (qa-…); its state under .achilles/runs/<id>/ is reused.' })),
      }),
      async execute(_id, params, _signal, _update, ctx) {
        return { content: [{ type: 'text', text: await delegate(pi, ctx, params.task, params.context, params.run || undefined) }], details: undefined }
      },
    })
    pi.registerCommand('achilles', {
      description: 'Delegate a QA task to the Achilles orchestrator, or resume a run: /achilles resume <run-id> [notes].',
      handler: async (args, ctx) => {
        const resume = /^resume\s+(\S+)\s*([\s\S]*)$/.exec((args ?? '').trim())
        const said = resume ? await delegate(pi, ctx, resume[2]!, undefined, resume[1]) : await delegate(pi, ctx, args ?? '')
        ctx.ui.notify(said.split('\n')[0]!, 'info')
      },
    })
  } else if (role === ORCHESTRATOR) {
    pi.registerTool({
      name: 'Agent',
      label: 'Achilles expert',
      description: `Dispatch one Achilles expert (${EXPERTS.join(', ')}) and wait for its final message. The prompt names the brief file and the report path.`,
      parameters: Type.Object({
        subagent_type: Type.String({ description: `One of ${EXPERTS.join(', ')}.` }),
        prompt: Type.String({ description: 'The brief path and the report path.' }),
        description: Type.Optional(Type.String({ description: 'A short label.' })),
      }),
      async execute(_id, params, signal, _update, ctx) {
        const expert = params.subagent_type.replace(/^achilles:/, '').replace(/^(?!achilles-)/, 'achilles-')
        if (!EXPERTS.includes(expert)) throw new Error(`Unknown expert "${params.subagent_type}". Dispatch one of ${EXPERTS.join(', ')}.`)
        const text = await runAgent(expert, params.prompt, ctx, signal)
        return { content: [{ type: 'text', text }], details: undefined }
      },
    })
  }
  // Experts register nothing: they dispatch nobody.
}
