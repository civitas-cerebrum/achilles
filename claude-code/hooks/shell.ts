// The commands a Bash line runs, split as the shell would, so a hook judges invocations and write
// targets instead of text. The TypeScript port of the 0.2.x shell-words.sh; its cases are the spec.
//
// words() keeps $( ), backticks, $'…' and ${…} inside their word as written (nothing is expanded,
// so a judge sees them as unresolved). A heredoc's delimiter word becomes its body. Over MAX_BYTES
// the line is not split and `overflow` is set: a judge decides what an unreadable line means.

export const MAX_BYTES = 32768

export type Word = { text: string; kind: 'word' | 'sep' | 'op'; start: number; end: number }

export type Command = {
  /** The command word (basename; an npx package spec keeps its @scope and drops its @version) and its arguments. */
  args: string[]
  /** Offsets of each arg in the source line, for a rewrite. */
  spans: { start: number; end: number }[]
  /** Assignments peeled before the command word. */
  assign: string[]
  /** True when an assignment or `env` preceded the command. */
  env: boolean
  /** The directory of `env -C DIR`, else ''. */
  chdir: string
  /** True when a wrapper carried an option the peeler does not know: the command is unknown. */
  wrapBad: boolean
  /** Targets of > >> >| &> &>> >&file <> (with any fd number). */
  writes: string[]
  /** Heredoc and here-string bodies. */
  heredocs: string[]
}

