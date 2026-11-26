import type { EngineInterface } from 'claude-code'

import { exists, firstLine, run } from './io'
import { dirname, relTo } from './posix'

// The test-baseline lint (bin/spec-lint.mjs) as a node child, for the write-time notes: one write in
// write mode (findings new in "after"), named paths, or the touched tests of the working tree against
// HEAD. No run state, so the pi adapter uses it too. A child that cannot run, crashes or runs past its
// budget is a value the caller turns into a one-line note; nothing here refuses anything.

export const BASELINE_REF = 'skills/achilles-orchestrator/references/test-baseline.md'

/** The hard per-file budget the child is given (its exit 3), and the wait for the child itself. */
export const FILE_BUDGET_MS = 5000
const WAIT_MS = 8000

/** A path the lint may classify as spec or support: its code extensions, never a declaration file or a dependency. */
export const lintable = (p: string) => /\.(?:[cm]?[jt]sx?)$/i.test(p) && !/\.d\.[cm]?ts$/i.test(p) && !/(^|\/)node_modules\//.test(p)

export type LintFinding = {
  rule: string
  severity: string
  file: string
  line?: number
  message: string
  do?: string
  why?: string
  test?: { id?: string | null; title?: string } | null
  waived?: boolean
  touched?: boolean
}
export type LintFile = { path: string; kind: string; blob: string }
export type LintRun = { ok: true; files: LintFile[]; findings: LintFinding[]; changed?: string[] } | { ok: false; why: string }

