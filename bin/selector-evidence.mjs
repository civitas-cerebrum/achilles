#!/usr/bin/env node
// selector-evidence.mjs — live evidence for ONE committed page-repository entry.
//
// Consumers reach this through the `achilles-selector-evidence` bin:
//
//   npx achilles-selector-evidence --page CheckoutPage --element payButton \
//       --base-url https://shop.example.test --storage-state tests/data/.auth/shopper-a.json --url /checkout
//   npx achilles-selector-evidence --page HomePage --element searchBox --base-url https://shop.example.test --anonymous
//   npx achilles-selector-evidence --page CheckoutPage --element payButton --context north --url /checkout
//   npx achilles-selector-evidence --help
//
// WHY THIS EXISTS. A selector that looks right in the frontend source is often wrong live: it matches two
// elements, it matches a host that reads hidden while its dialog is open, or its accessible name is not what the
// source suggests. Rule 4 says "inspect the live site"; this tool makes the result of that inspection a committed,
// reviewable artefact — a note plus an outlined screenshot — instead of a sentence in a chat transcript.
//
// WHAT IT DOES. Reads the COMMITTED entry (it takes no selector argument, so evidence always describes what the
// suite will actually use), resolves it exactly as the framework does (@civitas-cerebrum/element-repository
// get(), frames included), requires exactly one match (at least one for an entry marked "list": true), outlines
// it with a <Page>.<element> label, screenshots the viewport (≤ 300 KB, clipped around the element when larger)
// and writes <out>/<Page>.<element>.{png,md}. The note is rendered and validated BEFORE any file is written, so a
// failed run never replaces a committed note or PNG.
//
// WHAT IT NEVER DOES. Click, type, submit or take a selector argument. It navigates, scrolls and reads. Its only
// raw locator is the optional --mask, which hides personal data in the screenshot.
//
// CONTEXTS. Where to open the page and with which session comes from flags (--base-url, --storage-state) or from
// the optional `contexts` map in achilles-factory-rules.json, picked with --context. Flags override the map.
// There are no built-in defaults: the tool cannot guess a project's URL or accounts.
//
// Exit codes: 0 note written · 1 evidence refused (count ≠ 1, resolution failed, PNG over cap, note invalid)
//             2 usage or configuration error (flags, unknown entry, missing storage state, Playwright unresolvable)

import * as fs from 'node:fs'
import * as path from 'node:path'
import { createRequire } from 'node:module'
import { DEFAULT_EVIDENCE_DIR, RULE_ID, TOOL_VERSION, cleanPath, fail, loadFactoryRules, redact, resolveAndCheck, validateNote, writeNoteText } from './evidence-note.mjs'

const MAX_PNG_BYTES = 300 * 1024
const VIEWPORT = { width: 1920, height: 1080 }
const DEFAULT_REPOSITORY = 'tests/data/page-repository.json'
// The default --out is the gate's default evidence dir, imported rather than restated: the two used to disagree,
// which left a project that omits `evidenceDir` writing notes the gate never reads. See evidence-note.mjs.
const DEFAULT_OUT = DEFAULT_EVIDENCE_DIR

const USAGE =
  'achilles-selector-evidence --page <Page> --element <element> (--base-url <url> [--storage-state <path>] | --context <name>) ' +
  '[--url <path>] [--out <dir>] [--repository <file>] [--mask <css>]… [--anonymous] [--help]'
const HELP = `Usage: ${USAGE}

Live evidence for one committed entry of the page repository: resolves it exactly as the framework does, requires
count 1 (≥ 1 for an entry marked "list": true), outlines it, screenshots the viewport (≤ 300 KB) and writes
<out>/<Page>.<element>.{png,md}. Never clicks, types or submits.

  --page, --element   the repository entry (no selector argument: evidence always describes the committed entry)
  --base-url          origin the --url is resolved against
  --storage-state     Playwright storage-state file for the signed-in session (required unless --anonymous)
  --context           name of an entry in the "contexts" map of achilles-factory-rules.json
                      ({ "<name>": { "baseUrl": "…", "storageState": "…" } }); flags override its fields
  --url               path to open (default "/"); the page must render the element without any interaction
  --out               output directory (default: rules["${RULE_ID}"].evidenceDir, else ${DEFAULT_OUT})
  --repository        page repository file (default ${DEFAULT_REPOSITORY})
  --mask              CSS selector masked in the screenshot (repeatable; default: none) — use it for personal data
  --anonymous         no session: open the page signed out (pre-login pages)
  --help              this text

Exit codes: 0 note written · 1 evidence refused · 2 usage or configuration error.
Rules file: $FACTORY_RULES, else achilles-factory-rules.json (optional).
`

