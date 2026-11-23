import type { EngineInterface } from 'claude-code'

import { LEDGER_DOCS_DIRS, PROTECTED_FILES } from '../data/protected-paths.mjs'
import {
  exists,
  factoryRules,
  hashText,
  readJson,
  readText,
  ruleOf,
  run,
  strings,
  threeLine,
  type FactoryRules,
} from './io'
import type { Who } from './context'
import { basename, isAbsolute, normalize, relative, resolve, within } from './posix'
import { ATTRIBUTION, OUTBOUND_REF, unreachableDeny, unreachableFiles } from './attribution'
import { contentSecret } from './secrets'
import { commands, gitCall, isReader, nestedCommand, unresolved, type Command } from './shell'

// Hook 1, the Bash judge: one parsed-command model, small judges. Denies only what is
// irreversible or dangerous (a hook or signing bypass, AI attribution on a commit, PR or issue, a
// force-push, a recursive delete outside the project, a k6 run past the ceilings, a spend-listed
// spec without its opt-in, a wdio call that could reset, retarget or hold a shared device or reach
// another expert's session, an orchestrator device session); advises on commit grammar, shell writes
// to protected state, the factory verify stamp, the wdio inspection form and the platform run form;
// rewrites a missing playwright-cli slug, a wdio session's name and a snapshot without --all. The
// main loop is never touched.

const REFS = (...paths: string[]) => `\n\nReferences:\n${paths.map(p => `  ${p}`).join('\n')}`
const COMMIT_REF = 'skills/achilles-orchestrator/references/commit-conventions.md'
const CLI_REF = 'skills/achilles-orchestrator/references/playwright-cli-protocol.md'
const PERF_REF = 'skills/performance-testing/SKILL.md'
const STATE_REF = 'skills/achilles-orchestrator/references/state-files.md'

const RESERVED_SLUGS = new Set(['default', 'test', 'session', 'temp', 'tmp', 'x', 'y', 'main'])
const SESSION_AGNOSTIC = new Set(['install-browser', 'close-all', 'kill-all', 'list', 'list-sessions', 'sessions', '--help', '-h', '--version', '-v'])
const HARD_MAX_VUS = 1000
const HARD_MAX_DURATION_S = 3600
const PERF_CONFIG = 'tests/perf/perf-onboarding.config.json'

type Verdict = { deny?: string; notes: string[]; command: string }

type Ctx = { root: string; home: string; who: Who; rules: FactoryRules | undefined; text: string }

// ── the model: top-level commands, one level of sh -c / eval, the cwd a cd moves ──

type Judged = { cmd: Command; nested: boolean; dir: string }

function expand(line: string, root: string, home: string): Judged[] {
  const out: Judged[] = []
  let dir = root
  for (const cmd of commands(line).commands) {
    const inner = nestedCommand(cmd.args)
    if (inner !== undefined) {
      let innerDir = dir
      for (const c of commands(inner).commands) {
        out.push({ cmd: { ...c, assign: [...cmd.assign, ...c.assign] }, nested: true, dir: innerDir })
        innerDir = moved(c, innerDir, home)
      }
      continue
    }
    out.push({ cmd, nested: false, dir })
    dir = moved(cmd, dir, home)
  }
  return out
}

function moved(cmd: Command, dir: string, home: string): string {
  if (cmd.args[0] !== 'cd' && cmd.args[0] !== 'pushd') return dir
  const to = cmd.args[1]
  if (to === undefined) return home
  if (to === '-' || unresolved(to)) return dir
  return resolve(dir, to, home)
}

const shortGroup = (a: string) => /^-[A-Za-z]+$/.test(a)
const hasFlag = (args: readonly string[], long: string[], short: string | undefined, valueLetters = '') => {
  for (const a of args) {
    if (a === '--') break
    if (long.includes(a)) return true
    if (short !== undefined && shortGroup(a)) {
      for (const ch of a.slice(1)) {
        if (ch === short) return true
        if (valueLetters.includes(ch)) break
      }
    }
  }
  return false
}

// ── git: force-push (deny), commit bypass and attribution (deny), grammar (advice), factory stamp (advice) ──

async function judgeGit($: EngineInterface, ctx: Ctx, j: Judged, v: Verdict) {
  const git = gitCall(j.cmd.args)
  if (!git) return
  if (git.sub === 'push') {
    if (hasFlag(git.rest, ['--force'], 'f', 'o')) v.deny ??= `an Achilles agent does not force-push; hand back BLOCKED and name the branch state.${REFS(COMMIT_REF)}`
    return
  }
  if (git.sub !== 'commit') return
  const rest = git.rest
  if (git.configs.includes('commit.gpgsign=false') || hasFlag(rest, ['--no-verify', '--no-gpg-sign'], 'n', 'mFCctSu'))
    v.deny ??= `git commit must not bypass hooks or signing (--no-verify, -n, --no-gpg-sign, -c commit.gpgsign=false). Investigate what the hook refuses and fix that.${REFS(COMMIT_REF)}`
  const messages: string[] = []
  let scan = ctx.text + j.cmd.heredocs.join('\n')
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i]!
    if (a === '--') break
    if (a === '-m' || a === '--message') messages.push(rest[++i] ?? '')
    else if (a.startsWith('--message=')) messages.push(a.slice('--message='.length))
    else if (/^-[a-zA-Z]*m./.test(a) && shortGroup(a.slice(0, a.indexOf('m') + 1))) messages.push(a.slice(a.indexOf('m') + 1))
    else if (/^-[a-zA-Z]*m$/.test(a)) messages.push(rest[++i] ?? '')
    else if (a === '-F' || a === '--file' || a.startsWith('--file=') || /^-[a-zA-Z]*F$/.test(a)) {
      const file = a.startsWith('--file=') ? a.slice('--file='.length) : (rest[++i] ?? '')
      if (file !== '-' && file !== '') scan += `\n${(await readText($, resolve(j.dir, file, ctx.home))) ?? ''}`
    }
  }
  if (ATTRIBUTION.test(scan)) v.deny ??= `AI-attribution in a commit (Co-Authored-By: Claude …, Claude-Session:, "Generated with Claude Code", a claude.ai/code URL) is refused: commits made by Achilles agents carry no AI attribution. Remove the trailer and commit again.${REFS(COMMIT_REF, OUTBOUND_REF)}`
  const subject = (messages[0] ?? j.cmd.heredocs[0] ?? '').split('\n')[0]!.trim()
  if (/^test\(j-[^)]*,/.test(subject)) v.notes.push(`commit grammar: "${subject}" is a multi-journey commit; one journey per commit (${COMMIT_REF}).`)
  else if (/^feat\((e2e|test|coverage|journey|onboarding)\)/.test(subject)) v.notes.push(`commit grammar: "${subject}" uses 'feat:' for test work; the convention is 'test:' not 'feat:' (${COMMIT_REF}).`)
  else if (/^review\(/.test(subject)) v.notes.push(`commit grammar: review-tagged commits are not used; verdicts live in the state file, not in commits (${COMMIT_REF}).`)
  await judgeVerifyStamp($, ctx, j, git.dirs, v)
}

