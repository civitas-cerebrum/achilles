// Code shapes the flow, structure, identity and readability families share: what drives the test,
// what asserts, loops and one-pass loops, the comment block above a statement, defect tags.
import { isFn, isMember, isCall, propName, memberChain, unwrap, rootIdent, isStr, strValue, anyNode } from './ast.mjs';
import { DRIVER_KINDS, FRAMEWORK_KINDS, classifyCall, testChain } from './bindings.mjs';
import { blockAbove } from './waivers.mjs';

export const LOOPS = new Set(['ForStatement', 'ForOfStatement', 'ForInStatement', 'WhileStatement', 'DoWhileStatement']);
export const ITERATION = new Set(['forEach', 'map', 'flatMap', 'filter', 'some', 'every', 'find', 'findLast', 'reduce']);
const ASSERT_NAME = /^(expect|verify|assert)/i;
const ACTOR_KIND = (k) => typeof k === 'string' && (DRIVER_KINDS.has(k) || FRAMEWORK_KINDS.has(k) || k.startsWith('fixture:') || k === 'fixtures');

/** A loop that runs its body at most once: `for (… of [x])`, `do {} while (false)`, `for (let i = 0; i < 1; …)`. */
export function onePass(n) {
  if (n.type === 'ForOfStatement') { const r = unwrap(n.right); return r.type === 'ArrayExpression' && r.elements.length <= 1; }
  if (n.type === 'DoWhileStatement') { const t = unwrap(n.test); return (t.type === 'BooleanLiteral' && !t.value) || (t.type === 'NumericLiteral' && t.value === 0); }
  if (n.type === 'ForStatement' && n.test && n.test.type === 'BinaryExpression' && n.init && n.init.type === 'VariableDeclaration') {
    const d = n.init.declarations[0];
    const t = n.test;
    return !!(d && d.init && d.init.type === 'NumericLiteral' && d.init.value === 0 && t.operator === '<' && t.right.type === 'NumericLiteral' && t.right.value <= 1 && t.left.type === 'Identifier' && d.id.type === 'Identifier' && t.left.name === d.id.name);
  }
  return false;
}

/** The ancestors of the current node up to (not including) the nearest function, innermost first. */
export function* upToFunction(stack) {
  for (let i = stack.length - 2; i >= 0; i--) {
    if (isFn(stack[i])) return;
    yield [stack[i], stack[i + 1]];
  }
}

/** The current node sits in the body of a loop (one-pass loops excluded) inside its own function. */
export function inLoop(stack) {
  for (const [a, child] of upToFunction(stack)) {
    if (LOOPS.has(a.type) && !onePass(a) && child === a.body) return true;
  }
  return false;
}

/** The node is an assertion call: `expect…`, `steps.verify*` / `steps.expect`, a Steps chain ending in a matcher, a call of `expect…`, `verify…` or `assert…`. */
export function isAssertion(x, kind) {
  if (!isCall(x)) return false;
  const c = unwrap(x.callee);
  const ch = memberChain(c) || [];
  if (ch[0] === 'expect') return true;
  if (c.type === 'Identifier') return ASSERT_NAME.test(c.name);
  if (!isMember(c)) return false;
  const p = propName(c) || '';
  const r = rootIdent(c);
  const rk = r ? kind(r) : null;
  if (rk === 'steps' && (/^(verify|expect)/.test(p) || /^to[A-Z]/.test(p) || p === 'satisfy' || p === 'throws')) return true;
  // a matcher at the end of a chain rooted at expect(…) or steps…
  let b = c;
  while (isMember(b) || isCall(b)) b = isMember(b) ? unwrap(b.object) : unwrap(b.callee);
  if (b && b.type === 'Identifier' && b.name === 'expect' && (/^to[A-Z]/.test(p) || p === 'toPass')) return true;
  return false;
}