// ── arguments ────────────────────────────────────────────────────────────────────────────────────────────────
const VALUED = new Set(['page', 'element', 'base-url', 'storage-state', 'context', 'url', 'out', 'repository', 'mask'])
function parseArgs(argv) {
  const a = { mask: [] }
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg === '--help' || arg === '-h') {
      process.stdout.write(HELP)
      process.exit(0)
    }
    if (arg === '--anonymous') {
      a.anonymous = true
      continue
    }
    const name = arg.startsWith('--') ? arg.slice(2) : ''
    if (VALUED.has(name)) {
      const value = argv[++i]
      if (value === undefined || value.startsWith('--'))
        fail(`Option --${name} needs a value (got ${value === undefined ? 'nothing' : value})`, `Use: ${USAGE}`, 'the-tool', 2)
      if (name === 'mask') a.mask.push(value)
      else a[name] = value
      continue
    }
    fail(`Unknown argument ${arg}`, `Use: ${USAGE}`, 'the-tool', 2)
  }
  return a
}

const args = parseArgs(process.argv.slice(2))
const cwd = process.cwd()
if (!args.page || !args.element) fail('Missing --page or --element', `Use: ${USAGE}`, 'the-tool', 2)

const rules = loadFactoryRules(cwd)
let ctx = {}
if (args.context) {
  ctx = rules.contexts?.[args.context]
  if (!ctx) {
    const known = Object.keys(rules.contexts ?? {})
    fail(
      `Unknown context ${args.context}`,
      known.length ? `Use one of: ${known.join(', ')} — or pass --base-url/--storage-state.` : 'Add a "contexts" map to achilles-factory-rules.json, or pass --base-url/--storage-state.',
      'config-and-contexts',
      2,
    )
  }
}
const baseUrl = args['base-url'] ?? ctx.baseUrl
const storageState = args.anonymous ? undefined : args['storage-state'] ?? ctx.storageState
if (!baseUrl) fail('No base URL: pass --base-url or --context', `Use: ${USAGE}`, 'config-and-contexts', 2)
try {
  new URL(baseUrl)
} catch {
  fail(`--base-url is not an absolute URL (${baseUrl})`, 'Pass an origin such as https://shop.example.test.', 'config-and-contexts', 2)
}
if (!args.anonymous && !storageState)
  fail('No session: pass --storage-state (or a context with storageState), or --anonymous for a signed-out page', `Use: ${USAGE}`, 'config-and-contexts', 2)
if (storageState && !fs.existsSync(path.resolve(cwd, storageState)))
  fail(`Storage state ${storageState} does not exist`, "Run the project's auth setup to produce it (the tool never logs in), then re-run.", 'config-and-contexts', 2)

const repoFile = path.resolve(cwd, args.repository ?? DEFAULT_REPOSITORY)
if (!fs.existsSync(repoFile)) fail(`Page repository ${path.relative(cwd, repoFile)} not found`, 'Pass --repository <file>.', 'the-tool', 2)
const repo = JSON.parse(fs.readFileSync(repoFile, 'utf8'))
const page = (repo.pages ?? []).find((p) => p.name === args.page)
const entry = page?.elements?.find((e) => e.elementName === args.element)
if (!entry)
  fail(
    `Unknown repository entry ${args.page}.${args.element}`,
    'Insert the entry first with "provisional": true, run this tool, then remove the flag in the same change.',
    'the-sequence',
    2,
  )

// Resolve Playwright and the element repository from the PROJECT, not from this file (same reasoning as mutate.mjs:
// a linked or hoisted package would otherwise resolve a different copy, or none). `require`, not `import()`: both
// are CommonJS and a dynamic import can yield a namespace without the named exports.
let chromium, ElementRepository
try {
  const req = createRequire(path.join(cwd, 'noop.js'))
  const pw = req('@playwright/test')
  chromium = pw?.chromium ?? pw?.default?.chromium
  ElementRepository = req('@civitas-cerebrum/element-repository').ElementRepository
  if (!chromium || !ElementRepository) throw new Error('module resolved but a required export is missing')
} catch (e) {
  fail(`@playwright/test or @civitas-cerebrum/element-repository unusable from ${cwd}: ${e.message}`, 'Run the tool from the project root after npm install.', 'the-tool', 2)
}

const key = `${args.page}.${args.element}`
const outDir = path.resolve(cwd, args.out ?? rules.rules?.[RULE_ID]?.evidenceDir ?? DEFAULT_OUT)
const pngPath = path.join(outDir, `${key}.png`)
const mdPath = path.join(outDir, `${key}.md`)
const contextLabel = `${args.context ?? 'flags'}${args.anonymous ? ' (anonymous)' : ''}`

