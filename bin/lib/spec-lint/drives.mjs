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

/** The expressions a value may come from: both branches of `?:`, `&&`, `||`, `??`, a sequence's tail, an await. */
function alternatives(e) {
  const u = unwrap(e);
  if (!u) return [];
  if (u.type === 'ConditionalExpression') return [...alternatives(u.consequent), ...alternatives(u.alternate)];
  if (u.type === 'LogicalExpression') return [...alternatives(u.left), ...alternatives(u.right)];
  if (u.type === 'SequenceExpression') return alternatives(u.expressions.at(-1));
  if (u.type === 'AwaitExpression') return alternatives(u.argument);
  return [u];
}

/** The identifier at the root of a member / call / await chain, and the first method called off it. */
function chain(e) {
  let r = unwrap(e);
  let first = null;
  while (r && (isMember(r) || isCall(r) || r.type === 'AwaitExpression' || r.type === 'SequenceExpression')) {
    if (r.type === 'AwaitExpression') { r = unwrap(r.argument); continue; }
    if (r.type === 'SequenceExpression') { r = unwrap(r.expressions.at(-1)); continue; }
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
    const alts = alternatives(a && a.type === 'SpreadElement' ? a.argument : a);
    if (alts.length > 1 || (alts[0] && alts[0] !== unwrap(a && a.type === 'SpreadElement' ? a.argument : a))) return alts.some((x) => handsOn(x, tainted));
    const u = alts[0];
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
    const tainted = new Set(file ? moduleTaint(file) : []);
    fn.params.forEach((p, i) => { for (const n of bindingParamNames(p)) tainted.add(n); if (positions.includes(i)) for (const n of patternNames(p)) tainted.add(n); });
    if (fn.params.some((p, i) => positions.includes(i) || bindingParamNames(p).length)) tainted.add('arguments');
    const result = !!fn.body && tainted.size > 0 && driven(fn.body, file, tainted, depth);
    memo.set(key, result);
    return result;
  }

  /** A value comes from a tainted name: an alias, a member read, a container, or a branch of a conditional. */
  const fromBinding = (e, tainted) => alternatives(e).some((v) => {
    const { root: r, first } = chain(v);
    return (r && tainted.has(r) && !(first && BACK_DOOR.test(first))) || handsOn(v, tainted);
  });

  /**
   * Names of a module's top-level `let` / `var` variables assigned anywhere in it from a function parameter that
   * may hold a binding (untyped, `any`, framework-typed or framework-named): `let current; export function
   * remember(s) { current = s; }`. Read inside that module, they hold the binding.
   */
  function moduleTaint(file) {
    if (file.facts.moduleTaint) return file.facts.moduleTaint;
    const vars = new Set();
    for (const st of file.ast.program.body) {
      const d = st.type === 'ExportNamedDeclaration' ? st.declaration : st;
      if (d && d.type === 'VariableDeclaration' && d.kind !== 'const') for (const x of d.declarations) for (const n of patternNames(x.id)) vars.add(n);
    }
    const out = new Set();
    if (vars.size) {
      const loose = (p) => { const q = p.type === 'AssignmentPattern' ? p.left : p; const tn = q.type === 'Identifier' ? typeName(q) : null; return q.type === 'Identifier' && (!tn || tn === 'any' || tn === 'unknown' || bindingParamNames(q).length > 0); };
      anyNode(file.ast.program, (fn) => {
        if (!isFn(fn)) return false;
        const params = new Set(fn.params.filter(loose).flatMap((p) => patternNames(p)));
        if (!params.size) return false;
        anyNode(fn.body, (x) => {
          if (x.type !== 'AssignmentExpression' || x.operator !== '=') return false;
          const left = x.left.type === 'Identifier' ? x.left.name : chain(x.left).root;
          if (left && vars.has(left) && fromBinding(x.right, params)) out.add(left);
          return false;
        });
        return false;
      });
    }
    return (file.facts.moduleTaint = out);
  }

  /** Functions declared under `root` by name (closures a call may run). */
  const localFns = (root) => {
    const out = new Map();
    anyNode(root, (x) => {
      if (x.type === 'FunctionDeclaration' && x.id) out.set(x.id.name, x);
      if (x.type === 'VariableDeclarator' && x.id.type === 'Identifier' && isFn(unwrap(x.init))) out.set(x.id.name, unwrap(x.init));
      return false;
    });
    return out;
  };

  /**
   * Does code under `root` drive the UI, given the tainted names (extended here by aliases, assignments,
   * conditional branches and objects a binding is stored on)? `scope` is the function body closures are
   * looked up in (default: `root`).
   */
  function driven(root, file, tainted, depth = 0, scope = root) {
    tainted = new Set(tainted);
    for (let changed = true; changed;) {
      changed = false;
      const add = (n) => { if (n && !tainted.has(n)) { tainted.add(n); changed = true; } };
      anyNode(scope, (x) => {
        if (x.type === 'VariableDeclarator' && x.init && fromBinding(x.init, tainted)) for (const n of patternNames(x.id)) add(n);
        if (x.type === 'AssignmentExpression' && fromBinding(x.right, tainted)) {
          if (x.left.type === 'Identifier') add(x.left.name);
          else if (isMember(x.left)) add(chain(x.left).root); // `o.s = steps` taints `o`
          else for (const n of patternNames(x.left)) add(n);
        }
        return false;
      });
    }
    const closures = localFns(scope);
    return anyNode(root, (x) => {
      if (!isCall(x) && x.type !== 'NewExpression') return false;
      const c = unwrap(x.callee);
      if (c.type === 'Identifier' && tainted.has(c.name)) return true;
      // a closure or a module function that reads a tainted name runs with that taint
      if (c.type === 'Identifier' && depth < MAX_DEPTH) {
        const closure = closures.get(c.name);
        if (closure && closure.body && driven(closure.body, file, tainted, depth + 1, closure.body)) return true;
        if (!closure && file && !x.arguments.some((a) => handsOn(a, tainted))) {
          const target = resolve(file, c.name);
          if (target && target.fn.body && moduleTaint(target.file).size && bodyDrives(target.fn, target.file, [], depth + 1)) return true;
        }
      }
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
