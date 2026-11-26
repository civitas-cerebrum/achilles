// "Drives the UI", defined once by taint and shared by the rules that ask it (hook branches through verbs,
// page-object classes, constant-table tests, sleep helpers).
//
// Tainted names in a function body: parameters that hold a framework or driver binding (by annotation, by a
// framework-like name when untyped or `any`, a destructured fixtures parameter's framework keys, or the argument
// positions the caller handed a binding to), and from those their aliases (`const s = steps`), destructured
// members (`const { click } = steps`), member reads (`opts.steps`) and containers (`{ steps }`, `[page]`).
// A call drives the UI when it is a member call off a tainted root whose first method is not api*, request* or
// sql*; a call of a tainted name; or a call that hands a tainted value on (directly, in an object or array, or
// spread) to a function that drives by this same definition. A function the lint cannot resolve drives. Calls
// that receive no tainted value (`bearer(user)`, `testInfo.annotations.push(…)`, `expect(…)`, logging) do not.
import { isFn, isMember, isCall, propName, unwrap, anyNode, typeName } from './ast.mjs';
import { TYPE_KIND, DRIVER_KINDS, FRAMEWORK_KINDS } from './bindings.mjs';
import { resolveRelative } from './suite.mjs';

const BINDING_NAME = /^(page|steps|context|browser|locator|repo|interactions|driver|frame)$/;
const BACK_DOOR = /^(api|request|sql)[A-Z]/;
const MAX_DEPTH = 4;

/** Identifier names a binding pattern declares. */
export function patternNames(p) {
  if (!p) return [];
  if (p.type === 'Identifier') return [p.name];
  if (p.type === 'ObjectPattern') return p.properties.flatMap((x) => patternNames(x.type === 'RestElement' ? x.argument : x.value));
  if (p.type === 'ArrayPattern') return p.elements.flatMap(patternNames);
  if (p.type === 'AssignmentPattern') return patternNames(p.left);
  if (p.type === 'RestElement') return patternNames(p.argument);
  if (p.type === 'TSParameterProperty') return patternNames(p.parameter);
  return [];
}

/** Names of a parameter that hold a binding by their own shape: annotation, a framework-like name, fixture keys. */
function bindingParamNames(p) {
  const q = p.type === 'AssignmentPattern' ? p.left : p.type === 'TSParameterProperty' ? p.parameter : p;
  if (q.type === 'Identifier') {
    const k = TYPE_KIND[typeName(q)];
    const tn = typeName(q);
    if (k && (FRAMEWORK_KINDS.has(k) || DRIVER_KINDS.has(k))) return [q.name];
    return (!tn || tn === 'any' || tn === 'unknown') && BINDING_NAME.test(q.name) ? [q.name] : [];
  }
  if (q.type === 'ObjectPattern') return q.properties.filter((x) => x.type === 'ObjectProperty' && BINDING_NAME.test(x.key.name || x.key.value || '')).flatMap((x) => patternNames(x.value));
  return [];
}

/** The identifier at the root of a member / call / await chain, and the first method called off it. */
function chain(e) {
  let r = unwrap(e);
  let first = null;
  while (r && (isMember(r) || isCall(r) || r.type === 'AwaitExpression')) {
    if (r.type === 'AwaitExpression') { r = unwrap(r.argument); continue; }
    if (isCall(r)) { const c = unwrap(r.callee); if (isMember(c)) first = propName(c); r = isMember(c) ? unwrap(c.object) : c; continue; }
    r = unwrap(r.object);
  }
  return { root: r && r.type === 'Identifier' ? r.name : null, first };
}

/**
 * The drive checker for a project: { bodyDrives(fn, file, positions), callHandsOn(call, tainted) }.
 * `localFunction(file, name)` and `importsOf(file)` come from the caller's module helpers.
 */
