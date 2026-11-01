// POSIX path arithmetic for a module with no Node: lexical only, symlinks are not followed.

export const isAbsolute = (p: string) => p.startsWith('/')

export function normalize(p: string): string {
  const abs = isAbsolute(p)
  const out: string[] = []
  for (const seg of p.split('/')) {
    if (seg === '' || seg === '.') continue
    if (seg === '..') {
      if (out.length > 0 && out[out.length - 1] !== '..') out.pop()
      else if (!abs) out.push('..')
      continue
    }
    out.push(seg)
  }
  const joined = out.join('/')
  return abs ? `/${joined}` : joined || '.'
}

export const join = (...parts: string[]) => normalize(parts.filter(p => p !== '').join('/'))

export function resolve(base: string, p: string, home = '/'): string {
  if (p === '~') return normalize(home)
  if (p.startsWith('~/')) return normalize(`${home}/${p.slice(2)}`)
  return normalize(isAbsolute(p) ? p : `${base}/${p}`)
}

export function relative(from: string, to: string): string {
  const a = normalize(from).split('/').filter(Boolean)
  const b = normalize(to).split('/').filter(Boolean)
  let i = 0
  while (i < a.length && i < b.length && a[i] === b[i]) i++
  const up = a.slice(i).map(() => '..')
  const rel = [...up, ...b.slice(i)].join('/')
  return rel === '' ? '.' : rel
}

export const basename = (p: string) => p.replace(/\/+$/, '').split('/').pop() ?? ''
export const dirname = (p: string) => {
  const n = p.replace(/\/+$/, '')
  const i = n.lastIndexOf('/')
  return i < 0 ? '.' : i === 0 ? '/' : n.slice(0, i)
}

/** `rel` is `root` itself or beneath it. */
export const within = (root: string, p: string) => p === root || p.startsWith(`${root}/`)

/** The project-relative spelling of `abs` under `root`, or `abs` when it lies outside. */
export const relTo = (root: string, abs: string) => (within(root, abs) ? (abs === root ? '.' : abs.slice(root.length + 1)) : abs)

/** Bash-glob match per entry, as the factory rule files spell scopes: `dir/**` also matches `dir` itself. */
export function inScope(rel: string, globs: readonly string[] | undefined): boolean {
  for (const g of globs ?? []) {
    if (g === '') continue
    const dir = g.endsWith('/**') ? g.slice(0, -3) : undefined
    if (dir !== undefined) {
      const head = globToRegExp(dir)
      const parts = rel.split('/')
      for (let i = 1; i <= parts.length; i++) if (head.test(parts.slice(0, i).join('/'))) return true
      continue
    }
    if (globToRegExp(g).test(rel)) return true
  }
  return false
}

export function globToRegExp(glob: string): RegExp {
  let re = ''
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i]!
    if (c === '*') {
      if (glob[i + 1] === '*') {
        re += '.*'
        i++
        if (glob[i + 1] === '/') i++
      } else re += '[^/]*'
    } else if (c === '?') re += '[^/]'
    else re += c.replace(/[.+^${}()|[\]\\]/g, '\\$&')
  }
  return new RegExp(`^${re}$`)
}
