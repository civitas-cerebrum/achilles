import type { EngineInterface, On, TurnCompleteInput } from 'claude-code'

import type { AchillesSelectorScope } from '../types'
import { afterContent, editRun, exists, isDisabled, isFrontendSource, note, placeFile, readText, run, who, type Who } from './context'
import { basename, within } from './posix'
import { commands } from './shell'

// Hook 7, selector development. An author on a selector brief may change application source by
// exactly one added inert test attribute on one opening tag; any other edit of an existing
// frontend file is refused (selector-diff-validator.js decides, in a node child). The eight-step
// pipeline is observed from the author's calls and kept as run state: the status line shows the
// step, an out-of-order step is a note, and a scope left open at the author's end is a note to
// the orchestrator with the revert line.

const REF = 'skills/selector-development/references/guardrail-pipeline.md'
const DIR = 'tests/e2e/.selector-development'
export const STEPS = ['before_snapshot', 'patch_applied', 'typecheck', 'unit_tests', 'e2e', 'after_snapshot', 'visual_diff', 'stage'] as const
type Step = (typeof STEPS)[number]

const onSelectorBrief = (w: Who) => w.role === 'author' && w.expert?.kind === 'selector'

/** The pipeline step a Bash command is, read off the parsed command. */
export function stepOf(command: string): Step | undefined {
  for (const c of commands(command).commands) {
    const a = c.args
    const line = a.join(' ')
    if (/^(playwright-cli|@playwright\/cli)$/i.test(a[0] ?? '') && a.includes('screenshot')) {
      if (line.includes('.selector-development/before/')) return 'before_snapshot'
      if (line.includes('.selector-development/after/')) return 'after_snapshot'
    }
    if (a[0] === 'tsc' && a.includes('--noEmit')) return 'typecheck'
    if ((a[0] === 'npm' || a[0] === 'pnpm' || a[0] === 'yarn') && /^(typecheck|lint:types)$/.test(a[a[1] === 'run' ? 2 : 1] ?? '')) return 'typecheck'
    if ((a[0] === 'npm' || a[0] === 'pnpm' || a[0] === 'yarn') && /^test:unit$|^unit$/.test(a[a[1] === 'run' ? 2 : 1] ?? '')) return 'unit_tests'
    if (a[0] === 'vitest' || a[0] === 'jest') return 'unit_tests'
    if (a[0] === 'playwright' && a[1] === 'test') return 'e2e'
    if (a.some(x => x.endsWith('visual-diff.js')) || a[0] === 'achilles-visual-diff') return 'visual_diff'
    if (a[0] === 'git' && a[1] === 'add') return 'stage'
  }
  return undefined
}

function record(scope: AchillesSelectorScope | undefined, name: Step, status: 'pass' | 'fail', file?: string): { scope: AchillesSelectorScope; outOfOrder?: string } {
  const s: AchillesSelectorScope = scope ?? { scope: 'selector', files: [], steps: [] }
  const idx = STEPS.indexOf(name)
  const done = s.steps.filter(x => x.status === 'pass').map(x => x.name)
  const missing = STEPS.slice(0, idx).filter(x => !done.includes(x))
  const failed = s.steps.find(x => x.status === 'fail')
  const outOfOrder = failed ? `step ${failed.name} failed; the pipeline stops there and reverts` : missing.length > 0 ? `${name} ran before ${missing.join(', ')}` : undefined
  return { scope: { ...s, files: file && !s.files.includes(file) ? [...s.files, file] : s.files, steps: [...s.steps, { name, status }] }, ...(outOfOrder ? { outOfOrder } : {}) }
}

async function convention($: EngineInterface, root: string): Promise<string> {
  const detected = ((await readText($, `${root}/${DIR}/.detected-convention`)) ?? '').trim()
  return /^[a-z][a-z0-9-]*$/.test(detected) ? detected : 'data-testid'
}