export function makeDrives(project, { localFunction, importsOf }) {
  const memo = new Map();

  /** The function a name resolves to (in-file or a project import, re-exports followed), with its file. */
  function resolve(file, name, depth = 0) {
    const local = localFunction(file, name);
    if (local) return { fn: local, file };
    const imp = importsOf(file).get(name);
    if (!imp || depth > MAX_DEPTH) return null;
    const target = resolveRelative(file.abs, imp.source);
    const tf = target && project.allFiles.find((f) => f.abs === target);
    if (!tf) return null;
    const direct = resolve(tf, imp.imported, depth + 1);
    if (direct) return direct;
    for (const st of tf.ast.program.body) {
      if (st.type === 'ExportAllDeclaration') { const t = resolveRelative(tf.abs, st.source.value); const f = t && project.allFiles.find((x) => x.abs === t); const r = f && depth < MAX_DEPTH ? resolveInFile(f, imp.imported, depth + 1) : null; if (r) return r; }
      if (st.type === 'ExportNamedDeclaration' && st.source) for (const sp of st.specifiers) if (sp.local && (sp.exported.name || sp.exported.value) === imp.imported) {
        const t = resolveRelative(tf.abs, st.source.value); const f = t && project.allFiles.find((x) => x.abs === t); const r = f ? resolveInFile(f, sp.local.name || sp.local.value, depth + 1) : null; if (r) return r;
      }
    }
    return null;
  }
  const resolveInFile = (file, name, depth) => { const fn = localFunction(file, name); return fn ? { fn, file } : depth < MAX_DEPTH ? resolve(file, name, depth) : null; };

  /** An argument hands a tainted value on: the name, a member read off it, or a container holding one. */
  const handsOn = (a, tainted) => {
    const u = unwrap(a && a.type === 'SpreadElement' ? a.argument : a);
    if (!u) return false;
    if (u.type === 'Identifier') return tainted.has(u.name);
    if (isMember(u)) { const { root } = chain(u); return !!root && tainted.has(root) && !anyNode(u, isCall); }
    if (u.type === 'ObjectExpression') return u.properties.some((p) => handsOn(p.type === 'SpreadElement' ? p : p.type === 'ObjectProperty' ? p.value : null, tainted));
    if (u.type === 'ArrayExpression') return u.elements.some((e) => e && handsOn(e, tainted));
    return false;
  };

  /** Does `fn` (in `file`) drive the UI, with the parameters at `positions` holding a binding? */
  function bodyDrives(fn, file, positions = [], depth = 0) {
    if (depth > MAX_DEPTH) return true;
    const key = `${file && file.abs}:${fn.start}:${[...positions].join(',')}`;
    if (memo.has(key)) return memo.get(key);
    memo.set(key, true); // a cycle drives (conservative)
    const tainted = new Set();
    fn.params.forEach((p, i) => { for (const n of bindingParamNames(p)) tainted.add(n); if (positions.includes(i)) for (const n of patternNames(p)) tainted.add(n); });
    const result = !!fn.body && tainted.size > 0 && driven(fn.body, file, tainted, depth);
    memo.set(key, result);
    return result;
  }

  /** Does code under `root` drive the UI, given the tainted names (extended by aliases found here)? */
  function driven(root, file, tainted, depth = 0) {
    tainted = new Set(tainted);
    for (let changed = true; changed;) {
      changed = false;
      anyNode(root, (x) => {
        if (x.type !== 'VariableDeclarator' || !x.init) return false;
        const init = unwrap(x.init);
        const { root: r, first } = chain(init);
        const fromBinding = (r && tainted.has(r) && !(first && BACK_DOOR.test(first))) || handsOn(init, tainted);
        if (fromBinding) for (const n of patternNames(x.id)) if (!tainted.has(n)) { tainted.add(n); changed = true; }
        return false;
      });
    }
    return anyNode(root, (x) => {
      if (!isCall(x) && x.type !== 'NewExpression') return false;
      const c = unwrap(x.callee);
      if (c.type === 'Identifier' && tainted.has(c.name)) return true;
      if (isMember(c)) {
        const { root: r } = chain(c);
        if (r && tainted.has(r)) {
          // the method called directly off the binding decides: steps.apiGet(…).then(…) is a value
          const { first } = chain(x);
          return !(first && BACK_DOOR.test(first));
        }
      }
      const positions = x.arguments.map((a, i) => (handsOn(a, tainted) ? i : -1)).filter((i) => i >= 0);
      if (!positions.length) return false;
      if (c.type === 'Identifier' && /^(expect|String|Number|Boolean)$/.test(c.name)) return false;
      if (isMember(c) && chain(c).root === 'console') return false;
      const target = c.type === 'Identifier' && file ? resolve(file, c.name) : null;
      return !target || bodyDrives(target.fn, target.file, positions, depth + 1);
    });
  }

  /** A call hands a binding on to a function that drives (or one the lint cannot resolve). */
  function callDrives(call, file, isBinding) {
    const positions = call.arguments.map((a, i) => (isBinding(a) ? i : -1)).filter((i) => i >= 0);
    if (!positions.length) return false;
    const c = unwrap(call.callee);
    const target = c.type === 'Identifier' ? resolve(file, c.name) : null;
    return !target || bodyDrives(target.fn, target.file, positions, 1);
  }

  return { bodyDrives, driven, callDrives, resolve };
}

export { isFn };
