import type { EngineInterface, Register } from 'claude-code'

import type { AchillesRun } from './types'
import { registerBashJudge } from './hooks/bash-judge'
import { dispatchAdvice } from './hooks/dispatch'
import { registerHygiene } from './hooks/hygiene'
import { registerLedger } from './hooks/ledger'
import { PANE, registerPane, rememberHandback } from './hooks/pane'
import { closeSessions, registerReporting } from './hooks/reporting'
import { registerReturnTracking, reviewReturn } from './hooks/returns'
import { closeSelectorScope, registerSelector } from './hooks/selector'
import { recordReceipt, registerSignoff } from './hooks/signoff'
import { EXPERTS, ORCHESTRATOR, editRun, isDisabled, note, readRuns, roleOf, setDisabled, whoIs, writeRuns } from './hooks/context'

// The Claude Code adapter of the Achilles methodology. The main session is never bound:
// QA work enters through delegate_qa or /achilles, which start the orchestrator agent in
// the background and answer at once; the orchestrator dispatches its experts with the
// Agent tool and waits for them as any Agent call does; its hand-back reaches the main
// session as a prompt of its own. The agent types are the plugin's agents/*.md, the one
// source for every harness; this module registers them from those files at session start
// (a hooks-module reload does not re-read a plugin's agents folder; a registration does).
// The guards live under hooks/, one file each; this file is registration, runs and hand-back.

// The bare spelling the agent definitions use ("the Agent tool's type achilles-author"),
// rewritten at agent.spawn to the plugin-qualified name the engine dispatches.
const BARE = /^achilles-(orchestrator|inspector|author|reviewer|doc-writer)$/
const DELEGATE = 'mcp__achilles__delegate_qa'
const OFF = 'BLOCKED\nAchilles is switched off in this session (ACHILLES_DISABLE=1).'

// The orchestrator's prompt opens with this line and the agent.spawn hook reads it back, so
// the run learns its loop's id whether the plugin's own spawn answered it (the engine does)
// or only the hook chain saw it (the test kit).
const MARK = /^\[achilles run=([\w-]+)\]/
// A turn of the orchestrator's is its hand-back only when it opens with a status word: a
// turn that ended while a background expert still ran is not.
const TERMINAL = /^(DONE|DONE_WITH_CONCERNS|NEEDS_CONTEXT|BLOCKED)\b/

const ROUTE_NOTE =
  'Note from the Achilles orchestration: that agent is one of the Achilles experts, which the Achilles orchestrator briefs and reads back. QA work is better routed through delegate_qa (or /achilles): the orchestrator preflights, writes the brief, dispatches the right experts and hands back one verdict.'
const HANDBACK_LEAD = (id: string) =>
  `Achilles hand-back (run ${id}). Relay this to the person. If it is NEEDS_CONTEXT, ask them the numbered questions and re-delegate only with their answers.`

const text = (t: string) => ({ type: 'text', text: t })

// ── agents/*.md: frontmatter (name, description, tools, skills, model) and the prompt ──

type AgentFile = { name: string; description: string; prompt: string; tools?: string[]; skills?: string[]; model?: string }