// The factory rule process.evidence: a commit inside the project needs a verify stamp that hashes the current tree.
async function judgeVerifyStamp($: EngineInterface, ctx: Ctx, j: Judged, dirs: string[], v: Verdict) {
  const rule = ruleOf(ctx.rules, 'process.evidence')
  if (!rule) return
  let dir = j.dir
  for (const d of dirs) dir = resolve(dir, d, ctx.home)
  if (!within(ctx.root, dir)) return
  const stampRel = typeof rule.stamp === 'string' ? rule.stamp : ''
  const trail = typeof rule.trailDir === 'string' ? rule.trailDir : ''
  const hashCommand = strings(rule.hashCommand)
  if (stampRel === '' || trail === '' || hashCommand.length === 0) return
  const action = typeof rule.action === 'string' ? rule.action : undefined
  const doc = typeof rule.doc === 'string' ? rule.doc : undefined
  const what = 'Tree changed since the last verify (or no verify yet).'
  const say = (detail: string) => v.notes.push(threeLine('process.evidence', `${what} ${detail}`, action, doc))
  const stamp = await readJson<{ treeHash?: unknown }>($, `${ctx.root}/${stampRel}`)
  if (stamp === undefined) return say((await exists($, `${ctx.root}/${stampRel}`)) ? `${stampRel} is not JSON.` : `No verify stamp (${stampRel} missing).`)
  const curRel = typeof rule.currentChange === 'string' ? rule.currentChange : ''
  if (curRel !== '') {
    const marker = await readText($, `${ctx.root}/${curRel}`)
    if (marker !== undefined) {
      const change = marker.split(/\s/)[0] ?? ''
      if (!/^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9]+(-[a-z0-9]+)*$/.test(change)) return say(`${curRel} names "${change}", which is not a <yyyy-mm-dd>-<slug> change folder.`)
      for (const r of strings(rule.required)) if (!(await exists($, `${ctx.root}/${trail}/${change}/${r}`))) return say(`The current change ${trail}/${change}/ has no ${r}.`)
    }
  }
  const want = typeof stamp.treeHash === 'string' ? stamp.treeHash : ''
  if (want === '') return say(`${stampRel} has no treeHash.`)
  const ran = await run($, hashCommand, { cwd: ctx.root, timeoutMs: 8000 })
  if (!ran.ok || ran.exitCode !== 0) return v.notes.push(`the verify stamp could not be checked (${hashCommand[0]} ${ran.ok ? `exited ${ran.exitCode}` : ran.reason}); run the verify step before committing.`)
  const now = ran.stdout.trim().split(/\s+/)[0] ?? ''
  if (now !== want) say(`Stamp tree ${want.slice(0, 12)} ≠ current tree ${now.slice(0, 12)} (a file under the hashed roots changed after the verify step).`)
}

// ── rm -rf outside the project ──

