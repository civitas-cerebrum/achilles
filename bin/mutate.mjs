#!/usr/bin/env node
// mutate.mjs — behavioural mutation testing: prove the suite can FAIL.
//
// Consumers reach this through the `achilles-mutate` bin:
//
//   npx achilles-mutate                          # uses .achilles/mutations.mjs
//   npx achilles-mutate --config path/to/muts.mjs
//   npx achilles-mutate --only pills-hidden      # one mutation, for iterating
//   npx achilles-mutate --calibrate              # prove the applied-checks discriminate
//   npx achilles-mutate --repeat 3               # flake control: owner must fail 2 of 3
//   npx achilles-mutate --concurrency 4          # run mutations in parallel
//
// WHY THIS EXISTS. A green suite proves nothing until you have seen it go red
// for the right reason. Mutation testing injects the broken state an acceptance
// criterion forbids and checks that the suite notices. See
// skills/ticket-driven-testing/SKILL.md §8b.
//
// WHY IT IS A BIN AND NOT A PROSE RECIPE. It was a prose recipe first, and
// every subtlety in it drew blood in practice:
//
//   - `addInitScript(str)` silently does nothing; it wants `{ content: str }`.
//     That one produced a reported coverage hole that did not exist.
//   - A mutation "caught" by fifteen tests is usually a broken shared
//     precondition, not coverage — and it destroys the report's ability to say
//     WHICH criterion regressed. Hence owner-based classification.
//   - An un-applied mutation is indistinguishable from an uncaught one. Both
//     leave the suite green. Reading the second as a hole manufactures work.
//
// Prose cannot carry that reliably into the next project. Code can.
//
// WHY BROWSER-LEVEL AND NOT SOURCE-LEVEL. Source mutation needs a locally
// runnable app. QA work frequently targets a deployed preview that cannot be
// rebuilt. Injecting CSS/JS to recreate the broken state is weaker in one way
// (it binds to behaviour, not to the source change) and stronger in another
// (it tests the artifact that actually shipped).

import { spawnSync } from 'node:child_process'
import * as fs from 'node:fs'
import * as path from 'node:path'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'

const argv = process.argv.slice(2)
const flag = (name, fallback) => {
  const i = argv.indexOf(`--${name}`)
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback
}

const CONFIG = path.resolve(flag('config', '.achilles/mutations.mjs'))
const ONLY = flag('only', null)
// Flake control. One run per mutation means ANY failing test counts as CAUGHT, so on a suite with
// a realistic 1-2% flake rate a mutation pass reports coverage it did not measure — the instrument
// rule broken inside the tool that implements it. With --repeat N a mutation is CAUGHT only if the
// same test fails in a MAJORITY of runs, and the noop control must be green in a majority too.
const REPEAT = Math.max(1, parseInt(flag('repeat', '1'), 10) || 1)
// Mutations are independent runs against a deployed URL — embarrassingly parallel. Serial was
// costing N x suite-runtime, which is what makes this unaffordable on a slow suite.
const CONCURRENCY = Math.max(1, parseInt(flag('concurrency', '1'), 10) || 1)
const OUT = path.resolve('.achilles/mutation-out')

if (!fs.existsSync(CONFIG)) {
  console.error(`✖ No mutation config at ${path.relative(process.cwd(), CONFIG)}`)
  console.error(`
Create one. It exports \`specs\` (the specs to run) and \`mutations\`:

  export const specs = ['tests/regression/feature.spec.ts']
  export const startPath = '/the/page/under/test'
  export const mutations = [
    { id: 'noop', what: 'harness control — nothing injected' },
    {
      id: 'pills-hidden',
      ac: 'AC-1',
      what: 'the filter row is not rendered at all',
      css: '[data-pills]{display:none!important}',
      // The test that OWNS this criterion. If some OTHER test catches the
      // mutation, that is a broken shared precondition, not coverage.
      expectedCatchers: ['TC_001', 'TC_002'],
      // Evaluated IN THE PAGE. Must be true once the mutation is live.
      // A selector alone is too weak: most mutations change a computed style
      // rather than adding a node.
      appliedWhen: 'getComputedStyle(document.querySelector("[data-pills]")).display==="none"',
      // Only if the mutation is width-scoped: check it where it actually applies.
      // checkViewport: { width: 1280, height: 900 },
    },
  ]

Your project's page fixture must forward the two injection variables, because a
Playwright config cannot add them:

  if (process.env.E2E_MUTATION_INIT) await page.addInitScript({ content: process.env.E2E_MUTATION_INIT })
  if (process.env.E2E_MUTATION_CSS) {
    const css = process.env.E2E_MUTATION_CSS
    page.on('load', () => { page.addStyleTag({ content: css }).catch(() => {}) })
  }
`)
  process.exit(2)
}

