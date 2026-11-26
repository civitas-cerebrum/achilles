// Driver-binding kinds and regions (test-baseline.md §Driver bindings).
//
// A value's kind is one of
//   driver     page, frame, context, browser, request, locator, input (keyboard / mouse / touchscreen)
//   framework  steps, repo, interactions, interactions-part (interactions.interact / verify / …), element
//   other      contextStore, fixtures (an undestructured fixtures object), fixture:<name> (a project
//              fixture of unknown kind), untyped (an unannotated or `any` parameter), response, apirequest
// Kinds come from fixture parameters by key (and `fx.page` on an undestructured fixtures object), custom
// fixtures by their extend type argument or by what the fixture body passes to use(…), parameters by
// annotation or name, variables by initialiser or (declared without one) by annotation, later assignments
// (written to the declaring scope), destructuring over a driver or fixtures value, the `.locator` of a
// repository element, the reach-through members of TB-A14 (`repo.driver`, `steps.page`, …), and
// containers: an array or list of one kind is `list:<kind>` (indexing, iteration and iteration callbacks
// yield the kind), an object literal holding bindings is `obj:{"key":"kind"}`.
import { isFn, isMember, isCall, propName, memberChain, unwrap, typeName, isStr, strValue } from './ast.mjs';

export const DRIVER_KINDS = new Set(['page', 'frame', 'context', 'browser', 'request', 'locator', 'input']);
export const FRAMEWORK_KINDS = new Set(['steps', 'repo', 'interactions', 'interactions-part', 'element']);
export const FIXTURE_KIND = { page: 'page', context: 'context', browser: 'browser', request: 'request', steps: 'steps', repo: 'repo', interactions: 'interactions', contextStore: 'contextStore' };
export const TYPE_KIND = {
  Page: 'page', BrowserContext: 'context', Browser: 'browser', Locator: 'locator', FrameLocator: 'locator', Frame: 'frame',
  APIRequestContext: 'request', Keyboard: 'input', Mouse: 'input', Touchscreen: 'input',
  Steps: 'steps', ElementRepository: 'repo', ElementInteractions: 'interactions', WebElement: 'element', Element: 'element', ContextStore: 'contextStore',
};
const NAME_KIND = { page: 'page', context: 'context', browser: 'browser', locator: 'locator', steps: 'steps', repo: 'repo', interactions: 'interactions' };
export const LOCATOR_CTORS = new Set(['locator', 'getByRole', 'getByText', 'getByTestId', 'getByLabel', 'getByPlaceholder', 'getByAltText', 'getByTitle', 'frameLocator', '$', '$$']);
export const LOCATOR_CHAIN = new Set(['first', 'last', 'nth', 'filter', 'and', 'or', 'contentFrame', 'owner', 'describe']);
const REPO_ELEMENT_CALLS = /^(get|getAll|getByText|getByAttribute|getByIndex|getRandom|getVisible|getByRole|getByVisibleText)$/;
const REACH = /^_?(page|driver|browser|context)$/;
export const TEST_MODIFIERS = new Set(['only', 'skip', 'fixme', 'fail', 'slow']);
export const HOOKS = new Set(['beforeEach', 'afterEach', 'beforeAll', 'afterAll']);

export class Scope {
  constructor(parent = null, fn = null) { this.parent = parent; this.fn = fn; this.vars = new Map(); this.decls = new Set(); }
  lookup(name) { for (let s = this; s; s = s.parent) if (s.vars.has(name)) return s.vars.get(name); return null; }
  declaring(name) { for (let s = this; s; s = s.parent) if (s.decls.has(name) || s.vars.has(name)) return s; return null; }
  get isModule() { return this.parent === null; }
}

/** The kind a reach-through member read yields (`steps.page` → page, `repo.context` → context), or null. */
export function reachKind(objKind, prop) {
  if (!FRAMEWORK_KINDS.has(objKind) || !prop || !REACH.test(prop)) return null;
  const p = prop.replace(/^_/, '');
  return p === 'context' ? 'context' : p === 'browser' ? 'browser' : 'page';
}