const STOP = /['" \t\n\\$`;&|()<>#]/
const DQ_STOP = /["\\$`]/
const REDIRS = ['<<<', '<<-', '&>>', '>>', '>|', '>&', '<<', '<>', '<&', '&>', '>', '<']

export function words(line: string): { words: Word[]; overflow: boolean } {
  if (line.length > MAX_BYTES) return { words: [], overflow: true }
  const out: Word[] = []
  const t = line
  const n = t.length
  let i = 0
  let w = ''
  let have = false
  let start = 0
  let hdNext: string | undefined
  const hds: { idx: number; op: string; delim: string }[] = []

  const flush = () => {
    if (!have) return
    out.push({ text: w, kind: 'word', start, end: i })
    if (hdNext !== undefined) {
      hds.push({ idx: out.length - 1, op: hdNext, delim: w })
      hdNext = undefined
    }
    w = ''
    have = false
  }
  const begin = () => {
    if (!have) start = i
    have = true
  }
  const sep = () => {
    flush()
    out.push({ text: '', kind: 'sep', start: i, end: i + 1 })
  }
  const redir = () => {
    const op = REDIRS.find(o => t.startsWith(o, i)) ?? '>'
    out.push({ text: op, kind: 'op', start: i, end: i + op.length })
    i += op.length
    if (op === '<<' || op === '<<-') hdNext = op
  }
  const heredocs = () => {
    for (const h of hds) {
      let body = ''
      while (i < n) {
        const nl = t.indexOf('\n', i)
        let lineText = nl < 0 ? t.slice(i) : t.slice(i, nl)
        i = nl < 0 ? n : nl + 1
        if (h.op === '<<-') lineText = lineText.replace(/^\t+/, '')
        if (lineText === h.delim) break
        body += `${lineText}\n`
      }
      out[h.idx]!.text = body
    }
    hds.length = 0
  }
  // $( … ) stays in the word as written; its separators do not split the line.
  const subst = () => {
    let k = i + 2
    let depth = 1
    while (k < n) {
      const ch = t[k]!
      if (ch === '(') depth++
      else if (ch === ')') {
        depth--
        if (depth === 0) break
      } else if (ch === "'") {
        const close = t.indexOf("'", k + 1)
        k = close < 0 ? n : close
      } else if (ch === '"') {
        k++
        while (k < n && t[k] !== '"') {
          if (t[k] === '\\') k++
          k++
        }
      } else if (ch === '\\') k++
      k++
    }
    begin()
    w += t.slice(i, k + 1)
    i = k + 1
  }
  const backtick = () => {
    let k = i + 1
    while (k < n) {
      const ch = t[k]!
      if (ch === '\\') {
        k += 2
        continue
      }
      if (ch === '`') break
      k++
    }
    begin()
    w += t.slice(i, k + 1)
    i = k + 1
  }
  const dquote = () => {
    while (i < n) {
      const c = t[i]!
      if (c === '"') {
        i++
        return
      }
      if (c === '\\') {
        const nx = t[i + 1]
        if (nx === '"' || nx === '\\' || nx === '$' || nx === '`') w += nx
        else if (nx !== '\n') w += `\\${nx ?? ''}`
        i += 2
        continue
      }
      if (c === '$' && t[i + 1] === '(') {
        subst()
        continue
      }
      if (c === '`') {
        backtick()
        continue
      }
      const m = DQ_STOP.exec(t.slice(i))
      const len = m ? Math.max(m.index, 1) : n - i
      w += t.slice(i, i + len)
      i += len
    }
  }

  while (i < n) {
    const c = t[i]!
    if (c === "'") {
      begin()
      const close = t.indexOf("'", i + 1)
      const end = close < 0 ? n : close
      w += t.slice(i + 1, end)
      i = end + 1
    } else if (c === '"') {
      begin()
      i++
      dquote()
    } else if (c === '\\') {
      const nx = t[i + 1]
      if (nx !== '\n') {
        begin()
        w += nx ?? ''
      }
      i += 2
    } else if (c === '$') {
      const nx = t[i + 1]
      if (nx === '(') subst()
      else if (nx === '{') {
        const close = t.indexOf('}', i)
        const end = close < 0 ? n : close + 1
        begin()
        w += t.slice(i, end)
        i = end
      } else {
        begin()
        w += '$'
        i++
      }
    } else if (c === '`') backtick()
    else if (c === ' ' || c === '\t') {
      flush()
      i++
    } else if (c === '\n') {
      sep()
      i++
      heredocs()
    } else if (c === ';' || c === '|' || c === '(' || c === ')') {
      sep()
      i++
    } else if (c === '&') {
      if (t[i + 1] === '>') {
        flush()
        redir()
      } else {
        sep()
        i++
      }
    } else if (c === '<' || c === '>') {
      // Digits glued to the operator are its fd number, not a word.
      if (have && /^[0-9]+$/.test(w)) {
        w = ''
        have = false
      } else flush()
      redir()
    } else if (c === '#') {
      if (!have) {
        const nl = t.indexOf('\n', i)
        i = nl < 0 ? n : nl
      } else {
        w += '#'
        i++
      }
    } else {
      const m = STOP.exec(t.slice(i))
      const len = m ? Math.max(m.index, 1) : n - i
      begin()
      w += t.slice(i, i + len)
      i += len
    }
  }
  flush()
  return { words: out, overflow: false }
}

const WRAP_SKIP_VALUE = new Set(['env:-u'])
const ASSIGN = /^[A-Za-z_][A-Za-z0-9_]*=/
const KEYWORDS = new Set(['if', 'then', 'elif', 'else', 'fi', 'while', 'until', 'do', 'done', '!', '{', '}'])

export function commands(line: string): { commands: Command[]; overflow: boolean } {
  const split = words(line)
  if (split.overflow) return { commands: [], overflow: true }
  const sw = split.words
  const out: Command[] = []
  let k = 0
  while (k <= sw.length) {
    const cmd: Command = { args: [], spans: [], assign: [], env: false, chdir: '', wrapBad: false, writes: [], heredocs: [] }
    let wrapped = ''
    let skip = ''
    while (k < sw.length && sw[k]!.kind !== 'sep') {
      const item = sw[k]!
      k++
      if (item.kind === 'op') {
        const op = item.text
        if (k >= sw.length || sw[k]!.kind !== 'word') continue
        const target = sw[k]!.text
        if (op === '>&' && (target === '-' || /^[0-9]/.test(target))) {
          k++
          continue
        }
        if (['>', '>>', '>|', '&>', '&>>', '>&', '<>'].includes(op)) cmd.writes.push(target)
        else if (op === '<<' || op === '<<-' || op === '<<<') cmd.heredocs.push(target)
        k++
        continue
      }
      let word = item.text
      if (cmd.args.length === 0) {
        if (skip === 'chdir') {
          cmd.chdir = word
          skip = ''
          continue
        }
        if (skip === 'value') {
          skip = ''
          continue
        }
        if (ASSIGN.test(word)) {
          cmd.env = true
          cmd.assign.push(word)
          continue
        }
        if (KEYWORDS.has(word) && wrapped === '') continue
        if (wrapped !== '') {
          if (word === '--') {
            wrapped += '--'
            continue
          }
          const key = `${wrapped}:${word}`
          if (key === 'env:-C' || key === 'env:--chdir') {
            skip = 'chdir'
            continue
          }
          if (wrapped === 'env' && word.startsWith('-C') && word.length > 2) {
            cmd.chdir = word.slice(2)
            continue
          }
          if (wrapped === 'env' && word.startsWith('--chdir=')) {
            cmd.chdir = word.slice('--chdir='.length)
            continue
          }
          if (WRAP_SKIP_VALUE.has(key)) {
            skip = 'value'
            continue
          }
          if (['env:-i', 'time:-p', 'npx:-y', 'npx:--yes', 'npx:--no', 'npx:--no-install'].includes(key) || (wrapped === 'timeout' && /^[0-9]/.test(word))) continue
          if (word.startsWith('-') && ['env', 'exec', 'nohup', 'time', 'timeout', 'npx'].includes(wrapped.replace(/-+$/, ''))) {
            cmd.wrapBad = true
            continue
          }
        }
        const base = word.slice(word.lastIndexOf('/') + 1)
        if (base === 'command') {
          const nx = sw[k]?.text
          if (nx !== '-v' && nx !== '-V') {
            wrapped = 'command'
            continue
          }
        } else if (base === 'env') {
          cmd.env = true
          wrapped = 'env'
          continue
        } else if (['exec', 'nohup', 'time', 'timeout'].includes(base)) {
          wrapped = base
          continue
        } else if (base === 'npx' || base === 'bunx') {
          wrapped = 'npx'
          continue
        } else if (['npm', 'pnpm', 'yarn', 'bun'].includes(base)) {
          const nx = sw[k]
          if (nx && nx.kind === 'word' && (nx.text === 'exec' || nx.text === 'dlx')) {
            k++
            wrapped = 'npx'
            continue
          }
        }
        if (word.startsWith('@')) {
          const rest = word.slice(1)
          const at = rest.indexOf('@')
          word = `@${at < 0 ? rest : rest.slice(0, at)}`
        } else {
          if (wrapped.startsWith('npx')) word = word.split('@')[0]!
          word = word.slice(word.lastIndexOf('/') + 1)
        }
      }
      cmd.args.push(word)
      cmd.spans.push({ start: item.start, end: item.end })
    }
    if (cmd.args.length > 0 || cmd.writes.length > 0 || cmd.env) out.push(cmd)
    k++
  }
  return { commands: out, overflow: false }
}

const READERS = new Set(['cat', 'head', 'tail', 'grep', 'egrep', 'fgrep', 'rg', 'ls', 'stat', 'wc', 'diff', 'cmp', 'file', 'sha256sum', 'shasum', 'md5', 'md5sum', 'jq', 'echo', 'printf', 'test', '[', 'which', 'type', 'pgrep'])
export const GIT_READS = new Set(['status', 'diff', 'log', 'show', 'ls-files', 'blame', 'commit', 'add', 'rev-parse', 'grep', 'fetch'])

/** The one allowlist of commands that only read their operands and run nothing they are handed. */
export function isReader(args: readonly string[]): boolean {
  const [c, s] = args
  if (c === undefined) return false
  if (READERS.has(c)) return true
  if (c === 'command' && (s === '-v' || s === '-V')) return true
  if (c === 'npm' && ['ls', 'list', 'view', 'info'].includes(s ?? '')) return true
  if (c === 'git' && s !== undefined && GIT_READS.has(s)) return true
  return false
}

const SHELLS = /^(bash|sh|zsh|dash|ksh)$/

/** The command string a command runs in a nested shell (`sh -c '…'`, `eval '…'`), or undefined. */
export function nestedCommand(args: readonly string[]): string | undefined {
  if (args.length < 2) return undefined
  if (SHELLS.test(args[0]!)) {
    const ci = args.findIndex((t, j) => j > 0 && /^-[A-Za-z]*c[A-Za-z]*$/.test(t))
    return ci > 0 ? args[ci + 1] : undefined
  }
  if (args[0] === 'eval') return args.slice(1).join(' ')
  return undefined
}

/** True when the shell would expand the word: a variable, a substitution or a glob. */
export const unresolved = (w: string) => /[$`*?[]/.test(w)

/** `git [-C dir] [-c k=v] [--opt] <sub> …`: the subcommand, its args, and the global options seen. */
export function gitCall(args: readonly string[]): { sub: string; rest: string[]; configs: string[]; dirs: string[] } | undefined {
  if (args[0] !== 'git') return undefined
  const configs: string[] = []
  const dirs: string[] = []
  let j = 1
  while (j < args.length) {
    const a = args[j]!
    if (a === '-C') {
      dirs.push(args[j + 1] ?? '')
      j += 2
    } else if (a === '-c') {
      configs.push(args[j + 1] ?? '')
      j += 2
    } else if (a.startsWith('-c') && a.length > 2 && !a.startsWith('--')) {
      configs.push(a.slice(2))
      j++
    } else if (a === '--git-dir' || a === '--work-tree' || a === '--namespace') j += 2
    else if (a.startsWith('-')) j++
    else return { sub: a, rest: args.slice(j + 1), configs, dirs }
  }
  return undefined
}
