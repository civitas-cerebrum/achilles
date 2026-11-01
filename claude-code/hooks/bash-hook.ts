import type { On } from 'claude-code'

import { judgeBash } from './bash-judge'
import { contentSecret } from './secrets'
import { editExpert, factoryRules, isDisabled, note, placeFile, ruleOf, threeLine, who, writtenText } from './context'

// The Bash judge and the secrets screen on Claude Code's tool.call, for the Achilles agents' loops.
// The judge itself (bash-judge.ts) touches no run state, so the pi adapter runs it too.

export function registerBashJudge(on: On) {
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    if (isDisabled()) return next(e)
    const w = await who($, e.agentId)
    if (!w) return next(e)
    const v = await judgeBash($, e.command, w)
    if (v.deny !== undefined) return { deny: `achilles: ${v.deny}` }
    const slugs = v.notes.filter(n => n.startsWith('__slug:')).map(n => n.slice(7))
    const notes = v.notes.filter(n => !n.startsWith('__slug:'))
    if (w.expert && slugs.some(s => !(w.expert!.slugs ?? []).includes(s))) {
      const agentId = w.expert.agentId
      await editExpert($, w.run.id, agentId, x => ({ ...x, slugs: [...new Set([...(x.slugs ?? []), ...slugs])] }))
    }
    for (const n of notes) await note($, e.agentId, n)
    return next(v.command === e.command ? e : { ...e, command: v.command })
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
