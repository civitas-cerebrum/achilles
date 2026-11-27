// Parser loading and the AST helpers every spec-lint module shares.
// The parser is @babel/parser, loaded through the adapter's import-boundary screen (one loader chain:
// this package's copy first, then the project's own).
import { createRequire } from 'node:module';
import path from 'node:path';

const require = createRequire(import.meta.url);
const { loadParser } = require('../../../claude-code/lib/import-boundary-scan.js');

let cached = null;
/** The @babel/parser module (this package's dependency, else the project's copy under `root`). */
export function parserFor(root) {
  if (!cached) cached = loadParser(root);
  return cached;
}

const BASE_PLUGINS = ['typescript', 'decorators-legacy', 'classProperties', 'topLevelAwait', 'importAttributes'];

/** Parses test or support code. Throws the parser's error (with `loc`) when no plugin set accepts the file. */
export function parseCode(parser, text, file) {
  const jsx = /\.(tsx|jsx)$/i.test(file);
  const opts = (plugins, sourceType = 'module') => ({
    sourceType, plugins, errorRecovery: false, attachComment: true,
    allowReturnOutsideFunction: true, allowImportExportEverywhere: true, allowAwaitOutsideFunction: true,
  });
  const attempts = [opts(jsx ? [...BASE_PLUGINS, 'jsx'] : BASE_PLUGINS), opts([...BASE_PLUGINS, 'jsx']), opts(BASE_PLUGINS, 'script')];
  let first = null;
  for (const o of jsx ? attempts.slice(1) : attempts) {
    try { return parser.parse(text, o); } catch (e) { first ??= e; }
  }
  throw first;
}

/** Parses a type declaration file. */
export function parseDts(parser, text) {
  return parser.parse(text, { sourceType: 'module', plugins: [['typescript', { dts: true }], 'decorators-legacy'], errorRecovery: true });
}

export const SKIP_KEYS = new Set(['loc', 'start', 'end', 'extra', 'range', 'leadingComments', 'trailingComments', 'innerComments', 'comments', 'tokens', 'errors']);

export const isFn = (n) => !!n && (n.type === 'ArrowFunctionExpression' || n.type === 'FunctionExpression' || n.type === 'FunctionDeclaration' || n.type === 'ObjectMethod' || n.type === 'ClassMethod' || n.type === 'ClassPrivateMethod');
export const isMember = (n) => !!n && (n.type === 'MemberExpression' || n.type === 'OptionalMemberExpression');
export const isCall = (n) => !!n && (n.type === 'CallExpression' || n.type === 'OptionalCallExpression');
export const isStr = (n) => !!n && (n.type === 'StringLiteral' || (n.type === 'TemplateLiteral' && n.expressions.length === 0));
export const strValue = (n) => (n.type === 'StringLiteral' ? n.value : n.quasis.map((q) => q.value.cooked).join(''));
const WRAPPERS = new Set(['TSAsExpression', 'TSNonNullExpression', 'ParenthesizedExpression', 'TSSatisfiesExpression', 'TSTypeAssertion', 'TypeCastExpression']);
export const isWrapper = (n) => !!n && WRAPPERS.has(n.type);

/** Strips type casts, non-null assertions and parentheses. */
export function unwrap(n) {
  while (n && isWrapper(n)) n = n.expression;
  return n;
}

/** A member's statically known property name, or null (computed from code). */
export function propName(m) {
  if (!isMember(m)) return null;
  if (!m.computed) return m.property.type === 'Identifier' ? m.property.name : m.property.type === 'PrivateName' ? `#${m.property.id.name}` : null;
  const p = unwrap(m.property);
  return isStr(p) ? strValue(p) : p.type === 'NumericLiteral' ? String(p.value) : null;
}

/** `test.describe.only` → ['test', 'describe', 'only']; null when the chain is not identifiers and names. */
export function memberChain(callee) {
  const out = [];
  let n = unwrap(callee);
  while (isMember(n)) {
    const p = propName(n);
    if (p === null) return null;
    out.unshift(p);
    n = unwrap(n.object);
  }
  if (n && n.type === 'Identifier') { out.unshift(n.name); return out; }
  return null;
}

/** The identifier at the root of a member / call / await chain. */
export function rootIdent(n) {
  for (;;) {
    if (!n) return null;
    if (n.type === 'Identifier') return n;
    if (isMember(n)) n = n.object;
    else if (isCall(n)) n = n.callee;
    else if (n.type === 'AwaitExpression') n = n.argument;
    else if (isWrapper(n)) n = n.expression;
    else return null;
  }
}

/** Child nodes of `n` in source order. */
export function* children(n) {
  for (const k of Object.keys(n)) {
    if (SKIP_KEYS.has(k)) continue;
    const v = n[k];
    if (Array.isArray(v)) { for (const c of v) if (c && typeof c.type === 'string') yield c; }
    else if (v && typeof v.type === 'string') yield v;
  }
}

/** True when `pred` holds for `root` or any node below it. */
export function anyNode(root, pred, { intoFunctions = true } = {}) {
  const stack = [root];
  while (stack.length) {
    const x = stack.pop();
    if (!x || typeof x.type !== 'string') continue;
    if (pred(x)) return true;
    if (!intoFunctions && x !== root && isFn(x)) continue;
    for (const c of children(x)) stack.push(c);
  }
  return false;
}

/** The name of a type reference annotation (`page: Page` → 'Page'), or null. */
export function typeName(node) {
  const ta = node && node.typeAnnotation && (node.typeAnnotation.typeAnnotation || node.typeAnnotation);
  if (!ta) return null;
  if (ta.type === 'TSTypeReference') {
    const t = ta.typeName;
    return t.type === 'Identifier' ? t.name : t.type === 'TSQualifiedName' ? t.right.name : null;
  }
  if (ta.type === 'TSAnyKeyword') return 'any';
  if (ta.type === 'TSUnknownKeyword') return 'unknown';
  return null;
}

export const relPosix = (root, abs) => path.relative(root, abs).split(path.sep).join('/');
