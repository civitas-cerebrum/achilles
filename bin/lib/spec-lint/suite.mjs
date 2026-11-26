// Suite-level facts across files: the import graph (which support modules a spec reaches, used for the
// support classification and, with --suite, for following a touched spec's imports), and the repository
// resolution of TB-A6 (a later unit: the definition fix that resolves the repository exactly as the
// fixture does is not implemented yet, so it resolves nothing).
import { existsSync, statSync } from 'node:fs';
import path from 'node:path';
import { isCall, isStr, strValue } from './ast.mjs';

const EXTS = ['.ts', '.tsx', '.mts', '.cts', '.js', '.jsx', '.mjs', '.cjs'];

/** Module specifiers a file loads: static imports, re-exports, require('…') and import('…') with literal specifiers. */
export function specifiers(ast) {
  const out = [];
  for (const st of ast.program.body) {
    if ((st.type === 'ImportDeclaration' || st.type === 'ExportAllDeclaration' || st.type === 'ExportNamedDeclaration') && st.source) out.push(st.source.value);
  }
  const stack = [ast.program];
  while (stack.length) {
    const n = stack.pop();
    if (!n || typeof n.type !== 'string') continue;
    if (isCall(n) && n.arguments.length && isStr(n.arguments[0]) && ((n.callee.type === 'Identifier' && n.callee.name === 'require') || n.callee.type === 'Import')) out.push(strValue(n.arguments[0]));
    if (n.type === 'ImportExpression' && isStr(n.source)) out.push(strValue(n.source));
    for (const k of Object.keys(n)) {
      if (k === 'loc' || k === 'leadingComments' || k === 'trailingComments' || k === 'innerComments') continue;
      const v = n[k];
      if (Array.isArray(v)) for (const c of v) { if (c && typeof c.type === 'string') stack.push(c); }
      else if (v && typeof v.type === 'string') stack.push(v);
    }
  }
  return [...new Set(out)];
}

/** Resolves a relative specifier from `fromAbs` to a code file, or null (bare packages and path aliases are not followed). */
export function resolveRelative(fromAbs, spec) {
  if (!spec.startsWith('.')) return null;
  const base = path.resolve(path.dirname(fromAbs), spec);
  const tries = [base, ...EXTS.map((e) => base + e), ...EXTS.map((e) => base.replace(/\.[cm]?js$/, e)), ...EXTS.map((e) => path.join(base, `index${e}`))];
  for (const t of tries) if (existsSync(t) && statSync(t).isFile()) return t;
  return null;
}

/** Every file reachable from `starts` through `edges` (abs → abs[]), the starts excluded unless reached again. */
export function reachable(starts, edges) {
  const seen = new Set();
  const stack = [...starts];
  while (stack.length) {
    const f = stack.pop();
    for (const g of edges.get(f) || []) if (!seen.has(g)) { seen.add(g); stack.push(g); }
  }
  return seen;
}

/** TB-A6 (later unit): repository names are not resolved yet. */
export function unresolvedRepositoryNames() {
  return [];
}