function judgeRm(ctx: Ctx, j: Judged, v: Verdict) {
  const a = j.cmd.args
  if (a[0] !== 'rm') return
  const recursive = hasFlag(a.slice(1), ['--recursive'], 'r') || hasFlag(a.slice(1), [], 'R')
  const force = hasFlag(a.slice(1), ['--force'], 'f')
  if (!recursive || !force) return
  let opts = true
  for (const t of a.slice(1)) {
    if (opts && t === '--') {
      opts = false
      continue
    }
    if (opts && t.startsWith('-')) continue
    const target = resolve(j.dir, t.replace(/^["']|["']$/g, ''), ctx.home)
    if (!within(ctx.root, target)) {
      v.deny ??= `recursive delete outside the project (${target}) is off limits for an Achilles agent; hand back BLOCKED if it is needed.${REFS(STATE_REF)}`
      return
    }
  }
}

// ── k6 run: hard ceilings, the target allowlist, the production guard ──

function seconds(d: string): number | undefined {
  let total = 0
  let any = false
  for (const m of d.matchAll(/(\d+(?:\.\d+)?)(ms|s|m|h)?/g)) {
    const n = Number(m[1])
    const unit = m[2] ?? 's'
    total += unit === 'h' ? n * 3600 : unit === 'm' ? n * 60 : unit === 'ms' ? n / 1000 : n
    any = true
  }
  return any ? total : undefined
}

async function judgeK6($: EngineInterface, ctx: Ctx, j: Judged, v: Verdict) {
  const a = j.cmd.args
  if (a[0] !== 'k6' || a[1] !== 'run') return
  const refs = REFS(PERF_REF)
  const config = await readJson<{ targets?: { allowlist?: unknown }; production?: { origin?: unknown; allowed?: unknown } }>($, `${ctx.root}/${PERF_CONFIG}`)
  if (!config) return void (v.deny ??= `perf load run attempted but ${PERF_CONFIG} is missing; run the performance pipeline's Phase 1 (Scaffold) first to establish the target allowlist and caps.${refs}`)
  let vus: number | undefined
  let duration: string | undefined
  let origin: string | undefined
  const rest = a.slice(2)
  for (let i = 0; i < rest.length; i++) {
    const t = rest[i]!
    const next = rest[i + 1]
    if (t === '--vus' || t === '-u') vus = Number(next)
    else if (t.startsWith('--vus=')) vus = Number(t.slice(6))
    else if (/^-u\d+$/.test(t)) vus = Number(t.slice(2))
    else if (t === '--duration' || t === '-d') duration = next
    else if (t.startsWith('--duration=')) duration = t.slice(11)
    else if (t === '-e' && next?.startsWith('PERF_BASE_URL=')) origin ??= next.slice('PERF_BASE_URL='.length)
    else if (t.startsWith('-ePERF_BASE_URL=')) origin ??= t.slice('-ePERF_BASE_URL='.length)
  }
  for (const as of j.cmd.assign) if (as.startsWith('PERF_BASE_URL=')) origin ??= as.slice('PERF_BASE_URL='.length)
  if (vus !== undefined && vus > HARD_MAX_VUS) return void (v.deny ??= `requested VUs (${vus}) exceed the hard ceiling of ${HARD_MAX_VUS}; the ceiling is not configurable, it caps autonomous blast radius.${refs}`)
  const dur = duration === undefined ? undefined : seconds(duration)
  if (dur !== undefined && dur > HARD_MAX_DURATION_S) return void (v.deny ??= `requested duration (${duration} = ${dur}s) exceeds the hard ceiling of ${HARD_MAX_DURATION_S}s / 1h; the ceiling is not configurable.${refs}`)
  const url = origin ?? rest.find(t => /^https?:\/\//.test(t))
  const target = url === undefined ? undefined : /^https?:\/\/[^/\s"']+/.exec(url)?.[0]
  if (target === undefined) return void (v.deny ??= `could not determine the load target origin from the k6 command; add an explicit -e PERF_BASE_URL=<allowlisted-origin> so the target can be checked against the allowlist.${refs}`)
  const allow = strings(config.targets?.allowlist).map(x => x.replace(/\/+$/, ''))
  if (!allow.includes(target)) return void (v.deny ??= `perf load target ${target} is not in targets.allowlist of ${PERF_CONFIG}; add it explicitly before load-testing it.${refs}`)
  const prod = typeof config.production?.origin === 'string' ? config.production.origin.replace(/\/+$/, '') : ''
  if (prod !== '' && prod === target && config.production?.allowed !== true) v.deny ??= `${target} is the configured production origin and production.allowed is not true; production load needs production.allowed: true in ${PERF_CONFIG} (a deliberate opt-in).${refs}`
}

// ── gh pr create|edit|comment|review and gh issue create|edit|comment: attribution (deny). The sign-off hook judges the publish itself. ──

const GH_WRITES: Record<string, string[]> = { pr: ['create', 'edit', 'comment', 'review'], issue: ['create', 'edit', 'comment'] }

async function judgeGh($: EngineInterface, ctx: Ctx, j: Judged, v: Verdict) {
  const a = j.cmd.args
  if (a[0] !== 'gh' || !(GH_WRITES[a[1] ?? ''] ?? []).includes(a[2] ?? '')) return
  const what = a[2] === 'comment' || a[2] === 'review' ? 'comment' : a[1] === 'pr' ? 'pull request' : 'issue'
  let scan = ctx.text
  for (let i = 3; i < a.length; i++) {
    const t = a[i]!
    const file = t === '--body-file' || t === '-F' ? a[++i] : t.startsWith('--body-file=') ? t.slice('--body-file='.length) : undefined
    if (file !== undefined && file !== '-') scan += `\n${(await readText($, resolve(j.dir, file, ctx.home))) ?? ''}`
  }
  if (ATTRIBUTION.test(scan)) v.deny ??= `AI-attribution in ${what === 'issue' ? 'an' : 'a'} ${what} (Co-Authored-By: Claude …, Claude-Session:, "Generated with Claude Code", a claude.ai/code URL) is refused: ${what === 'pull request' ? 'PRs' : `${what}s`} made by Achilles agents carry no AI attribution. Remove it from the title and body.${REFS(COMMIT_REF, OUTBOUND_REF)}`
  if (v.deny === undefined && (a[1] === 'issue' || a[2] === 'comment' || a[2] === 'review')) {
    const unreachable = await unreachableFiles($, scan)
    if (unreachable.length > 0) v.deny = unreachableDeny(`this ${what}`, unreachable).replace(/^achilles: /, '')
  }
}

// ── playwright-cli: every session needs its own slug; a missing or malformed one is rewritten from the agent ──

const isPlaywrightCli = (name: string) => /^(playwright-cli|@playwright\/cli)$/i.test(name)

export const derivedSlug = (role: string, agentId: string) => `${role}-${hashText(agentId).slice(0, 6)}`

function judgePlaywrightCli(ctx: Ctx, j: Judged, v: Verdict, inserts: { at: number; replaceTo?: number; text: string }[]) {
  const a = j.cmd.args
  if (!isPlaywrightCli(a[0] ?? '')) return
  const sub = a.slice(1).find(t => !t.startsWith('-'))
  if (sub === undefined || SESSION_AGNOSTIC.has(sub) || a.some(t => SESSION_AGNOSTIC.has(t))) return
  let slug: string | undefined
  let slugIdx = -1
  for (let i = 1; i < a.length; i++) {
    if (a[i]!.startsWith('-s=')) {
      slug = a[i]!.slice(3)
      slugIdx = i
    } else if (a[i] === '-s' && a[i + 1] !== undefined) {
      slug = a[i + 1]
      slugIdx = i + 1
    }
  }
  const bad = slug === undefined ? 'has no -s=<slug>' : RESERVED_SLUGS.has(slug) ? `uses the collision-prone slug '${slug}'` : slug.length < 6 ? `uses a slug too short to be distinct ('${slug}')` : slug.length > 28 ? `uses a slug too long for the socket path ('${slug}')` : undefined
  if (bad === undefined) {
    v.notes.push(`__slug:${slug}`)
    return
  }
  const derived = derivedSlug(ctx.who.role, ctx.who.expert?.agentId ?? ctx.who.run.agentId ?? 'run')
  if (j.nested) return v.notes.push(`a playwright-cli call inside a nested shell ${bad}; every session carries -s=<slug> (yours: ${derived}) so parallel experts never share a browser profile (${CLI_REF}).`)
  if (slug === undefined) inserts.push({ at: j.cmd.spans[0]!.end, text: ` -s=${derived}` })
  else inserts.push({ at: j.cmd.spans[slugIdx]!.start, replaceTo: j.cmd.spans[slugIdx]!.end, text: a[slugIdx]!.startsWith('-s=') ? `-s=${derived}` : derived })
  v.notes.push(`__slug:${derived}`)
  v.notes.push(`playwright-cli ${bad}; it ran as -s=${derived}. Use that slug for every call of this session (${CLI_REF}).`)
}

// ── wdio session: the one platform inspection form (npx wdio session -s <slug> <action> …) ──
// The session name follows the playwright-cli -s= rule: a valid slug of the agent's own is kept
// and recorded (the turn's end closes it), a missing, malformed or taken one is rewritten to the
// agent's derived slug. snapshot always carries --all (iOS judges list rows hidden otherwise).
// Denied, because a device is shared: open with a capability or server flag of its own or inline
// capabilities (it could reset or retarget the device), an idle timeout of 0 or past the cap,
// close --all, wdio repl, a call that would reach another expert's session, and any device session
// of the orchestrator's. Every other command-form problem is a note; the CLI refuses what it cannot run.

const PLATFORM_INSPECT_REF = 'skills/achilles-orchestrator/references/platform-inspection-protocol.md'
// The actions of `wdio session` in @wdio/cli 10.2.0 (wdio session --help).
const WDIO_ACTIONS = new Set([
  'open', 'close', 'list', 'info', 'restart', 'status', 'exec', 'helpers', 'snapshot', 'read', 'find', 'diff', 'screenshot', 'pdf', 'source', 'get', 'is', 'logs',
  'navigate', 'back', 'forward', 'reload', 'wait', 'click', 'tap', 'fill', 'type', 'press', 'select', 'upload', 'hover', 'focus', 'check', 'uncheck', 'drag', 'scroll', 'swipe', 'long-press',
  'tabs', 'windows', 'frame', 'contexts', 'dialog', 'app', 'deeplink', 'rotate', 'keyboard', 'background', 'lock', 'unlock', 'geolocation', 'emulate', 'requests', 'mock', 'unmock',
  'cookies', 'storage', 'state', 'visual', 'trace', 'record', 'history', 'export', 'resume', 'doctor', 'skill',
])
const WDIO_AGNOSTIC = new Set(['list', 'doctor', 'skill'])
// The global flags that may precede the action (besides the session flag).
const WDIO_GLOBAL_BOOL = new Set(['--json', '-q', '--quiet', '--color', '--no-color'])
// open's flags that the inspection form allows; every other one sets a capability, the server or a
// browser option outside the capabilities file.
const WDIO_OPEN_FLAGS = new Set(['--capabilities', '--appium-url', '--bundle-id', '--package', '--app', '--activity', '--replace', '--launch-timeout', '--idle-timeout', '--log-level', '--snapshot', '--no-snapshot', '--json', '-q', '--quiet', '--color', '--no-color', '--timeout'])
const WDIO_OPEN_VALUE = new Set(['--capabilities', '--appium-url', '--bundle-id', '--package', '--app', '--activity', '--launch-timeout', '--idle-timeout', '--log-level', '--timeout'])
// A flag of open's that sets a capability or the server outside the capabilities file: by name, or by
// a word in it (any vendor or future spelling of a device, reset, app, server or credential option).
// @wdio/session 10.2.0's own (OPEN_OPTIONS in build/cli.js): --hostname, --port, --path, --protocol, --attach
// (a server or an existing session), --browser, --device, --platform-version, --udid, --reset/--no-reset,
// --full-reset, --orientation (capabilities) and --provider, --os, --os-version, --region, --tunnel,
// --tunnel-name (a cloud device) all match.
const WDIO_CAPABILITY_FLAG = /udid|device|platform|automation|reset|orientation|host|port|path|protocol|attach|tunnel|provider|server|url|caps|capabilit|avd|simulator|emulator|app|bundle|package|activity|user|key|token|region|locale|language|grant|browser|vendor|cloud|^--os(-|$)/i
// open options of @wdio/session 10.2.0 that apply to a browser, a desktop app or a cloud label only and
// touch no device: a note. The string-valued ones take their value.
const WDIO_OPEN_NOTE_BOOL = new Set(['--headed', '--headless', '--bidi', '--no-bidi'])
const WDIO_OPEN_ARRAY = new Set(['--arg', '--app-arg'])
const WDIO_OPEN_NOTE_VALUE = new Set(['--viewport', '--browser-version', '--binary', '--arg', '--profile', '--app-arg', '--chromedriver', '--electron-version', '--project', '--build', '--name'])
const CAPS_FILE = /^(\.\/)?tests\/capabilities\/[A-Za-z0-9._-]+\.json$/
const MAX_IDLE_S = 1800
const OPEN_FORM = '`npx wdio session -s <slug> open <android|ios> --appium-url "$APPIUM_URL" --capabilities tests/capabilities/<device>.json --bundle-id <id> | --package <id>`'
const RUNNERS = new Set(['node', 'bun', 'deno', 'tsx', 'ts-node', '@wdio/cli'])

/**
 * A long flag's canonical name: lower-case kebab-case. The CLI's parser reads camelCase as the kebab
 * flag (`--idleTimeout` is `--idle-timeout`); snake_case and upper case (`--idle_timeout`,
 * `--IDLE-TIMEOUT`) the CLI refuses, and they are judged the same way to be safe. A `=value` is cut off.
 */
export function flagName(t: string): string {
  const eq = t.indexOf('=')
  const raw = eq > 0 ? t.slice(0, eq) : t
  if (!raw.startsWith('--')) return raw
  return `--${raw.slice(2).replace(/([a-z0-9])([A-Z])/g, '$1-$2').replace(/_/g, '-').toLowerCase()}`
}

const isWdioWord = (w: string) => w === '@wdio/cli' || /^wdio(\.[cm]?js)?$/.test(basename(w))
const isSessionFlag = (t: string) => (t.startsWith('-s') && !t.startsWith('--')) || t === '--session' || t.startsWith('--session=')
// After the action (whose arguments may be free text: fill e3 -secret, find -text), only the exact session flag forms count.
const isExactSessionFlag = (t: string) => t === '-s' || t.startsWith('-s=') || t === '--session' || t.startsWith('--session=')
/** A session name wdio and the turn-end close accept: starts with a letter or digit. */
export const WDIO_NAME = /^[A-Za-z0-9][A-Za-z0-9_-]*$/

/** Where the wdio CLI word sits in a command (`wdio`, `@wdio/cli`, `npx -p @wdio/cli wdio`, `node …/wdio.js`), or -1. */
function wdioAt(a: readonly string[]): number {
  const first = a[0] ?? ''
  if (first === '@wdio/cli') return a[1] !== undefined && a[1] !== '@wdio/cli' && isWdioWord(a[1]) ? 1 : 0
  if (isWdioWord(first)) return 0
  if (!RUNNERS.has(first)) return -1
  const k = a.findIndex((t, i) => i > 0 && !t.startsWith('-'))
  return k > 0 && isWdioWord(a[k]!) ? k : -1
}

/**
 * Whether `session` stands in the subcommand position after the wdio word at k: the first word
 * after wdio's own options, or the word after that when an option may have taken the first as its
 * value (`wdio --opt value session`). A `session` further on is an argument (`wdio run x --suite session`).
 */
function sessionAfter(a: readonly string[], k: number): boolean {
  let i = k + 1
  while (i < a.length && a[i]!.startsWith('-')) i++
  if (a[i] === 'session') return true
  return i > k + 1 && a[i - 1] !== '--' && !a[i - 1]!.includes('=') && a[i + 1] === 'session'
}

/** A project-relative tests/capabilities/<device>.json for a literal path, else undefined. */
function capabilitiesFile(ctx: Ctx, dir: string, value: string): string | undefined {
  if (unresolved(value)) return undefined
  if (isAbsolute(value)) {
    const rel = relative(ctx.root, value)
    return CAPS_FILE.test(rel) ? rel : undefined
  }
  if (!CAPS_FILE.test(value)) return undefined
  const rel = relative(ctx.root, resolve(dir, value, ctx.home))
  return CAPS_FILE.test(rel) ? rel : undefined
}

/** Which other live expert holds a session name (its recorded names or its derived slug), or undefined. */
function heldBy(ctx: Ctx, name: string): string | undefined {
  const mine = ctx.who.expert?.agentId
  const owner = ctx.who.run.experts.find(x => x.agentId !== mine && ((x.wdio ?? []).includes(name) || derivedSlug(x.role, x.agentId) === name))
  return owner ? `another expert (${owner.role} ${owner.agentId}) that is still at work` : undefined
}

/** Why a session name is not this agent's to use, or undefined when it is; `holder` is set when another expert holds it. */
function badSessionName(ctx: Ctx, name: string | undefined): { why: string; holder?: string } | undefined {
  if (name === undefined || name === '') return { why: 'has no -s <name>' }
  const holder = heldBy(ctx, name)
  if (holder) return { why: `uses '${name}', the session of ${holder}`, holder }
  if (!WDIO_NAME.test(name)) return { why: `uses a session name that does not start with a letter or digit or has characters outside [A-Za-z0-9_-] ('${name}')` }
  if (RESERVED_SLUGS.has(name)) return { why: `uses the collision-prone session name '${name}'` }
  if (name.length < 6) return { why: `uses a session name too short to be distinct ('${name}')` }
  if (name.length > 28) return { why: `uses a session name too long for the socket path ('${name}')` }
  return undefined
}

/** The agent's own session name: its derived slug, or a re-hashed one when another expert already holds that. */
function ownSessionName(ctx: Ctx): string {
  const id = ctx.who.expert?.agentId ?? ctx.who.run.agentId ?? 'run'
  let name = derivedSlug(ctx.who.role, id)
  for (let n = 1; n < 10 && heldBy(ctx, name) !== undefined; n++) name = derivedSlug(ctx.who.role, `${id}#${n}`)
  return name
}

async function judgeWdio($: EngineInterface, ctx: Ctx, j: Judged, v: Verdict, inserts: { at: number; replaceTo?: number; text: string }[]) {
  const a = j.cmd.args
  const refs = REFS(PLATFORM_INSPECT_REF)
  const at = wdioAt(a)
  // A form the judge cannot read is refused: none of the device-safety checks could run on it.
  const unrecognised = `Run it as \`npx wdio session -s <slug> <action> …\`: this command reaches \`wdio session\` through a form the judge does not read (a package-manager exec, a wrapper, a runner option), so it cannot check that the call keeps off other experts' sessions and shared devices.${refs}`
  if (at < 0) {
    if (isReader(a) || (a[0] === 'find' && !a.some(x => /^-(delete|exec|execdir|ok|okdir)$/.test(x)))) return
    if (a.some((t, k) => isWdioWord(t) && sessionAfter(a, k))) return void (v.deny ??= unrecognised)
    // find … -exec node {} session: the wdio file runs as {}, so the words after it count.
    if (a[0] === 'find' && a.some(t => /wdio/.test(t)) && a.some((t, k) => t === '{}' && sessionAfter(a, k))) return void (v.deny ??= unrecognised)
    if (j.cmd.wrapBad && a.some(t => /wdio/.test(t))) v.deny ??= `Run \`npx wdio session -s <slug> <action> …\` directly: this command runs wdio behind a wrapper option the judge cannot read.${refs}`
    return
  }
  const sub = a[at + 1]
  if (sub !== 'session' && sub !== 'repl' && sessionAfter(a, at)) return void (v.deny ??= unrecognised)
  if (sub === 'repl') return void (v.deny ??= `Inspect with ${OPEN_FORM} instead: \`wdio repl\` opens a device session outside the inspection form, with no session name to close it by and no check on what it sets on a shared device.${refs}`)
  if (sub !== 'session') return
  const s = at + 1
  if (a.slice(s + 1).some(t => t === '--help' || t === '-h' || t === '--version')) return
  // Every session flag anywhere is counted. A flag before the action other than the global ones is
  // collected (with its value) and judged as one of the action's: a capability flag stays one.
  const sessionFlags: number[] = []
  const early: string[] = []
  // The same flags for open's judge, a consumed value joined as --flag=value so it never reads as the platform.
  const earlyFlags: string[] = []
  let action = -1
  for (let i = s + 1; i < a.length; i++) {
    const t = a[i]!
    if (action >= 0 ? isExactSessionFlag(t) : isSessionFlag(t)) {
      sessionFlags.push(i)
      if (t === '-s' || t === '--session') i++
      continue
    }
    if (action >= 0) continue
    const fn = flagName(t)
    if (fn === '--timeout' && !t.includes('=')) {
      i++
      continue
    }
    if (fn === '--timeout' || WDIO_GLOBAL_BOOL.has(fn)) continue
    if (t.startsWith('-')) {
      early.push(t)
      earlyFlags.push(t)
      const next = a[i + 1]
      const takesValue = !t.includes('=') && next !== undefined && !next.startsWith('-') && (WDIO_OPEN_VALUE.has(fn) || (!WDIO_OPEN_FLAGS.has(fn) && !WDIO_ACTIONS.has(next)))
      if (takesValue) {
        early.push(a[++i]!)
        earlyFlags[earlyFlags.length - 1] = `${t}=${a[i]}`
      }
      continue
    }
    action = i
  }
  const act = action < 0 ? '' : a[action]!
  if (act === '') return
  const rest = a.slice(action + 1)
  if (act === 'close' && rest.includes('--all')) return void (v.deny ??= `Close your own session with \`npx wdio session -s <slug> close\`: \`close --all\` closes every session, including other experts' sessions on shared devices.${refs}`)
  // The orchestrator holds no device: it lists sessions and closes a stale one by its name, nothing else.
  if (!ctx.who.expert) {
    if (act === 'list' || act === 'close') return
    return void (v.deny ??= `Leave device sessions to the experts: brief an inspector (or an author on a platform brief) for \`wdio session ${act}\`. The orchestrator only lists sessions (\`npx wdio session list\`) and closes a stale one by its name (\`npx wdio session -s <name> close\`).${refs}`)
  }
  if (!WDIO_ACTIONS.has(act)) return void v.notes.push(`Check the action against \`npx wdio session --help\`: '${act}' is not a wdio session action of @wdio/cli 10.2.0, so the CLI refuses it (${PLATFORM_INSPECT_REF}).`)
  if (WDIO_AGNOSTIC.has(act)) return
  const nameAt = (i: number) => {
    const f = a[i]!
    return f === '-s' || f === '--session' ? a[i + 1] : f.startsWith('--session=') ? f.slice('--session='.length) : f.slice(f.startsWith('-s=') ? 3 : 2)
  }
  const notes: string[] = []
  // Several session flags naming one name collapse to the first (a name not this agent's is then
  // rewritten as any other); different names are refused.
  const collapse: { at: number; replaceTo?: number; text: string }[] = []
  if (sessionFlags.length > 1) {
    const names = sessionFlags.map(nameAt)
    if (!names.every(n => n === names[0]) || names[0] === undefined || names[0] === '')
      return void (v.deny ??= `Pass one -s <slug>: this call names more than one session flag (${sessionFlags.map(i => a[i]).join(', ')}), so the judge cannot tell which session it reaches or keep it off another expert's.${refs}`)
    for (const i of sessionFlags.slice(1)) {
      const end = a[i] === '-s' || a[i] === '--session' ? i + 1 : i
      const next = j.cmd.spans[end + 1]
      collapse.push(next ? { at: j.cmd.spans[i]!.start, replaceTo: next.start, text: '' } : { at: j.cmd.spans[i - 1]!.end, replaceTo: j.cmd.spans[end]!.end, text: '' })
    }
    if (!j.nested) notes.push(`wdio session named its session ${names.length} times; it ran with one session flag (${PLATFORM_INSPECT_REF}).`)
  }
  if (act === 'open') {
    const open = await judgeWdioOpen($, ctx, j, [...earlyFlags, ...rest])
    if (open.deny !== undefined) return void (v.deny ??= `${open.deny}${refs}`)
    notes.push(...open.notes)
  }
  if (early.length > 0) notes.push(`Put \`${early.join(' ')}\` after the action: before it only -s/--session, --timeout, --json, -q/--quiet and --color/--no-color stand (${PLATFORM_INSPECT_REF}).`)
  const flagAt = sessionFlags[0]
  const flag = flagAt === undefined ? undefined : a[flagAt]!
  const given = flagAt === undefined ? undefined : nameAt(flagAt)
  const bad = badSessionName(ctx, given)
  const fixes: { at: number; replaceTo?: number; text: string }[] = []
  let name = given!
  if (bad !== undefined) {
    name = ownSessionName(ctx)
    if (flagAt === undefined) fixes.push({ at: j.cmd.spans[s]!.end, text: ` -s ${name}` })
    else if ((flag === '-s' || flag === '--session') && a[flagAt + 1] !== undefined) fixes.push({ at: j.cmd.spans[flagAt]!.start, replaceTo: j.cmd.spans[flagAt + 1]!.end, text: `-s ${name}` })
    else fixes.push({ at: j.cmd.spans[flagAt]!.start, replaceTo: j.cmd.spans[flagAt]!.end, text: `-s ${name}` })
  }
  let addAll = false
  if (act === 'snapshot') {
    const off = rest.findIndex(t => t === '--all=false' || t === '--no-all')
    if (off >= 0) fixes.push({ at: j.cmd.spans[action + 1 + off]!.start, replaceTo: j.cmd.spans[action + 1 + off]!.end, text: '--all' })
    else if (!rest.includes('--all') && !rest.includes('--all=true')) fixes.push({ at: j.cmd.spans[action]!.end, text: ' --all' })
    addAll = fixes.length > (bad !== undefined ? 1 : 0)
  }
  if (j.nested) {
    // A nested shell cannot be rewritten: another expert's session stays refused, the rest is a note.
    if (bad?.holder !== undefined) return void (v.deny ??= `Use your own session name (-s ${name}): '${given}' is the session of ${bad.holder}, and a call inside a nested shell (sh -c, eval) cannot be rewritten.${refs}`)
    const what = [bad !== undefined ? `-s ${name}` : '', addAll ? '--all' : ''].filter(Boolean).join(' and ')
    if (what !== '') notes.push(`Run it as \`npx wdio session -s ${name} ${act} …\`${addAll ? ' with --all' : ''}: a wdio session call inside a nested shell (sh -c, eval) cannot be rewritten, and this one needs ${what}${bad !== undefined ? ` (it ${bad.why})` : ''} (${PLATFORM_INSPECT_REF}).`)
    v.notes.push(...notes)
    if (bad === undefined) v.notes.push(`__wdio:${given}`)
    return
  }
  inserts.push(...fixes, ...collapse)
  if (bad !== undefined) notes.push(`wdio session ${bad.why}; it ran as -s ${name}. Use that name for every call of this session (${PLATFORM_INSPECT_REF}).`)
  v.notes.push(...notes)
  v.notes.push(`__wdio:${name}`)
}

/** An --idle-timeout value in seconds (a bare number is milliseconds), or undefined when unreadable. */
// As @wdio/session 10.2.0 parses it (parseDuration): one number with an optional ms|s|m|h unit, a bare number is milliseconds.
function idleSeconds(value: string): number | undefined {
  const m = /^(\d+(?:\.\d+)?)(ms|s|m|h)?$/.exec(value.trim())
  if (!m) return undefined
  return (Number(m[1]) * { ms: 1, s: 1e3, m: 6e4, h: 36e5 }[(m[2] ?? 'ms') as 'ms' | 's' | 'm' | 'h']) / 1000
}

/**
 * An `open` judged against the inspection form: a deny for what could reset, retarget or hold a
 * shared device; a note, leading with the fix, for every other departure.
 */
async function judgeWdioOpen($: EngineInterface, ctx: Ctx, j: Judged, rest: readonly string[]): Promise<{ deny?: string; notes: string[] }> {
  const form = OPEN_FORM
  const notes: string[] = []
  const say = (what: string) => (notes.push(`${what} (${PLATFORM_INSPECT_REF})`), { notes })
  const flags: Record<string, string> = {}
  const positional: string[] = []
  for (let i = 0; i < rest.length; i++) {
    const t = rest[i]!
    if (isSessionFlag(t)) {
      if (t === '-s' || t === '--session') i++
      continue
    }
    if (!t.startsWith('-')) {
      positional.push(t)
      continue
    }
    const eq = t.indexOf('=')
    const shown = eq > 0 ? t.slice(0, eq) : t
    const name = flagName(t)
    // A short flag other than -q may be an alias of a capability option; the judge cannot tell which.
    if (!name.startsWith('--') && !WDIO_OPEN_FLAGS.has(name))
      return { deny: `Use a long flag listed by \`npx wdio session open --help\`, or put the value in tests/capabilities/<device>.json and open with ${form}: \`${shown}\` is a short flag that may alias a capability option on a shared device, and the judge cannot tell which.`, notes }
    const noteOnly = WDIO_OPEN_NOTE_BOOL.has(name) || WDIO_OPEN_NOTE_VALUE.has(name)
    if (!WDIO_OPEN_FLAGS.has(name) && (noteOnly || !WDIO_CAPABILITY_FLAG.test(name))) {
      say(`Check \`npx wdio session open --help\` and drop \`${shown}\`: it is not part of the inspection form${noteOnly ? ' (it applies to a browser, a desktop app or a cloud label, not a device inspection)' : ''} (${form}).`)
      // A value is never a dash-leading word (the parser reads that as the next flag); an array option
      // (--arg, --app-arg) takes every following word, as the parser does.
      const isValue = (k: number) => rest[k] !== undefined && !rest[k]!.startsWith('-')
      if (eq < 0 && isValue(i + 1) && (WDIO_OPEN_NOTE_VALUE.has(name) || (!WDIO_OPEN_NOTE_BOOL.has(name) && positional.length > 0))) {
        i++
        if (WDIO_OPEN_ARRAY.has(name)) while (isValue(i + 1)) i++
      }
      continue
    }
    if (!WDIO_OPEN_FLAGS.has(name))
      return { deny: `Put the value in tests/capabilities/<device>.json and open with ${form}: \`${shown}\` is not part of the inspection form. A device's capabilities (device, udid, OS version, reset, app, orientation, vendor options) come only from the capabilities file and the server only from --appium-url; a flag of its own could reset or retarget a shared device.`, notes }
    // A dash-leading word is the next flag, never this one's value.
    flags[name] = eq > 0 ? t.slice(eq + 1) : WDIO_OPEN_VALUE.has(name) && rest[i + 1] !== undefined && !rest[i + 1]!.startsWith('-') ? rest[++i]! : ''
  }
  const idle = flags['--idle-timeout']
  if (idle !== undefined) {
    const secs = idleSeconds(idle)
    if (secs === undefined || secs <= 0 || secs > MAX_IDLE_S)
      return { deny: `Open with --idle-timeout 30m or less (never 0): --idle-timeout ${idle} is ${secs === 0 ? 'no idle limit at all' : secs === undefined ? 'unreadable' : 'over the 30m cap'}. A device is shared, so an abandoned session must end within 30 minutes.`, notes }
  }
  const caps = flags['--capabilities']
  if (caps !== undefined && /^\s*[{[]/.test(caps))
    return { deny: `Pass the capabilities file instead (--capabilities tests/capabilities/<device>.json): inline JSON bypasses the one file the test run also uses and can set anything on a shared device. Open with ${form}.`, notes }
  const target = positional[0] ?? ''
  if (target === 'macos' || target === 'windows') return say(`Inspect on android or ios: platform "${target}" is declared but not implemented yet.`)
  if (target !== 'android' && target !== 'ios') return say(`Open android or ios with ${form}: \`open ${target || '<nothing>'}\` is not a platform inspection. A web page is inspected with playwright-cli.`)
  if (positional.length > 1) say(`Drop the extra argument (${positional.slice(1).join(' ')}): \`open ${target}\` takes the platform only; the app comes from the capabilities file, repeated with --bundle-id (ios) / --package (android).`)
  if (caps === undefined || caps === '') return say(`Open with --capabilities tests/capabilities/<device>.json, the same file the test run uses: ${form}.`)
  const file = capabilitiesFile(ctx, j.dir, caps)
  if (file === undefined) return say(`Use a capabilities file under tests/capabilities/: --capabilities ${caps} is not one, and the inspection session and the test run share tests/capabilities/<device>.json.`)
  const url = flags['--appium-url']
  if (url === undefined || !(/^\$\{?APPIUM_URL\}?$/.test(url) || /^https?:\/\/\S+$/.test(url))) say(`Name the server with --appium-url "$APPIUM_URL" (or the server URL with its base path, e.g. http://<appium-server>/wd/hub): ${form}.`)
  const text = await readText($, `${ctx.root}/${file.replace(/^\.\//, '')}`)
  if (text === undefined) return say(`Write ${file} first (the scaffold phase does): it does not exist.`)
  let doc: Record<string, unknown> = {}
  try {
    doc = JSON.parse(text) as Record<string, unknown>
  } catch {
    return say(`Fix ${file}: it is not JSON.`)
  }
  const flat = 'top-level keys, no alwaysMatch/firstMatch wrapper (the library sends the file content as the capabilities object)'
  if (doc === null || typeof doc !== 'object' || Array.isArray(doc)) return say(`Make ${file} a flat JSON object: ${flat}; it is not a JSON object.`)
  const wrapper = ['alwaysMatch', 'firstMatch', 'capabilities'].find(k => k in doc)
  if (wrapper !== undefined) return say(`Make ${file} a flat JSON object: ${flat}; it wraps its capabilities in "${wrapper}".`)
  const named = doc.platformName
  if (typeof named !== 'string' || named === '') return say(`Add platformName to ${file}: the capabilities file names its platform, and open must match it.`)
  if (named.toLowerCase() !== target) return say(`Open the platform ${file} names (${named.toLowerCase()}): \`open ${target}\` does not match its platformName "${named}".`)
  // @wdio/session 10.2.0 checks the app flag before it merges the capabilities file (open ios exits 2
  // without --app/--bundle-id, android without --app/--package), so the form always repeats the app id
  // the file names; a missing or different one is noted.
  const str = (k: string) => (typeof doc[k] === 'string' && doc[k] !== '' ? (doc[k] as string) : undefined)
  const [idFlag, idKey, otherFlag] = target === 'ios' ? ['--bundle-id', 'appium:bundleId', '--package'] : ['--package', 'appium:appPackage', '--bundle-id']
  if (flags[otherFlag] !== undefined) return say(`Drop ${otherFlag}: it does not apply to ${target}; open ${target} with ${idFlag} <the ${idKey} of ${file}>.`)
  // The activity is a capability like any other: it lives in the file; the flag may only repeat it.
  const activity = flags['--activity']
  if (activity !== undefined) {
    if (target === 'ios') return say(`Drop --activity: it does not apply to ios; open ios with --bundle-id <the appium:bundleId of ${file}>.`)
    if (activity !== str('appium:appActivity')) return say(`Put appium:appActivity in ${file} (the flag may only repeat it, or leave it out): --activity ${activity} is not its appium:appActivity.`)
  }
  const id = str(idKey)
  const app = str('appium:app')
  if (id !== undefined) {
    if (flags['--app'] !== undefined) return say(`Open with ${idFlag} ${id}, not --app: ${file} names the app by ${idKey}.`)
    if (flags[idFlag] === undefined || flags[idFlag] === '') return say(`Add ${idFlag} ${id} (the ${idKey} of ${file}): the CLI checks the app flag before it reads the file and exits 2 without it.`)
    if (flags[idFlag] !== id) return say(`Use ${idFlag} ${id}: ${idFlag} ${flags[idFlag]} does not match ${file}, whose ${idKey} is ${id}; inspect the app the test run uses.`)
    return { notes }
  }
  if (app !== undefined) {
    if (flags[idFlag] !== undefined) return say(`Open with --app ${app}, not ${idFlag}: ${file} names the app by appium:app.`)
    if (!flags['--app']) return say(`Add --app ${app} (the appium:app of ${file}): the CLI checks the app flag before it reads the file and exits 2 without it.`)
    if (flags['--app'] !== app) return say(`Use --app ${app}: not --app ${flags['--app']}, since ${file} names appium:app ${app}; inspect the app the test run uses.`)
    return { notes }
  }
  return say(`Name the app in ${file} (${idKey} or appium:app); open repeats it with ${idFlag} or --app.`)
}

// ── platform test runs: E2E_PLATFORM=<p> E2E_CAPABILITIES=tests/capabilities/<device>.json APPIUM_URL=… npx playwright test -c playwright.platform.config.ts ──
// A command is a platform run only when it names playwright.platform.config.*, sets E2E_CAPABILITIES,
// or sets E2E_PLATFORM to a platform value; PLATFORM and CAPABILITIES are never read (an ambient
// PLATFORM=linux or Platform=x64 is not ours). A platform run outside the form gets a note and runs.

const PLATFORM_REF = 'skills/platform-testing/SKILL.md'
const PLATFORM_CONFIG = /(^|\/)playwright\.platform\.config\.[cm]?[jt]s$/
const PLATFORM_VALUES = new Set(['android', 'ios', 'macos', 'windows'])
const RUN_FORM = '`E2E_PLATFORM=<android|ios> E2E_CAPABILITIES=tests/capabilities/<device>.json APPIUM_URL=<server-with-base-path> npx playwright test -c playwright.platform.config.ts`'
const PM = new Set(['npm', 'pnpm', 'yarn'])
const PM_VALUE_OPTS: Record<string, Set<string>> = {
  npm: new Set(['--prefix', '-C', '-w', '--workspace', '--userconfig', '--cache', '--registry', '--loglevel']),
  yarn: new Set(['--cwd']),
  pnpm: new Set(['-C', '--dir', '-F', '--filter']),
}

/** The package.json script a package-manager command runs (`npm run x`, `npm test`, `npm t`, `pnpm x`, `yarn x`), or undefined. */
function scriptName(a: readonly string[], scripts: Record<string, string>): string | undefined {
  if (!PM.has(a[0] ?? '')) return undefined
  // Leading options (npm --silent test, yarn -s build) stand before the subcommand; the value of a
  // value-taking one (npm --prefix dir, yarn --cwd dir, pnpm -F pkg) is not the subcommand.
  const takesValue = PM_VALUE_OPTS[a[0]!]!
  let k = -1
  for (let i = 1; i < a.length; i++) {
    const t = a[i]!
    if (takesValue.has(t)) i++
    else if (!t.startsWith('-')) {
      k = i
      break
    }
  }
  if (k < 0) return undefined
  const sub = a[k]!
  if (sub === 'run' || sub === 'run-script') return a.slice(k + 1).find(t => !t.startsWith('-'))
  if (sub === 'test' || sub === 't' || sub === 'tst') return 'test'
  if (a[0] !== 'npm' && Object.prototype.hasOwnProperty.call(scripts, sub)) return sub
  return undefined
}

async function judgePlatformRun($: EngineInterface, ctx: Ctx, all: Judged[], v: Verdict) {
  const exported: Record<string, string> = {}
  let scripts: Record<string, string> | undefined
  for (const { cmd, dir } of all) {
    const a = cmd.args
    if (a[0] === 'export') {
      for (const t of a.slice(1)) if (/^[A-Za-z_]\w*=/.test(t)) exported[t.slice(0, t.indexOf('='))] = t.slice(t.indexOf('=') + 1)
      continue
    }
    const env: Record<string, string> = { ...exported }
    for (const as of cmd.assign) env[as.slice(0, as.indexOf('='))] = as.slice(as.indexOf('=') + 1)
    let config: string | undefined
    let list = false
    const pw = a.findIndex((t, k) => /(^|\/)playwright$/.test(t) && a[k + 1] === 'test')
    if (pw >= 0) {
      const args = a.slice(pw + 2)
      for (let i = 0; i < args.length; i++) {
        const t = args[i]!
        if (t === '-c' || t === '--config') config = args[++i]
        else if (t.startsWith('--config=')) config = t.slice('--config='.length)
        else if (/^-c./.test(t)) config = t.slice(2)
        else if (t === '--list') list = true
      }
    } else if (PM.has(a[0] ?? '')) {
      scripts ??= (await readJson<{ scripts?: Record<string, string> }>($, `${ctx.root}/package.json`))?.scripts ?? {}
      const name = scriptName(a, scripts)
      const script = name === undefined ? '' : (scripts[name] ?? '')
      if (!/playwright test/.test(script)) continue
      config = /(?:-c|--config)[ =](\S+)/.exec(script)?.[1]
      list = /--list\b/.test(script) || a.includes('--list')
    } else continue
    const platformConfig = config !== undefined && PLATFORM_CONFIG.test(config)
    const platform = env.E2E_PLATFORM
    const caps = env.E2E_CAPABILITIES
    if (!platformConfig && caps === undefined && !(platform !== undefined && PLATFORM_VALUES.has(platform))) continue
    const say = (what: string) => v.notes.push(`${what} The platform run form: ${RUN_FORM} (${PLATFORM_REF}).`)
    if (caps !== undefined && capabilitiesFile(ctx, dir, caps) === undefined) {
      say(`Name a file under tests/capabilities/ with E2E_CAPABILITIES: ${caps} is not one; the run and the inspection session share tests/capabilities/<device>.json, the only place capabilities live.`)
      continue
    }
    if (list && platform === undefined) continue
    if (platform === undefined) say('Set E2E_PLATFORM=<android|ios> on this platform run: without it the fixture runs web.')
    else if (platform === 'macos' || platform === 'windows') say(`Run on android or ios: E2E_PLATFORM=${platform} is declared but not implemented yet.`)
    else if (platform !== 'android' && platform !== 'ios') say(`Set E2E_PLATFORM to android or ios for a platform run: '${platform}' is not one (web runs use the web config).`)
    else if (!platformConfig) say(`Run it with -c playwright.platform.config.ts (testDir tests/platform, workers: 1): this E2E_PLATFORM=${platform} run uses ${config ?? 'the web config'}.`)
    else if (caps === undefined && !list) say(`Name the device with E2E_CAPABILITIES=tests/capabilities/<device>.json: this E2E_PLATFORM=${platform} run names none.`)
  }
}

// ── protected state and the factory state dir: on a line naming them, every command must be a reader or a copy out ──

const esc = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
const namesRe = (names: string[]) => new RegExp(`(^|[^A-Za-z0-9_.-])(${names.map(esc).join('|')})([^A-Za-z0-9_.-]|$)`, 'i')
const literal = (w: string) => !/[$`*?[]/.test(w)

function inertMessageArgs(args: readonly string[]): Set<number> {
  const inert = new Set<number>()
  if (args[0] !== 'git' || !['commit', 'tag', 'merge'].includes(args[1] ?? '')) return inert
  for (let i = 2; i < args.length; i++) {
    const a = args[i]!
    if (a.startsWith('--message=') || (/^-[^-]*m./.test(a) && shortGroup(a.slice(0, a.indexOf('m') + 1)))) inert.add(i)
    else if (a === '--message' || a === '-m' || /^-[^-]*m$/.test(a)) inert.add(++i)
  }
  return inert
}

/** The findings of the armed-line judge: what each non-reader does on a line that names protected state. */
export function judgeArmed(all: Judged[], names: RegExp, label: string): { what: string; frag: string }[] {
  const hits = (w: string) => names.test(w)
  let armed = false
  for (const { cmd } of all) {
    const inert = inertMessageArgs(cmd.args)
    if ([...cmd.assign, ...cmd.writes, ...(cmd.chdir ? [cmd.chdir] : [])].some(hits)) armed = true
    cmd.args.forEach((a, i) => {
      if (!inert.has(i) && hits(a)) armed = true
    })
  }
  if (!armed) return []
  const out: { what: string; frag: string }[] = []
  const say = (what: string, frag: string) => out.push({ what, frag: frag.replace(/\n/g, ' ').slice(0, 80) })
  let inState = false
  for (const { cmd } of all) {
    const c = cmd.args[0]
    const frag = cmd.args.join(' ')
    if (cmd.wrapBad) say(`runs behind a wrapper option the judge cannot read while naming ${label}`, frag)
    for (const t of cmd.writes) {
      if (hits(t)) say(`redirects output into ${label}`, t)
      else if (!literal(t)) say(`redirects output to a target it cannot resolve (${t}) while naming ${label}`, t)
      else if (inState && !isAbsolute(t)) say(`redirects output from inside ${label}`, t)
    }
    if (c === undefined) continue
    if (c === 'cd' || c === 'pushd') {
      const to = cmd.args[1] ?? ''
      if (hits(to) || !literal(to)) inState = true
      continue
    }
    let touches = inState || c === 'xargs'
    if (cmd.chdir !== '' && (hits(cmd.chdir) || !literal(cmd.chdir))) touches = true
    const inert = inertMessageArgs(cmd.args)
    let substitution = false
    for (let i = 1; i < cmd.args.length; i++) {
      if (inert.has(i)) continue
      const a = cmd.args[i]!
      if (/\$\(|`/.test(a)) substitution = true
      if (hits(a) || !literal(a)) touches = true
    }
    if (substitution) {
      say(`runs a command substitution the judge cannot read while naming ${label}`, frag)
      continue
    }
    if (cmd.assign.some(hits)) touches = true
    if (!touches) continue
    if (c === 'find' ? !cmd.args.some(x => /^-(delete|exec|ok|fprint|fls)/.test(x)) : isReader(cmd.args)) continue
    if ((c === 'cp' || c === 'install') && !inState && copyOutOk(cmd.args, hits)) continue
    say(`runs ${c} on ${label}, which only readers and copying out of it may do`, frag)
  }
  return out
}

function copyOutOk(args: readonly string[], hits: (w: string) => boolean): boolean {
  let target = ''
  let ops = 0
  for (let i = 1; i < args.length; i++) {
    const a = args[i]!
    if (a === '-t' || a === '--target-directory' || /^-[^-]*t$/.test(a)) target = args[++i] ?? ''
    else if (a.startsWith('--target-directory=')) target = a.slice('--target-directory='.length)
    else if (a.startsWith('-')) {
      if (ops > 0) return false
    } else {
      ops++
      if (args[i + 1] === undefined && target === '') target = a
    }
  }
  return ops >= 1 && target !== '' && literal(target) && !hits(target)
}

function judgeProtected(ctx: Ctx, all: Judged[], v: Verdict) {
  const ledger = judgeArmed(all, namesRe([...PROTECTED_FILES, ...LEDGER_DOCS_DIRS]), 'the pipeline state files')
  if (ledger.length > 0) {
    const f = ledger[0]!
    v.notes.push(`this command ${f.what} (\`${f.frag}\`). The ledgers, journey map and cycle/coverage state change through the Write or Edit tool, where the ledger checks run; a shell write bypasses them (${STATE_REF}).`)
  }
  const state = ruleOf(ctx.rules, 'process.state')
  const stateDir = typeof state?.stateDir === 'string' ? state.stateDir.replace(/\/$/, '') : ''
  if (state && stateDir !== '') {
    const evidence = ruleOf(ctx.rules, 'process.evidence')
    const stamp = basename(typeof evidence?.stamp === 'string' ? evidence.stamp : 'verify-stamp')
    const marker = basename(typeof evidence?.currentChange === 'string' ? evidence.currentChange : 'current-change')
    const found = judgeArmed(all, namesRe([stateDir, stamp, marker]), `${stateDir}/`)
    if (found.length > 0) {
      const f = found[0]!
      v.notes.push(threeLine('process.state', `Bash command ${f.what} (\`${f.frag}\`) — its files are trust anchors written only by the project's own tools.`, typeof state.action === 'string' ? state.action : undefined, typeof state.doc === 'string' ? state.doc : undefined))
    }
  }
}

// ── the factory rule spend.opt-in: a spend-listed spec runs only with the per-segment opt-in ──

const VALUE_OPTS = new Set(['-c', '--config', '-g', '--grep', '-G', '--grep-invert', '--project', '--reporter', '--output', '--workers', '-j', '--retries', '--repeat-each', '--timeout', '--max-failures', '-x', '--shard', '--trace', '--test-list', '--test-list-invert', '--update-snapshots', '-u', '--tsconfig', '--global-timeout'])

async function judgeSpend($: EngineInterface, ctx: Ctx, all: Judged[], v: Verdict) {
  const rule = ruleOf(ctx.rules, 'spend.opt-in')
  if (!rule) return
  const listRel = typeof rule.list === 'string' ? rule.list : ''
  const envName = typeof rule.optInEnv === 'string' ? rule.optInEnv : ''
  const flag = typeof rule.optInFlag === 'string' ? rule.optInFlag : ''
  if (listRel === '' || envName === '' || flag === '') return
  const wrapper = typeof rule.wrapper === 'string' ? basename(rule.wrapper) : ''
  const spendProjects = new Set(strings(rule.spendProjects))
  const spendScripts = new Set(strings(rule.spendScripts))
  const triggers = all.some(({ cmd }) => cmd.args.some(t => /(^|\/)playwright$/.test(t)) || (wrapper !== '' && cmd.args.some(t => basename(t) === wrapper)) || (cmd.args[0] === 'npm' && cmd.args[1] === 'run' && spendScripts.has(cmd.args[2] ?? '')))
  if (!triggers) return
  const listDoc = await readJson<{ specs?: unknown }>($, `${ctx.root}/${listRel}`)
  if (!listDoc || !Array.isArray(listDoc.specs)) return v.notes.push(`${listRel} is missing or has no "specs" array, so the spend list could not be checked; the project wrapper still excludes the listed specs.`)
  const listed = listDoc.specs.filter((x): x is string => typeof x === 'string' && x !== '').map(x => normalize(x))
  const say = (what: string) => (v.deny ??= threeLine('spend.opt-in', what, typeof rule.action === 'string' ? rule.action : undefined, typeof rule.doc === 'string' ? rule.doc : undefined))
  const normArg = (raw: string, dir: string) => {
    const a = raw.replace(/:\d+(:\d+)?$/, '')
    if (a === '') return ''
    if (isAbsolute(a)) {
      const rel = relative(ctx.root, a)
      return rel.startsWith('..') ? normalize(a) : rel
    }
    if (a.includes('..')) {
      const rel = relative(ctx.root, resolve(dir, a))
      if (!rel.startsWith('..')) return rel
    }
    return normalize(a)
  }
  for (const { cmd, dir } of all) {
    const env: Record<string, string> = {}
    for (const as of cmd.assign) env[as.slice(0, as.indexOf('='))] = as.slice(as.indexOf('=') + 1)
    const envOk = env[envName] === '1'
    const rest = cmd.args
    const pw = rest.findIndex((t, j) => /(^|\/)playwright$/.test(t) && rest[j + 1] === 'test')
    const wr = wrapper === '' ? -1 : rest.findIndex(t => basename(t) === wrapper)
    let mode: 'pw' | 'wrapper'
    let args: string[]
    if (pw >= 0) {
      mode = 'pw'
      args = rest.slice(pw + 2)
    } else if (wr >= 0) {
      mode = 'wrapper'
      args = rest.slice(wr + 1)
    } else if (rest[0] === 'npm' && rest[1] === 'run' && spendScripts.has(rest[2] ?? '')) {
      if (!envOk) say(`Command runs a whole spend-incurring project (npm run ${rest[2]}), which includes the specs in ${listRel}.`)
      continue
    } else continue
    if (mode === 'pw' && envOk) continue
    if (mode === 'wrapper' && args.includes(flag)) continue
    const files: string[] = []
    const projects: string[] = []
    let expect: string | undefined
    for (const t of args) {
      if (expect !== undefined) {
        if (expect === '--project') projects.push(t)
        expect = undefined
        continue
      }
      if (t.startsWith('--project=')) projects.push(t.slice(10))
      else if (t.startsWith('-')) {
        if (!t.includes('=') && VALUE_OPTS.has(t)) expect = t
      } else files.push(t)
    }
    const optIn = mode === 'pw' ? `${envName}=1` : flag
    for (const f of files) {
      const a = normArg(f, dir)
      if (a === '') continue
      const hit = listed.find(e => e.includes(a) || a.includes(e))
      if (hit !== undefined) {
        say(`Command runs the spend-incurring spec ${basename(hit)} (listed in ${listRel}) without ${optIn}.`)
        return
      }
    }
    const unknown = [...files, ...projects].find(t => /\$|`/.test(t))
    if (unknown !== undefined) {
      say(`Command passes ${unknown} (a shell expansion) as a spec or project argument; the judge cannot tell whether it names a spend-incurring spec in ${listRel} — use a literal path (or ${optIn} for an owner-approved run).`)
      return
    }
    if (mode === 'pw' && files.length === 0) {
      if (projects.length === 0) {
        say(`\`playwright test\` with no --project and no file argument runs every project, including the spend-incurring specs in ${listRel}.`)
        return
      }
      const p = projects.find(x => spendProjects.has(x))
      if (p !== undefined) {
        say(`\`playwright test --project=${p}\` with no file argument would run the spend-incurring specs in ${listRel}.`)
        return
      }
    }
  }
}

// ── the judge ──

export async function judgeBash($: EngineInterface, command: string, w: Who): Promise<Verdict> {
  const v: Verdict = { notes: [], command }
  const root = await $.session.cwd()
  const home = (await $.env.get('HOME').catch(() => undefined)) ?? '/'
  const parsed = commands(command)
  const rules = await factoryRules($, root)
  if (parsed.overflow) {
    // Unsplit, nothing on the line is proved: the denies hold for any line that names their programs.
    if (/\b(git|rm|k6|playwright|gh|wdio)\b/.test(command)) v.deny = 'this command is too long to judge (over 32 KB); split it.'
    const state = ruleOf(rules, 'process.state')
    const stateDir = typeof state?.stateDir === 'string' ? state.stateDir.replace(/\/$/, '') : ''
    if (state && stateDir !== '' && command.toLowerCase().includes(stateDir.toLowerCase()))
      v.notes.push(threeLine('process.state', `Bash command is too long to split (over 32 KB), so it may reach ${stateDir}/ — its files are trust anchors written only by the project's own tools.`, typeof state.action === 'string' ? state.action : undefined, typeof state.doc === 'string' ? state.doc : undefined))
    return v
  }
  const ctx: Ctx = { root, home, who: w, rules, text: command }
  const all = expand(command, root, home)
  const inserts: { at: number; replaceTo?: number; text: string }[] = []
  for (const j of all) {
    await judgeGit($, ctx, j, v)
    judgeRm(ctx, j, v)
    await judgeK6($, ctx, j, v)
    await judgeGh($, ctx, j, v)
    judgePlaywrightCli(ctx, j, v, inserts)
    await judgeWdio($, ctx, j, v, inserts)
  }
  await judgePlatformRun($, ctx, all, v)
  judgeProtected(ctx, all, v)
  await judgeSpend($, ctx, all, v)
  if (v.deny === undefined && inserts.length > 0) {
    let out = command
    for (const ins of inserts.sort((a, b) => b.at - a.at)) out = `${out.slice(0, ins.at)}${ins.text}${out.slice(ins.replaceTo ?? ins.at)}`
    v.command = out
  }
  return v
}