// ── live run ─────────────────────────────────────────────────────────────────────────────────────────────────
const browser = await chromium.launch({ headless: process.env.HEADED !== '1' })
let failure
try {
  const context = await browser.newContext({ storageState, viewport: VIEWPORT })
  const pw = await context.newPage()
  await pw.goto(new URL(args.url ?? '/', baseUrl).toString(), { waitUntil: 'domcontentloaded', timeout: 60_000 })
  await pw.waitForLoadState('load', { timeout: 30_000 }).catch(() => {})
  const where = cleanPath(new URL(pw.url()).pathname)

  const er = new ElementRepository(pw, repoFile, 30_000)
  const { locator } = await er.get(args.element, args.page) // the framework's own resolution, frames included
  const list = entry.list === true
  const check = await resolveAndCheck(locator, {
    key,
    list,
    where,
    framed: Boolean(page.frame),
    frameTitles: () =>
      pw.evaluate(() => [...document.querySelectorAll('iframe')].map((f) => f.getAttribute('title') ?? f.getAttribute('name') ?? '(untitled)')),
  })

  if (!check.ok) {
    failure = [check.what, check.action]
  } else {
    const first = locator.first()
    await first.scrollIntoViewIfNeeded({ timeout: 10_000 }).catch(() => {})
    await first.evaluate((node, label) => {
      node.style.outline = '3px solid #ff3b30'
      node.style.outlineOffset = '2px'
      const tag = node.ownerDocument.createElement('div')
      tag.textContent = label
      const r = node.getBoundingClientRect() // the label sits just above the element, so a clipped shot still shows it
      Object.assign(tag.style, {
        position: 'fixed', top: `${Math.max(0, r.top - 30)}px`, left: `${Math.max(0, r.left)}px`, zIndex: '2147483647',
        background: '#ff3b30', color: '#fff', font: '14px monospace', padding: '4px 8px',
      })
      node.ownerDocument.body.appendChild(tag)
      const vw = node.ownerDocument.defaultView?.innerWidth ?? 1920
      if (r.left + tag.offsetWidth > vw) tag.style.left = `${Math.max(0, vw - tag.offsetWidth - 4)}px`
    }, key)
    const meta = await first.evaluate((n) => ({
      tag: n.tagName.toLowerCase(),
      role: n.getAttribute('role'),
      name: n.getAttribute('aria-label') || n.textContent?.trim().replace(/\s+/g, ' ').slice(0, 80),
      dataAttrs: [...n.attributes].filter((a) => a.name.startsWith('data-')).slice(0, 3).map((a) => `${a.name}=${a.value}`).join(', '),
    }))
    const aria = await first.ariaSnapshot({ timeout: 5_000 }).then((s) => s.split('\n')[0]).catch(() => '')

    // Rendered and validated BEFORE any file is written: a refusal leaves committed files alone.
    const text = validateNote({
      key,
      selector: entry.selector,
      context: contextLabel,
      url: where,
      date: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
      tool: `selector-evidence ${TOOL_VERSION}`,
      count: check.count,
      list,
      meta: { ...meta, name: meta.name ? redact(meta.name) : meta.name, dataAttrs: redact(meta.dataAttrs) },
      aria: redact(aria),
      screenshot: `${key}.png`,
      source: 'live',
    })

    const mask = args.mask.map((css) => pw.locator(css)) // the only raw locators this tool holds
    let png = await pw.screenshot({ mask })
    if (png.length > MAX_PNG_BYTES) {
      const b = (await first.boundingBox()) ?? { x: VIEWPORT.width / 2, y: VIEWPORT.height / 2, width: 0, height: 0 }
      for (const [w, h] of [[1280, 720], [960, 540], [640, 360]]) {
        // centre the element when it fits (label included); otherwise keep its top-left corner and label in view
        const x0 = b.width + 80 <= w ? b.x + b.width / 2 - w / 2 : b.x - 40
        const y0 = b.height + 80 <= h ? b.y + b.height / 2 - h / 2 : b.y - 40
        const clip = { x: Math.max(0, Math.min(VIEWPORT.width - w, x0)), y: Math.max(0, Math.min(VIEWPORT.height - h, y0)), width: w, height: h }
        png = await pw.screenshot({ mask, clip })
        if (png.length <= MAX_PNG_BYTES) break
      }
    }
    if (png.length > MAX_PNG_BYTES) {
      failure = [`${key}.png would be ${Math.round(png.length / 1024)} KB (cap 300 KB)`, 'Re-run on a calmer --url (fewer images in view); nothing over the cap is written.']
    } else {
      fs.mkdirSync(outDir, { recursive: true })
      fs.writeFileSync(pngPath, png)
      writeNoteText(mdPath, text)
      process.stdout.write(text + `png: ${path.relative(cwd, pngPath)} (${Math.round(png.length / 1024)} KB)\n`)
    }
  }
} catch (e) {
  failure = [`${key} could not be resolved: ${String(e?.message ?? e).split('\n')[0]}`, 'Check the --url (the page must render the element) and the frame the entry names, then re-run.']
} finally {
  await browser.close().catch(() => {})
}
if (failure) fail(failure[0], failure[1], 'the-tool', 1)
process.exit(0)
