// The guards on pi: the Claude Code adapter's Bash judge (claude-code/hooks/bash-judge.ts) and its
// secrets screen, run on pi's tool_call in the orchestrator's and the experts' processes. The judge
// reaches the host through a few nouns of Claude Code's `$`; this file answers them from Node. A
// deny blocks the call; a rewrite (the playwright-cli session flag) edits the input in place; a
// note is appended to the tool's result for the model to read.
import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import type { EngineInterface } from 'claude-code'
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent'
import { judgeBash } from '../claude-code/hooks/bash-judge'
import { factoryRules, placeFile, ruleOf, threeLine } from '../claude-code/hooks/io'
import { contentSecret } from '../claude-code/hooks/secrets'
import type { Who } from '../claude-code/hooks/context'

function engine(root: string, pluginRoot: string): EngineInterface {
  const $ = {
    session: { cwd: async () => root },
    env: { get: async (k: string) => process.env[k] },
    plugin: { root: pluginRoot },
    fs: { read: (p: string) => readFile(p, 'utf8'), exists: async (p: string) => existsSync(p) },
    process: {
      run: (argv: string[], o: { cwd?: string; stdin?: string; timeoutMs?: number; env?: Record<string, string> } = {}) =>
        new Promise((resolve, reject) => {
          const p = spawn(argv[0]!, argv.slice(1), { cwd: o.cwd ?? root, env: { ...process.env, ...o.env }, timeout: o.timeoutMs })
          let stdout = ''
          let stderr = ''
          p.stdout.on('data', d => (stdout += d))
          p.stderr.on('data', d => (stderr += d))
          p.on('error', reject)
          p.on('close', code => resolve({ stdout, stderr, exitCode: code ?? 1 }))
          p.stdin.end(o.stdin ?? '')
        }),
    },
  }
  return $ as unknown as EngineInterface
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

  pi.on('tool_call', async (e, ctx) => {
    const $ = engine(ctx.cwd, pluginRoot)
    const input = e.input as { command?: string; path?: string; content?: string; edits?: { newText: string }[] }
    if (e.toolName === 'bash' && typeof input.command === 'string') {
      const command = input.command
      const v = await judgeBash($, command, w).catch(() => ({ deny: 'its Bash judge failed, so the call is refused.', notes: [] as string[], command }))
      if (v.deny !== undefined) return { block: true, reason: `achilles: ${v.deny}` }
      if (v.command !== command) input.command = v.command
      const said = v.notes.filter(n => !n.startsWith('__slug:'))
      if (said.length > 0) notes.set(e.toolCallId, said)
      return
    }
    if ((e.toolName === 'write' || e.toolName === 'edit') && typeof input.path === 'string') {
      const rule = ruleOf(await factoryRules($, ctx.cwd), 'secrets.none')
      if (!rule) return
      const text = e.toolName === 'write' ? (input.content ?? '') : (input.edits ?? []).map(x => x.newText).join('\n')
      const { rel } = placeFile(ctx.cwd, input.path)
      const hit = contentSecret(rule, rel, text)
      if (hit) return { block: true, reason: `achilles: ${threeLine('secrets.none', `${e.toolName === 'write' ? 'Write to' : 'Edit of'} ${rel} ${hit.what}`, typeof rule.action === 'string' ? rule.action : undefined, typeof rule.doc === 'string' ? rule.doc : undefined)}` }
    }
  })

  pi.on('tool_result', e => {
    const said = notes.get(e.toolCallId)
    if (!said) return
    notes.delete(e.toolCallId)
    return { content: [...e.content, ...said.map(n => ({ type: 'text' as const, text: `achilles: ${n}` }))] }
  })
}
