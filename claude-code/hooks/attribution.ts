import type { On } from 'claude-code'

import { isDisabled, note, placeFile, who } from './context'
import { within } from './posix'

// No AI signature on anything that leaves the run (skills/achilles-orchestrator/references/outbound-text.md):
// one detector shared by the Bash judge (commits, gh pr and gh issue text) and the two surfaces
// registered here: an outbound MCP write (a tracker ticket or comment, a page, a chat message) and
// a report document written to disk. A signature is refused; agent framing in an outbound message
// is a note. The main loop is never touched.

export const OUTBOUND_REF = 'skills/achilles-orchestrator/references/outbound-text.md'

/** An AI signature: an AI co-author trailer, a session link, a "generated with" footer. */
export const ATTRIBUTION =
  /(^|['"\s])\s*co-authored-by:.*(claude|anthropic|noreply@anthropic\.com)|generated with.*claude(\s+code)?\b|claude\.ai\/code|(^|['"\s])\s*claude-session:|🤖\s*generated/i

/** Agent framing: the text presents itself as an agent's output or names the harness's internals. */
export const FRAMING =
  /\bas an ai\b|\bai (qa )?agent\b|\blanguage model\b|\bsub-?agents?\b|\bachilles[- ](orchestrator|agent|expert|run|inspector|author|reviewer|reproducer|doc-writer)\b|\byou are an? (independent )?(qa )?(reproducer|agent|expert)\b/i

const REFS = `\n\nReferences:\n  ${OUTBOUND_REF}`

/** A tool name that writes outward rather than reads. */
const WRITES = /create|edit|update|save|add|comment|transition|publish|post|send|reply|upload|schedule/i
const READS = /^(get|list|search|read|fetch|lookup|view|query|discover)/i

/** Every string inside a tool call's arguments, flattened. */
export function strings(value: unknown, out: string[] = [], depth = 0): string[] {
  if (depth > 6) return out
  if (typeof value === 'string') out.push(value)
  else if (Array.isArray(value)) for (const v of value) strings(v, out, depth + 1)
  else if (value && typeof value === 'object') for (const [k, v] of Object.entries(value)) if (k !== 'agentId' && k !== 'tool') strings(v, out, depth + 1)
  return out
}

/** A document that is a report someone else will read: docs, run docs, evidence summaries, decks and catalogues. */
export const isReport = (rel: string) =>
  /^docs\//.test(rel) || /^tests\/e2e\/docs\/[^.][^/]*\.md$/.test(rel) || /(^|\/)evidence\/.+\/summary\.md$/.test(rel) || /^(qa-summary-deck|test-catalogue)\.(html|md)$/.test(rel)

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
