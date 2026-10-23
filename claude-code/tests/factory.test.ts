import { describe, expect, mock, test } from 'claude-code/testing'

import { CASES, FIXTURE, RULES } from './factory-cases.mjs'
import { ROOT, START, engine, notes, spawnExpert, startRun } from './harness'

// The factory rule cases, run against the hooks that own each rule. A case's "deny" stands
// where the hook denies (secrets.none, spend.opt-in) and reads as an advisory note naming the
// rule where the hook advises (process.evidence, process.state, specs.shape, selectors.*):
// the messageContains substrings are then matched against that note.

type Case = {
  name: string
  hook: string
  ruleId: string
  input: { tool_name: string; cwd?: string; tool_input: Record<string, unknown> }
  expect: 'allow' | 'deny'
  messageContains?: string[]
  cwd?: 'temp'
  copy?: (string | Record<string, string>)[]
  write?: Record<string, string>
  stamp?: string
}

const DENIES = new Set(['secrets.none', 'spend.opt-in'])
// The rules a shipped hook owns; the spec-hygiene rules join with that hook.
const OWNED = new Set(['secrets.none', 'spend.opt-in', 'process.evidence', 'process.state', 'specs.shape', 'selectors.no-inline', 'selectors.evidence'])
const RULE_FILE = 'achilles-factory-rules.json'
const RULES_TEXT = JSON.stringify(RULES, null, 2)
const FRESH = 'fresh0tree0hash0'
const subst = (v: unknown): unknown =>
  typeof v === 'string' ? v.split('{{ROOT}}').join(ROOT) : Array.isArray(v) ? v.map(subst) : v && typeof v === 'object' ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, subst(x)])) : v

// The evidenceDir default comes from the shipped schema; one case proves the note when it is unreadable.
const SCHEMA = { [`${ROOT}/schemas/factory-rules.schema.json`]: JSON.stringify({ $defs: { selectorsEvidence: { properties: { evidenceDir: { default: 'docs/evidence/selectors' } } } } }) }

function project(c: Case): Record<string, string> {
  return { ...(c.name.endsWith('deny-schema-unreadable') ? {} : SCHEMA), ...files(c) }
}

function files(c: Case): Record<string, string> {
  if (c.cwd !== 'temp') return { ...Object.fromEntries(Object.entries(FIXTURE as Record<string, string>).map(([k, v]) => [`${ROOT}/${k}`, v])), [`${ROOT}/${RULE_FILE}`]: RULES_TEXT }
  const files: Record<string, string> = {}
  for (const entry of c.copy ?? []) {
    for (const [dest, src] of Object.entries(typeof entry === 'string' ? { [entry]: entry } : entry)) {
      files[`${ROOT}/${dest}`] = src === RULE_FILE ? RULES_TEXT : ((FIXTURE as Record<string, string>)[src] ?? '')
    }
  }
  for (const [p, body] of Object.entries(c.write ?? {})) files[`${ROOT}/${p}`] = String(subst(body))
  if (c.stamp) {
    const rules = JSON.parse(files[`${ROOT}/${RULE_FILE}`] ?? RULES_TEXT) as { rules: Record<string, { stamp?: string }> }
    const stamp = rules.rules['process.evidence']?.stamp ?? '.factory/verify-stamp'
    files[`${ROOT}/${stamp}`] = JSON.stringify({ treeHash: c.stamp === 'fresh' ? FRESH : c.stamp })
  }
  return files
}

describe('factory rules', () => {
  // A Bash call runs in the session's directory; a case whose payload names another cwd has no counterpart.
  for (const c of (CASES as Case[]).filter(x => OWNED.has(x.ruleId) && (x.input.cwd === undefined || x.input.cwd === '{{ROOT}}'))) {
    test(`${c.name} (${DENIES.has(c.ruleId) ? c.expect : c.expect === 'deny' ? 'advise' : 'allow'})`, async ($, on) => {
      const h = engine(on, { files: project(c) })
      const session = mock.session(on)
      // process.evidence's hashCommand: the stamp a case calls "fresh" is what it prints.
      h.procs.push(argv => (argv.join(' ').includes('tree-hash') ? `${FRESH}\n` : undefined))
      // specs.shape's scenario lint: the fixture's stub (a block needs an **Oracle** line), or the script the case wrote.
      h.procs.push(argv => {
        if (!argv.some(a => a.includes('scenario-lint'))) return undefined
        const script = h.files.get(`${ROOT}/${argv[1]}`) ?? ''
        if (script.includes('boom')) return { exitCode: 1, stderr: 'lint crashed: boom\nsecond line\n' }
        const id = argv[argv.indexOf('--id') + 1]!
        const text = argv.filter(a => a.endsWith('.md')).map(d => h.files.get(d) ?? '').join('\n')
        const block = text.split(/^#+ /m).find(b => b.startsWith(`${id} `)) ?? ''
        return block.includes('**Oracle**') ? { exitCode: 0 } : { exitCode: 1, stdout: `[specs.shape] ${id}: missing **Oracle**\n` }
      })
      await $.session.start(START)
      const author = await spawnExpert($, h, 'author', await startRun($, h))
      const input = subst(c.input) as Case['input']
      const r = await $.tool.call({ tool: input.tool_name, ...input.tool_input, agentId: author } as never)
      const said = notes(session, author).filter(n => c.ruleId === '' || n.includes(`[${c.ruleId}]`))
      const ruleNotes = said.filter(n => n.includes('['))
      if (c.expect === 'deny' && DENIES.has(c.ruleId)) {
        expect(r.deny ?? '').toContain(`[${c.ruleId}]`)
        for (const s of c.messageContains ?? []) expect(r.deny).toContain(s)
      } else if (c.expect === 'deny') {
        expect(r.deny).toBeUndefined()
        expect(ruleNotes.length).toBeGreaterThan(0)
        const text = ruleNotes.join('\n')
        for (const s of c.messageContains ?? []) expect(text).toContain(s)
      } else {
        expect(r.deny).toBeUndefined()
        expect(ruleNotes).toEqual([])
      }
    })
  }
})
