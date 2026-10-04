// evidence-note.mjs — the selector evidence note, shared by selector-evidence.mjs (live) and any backfill tool a
// project writes for entries that predate the convention.
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

export const TOOL_VERSION = '1.0'
export const RULE_ID = 'selectors.evidence'
export const DOC = 'skills/achilles-protocol/references/selector-evidence.md'

/**
 * Where notes live when `evidenceDir` is absent from the rule. The authoritative copy of this string is the
 * `default` of `rules.selectors.evidence.evidenceDir` in hooks/data/factory-rules.schema.json; this constant and
 * repository-evidence-gate.sh's own fallback restate it, and scripts/lint-doc-drift.mjs fails when any of them,
 * or the two reference docs, drift apart.
 *
 * `evidenceDir` is schema-OPTIONAL, so the default is load-bearing, and the gate and the tool have to agree on it
 * to the character. They did not: the gate looked in `docs/evidence/selectors` while this tool wrote to
 * `tests/e2e/docs/evidence/selectors`. For a project that omits the field that is a permanent deny loop — the agent
 * runs achilles-selector-evidence, the note lands where the gate never looks, the gate denies the same write again
 * and its action tells the agent to run the tool it has just run. There is no way out of it from inside the session.
 */
export const DEFAULT_EVIDENCE_DIR = 'docs/evidence/selectors'

/** The project's factory rules file: $FACTORY_RULES, else achilles-factory-rules.json. Missing file → {}. */
export function loadFactoryRules(cwd = process.cwd()) {
  const file = path.resolve(cwd, process.env.FACTORY_RULES || 'achilles-factory-rules.json')
  if (!existsSync(file)) return {}
  try {
    return JSON.parse(readFileSync(file, 'utf8'))
  } catch (e) {
    fail(`${path.relative(cwd, file)} is not valid JSON: ${e.message}`, 'Fix the rules file, or unset FACTORY_RULES.', 'config-and-contexts', 2)
  }
}

/** The three-line message every factory tool prints: [rule-id] what / → Do: … / → Why/how: doc#anchor. */
export function formatMessage(what, action, anchor = 'the-sequence') {
  return `[${RULE_ID}] ${what}\n→ Do: ${action}\n→ Why/how: ${DOC}#${anchor}`
}

/** Prints the three-line message to stderr and exits (1 = evidence refused, 2 = usage or configuration). */
export function fail(what, action, anchor, code = 1) {
  process.stderr.write(formatMessage(what, action, anchor) + '\n')
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
 * aria, screenshot, source, record, legacySource, live } — missing fields render as "—".
 * A note without `count` is a backfill note: it says so instead of pretending the tool resolved it.
 */
export function renderNote(n) {
  const d = (v) => (v === undefined || v === null || v === '' ? '—' : v)
  const lines = [
    `# ${n.key}`,
    `- selector: ${JSON.stringify(n.selector)}`,
    `- context: ${d(n.context)} · url: ${d(n.url)} · date: ${d(n.date)} · tool: ${d(n.tool)}`,
  ]
  if (n.count !== undefined) {
    const m = n.meta ?? {}
    lines.push(
      `- resolved count: ${n.count}${n.list ? ' (list entry)' : ''} · tag: ${d(m.tag)} · role: ${d(m.role)} · ` +
        `name: ${m.name ? JSON.stringify(oneLine(m.name)) : '—'} · data-attribute: ${d(m.dataAttrs)}`,
    )
    lines.push(`- aria snippet: ${n.aria ? '`' + oneLine(n.aria).replace(/`/g, "'").slice(0, 300) + '`' : '—'}`)
  } else {
    lines.push('- resolved count: — (backfill note: not re-resolved by the tool)')
  }
  if (n.record !== undefined) lines.push(`- legacy record: ${JSON.stringify(oneLine(n.record).slice(0, 700))}`)
  if (n.legacySource !== undefined) lines.push(`- legacy source: ${n.legacySource}`)
  if (n.live !== undefined) lines.push(`- live-observed: ${n.live}`)
  lines.push(`- screenshot: ${d(n.screenshot)}`)
  lines.push(`- source: ${n.source}`)
  return lines.join('\n') + '\n'
}

/** Renders and validates a note: a `source` is required and the text may not contain '@'. Throws before any write. */
export function validateNote(n) {
  if (!n.source) throw new Error(`refusing to write the ${n.key} note: it has no source`)
  const text = renderNote(n)
  if (text.includes('@')) throw new Error(`refusing to write the ${n.key} note: its text contains '@' (personal data?)`)
  return text
}

export function writeNoteText(file, text) {
  mkdirSync(path.dirname(file), { recursive: true })
  writeFileSync(file, text)
  return text
}

export const writeNote = (file, n) => writeNoteText(file, validateNote(n))

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
