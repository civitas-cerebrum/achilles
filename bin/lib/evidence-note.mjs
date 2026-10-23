// evidence-note.mjs — the selector evidence note written by selector-evidence.mjs.
//
// One note per repository entry: <evidence dir>/<Page>.<element>.md. The note is a contract, not a log: the
// repository-evidence gate reads exactly two of its lines —
//
//   - selector: <JSON>   must deep-equal the entry's selector in page-repository.json (key order irrelevant)
//   - source: <kind>     must be present (live | legacy-inspection <path> | live-run (exercised by <file:line>))
//
// — so a note left behind by a changed selector is refused, and a hand-written note without a source is refused.
// See skills/achilles-protocol/references/selector-evidence.md#the-note.
//
// This module is pure (node:fs and node:path only). It never imports Playwright, so the count-check seam
// (resolveAndCheck) can be driven with a fake locator.
import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import * as path from 'node:path'
import { projectRoot, rulesPath } from './project-root.mjs'

export const TOOL_VERSION = '1.0'
export const RULE_ID = 'selectors.evidence'
export const DOC = 'skills/achilles-protocol/references/selector-evidence.md'

const SCHEMA = new URL('../../hooks/data/factory-rules.schema.json', import.meta.url)

/** Where notes live when the rule omits `evidenceDir`: the schema's `default`, which repository-evidence-gate.sh reads too. */
export const DEFAULT_EVIDENCE_DIR = JSON.parse(readFileSync(SCHEMA, 'utf8')).$defs.selectorsEvidence.properties.evidenceDir.default

/** The project's factory rules file (see lib/project-root.mjs). Missing file → {}. */
export function loadFactoryRules(root = projectRoot()) {
  const file = rulesPath(root)
  if (!existsSync(file)) return {}
  try {
    return JSON.parse(readFileSync(file, 'utf8'))
  } catch (e) {
    fail(`${path.relative(root, file)} is not valid JSON: ${e.message}`, 'Fix the rules file, or unset FACTORY_RULES.', 'config-and-contexts', 2)
  }
}

/** Prints the three-line message `[rule-id] what / → Do: … / → Why/how: doc#anchor` to stderr and exits (1 = evidence refused, 2 = usage or configuration). */
export function fail(what, action, anchor, code = 1) {
  process.stderr.write(`[${RULE_ID}] ${what}\n→ Do: ${action}\n→ Why/how: ${DOC}#${anchor}\n`)
  process.exit(code)
}

/** Emails → <redacted-email>; any remaining '@' → ' at ' (a tag such as @checkout survives readably). */
export function redact(text) {
  return String(text ?? '')
    .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}/gi, '<redacted-email>')
    .replace(/@/g, ' at ')
}

/** Replaces id/token path segments (long hex ids, opaque tokens with a digit) with <id>. Query and hash are dropped. */
export const cleanPath = (p) =>
  String(p)
    .split('/')
    .map((s) => (/^[0-9a-f]{16,}$/i.test(s) || /^(?=.*\d)[A-Za-z0-9_-]{20,}$/.test(s) ? '<id>' : s))
    .join('/')

const oneLine = (s) => String(s).replace(/\s+/g, ' ').trim()

/**
 * Renders a note. `n` = { key, selector, context, url, date, tool, count, list, meta: { tag, role, name, dataAttrs },
 * aria, screenshot, source } — missing fields render as "—".
 */