const meaningful = (k) => DRIVER_KINDS.has(k) || FRAMEWORK_KINDS.has(k);
/** The kind of each element of a `list:<kind>`, or null. */
export const listElement = (k) => (typeof k === 'string' && k.startsWith('list:') ? k.slice(5) : null);
const objMembers = (k) => (typeof k === 'string' && k.startsWith('obj:') ? JSON.parse(k.slice(4)) : null);
const LIST_KEEP = new Set(['filter', 'slice', 'reverse', 'concat', 'toReversed', 'toSorted', 'sort']);
const LIST_PICK = new Set(['at', 'find', 'findLast', 'pop', 'shift']);

/** The kind of an expression, or null. `env.fixtureKinds` maps project fixture names to kinds. */
export function kindOf(e, scope, env) {
  e = unwrap(e);
  if (!e) return null;
  switch (e.type) {
    case 'AwaitExpression': return kindOf(e.argument, scope, env);
    case 'Identifier': return scope.lookup(e.name);
    case 'ArrayExpression': {
      for (const el of e.elements) { const k = el && el.type !== 'SpreadElement' ? kindOf(el, scope, env) : el ? listElement(kindOf(el.argument, scope, env)) : null; if (meaningful(k)) return `list:${k}`; }
      return null;
    }
    case 'ObjectExpression': {
      const out = {};
      for (const pr of e.properties) {
        if (pr.type === 'SpreadElement') { Object.assign(out, objMembers(kindOf(pr.argument, scope, env)) || {}); continue; }
        if (pr.type !== 'ObjectProperty' || pr.computed) continue;
        const key = pr.key.type === 'Identifier' ? pr.key.name : isStr(pr.key) ? strValue(pr.key) : null;
        const k = key ? kindOf(pr.value, scope, env) : null;
        if (meaningful(k)) out[key] = k;
      }
      return Object.keys(out).length ? `obj:${JSON.stringify(out)}` : null;
    }
    case 'MemberExpression': case 'OptionalMemberExpression': {
      const k = kindOf(e.object, scope, env);
      const p = propName(e);
      const le = listElement(k);
      if (le) return e.computed ? le : null;
      const om = objMembers(k);
      if (om) return p !== null && Object.hasOwn(om, p) ? om[p] : null;
      if (k === 'fixtures') return FIXTURE_KIND[p] || env.fixtureKinds.get(p) || (p ? `fixture:${p}` : null);
      const r = reachKind(k, p);
      if (r) return r;
      if (k === 'interactions' && /^(interact|verify|extract|navigate)$/.test(p || '')) return 'interactions-part';
      if (k === 'element' && p === 'locator') return 'locator';
      if (p === 'steps' && k !== 'steps' && !e.computed) return 'steps';
      if (k === 'page' && (p === 'keyboard' || p === 'mouse' || p === 'touchscreen')) return 'input';
      if ((k === 'page' || k === 'context') && p === 'request') return 'request';
      return null;
    }
    case 'NewExpression': {
      const n = e.callee.type === 'Identifier' ? e.callee.name : null;
      return n === 'Steps' ? 'steps' : n === 'WebElement' ? 'element' : n === 'ElementRepository' ? 'repo' : n === 'ElementInteractions' ? 'interactions' : null;
    }
    case 'CallExpression': case 'OptionalCallExpression': {
      const c = unwrap(e.callee);
      if (!isMember(c)) return null;
      const p = propName(c);
      const k = kindOf(c.object, scope, env);
      const le = listElement(k);
      if (le) return LIST_KEEP.has(p) ? k : LIST_PICK.has(p) ? le : null;
      if (k === 'steps') return p === 'switchToNewTab' || p === 'closeTab' ? 'page' : p === 'forPage' ? 'steps' : null;
      if (k === 'repo') return REPO_ELEMENT_CALLS.test(p || '') ? 'element' : null;
      if (k === 'page' || k === 'frame' || k === 'locator') {
        if (LOCATOR_CTORS.has(p) || LOCATOR_CHAIN.has(p)) return 'locator';
        if (p === 'context') return 'context';
        if (p === 'mainFrame' || p === 'frame' || p === 'parentFrame') return 'frame';
        if (p === 'frames' || p === 'childFrames') return 'list:frame';
        if (p === 'waitForEvent') { const a = e.arguments[0]; return isStr(a) && /^(popup|page)$/.test(strValue(a)) ? 'page' : null; }
        if (p === 'goto' || p === 'reload' || p === 'waitForResponse' || p === 'waitForRequest') return 'response';
        return null;
      }
      if (k === 'context') return p === 'newPage' || p === 'waitForEvent' ? 'page' : p === 'browser' ? 'browser' : p === 'pages' ? 'list:page' : null;
      if (k === 'browser') return p === 'newContext' ? 'context' : p === 'newPage' ? 'page' : p === 'contexts' ? 'list:context' : null;
      if (k === 'request') return p === 'newContext' ? 'request' : 'response';
      if (k === 'apirequest' && p === 'newContext') return 'request';
      const ch = memberChain(c);
      if (ch && ['chromium', 'firefox', 'webkit'].includes(ch[0]) && (p === 'launch' || p === 'connect')) return 'browser';
      return null;
    }
    default: return null;
  }
}