/**
 * The node drives the test: an assertion, a Steps / repository / interactions / driver call, a call on a project
 * fixture, or a verb call (a call that receives a Steps, framework or driver binding).
 */
export function isDriving(x, kind) {
  if (!isCall(x) && x.type !== 'NewExpression') return false;
  if (isCall(x) && isAssertion(x, kind)) return true;
  const c = unwrap(x.callee);
  const r = rootIdent(c);
  if (r && ACTOR_KIND(kind(r))) return true;
  return x.arguments.some((a) => { const u = unwrap(a && a.type === 'SpreadElement' ? a.argument : a); return u && ACTOR_KIND(kind(u)); });
}

/** Some node below `root` drives the test (nested callbacks included). */
export const drives = (root, kind) => !!root && anyNode(root, (y) => isDriving(y, kind));
/** Some `await` below `root` awaits a driving call. */
export const awaitsDriving = (root, kind) => !!root && anyNode(root, (y) => y.type === 'AwaitExpression' && anyNode(y.argument, (z) => isDriving(z, kind)));

/** The statement on the stack nearest the current node. */
export function statementOf(stack) {
  for (let i = stack.length - 1; i >= 0; i--) if (/Statement$|Declaration$/.test(stack[i].type) && stack[i].type !== 'BlockStatement') return stack[i];
  return null;
}

/** Text of the contiguous comment block directly above `line` (comment-only lines), top to bottom. */
export function commentBlockAbove(file, line) {
  return blockAbove(line, file.commentLines).sort((a, b) => a - b).map((l) => file.lines[l - 1]);
}

/** The text of a trailing `// …` comment on `line`, or ''. */
export function trailingComment(file, line) {
  for (const c of file.ast.comments || []) if (c.loc.start.line === line && c.type === 'CommentLine' && file.lines[line - 1].slice(0, c.loc.start.column).trim() !== '') return c.value;
  return '';
}

/** The string tags of a test or describe call: title `@tags` plus the `tag` option. */
export function tagsOf(call) {
  const out = new Set();
  const t = unwrap(call.arguments[0]);
  const title = t && (isStr(t) ? strValue(t) : t.type === 'TemplateLiteral' ? t.quasis.map((q) => q.value.cooked).join(' ') : '');
  for (const m of (title || '').matchAll(/(^|\s)(@[\w-]+)/g)) out.add(m[2]);
  for (const a of call.arguments.slice(1)) {
    const o = unwrap(a);
    if (!o || o.type !== 'ObjectExpression') continue;
    for (const pr of o.properties) {
      if (pr.type !== 'ObjectProperty' || propKey(pr) !== 'tag') continue;
      const v = unwrap(pr.value);
      for (const e of v.type === 'ArrayExpression' ? v.elements : [v]) if (e && isStr(e)) out.add(strValue(e));
    }
  }
  return out;
}

export const propKey = (pr) => (pr.key && (pr.key.type === 'Identifier' ? pr.key.name : isStr(pr.key) ? strValue(pr.key) : null));

/** The enclosing test / describe declaration calls of the current node, innermost first. */
export function enclosingDeclarations(stack, names) {
  const out = [];
  for (let i = stack.length - 2; i >= 0; i--) {
    const n = stack[i];
    if (!isCall(n)) continue;
    const c = classifyCall(n, names);
    if (c && (c.type === 'test' || c.type === 'describe') && c.fn === stack[i + 1]) out.push({ call: n, cls: c });
  }
  return out;
}

/** True when `call` is a call on a test binding whose chain ends in one of `mods` (`test.skip`, `test.describe.only`). */
export function testModifier(call, names) {
  const ch = testChain(unwrap(call.callee), names);
  return ch ? ch.slice(1) : null;
}

/**
 * The declarations of a file, computed once: tests, describes, hooks and the module- or describe-level
 * helper functions, each with its describe chain (innermost last).
 */
