import type { EngineInterface, On } from 'claude-code'

import {
  afterContent,
  editExpert,
  exists,
  factoryRules,
  isDisabled,
  isPageRepository,
  isSpecPath,
  maskComments,
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
import { basename, inScope, resolve, within } from './posix'

// Hook 6, spec hygiene: a Write or Edit under tests/ (and the root runner config) by an achilles
// expert is screened for test IDs, the import boundary, the factory intake / inline-selector /
// repository-evidence rules, the evidence floor of a diagnosing expert and the journey map's
// authorship marker. Everything is a note to the writing loop; nothing is refused. The two heavy
// scanners run as node children with a timeout, and say so when they could not run.

const ID_REF = 'skills/achilles-orchestrator/references/test-identity.md'
const BOUNDARY_REF = 'skills/achilles-orchestrator/references/spec-shape.md'
const FD_REF = 'skills/failure-diagnosis/SKILL.md'
const MAP_REF = 'skills/journey-mapping/SKILL.md'
const MAP = 'tests/e2e/docs/journey-map.md'
const SENTINEL = '<!-- journey-mapping:generated -->'
const EVIDENCE = /trace\.zip|\.trace([^a-z]|$)|error-context\.md|test-failed-[0-9]*\.png|video\.webm|page@[0-9a-f]*\.jpe?g|results\.json|\/test-results\/|\/playwright-report\/|show-trace|show-report|gh run download|actions\/runs\/[^ ]*\/artifacts/
const CODE = /\.(ts|mts|cts|js|mjs|cjs)$/

type W = { tool: string; file_path: string; content?: string; old_string?: string; new_string?: string; replace_all?: boolean }

// ── test IDs: one pattern source (CIVITAS_TEST_ID_PATTERN, else the factory titleIdPattern, else the house shape) ──

async function testIds($: EngineInterface, rel: string, before: string, after: string, rules: FactoryRules | undefined): Promise<string[]> {
  const override = await $.env.get('CIVITAS_TEST_ID_PATTERN').catch(() => undefined)
  const project = ruleOf(rules, 'specs.shape')?.titleIdPattern
  const pattern = override || (typeof project === 'string' ? project : undefined)
  const r = await run($, ['node', `${$.plugin.root}/claude-code/lib/test-id-scan.js`, '--stdin'], { stdin: JSON.stringify({ before, after }), timeoutMs: 5000, ...(pattern ? { env: { CIVITAS_TEST_ID_PATTERN: pattern } } : {}) })
  if (!r.ok || r.exitCode !== 0) return [`the test-ID scan could not run on ${rel} (${r.ok ? `exit ${r.exitCode}` : r.reason}); check the titles by hand (${ID_REF}).`]
  let out: { untagged?: string[]; duplicates?: { id: string; titles: string[] }[] }
  try {
    out = JSON.parse(r.stdout)
  } catch {
    return []
  }
  const shape = pattern ? `this project pins its own ID pattern (${pattern})` : 'the house shape is TC plus a 2-5 letter area code and a 4-6 digit ordinal (TCLG-000420 · …)'
  const found: string[] = []
  if ((out.untagged ?? []).length > 0) found.push(`${rel} adds ${out.untagged!.length} test case${out.untagged!.length > 1 ? 's' : ''} without a stable test ID: ${out.untagged!.map(t => `no ID: "${t}"`).join('; ')}. ${shape} (${ID_REF}).`)
  for (const d of out.duplicates ?? []) found.push(`${rel} has duplicate ID ${d.id} on ${d.titles.length} cases; an ID names one case (${ID_REF}).`)
  return found
}

// ── the import boundary: test code and the runner config reach nothing outside tests/ ──

async function importBoundary($: EngineInterface, e: W, root: string, rel: string): Promise<string[]> {
  const name = basename(rel)
  const inScopeFile = (rel.startsWith('tests/') && (CODE.test(rel) || /^(package|[jt]sconfig[^/]*)\.json$/.test(name))) || /^playwright[^/]*\.config\.[cm]?[jt]s$/.test(rel) || rel === 'package.json'
  if (!inScopeFile) return []
  const r = await run($, ['node', `${$.plugin.root}/claude-code/lib/import-boundary-scan.js`, e.file_path, root], { stdin: JSON.stringify({ tool_name: e.tool, tool_input: e }), timeoutMs: 6000, cwd: root })
  if (!r.ok) return [`the import-boundary screen did not finish on ${rel} (${r.reason}); it is a static floor, so read the imports by hand (${BOUNDARY_REF}).`]
  if (r.exitCode !== 0) return [`the import-boundary screen could not run on ${rel} (${r.exitCode === 3 ? 'its time budget ran out' : r.stderr.trim().split('\n')[0] || `exit ${r.exitCode}`}) (${BOUNDARY_REF}).`]
  try {
    const out = JSON.parse(r.stdout) as { offenders?: string[] }
    const offenders = out.offenders ?? []
    return offenders.length === 0 ? [] : [`${rel} reaches outside tests/: ${offenders.slice(0, 5).join('; ')}${offenders.length > 5 ? ` (+${offenders.length - 5} more)` : ''}. Code the runner loads stays inside tests/ (${BOUNDARY_REF}).`]
  } catch {
    return []
  }
}

// ── factory rules: specs.shape (intake, frozen dirs), selectors.no-inline, selectors.evidence ──

const TITLE = /(?<![\w.$])test(?:\.(?:skip|fixme|only|fail|slow))?\(\s*(?:'([^'\n]*)'|"([^"\n]*)"|`([^`]*)`)/g

async function intake($: EngineInterface, rules: FactoryRules, root: string, rel: string, isNew: boolean, text: string): Promise<string[]> {
  const rule = ruleOf(rules, 'specs.shape')
  if (!rule || !isNew) return []
  const action = typeof rule.action === 'string' ? rule.action : undefined
  const doc = typeof rule.doc === 'string' ? rule.doc : undefined
  const say = (what: string, act = action) => [threeLine('specs.shape', what, act, doc)]
  for (const d of strings(rule.frozenDirs).map(x => x.replace(/\/$/, '')))
    if (rel.startsWith(`${d}/`)) return say(`Write to ${rel} creates a new file under the frozen ${d}/ directory.`, `Put the new file under a directory that is not frozen (frozenDirs in ${rules.rel}); editing an existing file there is allowed, and lifting a freeze is an owner decision.`)
  if (text === '' || !/\.(spec|test)\./.test(basename(rel))) return []
  if (!inScope(rel, strings(rule.scope)) || inScope(rel, strings(rule.exclude))) return []
  const pattern = typeof rule.titleIdPattern === 'string' ? rule.titleIdPattern : ''
  if (pattern === '') return []
  let re: RegExp
  try {
    re = new RegExp(pattern)
  } catch {
    return []
  }
  const docs = strings(rule.scenarioDocs)
  const docText = (await Promise.all(docs.map(d => readText($, `${root}/${d}`)))).map(t => t ?? '').join('\n')
  const lint = strings(rule.lint)
  const lintPath = lint[1] && !lint[1].startsWith('-') ? resolve(root, lint[1]) : undefined
  const lintReady = lint.length > 0 && (lintPath === undefined || (await exists($, lintPath)))
  const what = (t: string) => `New spec ${rel} has a test without a written scenario (${t}).`
  for (const m of maskComments(text).matchAll(TITLE)) {
    const title = m[1] ?? m[2] ?? m[3] ?? ''
    const hit = re.exec(title)
    if (!hit || hit.index !== 0) return say(what(title))
    const id = hit[0].replace(/ — $/, '').trim()
    const headed = new RegExp(`^#+ ${id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}( |$)`, 'm').test(docText)
    if (!headed) return say(what(`${title} — no scenario block headed ${id} in ${docs.join(', ')}`))
    if (!lintReady) continue
    const r = await run($, [...lint, '--id', id, ...docs.map(d => `${root}/${d}`)], { cwd: root, timeoutMs: 5000 })
    if (!r.ok) return [`the scenario lint did not finish for ${id} (${r.reason}).`]
    if (r.exitCode !== 0) {
      const out = `${r.stdout}\n${r.stderr}`
      const why = out.split('\n').filter(l => l.startsWith('[specs.shape] ')).map(l => l.slice(14)).slice(0, 3).join(';')
      return say(what(`${title} — ${why || out.split('\n').find(l => l.trim() !== '')?.trim() || `exit ${r.exitCode}`}`))
    }
  }
  return []
}

function noInline(rules: FactoryRules, rel: string, tool: string, text: string): string[] {
  const rule = ruleOf(rules, 'selectors.no-inline')
  if (!rule || !CODE.test(rel) || !inScope(rel, strings(rule.scope)) || text === '') return []
  let body = maskComments(text)
  for (const a of strings(rule.allowed)) body = body.split(a).join('')
  const p = strings(rule.forbidden).find(f => body.includes(f))
  return p === undefined ? [] : [threeLine('selectors.no-inline', `${tool === 'Edit' ? 'Edit of' : 'Write to'} ${rel} contains \`${p}\`.`, typeof rule.action === 'string' ? rule.action : undefined, typeof rule.doc === 'string' ? rule.doc : undefined)]
}

type Entry = { page: string; el: string; sel: unknown; prov: boolean }
const entries = (doc: unknown, key: string): Entry[] => {
  const out: Entry[] = []
  for (const p of ((doc as { pages?: unknown })?.pages as { name?: string; elements?: unknown[] }[] | undefined) ?? [])
    for (const e of (p?.elements ?? []) as Record<string, unknown>[]) if (e && typeof e === 'object') out.push({ page: String(p.name), el: String(e.elementName), sel: e.selector, prov: e[key] === true })
  return out
}
const same = (a: unknown, b: unknown): boolean => {
  if (a === b) return true
  if (typeof a !== 'object' || typeof b !== 'object' || a === null || b === null) return false
  const ka = Object.keys(a).sort()
  const kb = Object.keys(b).sort()
  return ka.length === kb.length && ka.every((k, i) => k === kb[i] && same((a as Record<string, unknown>)[k], (b as Record<string, unknown>)[k]))
}

async function repositoryEvidence($: EngineInterface, rules: FactoryRules, root: string, rel: string, before: string, after: string): Promise<string[]> {
  const rule = ruleOf(rules, 'selectors.evidence')
  if (!rule || typeof rule.repository !== 'string' || rel !== rule.repository) return []
  const doc = typeof rule.doc === 'string' ? rule.doc : undefined
  let evDir = typeof rule.evidenceDir === 'string' ? rule.evidenceDir : undefined
  if (evDir === undefined) {
    const schema = await readJson<{ $defs?: { selectorsEvidence?: { properties?: { evidenceDir?: { default?: unknown } } } } }>($, `${$.plugin.root}/schemas/factory-rules.schema.json`)
    const d = schema?.$defs?.selectorsEvidence?.properties?.evidenceDir?.default
    if (typeof d !== 'string') return [threeLine('selectors.evidence', 'The shipped schema schemas/factory-rules.schema.json is unreadable or lacks the evidenceDir default.', 'Reinstall @civitas-cerebrum/achilles; the evidenceDir default is read from it.', doc)]
    evDir = d
  }
  const pkey = typeof rule.provisionalKey === 'string' ? rule.provisionalKey : 'provisional'
  let next: unknown
  try {
    next = JSON.parse(after)
  } catch {
    return []
  }
  let prior: unknown = {}
  try {
    prior = JSON.parse(before || '{}')
  } catch {
    /* an unparseable prior judges every entry as new */
  }
  const old = new Map(entries(prior, pkey).map(x => [`${x.page}\u001f${x.el}`, x.sel]))
  for (const x of entries(next, pkey)) {
    if (x.prov || same(old.get(`${x.page}\u001f${x.el}`), x.sel)) continue
    const action = typeof rule.action === 'string' ? rule.action.split('<Page>').join(x.page).split('<element>').join(x.el) : `Insert the entry with "${pkey}": true, record live evidence for ${x.page}.${x.el}, then drop the flag in the same change.`
    const noteRel = `${evDir}/${x.page}.${x.el}.md`
    const text = await readText($, `${root}/${noteRel}`)
    if (text === undefined) return [threeLine('selectors.evidence', `Repository entry ${x.page}.${x.el} has no evidence note.`, action, doc)]
    if (!/^- source: /m.test(text)) return [threeLine('selectors.evidence', `Evidence note ${noteRel} has no "- source:" line (not written by the evidence tool).`, action, doc)]
    const line = /^- selector: (.*)$/m.exec(text)?.[1]
    let noted: unknown
    try {
      noted = line === undefined ? undefined : JSON.parse(line)
    } catch {
      noted = undefined
    }
    if (!same(noted, x.sel)) return [threeLine('selectors.evidence', `Evidence note ${noteRel} is stale: its "- selector:" line does not describe the new selector of ${x.page}.${x.el}.`, action, doc)]
  }
  return []
}

// ── the evidence floor and the journey map ──

function evidenceFloor(w: Who, rel: string): string[] {
  const x = w.expert
  if (!x || x.evidence) return []
  const diagnosing = x.kind === 'diagnosis' || (x.skills ?? []).some(s => s === 'failure-diagnosis' || s.endsWith(':failure-diagnosis'))
  if (!diagnosing || !(isSpecPath(rel) || isPageRepository(rel))) return []
  return [
    `Evidence-floor violation: ${rel} is being written from a failure diagnosis that has not opened any failure evidence (no trace, error-context.md, failure screenshot, video or reporter JSON). Open the evidence, then write: locally Read test-results/<test>/test-failed-1.png and error-context.md, unzip the trace.zip; for a pipeline failure gh run download <run-id> --dir <scratch> first. Mind the attempt split: attempt 0 and -retry1 are sibling directories (${FD_REF} §"Stage 0b — Pipeline evidence retrieval").`,
  ]
}

async function journeyMap($: EngineInterface, root: string, rel: string, tool: string, before: string, after: string): Promise<string[]> {
  if (rel === MAP) {
    if (tool === 'Edit' && before.split('\n')[0]!.trim() === SENTINEL) return []
    const out: string[] = []
    if (after.split('\n')[0]!.trim() !== SENTINEL) out.push(`${MAP}: line 1 must be the literal sentinel \`${SENTINEL}\`; the map is written by the journey-mapping author step (${MAP_REF}).`)
    const state = await readJson<{ cycles?: Record<string, { 'dispatched-sections'?: string[] }> }>($, `${root}/tests/e2e/docs/.phase4-cycle-state.json`)
    if (!state) out.push(`${MAP} is written while tests/e2e/docs/.phase4-cycle-state.json does not exist; the map follows the discovery cycles (${MAP_REF}).`)
    else if ((state.cycles?.['1']?.['dispatched-sections'] ?? []).length === 0) out.push(`${MAP} is written with 0 cycle-1 section dispatches recorded (${MAP_REF}).`)
    return out
  }
  if (rel === 'tests/e2e/docs/journey-map-coverage.md') {
    const map = await readText($, `${root}/${MAP}`)
    if (map === undefined) return [`the coverage matrix may only be written after journey-map.md exists (${MAP_REF}).`]
    if (map.split('\n')[0]!.trim() !== SENTINEL) return [`the coverage matrix is written against a journey-map.md missing the sentinel (${MAP_REF}).`]
  }
  return []
}

export function registerHygiene(on: On) {
  on('tool.call', { tool: ['Write', 'Edit'] }, async ($, e, next) => {
    if (isDisabled()) return next(e)
    const w = await who($, e.agentId)
    if (!w) return next(e)
    const root = await $.session.cwd()
    const { abs, rel } = placeFile(root, e.file_path)
    if (!within(root, abs)) return next(e)
    const isTests = rel.startsWith('tests/')
    const isConfig = /^playwright[^/]*\.config\.[cm]?[jt]s$/.test(rel) || rel === 'package.json'
    if (!isTests && !isConfig) return next(e)
    const rules = await factoryRules($, root)
    const isNew = !(await exists($, abs))
    const synth = await afterContent($, e, abs)
    // The screens run side by side, so the two node children share one budget.
    const ok = !('error' in synth)
    const found = await Promise.all([
      ok && isTests && isSpecPath(rel) ? testIds($, rel, synth.before, synth.after, rules) : [],
      ok ? journeyMap($, root, rel, e.tool, synth.before, synth.after) : [],
      ok && rules ? repositoryEvidence($, rules, root, rel, synth.before, synth.after) : [],
      rules ? intake($, rules, root, rel, isNew, writtenText(e)) : [],
      rules ? noInline(rules, rel, e.tool, writtenText(e)) : [],
      evidenceFloor(w, rel),
      importBoundary($, e, root, rel),
    ])
    const findings = found.flat()
    for (const f of findings) await note($, e.agentId, f)
    return next(e)
  })

  // What a diagnosing expert opened: any failure evidence lifts its evidence floor.
  on('tool.call', { tool: ['Read', 'Bash'] }, async ($, e, next) => {
    if (isDisabled()) return next(e)
    const seen = e.tool === 'Read' ? (e as unknown as { file_path?: string }).file_path : (e as unknown as { command?: string }).command
    if (typeof seen !== 'string' || !EVIDENCE.test(seen)) return next(e)
    const w = await who($, e.agentId)
    if (w?.expert && !w.expert.evidence) await editExpert($, w.run.id, w.expert.agentId, x => ({ ...x, evidence: true }))
    return next(e)
  })
}