function parseAgent(source: string): AgentFile | undefined {
  const m = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/.exec(source)
  if (!m) return undefined
  const fields: Record<string, string | string[]> = {}
  let last: string | undefined
  for (const line of m[1]!.split(/\r?\n/)) {
    const kv = /^([A-Za-z][\w-]*):\s*(.*)$/.exec(line)
    if (kv) {
      last = kv[1]!
      fields[last] = kv[2]!.trim().replace(/^(["'])(.*)\1$/, '$2')
      continue
    }
    const item = /^\s*-\s+(.*)$/.exec(line)
    if (item && last !== undefined) {
      const held = fields[last]
      fields[last] = [...(Array.isArray(held) ? held : held ? [held] : []), item[1]!.trim().replace(/^(["'])(.*)\1$/, '$2')]
    }
  }
  const list = (v: string | string[] | undefined) =>
    v === undefined ? undefined : (Array.isArray(v) ? v : v.replace(/^\[|\]$/g, '').split(',')).map(s => s.trim()).filter(Boolean)
  const name = fields.name
  const description = fields.description
  if (typeof name !== 'string' || name === '' || typeof description !== 'string' || description === '') return undefined
  const model = fields.model
  return {
    name,
    description,
    prompt: m[2]!.trim(),
    tools: list(fields.tools),
    skills: list(fields.skills),
    ...(typeof model === 'string' && model !== '' ? { model } : {}),
  }
}

async function registerAgents($: EngineInterface) {
  const dir = `${$.plugin.root}/agents`
  for (const entry of await $.fs.list(dir)) {
    if (entry.kind !== 'file' || !entry.name.endsWith('.md')) continue
    const agent = parseAgent(String(await $.fs.read(`${dir}/${entry.name}`)))
    if (!agent) continue
    const { tools, skills, ...spec } = agent
    await $.agent.register({ ...spec, ...(tools ? { tools } : {}), ...(skills ? { skills } : {}) })
  }
}

// ── runs: delegate, hand back ──

async function delegate($: EngineInterface, task: string, context?: string, fromAgent?: string): Promise<string> {
  if (task.trim() === '') return 'NEEDS_CONTEXT\nNo task was given.'
  if (whoIs(await readRuns($), fromAgent)) return 'BLOCKED\ndelegate_qa is the main session’s door; inside a run the orchestrator dispatches experts with the Agent tool.'
  const id = `qa-${(await $.clock.now()).toString(36)}`
  const run: AchillesRun = { id, task, dir: `.achilles/runs/${id}`, experts: [] }
  await writeRuns($, runs => [...runs, run])
  const prompt = `[achilles run=${id}]\nRun ${id}. State directory: ${run.dir}/ (briefs/<slug>.md, reports/<slug>.md, resume.json).\n\nTask: ${task}${context ? `\n\nContext:\n${context}` : ''}`
  const spawned = await $.agent.spawn({ subagentType: ORCHESTRATOR, prompt, description: `achilles ${id}` })
  if (spawned.deny !== undefined) {
    await writeRuns($, runs => runs.filter(r => r.id !== id))
    return `BLOCKED\nThe Achilles orchestrator could not start: ${spawned.deny}`
  }
  if (spawned.agentId !== undefined) await editRun($, id, r => ({ ...r, agentId: r.agentId ?? spawned.agentId }))
  return `RUNNING ${id}\nThe Achilles orchestrator is working in the background (state under ${run.dir}/). Its hand-back arrives as a message of its own; there is nothing to wait on.`
}

function summary(run: AchillesRun): string {
  const dispatched = Object.entries(run.dispatched ?? {})
  const parts = [
    dispatched.length === 0 ? 'no experts dispatched' : `experts dispatched: ${dispatched.map(([role, n]) => `${role} ×${n}`).join(', ')}`,
    run.archived ? `playwright runs archived under .achilles/runs/: ${run.archived}` : '',
    run.judge && run.judge.consecutive > 0 ? `judge loop left open (${run.judge.consecutive} consecutive improvements-needed)` : '',
    run.selector ? `selector scope ${run.selector.scope} left at step ${run.selector.steps.length}/8` : '',
  ].filter(Boolean)
  return `Run summary: ${parts.join('; ')}.`
}

async function handBack($: EngineInterface, run: AchillesRun, body: string) {
  await writeRuns($, runs => runs.filter(r => r.id !== run.id))
  await rememberHandback($, run.id, run.task, body)
  await $.prompt.submit({ text: `${HANDBACK_LEAD(run.id)}\n\nTask: ${run.task}\n\n${body}\n\n${summary(run)}` })
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.tool.register({
      name: 'delegate_qa',
      description: 'Delegate a quality-assurance task (verify, test, audit, repair, document) to the Achilles orchestrator. Returns at once; the hand-back arrives as a message of its own.',
      inputSchema: {
        type: 'object',
        properties: {
          task: { type: 'string', description: 'The QA task, in one or two sentences.' },
          context: { type: 'string', description: 'Optional background: files, tickets, constraints, answers to earlier NEEDS_CONTEXT questions.' },
        },
        required: ['task'],
      },
      isDeferred: false,
    })
    await $.command.register({ name: 'achilles', description: 'Delegate a QA task to the Achilles orchestrator; with no task, open the Achilles pane.', argumentHint: '[task]' })
    await registerAgents($)
    setDisabled((await $.env.get('ACHILLES_DISABLE')) === '1')
    const runs = await readRuns($)
    await writeRuns($, () => runs)
    return next(e)
  })

  on('tool.call', { tool: DELEGATE }, async ($, e) => {
    if (isDisabled()) return { result: OFF }
    const { task, context } = e as unknown as { task?: unknown; context?: unknown }
    return { result: await delegate($, typeof task === 'string' ? task : '', typeof context === 'string' ? context : undefined, e.agentId) }
  }).catch(($, e, next) => (next.called ? next(e) : { result: `BLOCKED\nThe delegate_qa hook failed before the orchestrator started: ${next.error?.message ?? 'unknown error'}.` }))

  // `/achilles <task>` delegates; `/achilles` alone opens the pane.
  on('command.run', { command: 'achilles' }, async ($, e) => {
    if (e.args.trim() === '') {
      await $.ui.open({ id: PANE, title: 'Achilles' })
      return { text: 'Achilles pane opened: runs in flight, their experts and the last hand-back.' }
    }
    return { text: isDisabled() ? OFF : await delegate($, e.args) }
  })

  // Every spawn goes through. A bare achilles-<role> type is rewritten to the plugin's name;
  // the orchestrator's own spawn (marked prompt) is tied to its run; an expert spawned from
  // an orchestrator's loop (parentAgentId, absent on the main loop) is counted in that run;
  // an expert spawned from anywhere else gets a note about the door.
  on('agent.spawn', async ($, e, next) => {
    if (isDisabled()) return next(e)
    const subagentType = BARE.test(e.subagentType) ? `achilles:${e.subagentType}` : e.subagentType
    const parent = EXPERTS.includes(subagentType) ? whoIs(await readRuns($), e.parentAgentId) : undefined
    const advice = parent?.role === 'orchestrator' ? await dispatchAdvice($, e, roleOf(subagentType), parent) : undefined
    const rewritten = { ...e, subagentType, ...(advice ? { prompt: advice.prompt } : {}), ...(advice?.background === false ? { background: false } : {}) }
    const started = await next(advice || subagentType !== e.subagentType ? rewritten : e)
    for (const n of advice?.notes ?? []) await note($, e.parentAgentId, n)
    const m = MARK.exec(e.prompt)
    if (m && started.agentId !== undefined) {
      const agentId = started.agentId
      await editRun($, m[1]!, r => ({ ...r, agentId: r.agentId ?? agentId }))
      return started
    }
    if (!EXPERTS.includes(subagentType)) return started
    if (parent?.role === 'orchestrator') {
      if (started.agentId !== undefined) {
        const role = roleOf(subagentType)
        const expert = { agentId: started.agentId, role, ...advice?.fields }
        await editRun($, parent.run.id, r => ({ ...r, experts: [...r.experts, expert], dispatched: { ...r.dispatched, [role]: (r.dispatched?.[role] ?? 0) + 1 } }))
      }
    } else if (started.deny === undefined) {
      await $.session.append({ ...(e.parentAgentId === undefined ? {} : { agentId: e.parentAgentId }), message: { type: 'user', content: [text(ROUTE_NOTE)] } })
    }
    return started
  }).catch(($, e, next) => next(e))

  on('turn.complete', async ($, e, next) => {
    if (isDisabled()) return next(e)
    const w = whoIs(await readRuns($), e.agentId)
    if (!w) return next(e)
    if (w.role === 'orchestrator') {
      if (e.reason === 'answer') {
        const first = e.answer.split('\n').find(l => l.trim() !== '')?.trim() ?? ''
        if (!TERMINAL.test(first)) {
          await writeRuns($, runs => runs)
          return next(e)
        }
        await handBack($, w.run, e.answer)
      } else {
        await handBack($, w.run, `BLOCKED\nThe orchestrator's run ended by ${e.reason === 'aborted' ? 'an interruption' : e.reason === 'error' ? 'an API error' : 'a model refusal'} before it handed back; its state is under ${w.run.dir}/.`)
      }
    } else {
      // An expert's end: it leaves the run first, so a slow guard below can never keep it
      // counted; then the guards read its hand-back side by side, inside one budget.
      await editRun($, w.run.id, r => ({ ...r, experts: r.experts.filter(x => x.agentId !== e.agentId) }))
      await Promise.all([
        ...(e.reason === 'answer' ? [reviewReturn($, w, e), recordReceipt($, w, e)] : []),
        closeSelectorScope($, w, e),
        closeSessions($, w),
      ])
    }
    return next(e)
  })

  registerBashJudge(on)
  registerLedger(on)
  registerSignoff(on)
  registerReturnTracking(on)
  registerHygiene(on)
  registerSelector(on)
  registerReporting(on)
  registerPane(on)
}