const cfg = await import(pathToFileURL(CONFIG).href)
const { specs = [], mutations = [], startPath = '/', control = null, viewport = { width: 1440, height: 900 } } = cfg

if (!specs.length) {
  console.error('✖ config exports no `specs` — nothing to run.')
  process.exit(2)
}
if (!mutations.some((m) => m.id === 'noop')) {
  // Not a style preference. Without it there is no way to tell "the suite catches mutations"
  // from "the harness breaks the page and everything is red".
  console.error('✖ config has no `noop` mutation. The harness needs its own control.')
  console.error('  Add: { id: "noop", what: "harness control — nothing injected" }')
  process.exit(2)
}

/** Test IDs that did not pass. `test.fail()` sentinels are expected-fail and count as passing,
 *  so they can never masquerade as a caught mutation. */
function failedTests(stdout) {
  const start = stdout.indexOf('{')
  if (start < 0) return ['<no-json-report>']
  let report
  try {
    report = JSON.parse(stdout.slice(start))
  } catch {
    return ['<report-parse-failed>']
  }
  const failed = []
  const walk = (suites) =>
    (suites || []).forEach((s) => {
      ;(s.specs || []).forEach((sp) => {
        if (sp.ok === false) failed.push(sp.title.match(/TC_[A-Z0-9_]+/)?.[0] || sp.title.slice(0, 48))
      })
      walk(s.suites)
    })
  walk(report.suites)
  return failed
}

/**
 * Did the mutation actually take effect?
 *
 * Only asked when a mutation SURVIVED — if a test went red the mutation self-evidently applied,
 * and a browser launch per mutation is not free.
 */
async function checkApplied({ css, init, appliedWhen, checkViewport }) {
  if (!appliedWhen) return { applied: null, reason: 'no appliedWhen declared' }

  // Resolve Playwright from the PROJECT, not from this file. A bare `import('@playwright/test')`
  // resolves relative to the bin's own location, which is wrong whenever the package is linked,
  // run from a sibling checkout, or hoisted differently than the consumer — and the failure is
  // silent, degrading every applied-check to "unknown".
  // `require`, not `import()`. @playwright/test is CJS and re-exports through a path the
  // cjs-module-lexer cannot statically read, so dynamic import yields a namespace with NO named
  // exports and `chromium` comes back undefined — which surfaces as a TypeError at .launch()
  // rather than as a resolution failure, i.e. a confusing error one call too late.
  let chromium
  try {
    const req = createRequire(path.join(process.cwd(), 'noop.js'))
    const pw = req('@playwright/test')
    chromium = pw?.chromium ?? pw?.default?.chromium
    if (!chromium) throw new Error('module resolved but exports no `chromium`')
  } catch (e) {
    return { applied: null, reason: `@playwright/test unusable from ${process.cwd()}: ${e.message}` }
  }

  const browser = await chromium.launch()
  try {
    const ctx = await browser.newContext({
      // A width-scoped mutation (`@media (max-width: …)`) does not apply at the run's default
      // viewport, so a check performed there reports false for a mutation that works perfectly —
      // and the runner would call that VOID. `checkViewport` lets the check run where the mutation
      // is actually in scope. Found by --calibrate, before it ever produced a false verdict.
      viewport: checkViewport || viewport,
      bypassCSP: true,
      extraHTTPHeaders: JSON.parse(process.env.E2E_MUTATION_HEADERS || '{}'),
    })
    const page = await ctx.newPage()
    if (init) await page.addInitScript({ content: init })
    if (css) page.on('load', () => { page.addStyleTag({ content: css }).catch(() => {}) })

    const base = process.env.PLAYWRIGHT_TEST_BASE_URL
    await page.goto(new URL(startPath, base).toString(), { waitUntil: 'domcontentloaded' })

    // CONTROL. A false applied-check means nothing if the page never rendered — a CDN challenge,
    // an auth wall and a broken URL all present as "every selector is absent".
    if (control) {
      await page.waitForSelector(control, { timeout: 30000 }).catch(() => {})
      if (!(await page.locator(control).count())) {
        return { applied: null, reason: `CONTROL "${control}" MISSING — page did not render; check is void` }
      }
    }

    if (cfg.beforeCheck) await cfg.beforeCheck(page)

    const applied = await page.evaluate((expr) => {
      try { return Boolean(eval(expr)) } catch { return false }
    }, appliedWhen)
    return { applied, reason: applied ? 'observed in page' : 'expression evaluated false' }
  } finally {
    await browser.close()
  }
}