export function declarations(file) {
  if (file.facts.decls) return file.facts.decls;
  const out = { tests: [], describes: [], hooks: [], helpers: [], steps: [] };
  const names = file.testNames;
  const helperOf = (st, chain, exported) => {
    if (st.type === 'FunctionDeclaration' && st.id) out.helpers.push({ name: st.id.name, fn: st, node: st, exported, describes: chain });
    if (st.type === 'VariableDeclaration') for (const d of st.declarations) if (d.id.type === 'Identifier' && isFn(unwrap(d.init))) out.helpers.push({ name: d.id.name, fn: unwrap(d.init), node: st, exported, describes: chain });
  };
  const visit = (n, chain) => {
    if (!n || typeof n.type !== 'string') return;
    if (isCall(n)) {
      const c = classifyCall(n, names);
      if (c && c.type === 'describe') {
        const d = { call: n, fn: c.fn, cls: c, depth: chain.length + 1, describes: chain, line: n.loc.start.line, endLine: n.loc.end.line };
        out.describes.push(d);
        for (const a of n.arguments) if (a !== c.fn) visit(a, chain);
        for (const st of c.fn.body.type === 'BlockStatement' ? c.fn.body.body : []) { helperOf(st, [...chain, d], false); visit(st, [...chain, d]); }
        return;
      }
      if (c && c.type === 'test') out.tests.push({ call: n, fn: c.fn, cls: c, title: c.title, describes: chain, line: n.loc.start.line, endLine: n.loc.end.line });
      else if (c && c.type === 'hook') out.hooks.push({ call: n, fn: c.fn, mod: c.mod, describes: chain, line: n.loc.start.line, endLine: n.loc.end.line });
      else if (c && c.type === 'step') out.steps.push({ call: n, fn: c.fn });
    }
    for (const k of Object.keys(n)) {
      if (k === 'loc' || k.endsWith('Comments')) continue;
      const v = n[k];
      if (Array.isArray(v)) { for (const x of v) if (x && typeof x.type === 'string') visit(x, chain); } else if (v && typeof v.type === 'string') visit(v, chain);
    }
  };
  for (const st of file.ast.program.body) {
    if (st.type === 'ExportNamedDeclaration' && st.declaration) helperOf(st.declaration, [], true);
    else if (st.type === 'ExportDefaultDeclaration' && isFn(st.declaration)) out.helpers.push({ name: st.declaration.id ? st.declaration.id.name : 'default', fn: st.declaration, node: st, exported: true, describes: [] });
    else helperOf(st, [], false);
    visit(st, []);
  }
  // `export { helper }` lists
  for (const st of file.ast.program.body) {
    if (st.type !== 'ExportNamedDeclaration' || st.declaration || st.source) continue;
    for (const sp of st.specifiers) { const h = out.helpers.find((x) => x.name === (sp.local.name || sp.local.value)); if (h) h.exported = true; }
  }
  return (file.facts.decls = out);
}

/** Identifier names referenced (not as property keys) below `root`. */
export function referencedNames(root) {
  const out = new Set();
  const rec = (n, parent, key) => {
    if (!n || typeof n.type !== 'string') return;
    if (n.type === 'Identifier') {
      const asKey = parent && ((isMember(parent) && key === 'property' && !parent.computed) || ((parent.type === 'ObjectProperty' || parent.type === 'ObjectMethod') && key === 'key' && !parent.computed));
      if (!asKey) out.add(n.name);
      return;
    }
    for (const k of Object.keys(n)) {
      if (k === 'loc' || k.endsWith('Comments') || k === 'typeAnnotation') continue;
      const v = n[k];
      if (Array.isArray(v)) { for (const x of v) if (x && typeof x.type === 'string') rec(x, n, k); } else if (v && typeof v.type === 'string') rec(v, n, k);
    }
  };
  rec(root, null, null);
  return out;
}

export { isFn, isMember, isCall, propName, memberChain, unwrap, rootIdent, isStr, strValue, anyNode };