const annotationKind = (node) => {
  const t = typeName(node);
  return t && TYPE_KIND[t] ? TYPE_KIND[t] : null;
};

/** Binds a destructured fixtures parameter (`{ page, steps: s }`). */
function bindFixturePattern(pattern, scope, env) {
  for (const pr of pattern.properties) {
    if (pr.type === 'RestElement' && pr.argument.type === 'Identifier') { scope.decls.add(pr.argument.name); scope.vars.set(pr.argument.name, 'fixtures'); continue; }
    if (pr.type !== 'ObjectProperty') continue;
    const key = pr.key.type === 'Identifier' ? pr.key.name : isStr(pr.key) ? strValue(pr.key) : null;
    let v = pr.value;
    if (v.type === 'AssignmentPattern') v = v.left;
    if (!key || v.type !== 'Identifier') continue;
    scope.decls.add(v.name);
    scope.vars.set(v.name, FIXTURE_KIND[key] || env.fixtureKinds.get(key) || `fixture:${key}`);
  }
}

/** Binds a function's parameters. `fixtureCallback`: a test, hook or fixture callback (its first parameter holds fixtures). */
export function bindParams(fn, scope, env, { fixtureCallback = false, support = false } = {}) {
  fn.params.forEach((p, i) => {
    let q = p.type === 'AssignmentPattern' ? p.left : p;
    if (q.type === 'RestElement') q = q.argument;
    if (fixtureCallback && i === 0) {
      if (q.type === 'ObjectPattern') { bindFixturePattern(q, scope, env); return; }
      if (q.type === 'Identifier') { scope.decls.add(q.name); scope.vars.set(q.name, 'fixtures'); return; }
    }
    if (q.type === 'Identifier') {
      scope.decls.add(q.name);
      const ak = annotationKind(q);
      const tn = typeName(q);
      if (ak) scope.vars.set(q.name, ak);
      else if (!tn || tn === 'any') {
        if (NAME_KIND[q.name] && (!tn)) scope.vars.set(q.name, NAME_KIND[q.name]);
        else if (support && !fixtureCallback) scope.vars.set(q.name, 'untyped');
      }
    } else if (q.type === 'ObjectPattern') {
      // `{ page }: { page: Page }` by the member's annotation, else `{ page }` by name
      const lit = q.typeAnnotation && q.typeAnnotation.typeAnnotation;
      const typed = new Map();
      if (lit && lit.type === 'TSTypeLiteral') for (const m of lit.members) if (m.type === 'TSPropertySignature' && m.key) { const k = annotationKind(m); if (k) typed.set(m.key.name || m.key.value, k); }
      for (const pr of q.properties) {
        let v = pr.type === 'ObjectProperty' ? pr.value : pr.type === 'RestElement' ? pr.argument : null;
        if (v && v.type === 'AssignmentPattern') v = v.left;
        if (!v || v.type !== 'Identifier') continue;
        scope.decls.add(v.name);
        const key = pr.type === 'ObjectProperty' ? (pr.key.type === 'Identifier' ? pr.key.name : isStr(pr.key) ? strValue(pr.key) : null) : null;
        const k = key ? typed.get(key) || NAME_KIND[key] : null;
        if (k) scope.vars.set(v.name, k);
      }
    }
  });
}

