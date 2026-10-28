// The pi adapter: expert mode on pi. The main session delegates with delegate_qa or /achilles; the
// orchestrator and each expert run as their own `pi` process, set up from agents/achilles-<role>.md,
// the same definitions the Claude Code plugin registers. The orchestrator's process gets an Agent tool
// shaped like Claude Code's (subagent_type, prompt, description), so the skills read the same on both
// harnesses. Which tools a process registers follows ACHILLES_ROLE, set on every process this spawns.
import { spawn, type ChildProcess } from 'node:child_process'
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { Type } from '@earendil-works/pi-ai'
import type { ExtensionAPI, ExtensionContext } from '@earendil-works/pi-coding-agent'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const ORCHESTRATOR = 'achilles-orchestrator'
// Every other agents/achilles-<name>.md is an expert the orchestrator may dispatch.
const EXPERTS = readdirSync(join(ROOT, 'agents')).map(f => f.replace(/\.md$/, '')).filter(n => n.startsWith('achilles-') && n !== ORCHESTRATOR)
// Claude Code tool names in agents/*.md → pi's. Skills need no tool on pi: the model reads SKILL.md.
const TOOLS: Record<string, string[]> = { Read: ['read'], Write: ['write'], Edit: ['edit'], Bash: ['bash'], Grep: ['grep'], Glob: ['find', 'ls'], Agent: ['Agent'], Skill: [] }
const TERMINAL = /^(DONE|DONE_WITH_CONCERNS|NEEDS_CONTEXT|BLOCKED)\b/
const HANDBACK_LEAD = (id: string) =>
  `Achilles hand-back (run ${id}). Relay this to the person. If it is NEEDS_CONTEXT, ask them the numbered questions and re-delegate only with their answers.`

type Agent = { tools: string[]; skills: string[]; model?: string; prompt: string }

function agentFile(role: string): Agent {
  const m = readFileSync(join(ROOT, 'agents', `${role}.md`), 'utf8').match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/)
  if (!m) throw new Error(`agents/${role}.md has no frontmatter`)
  const field = (k: string) => m[1]!.match(new RegExp(`^${k}:\\s*(.*)$`, 'm'))?.[1]?.trim()
  const list = (k: string) => (field(k) ?? '').split(',').map(s => s.trim()).filter(Boolean)
  return { tools: list('tools').flatMap(t => TOOLS[t] ?? []), skills: list('skills'), model: field('model'), prompt: m[2]!.trim() }
}

// The pi this process runs as, so a child uses the same install: pi's own CLI script under node,
// the compiled binary itself, else `pi` on PATH. Any other script is never re-run.
function piCommand(): [string, string[]] {
  const script = process.argv[1]
  if (script && /pi-coding-agent|[\\/]pi(\.[cm]?js)?$/.test(script) && existsSync(script)) return [process.execPath, [script]]
  return /^(node|bun)(\.exe)?$/.test(basename(process.execPath)) ? ['pi', []] : [process.execPath, []]
}

const children = new Set<ChildProcess>()

/** Runs `role` on `prompt` in its own pi process and resolves to its final message, or a BLOCKED one. */
function runAgent(role: string, prompt: string, ctx: ExtensionContext, signal?: AbortSignal): Promise<string> {
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
  const args = ['--mode', 'json', '-p', '--no-session', trust, '--tools', agent.tools.join(','), '--append-system-prompt', system, ...(model ? ['--model', model] : []), prompt]
  const [cmd, pre] = piCommand()
  return new Promise(resolve => {
    const proc = spawn(cmd, [...pre, ...args], { cwd: ctx.cwd, env: { ...process.env, ACHILLES_ROLE: role }, stdio: ['ignore', 'pipe', 'pipe'] })
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
  })
}

// In the TUI and RPC modes the run goes on in the background and its hand-back arrives as a message
// of its own; print and JSON modes end with the prompt, so there the tool waits for the hand-back.
async function delegate(pi: ExtensionAPI, ctx: ExtensionContext, task: string, context?: string): Promise<string> {
  if (task.trim() === '') return 'NEEDS_CONTEXT\nNo task was given.'
  const id = `qa-${Date.now().toString(36)}`
  const dir = `.achilles/runs/${id}`
  const prompt = `[achilles run=${id}]\nRun ${id}. State directory: ${dir}/ (briefs/<slug>.md, reports/<slug>.md, resume.json).\n\nTask: ${task}${context ? `\n\nContext:\n${context}` : ''}`
  const run = runAgent(ORCHESTRATOR, prompt, ctx).then(text => {
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
  const role = process.env.ACHILLES_ROLE || undefined
  pi.on('session_shutdown', () => children.forEach(c => c.kill('SIGTERM')))

  if (role === undefined) {
    pi.registerTool({
      name: 'delegate_qa',
      label: 'Achilles',
      description: 'Delegate a quality-assurance task (verify, test, audit, repair, document) to the Achilles orchestrator. In an interactive session it returns at once and the hand-back arrives as a message of its own.',
      parameters: Type.Object({
        task: Type.String({ description: 'The QA task, in one or two sentences.' }),
        context: Type.Optional(Type.String({ description: 'Optional background: files, tickets, constraints, answers to earlier NEEDS_CONTEXT questions.' })),
      }),
      async execute(_id, params, _signal, _update, ctx) {
        return { content: [{ type: 'text', text: await delegate(pi, ctx, params.task, params.context) }], details: undefined }
      },
    })
    pi.registerCommand('achilles', {
      description: 'Delegate a QA task to the Achilles orchestrator.',
      handler: async (args, ctx) => ctx.ui.notify((await delegate(pi, ctx, args ?? '')).split('\n')[0]!, 'info'),
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
