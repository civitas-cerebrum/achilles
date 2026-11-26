import type { On } from 'claude-code'

import { judgeBash } from './bash-judge'
import { contentSecret } from './secrets'
import { recordShellWrites } from './compliance-notes'
import { editExpert, factoryRules, isDisabled, note, placeFile, ruleOf, threeLine, who, writtenText } from './context'

// The Bash judge and the secrets screen on Claude Code's tool.call, for the Achilles agents' loops.
// The judge itself (bash-judge.ts) touches no run state, so the pi adapter runs it too.

// An Achilles agent's run ends when its turn ends: a command left running in the background is cut off
// or its result never reaches the report, and the orchestrator is then made to hand back mid-run. So a
// background Bash call from an Achilles loop is refused, with the way to run it in the foreground.
export const BACKGROUND_DENY =
  'achilles: an Achilles agent\'s run ends with its turn, so a command left in the background is lost and its result never reaches your report. ' +
  'Run it in the foreground (Bash timeout up to 600000 ms). Split anything longer into calls that each finish within about 9 minutes: ' +
  'one spec file or `--grep` slice per call, one mutation pass per call, `--repeat-each` per test rather than per file.'

export function registerBashJudge(on: On) {
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    if (isDisabled()) return next(e)
    const w = await who($, e.agentId)
    if (!w) return next(e)
    if (e.run_in_background === true) return { deny: BACKGROUND_DENY }
    const v = await judgeBash($, e.command, w)
    if (v.deny !== undefined) return { deny: `achilles: ${v.deny}` }
    const slugs = v.notes.filter(n => n.startsWith('__slug:')).map(n => n.slice(7))
    const notes = v.notes.filter(n => !n.startsWith('__slug:'))
    if (w.expert && slugs.some(s => !(w.expert!.slugs ?? []).includes(s))) {
      const agentId = w.expert.agentId
      await editExpert($, w.run.id, agentId, x => ({ ...x, slugs: [...new Set([...(x.slugs ?? []), ...slugs])] }))
    }
    for (const n of notes) await note($, e.agentId, n)
    const ran = await next(v.command === e.command ? e : { ...e, command: v.command })
    // Record only: the test files the command wrote join the run's touched list.
    if ((v.writes ?? []).length > 0 && ran.deny === undefined && e.agentId !== undefined) await recordShellWrites($, w, e.agentId, v.writes!).catch(() => undefined)
    return ran
  }).catch(($, e, next) => (next.called ? next(e) : { deny: 'achilles: its Bash judge failed, so the call is refused.' }))

  // The factory rule secrets.none: a credential or PII shape never lands in a committed file. Hook 1 owns this deny.
  on('tool.call', { tool: ['Write', 'Edit'] }, async ($, e, next) => {
    if (isDisabled()) return next(e)
    const w = await who($, e.agentId)
    if (!w) return next(e)
    const root = await $.session.cwd()
    const rules = await factoryRules($, root)
    const rule = ruleOf(rules, 'secrets.none')
    if (!rule) return next(e)
    const { rel } = placeFile(root, e.file_path)
    const hit = contentSecret(rule, rel, writtenText(e))
    if (!hit) return next(e)
    return { deny: `achilles: ${threeLine('secrets.none', `${e.tool === 'Write' ? 'Write to' : 'Edit of'} ${rel} ${hit.what}`, typeof rule.action === 'string' ? rule.action : undefined, typeof rule.doc === 'string' ? rule.doc : undefined)}` }
  }).catch(($, e, next) => (next.called ? next(e) : { deny: 'achilles: its secrets screen failed, so the write is refused.' }))
}
