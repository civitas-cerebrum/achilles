import type { Command } from './shell'
import { gitCall, unresolved } from './shell'
import { basename, resolve } from './posix'

// The files a parsed Bash line writes, as far as the command words show it: redirection targets,
// in-place edits (`sed -i`), `tee`, the target of `cp` / `mv` / `install`, `git checkout <ref> -- <path>`
// and `git restore <path>`, and the literal paths a `node -e` script writes with fs. Only literal words
// count; a target the shell would expand is not guessed. Used to record who wrote which test file; it
// decides nothing.

const NODE_WRITE = /\b(?:writeFileSync|appendFileSync|writeFile|appendFile|createWriteStream|copyFileSync|copyFile)\s*\(\s*(['"`])([^'"`$\n]+)\1/g

/** Operands of a command: its arguments after options (`--` ends options), skipping the values of the options named. */
function operands(args: readonly string[], valued: ReadonlySet<string> = new Set()): string[] {
  const out: string[] = []
  let opts = true
  for (let i = 1; i < args.length; i++) {
    const a = args[i]!
    if (opts && a === '--') {
      opts = false
      continue
    }
    if (opts && a.startsWith('-') && a !== '-') {
      if (valued.has(a)) i++
      continue
    }
    out.push(a)
  }
  return out
}

function sedTargets(raw: readonly string[]): string[] {
  // BSD sed spells an in-place edit without a backup as `-i ''`: the empty word is the suffix, not the script
  const args = raw.filter((a, i) => !(a === '' && raw[i - 1] === '-i'))
  let inPlace = false
  let script = false
  for (const a of args.slice(1)) {
    if (a === '--') break
    if (a === '--in-place' || a.startsWith('--in-place=')) inPlace = true
    else if (a === '-e' || a === '--expression' || a === '-f' || a === '--file' || a.startsWith('--expression=') || a.startsWith('--file=')) script = true
    else if (/^-[A-Za-z]+/.test(a) && !a.startsWith('--')) {
      // a short group: -i takes the rest of the group as its backup suffix
      for (const ch of a.slice(1)) {
        if (ch === 'i') {
          inPlace = true
          break
        }
        if (ch === 'e' || ch === 'f') {
          script = true
          break
        }
      }
    }
  }
  if (!inPlace) return []
  const ops = operands(args, new Set(['-e', '--expression', '-f', '--file']))
  return script ? ops : ops.slice(1)
}

function copyTarget(args: readonly string[]): string[] {
  for (let i = 1; i < args.length; i++) {
    const a = args[i]!
    if (a === '-t' || a === '--target-directory') return []
    if (a.startsWith('--target-directory=')) return []
  }
  const ops = operands(args, new Set(['-S', '--suffix', '-m', '--mode', '-o', '--owner', '-g', '--group']))
  if (ops.length < 2) return []
  // `cp a b` writes b; `cp a b dir/` writes into dir: only the single-source form names its file
  return ops.length === 2 ? [ops[1]!.endsWith('/') ? `${ops[1]}${basename(ops[0]!)}` : ops[1]!] : []
}

function gitTargets(args: readonly string[]): string[] {
  const git = gitCall(args)
  if (!git) return []
  const rest = git.rest
  const dash = rest.indexOf('--')
  if (git.sub === 'checkout') return dash >= 0 ? rest.slice(dash + 1) : []
  if (git.sub === 'restore') {
    const staged = rest.includes('--staged') || rest.includes('-S')
    const worktree = rest.includes('--worktree') || rest.includes('-W')
    if (staged && !worktree) return []
    return dash >= 0 ? rest.slice(dash + 1) : operands(['restore', ...rest], new Set(['-s', '--source']))
  }
  return []
}

function nodeTargets(args: readonly string[]): string[] {
  if (args[0] !== 'node' && args[0] !== 'bun' && args[0] !== 'deno') return []
  const out: string[] = []
  for (let i = 1; i < args.length; i++) {
    const a = args[i]!
    const script = a === '-e' || a === '--eval' || a === '-p' || a === '--print' ? args[i + 1] : a.startsWith('--eval=') ? a.slice(7) : undefined
    if (script === undefined) continue
    for (const m of script.matchAll(NODE_WRITE)) out.push(m[2]!)
  }
  return out
}

/** The absolute paths the commands of one line write, each resolved against the directory it runs in. */
export function shellWrites(all: readonly { cmd: Command; dir: string }[], home: string): string[] {
  const out = new Set<string>()
  for (const { cmd, dir } of all) {
    const targets = [...cmd.writes]
    const c = cmd.args[0]
    if (c === 'sed' || c === 'gsed') targets.push(...sedTargets(cmd.args))
    else if (c === 'tee') targets.push(...operands(cmd.args))
    else if (c === 'cp' || c === 'mv' || c === 'install') targets.push(...copyTarget(cmd.args))
    else if (c === 'git') targets.push(...gitTargets(cmd.args))
    else targets.push(...nodeTargets(cmd.args))
    const base = cmd.chdir !== '' && !unresolved(cmd.chdir) ? resolve(dir, cmd.chdir, home) : dir
    // `git -C <dir> checkout …` names its paths from <dir>; a redirection stays relative to the shell's directory
    let gitBase = base
    for (const d of c === 'git' ? (gitCall(cmd.args)?.dirs ?? []) : []) gitBase = unresolved(d) ? gitBase : resolve(gitBase, d, home)
    const own = new Set(cmd.writes)
    for (const t of targets) {
      if (t === '' || unresolved(t) || /^\/dev\//.test(t) || /^&?\d*$/.test(t)) continue
      out.add(resolve(own.has(t) ? dir : gitBase, t, home))
    }
  }
  return [...out]
}