// --calibrate: prove the applied-checks can produce BOTH answers, before any of them is believed.
//
// This exists because the rule said "control the checker" and the tool gave you no way to do it.
// The check is deliberately unreachable for the control mutation during a normal run (there is
// nothing to apply), so the negative direction cannot be observed from a run log — it needs its
// own command, and it needs to leave an artifact. A checker verified only in the positive
// direction is indistinguishable from one hard-wired to `true`, which fails silently and in the
// direction that hides coverage holes.
if (argv.includes('--calibrate')) {
  if (!process.env.PLAYWRIGHT_TEST_BASE_URL) {
    console.error('✖ PLAYWRIGHT_TEST_BASE_URL is required.')
    process.exit(2)
  }
  console.log('──── calibrating applied-checks ────')
  console.log('Each expression must report TRUE with its mutation injected and FALSE with nothing')
  console.log('injected. An expression that cannot report both is not measuring the mutation.\n')

  let bad = 0
  for (const m of mutations.filter((x) => x.appliedWhen)) {
    const on = await checkApplied(m).catch((e) => ({ applied: null, reason: e.message }))
    // Same expression, no injection. Anything other than false means the expression is reading
    // something the mutation did not cause.
    const off = await checkApplied({ appliedWhen: m.appliedWhen }).catch((e) => ({ applied: null, reason: e.message }))
    const ok = on.applied === true && off.applied === false
    if (!ok) bad++
    console.log(`${ok ? '✓' : '✖'} ${m.id.padEnd(26)} injected=${String(on.applied).padEnd(5)} clean=${String(off.applied).padEnd(5)}${ok ? '' : `   ← ${on.applied !== true ? `injected: ${on.reason}` : `clean: ${off.reason}`}`}`)
  }

  console.log(`\n${mutations.filter((x) => x.appliedWhen).length - bad} of ${mutations.filter((x) => x.appliedWhen).length} applied-checks discriminate.`)
  if (bad) {
    console.log('\nA check that cannot report both answers must not be trusted:')
    console.log('  injected!=true  → the expression does not detect its own mutation (false VOIDs).')
    console.log('  clean!=false    → it reports true regardless, so every mutation looks applied.')
  }
  process.exit(bad ? 1 : 0)
}

if (!process.env.PLAYWRIGHT_TEST_BASE_URL) {
  console.error('✖ PLAYWRIGHT_TEST_BASE_URL is required — mutations run against a deployed target.')
  process.exit(2)
}

fs.mkdirSync(OUT, { recursive: true })

const queue = ONLY ? mutations.filter((m) => m.id === ONLY || m.id === 'noop') : mutations
const results = []

