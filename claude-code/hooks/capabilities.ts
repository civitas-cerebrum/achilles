// The capability-literal gate (part of hook 1's Write/Edit screens): a device's capabilities live
// only in tests/capabilities/<device>.json, the one file the inspection session and the test run
// both name. A platform spec, fixture, platform JSON file or the platform config that spells a
// capability out would make a second, drifting copy, so its Write or Edit is refused (bash-hook.ts
// registers it on Claude Code, pi/guards.ts on pi). Pure: no engine import, so pi can load it.
//
// Only a key whose value is a literal counts: a type annotation (`platformName: string`), a rename
// (`{ platformName: name }`) or a ternary branch is code reading capabilities, not a copy of them.
// Comments are stripped first. The e2e fixtures (web) are screened only for `appium:` keys and an
// inline `capabilities: {`, since their test data may carry words like `udid`.

const PLATFORM_REF = 'skills/platform-testing/SKILL.md'
const FORM = 'tests/capabilities/<device>.json'

type Scope = 'platform' | 'web-fixture'

/** Which screen a project-relative path gets, or undefined when it is not screened. */
export function capabilityScope(rel: string): Scope | undefined {
  if (/^tests\/platform\/docs\//.test(rel)) return undefined
  if (/^tests\/platform\/.+\.[cm]?[jt]sx?$/.test(rel)) return 'platform'
  if (/^tests\/platform\/.+\.json$/.test(rel) && !/(^|\/)page-repository\.json$/.test(rel)) return 'platform'
  if (/^playwright\.platform\.config\.[cm]?[jt]s$/.test(rel)) return 'platform'
  if (/^tests\/e2e\/fixtures\/.+\.[cm]?[jt]sx?$/.test(rel)) return 'web-fixture'
  return undefined
}

const isFixture = (rel: string) => /^tests\/(platform|e2e)\/fixtures\//.test(rel)

const CAPABILITY_KEYS = ['platformName', 'automationName', 'udid', 'bundleId', 'appPackage', 'appActivity']
const LITERAL = `\\s*:\\s*(?:["'\`\\d]|-\\d|true\\b|false\\b|null\\b|\\{|\\[)`
const KEY = new RegExp(`(?:^|[\\s{,(])(["'\`]?)(${CAPABILITY_KEYS.join('|')})\\1${LITERAL}`, 'm')
const APPIUM_KEY = /["'`](appium:[A-Za-z][\w.-]*)["'`]\s*:/
const INLINE = /\b((?:desired)?[cC]apabilities)["'`]?\s*:\s*\{/
const CAPS_VALUE = /\bcapabilities["'`]?\s*:\s*([^,}\n;]+)/g
const STRING = /(["'`])((?:(?!\1)[^\\\n]|\\.)*)\1/g
const CAPS_PATH = /^tests\/capabilities\/[A-Za-z0-9._-]+\.json$/
const LITERAL_VALUE = /:\s*(?:["'`\d]|-\d|true\b|false\b|null\b|\[)|["'`][^"'`\n]*["'`]\s*:/

/** An inline `capabilities: {…}` that holds a literal (a copy), not an object type or an empty object. */
function inlineCopy(text: string): string | undefined {
  for (const m of text.matchAll(new RegExp(INLINE.source, 'g'))) {
    const start = m.index! + m[0].length
    const end = text.indexOf('}', start)
    if (LITERAL_VALUE.test(text.slice(start, end < 0 ? undefined : end))) return m[1]
  }
  return undefined
}

/** The text without // and /* *\/ comments (a `//` inside a URL is kept). */
export function stripComments(text: string): string {
  return text.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/(^|[^:"'`\\])\/\/[^\n]*/g, '$1')
}

/** What capability literal the text carries for a screened file, or undefined. */
export function capabilityLiteral(rel: string, raw: string): string | undefined {
  const scope = capabilityScope(rel)
  if (scope === undefined) return undefined
  const text = stripComments(raw)
  const appium = APPIUM_KEY.exec(text)
  if (appium) return `the "${appium[1]}" key`
  const inline = inlineCopy(text)
  if (inline) return `an inline \`${inline}: {…}\` object`
  // A fixture's capabilities value is code (process.env.CAPABILITIES with or without a fallback, a
  // variable, a type) or a path to a capabilities file; a string naming anything else is a copy.
  if (isFixture(rel))
    for (const m of text.matchAll(CAPS_VALUE))
      for (const str of m[1]!.matchAll(STRING))
        if (!CAPS_PATH.test(str[2]!)) return `a capabilities value \`${m[1]!.trim()}\` naming "${str[2]}", which is not a '${FORM}' path`
  if (scope === 'web-fixture') return undefined
  const key = KEY.exec(text)
  if (key) return `the \`${key[2]}\` key with a literal value`
  return undefined
}

export const capabilityDeny = (rel: string, what: string) =>
  `achilles: ${rel} would carry a capability literal (${what}). Capabilities live only in ${FORM}; the run names that file with CAPABILITIES=${FORM} and the fixture reads it through session.capabilities (a file path, default process.env.CAPABILITIES). Move the value into the capabilities file.\n\nReferences:\n  ${PLATFORM_REF}`
