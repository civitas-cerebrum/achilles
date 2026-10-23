import type { EngineInterface, On } from 'claude-code'

import { LEDGER_DOCS_DIRS, PROTECTED_FILES } from '../data/protected-paths.mjs'
import {
  editExpert,
  exists,
  factoryRules,
  hashText,
  isDisabled,
  note,
  placeFile,
  readJson,
  readText,
  ruleOf,
  run,
  strings,
  threeLine,
  who,
  writtenText,
  type FactoryRules,
  type Who,
} from './context'
import { basename, isAbsolute, normalize, relative, resolve, within } from './posix'
import { contentSecret } from './secrets'
import { commands, gitCall, isReader, nestedCommand, unresolved, type Command } from './shell'

// Hook 1, the Bash judge: one parsed-command model, small judges. Denies only what is
// irreversible or dangerous (a hook or signing bypass, AI attribution on a commit or PR, a
// force-push, a recursive delete outside the project, a k6 run past the ceilings, a spend-listed
// spec without its opt-in); advises on commit grammar, shell writes to protected state and the
// factory verify stamp; rewrites a missing playwright-cli slug. The main loop is never touched.

const REFS = (...paths: string[]) => `\n\nReferences:\n${paths.map(p => `  ${p}`).join('\n')}`
const COMMIT_REF = 'skills/achilles-orchestrator/references/commit-conventions.md'
const CLI_REF = 'skills/achilles-orchestrator/references/playwright-cli-protocol.md'
const PERF_REF = 'skills/performance-testing/SKILL.md'
const STATE_REF = 'skills/achilles-orchestrator/references/state-files.md'

const ATTRIBUTION = /(^|['"\s])\s*co-authored-by:.*(claude|anthropic|noreply@anthropic\.com)|generated with.*claude(\s+code)?\b|claude\.ai\/code/i
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
  if (ATTRIBUTION.test(scan)) v.deny ??= `AI-attribution in a commit (Co-Authored-By: Claude …, "Generated with Claude Code", a claude.ai/code URL) is refused: commits made by Achilles agents carry no AI attribution. Remove the trailer and commit again.${REFS(COMMIT_REF)}`
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

// ── gh pr create|edit: attribution (deny). The sign-off hook judges the publish itself. ──

async function judgeGh($: EngineInterface, ctx: Ctx, j: Judged, v: Verdict) {
  const a = j.cmd.args
  if (a[0] !== 'gh' || a[1] !== 'pr' || (a[2] !== 'create' && a[2] !== 'edit')) return
  let scan = ctx.text
  for (let i = 3; i < a.length; i++) {
    const t = a[i]!
    const file = t === '--body-file' || t === '-F' ? a[++i] : t.startsWith('--body-file=') ? t.slice('--body-file='.length) : undefined
    if (file !== undefined && file !== '-') scan += `\n${(await readText($, resolve(j.dir, file, ctx.home))) ?? ''}`
  }
  if (ATTRIBUTION.test(scan)) v.deny ??= `AI-attribution in a pull request (Co-Authored-By: Claude …, "Generated with Claude Code", a claude.ai/code URL) is refused: PRs made by Achilles agents carry no AI attribution. Remove it from the title and body.${REFS(COMMIT_REF)}`
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
    if (/\b(git|rm|k6|playwright|gh)\b/.test(command)) v.deny = 'this command is too long to judge (over 32 KB); split it.'
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
  }
  judgeProtected(ctx, all, v)
  await judgeSpend($, ctx, all, v)
  if (v.deny === undefined && inserts.length > 0) {
    let out = command
    for (const ins of inserts.sort((a, b) => b.at - a.at)) out = `${out.slice(0, ins.at)}${ins.text}${out.slice(ins.replaceTo ?? ins.at)}`
    v.command = out
  }
  return v
}

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
