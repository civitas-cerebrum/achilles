import type { EngineInterface, On } from 'claude-code'

import { editRun, isDisabled, note, readJson, run, who, type Who } from './context'
import { commands } from './shell'

// Hook 8, reporting, all after the fact and never refusing: a Playwright run by an achilles loop
// is archived to .achilles/runs/<runId>/ when the Achilles reporter did not already claim it
// (claude-code/lib/archive-run.mjs, a node child); each expert's own playwright-cli sessions are
// closed when its turn ends; the run summary line rides in the hand-back (hooks.ts).

/** What a Bash line runs that is a Playwright run: the --output and JSON report it names, or undefined. */
export async function playwrightRun($: EngineInterface, command: string, root: string): Promise<{ output?: string; json?: string } | undefined> {
  const scripts = (await readJson<{ scripts?: Record<string, string> }>($, `${root}/package.json`))?.scripts ?? {}
  for (const c of commands(command).commands) {
    const a = c.args
    const npmScript = (a[0] === 'npm' || a[0] === 'pnpm' || a[0] === 'yarn') && (a[1] === 'run' || a[1] === 'test') ? scripts[a[1] === 'run' ? (a[2] ?? '') : 'test'] : undefined
    const isRun = (a[0] === 'playwright' && a[1] === 'test') || a[0] === 'achilles-self-repair' || (a[0] === 'node' && (a[1] ?? '').endsWith('bin/self-repair.mjs')) || (npmScript !== undefined && /playwright test|achilles-self-repair/.test(npmScript))
    if (!isRun) continue
    const out = a.find(x => x.startsWith('--output='))?.slice(9) ?? (a.includes('--output') ? a[a.indexOf('--output') + 1] : undefined)
    const json = c.assign.find(x => x.startsWith('PLAYWRIGHT_JSON_OUTPUT_NAME='))?.slice('PLAYWRIGHT_JSON_OUTPUT_NAME='.length)
    return { ...(out ? { output: out } : {}), ...(json ? { json } : {}) }
  }
  return undefined
}

/** Called at an expert's turn end (hooks.ts): its own browser sessions close with it. */
export async function closeSessions($: EngineInterface, w: Who) {
  const slugs = (w.expert?.slugs ?? []).filter(s => /^[A-Za-z0-9_-]+$/.test(s)).slice(0, 8)
  if (slugs.length === 0) return
  // One child for every session, bounded, so the turn's end never waits past its budget.
  const r = await run($, ['sh', '-c', slugs.map(s => `npx --no-install playwright-cli -s=${s} close >/dev/null 2>&1`).join('; ')], { timeoutMs: 4000 })
  if (!r.ok) await note($, w.run.agentId, `the playwright-cli sessions of ${w.expert!.agentId} (${slugs.join(', ')}) could not be closed (${r.reason}); close them with npx playwright-cli -s=<slug> close.`)
}

export function registerReporting(on: On) {
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    if (isDisabled()) return next(e)
    const w = await who($, e.agentId)
    if (!w) return next(e)
    const root = await $.session.cwd()
    const pw = await playwrightRun($, e.command, root)
    const ran = await next(e)
    if (!pw || ran.deny !== undefined) return ran
    const argv = ['node', `${$.plugin.root}/claude-code/lib/archive-run.mjs`, root, ...(pw.output ? ['--output', pw.output] : []), ...(pw.json ? ['--json', pw.json] : []), '--trigger', w.role]
    const r = await run($, argv, { cwd: root, timeoutMs: 8000 })
    let out: { archived?: boolean; why?: string; runId?: string; skipped?: unknown[]; pruned?: string[]; incomplete?: boolean } = {}
    try {
      out = r.ok ? JSON.parse(r.stdout) : {}
    } catch {
      out = {}
    }
    if (!r.ok || r.exitCode !== 0) await note($, e.agentId, `the run's artefacts could not be archived (${r.ok ? r.stderr.trim().split('\n')[0] || `exit ${r.exitCode}` : r.reason}); copy anything you need out of the output directory before the next run wipes it.`)
    else if (out.archived) {
      await editRun($, w.run.id, x => ({ ...x, archived: (x.archived ?? 0) + 1 }))
      const said = [
        out.incomplete ? 'some files could not be copied, so the run is not marked archived and the next run retries' : '',
        (out.skipped ?? []).length > 0 ? `${out.skipped!.length} trace/video file(s) were skipped over ACHILLES_ARTIFACT_MAX_MB` : '',
        (out.pruned ?? []).length > 0 ? `older runs pruned past ACHILLES_ARTIFACT_RETAIN: ${out.pruned!.join(', ')}` : '',
      ].filter(Boolean)
      if (said.length > 0) await note($, e.agentId, `the run's artefacts are archived under .achilles/runs/${out.runId}/; ${said.join('; ')}.`)
    }
    return ran
  })
}