/** Binds a variable declarator: initialiser kind, annotation, destructuring over a driver / fixtures value. */
export function bindDeclarator(d, scope, env) {
  if (d.id.type === 'Identifier') {
    scope.decls.add(d.id.name);
    const k = d.init ? kindOf(d.init, scope, env) : null;
    const ak = annotationKind(d.id);
    if (k) scope.vars.set(d.id.name, k);
    else if (ak) scope.vars.set(d.id.name, ak);
    return;
  }
  if (d.id.type === 'ObjectPattern' && d.init) {
    for (const pr of d.id.properties) {
      if (pr.type !== 'ObjectProperty') continue;
      let v = pr.value;
      if (v.type === 'AssignmentPattern') v = v.left;
      if (v.type !== 'Identifier') continue;
      scope.decls.add(v.name);
      const key = pr.key.type === 'Identifier' ? pr.key.name : isStr(pr.key) ? strValue(pr.key) : null;
      if (!key) continue;
      const mk = kindOf({ type: 'MemberExpression', object: d.init, property: { type: 'Identifier', name: key }, computed: false }, scope, env);
      if (mk) scope.vars.set(v.name, mk);
      else if (key === 'request' && isCall(unwrap(d.init)) && unwrap(d.init).callee.type === 'Identifier' && unwrap(d.init).callee.name === 'require') scope.vars.set(v.name, 'apirequest');
    }
    return;
  }
  if (d.id.type === 'ArrayPattern' && d.init) {
    const init = unwrap(d.init.type === 'AwaitExpression' ? d.init.argument : d.init);
    const arr = init.type === 'ArrayExpression' ? init.elements
      : isCall(init) && init.arguments[0] && init.arguments[0].type === 'ArrayExpression' ? init.arguments[0].elements : null;
    const whole = listElement(kindOf(d.init, scope, env));
    d.id.elements.forEach((el, i) => {
      if (!el || el.type !== 'Identifier') return;
      scope.decls.add(el.name);
      const k = (arr && arr[i] && arr[i].type !== 'SpreadElement' ? kindOf(arr[i], scope, env) : null) || whole;
      if (k) scope.vars.set(el.name, k);
    });
  }
}

/** `for (const p of <list>)` binds `p` to the list's element kind. */
export function bindForOf(n, scope, env) {
  const el = listElement(kindOf(n.right, scope, env));
  if (!el) return;
  const left = n.left.type === 'VariableDeclaration' ? n.left.declarations[0].id : n.left;
  if (left && left.type === 'Identifier') { scope.decls.add(left.name); scope.vars.set(left.name, el); }
}

/** A later assignment `x = await browser.newPage()` writes the kind to the scope that declares `x`. */
export function bindAssignment(a, scope, env) {
  if (a.left.type !== 'Identifier' || a.operator !== '=') return;
  const k = kindOf(a.right, scope, env);
  if (!k) return;
  (scope.declaring(a.left.name) || scope).vars.set(a.left.name, k);
}

/** Import bindings: `import { request } from '@playwright/test'` is the request factory. */
export function bindImports(ast, scope) {
  for (const st of ast.program.body) {
    if (st.type !== 'ImportDeclaration') continue;
    for (const sp of st.specifiers) {
      scope.decls.add(sp.local.name);
      if (sp.type === 'ImportSpecifier' && /^@?playwright/.test(st.source.value) && sp.imported.name === 'request') scope.vars.set(sp.local.name, 'apirequest');
    }
  }
}

// ── test bindings and the calls that declare tests ─────────────────────────

