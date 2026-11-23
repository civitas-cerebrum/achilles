// platform-evidence.mjs — `achilles-selector-evidence --platform <android|ios>`: the evidence note for ONE committed
// entry of a platform page (page `platform` android or ios), built OFFLINE from the inspection material the expert
// already captured in its `npx wdio session`:
//
//   npx wdio session -s <slug> source --path <scratch>/Settings.xml                       (the page source XML)
//   npx wdio session -s <slug> screenshot <ref> --path <scratch>/SettingsPage.networkRow.png   (the ELEMENT shot;
//                                                    <ref> from `snapshot -i --all --selectors`)
//   npx achilles-selector-evidence --platform ios --page SettingsPage --element networkRow \
//       --capabilities tests/capabilities/iphone.json --screen Settings \
//       --source <scratch>/Settings.xml --screenshot <scratch>/SettingsPage.networkRow.png
//
// It never opens a session, never starts a browser and never touches a device: it resolves the committed selector
// against the saved page source, records what it found and copies the screenshot beside the note. Forms it cannot
// evaluate faithfully offline are written down as "unresolved offline (<why>)" — never as a guessed count.
//
// The note's fields, in this order (the order is a cross-team contract): selector, platform, capabilities, screen,
// resolved count, class, accessibility id, id, label, source snippet, screenshot, source. `- selector:` is the
// repository selector JSON (the repository-evidence gate compares it deep-equal); `capabilities` is the file PATH,
// never a capability value.
//
// Exit codes as the web mode: 0 note written · 1 evidence refused · 2 usage or configuration error.
import * as fs from 'node:fs'
import * as path from 'node:path'
import { projectRoot } from './project-root.mjs'
import { DEFAULT_EVIDENCE_DIR, NOTE_REFUSED, RULE_ID, fail, loadFactoryRules, redact } from './evidence-note.mjs'

export const IMPLEMENTED = ['android', 'ios']
export const DECLARED = ['macos', 'windows']
export const NOTE_FIELDS = ['selector', 'platform', 'capabilities', 'screen', 'resolved count', 'class', 'accessibility id', 'id', 'label', 'source snippet', 'screenshot', 'source']
export const CAPABILITIES_DIR = 'tests/capabilities/'
/** An element screenshot on a 3x display can pass the web 300 KB cap; 1 MB still keeps the evidence dir reviewable. */
export const MAX_PNG_BYTES = 1024 * 1024
// wdio CLI 10.2.0: `source` and `screenshot` write the file named by --path (stdout is a status line, not the XML).
const SOURCE_CMD = 'npx wdio session -s <slug> source --path <scratch>/<screen>.xml'
const SHOT_CMD = 'npx wdio session -s <slug> screenshot <ref> --path <scratch>/<Page>.<element>.png'
const POSITIONAL = 'positional: needs a "fallback" or a known-issues row'

export const USAGE =
  'achilles-selector-evidence --platform <android|ios> --page <Page> --element <element> --capabilities tests/capabilities/<device>.json ' +
  '--screen <name> --source <page-source.xml> --screenshot <screen.png> [--context <name>] [--out <dir>] [--repository <file>]'

// ── XML: the subset Appium page sources use (elements, attributes, comments, declarations; no text content) ──────

const ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" }
const decode = (s) =>
  s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (m, e) =>
    e[0] === '#' ? String.fromCodePoint(e[1] === 'x' || e[1] === 'X' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10)) : ENTITIES[e] ?? m,
  )