const runOnce = (m) =>
  failedTests(
    spawnSync('npx', ['playwright', 'test', ...specs, '--reporter=json'], {
      encoding: 'utf8',
      maxBuffer: 128 * 1024 * 1024,
      env: { ...process.env, E2E_MUTATION_CSS: m.css ?? '', E2E_MUTATION_INIT: m.init ?? '' },
    }).stdout || '',
  )

/** A test counts as failing only if it failed in MORE THAN HALF the repeats. */
const majorityFailures = (passes) => {
  const need = Math.floor(passes.length / 2) + 1
  const tally = new Map()
  for (const failed of passes) for (const t of new Set(failed)) tally.set(t, (tally.get(t) || 0) + 1)
  return [...tally.entries()].filter(([, n]) => n >= need).map(([t]) => t)
}

const runMutation = async (m) => {
  const passes = []
  for (let i = 0; i < REPEAT; i++) passes.push(runOnce(m))
  const failed = majorityFailures(passes)
  const caught = failed.length > 0
  // Flake visible across repeats is worth surfacing: it is why a single-run verdict lies.
  const unstable = REPEAT > 1 && passes.some((p) => p.length !== passes[0].length)

  let applied = { applied: null, reason: 'not needed — mutation was caught' }
  if (!caught && m.id !== 'noop') {
    applied = await checkApplied(m).catch((e) => ({ applied: null, reason: `check errored: ${e.message}` }))
  }
  return { ...m, caught, failedTests: failed, applied, unstable }
}

/** Bounded-concurrency map. Mutations never touch each other's state, only the shared target. */
const mapLimit = async (items, limit, fn) => {
  const out = new Array(items.length)
  let next = 0
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, async () => {
      while (next < items.length) {
        const i = next++
        out[i] = await fn(items[i])
      }
    }),
  )
  return out
}

// The control runs FIRST and ALONE. If the harness is breaking the page, every parallel result
// behind it is void, and there is no point spending the machine time to find that out.
const noopEntry = queue.find((m) => m.id === 'noop')
const rest = queue.filter((m) => m.id !== 'noop')

process.stdout.write(`\n▶ noop — ${noopEntry.what || 'harness control'}\n`)
const noopResult = await runMutation(noopEntry)
process.stdout.write(`   ${noopResult.caught ? `CONTROL RED — ${noopResult.failedTests.join(', ')}` : 'control green — results are meaningful'}\n`)
results.push(noopResult)

if (!noopResult.caught) {
  if (CONCURRENCY > 1) process.stdout.write(`\nRunning ${rest.length} mutations, ${CONCURRENCY} at a time${REPEAT > 1 ? `, ${REPEAT}x each` : ''}.\n`)
  // The per-mutation verdict, live. Deleting this once already made a run go quiet between the
  // header and the summary — and the REASON on a VOID/UNCHECKED only appears here, so losing it
  // means losing the one line that says why a result cannot be believed.
  const verdictLine = (r) => {
    if (r.caught) return `CAUGHT by ${r.failedTests.join(', ')}`
    if (r.applied?.applied === true) return 'SURVIVED — mutation applied and no test failed'
    if (r.applied?.applied === false) return `VOID — mutation never took effect (${r.applied.reason})`
    return `UNCHECKED — no test failed, and the applied-check could not run (${r.applied?.reason})`
  }

  const done = await mapLimit(rest, CONCURRENCY, async (m) => {
    if (CONCURRENCY === 1) process.stdout.write(`\n▶ ${m.id} — ${m.what || ''}\n`)
    const r = await runMutation(m)
    const prefix = CONCURRENCY > 1 ? `   ${r.id}: ` : '   '
    process.stdout.write(prefix + verdictLine(r) + '\n')
    // Repeats that disagree are the whole reason --repeat exists: say so, rather than silently
    // taking the majority and presenting it as a clean result.
    if (r.unstable) process.stdout.write(`   ⚠ flaky across repeats — the majority verdict above hides disagreement\n`)
    return r
  })
  results.push(...done)
}

