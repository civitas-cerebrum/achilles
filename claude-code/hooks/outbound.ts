import type { On } from 'claude-code'

import { ATTRIBUTION, FRAMING, OUTBOUND_REF, REFS, isReport, strings, unreachableDeny, unreachableFiles } from './attribution'
import { isDisabled, note, placeFile, who } from './context'
import { within } from './posix'

// The two outbound surfaces of the AI-signature rule (attribution.ts holds the detector): an
// outbound MCP write and a report document written to disk, in an Achilles agent's loop only.

/** A tool name that writes outward rather than reads. */
const WRITES = /create|edit|update|save|add|comment|transition|publish|post|send|reply|upload|schedule/i
const READS = /^(get|list|search|read|fetch|lookup|view|query|discover)/i

export function registerOutbound(on: On) {
  on('tool.call', { tool: /^mcp__/ }, async ($, e, next) => {
    if (isDisabled()) return next(e)
    const name = e.tool.split('__').pop() ?? e.tool
    if (READS.test(name) || !WRITES.test(name)) return next(e)
    const w = await who($, e.agentId)
    if (!w) return next(e)
    const text = strings(e).join('\n')
    if (ATTRIBUTION.test(text))
      return { deny: `achilles: an AI signature (Co-Authored-By: Claude …, Claude-Session:, "Generated with Claude Code", a claude.ai/code link) in an outbound message is refused: tickets, comments, pages and messages an Achilles agent sends carry none. Remove it and send again.${REFS}` }
    const unreachable = await unreachableFiles($, text)
    if (unreachable.length > 0) return { deny: unreachableDeny('this outbound message', unreachable) }
    const framed = FRAMING.exec(text)
    if (framed) await note($, e.agentId, `this outbound message reads as an agent's output ("${framed[0]}"); write it as the QA work itself, with no agent framing or harness internals (${OUTBOUND_REF}).`)
    return next(e)
  }).catch(($, e, next) => next(e))

  on('tool.call', { tool: ['Write', 'Edit'] }, async ($, e, next) => {
    if (isDisabled()) return next(e)
    const w = await who($, e.agentId)
    if (!w) return next(e)
    const root = await $.session.cwd()
    const { abs, rel } = placeFile(root, e.file_path)
    if (!within(root, abs) || !isReport(rel)) return next(e)
    const args = e as unknown as { content?: unknown; new_string?: unknown }
    const text = [args.content, args.new_string].filter((x): x is string => typeof x === 'string').join('\n')
    if (ATTRIBUTION.test(text))
      return { deny: `achilles: an AI signature (Co-Authored-By: Claude …, Claude-Session:, "Generated with Claude Code", a claude.ai/code link) in the report ${rel} is refused: reports carry none. Remove it and write again.${REFS}` }
    return next(e)
  }).catch(($, e, next) => next(e))
}