/** Parses a page source into { tag: '#document', children } nodes with { tag, attrs, children, parent, raw, order }. */
export function parseXml(text) {
  const doc = { tag: '#document', attrs: {}, children: [], parent: null, raw: '', order: -1 }
  const stack = [doc]
  let order = 0
  const re = /<!--[\s\S]*?-->|<\?[\s\S]*?\?>|<!\[CDATA\[[\s\S]*?\]\]>|<![^>]*>|<\/\s*([^\s>]+)\s*>|<([^\s/>!?]+)((?:\s+[^\s=/>]+\s*=\s*(?:"[^"]*"|'[^']*'))*)\s*(\/?)>/g
  let m
  while ((m = re.exec(text))) {
    if (m[1] !== undefined) {
      if (stack.length > 1 && stack[stack.length - 1].tag === m[1]) stack.pop()
      else throw new Error(`unbalanced closing tag </${m[1]}>`)
      continue
    }
    if (m[2] === undefined) continue
    const attrs = {}
    for (const a of m[3].matchAll(/([^\s=/>]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)) attrs[a[1]] = decode(a[2] ?? a[3] ?? '')
    const parent = stack[stack.length - 1]
    const node = { tag: m[2], attrs, children: [], parent, raw: m[0], order: order++ }
    parent.children.push(node)
    if (m[4] !== '/') stack.push(node)
  }
  if (doc.children.length === 0) throw new Error('no element found')
  return doc
}

const descendants = (n, self = false) => {
  const out = self ? [n] : []
  const walk = (x) => x.children.forEach((c) => (out.push(c), walk(c)))
  walk(n)
  return out
}
const docOrder = (nodes) => [...new Set(nodes)].sort((a, b) => a.order - b.order)
const elements = (doc) => descendants(doc)

class Unresolved extends Error {}
const unresolved = (why) => {
  throw new Unresolved(why)
}

// ── the platform's view of a node (the attributes UiAutomator2 / XCUITest write) ──────────────────────────────────

const VIEW = {
  ios: {
    cls: (n) => n.attrs.type ?? n.tag,
    accessibilityId: (n) => n.attrs.name,
    id: (n) => n.attrs.name, // A4: `id` on ios is the name lookup
    label: (n) => n.attrs.label || n.attrs.value,
  },
  android: {
    cls: (n) => n.attrs.class ?? n.tag,
    accessibilityId: (n) => n.attrs['content-desc'],
    id: (n) => n.attrs['resource-id'],
    label: (n) => n.attrs.text || n.attrs['content-desc'],
  },
}

// ── NSPredicate subset (predicate, class chain): `attr OP value` joined by AND ──────────────────────────────────────

const PREDICATE_ATTRS = new Set(['name', 'label', 'value', 'type', 'enabled', 'visible', 'accessible', 'selected'])
const BOOLEAN_ATTRS = new Set(['enabled', 'visible', 'accessible', 'selected'])
const PREDICATE_OPS = { '==': (a, b) => a === b, '=': (a, b) => a === b, '!=': (a, b) => a !== b, CONTAINS: (a, b) => a.includes(b), BEGINSWITH: (a, b) => a.startsWith(b), ENDSWITH: (a, b) => a.endsWith(b) }

/** Splits on a keyword outside quotes. */
function splitOutsideQuotes(s, sep) {
  const parts = []
  let q = null
  let start = 0
  for (let i = 0; i < s.length; i++) {
    const c = s[i]
    if (q) {
      if (c === '\\') unresolved('escaped characters in a quoted value')
      if (c === q) q = null
    } else if (c === '"' || c === "'") q = c
    else if (sep.test(s.slice(i)) && /\s/.test(s[i - 1] ?? ' ')) {
      const m = sep.exec(s.slice(i))
      parts.push(s.slice(start, i))
      i += m[0].length - 1
      start = i + 1
    }
  }
  if (q) unresolved('an unterminated quote')
  parts.push(s.slice(start))
  return parts
}

export function compilePredicate(expr) {
  if (/^\s*$/.test(expr)) unresolved('an empty predicate')
  const clauses = splitOutsideQuotes(expr, /^(AND|&&)\s/i).map((c) => c.trim())
  const tests = clauses.map((c) => {
    if (splitOutsideQuotes(c, /^(OR|\|\|)\s/i).length > 1) unresolved('OR is outside the offline predicate subset (attr OP value joined by AND)')
    const m = /^([A-Za-z]+)\s*(==|=|!=|CONTAINS|BEGINSWITH|ENDSWITH)\s*('([^']*)'|"([^"]*)"|true|false|TRUE|FALSE|YES|NO|1|0)$/.exec(c)
    if (!m) unresolved(`"${c}" is outside the offline predicate subset (attr ==|!=|CONTAINS|BEGINSWITH|ENDSWITH 'value', joined by AND; no [c]/[d] modifiers, OR, NOT, MATCHES, LIKE, IN or parentheses)`)
    const attr = m[1]
    if (!PREDICATE_ATTRS.has(attr)) unresolved(`the predicate attribute "${attr}" is not in the page source`)
    const quoted = m[4] ?? m[5]
    // XCUITest compares booleans as numbers: `enabled == 1` / `enabled == true` match, `enabled == 'true'` does not
    // compare the way the source text suggests, so only unquoted booleans on boolean attributes resolve offline.
    if (BOOLEAN_ATTRS.has(attr) && quoted !== undefined) unresolved(`"${c}" compares the boolean attribute ${attr} with a quoted string; write it unquoted (${attr} == true)`)
    if (!BOOLEAN_ATTRS.has(attr) && quoted === undefined) unresolved(`"${c}" compares the string attribute ${attr} with an unquoted value`)
    if (BOOLEAN_ATTRS.has(attr) && !/^(==|=|!=)$/.test(m[2])) unresolved(`"${c}" applies ${m[2]} to the boolean attribute ${attr}`)
    const want = quoted ?? (/^(true|yes|1)$/i.test(m[3]) ? 'true' : 'false')
    const op = PREDICATE_OPS[m[2].toUpperCase()]
    return (n) => op(n.attrs[attr] ?? '', want)
  })
  return (n) => tests.every((t) => t(n))
}

// ── iOS class chain subset: Type|* segments, '/' child, '**/' descendant, [`predicate`] filters; no indices ─────

export function evalClassChain(doc, expr) {
  const base = elements(doc).find((n) => n.tag === 'XCUIElementTypeApplication') ?? doc
  const segs = []
  let i = 0
  while (i < expr.length) {
    let deep = false
    if (expr.startsWith('**/', i)) {
      deep = true
      i += 3
    }
    const t = /^(\*|[A-Za-z]+)/.exec(expr.slice(i))
    if (!t) unresolved(`class chain segment at "${expr.slice(i)}" is outside the offline subset`)
    i += t[0].length
    const preds = []
    while (expr[i] === '[') {
      if (expr[i + 1] === '$') unresolved('a class chain descendant predicate [$…$] is not evaluated offline')
      if (expr[i + 1] !== '`') unresolved('class chain indices ([n], [-n]) are positional and are not evaluated offline')
      const end = expr.indexOf('`]', i + 2)
      if (end < 0) unresolved('an unterminated class chain predicate')
      preds.push(compilePredicate(expr.slice(i + 2, end)))
      i = end + 2
    }
    segs.push({ deep, type: t[1], preds })
    if (i < expr.length) {
      if (expr[i] !== '/') unresolved(`class chain text "${expr.slice(i)}" is outside the offline subset`)
      i++
    }
  }
  let ctx = [base]
  for (const s of segs) {
    const next = []
    for (const c of ctx)
      for (const n of s.deep ? descendants(c) : c.children)
        if ((s.type === '*' || n.tag === s.type) && s.preds.every((p) => p(n))) next.push(n)
    ctx = docOrder(next)
  }
  return { nodes: ctx }
}

// ── Android UiSelector subset: new UiSelector() with text/description/resourceId/className matchers ────────────────

const UI_METHODS = {
  text: (n, v) => n.attrs.text === v,
  textContains: (n, v) => (n.attrs.text ?? '').includes(v),
  textStartsWith: (n, v) => (n.attrs.text ?? '').startsWith(v),
  description: (n, v) => n.attrs['content-desc'] === v,
  descriptionContains: (n, v) => (n.attrs['content-desc'] ?? '').includes(v),
  descriptionStartsWith: (n, v) => (n.attrs['content-desc'] ?? '').startsWith(v),
  resourceId: (n, v) => n.attrs['resource-id'] === v,
  className: (n, v) => (n.attrs.class ?? n.tag) === v,
}

export function evalUiSelector(doc, expr) {
  const m = /^\s*new\s+UiSelector\(\)\s*((?:\.\w+\("[^"\\]*"\)\s*)+);?\s*$/.exec(expr)
  if (!m) unresolved('only `new UiSelector()` chains of text/textContains/textStartsWith/description/descriptionContains/descriptionStartsWith/resourceId/className("…") are evaluated offline (UiScrollable, instance(), index() and regex matchers are not)')
  const calls = [...m[1].matchAll(/\.(\w+)\("([^"]*)"\)/g)].map(([, name, v]) => {
    if (!UI_METHODS[name]) unresolved(`UiSelector.${name}() is outside the offline subset`)
    return (n) => UI_METHODS[name](n, v)
  })
  return { nodes: elements(doc).filter((n) => n.tag !== 'hierarchy' && calls.every((c) => c(n))) }
}

// ── XPath subset ──────────────────────────────────────────────────────────────────────────────────────────────────
// Absolute location paths of '/' and '//' steps; node test '*' or an element name; predicates [n], [last()],
// [@a], [@a="v"], [@a!="v"], [contains(@a,"v")], [starts-with(@a,"v")], conditions joined by 'and'; one optional
// wrapper (path)[n] | (path)[last()]. A numeric or last() predicate makes the selector positional. Everything else
// (axes, text(), functions, unions, 'or', relative paths) is "unresolved offline".

function parsePredicate(body) {
  const b = body.trim()
  if (/^\d+$/.test(b)) return { pos: Number(b) }
  if (b === 'last()') return { pos: 'last' }
  const conds = b.split(/\s+and\s+/).map((c) => {
    let m
    if ((m = /^@([\w:.-]+)$/.exec(c))) return (n) => m[1] in n.attrs
    if ((m = /^@([\w:.-]+)\s*(!?=)\s*(?:"([^"]*)"|'([^']*)')$/.exec(c))) {
      const [, a, op, d, s] = m
      const v = d ?? s
      // XPath: @a != "v" is true only for an element that HAS @a with another value.
      return op === '=' ? (n) => n.attrs[a] === v : (n) => a in n.attrs && n.attrs[a] !== v
    }
    if ((m = /^(contains|starts-with)\(\s*@([\w:.-]+)\s*,\s*(?:"([^"]*)"|'([^']*)')\s*\)$/.exec(c))) {
      const [, fn, a, d, s] = m
      const v = d ?? s
      return fn === 'contains' ? (n) => (n.attrs[a] ?? '').includes(v) : (n) => (n.attrs[a] ?? '').startsWith(v)
    }
    unresolved(`the xpath predicate [${b}] is outside the offline subset`)
  })
  return { test: (n) => conds.every((c) => c(n)) }
}

function parsePath(p) {
  if (!p.startsWith('/')) unresolved('relative xpath is not evaluated offline; start it with / or //')
  const steps = []
  let i = 0
  while (i < p.length) {
    const deep = p.startsWith('//', i)
    if (!deep && p[i] !== '/') unresolved(`xpath text "${p.slice(i)}" is outside the offline subset`)
    i += deep ? 2 : 1
    const t = /^(\*|[A-Za-z_][\w.-]*)/.exec(p.slice(i))
    if (!t || p[i + t[0].length] === ':' || p[i + t[0].length] === '(') unresolved(`xpath step at "${p.slice(i)}" is outside the offline subset (no axes or functions)`)
    i += t[0].length
    const preds = []
    while (p[i] === '[') {
      let depth = 0
      let q = null
      let j = i
      for (; j < p.length; j++) {
        const c = p[j]
        if (q) {
          if (c === q) q = null
        } else if (c === '"' || c === "'") q = c
        else if (c === '[') depth++
        else if (c === ']' && --depth === 0) break
      }
      if (j >= p.length) unresolved('an unterminated xpath predicate')
      preds.push(parsePredicate(p.slice(i + 1, j)))
      i = j + 1
    }
    steps.push({ deep, name: t[1], preds })
  }
  return steps
}

const applyPreds = (list, preds) => {
  let out = list
  for (const pr of preds) {
    if (pr.pos !== undefined) {
      const k = pr.pos === 'last' ? out.length : pr.pos
      out = out[k - 1] ? [out[k - 1]] : []
    } else out = out.filter(pr.test)
  }
  return out
}

export function evalXpath(doc, expr) {
  const x = expr.trim()
  if (/\|/.test(x.replace(/"[^"]*"|'[^']*'/g, ''))) unresolved('xpath unions (|) are not evaluated offline')
  let path = x
  let outer = null
  const w = /^\((.*)\)\s*\[\s*(\d+|last\(\))\s*\]$/.exec(x)
  if (w) {
    path = w[1].trim()
    outer = w[2] === 'last()' ? 'last' : Number(w[2])
  }
  const steps = parsePath(path)
  let positional = outer !== null
  let ctx = [doc]
  for (const s of steps) {
    if (s.preds.some((p) => p.pos !== undefined)) positional = true
    const next = []
    for (const c of ctx)
      for (const parent of s.deep ? descendants(c, true) : [c])
        next.push(...applyPreds(parent.children.filter((n) => s.name === '*' || n.tag === s.name), s.preds))
    ctx = docOrder(next)
  }
  if (outer !== null) {
    const k = outer === 'last' ? ctx.length : outer
    ctx = ctx[k - 1] ? [ctx[k - 1]] : []
  }
  return { nodes: ctx, positional }
}

// ── one selector against one page source ──────────────────────────────────────────────────────────────────────────

const ALIASES = { accessibilityid: 'accessibility id', classname: 'class name', androiduiautomator: 'uiautomator', iosnspredicatestring: 'predicate', iosclasschain: 'class chain' }
const IOS_ONLY = new Set(['predicate', 'class chain'])
const ANDROID_ONLY = new Set(['uiautomator'])

/** Positional forms read off the selector TEXT, so a form the tool cannot evaluate is still flagged. */
export function isPositional(key, value) {
  const bare = String(value).replace(/"[^"]*"|'[^']*'|`[^`]*`/g, '""')
  if (key === 'xpath') return /\[\s*\d+\s*\]/.test(bare) || /\b(position|last)\s*\(\s*\)/.test(bare)
  if (key === 'class chain') return /\[\s*-?\d+\s*\]/.test(bare)
  if (key === 'uiautomator') return /\.(instance|index)\s*\(/.test(bare)
  return false
}

/**
 * Resolves a repository selector on a parsed page source. Returns { nodes, positional } or { unresolved, positional }.
 * Returns { wrongPlatform } when the strategy cannot exist on this platform at all.
 */
export function resolveSelector(doc, selector, platform) {
  const keys = Object.keys(selector ?? {}).filter((k) => k !== 'fallback')
  if (keys.map((k) => k.toLowerCase()).sort().join('+') === 'name+role')
    return { unresolved: 'role + name is the enhanced accessibility lookup; it has no page-source equivalent and is not evaluated offline' }
  if (keys.length !== 1) return { unresolved: keys.length === 0 ? 'the selector has no strategy key' : `combined strategies (${keys.join(' + ')}) are not evaluated offline` }
  const key = ALIASES[keys[0].toLowerCase()] ?? keys[0].toLowerCase()
  const r = resolveOne(doc, key, keys[0], selector[keys[0]], platform)
  return typeof selector[keys[0]] === 'string' && isPositional(key, selector[keys[0]]) ? { ...r, positional: true } : r
}

function resolveOne(doc, key, rawKey, value, platform) {
  if (typeof value !== 'string') return { unresolved: `the ${key} value is not a string` }
  if ((platform === 'android' && IOS_ONLY.has(key)) || (platform === 'ios' && ANDROID_ONLY.has(key))) return { wrongPlatform: key }
  const v = VIEW[platform]
  const all = () => elements(doc)
  try {
    switch (key) {
      case 'accessibility id':
        return { nodes: all().filter((n) => v.accessibilityId(n) === value) }
      case 'id':
        if (platform === 'android' && !value.includes(':')) {
          // UiAutomator2 completes a short id with the app package (the top node's), then tries android:id/.
          const appPackage = all().find((n) => n.attrs.package)?.attrs.package
          const mine = appPackage ? all().filter((n) => v.id(n) === `${appPackage}:id/${value}`) : []
          return { nodes: mine.length > 0 ? mine : all().filter((n) => v.id(n) === `android:id/${value}`) }
        }
        return { nodes: all().filter((n) => v.id(n) === value) }
      case 'class name':
        return { nodes: all().filter((n) => n.tag !== 'hierarchy' && v.cls(n) === value) }
      case 'text':
        return { nodes: all().filter((n) => (platform === 'ios' ? n.attrs.label : n.attrs.text) === value) }
      case 'xpath':
        return evalXpath(doc, value)
      case 'predicate': {
        const p = compilePredicate(value)
        // The search runs below the application element, as XCUITest's does.
        return { nodes: all().filter((n) => n.tag.startsWith('XCUIElementType') && n.tag !== 'XCUIElementTypeApplication' && p(n)) }
      }
      case 'class chain':
        return evalClassChain(doc, value)
      case 'uiautomator':
        return evalUiSelector(doc, value)
      default:
        return { unresolved: `the "${rawKey}" strategy is not resolvable offline` }
    }
  } catch (e) {
    if (e instanceof Unresolved) return { unresolved: e.message }
    throw e
  }
}

// ── the note ──────────────────────────────────────────────────────────────────────────────────────────────────────

const oneLine = (s) => String(s).replace(/\s+/g, ' ').trim()
const dash = (v) => (v === undefined || v === null || v === '' ? '—' : v)

/** `n` = { key, platform, selector, capabilities, screen, count, list, positional, unresolved, node, screenshot, source }. */
export function renderPlatformNote(n) {
  const v = VIEW[n.platform]
  const node = n.node
  const count = (n.unresolved !== undefined ? `unresolved offline (${oneLine(n.unresolved)})` : `${n.count}${n.list ? ' (list entry)' : ''}`) + (n.positional ? ` (${POSITIONAL})` : '')
  const label = node ? v.label(node) : undefined
  const snippet = node ? '`' + oneLine(node.raw).replace(/`/g, "'").slice(0, 300) + '`' : undefined
  const values = {
    selector: JSON.stringify(n.selector),
    platform: n.platform,
    capabilities: n.capabilities,
    screen: oneLine(n.screen),
    'resolved count': count,
    class: dash(node && v.cls(node)),
    'accessibility id': dash(node && redact(v.accessibilityId(node) ?? '')),
    id: dash(node && redact(v.id(node) ?? '')),
    label: label ? JSON.stringify(redact(oneLine(label)).slice(0, 80)) : '—',
    'source snippet': dash(snippet && redact(snippet)),
    screenshot: dash(n.screenshot),
    source: n.source,
  }
  return [`# ${n.key} (${n.platform})`, ...NOTE_FIELDS.map((f) => `- ${f}: ${values[f]}`)].join('\n') + '\n'
}

function validate(n) {
  const err = (msg) => Object.assign(new Error(msg), { code: NOTE_REFUSED })
  if (!n.source) throw err(`refusing to write the ${n.key} note: it has no source`)
  const text = renderPlatformNote(n)
  const offending = text.split('\n').find((l) => l.includes('@') && !l.startsWith('- selector:'))
  if (offending !== undefined) throw err(`refusing to write the ${n.key} note: ${JSON.stringify(oneLine(offending).slice(0, 120))} contains '@' (personal data?)`)
  return text
}

// ── the command ──────────────────────────────────────────────────────────────────────────────────────────────────

const VALUED = new Set(['context', 'platform', 'page', 'element', 'capabilities', 'screen', 'source', 'screenshot', 'out', 'repository'])
const posix = (p) => p.split(path.sep).join('/')

function parseArgs(argv) {
  const a = {}
  for (let i = 0; i < argv.length; i++) {
    const name = argv[i].startsWith('--') ? argv[i].slice(2) : ''
    if (!VALUED.has(name)) fail(`Unknown argument ${argv[i]} for --platform mode`, `Use: ${USAGE}`, 'platform-pages', 2)
    const value = argv[++i]
    if (value === undefined || value.startsWith('--')) fail(`Option --${name} needs a value`, `Use: ${USAGE}`, 'platform-pages', 2)
    a[name] = value
  }
  return a
}

/** Refuses anything but a path to a JSON file under tests/capabilities/; returns the project-relative path. */
function capabilitiesFile(root, value, platform) {
  // The value is never echoed: a mistaken inline value may carry a device id or a credential.
  // Inline: JSON, a quote, whitespace, '=' or a colon that is not a drive letter (C:\ or C:/).
  const colon = value.replace(/^[A-Za-z]:[\\/]/, '').includes(':')
  if (/^\s*[{[]/.test(value) || /["'\s=]/.test(value) || colon)
    fail('--capabilities was given capability values inline', `Pass the path of a capabilities file (${CAPABILITIES_DIR}<device>.json), the same file the test run and the inspection session use. Capabilities live only in those files.`, 'platform-pages', 2)
  const rel = posix(path.relative(root, path.resolve(root, value)))
  if (!rel.startsWith(CAPABILITIES_DIR) || rel.includes('../') || !rel.endsWith('.json'))
    fail(`--capabilities is not a path under ${CAPABILITIES_DIR}`, `Pass ${CAPABILITIES_DIR}<device>.json: the only place a project keeps capabilities.`, 'platform-pages', 2)
  let caps
  try {
    caps = JSON.parse(fs.readFileSync(path.join(root, rel), 'utf8'))
  } catch (e) {
    fail(`Capabilities file ${rel} is missing or not JSON (${e.code ?? 'parse error'})`, 'Pass the capabilities file the inspection session used.', 'platform-pages', 2)
  }
  const named = caps?.platformName ?? caps?.alwaysMatch?.platformName ?? caps?.capabilities?.alwaysMatch?.platformName
  if (typeof named === 'string' && named.toLowerCase() !== platform)
    fail(`The platformName in ${rel} does not name ${platform}`, `Pass the capabilities file of a ${platform} device, or the --platform that file targets.`, 'platform-pages', 2)
  return rel
}

function inputFile(root, value, flag, hint) {
  const abs = path.resolve(root, value)
  if (!fs.existsSync(abs) || !fs.statSync(abs).isFile()) fail(`--${flag} ${value} does not exist`, hint, 'platform-pages', 2)
  return abs
}

/**
 * Which mode a command line asks for: the --platform value, else the `platform` of the --context it names, else web.
 * A web context ({ baseUrl, storageState }) and no --platform keep the web mode.
 */
export function platformOf(argv, rules = {}) {
  const at = (flag) => {
    const i = argv.indexOf(flag)
    return i >= 0 ? argv[i + 1] : undefined
  }
  const explicit = at('--platform')
  if (explicit !== undefined) return explicit
  const ctx = rules.contexts?.[at('--context')]
  return typeof ctx?.platform === 'string' ? ctx.platform : 'web'
}

export function runPlatform(argv, rules = loadFactoryRules(projectRoot())) {
  const args = parseArgs(argv)
  if (args.context !== undefined) {
    // A platform context gives the platform and the capabilities file. Its `server` is never read here: evidence is
    // offline, and the server value (a URL or env:<VAR>) has no place in a note or a message.
    const ctx = rules.contexts?.[args.context]
    if (!ctx || typeof ctx.platform !== 'string')
      fail(`--context ${args.context} is not a platform context`, 'Name a context of achilles-factory-rules.json shaped { "platform", "capabilities", "server" }, or pass --platform and --capabilities.', 'platform-pages', 2)
    if (args.platform !== undefined && args.platform !== ctx.platform)
      fail(`--platform ${args.platform} contradicts context ${args.context} (platform ${ctx.platform})`, 'Drop --platform, or pick the context of that platform.', 'platform-pages', 2)
    args.platform = ctx.platform
    args.capabilities ??= ctx.capabilities
  }
  const platform = args.platform
  if (platform === 'web') fail('--platform web is the default mode', 'Omit --platform for web pages and pass --base-url or a web --context.', 'platform-pages', 2)
  if (DECLARED.includes(platform))
    fail(`Platform ${platform} is declared but not implemented yet`, `Selector evidence runs for ${IMPLEMENTED.join(' and ')} pages today.`, 'platform-pages', 2)
  if (!IMPLEMENTED.includes(platform)) fail(`Unknown --platform ${platform}`, `Use --platform android | ios (web pages: omit --platform).`, 'platform-pages', 2)
  for (const f of ['page', 'element', 'capabilities', 'screen', 'source', 'screenshot'])
    if (!args[f]) fail(`Missing --${f}`, `Use: ${USAGE}`, 'platform-pages', 2)
  if (/[\n\r]/.test(args.screen)) fail('--screen must be one line', 'Pass the screen name as tests/platform/docs/app-context.md keys it.', 'platform-pages', 2)

  const root = projectRoot()
  const capabilities = capabilitiesFile(root, args.capabilities, platform)

  const ruleRepo = rules.rules?.[RULE_ID]?.repository
  const defaultRepo = fs.existsSync(path.join(root, 'tests/e2e/page-repository.json')) ? 'tests/e2e/page-repository.json' : 'tests/platform/page-repository.json'
  const repoFile = path.resolve(root, args.repository ?? ruleRepo ?? defaultRepo)
  if (!fs.existsSync(repoFile)) fail(`Page repository ${posix(path.relative(root, repoFile))} not found`, 'Pass --repository <file>.', 'the-tool', 2)
  const repo = JSON.parse(fs.readFileSync(repoFile, 'utf8'))
  const named = (repo.pages ?? []).filter((p) => p.name === args.page)
  const page = named.find((p) => (p.platform ?? 'web') === platform)
  if (!page) {
    const have = named.map((p) => p.platform ?? 'web')
    fail(`Page "${args.page}" has no entry for platform "${platform}". Available: ${have.length ? have.join(', ') : 'none'}.`, `Add a { "name": "${args.page}", "platform": "${platform}" } page to the repository (one page name, one selector set per platform).`, 'platform-pages', 2)
  }
  const entry = page.elements?.find((e) => e.elementName === args.element)
  if (!entry)
    fail(`Unknown repository entry ${args.page}.${args.element} on the ${platform} page`, 'Insert the entry first with "provisional": true, run this tool, then remove the flag in the same change.', 'the-sequence', 2)

  const sourceFile = inputFile(root, args.source, 'source', `Save the page source first: ${SOURCE_CMD}, on the screen named by --screen.`)
  const shotFile = inputFile(root, args.screenshot, 'screenshot', `Save the element screenshot first: ${SHOT_CMD} (the ref from snapshot -i --all --selectors), on the same screen.`)
  const png = fs.readFileSync(shotFile)
  if (png.length < 8 || png.readUInt32BE(0) !== 0x89504e47) fail(`--screenshot ${args.screenshot} is not a PNG`, `Pass the PNG that ${SHOT_CMD} saved.`, 'platform-pages', 2)
  if (png.length > MAX_PNG_BYTES)
    fail(`--screenshot is ${Math.round(png.length / 1024)} KB (cap ${MAX_PNG_BYTES / 1024} KB)`, `Take the element screenshot instead of the full screen: ${SHOT_CMD}, then re-run; nothing over the cap is written.`, 'platform-pages', 1)

  let doc
  try {
    doc = parseXml(fs.readFileSync(sourceFile, 'utf8'))
  } catch (e) {
    fail(`--source ${args.source} is not a page source (${e.message})`, `Pass the XML file that ${SOURCE_CMD} wrote.`, 'platform-pages', 2)
  }

  const key = `${args.page}.${args.element}`
  const list = entry.list === true
  const r = resolveSelector(doc, entry.selector, platform)
  if (r.wrongPlatform)
    fail(`${key} uses the ${r.wrongPlatform} strategy, which does not exist on ${platform}`, 'Pick a strategy of this platform (CONTRACT order: accessibility id, then id / predicate, then class chain / uiautomator, then text, xpath last).', 'platform-pages', 1)
  if (r.nodes) {
    const count = r.nodes.length
    if (!(list ? count >= 1 : count === 1)) {
      const candidates = r.nodes.slice(0, 8).map((n) => `${VIEW[platform].cls(n)}${VIEW[platform].label(n) ? ` ${JSON.stringify(redact(VIEW[platform].label(n)))}` : ''}`)
      fail(
        `${key} resolved to ${count} elements on screen ${oneLine(args.screen)}${candidates.length ? ` (candidates: ${candidates.join(', ')})` : ''}`,
        count === 0
          ? 'Capture the source on the screen where the element is rendered (scroll it into view first), or fix the selector through live inspection, then re-run.'
          : 'Tighten the selector until exactly one element matches (or mark a genuine list entry "list": true), then re-run.',
        'platform-pages',
        1,
      )
    }
  }

  const evDir = path.resolve(root, args.out ?? rules.rules?.[RULE_ID]?.evidenceDir ?? DEFAULT_EVIDENCE_DIR)
  const base = `${key}.${platform}`
  let text
  try {
    text = validate({
      key,
      platform,
      selector: entry.selector,
      capabilities,
      screen: args.screen,
      count: r.nodes?.length,
      list,
      positional: r.positional === true,
      unresolved: r.unresolved,
      node: r.nodes?.[0],
      screenshot: `${base}.png`,
      source: 'live (wdio session page source)',
    })
  } catch (e) {
    fail(String(e.message), `Nothing was written to ${posix(path.relative(root, evDir))}. Insert the entry with the rule's provisional flag and a known-issues row if the observed text cannot be kept out.`, 'the-tool', 1)
  }
  fs.mkdirSync(evDir, { recursive: true })
  fs.writeFileSync(path.join(evDir, `${base}.png`), png)
  fs.writeFileSync(path.join(evDir, `${base}.md`), text)
  if (r.unresolved !== undefined)
    process.stderr.write(`[${RULE_ID}] ${key} (${platform}): unresolved offline (${r.unresolved}); the note says so and carries no count. Confirm the element in the live snapshot, or prefer a strategy the tool resolves.\n`)
  if (r.positional) process.stderr.write(`[${RULE_ID}] ${key} (${platform}): the selector is positional; the entry needs a "fallback" or a known-issues row.\n`)
  process.stdout.write(text + `png: ${posix(path.relative(root, path.join(evDir, `${base}.png`)))} (${Math.round(png.length / 1024)} KB)\n`)
  process.exit(0)
}