fs.writeFileSync(path.join(OUT, 'mutation-report.json'), JSON.stringify(results, null, 2))

const noop = results.find((r) => r.id === 'noop')
const real = results.filter((r) => r.id !== 'noop')

console.log('\n──────── mutation report ────────')
if (noop?.caught) {
  console.log(`✖ HARNESS INVALID — the no-op control went red (${noop.failedTests.join(', ')}).`)
  console.log('  The harness is breaking the page, not the mutations being caught. All results void.')
  process.exit(2)
}
console.log('✓ control (noop): suite green — results are meaningful\n')

// Three outcomes, not two. An un-applied mutation is a VOID measurement, not a survivor:
// calling it a survivor manufactures a coverage hole that does not exist.
const classify = (r) => {
  // Three ways a mutation can fail to be caught, and they mean different things. Collapsing the
  // last two into one verdict is how an infrastructure failure gets read as a coverage fact —
  // which is the same class of error VOID was introduced to prevent, so it must not be repeated
  // one level up.
  if (!r.caught && r.applied?.applied === false) return 'VOID'      // checked: never took effect
  if (!r.caught && r.applied?.applied !== true) return 'UNCHECKED'  // could not check at all
  if (!r.caught) return 'SURVIVED'                                   // checked: applied, nothing failed
  if (!r.expectedCatchers?.length) return 'CAUGHT'
  return r.expectedCatchers.some((e) => r.failedTests.some((f) => f.includes(e))) ? 'CAUGHT' : 'WRONG-TEST'
}

const survivors = [], wrongTest = [], voids = [], unchecked = []
for (const r of real) {
  const v = classify(r)
  if (v === 'SURVIVED') survivors.push(r)
  if (v === 'WRONG-TEST') wrongTest.push(r)
  if (v === 'VOID') voids.push(r)
  if (v === 'UNCHECKED') unchecked.push(r)
  const mark = { CAUGHT: '✓ caught  ', 'WRONG-TEST': '⚠ WRONG-TEST', VOID: '· VOID     ', UNCHECKED: '? UNCHECKED', SURVIVED: '✖ SURVIVED' }[v]
  const shown = r.failedTests.slice(0, 4).join(', ') + (r.failedTests.length > 4 ? ` (+${r.failedTests.length - 4})` : '')
  const owner = r.expectedCatchers?.length ? `  [owner: ${r.expectedCatchers.join('/')}]` : ''
  console.log(`${mark} ${r.id.padEnd(26)} ${r.caught ? shown : '(nothing failed)'}${owner}`)
}

const ok = real.length - survivors.length - wrongTest.length - voids.length - unchecked.length
console.log(`\n${survivors.length} survived, ${wrongTest.length} caught by the WRONG test, ${voids.length} VOID (never applied), ${unchecked.length} UNCHECKED, ${ok}/${real.length} caught by their owner.`)
if (unchecked.length) {
  console.log('\nUNCHECKED means the applied-check could not RUN — an infrastructure failure, not')
  console.log('a fact about coverage. Do not read it as a survivor and do not read it as a void:')
  unchecked.forEach((u) => console.log(`  ${u.id}: ${u.applied?.reason}`))
}

if (voids.length) {
  console.log('\nVOID means the mutation never took effect — it says NOTHING about coverage.')
  console.log('Fix the injection and re-run before reading any verdict for: ' + voids.map((v) => v.id).join(', '))
}
if (wrongTest.length) {
  console.log('\nWRONG-TEST means a shared precondition failed, not that the criterion is covered.')
  console.log('Blast radius is a bug in the SUITE: find what every failing test has in common.')
}
if (survivors.length) {
  console.log('\nA SURVIVED mutation is a finding, not a suggestion: a stated criterion has no test')
  console.log('that can fail for it. Do not target zero — a survivor with a written, defensible')
  console.log('reason is a decision. Narrow the test\'s CLAIM rather than over-fitting its assertion.')
}

process.exit(survivors.length || wrongTest.length || voids.length || unchecked.length ? 1 : 0)