/**
 * The member chain of a callee rooted at a test binding, with a namespace import resolved
 * (`fx.test.describe` → ['test', 'describe']), or null.
 */
export function testChain(callee, names) {
  const ch = memberChain(callee);
  if (!ch) return null;
  if (names.namespaces && names.namespaces.has(ch[0]) && ch.length > 1 && TEST_NAMES.has(ch[1])) return ch.slice(1);
  return names.has(ch[0]) ? ch : null;
}
const TEST_NAMES = new Set(['test', 'it', 'describe', 'setup']);

const isTestFactory = (init, names) => {
  const n = unwrap(init && init.type === 'AwaitExpression' ? init.argument : init);
  if (!isCall(n)) return false;
  const ch = testChain(n.callee, names) || memberChain(n.callee);
  if (ch && (ch[0] === 'baseFixture' || ch[0] === 'mergeTests')) return true;
  if (ch && ch.at(-1) === 'extend' && testChain(n.callee, names)) return true;
  if (isMember(n.callee) && propName(n.callee) === 'extend' && isCall(unwrap(n.callee.object))) return isTestFactory(unwrap(n.callee.object), names);
  return false;
};

/** Names bound to a Playwright test object in this file: imported `test` / `it`, aliases, extend / baseFixture / mergeTests results. */
export function testBindings(ast) {
  const names = new Set();
  names.namespaces = new Set();
  for (const st of ast.program.body) {
    if (st.type !== 'ImportDeclaration') continue;
    for (const sp of st.specifiers) {
      if (sp.type === 'ImportSpecifier' && TEST_NAMES.has(sp.imported.name)) names.add(sp.local.name);
      if (sp.type === 'ImportNamespaceSpecifier' && (st.source.value.startsWith('.') || /^@playwright\/test$/.test(st.source.value))) names.namespaces.add(sp.local.name);
    }
  }
  // require destructuring and factory results, to a fixed point (an extend of an extend)
  for (let changed = true; changed;) {
    changed = false;
    const stack = [ast.program];
    while (stack.length) {
      const n = stack.pop();
      if (!n || typeof n.type !== 'string') continue;
      if (n.type === 'VariableDeclarator' && n.init) {
        if (n.id.type === 'Identifier' && !names.has(n.id.name) && (isTestFactory(n.init, names) || (unwrap(n.init).type === 'Identifier' && testChain(unwrap(n.init), names)))) { names.add(n.id.name); changed = true; }
        const r = unwrap(n.init);
        if (n.id.type === 'ObjectPattern' && isCall(r) && r.callee.type === 'Identifier' && r.callee.name === 'require') {
          for (const pr of n.id.properties) {
            const key = pr.type === 'ObjectProperty' && pr.key.type === 'Identifier' ? pr.key.name : null;
            if (key && ['test', 'it'].includes(key) && pr.value.type === 'Identifier' && !names.has(pr.value.name)) { names.add(pr.value.name); changed = true; }
          }
        }
      }
      for (const k of Object.keys(n)) {
        if (k === 'loc' || k.endsWith('Comments')) continue;
        const v = n[k];
        if (Array.isArray(v)) for (const c of v) { if (c && typeof c.type === 'string') stack.push(c); }
        else if (v && typeof v.type === 'string') stack.push(v);
      }
    }
  }
  return names;
}

function titleOf(a) {
  const n = unwrap(a);
  if (!n) return null;
  if (n.type === 'StringLiteral') return { text: n.value, dynamic: false };
  if (n.type === 'TemplateLiteral') return { text: n.quasis.map((q) => q.value.cooked).join('${}'), dynamic: n.expressions.length > 0 };
  if (n.type === 'BinaryExpression') { const l = titleOf(n.left); return l ? { text: `${l.text}…`, dynamic: true } : null; }
  return null;
}
export const idOfTitle = (t) => { const m = t && /^([A-Z][A-Z0-9]*-[A-Za-z0-9][A-Za-z0-9-]*)(?=\s|$)/.exec(t); return m ? m[1] : null; };

