import type { EngineInterface, On } from 'claude-code'

import { editRun, isDisabled, note, readJson, run, who, type Who } from './context'
import { commands } from './shell'

// Hook 8, reporting, all after the fact and never refusing: a Playwright run by an achilles loop
// is archived to .achilles/runs/<runId>/ when the Achilles reporter did not already claim it
// (claude-code/lib/archive-run.mjs, a node child); each expert's own playwright-cli and wdio
// session inspection sessions are closed when its turn ends; the run summary line rides in the
// hand-back (hooks.ts).

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

/**
 * Called at an expert's turn end, and at each of the orchestrator's (hooks.ts): its own browser
 * sessions and its own `wdio session` inspection sessions close with it, so a device is never held
 * past the turn that opened it.
 */
export async function closeSessions($: EngineInterface, w: Who) {
  const safe = (xs: string[] | undefined) => (xs ?? []).filter(s => /^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(s)).slice(0, 8)
  const slugs = safe(w.expert?.slugs)
  const wdio = safe(w.expert ? w.expert.wdio : w.run.wdio)
  if (slugs.length === 0 && wdio.length === 0) return
  // One child for every session, bounded, so the turn's end never waits past its budget. The
  // browser closes run in turn; each wdio close runs in the background, since ending an Appium
  // session on a device is slow and may hang: @wdio/session 10.2.0 waits up to 35 s for the daemon to
  // answer, then sends SIGTERM and waits up to 25 s more, then SIGKILL. The 40 s budget is a
  // deliberate give-up: past it the child is reported failed while the backgrounded close goes on.
  // The child fails when any close did not end its session. Exit 4 is SESSION_NOT_FOUND: no session
  // by that name is running, so the device is already free.
  const browser = slugs.map(s => `npx --no-install playwright-cli -s=${s} close >/dev/null 2>&1`).join('; ')
  const devices = wdio.length === 0 ? '' : `${wdio.map((s, i) => `(npx --no-install wdio session -s ${s} close >/dev/null 2>&1; c=$?; [ $c -eq 0 ] || [ $c -eq 4 ]) & p${i}=$!`).join('; ')}; s=0; ${wdio.map((_, i) => `wait $p${i} || s=1`).join('; ')}; exit $s`
  const r = await run($, ['sh', '-c', [browser, devices].filter(Boolean).join('; ')], { timeoutMs: wdio.length > 0 ? 40000 : 4000 })
  const owner = w.expert?.agentId ?? 'the orchestrator'
  if (!r.ok && slugs.length > 0) await note($, w.run.agentId, `the playwright-cli sessions of ${owner} (${slugs.join(', ')}) could not be closed (${r.reason}); close them with npx playwright-cli -s=<slug> close.`)
  if (wdio.length === 0) return
  const closed = r.ok && r.exitCode === 0
  const why = r.ok ? `exit ${r.exitCode}` : r.reason
  if (w.expert) {
    if (!closed) await note($, w.run.agentId, `the wdio inspection sessions of ${owner} (${wdio.join(', ')}) could not be closed (${why}), so the device may still be held; close them with npx wdio session -s <slug> close.`)
    return
  }
  // The orchestrator's names are kept until a close succeeds, so its next turn end tries again; after
  // two failed closes in a row a name is dropped, so a hung close cannot stall every orchestrator turn.
  let dropped: string[] = []
  await editRun($, w.run.id, x => {
    const fails = { ...(x.wdioFails ?? {}) }
    for (const n of wdio) fails[n] = closed ? 0 : (fails[n] ?? 0) + 1
    dropped = wdio.filter(n => fails[n]! >= 2)
    const gone = new Set(closed ? wdio : dropped)
    for (const n of gone) delete fails[n]
    // A dropped name stays reserved: the device may still be held under it, so no expert may take it.
    return { ...x, wdio: (x.wdio ?? []).filter(n => !gone.has(n)), wdioFails: fails, wdioDropped: [...new Set([...(x.wdioDropped ?? []), ...dropped])] }
  })
  if (closed) return
  const kept = wdio.filter(n => !dropped.includes(n))
  if (kept.length > 0) await note($, w.run.agentId, `your wdio inspection sessions (${kept.join(', ')}) could not be closed (${why}), so the device may still be held; the next turn end tries again, or close them with npx wdio session -s <slug> close.`)
  if (dropped.length > 0) await note($, w.run.agentId, `your wdio inspection session${dropped.length === 1 ? '' : 's'} ${dropped.join(', ')} failed to close twice in a row (${why}) and ${dropped.length === 1 ? 'is' : 'are'} no longer closed at turn end; the device may still be held. Free it by hand: npx wdio session -s ${dropped[0]} close, or stop the session on the Appium server.`)
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