/** Called at an author's turn end (hooks.ts): a scope left between the patch and the visual diff gets the revert line. */
export async function closeSelectorScope($: EngineInterface, w: Who, _e: TurnCompleteInput) {
  const s = w.run.selector
  if (!s || !onSelectorBrief(w)) return
  const passed = s.steps.filter(x => x.status === 'pass').map(x => x.name)
  const last = passed[passed.length - 1]
  if (s.files.length > 0 && last !== 'visual_diff' && last !== 'stage')
    await note($, w.run.agentId, `the selector scope ${s.scope} ended after ${last ?? 'no passing step'} with an incomplete patch on ${s.files.join(', ')}. Revert it before anything else builds on it: git checkout -- ${s.files.join(' ')} (${REF} §"Revert path").`)
  await editRun($, w.run.id, r => {
    const { selector: _, ...rest } = r
    return rest
  })
}

export function registerSelector(on: On) {
  on('tool.call', { tool: ['Write', 'Edit'] }, async ($, e, next) => {
    if (isDisabled()) return next(e)
    const w = await who($, e.agentId)
    if (!w || !onSelectorBrief(w)) return next(e)
    const root = await $.session.cwd()
    const { abs, rel } = placeFile(root, e.file_path)
    if (!within(root, abs) || rel.startsWith('tests/') || !isFrontendSource(rel)) return next(e)
    if (!(await exists($, abs))) return next(e)
    const synth = await afterContent($, e, abs)
    if ('error' in synth) return { deny: `achilles: the edit of ${rel} does not apply to the file on disk (${synth.error}), so its inertness cannot be checked.` }
    const r = await run($, ['node', `${$.plugin.root}/claude-code/lib/selector-diff-validator.js`], { stdin: JSON.stringify({ before: synth.before, after: synth.after, expectedAttr: await convention($, root), filePath: basename(rel) }), timeoutMs: 7000 })
    let verdict: { ok?: boolean; reason?: string; detail?: string; attrValue?: string } | undefined
    try {
      verdict = r.ok && r.exitCode === 0 ? JSON.parse(r.stdout) : undefined
    } catch {
      verdict = undefined
    }
    if (!verdict) {
      await note($, e.agentId, `the inertness check of ${rel} could not run (${r.ok ? r.stderr.trim().split('\n')[0] || `exit ${r.exitCode}` : r.reason}); the edit went through unchecked, so review its diff before staging (${REF}).`)
      return next(e)
    }
    if (!verdict.ok)
      return { deny: `achilles: a selector brief changes application source by exactly one added inert test attribute on one opening tag; this edit of ${rel} is ${verdict.reason}${verdict.detail ? ` (${verdict.detail})` : ''}. Add only ${await convention($, root)}="<kebab-value>" to the target element and change nothing else (${REF}).` }
    const ran = await next(e)
    if (ran.deny === undefined) {
      const rec = record(w.run.selector ?? { scope: basename(w.expert?.brief ?? 'selector').replace(/\.md$/, ''), files: [], steps: [] }, 'patch_applied', ran.isError ? 'fail' : 'pass', rel)
      await editRun($, w.run.id, x => ({ ...x, selector: rec.scope }))
      if (rec.outOfOrder) await note($, e.agentId, `selector pipeline out of order: ${rec.outOfOrder} (${REF}).`)
    }
    return ran
  }).catch(($, e, next) => (next.called ? next(e) : { deny: 'achilles: its selector inertness check failed, so the edit is refused.' }))

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    if (isDisabled()) return next(e)
    const step = stepOf(e.command)
    if (!step) return next(e)
    const w = await who($, e.agentId)
    if (!w || !onSelectorBrief(w)) return next(e)
    const ran = await next(e)
    const rec = record(w.run.selector ?? { scope: basename(w.expert?.brief ?? 'selector').replace(/\.md$/, ''), files: [], steps: [] }, step, ran.deny !== undefined || ran.isError ? 'fail' : 'pass')
    await editRun($, w.run.id, x => ({ ...x, selector: rec.scope }))
    if (rec.outOfOrder) await note($, e.agentId, `selector pipeline out of order: ${rec.outOfOrder} (${REF}).`)
    return ran
  })
}
