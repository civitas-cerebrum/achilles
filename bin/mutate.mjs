#!/usr/bin/env node
// mutate.mjs — behavioural mutation testing: prove the suite can FAIL.
//
// Consumers reach this through the `achilles-mutate` bin:
//
//   npx achilles-mutate                          # uses .achilles/mutations.mjs
//   npx achilles-mutate --config path/to/muts.mjs
//   npx achilles-mutate --only pills-hidden      # one mutation, for iterating
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
async function checkApplied({ css, init, appliedWhen }) {
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
      viewport,
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

if (!process.env.PLAYWRIGHT_TEST_BASE_URL) {
  console.error('✖ PLAYWRIGHT_TEST_BASE_URL is required — mutations run against a deployed target.')
  process.exit(2)
}

fs.mkdirSync(OUT, { recursive: true })

const queue = ONLY ? mutations.filter((m) => m.id === ONLY || m.id === 'noop') : mutations
const results = []

for (const m of queue) {
  process.stdout.write(`\n▶ ${m.id} — ${m.what || ''}\n`)
  const run = spawnSync('npx', ['playwright', 'test', ...specs, '--reporter=json'], {
    encoding: 'utf8',
    maxBuffer: 128 * 1024 * 1024,
    env: { ...process.env, E2E_MUTATION_CSS: m.css ?? '', E2E_MUTATION_INIT: m.init ?? '' },
  })
  const failed = failedTests(run.stdout || '')
  const caught = failed.length > 0

  let applied = { applied: null, reason: 'not needed — mutation was caught' }
  if (!caught && m.id !== 'noop') {
    applied = await checkApplied(m).catch((e) => ({ applied: null, reason: `check errored: ${e.message}` }))
  }

  results.push({ ...m, caught, failedTests: failed, applied })

  // The control is the one mutation where "nothing failed" is the GOOD outcome, so it must not
  // print as SURVIVED — that reads as a failure and buries the line that matters. It also never
  // runs an applied-check (there is nothing to apply), so the default reason would leak in.
  let line
  if (m.id === 'noop') {
    line = caught ? `CONTROL RED — ${failed.join(', ')} (harness is breaking the page)` : 'control green — results are meaningful'
  } else if (caught) {
    line = `CAUGHT by ${failed.join(', ')}`
  } else if (applied.applied === true) {
    line = 'SURVIVED — mutation applied and no test failed'
  } else if (applied.applied === false) {
    line = `VOID — mutation never took effect (${applied.reason})`
  } else {
    line = `UNCHECKED — no test failed, and the applied-check could not run (${applied.reason})`
  }
  process.stdout.write(`   ${line}\n`)
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