export function renderNote(n) {
  const d = (v) => (v === undefined || v === null || v === '' ? '—' : v)
  const lines = [
    `# ${n.key}`,
    `- selector: ${JSON.stringify(n.selector)}`,
    `- context: ${d(n.context)} · url: ${d(n.url)} · date: ${d(n.date)} · tool: ${d(n.tool)}`,
  ]
  const m = n.meta ?? {}
  lines.push(
    `- resolved count: ${d(n.count)}${n.list ? ' (list entry)' : ''} · tag: ${d(m.tag)} · role: ${d(m.role)} · ` +
      `name: ${m.name ? JSON.stringify(oneLine(m.name)) : '—'} · data-attribute: ${d(m.dataAttrs)}`,
  )
  lines.push(`- aria snippet: ${n.aria ? '`' + oneLine(n.aria).replace(/`/g, "'").slice(0, 300) + '`' : '—'}`)
  lines.push(`- screenshot: ${d(n.screenshot)}`)
  lines.push(`- source: ${n.source}`)
  return lines.join('\n') + '\n'
}

/**
 * Renders and validates a note: a `source` is required, and no line but `- selector:` may contain '@'. Throws
 * before any write, so a refusal leaves the committed note alone.
 *
 * The '@' rule guards against personal data (an address read off a live page) reaching a committed file, so it covers
 * the observed fields (accessible name, data attributes, aria snippet, url) but not the selector line: the selector
 * is the project's own committed value and the gate requires the note to carry it back verbatim. The error names the
 * offending line.
 */
export function validateNote(n) {
  if (!n.source) { const e = new Error(`refusing to write the ${n.key} note: it has no source`); e.code = NOTE_REFUSED; throw e }
  const text = renderNote(n)
  const offending = text.split('\n').find((line) => line.includes('@') && !line.startsWith('- selector:'))
  if (offending !== undefined) {
    const err = new Error(`refusing to write the ${n.key} note: ${JSON.stringify(oneLine(offending).slice(0, 120))} contains '@' (personal data?)`)
    err.code = NOTE_REFUSED
    throw err
  }
  return text
}

/**
 * Marks an error as "the note was refused", as opposed to anything that went wrong reaching the page. A caller that
 * cannot tell them apart reports a refusal as a resolution failure and sends the agent to fix the --url and the
 * frame when the selector resolved perfectly well.
 */
export const NOTE_REFUSED = 'NOTE_REFUSED'

export function writeNoteText(file, text) {
  mkdirSync(path.dirname(file), { recursive: true })
  writeFileSync(file, text)
  return text
}

/**
 * The count check on a resolved locator — the seam a fake locator can drive. Exactly one match, or at least one
 * for an entry marked "list": true. Returns { ok: true, count } or { ok: false, count, what, action }; the caller
 * prints the three-line message. `frameTitles` (optional async fn) names the iframes present when a framed entry
 * resolves to 0. The locator needs only first().waitFor(), count() and evaluateAll().
 */
export async function resolveAndCheck(locator, { key, list = false, where = '', framed = false, frameTitles, timeout = 30_000 } = {}) {
  await locator.first().waitFor({ state: 'attached', timeout }).catch(() => {})
  const count = await locator.count()
  if (list ? count >= 1 : count === 1) return { ok: true, count }
  const on = where ? ` on ${where}` : ''
  if (count === 0) {
    const titles = framed && frameTitles ? await frameTitles() : []
    const frames = framed ? ` (iframe titles present: ${titles.length ? titles.map((t) => JSON.stringify(t)).join(', ') : 'none'})` : ''
    return {
      ok: false,
      count,
      what: `${key} resolved to 0 elements${on}${frames}`,
      action: 'Open a --url where the element is rendered, or fix the selector through live inspection, then re-run.',
    }
  }
  const candidates = await locator
    .evaluateAll((ns) =>
      ns.slice(0, 8).map((n) => {
        const a = [...n.attributes].find((x) => x.name.startsWith('data-'))
        return a ? `${a.name}=${a.value}` : n.tagName.toLowerCase()
      }),
    )
    .catch(() => [])
  return {
    ok: false,
    count,
    what: `${key} resolved to ${count} elements${on}${candidates.length ? ` (candidates: ${candidates.join(', ')})` : ''}`,
    action: 'Tighten the selector until exactly one element matches (or mark a genuine list entry "list": true), then re-run.',
  }
}
