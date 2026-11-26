// Family A: framework surface (test-baseline.md §Family A). TB-A6 (repository names resolve) waits for
// the definition fix; TB-A8 is judgment.
import {
  isFn, isMember, isCall, propName, memberChain, unwrap, rootIdent, isStr, strValue, anyNode, typeName,
} from '../ast.mjs';
import { LOCATOR_CTORS, LOCATOR_CHAIN, DRIVER_KINDS, FRAMEWORK_KINDS, reachKind, classifyCall, testChain } from '../bindings.mjs';
import { blockAbove } from '../waivers.mjs';
import { shippedVersions, readSnapshot } from '../surface.mjs';

const PKG = '@civitas-cerebrum/element-interactions';
const EVAL = new Set(['evaluate', 'evaluateHandle', '$eval', '$$eval', 'addInitScript', 'addStyleTag', 'exposeFunction', 'exposeBinding']);
const ACCESSORS = new Set(['context', 'mainFrame', 'frames']);
const SLEEPS = new Set(['waitForTimeout', 'pause']);
const WEB_MATCHERS = new Set(['toBeVisible', 'toBeHidden', 'toBeEnabled', 'toBeDisabled', 'toBeChecked', 'toBeEditable', 'toBeFocused', 'toBeInViewport', 'toBeAttached', 'toBeEmpty', 'toHaveText', 'toHaveValue', 'toHaveValues', 'toHaveCount', 'toHaveAttribute', 'toHaveClass', 'toHaveCSS', 'toHaveId', 'toHaveRole', 'toHaveURL', 'toHaveTitle', 'toHaveScreenshot', 'toHaveAccessibleName', 'toContainText', 'toMatchAriaSnapshot', 'toHaveJSProperty', 'toHaveAccessibleDescription', 'toHaveAccessibleErrorMessage', 'toContainClass']);
const URL_STEPS = /^(navigateTo|waitForUrl|waitForResponse|verifyUrlContains|expectNoRequest|openDeepLink|api[A-Z]\w*|request[A-Z]\w*)$/;
const PW_SOURCE = /^(?:@playwright\/test(?:\/.*)?|playwright(?:-core)?(?:\/.*)?)$/;
// A selector shape, anchored at the start: an XPath, an engine prefix, `#id`, `.class`, `[attr]`, `tag[`,
// `tag.class`, `tag#id`, `tag:pseudo`, `*`, `tag > tag`, or a Playwright chain (`… >> …`).
const SELECTOR_RE = /^\s*(?:\/\/|\(\/\/|(?:xpath|css|text|id|data-testid|internal):|#[A-Za-z_][\w-]*|\.[A-Za-z_][\w-]*|\[[\w-]+(?:\s*[~|^$*]?=|\])|[a-z][a-z0-9]*(?:\[|[.#][A-Za-z_]|:[a-z])|\*|[a-z][a-z0-9]*\s*>\s*[a-z.#[*]|\S+\s*>>\s*\S)/;
const looksSelector = (s) => typeof s === 'string' && s.length > 0 && SELECTOR_RE.test(s) && !/^https?:/.test(s) && !/^\/[\w-]*(\/|$)/.test(s.trim());
const NAME_PARAM = /^(?:elementName|pageName)$/;
const FRAMEWORK_FIXTURES = ['steps', 'repo', 'interactions', 'contextStore'];
// Driver properties that are objects, not methods: reading them is not taking a method off the binding.
const DRIVER_PROPERTIES = new Set(['keyboard', 'mouse', 'touchscreen', 'request', 'clock', 'coverage', 'accessibility', 'tracing']);
const BIND_FORMS = new Set(['call', 'apply', 'bind']);
// Lifecycle of a page or context a fixture owns: closing it, checking whether it is closed.
const FIXTURE_LIFECYCLE = new Set(['close', 'isClosed']);
const DRIVER_FACTORIES = new Set(['chromium', 'firefox', 'webkit', 'request', 'selectors', '_electron', '_android']);
const PW_OPTION_FIXTURES = ['acceptDownloads', 'baseURL', 'bypassCSP', 'colorScheme', 'clientCertificates', 'deviceScaleFactor', 'extraHTTPHeaders', 'geolocation', 'hasTouch', 'httpCredentials', 'ignoreHTTPSErrors', 'isMobile', 'javaScriptEnabled', 'locale', 'offline', 'permissions', 'proxy', 'screenshot', 'serviceWorkers', 'storageState', 'testIdAttribute', 'timezoneId', 'trace', 'userAgent', 'video', 'viewport', 'browserName', 'defaultBrowserType', 'headless', 'channel', 'launchOptions', 'connectOptions', 'contextOptions', 'navigationTimeout', 'actionTimeout'];
const PW_TEST_FIXTURES = ['page', 'context', 'browser', 'request', 'playwright', ...PW_OPTION_FIXTURES];
const A9_ALLOWED = new Set([...FRAMEWORK_FIXTURES, 'page', ...PW_OPTION_FIXTURES]);
const DECLARED_BUILTIN = new Set([...FRAMEWORK_FIXTURES, ...PW_TEST_FIXTURES]);
const REFLECT_OBJECT = /^Object\.(values|entries|keys|getOwnPropertyDescriptors?|getPrototypeOf|assign)$/;
const MUTATION_VAR = /^E2E_MUTATION_(CSS|INIT)$/;

const doRaw = (target) => `Replace the raw call with steps.${target}(…), addressing elements by their page-repository names.`;
const DO_NO_EQUIV = 'There is no known Steps equivalent: move the call into a verb or fixture and ask for the method to be added to the no-equivalent table (an Achilles release) or for a framework-gap row (the person decides); until then it stays a finding.';

export const RULES = [
  { id: 'TB-A1', title: 'raw locator on a driver binding', severity: 'blocking', appliesTo: ['spec'], do: 'Address the element by its page-repository name through steps.* (or the escape hatch of a framework-gap row with a waiver).' },
  { id: 'TB-A2', title: 'raw call on a driver binding', severity: 'blocking', appliesTo: ['spec'], do: DO_NO_EQUIV },
  { id: 'TB-A2b', title: 'raw call with no Steps equivalent in a spec', severity: 'advisory', appliesTo: ['spec'], do: 'Move the call into a verb or fixture that cites its register row (`// framework-gap: FG-<n>` directly above it).' },
  { id: 'TB-A3', title: 'web-first assertion on a page, locator or response', severity: 'blocking', appliesTo: ['spec'], do: 'Assert through steps.verify* or steps.expect(…), or assert on plain data read through the Steps API.' },
  { id: 'TB-A4', title: 'page scripting through a driver binding', severity: 'blocking', appliesTo: ['spec'], do: 'Use steps.evaluateScript, steps.getWindowProperty or the steps storage reads instead of scripting the page.' },
  { id: 'TB-A5', title: 'inline selector', severity: 'blocking', appliesTo: ['spec', 'support'], waivable: false, do: 'Add the element to the page repository and pass its name; never a selector string in durable test code.' },
  { id: 'TB-A7', title: 'value import from a Playwright package in a spec', severity: 'blocking', appliesTo: ['spec'], do: "Import test and expect from the project's fixtures module; keep only `import type` from Playwright." },
  { id: 'TB-A9', title: 'fixture outside the framework, project and option fixtures', severity: 'advisory', appliesTo: ['spec'], do: 'Use a project fixture that owns its teardown, a verb, or a framework-gap citation instead of the raw fixture.' },
  { id: 'TB-A10', title: 'Steps method or fixture that does not exist', severity: 'blocking', appliesTo: ['spec', 'support'], do: 'Use a public method of the installed CommonSteps surface (api-reference.md), or declare the fixture with extend.' },
  { id: 'TB-A11', title: 'driver binding handed out of the spec', severity: 'blocking', appliesTo: ['spec'], do: 'Pass steps (plus data) to verbs; a capability that needs the page is a project fixture, not a spec argument.' },
  { id: 'TB-A12', title: 'raw framework call in a support module outside the wiring shapes', severity: 'blocking', appliesTo: ['support'], do: 'Drive the UI through steps.* in verbs; raw calls belong only in the wiring shapes (fixture lifecycle, cited route mocks, mutation hooks, API back-door helpers).' },
  { id: 'TB-A13', title: 'framework release too old for the Steps equivalent', severity: 'advisory', appliesTo: ['spec'], waivable: false, do: 'Upgrade the framework first, then use the Steps method.' },
  { id: 'TB-A14', title: 'reach-through to the driver behind a framework object', severity: 'blocking', appliesTo: ['spec', 'support'], do: 'Use the public Steps, repository and interactions methods; never the driver behind them.' },
];

/** The equivalence table entry for a raw method on a receiver kind, or null. */
function equivalenceOf(eq, kind, method, call) {
  if (kind === 'request' && eq.http[method]) return { cat: 'http', targets: eq.http[method].targets };
  if (kind === 'request') return { cat: 'unlisted' };
  const e = eq.methods[method];
  if (!e) return null;
  if (e.on && !e.on.includes(kind)) return null;
  if (e.args) {
    const a = call.arguments[0];
    if (!isStr(a) || !e.args.includes(strValue(a))) return null;
  }
  return { cat: 'equiv', targets: e.targets };
}

function noEquivalentOf(eq, kind, method, call) {
  for (const e of eq.noEquivalent) {
    if (!e.on.includes(kind) || !e.methods.includes(method)) continue;
    if (e.args) {
      const a = call.arguments[0];
      if (!isStr(a) || !e.args.includes(strValue(a))) continue;
    }
    return e;
  }
  return null;
}

/** Classifies a call on a driver binding: { cat, kind, method, targets?, row?, mutation? } or null. */
export function classifyRaw(call, ctx) {
  let callee = unwrap(call.callee);
  if (callee && callee.type === 'SequenceExpression') callee = unwrap(callee.expressions.at(-1));
  if (!isMember(callee)) return null;
  // `page.goto.call(page, …)`, `.apply(page, […])`, `.bind(page)`: a raw call of the method taken off
  if (BIND_FORMS.has(propName(callee) || '') && isMember(unwrap(callee.object)) && DRIVER_KINDS.has(ctx.kind(unwrap(callee.object).object))) {
    const m = propName(callee);
    const args = m === 'call' ? call.arguments.slice(1) : m === 'apply' && call.arguments[1] && call.arguments[1].type === 'ArrayExpression' ? call.arguments[1].elements : [];
    const c = classifyRaw({ ...call, callee: unwrap(callee.object), arguments: args }, ctx);
    return c ? { ...c, via: m } : null;
  }
  const kind = ctx.kind(callee.object);
  if (!DRIVER_KINDS.has(kind)) return null;
  const eq = ctx.project.equivalents;
  const method = propName(callee);
  if (method === null) return { cat: 'computed', kind, method: '[computed]' };
  if (LOCATOR_CTORS.has(method) && kind !== 'context' && kind !== 'browser' && kind !== 'request' && kind !== 'input') return { cat: 'locator', kind, method };
  if (LOCATOR_CHAIN.has(method) && kind === 'locator') return { cat: 'chain', kind, method };
  if (ACCESSORS.has(method)) return { cat: 'accessor', kind, method };
  if (SLEEPS.has(method)) return { cat: 'sleep', kind, method };
  if (EVAL.has(method)) return { cat: 'eval', kind, method, targets: eq.evaluate.methods.includes(method) ? eq.evaluate.targets : null, mutation: method === 'addStyleTag' || method === 'addInitScript' };
  const ne = noEquivalentOf(eq, kind, method, call);
  if (ne) return { cat: 'noeq', kind, method, row: ne.row };
  if (method === 'waitForEvent') {
    // popup / page: steps.switchToNewTab (below); another literal event is an event capture with no Steps
    // equivalent (A2b, like on(...)); a non-literal event cannot be classified (A2, no known equivalent).
    const a = call.arguments[0];
    if (!isStr(a)) return { cat: 'unlisted', kind, method };
    if (!/^(popup|page)$/.test(strValue(a))) return { cat: 'noeq', kind, method, row: null };
  }
  const e = equivalenceOf(eq, kind, method, call);
  if (e) return { ...e, kind, method };
  return { cat: 'unlisted', kind, method };
}

/** True when the receiver of `call` is itself a raw locator chain (a chain reports once). */
function receiverIsLocatorChain(call, ctx) {
  let r = unwrap(unwrap(call.callee).object);
  while (r && r.type === 'AwaitExpression') r = unwrap(r.argument);
  while (isCall(r)) {
    const c = classifyRaw(r, ctx);
    if (!c) return false;
    if (c.cat === 'locator') return true;
    if (c.cat !== 'chain') return false;
    r = unwrap(unwrap(r.callee).object);
  }
  return false;
}

const releaseCache = new Map();
/** The first shipped release whose surface has `method`, or null. */
function firstRelease(method) {
  if (releaseCache.has(method)) return releaseCache.get(method);
  let v = null;
  for (const r of shippedVersions()) { try { if (readSnapshot(r).methods.includes(method)) { v = r; break; } } catch { /* unreadable snapshot */ } }
  releaseCache.set(method, v);
  return v;
}

/**
 * The Steps read a page script certainly is: `localStorage.getItem(k)` / `sessionStorage.getItem(k)`,
 * `(el) => el.getAttribute(a)` on an element, `() => window.<name>`. Null for anything else.
 */
function scriptRead(call, c) {
  const fn = call.arguments.find(isFn);
  if (!fn) return null;
  let body = fn.body;
  if (body.type === 'BlockStatement') {
    if (body.body.length !== 1 || body.body[0].type !== 'ReturnStatement' || !body.body[0].argument) return null;
    body = body.body[0].argument;
  }
  body = unwrap(body);
  if (isCall(body) && body.arguments.length === 1 && isStr(body.arguments[0])) {
    const ch = (memberChain(body.callee) || []).join('.').replace(/^window\./, '');
    if (ch === 'localStorage.getItem') return 'getLocalStorage';
    if (ch === 'sessionStorage.getItem') return 'getSessionStorage';
    const p0 = fn.params[0];
    if (c.kind === 'locator' && p0 && p0.type === 'Identifier' && isMember(body.callee) && propName(body.callee) === 'getAttribute' && unwrap(body.callee.object).type === 'Identifier' && unwrap(body.callee.object).name === p0.name) return 'getAttribute';
    return null;
  }
  if (isMember(body) && !body.computed && fn.params.length === 0) {
    const ch = memberChain(body);
    if (ch && ch.length === 2 && ch[0] === 'window') return 'getWindowProperty';
  }
  return null;
}

/** The first target present in the installed surface, else the earliest release that has one. */
function availability(targets, surface) {
  const have = targets.find((t) => surface.methods.has(t.method));
  if (have) return { have: have.method };
  const later = [...targets].sort((a, b) => (a.since < b.since ? -1 : 1));
  return { have: null, since: later[0].since, method: later[0].method };
}

const stmtOf = (stack) => { for (let i = stack.length - 1; i >= 0; i--) if (/Statement$|Declaration$/.test(stack[i].type) && stack[i].type !== 'BlockStatement') return stack[i]; return null; };

/** In the fixtures module, inside `if (process.env.E2E_MUTATION_CSS | _INIT)` or `process.env.… && …`. */
function mutationGated(stack) {
  const gate = (t) => anyNode(t, (x) => isMember(x) && MUTATION_VAR.test(propName(x) || '') && (memberChain(x.object) || []).join('.') === 'process.env');
  for (let i = stack.length - 2; i >= 0; i--) {
    const a = stack[i];
    if (a.type === 'IfStatement' && stack[i + 1] !== a.test && gate(a.test)) return true;
    if (a.type === 'LogicalExpression' && a.operator === '&&' && stack[i + 1] === a.right && gate(a.left)) return true;
    if (isFn(a)) return false;
  }
  return false;
}

/** The nearest enclosing function on the stack. */
const enclosingFn = (stack) => { for (let i = stack.length - 1; i >= 0; i--) if (isFn(stack[i])) return stack[i]; return null; };

/** An API back-door helper: every driver call in the function is an HTTP call on a request binding. */
function backDoor(fn, ctx) {
  if (!fn) return false;
  let ok = true;
  anyNode(fn.body, (x) => {
    if (!ok || !isCall(x)) return false;
    const c = classifyRaw(x, ctx);
    if (c && !(c.kind === 'request' && (c.cat === 'http' || c.cat === 'unlisted' || c.cat === 'noeq')) && c.cat !== 'accessor') ok = false;
    return false;
  });
  return ok;
}

/** A literal inside a callback whose only consumer is `expect(cb).toThrow…` / `expect(cb).rejects…`. */
function inRefusalCallback(stack) {
  const refusal = (i) => {
    const names = [];
    for (let j = i - 1; j >= 0 && isMember(stack[j]); j--) names.push(propName(stack[j]));
    return names.some((n) => n === 'rejects' || /^toThrow/.test(n || ''));
  };
  for (let i = stack.length - 1; i > 0; i--) {
    const f = stack[i];
    const up = stack[i - 1];
    if (isCall(up) && up.callee.type === 'Identifier' && up.callee.name === 'expect' && up.arguments[0] === f && !isFn(f)) return refusal(i - 1);
    if (!isFn(f)) continue;
    const parent = stack[i - 1];
    if (isCall(parent) && parent.callee.type === 'Identifier' && parent.callee.name === 'expect' && parent.arguments[0] === f) return refusal(i - 1);
    if (parent.type === 'VariableDeclarator' && parent.init === f && parent.id.type === 'Identifier') {
      const name = parent.id.name;
      let container = null;
      for (let j = i - 2; j >= 0; j--) if (isFn(stack[j]) || stack[j].type === 'Program') { container = stack[j]; break; }
      if (!container) return false;
      let uses = 0, refusals = 0;
      const walk = (n, chain) => {
        if (!n || typeof n.type !== 'string') return;
        if (n.type === 'Identifier' && n.name === name && n !== parent.id) {
          uses++;
          const p = chain.at(-1);
          if (p && isCall(p) && p.callee.type === 'Identifier' && p.callee.name === 'expect' && p.arguments[0] === n) {
            const names = [];
            for (let k = chain.length - 2; k >= 0 && isMember(chain[k]); k--) names.push(propName(chain[k]));
            if (names.some((x) => x === 'rejects' || /^toThrow/.test(x || ''))) refusals++;
          }
        }
        for (const k of Object.keys(n)) {
          if (k === 'loc' || k.endsWith('Comments') || (n.type === 'MemberExpression' && k === 'property' && !n.computed) || (n.type === 'ObjectProperty' && k === 'key' && !n.computed)) continue;
          const v = n[k];
          if (Array.isArray(v)) for (const c of v) walk(c, [...chain, n]);
          else if (v && typeof v.type === 'string') walk(v, [...chain, n]);
        }
      };
      walk(container, []);
      return uses > 0 && uses === refusals;
    }
    return false;
  }
  return false;
}

/** The locator call sits in `interactions.<part>.<method>(new WebElement(<locator>))`, the escape-hatch form. */
function escapeHatch(stack, ctx) {
  for (let i = stack.length - 2; i >= 1; i--) {
    const a = stack[i];
    if (a.type === 'NewExpression' && a.callee.type === 'Identifier' && a.callee.name === 'WebElement') {
      const p = stack[i - 1];
      return isCall(p) && isMember(unwrap(p.callee)) && ctx.kind(unwrap(p.callee).object) === 'interactions-part';
    }
    if (isFn(a) || /Statement$/.test(a.type)) return false;
  }
  return false;
}

const literalArg = (a) => a && (isStr(a) || a.type === 'TemplateLiteral' || a.type === 'RegExpLiteral');
/** The source text of a node, whitespace collapsed, at most 60 characters. */
const src = (ctx, node) => { const t = ctx.file.text.slice(node.start, node.end).replace(/\s*(\??\.)\s*/g, '$1').replace(/\s+/g, ' '); return t.length > 60 ? `${t.slice(0, 57)}...` : t; };
const display = (c, ctx, n) => src(ctx, unwrap(n.callee));

export function visitors(project) {
  const surface = project.surface;
  const a13 = [];
  const forbidden = (() => {
    const r = project.rules?.rules?.['selectors.no-inline'];
    return r && Array.isArray(r.forbidden) ? { forbidden: r.forbidden.filter((x) => typeof x === 'string' && x), allowed: Array.isArray(r.allowed) ? r.allowed.filter((x) => typeof x === 'string') : [] } : null;
  })();

  const NONE = new Set();
  const privatesOf = (kind) => surface.privates[kind] || NONE;

  function rawCall(n, ctx) {
    const c = classifyRaw(n, ctx);
    if (!c) return;
    const { file } = ctx;
    const stmt = stmtOf(ctx.stack);
    if (c.cat === 'noeq') (file.facts.noEq ||= []).push({ stmtLine: stmt ? stmt.loc.start.line : n.loc.start.line, row: c.row, method: c.method, kind: c.kind });
    if (c.cat === 'accessor' || c.cat === 'chain' || c.cat === 'sleep') return;
    if (c.cat !== 'noeq' && receiverIsLocatorChain(n, ctx)) return;

    if (file.kind === 'support') {
      if (ctx.inRoute && ctx.inRoute.cited) return;
      if (c.cat === 'noeq') {
        const cited = stmt && file.citations.some((x) => x.row && blockAbove(stmt.loc.start.line, file.commentLines).includes(x.line));
        if (!cited) ctx.report('TB-A2b', n, { severity: 'advisory', message: `\`${display(c, ctx, n)}\` has no Steps equivalent${c.row ? ` (register row ${c.row})` : ''} and no \`// framework-gap:\` citation above it`, do: c.row ? `Cite the row directly above the call: \`// framework-gap: ${c.row}\`.` : 'Cite the register row that covers the call directly above it (`// framework-gap: FG-<n>`); a call no row covers needs a row the person decides on.', data: { row: c.row, kind: c.kind, method: c.method } });
        return;
      }
      if (c.cat === 'eval' && c.mutation && file.isFixturesModule && mutationGated(ctx.stack)) return;
      const http = c.kind === 'request';
      const fixture = ctx.region === 'fixture';
      if (http) {
        if (fixture || backDoor(enclosingFn(ctx.stack), ctx)) return;
        ctx.report('TB-A12', n, { severity: 'advisory', message: `HTTP raw call \`${display(c, ctx, n)}\` in a function that also drives the UI (advisory: the back-door recogniser is unmeasured)`, do: 'Keep HTTP setup in an API back-door helper that drives no UI, or use steps.request* / steps.api*.' });
        return;
      }
      // In a fixture body only UI driving blocks: locators, page scripting, raw calls with a Steps equivalent.
      if (fixture && (c.cat === 'unlisted' || FIXTURE_LIFECYCLE.has(c.method))) return;
      if (c.cat === 'unlisted') {
        ctx.report('TB-A12', n, { severity: 'advisory', message: `\`${display(c, ctx, n)}\` (no known Steps equivalent) in a support module outside the wiring shapes (advisory)`, do: DO_NO_EQUIV, data: { kind: c.kind, method: c.method } });
        return;
      }
      const what = c.cat === 'locator' ? 'raw locator' : c.cat === 'eval' ? 'page scripting' : 'raw call';
      const eqv = c.targets ? availability(c.targets, surface) : null;
      ctx.report('TB-A12', n, { message: `${what} \`${display(c, ctx, n)}\` in a support module outside the wiring shapes`, do: eqv && eqv.have ? `${doRaw(eqv.have)} Verbs drive the UI through steps.` : RULES.find((r) => r.id === 'TB-A12').do, data: { kind: c.kind, method: c.method } });
      return;
    }

    // spec
    if (c.cat === 'locator') { ctx.report('TB-A1', n, { message: `raw locator \`${display(c, ctx, n)}\` on a driver binding`, data: { kind: c.kind, method: c.method, hatch: escapeHatch(ctx.stack, ctx) } }); return; }
    if (c.cat === 'noeq') {
      const cited = file.citations.some((x) => x.row === c.row && stmt && x.line < stmt.loc.start.line && x.line >= stmt.loc.start.line - 3);
      ctx.report('TB-A2b', n, { message: `\`${display(c, ctx, n)}\` has no Steps equivalent${c.row ? ` (register row ${c.row})` : ''}${cited ? '; cited' : ''}: in a spec it belongs in a verb or fixture`, data: { row: c.row } });
      return;
    }
    if (c.cat === 'eval') {
      if (c.targets) {
        // Name a narrower read only when the script is certainly that read; otherwise steps.evaluateScript.
        const want = scriptRead(n, c) || 'evaluateScript';
        if (!surface.methods.has(want)) { versionGap(n, ctx, c, { since: firstRelease(want) || c.targets.find((t) => t.method === want)?.since || '?', method: want }); return; }
        ctx.report('TB-A4', n, { message: `page scripting \`${display(c, ctx, n)}\`; the installed release has steps.${want}`, do: `Use steps.${want}${want === 'evaluateScript' ? ' for the script' : ', which reads the same value'}.` });
        return;
      }
      ctx.report('TB-A4', n, { message: `page scripting \`${display(c, ctx, n)}\` on a driver binding` });
      return;
    }
    if (c.cat === 'equiv' || c.cat === 'http') {
      const av = availability(c.targets, surface);
      if (!av.have) { versionGap(n, ctx, c, av); return; }
      ctx.report('TB-A2', n, { message: `raw call \`${display(c, ctx, n)}\` has a Steps equivalent: steps.${av.have}`, do: doRaw(av.have), data: { kind: c.kind, method: c.method, equivalent: av.have } });
      return;
    }
    if (c.cat === 'computed') { ctx.report('TB-A2', n, { message: 'computed member call on a driver binding (no known Steps equivalent)', data: { kind: c.kind, method: c.method } }); return; }
    ctx.report('TB-A2', n, { message: `\`${display(c, ctx, n)}\`: no known Steps equivalent`, data: { kind: c.kind, method: c.method } });
  }

  function versionGap(n, ctx, c, av) {
    const msg = `upgrade ${PKG} to ≥ ${av.since}, then use steps.${av.method} instead of \`${display(c, ctx, n)}\` (installed ${surface.version})`;
    a13.push({ since: av.since, file: ctx.file.rel, line: n.loc.start.line });
    ctx.report('TB-A13', n, { message: msg, do: `Upgrade ${PKG} to ≥ ${av.since} as the first unit of work, then use steps.${av.method}.`, data: { upgradeTo: av.since, method: av.method } });
  }

  function webFirst(n, ctx) {
    const callee = unwrap(n.callee);
    if (!isMember(callee)) return;
    const matcher = propName(callee);
    if (!WEB_MATCHERS.has(matcher) && matcher !== 'toBeOK') return;
    let b = unwrap(callee.object);
    while (isMember(b)) b = unwrap(b.object);
    if (!isCall(b)) return;
    const ch = memberChain(b.callee) || [];
    if (ch[0] !== 'expect' || ch.length > 2 || (ch[1] && ch[1] !== 'soft')) return;
    const okToBe = matcher === 'toBeOK';
    if (ctx.file.kind === 'support') {
      if (ctx.inRoute && ctx.inRoute.cited) return;
      ctx.report('TB-A12', n, { severity: okToBe ? 'advisory' : 'blocking', message: `web-first assertion \`${matcher}\` in a support module`, do: 'Assert through steps.verify* or steps.expect(…) in the verb, or leave the outcome assertion to the test.' });
      return;
    }
    ctx.report('TB-A3', n, { severity: okToBe ? 'advisory' : 'blocking', message: `web-first assertion \`${matcher}\`${okToBe ? ' (advisory: unmeasured)' : ''}` });
  }

  function selectors(n, ctx) {
    const callee = unwrap(n.callee);
    if (!isMember(callee)) return;
    const p = propName(callee);
    const report = (node, message) => { if (!inRefusalCallback(ctx.stack)) ctx.report('TB-A5', node, { message }); };
    const k = ctx.kind(callee.object);
    const a0 = n.arguments[0];
    if (DRIVER_KINDS.has(k) && (LOCATOR_CTORS.has(p) || p === 'waitForSelector') && literalArg(a0)) return report(a0, `selector literal in \`${src(ctx, callee)}(…)\``);
    if (p === 'findBySelector' && literalArg(a0)) return report(a0, 'selector literal in `findBySelector(…)`');
    if (k === 'steps' && p && !URL_STEPS.test(p)) {
      const params = surface.params && surface.params[p];
      const positions = params ? params.map((x, i) => (NAME_PARAM.test(x) ? i : -1)).filter((i) => i >= 0) : [];
      for (const i of positions) {
        const a = n.arguments[i];
        if (a && isStr(a) && looksSelector(strValue(a))) return report(a, `selector-shaped name "${strValue(a)}" passed to steps.${p}`);
      }
    }
  }

  function stepsMethod(n, ctx) {
    const callee = unwrap(n.callee);
    if (!isMember(callee) || callee.computed) return;
    if (ctx.kind(callee.object) !== 'steps') return;
    const p = propName(callee);
    if (!p || surface.methods.has(p) || surface.properties.has(p)) return;
    ctx.report('TB-A10', n, { message: `steps.${p} is not a public method of ${PKG} ${surface.version} (${surface.source})` });
  }

  function leaks(n, ctx) {
    if (ctx.file.kind !== 'spec') return;
    const callee = unwrap(n.callee);
    const ch = memberChain(callee) || [];
    const cname = ch.join('.');
    if (n.type === 'NewExpression' && /^(WebElement|ElementInteractions|Steps|ElementRepository)$/.test(cname)) return;
    if (/^(expect|expect\.soft|expect\.poll|use)$/.test(cname)) return;
    const tc = testChain(callee, ctx.file.testNames);
    if (tc && tc.length === 2 && tc[1] === 'step') return;
    if (isCall(n) && classifyCall(n, ctx.file.testNames)) return;
    const root = rootIdent(callee);
    const ownerKind = root ? ctx.kind(root) : null;
    if (DRIVER_KINDS.has(ownerKind) || FRAMEWORK_KINDS.has(ownerKind)) return;
    if (isMember(callee) && (FRAMEWORK_KINDS.has(ctx.kind(callee.object)) || DRIVER_KINDS.has(ctx.kind(callee.object)))) return;
    const promiseCombinator = /^Promise\.(all|race|allSettled)$/.test(cname);
    if (promiseCombinator && n.arguments.every((a) => a.type !== 'ArrayExpression' || a.elements.every((e) => !e || isCall(unwrap(e)) || unwrap(e).type === 'AwaitExpression'))) return;
    const stored = ownerKind === 'contextStore';
    const promise = ch[0] === 'Promise';
    const direct = new Set(['page', 'frame', 'context', 'browser', 'request', 'locator']);
    const ext = (node, k, shape) => ctx.report('TB-A11', node, { severity: 'advisory', message: `${k} binding leaves the spec (${shape}) to \`${cname || 'a call'}\` (advisory: extended form, unmeasured)`, data: { shape } });
    const inspect = (a, shape) => {
      if (!a) return;
      if (a.type === 'SpreadElement') return inspect(a.argument, 'spread');
      const u = unwrap(a);
      if (u.type === 'ObjectExpression') { for (const pr of u.properties) inspect(pr.type === 'SpreadElement' ? pr.argument : pr.value, 'object'); return; }
      if (u.type === 'ArrayExpression') { for (const e of u.elements) inspect(e, 'array'); return; }
      if (isFn(u)) {
        let k2 = null;
        if (u.body.type !== 'BlockStatement') k2 = ctx.kind(u.body);
        else anyNode(u.body, (x) => { if (x.type === 'ReturnStatement' && x.argument) { const kk = ctx.kind(x.argument); if (DRIVER_KINDS.has(kk) || kk === 'element') k2 = kk; } return false; }, { intoFunctions: false });
        if (DRIVER_KINDS.has(k2) || k2 === 'element') ext(u, k2, 'closure');
        return;
      }
      const k = ctx.kind(u);
      if (typeof k === 'string' && (k.startsWith('list:') || k.startsWith('obj:'))) {
        const held = k.startsWith('list:') ? [k.slice(5)] : Object.values(JSON.parse(k.slice(4)));
        const d = held.find((x) => DRIVER_KINDS.has(x) || x === 'element');
        if (d) ext(u, d, 'container');
        return;
      }
      if (!(DRIVER_KINDS.has(k) || k === 'element')) return;
      if (shape === 'direct' && direct.has(k) && !stored && !promise) ctx.report('TB-A11', u, { message: `${k} binding passed to \`${cname || 'a call'}\`` });
      else ext(u, k, stored ? 'stored in contextStore' : promise ? 'promise' : k === 'input' ? 'input' : k === 'element' ? 'element' : shape);
    };
    if (isMember(callee) && propName(callee) === 'then') {
      const o = unwrap(callee.object);
      const recv = isCall(o) && (memberChain(o.callee) || []).join('.') === 'Promise.resolve' ? ctx.kind(o.arguments[0]) : ctx.kind(o);
      if ((DRIVER_KINDS.has(recv) || recv === 'element') && n.arguments[0] && !isFn(n.arguments[0])) ctx.report('TB-A11', n.arguments[0], { severity: 'advisory', message: `${recv} binding handed to \`${src(ctx, n.arguments[0])}\` through .then (advisory: extended form, unmeasured)`, data: { shape: 'then' } });
      return;
    }
    for (const a of n.arguments) inspect(a, 'direct');
  }

  function reach(n, ctx) {
    const { file } = ctx;
    const k = ctx.kind(n.object);
    const p = propName(n);
    if (k === 'untyped') {
      if (file.kind === 'support' && p && (/^(page|driver|browser)$/.test(p) || (/^(context|_.*)$/.test(p) && usedAsSteps(n.object, ctx)))) ctx.report('TB-A14', n, { severity: 'advisory', message: `\`.${p}\` read on an untyped parameter used as a framework object (advisory: name-based, unmeasured)`, do: 'Type the parameter as Steps and use its public methods.' });
      return;
    }
    if (!FRAMEWORK_KINDS.has(k)) return;
    if (p === null) { ctx.report('TB-A14', n, { message: `computed member with a non-literal key on a ${k} binding` }); return; }
    const inFixtureWiring = file.isFixturesModule && ctx.region === 'fixture';
    if (reachKind(k, p)) {
      if (inFixtureWiring && k === 'repo' && p === 'driver') return;
      ctx.report('TB-A14', n, { message: `reach-through \`${src(ctx, n)}\` to the driver` });
      return;
    }
    if (p.startsWith('_') || privatesOf(k).has(p)) ctx.report('TB-A14', n, { message: `non-public member \`${src(ctx, n)}\`` });
  }

  /** The untyped receiver is used as a Steps object elsewhere in its function (calls a Steps method on it). */
  function usedAsSteps(id, ctx) {
    if (id.type !== 'Identifier') return false;
    const decl = ctx.scope.declaring(id.name);
    const fn = decl && decl.fn;
    if (!fn) return false;
    return anyNode(fn.body, (x) => isCall(x) && isMember(unwrap(x.callee)) && unwrap(unwrap(x.callee).object).type === 'Identifier' && unwrap(unwrap(x.callee).object).name === id.name && surface.methods.has(propName(unwrap(x.callee)) || ''));
  }

  /** A driver method read off its binding without being called there (`const go = page.goto`, `(0, page.goto)`, `Reflect.apply(page.goto, …)`). */
  function methodRead(n, ctx) {
    const k = ctx.kind(n.object);
    if (!DRIVER_KINDS.has(k)) return;
    const p = propName(n);
    if (p !== null && DRIVER_PROPERTIES.has(p)) return;
    let i = ctx.stack.length - 2;
    let child = n;
    while (i >= 0 && ctx.stack[i].type === 'ParenthesizedExpression') { child = ctx.stack[i]; i--; }
    const parent = ctx.stack[i];
    if (!parent) return;
    if (isCall(parent) && parent.callee === child) return;
    if (isMember(parent) && parent.object === child) return; // `page.goto.call(…)` is a call of goto; `page.keyboard.press` reads a property
    if (parent.type === 'SequenceExpression' && parent.expressions.at(-1) === child && isCall(ctx.stack[i - 1]) && ctx.stack[i - 1].callee === parent) return;
    if (parent.type === 'AssignmentExpression' && parent.left === child) return;
    if (isCall(parent) && (memberChain(unwrap(parent.callee)) || [])[0] === 'expect') return;
    const c = classifyRaw({ type: 'CallExpression', callee: n, arguments: [], loc: n.loc, start: n.start, end: n.end }, ctx);
    if (!c || c.cat === 'accessor' || c.cat === 'chain') return;
    extracted(n, c, ctx);
  }

  function extracted(node, c, ctx) {
    const what = `\`${c.kind}.${c.method}\` taken off the driver binding (a raw call by another route)`;
    if (ctx.file.kind === 'support') {
      if (c.cat === 'noeq' || (ctx.region === 'fixture' && (c.cat === 'unlisted' || c.kind === 'request'))) return;
      ctx.report('TB-A12', node, { severity: c.kind === 'request' || c.cat === 'unlisted' ? 'advisory' : 'blocking', message: what, data: { kind: c.kind, method: c.method } });
      return;
    }
    if (c.cat === 'noeq') return;
    ctx.report(c.cat === 'locator' ? 'TB-A1' : c.cat === 'eval' ? 'TB-A4' : 'TB-A2', node, { message: what, data: { kind: c.kind, method: c.method } });
  }

  function reflection(n, ctx) {
    const ch = memberChain(unwrap(n.callee)) || [];
    const name = ch.join('.');
    if (!(ch[0] === 'Reflect' && ch.length === 2) && !REFLECT_OBJECT.test(name)) return;
    const hit = n.arguments.find((a) => FRAMEWORK_KINDS.has(ctx.kind(a.type === 'SpreadElement' ? a.argument : a)));
    if (hit) ctx.report('TB-A14', n, { message: `\`${name}\` over a ${ctx.kind(hit)} binding` });
  }

  function typeEscape(n, ctx) {
    const t = n.typeAnnotation;
    const inner = unwrap(n.expression);
    if (t && t.type === 'TSAnyKeyword' && FRAMEWORK_KINDS.has(ctx.kind(inner))) { ctx.report('TB-A14', n, { message: `\`as any\` on a ${ctx.kind(inner)} binding` }); return; }
    const e = n.expression;
    if (e && (e.type === 'TSAsExpression' || e.type === 'TSTypeAssertion') && e.typeAnnotation.type === 'TSUnknownKeyword' && FRAMEWORK_KINDS.has(ctx.kind(e.expression))) ctx.report('TB-A14', n, { message: `\`as unknown as …\` on a ${ctx.kind(e.expression)} binding` });
  }

  return {
    fileStart(file) {
      const targets = new Set();
      for (const c of file.ast.comments || []) {
        if (!/@ts-(ignore|expect-error)/.test(c.value)) continue;
        const own = file.lines[c.loc.start.line - 1].slice(0, c.loc.start.column).trim() === '';
        let l = c.loc.end.line + (own ? 1 : 0);
        while (own && file.commentLines.has(l)) l++;
        targets.add(l);
      }
      file.facts.tsIgnoreLines = targets;
      file.facts.tsIgnoreReported = new Set();
    },
    ImportDeclaration(n, ctx) {
      if (ctx.file.kind !== 'spec' || !PW_SOURCE.test(n.source.value)) return;
      const typeOnly = n.importKind === 'type' || (n.specifiers.length > 0 && n.specifiers.every((s) => s.importKind === 'type'));
      if (!typeOnly) ctx.report('TB-A7', n, { message: `value import from ${n.source.value} in a spec` });
    },
    ExportNamedDeclaration(n, ctx) {
      if (!n.source || !PW_SOURCE.test(n.source.value) || n.exportKind === 'type') return;
      if (ctx.file.kind === 'spec') { ctx.report('TB-A7', n, { message: `re-export from ${n.source.value} in a spec` }); return; }
      const names = n.specifiers.filter((sp) => sp.exportKind !== 'type').map((sp) => (sp.type === 'ExportNamespaceSpecifier' ? '*' : sp.local.name || sp.local.value));
      const hit = names.filter((x) => x === '*' || DRIVER_FACTORIES.has(x));
      if (hit.length) ctx.report('TB-A12', n, { message: `a support module re-exports Playwright's driver factories (${hit.join(', ')}) from ${n.source.value}`, do: 'Re-export only test and expect from the fixtures module; drivers come from fixtures, never from an import.' });
    },
    ExportAllDeclaration(n, ctx) {
      if (!PW_SOURCE.test(n.source.value) || n.exportKind === 'type') return;
      if (ctx.file.kind === 'spec') ctx.report('TB-A7', n, { message: `re-export from ${n.source.value} in a spec` });
      else ctx.report('TB-A12', n, { message: `a support module re-exports everything of ${n.source.value}, driver factories included`, do: 'Re-export only test and expect from the fixtures module; drivers come from fixtures, never from an import.' });
    },
    ImportExpression(n, ctx) {
      if (ctx.file.kind === 'spec' && isStr(n.source) && PW_SOURCE.test(strValue(n.source))) ctx.report('TB-A7', n, { message: `dynamic import of ${strValue(n.source)} in a spec` });
    },
    CallExpression(n, ctx) {
      if (ctx.file.kind === 'spec' && ((n.callee.type === 'Identifier' && n.callee.name === 'require') || n.callee.type === 'Import') && isStr(n.arguments[0]) && PW_SOURCE.test(strValue(n.arguments[0]))) {
        ctx.report('TB-A7', n, { message: `${n.callee.type === 'Import' ? 'dynamic import' : 'require'} of ${strValue(n.arguments[0])} in a spec` });
      }
      rawCall(n, ctx);
      webFirst(n, ctx);
      selectors(n, ctx);
      stepsMethod(n, ctx);
      leaks(n, ctx);
      reflection(n, ctx);
      const cls = ctx.file.kind === 'spec' ? classifyCall(n, ctx.file.testNames) : null;
      if (cls && cls.type === 'test') fixturesRequested(cls.fn, ctx, ctx.file.testsByNode.get(n) || null);
    },
    OptionalCallExpression(n, ctx) { rawCall(n, ctx); stepsMethod(n, ctx); leaks(n, ctx); },
    NewExpression(n, ctx) { leaks(n, ctx); },
    MemberExpression(n, ctx) {
      reach(n, ctx);
      methodRead(n, ctx);
      const lines = ctx.file.facts.tsIgnoreLines;
      if (lines && lines.has(n.loc.start.line) && FRAMEWORK_KINDS.has(ctx.kind(n.object)) && !ctx.file.facts.tsIgnoreReported.has(n.loc.start.line)) {
        ctx.file.facts.tsIgnoreReported.add(n.loc.start.line);
        ctx.report('TB-A14', n, { message: `@ts-ignore / @ts-expect-error over a member of a ${ctx.kind(n.object)} binding` });
      }
    },
    OptionalMemberExpression(n, ctx) { reach(n, ctx); },
    TSAsExpression(n, ctx) { typeEscape(n, ctx); },
    TSTypeAssertion(n, ctx) { typeEscape(n, ctx); },
    SpreadElement(n, ctx) {
      const k = ctx.kind(n.argument);
      if (FRAMEWORK_KINDS.has(k)) ctx.report('TB-A14', n, { message: `spread copy of a ${k} binding` });
    },
    VariableDeclarator(n, ctx) {
      if (n.id.type === 'Identifier' && n.init && typeName(n.id) === 'any' && FRAMEWORK_KINDS.has(ctx.kind(n.init))) ctx.report('TB-A14', n, { message: `\`any\`-typed alias of a ${ctx.kind(n.init)} binding` });
      if (n.id.type !== 'ObjectPattern' || !n.init) return;
      const k = ctx.kind(n.init);
      for (const pr of n.id.properties) {
        if (pr.type !== 'ObjectProperty') continue;
        const key = pr.key.type === 'Identifier' ? pr.key.name : isStr(pr.key) ? strValue(pr.key) : null;
        if (!key) continue;
        if (FRAMEWORK_KINDS.has(k) && (reachKind(k, key) || key.startsWith('_') || privatesOf(k).has(key))) {
          if (!(ctx.file.isFixturesModule && ctx.region === 'fixture' && k === 'repo' && key === 'driver')) ctx.report('TB-A14', pr, { message: `\`${key}\` destructured out of a ${k} binding` });
        }
        if (DRIVER_KINDS.has(k) && !DRIVER_PROPERTIES.has(key)) {
          const c = classifyRaw({ type: 'CallExpression', callee: { type: 'MemberExpression', object: n.init, property: { type: 'Identifier', name: key }, computed: false }, arguments: [] }, ctx);
          if (c && c.cat !== 'accessor' && c.cat !== 'chain') extracted(pr, c, ctx);
        }
      }
    },
    ReturnStatement(n, ctx) {
      if (ctx.file.kind !== 'spec' || !n.argument || !['test', 'hook', 'helper', 'describe'].includes(ctx.region)) return;
      const k = ctx.kind(n.argument);
      if (DRIVER_KINDS.has(k) || k === 'element') ctx.report('TB-A11', n, { severity: 'advisory', message: `${k} binding returned (advisory: extended form, unmeasured)`, data: { shape: 'returned' } });
    },
    AssignmentExpression(n, ctx) {
      if (ctx.file.kind !== 'spec') return;
      const k = ctx.kind(n.right);
      if (!(DRIVER_KINDS.has(k) || k === 'element')) return;
      if (isMember(n.left)) ctx.report('TB-A11', n, { severity: 'advisory', message: `${k} binding stored on an object (advisory: extended form, unmeasured)`, data: { shape: 'stored' } });
      else if (n.left.type === 'Identifier' && ctx.region !== 'module') {
        const s = ctx.scope.declaring(n.left.name);
        if (s && s.isModule && !(ctx.region === 'hook')) ctx.report('TB-A11', n, { severity: 'advisory', message: `${k} binding stored in a module variable (advisory: extended form, unmeasured)`, data: { shape: 'module-variable' } });
      }
    },
    StringLiteral(n, ctx) { forbiddenString(n, ctx); },
    TemplateLiteral(n, ctx) { forbiddenString(n, ctx); },
    projectEnd(p) {
      if (!a13.length) return;
      const top = [...a13].sort((a, b) => (a.since < b.since ? 1 : -1))[0].since;
      p.projectFindings.push({ rule: 'TB-A13', severity: 'advisory', message: `upgrade ${PKG} to ≥ ${top} (${a13.length} call site${a13.length === 1 ? '' : 's'}); installed ${surface.version}`, do: `Upgrade ${PKG} to ≥ ${top} as the first unit of work the next time a workflow touches the suite, then use the Steps methods.`, why: 'skills/achilles-orchestrator/references/test-baseline.md#tb-a13' });
    },
  };

  function forbiddenString(n, ctx) {
    if (!forbidden || !forbidden.forbidden.length) return;
    const parent = ctx.stack.at(-2);
    if (parent && (parent.type === 'ImportDeclaration' || parent.type === 'ExportNamedDeclaration' || parent.type === 'ExportAllDeclaration' || parent.type === 'TSLiteralType')) return;
    let s = n.type === 'StringLiteral' ? n.value : n.quasis.map((q) => q.value.cooked).join('');
    for (const a of forbidden.allowed) s = s.split(a).join('');
    const hit = forbidden.forbidden.find((f) => s.includes(f));
    if (hit) ctx.report('TB-A5', n, { severity: 'advisory', message: `contains \`${hit}\` from selectors.no-inline.forbidden (advisory: unmeasured)` });
  }

  function fixturesRequested(fn, ctx, test) {
    const p0 = fn.params[0];
    if (!p0 || p0.type !== 'ObjectPattern') return;
    for (const pr of p0.properties) {
      if (pr.type !== 'ObjectProperty') continue;
      const key = pr.key.type === 'Identifier' ? pr.key.name : isStr(pr.key) ? strValue(pr.key) : null;
      if (!key) continue;
      const declared = DECLARED_BUILTIN.has(key) || project.extendKeys.has(key);
      if (!A9_ALLOWED.has(key) && !project.extendKeys.has(key) && (DECLARED_BUILTIN.has(key) || !project.extendOpen)) ctx.report('TB-A9', pr, { message: `fixture \`${key}\` requested by a test`, test });
      if (!declared && !project.extendOpen) ctx.report('TB-A10', pr, { severity: 'advisory', message: `fixture \`${key}\` is declared by no extend, mergeTests or built-in fixture (advisory: unmeasured)`, test });
    }
  }
}