/** The git work tree a file sits in and its path there, so a write into a worktree is placed in that worktree; else `fallback` when the file lies under it. */
export async function placeInTree($: EngineInterface, abs: string, fallback: string): Promise<{ top: string; rel: string } | undefined> {
  // A new file may sit in a directory the write creates: ask git from the nearest one that exists.
  let dir = dirname(abs)
  for (let i = 0; i < 64 && dir !== '/' && !(await exists($, dir)); i++) dir = dirname(dir)
  const r = await run($, ['git', 'rev-parse', '--show-toplevel', '--show-prefix'], { cwd: dir, timeoutMs: 3000 })
  if (r.ok && r.exitCode === 0) {
    const [top = '', prefix = ''] = r.stdout.split('\n').map(l => l.trim())
    if (top !== '') return { top, rel: `${prefix}${relTo(dir, abs)}`.replace(/^\.\//, '') }
  }
  return abs.startsWith(`${fallback}/`) ? { top: fallback, rel: relTo(fallback, abs) } : undefined
}

/** The git top-level of a directory (the real path git reports), or undefined outside a work tree. */
export async function topOf($: EngineInterface, dir: string): Promise<string | undefined> {
  const r = await run($, ['git', 'rev-parse', '--show-toplevel'], { cwd: dir, timeoutMs: 3000 })
  const top = r.ok && r.exitCode === 0 ? (r.stdout.split('\n')[0] ?? '').trim() : ''
  return top === '' ? undefined : top
}

async function child($: EngineInterface, top: string, args: string[], stdin?: string, timeoutMs = WAIT_MS): Promise<LintRun> {
  const r = await run($, ['node', `${$.plugin.root}/bin/spec-lint.mjs`, ...args, '--json', '--quiet', '--budget-ms', String(FILE_BUDGET_MS)], {
    cwd: top,
    env: { CLAUDE_PROJECT_DIR: top },
    timeoutMs,
    ...(stdin === undefined ? {} : { stdin }),
  })
  if (!r.ok) return { ok: false, why: `it did not finish (${r.reason})` }
  if (r.exitCode === 3) return { ok: false, why: `it ran past its time budget of ${FILE_BUDGET_MS / 1000} s per file` }
  if (r.exitCode !== 0 && r.exitCode !== 1) return { ok: false, why: (firstLine(r.stderr).replace(/^\[spec-lint\]\s*/, '') || `exit ${r.exitCode}`).slice(0, 200) }
  try {
    const out = JSON.parse(r.stdout) as { files?: unknown; findings?: unknown; change?: { files?: unknown } }
    if (!Array.isArray(out.files) || !Array.isArray(out.findings)) return { ok: false, why: 'its report has no files or findings' }
    const changed = Array.isArray(out.change?.files) ? (out.change!.files as unknown[]).filter((x): x is string => typeof x === 'string') : undefined
    return { ok: true, files: out.files as LintFile[], findings: out.findings as LintFinding[], ...(changed ? { changed } : {}) }
  } catch {
    return { ok: false, why: r.stdout.trim() === '' ? `it ended with exit ${r.exitCode} and printed no report` : 'its report was not JSON' }
  }
}

/** Write mode: the findings `after` adds to `rel` over `before` (null for a new file), and the file's kind and object id. */
export function lintWrite($: EngineInterface, top: string, rel: string, before: string | null, after: string): Promise<LintRun> {
  return child($, top, ['--stdin'], JSON.stringify({ file: rel, before, after }))
}

/** The named files as they are on disk: their kinds and object ids (an out-of-scope path is simply absent). */
export function lintPaths($: EngineInterface, top: string, rels: string[]): Promise<LintRun> {
  return child($, top, rels)
}

/** The named files against HEAD with the lint's touched-test semantics: a finding counts only in a touched test, describe or file scope. */
export function lintTouched($: EngineInterface, top: string, rels: string[]): Promise<LintRun> {
  return child($, top, ['--base', 'HEAD', ...rels], undefined, 15000)
}

const MAX_SHOWN = 8

const lineOf = (f: LintFinding) =>
  `- [${f.rule}] ${f.file}${f.line ? `:${f.line}` : ''}${f.test?.id ? ` ${f.test.id}` : ''}: ${f.message}${f.severity === 'blocking' ? ' (blocking under the test baseline)' : /advisory/.test(f.message) ? '' : ' (advisory)'}${f.do ? `\n  → Do: ${f.do}` : ''}${f.why ? `\n  → Why/how: ${f.why}` : ''}`

/** The note for the findings one write added, blocking first; undefined when it added none. */
export function writeNote(rel: string, findings: LintFinding[]): string | undefined {
  const shown = findings.filter(f => !f.waived)
  if (shown.length === 0) return undefined
  const blocking = shown.filter(f => f.severity === 'blocking')
  const ordered = [...blocking, ...shown.filter(f => f.severity !== 'blocking')]
  const n = blocking.length
  const lead =
    n > 0
      ? `fix the ${n === 1 ? 'finding' : `${n} findings`} this write added to ${rel} that ${n === 1 ? 'is' : 'are'} blocking under the test baseline, in a follow-up write (the write itself landed):`
      : `this write added ${shown.length === 1 ? 'an advisory test-baseline finding' : `${shown.length} advisory test-baseline findings`} to ${rel}; fix ${shown.length === 1 ? 'it' : 'them'} while the change is open (the write itself landed):`
  const more = ordered.length > MAX_SHOWN ? `\n(+${ordered.length - MAX_SHOWN} more: run \`npx achilles-spec-lint ${rel}\`)` : ''
  return `${lead}\n${ordered.slice(0, MAX_SHOWN).map(lineOf).join('\n')}${more}\n\nReferences:\n  ${BASELINE_REF}`
}

/** The one-line note when the lint could not check a write. */
export const failNote = (rel: string, why: string) =>
  `run \`npx achilles-spec-lint ${rel}\` before you hand back: the test-baseline lint could not check this write (${why}); the write landed unchecked (${BASELINE_REF}).`

/** Blocking, unwaived findings in touched code of the given files, from a lintTouched run. */
export const blockingInTouched = (findings: LintFinding[], rels: ReadonlySet<string>) =>
  findings.filter(f => rels.has(f.file) && f.severity === 'blocking' && !f.waived && f.touched !== false)

/** The lines of a hand-back note listing blocking findings in touched tests. */
export const findingLines = (findings: LintFinding[]) =>
  `${findings.slice(0, MAX_SHOWN).map(lineOf).join('\n')}${findings.length > MAX_SHOWN ? `\n(+${findings.length - MAX_SHOWN} more: run \`npx achilles-spec-lint --base HEAD\`)` : ''}`
