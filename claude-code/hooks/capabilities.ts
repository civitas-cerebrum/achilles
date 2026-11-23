// The capability-literal gate (part of hook 1's Write/Edit screens): a device's capabilities live
// only in tests/capabilities/<device>.json, the one file the inspection session and the test run
// both name. A platform spec, a fixture or the platform config that spells a capability out would
// make a second, drifting copy, so its Write or Edit is refused (bash-hook.ts registers it on
// Claude Code, pi/guards.ts on pi). Pure: no engine import, so pi can load it.

const PLATFORM_REF = 'skills/platform-testing/SKILL.md'

/** The files screened: code under tests/platform/, the e2e fixtures and the platform config. */
export const screensCapabilities = (rel: string) =>
  (/^tests\/platform\/.+\.[cm]?[jt]sx?$/.test(rel) || /^tests\/e2e\/fixtures\/.+\.[cm]?[jt]sx?$/.test(rel) || /^playwright\.platform\.config\.[cm]?[jt]s$/.test(rel))

const CAPABILITY_KEYS = ['platformName', 'automationName', 'udid', 'bundleId', 'appPackage', 'appActivity', 'deviceName', 'platformVersion']
const KEY = new RegExp(`(^|[\\s{,(])(["'\`]?)(${CAPABILITY_KEYS.join('|')})\\2\\s*:`, 'm')
const APPIUM = /["'`](appium:[A-Za-z][\w.-]*)["'`]/
const INLINE = /\b((?:desired)?[cC]apabilities)\s*:\s*\{/

/** What capability literal the text carries for a screened file, or undefined. */
export function capabilityLiteral(rel: string, text: string): string | undefined {
  if (!screensCapabilities(rel)) return undefined
  const appium = APPIUM.exec(text)
  if (appium) return `the "${appium[1]}" key`
  const inline = INLINE.exec(text)
  if (inline) return `an inline \`${inline[1]}: {…}\` object`
  const key = KEY.exec(text)
  if (key) return `the \`${key[3]}\` key`
  return undefined
}

export const capabilityDeny = (rel: string, what: string) =>
  `achilles: ${rel} would carry a capability literal (${what}). Capabilities live only in tests/capabilities/<device>.json; the run names that file with CAPABILITIES=tests/capabilities/<device>.json and the fixture reads it through session.capabilities (a file path, default process.env.CAPABILITIES). Move the value into the capabilities file.\n\nReferences:\n  ${PLATFORM_REF}`
