// The guards on pi: the Claude Code adapter's Bash judge (claude-code/hooks/bash-judge.ts) and its
// secrets screen, run on pi's tool_call in the orchestrator's and the experts' processes. The judge
// reaches the host through a few nouns of Claude Code's `$`; this file answers them from Node. A
// deny blocks the call; a rewrite (the playwright-cli session flag) edits the input in place; a
// note is appended to the tool's result for the model to read. A bash call with no timeout gets one
// (pi's has no default, and one command that never returns holds the expert, the orchestrator
// and the main session with it): ACHILLES_PI_BASH_TIMEOUT seconds, 600 by default, as Claude Code caps.
import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import type { EngineInterface } from 'claude-code'
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent'
import { judgeBash } from '../claude-code/hooks/bash-judge'
import { factoryRules, placeFile, ruleOf, threeLine } from '../claude-code/hooks/io'
import { contentSecret } from '../claude-code/hooks/secrets'
import type { Who } from '../claude-code/hooks/context'
import { shellRecorder, writeRecorder, type Settle } from './compliance'

export function engine(root: string, pluginRoot: string): EngineInterface {
  const $ = {
    session: { cwd: async () => root },
    env: { get: async (k: string) => process.env[k] },
    plugin: { root: pluginRoot },
    fs: { read: (p: string) => readFile(p, 'utf8'), exists: async (p: string) => existsSync(p) },
    process: {
      run: (argv: string[], o: { cwd?: string; stdin?: string; timeoutMs?: number; env?: Record<string, string> } = {}) =>
        new Promise((resolve, reject) => {
          const p = spawn(argv[0]!, argv.slice(1), { cwd: o.cwd ?? root, env: { ...process.env, ...o.env } })
          let stdout = ''
          let stderr = ''
          let settled = false
          const finish = (f: () => void) => {
            if (settled) return
            settled = true
            if (timer) clearTimeout(timer)
            f()
          }
          // The wait is a bound: past it the child is killed outright and the call fails, even when the child
          // ignores SIGTERM or a grandchild still holds its pipes.
          const timer = o.timeoutMs
            ? setTimeout(() => {
                p.kill('SIGKILL')
                p.stdout.destroy()
                p.stderr.destroy()
                finish(() => reject(new Error(`timed out after ${o.timeoutMs} ms`)))
              }, o.timeoutMs)
            : undefined
          p.stdout.on('data', d => (stdout += d))
          p.stderr.on('data', d => (stderr += d))
          p.on('error', err => finish(() => reject(err)))
          p.on('close', code => finish(() => resolve({ stdout, stderr, exitCode: code ?? 1 })))
          // A child that exits before reading all of a large stdin closes the pipe: EPIPE is not this process's death.
          p.stdin.on('error', () => undefined)
          p.stdin.end(o.stdin ?? '')
        }),
    },
  }
  return $ as unknown as EngineInterface
}

const BASH_TIMEOUT = Number(process.env.ACHILLES_PI_BASH_TIMEOUT) || 600
const STATE_JSON = /^(tests\/(e2e|perf)\/docs|\.achilles)\/.*\.json$/

const parseError = (text: string) => {
  try {
    JSON.parse(text)
    return undefined
  } catch (err) {
    return err instanceof Error ? err.message : String(err)
  }
}

/** The file's text after pi's edit (each oldText replaced once); undefined when it cannot be read. */
async function edited(abs: string, edits: { oldText?: string; newText: string }[]): Promise<string | undefined> {
  const before = await readFile(abs, 'utf8').catch(() => undefined)
  if (before === undefined) return undefined
  return edits.reduce((text, x) => (typeof x.oldText === 'string' ? text.replace(x.oldText, () => x.newText) : text), before)
}

export function registerGuards(pi: ExtensionAPI, role: string, pluginRoot: string) {
  const short = role.replace(/^achilles-/, '')
  const runId = process.env.ACHILLES_RUN ?? 'pi'
  const w: Who = {
    run: { id: runId, task: '', dir: `.achilles/runs/${runId}`, agentId: runId, experts: [] },
    role: short,
    ...(short === 'orchestrator' ? {} : { expert: { agentId: `${short}-${process.pid}`, role: short } }),
  } as Who
  const notes = new Map<string, string[]>()
  const settles = new Map<string, Settle>()

  pi.on('tool_call', async (e, ctx) => {
    const $ = engine(ctx.cwd, pluginRoot)
    const input = e.input as { command?: string; timeout?: number; path?: string; content?: string; edits?: { oldText?: string; newText: string }[] }
    if (e.toolName === 'bash' && typeof input.command === 'string') {
      const command = input.command
      const v = await judgeBash($, command, w).catch(() => ({ deny: 'its Bash judge failed, so the call is refused.', notes: [] as string[], command }))
      if (v.deny !== undefined) return { block: true, reason: `achilles: ${v.deny}` }
      if (v.command !== command) input.command = v.command
      if (typeof input.timeout !== 'number' || input.timeout <= 0) input.timeout = BASH_TIMEOUT
      const said = v.notes.filter(n => !n.startsWith('__slug:'))
      if (said.length > 0) notes.set(e.toolCallId, said)
      // Record only: a failure here never blocks the call (pi turns a handler's throw into a refusal).
      try {
        const shell = shellRecorder($, ctx.cwd, runId, short, ('writes' in v ? v.writes : undefined) ?? [])
        if (shell) settles.set(e.toolCallId, shell)
      } catch {}
      return
    }
    if ((e.toolName === 'write' || e.toolName === 'edit') && typeof input.path === 'string') {
      const { abs, rel } = placeFile(ctx.cwd, input.path)
      try {
        const landed = e.toolName === 'write' ? (input.content ?? '') : await edited(abs, input.edits ?? [])
        const settle = landed === undefined ? undefined : await writeRecorder($, ctx.cwd, runId, short, abs, landed)
        if (settle) settles.set(e.toolCallId, settle)
      } catch {}
      // Run state the orchestrator and the gates read back (ledgers, cycle and coverage state,
      // resume files) must stay parseable: a write or edit that breaks one is refused.
      if (STATE_JSON.test(rel)) {
        const after = e.toolName === 'write' ? (input.content ?? '') : await edited(abs, input.edits ?? [])
        const broken = after === undefined ? undefined : parseError(after)
        if (broken) return { block: true, reason: `achilles: this ${e.toolName} would leave ${rel} unparseable (${broken}); run state is read back by the gates and on resume, so write it as valid JSON.` }
      }
      const rule = ruleOf(await factoryRules($, ctx.cwd), 'secrets.none')
      if (!rule) return
      const text = e.toolName === 'write' ? (input.content ?? '') : (input.edits ?? []).map(x => x.newText).join('\n')
      const hit = contentSecret(rule, rel, text)
      if (hit) return { block: true, reason: `achilles: ${threeLine('secrets.none', `${e.toolName === 'write' ? 'Write to' : 'Edit of'} ${rel} ${hit.what}`, typeof rule.action === 'string' ? rule.action : undefined, typeof rule.doc === 'string' ? rule.doc : undefined)}` }
    }
  })

  pi.on('tool_result', async e => {
    const settle = settles.get(e.toolCallId)
    settles.delete(e.toolCallId)
    const more = settle ? await settle((e as { isError?: boolean }).isError === true).catch(() => [] as string[]) : []
    const said = [...(notes.get(e.toolCallId) ?? []), ...more]
    if (said.length === 0) return
    notes.delete(e.toolCallId)
    return { content: [...e.content, ...said.map(n => ({ type: 'text' as const, text: `achilles: ${n}` }))] }
  })
}
