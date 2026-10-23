// The one secrets screen, two surfaces: the factory rule secrets.none over written content, and
// the HAR / console-log scan the sign-off hook runs over an evidence bundle. Values are never
// echoed: a finding names the field or quotes three characters.

import { inScope } from './posix'
import { strings } from './context'

export type SecretRule = { scope?: unknown; patterns?: unknown; allowlist?: unknown; action?: unknown; doc?: unknown }

/** secrets.none: the first secret-shaped value `text` writes into `rel`, or undefined. */
export function contentSecret(rule: SecretRule, rel: string, text: string): { what: string } | undefined {
  const scope = strings(rule.scope)
  const patterns = strings(rule.patterns)
  if (scope.length === 0 || patterns.length === 0 || text === '') return undefined
  if (!inScope(rel, scope)) return undefined
  const literals: string[] = []
  for (const a of strings(rule.allowlist)) {
    if (a.endsWith('/')) {
      if (rel.startsWith(a)) return undefined
    } else if (rel === a) return undefined
    else literals.push(a.toLowerCase())
  }
  for (const p of patterns) {
    let re: RegExp
    try {
      re = new RegExp(p, 'g')
    } catch {
      continue
    }
    for (const m of text.matchAll(re)) {
      const hit = m[0]
      if (hit === '') continue
      const low = hit.toLowerCase()
      if (literals.some(l => low.includes(l))) continue
      return { what: `contains a secret-shaped value \`${hit.slice(0, 3)}…\` (pattern ${p}).` }
    }
  }
  return undefined
}

const PLACEHOLDER = /redacted|\*\*\*|<removed>|\[hidden\]|xxxxx|<[a-z_-]+>/i
const NAME = /^(cookie|set-cookie|apikey|x-apikey)$|(^|[-_])(authorization|auth|bypass|token|jwt|secret|credential|password|passwd|api[-_]?key)([-_]|$)/
const BODY = /(access[_-]?token|refresh[_-]?token|id[_-]?token|client[_-]?secret|api[_-]?key|password|passwd|secret[_-]?key|private[_-]?key)"?'?[ \t]*[:=][ \t]*["']?[^"'\s,;}]{6,}/gi
const PAIR = /(^|[;,\s])([A-Za-z0-9_.-]*[-_])?(authorization|auth|bypass|token|jwt|secret|credential|password|passwd|api[-_]?key)([-_][A-Za-z0-9_.-]*)?\s*=[^;]+/gi
const CONSOLE = [/authorization[ \t]*[:=][ \t]*(bearer|basic|token)[ \t]+[^\s"]+/gi, /(protection|deployment)[-_]?bypass["']?[ \t]*[:=][ \t]*["']?[^\s",;}]{6,}/gi, BODY]

const live = (v: unknown) => typeof v === 'string' && v.length > 0 && !PLACEHOLDER.test(v)

/** The credential-bearing fields of a HAR that carry a live value, each named (never its value). */
export function harFindings(text: string): string[] {
  let doc: unknown
  try {
    doc = JSON.parse(text)
  } catch {
    return /"(authorization|set-cookie|cookie)"|bypass|api[-_]?key|[-_]token"/i.test(text) ? ['unparseable as JSON and contains credential-bearing field names'] : []
  }
  const out = new Set<string>()
  const judge = (name: string, value: unknown) => {
    if (typeof value !== 'string') return
    if (live(value)) {
      out.add(`field \`${name}\` carries a live value (value withheld)`)
      return
    }
    for (const m of value.matchAll(PAIR)) {
      const pair = m[0]
      if (PLACEHOLDER.test(pair)) continue
      const key = pair.split('=')[0]!.replace(/^[^A-Za-z0-9_]+/, '').toLowerCase()
      out.add(`field \`${name}\`, pair \`${key}\` carries a live value (value withheld)`)
    }
  }
  const visit = (node: unknown, depth: number) => {
    if (depth > 24 || node === null || typeof node !== 'object') return
    if (Array.isArray(node)) {
      for (const x of node) visit(x, depth + 1)
      return
    }
    const obj = node as Record<string, unknown>
    if (typeof obj.name === 'string' && 'value' in obj && NAME.test(obj.name.toLowerCase())) judge(obj.name.toLowerCase(), obj.value)
    for (const [k, v] of Object.entries(obj)) {
      if (typeof v === 'string' && NAME.test(k.toLowerCase())) judge(k.toLowerCase(), v)
      visit(v, depth + 1)
    }
  }
  visit(doc, 0)
  const log = (doc as { log?: { entries?: unknown } })?.log
  for (const entry of Array.isArray(log?.entries) ? log!.entries : []) {
    const e = entry as { request?: { postData?: { text?: unknown } }; response?: { content?: { text?: unknown } } }
    for (const body of [e.request?.postData?.text, e.response?.content?.text]) {
      if (typeof body !== 'string') continue
      for (const m of body.matchAll(BODY)) if (!PLACEHOLDER.test(m[0])) out.add('a credential-shaped assignment in a request/response body carries a live value (value withheld)')
    }
  }
  return [...out]
}

/** A console log is unstructured: each occurrence is judged on its own, so a placeholder earlier on the line vouches for nothing after it. */
export function consoleFinding(text: string): string | undefined {
  for (const re of CONSOLE) {
    for (const m of text.matchAll(re)) if (!PLACEHOLDER.test(m[0])) return 'a credential-shaped assignment carries a live value (value withheld)'
  }
  return undefined
}