/**
 * What a call declares: { type: test | describe | hook | step | extend | configure | annotation, fn, title, mod }
 * or null. `test.extend(…)` and `baseFixture(…).extend(…)` are extend calls.
 */
export function classifyCall(n, names) {
  const callee = unwrap(n.callee);
  if (isMember(callee) && propName(callee) === 'extend') {
    const obj = unwrap(callee.object);
    const ch = testChain(obj, names);
    if (ch || (isCall(obj) && (isTestFactory(obj, names) || (obj.callee.type === 'Identifier' && obj.callee.name === 'baseFixture')))) return { type: 'extend' };
  }
  const ch = testChain(callee, names);
  if (!ch) return null;
  const fn = n.arguments.find(isFn) || null;
  if (ch.includes('describe')) {
    if (ch.at(-1) === 'configure') return { type: 'configure' };
    return fn ? { type: 'describe', fn, title: titleOf(n.arguments[0]), mod: ch.at(-1) } : null;
  }
  if (ch.length === 2 && HOOKS.has(ch[1])) return fn ? { type: 'hook', fn, mod: ch[1] } : null;
  if (ch.length === 2 && ch[1] === 'step') return fn ? { type: 'step', fn } : null;
  if (ch.length === 2 && ch[1] === 'extend') return { type: 'extend' };
  if (ch.length === 1 || (ch.length === 2 && TEST_MODIFIERS.has(ch[1]))) {
    const title = titleOf(n.arguments[0]);
    if (title && fn) return { type: 'test', fn, title, mod: ch[1] || null };
    if (ch.length === 2) return { type: 'annotation', mod: ch[1] };
  }
  return null;
}

/** The fixture functions of an extend call's object argument: [{ key, fn, node }]. */
export function extendFixtures(call) {
  const o = unwrap(call.arguments[0]);
  const out = [];
  if (!o || o.type !== 'ObjectExpression') return { fixtures: out, open: true };
  let open = false;
  for (const pr of o.properties) {
    if (pr.type === 'SpreadElement') { open = true; continue; }
    const key = pr.key && (pr.key.type === 'Identifier' ? pr.key.name : isStr(pr.key) ? strValue(pr.key) : null);
    if (!key) { open = true; continue; }
    let fn = pr.type === 'ObjectMethod' ? pr : isFn(pr.value) ? pr.value : null;
    if (!fn && pr.value && pr.value.type === 'ArrayExpression' && isFn(pr.value.elements[0])) fn = pr.value.elements[0];
    out.push({ key, fn, node: pr });
  }
  return { fixtures: out, open };
}

/** Fixture kinds from an extend call's type argument (`extend<{ ctx2: BrowserContext }>`). */
export function typedFixtureKinds(call, typeDecls) {
  const out = new Map();
  const tp = call.typeParameters || call.typeArguments;
  if (!tp || !tp.params[0]) return out;
  const t = tp.params[0];
  const members = t.type === 'TSTypeLiteral' ? t.members : t.type === 'TSTypeReference' && t.typeName.type === 'Identifier' ? typeDecls.get(t.typeName.name) : null;
  for (const m of members || []) {
    if (m.type !== 'TSPropertySignature' || !m.key) continue;
    const k = annotationKind(m);
    if (k) out.set(m.key.name || m.key.value, k);
  }
  return out;
}

/** Interface and type-literal declarations of a file, by name. */
export function typeDeclarations(ast) {
  const out = new Map();
  for (const st of ast.program.body) {
    const d = st.type === 'ExportNamedDeclaration' ? st.declaration : st;
    if (d && d.type === 'TSInterfaceDeclaration') out.set(d.id.name, d.body.body);
    if (d && d.type === 'TSTypeAliasDeclaration' && d.typeAnnotation.type === 'TSTypeLiteral') out.set(d.id.name, d.typeAnnotation.members);
  }
  return out;
}

export const isDriverKind = (k) => DRIVER_KINDS.has(k);
export const isFrameworkKind = (k) => FRAMEWORK_KINDS.has(k);
export { isFn };
