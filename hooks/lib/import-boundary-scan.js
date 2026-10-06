// import-boundary-scan.js — import-boundary screen for
// hooks/achilles-import-boundary-gate.sh.
//
// `npx playwright test` runs under the orchestrator and executes the root
// config, every file it names, and every test file with its imports. None of
// that may reach code outside tests/. A static floor, not a sandbox: the
// source is parsed with @babel/parser and anything the screen cannot read is
// denied.
//
//   config   root playwright*.config.ts: imports from a fixed allowlist or
//            relative under tests/; globalSetup / globalTeardown / testDir and
//            file reporters evaluate statically to paths under tests/.
//   tests    every file under tests/, whatever its extension (node's CJS
//            loader runs any extension as JS): every specifier is one string
//            literal; relative ones resolve under tests/ and load code or JSON;
//            no `#` imports, no self-reference to the project's package.
//            package.json and tsconfig/jsconfig there may not point outside.
//   package  root package.json: name, exports and imports may not change.
//
// Usage: <PreToolUse payload> | node import-boundary-scan.js <file> <cwd>
//   → {"scope":"config"|"tests"|"package"|"none","offenders":["…", …]}
// Exit 3 when the time budget runs out; any non-zero exit is a deny.

'use strict';

const fs = require('fs');
const path = require('path');
const { createRequire } = require('module');
const { execFileSync } = require('child_process');

const MAX_BYTES = 256 * 1024;
const DEADLINE = Date.now() + 5000;
const CONFIG_IMPORTS = new Set(['@playwright/test', '@civitas-cerebrum/element-interactions', 'dotenv', 'dotenv/config', 'node:path', 'path', 'node:url', 'url']);
const CODE_EXT = ['.ts', '.tsx', '.mts', '.cts', '.js', '.jsx', '.mjs', '.cjs'];
const LIFECYCLE = new Set(['globalSetup', 'globalTeardown', 'testDir', 'reporter']);
const CASE_FOLD = process.platform === 'darwin' || process.platform === 'win32';
const fold = (s) => (CASE_FOLD ? s.toLowerCase() : s);
const SKIP_KEYS = new Set(['loc', 'start', 'end', 'extra', 'range', 'leadingComments', 'trailingComments', 'innerComments', 'comments', 'tokens', 'errors']);

// The hook runs from ~/.claude/hooks/lib, outside any node_modules tree: look
// beside it, then in the project, then in the project's copy of this package.
function loadParser(root) {
  const bases = [__filename, path.join(root, 'package.json'), path.join(root, 'node_modules', '@civitas-cerebrum', 'achilles', 'package.json')];
  for (const b of bases) {
    try { return createRequire(b)('@babel/parser'); } catch { /* next */ }
  }
  throw new Error('@babel/parser not found beside the hook or in the project');
}

// ── paths ───────────────────────────────────────────────────────────────────

function real(p) {
  let head = p, tail = '';
  while (!fs.existsSync(head) && path.dirname(head) !== head) {
    tail = path.join(path.basename(head), tail);
    head = path.dirname(head);
  }
  return path.join(fs.realpathSync.native(head), tail);
}
function within(dir, p) {
  const rel = path.relative(fold(dir), fold(p));
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}
const testsDir = (root) => path.join(root, 'tests');
const underTests = (root, abs) => within(testsDir(root), real(abs));
const hasTestsSegment = (p) => p.split(path.sep).some((s) => fold(s) === 'tests');

// $CLAUDE_PROJECT_DIR, else the git toplevel unless it sits at or under a
// tests/ segment (a gitfile under tests/ would move it), else cwd cut above tests/.
function projectRoot(file, cwd) {
  if (process.env.CLAUDE_PROJECT_DIR) return real(path.resolve(process.env.CLAUDE_PROJECT_DIR));
  let dir = path.dirname(file);
  while (!fs.existsSync(dir) && path.dirname(dir) !== dir) dir = path.dirname(dir);
  try {
    const top = execFileSync('git', ['-C', dir, 'rev-parse', '--show-toplevel'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    if (top && !hasTestsSegment(real(top))) return real(top);
  } catch { /* not a git work tree */ }
  const parts = real(cwd).split(path.sep);
  const t = parts.findIndex((s) => fold(s) === 'tests');
  return t > 0 ? parts.slice(0, t).join(path.sep) : real(cwd);
}

// ── JSONC (tsconfig accepts comments and trailing commas; node's package.json
// loader strips a BOM) ─────────────────────────────────────────────────────

function parseJsonc(text) {
  let s = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
  let out = '';
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === '"') {
      let j = i + 1;
      while (j < s.length && s[j] !== '"') j += s[j] === '\\' ? 2 : 1;
      out += s.slice(i, j + 1);
      i = j;
    } else if (c === '/' && s[i + 1] === '/') {
      while (i < s.length && s[i] !== '\n') i++;
      out += '\n';
    } else if (c === '/' && s[i + 1] === '*') {
      const e = s.indexOf('*/', i + 2);
      if (e === -1) throw new Error('unterminated comment');
      i = e + 1;
      out += ' ';
    } else out += c;
  }
  s = out.replace(/,(\s*[\]}])/g, '$1');
  return JSON.parse(s);
}
function readJsonc(p) {
  try { return parseJsonc(fs.readFileSync(p, 'utf8')); } catch { return null; }
}
function canonical(v) {
  if (Array.isArray(v)) return v.map(canonical);
  if (v && typeof v === 'object') return Object.fromEntries(Object.keys(v).sort().map((k) => [k, canonical(v[k])]));
  return v;
}
function stringLeaves(v, out = []) {
  if (typeof v === 'string') out.push(v);
  else if (v && typeof v === 'object') for (const x of Object.values(v)) stringLeaves(x, out);
  return out;
}

// ── AST ───────────────────────────────────────────────────────────────────

function parseCode(src, file, parser) {
  const ext = path.extname(file).toLowerCase();
  const attrs = ['importAttributes', { deprecatedAssertSyntax: true }];
  const sets = ext === '.ts' || ext === '.mts' || ext === '.cts' ? [['typescript', 'decorators-legacy']]
    : ext === '.tsx' ? [['typescript', 'jsx', 'decorators-legacy']]
    : CODE_EXT.includes(ext) ? [['jsx']]
    : [['jsx'], ['typescript']]; // a non-code file is JS to node's CJS loader
  let last;
  for (const plugins of sets) {
    try {
      return parser.parse(src, { sourceType: 'unambiguous', errorRecovery: false, allowReturnOutsideFunction: true, plugins: [...plugins, attrs] });
    } catch (e) { last = e; }
  }
  throw last;
}

function* walk(ast) {
  const stack = [{ node: ast.program, parent: null, key: null }];
  while (stack.length) {
    if (Date.now() > DEADLINE) { process.stderr.write('time budget exceeded\n'); process.exit(3); }
    const item = stack.pop();
    yield item;
    for (const [k, v] of Object.entries(item.node)) {
      if (SKIP_KEYS.has(k) || !v || typeof v !== 'object') continue;
      if (Array.isArray(v)) {
        for (let i = v.length - 1; i >= 0; i--) if (v[i] && typeof v[i].type === 'string') stack.push({ node: v[i], parent: item.node, key: k });
      } else if (typeof v.type === 'string') stack.push({ node: v, parent: item.node, key: k });
    }
  }
}

const isId = (n, name) => n && n.type === 'Identifier' && (name === undefined || n.name === name);
const isStr = (n) => n && n.type === 'StringLiteral';
// A member's property name when it is statically known; null when computed from code.
function propName(m) {
  if (!m.computed && m.property.type === 'Identifier') return m.property.name;
  if (isStr(m.property)) return m.property.value;
  return null;
}
const isMember = (n) => n && (n.type === 'MemberExpression' || n.type === 'OptionalMemberExpression');
const isCall = (n) => n && (n.type === 'CallExpression' || n.type === 'OptionalCallExpression' || n.type === 'NewExpression');
function unwrap(n) {
  while (n && ['TSAsExpression', 'TSSatisfiesExpression', 'TSNonNullExpression', 'TSTypeAssertion', 'ParenthesizedExpression'].includes(n.type)) n = n.expression;
  return n;
}

// A call that loads a module: import(), require(), require.resolve(), any
// `.require` / `._load` member, createRequire(…)(…).
function isLoaderCall(n) {
  if (n.type === 'ImportExpression') return true;
  if (!isCall(n)) return false;
  const c = unwrap(n.callee);
  if (c.type === 'Import' || isId(c, 'require')) return true;
  if (isMember(c)) {
    const p = propName(c);
    if (p === 'require' || p === '_load') return true;
    if (p === 'resolve' && isId(unwrap(c.object), 'require')) return true;
  }
  return isCall(c) && isId(unwrap(c.callee), 'createRequire');
}

// Each loaded specifier, or the reason it cannot be read.
function specifiers(ast) {
  const out = [];
  const take = (lit, where) => {
    if (!isStr(lit)) out.push({ bad: `${where} is not one string literal` });
    else if (/\\/.test((lit.extra && lit.extra.raw) || '')) out.push({ bad: `${where} "${lit.value}" contains an escape` });
    else out.push({ spec: lit.value });
  };
  for (const { node: n } of walk(ast)) {
    if (n.type === 'ImportDeclaration' || n.type === 'ExportAllDeclaration') take(n.source, 'import source');
    else if (n.type === 'ExportNamedDeclaration' && n.source) take(n.source, 'export source');
    else if (n.type === 'TSImportEqualsDeclaration' && n.moduleReference.type === 'TSExternalModuleReference') take(n.moduleReference.expression, 'import = require()');
    else if (isLoaderCall(n)) {
      const args = n.type === 'ImportExpression' ? [n.source, ...(n.options ? [n.options] : [])] : n.arguments;
      const extraOk = args.length === 2 && args[1].type === 'ObjectExpression' && (n.type === 'ImportExpression' || unwrap(n.callee).type === 'Import');
      if (args.length !== 1 && !extraOk) out.push({ bad: 'a loader call takes other than one argument' });
      else take(args[0], 'loader argument');
    }
  }
  return out;
}

// Constructs that load or run code the specifier walk cannot see.
function dangerous(ast) {
  const out = [];
  for (const { node: n, parent: p, key } of walk(ast)) {
    if (n.type === 'Identifier' && ['eval', 'Function', 'createRequire'].includes(n.name) && !(p && /^TS(?:TypeReference|QualifiedName|ExpressionWithTypeArguments|InterfaceHeritage)$/.test(p.type))
        && !(isMember(p) && key === 'property' && !p.computed) && !(p && p.type === 'ObjectProperty' && key === 'key' && !p.computed)) {
      out.push(`${n.name} — code the screen cannot read`);
    }
    if (isId(n, 'require')) {
      const callee = p && isCall(p) && key === 'callee';
      const resolveObj = isMember(p) && key === 'object' && propName(p) === 'resolve';
      const declKey = (isMember(p) && key === 'property' && !p.computed) || (p && p.type === 'ObjectProperty' && key === 'key' && !p.computed);
      if (!callee && !resolveObj && !declKey) out.push('require used other than require("<literal>")');
    }
    if (isMember(n)) {
      const obj = unwrap(n.object);
      const name = propName(n);
      if (name === null && (isId(obj, 'module') || isId(obj, 'require') || isId(obj, 'process') || isId(obj, 'globalThis') || isId(obj, 'global'))) {
        out.push(`${obj.name}[…] computed from code`);
      }
      if (isId(obj, 'process') && ['binding', '_linkedBinding', 'getBuiltinModule', 'dlopen', 'mainModule'].includes(name)) out.push(`process.${name}`);
      if (isId(obj, 'module') && ['constructor', 'require', 'children', 'parent'].includes(name) && !(name === 'require' && p && isCall(p) && key === 'callee')) out.push(`module.${name}`);
      if (name === '_load' || name === 'constructor' && isId(obj, 'module')) out.push(`.${name}`);
      if (name === 'require' && !(p && isCall(p) && key === 'callee')) out.push('.require used other than .require("<literal>")');
    }
  }
  return out;
}

// ── config ─────────────────────────────────────────────────────────────────

// Statically evaluates a path expression the config may use; throws otherwise.
function evalPath(n, root, cfgFile) {
  n = unwrap(n);
  if (isStr(n)) {
    if (/\\/.test((n.extra && n.extra.raw) || '')) throw new Error('an escape in a path literal');
    return n.value;
  }
  if (isId(n, '__dirname')) return root;
  if (n.type === 'MemberExpression' && n.object.type === 'MetaProperty' && propName(n) === 'url') return 'file://' + cfgFile;
  if (n.type === 'CallExpression' && isMember(n.callee)) {
    const obj = unwrap(n.callee.object);
    const fn = propName(n.callee);
    const args = () => n.arguments.map((a) => evalPath(a, root, cfgFile));
    if (isId(obj, 'path') && fn === 'join') return path.join(...args());
    if (isId(obj, 'path') && fn === 'resolve') return path.resolve(root, ...args());
    if (isId(obj, 'path') && fn === 'dirname' && n.arguments.length === 1) return path.dirname(args()[0]);
    if (isId(obj, 'require') && fn === 'resolve' && n.arguments.length === 1) return path.resolve(root, args()[0]);
  }
  if (n.type === 'CallExpression' && isId(n.callee, 'fileURLToPath') && n.arguments.length === 1) {
    const u = evalPath(n.arguments[0], root, cfgFile);
    if (!u.startsWith('file://')) throw new Error('fileURLToPath of something other than import.meta.url');
    return u.slice('file://'.length);
  }
  throw new Error(`${n.type} is not a literal or path helper`);
}

function lifecycleOffences(key, value, root, cfgFile) {
  const v = unwrap(value);
  const out = [];
  const check = (n, label) => {
    let p;
    try { p = evalPath(n, root, cfgFile); } catch (e) { out.push(`${label}: ${e.message}`); return; }
    if (!underTests(root, path.resolve(root, p))) out.push(`${label}: "${p}" resolves outside tests/`);
  };
  if (key === 'reporter') {
    const entries = v.type === 'ArrayExpression' ? v.elements : [v];
    for (const e of entries) {
      const name = e && unwrap(e).type === 'ArrayExpression' ? unwrap(e).elements[0] : e;
      if (!name) { out.push('reporter: an empty entry'); continue; }
      const n = unwrap(name);
      if (isStr(n) && !n.value.startsWith('.') && !path.isAbsolute(n.value) && !/\\/.test(n.extra.raw)) continue; // a package
      check(n, 'reporter');
    }
  } else if (v.type === 'ArrayExpression') {
    for (const e of v.elements) e ? check(e, key) : out.push(`${key}: an empty entry`);
  } else check(v, key);
  return out;
}

// The object(s) the config exports: export default / module.exports of an
// object, defineConfig(…objects), or an identifier bound to one of those.
function exportedConfigs(ast) {
  const top = new Map();
  for (const s of ast.program.body) {
    const decl = s.type === 'ExportNamedDeclaration' ? s.declaration : s;
    if (decl && decl.type === 'VariableDeclaration') for (const d of decl.declarations) if (isId(d.id)) top.set(d.id.name, d.init);
  }
  const exported = [];
  for (const s of ast.program.body) {
    if (s.type === 'ExportDefaultDeclaration') exported.push(s.declaration);
    if (s.type === 'ExpressionStatement' && s.expression.type === 'AssignmentExpression') {
      const l = s.expression.left;
      if (isMember(l) && isId(l.object, 'module') && propName(l) === 'exports') exported.push(s.expression.right);
    }
  }
  if (exported.length !== 1) throw new Error(`${exported.length} config exports — exactly one is readable`);
  const objects = [];
  const resolve = (n, depth) => {
    n = unwrap(n);
    if (isId(n) && depth === 0 && top.has(n.name)) return resolve(top.get(n.name), 1);
    if (n && n.type === 'ObjectExpression') return objects.push(n);
    if (n && n.type === 'CallExpression' && isId(n.callee, 'defineConfig') && n.arguments.length) return n.arguments.forEach((a) => resolve(a, depth));
    throw new Error(`the exported config is ${n ? n.type : 'empty'}, not an object the screen can read`);
  };
  resolve(exported[0], 0);
  return objects;
}

function bindingOffences(ast) {
  const out = [];
  const CANON = (init) => init && init.type === 'CallExpression' && isMember(init.callee) && isId(init.callee.object, 'path') && propName(init.callee) === 'dirname'
    && init.arguments.length === 1 && init.arguments[0].type === 'CallExpression' && isId(init.arguments[0].callee, 'fileURLToPath')
    && init.arguments[0].arguments.length === 1 && init.arguments[0].arguments[0].type === 'MemberExpression' && init.arguments[0].arguments[0].object.type === 'MetaProperty';
  const GUARDED = ['path', 'fileURLToPath', '__dirname', 'require', 'defineConfig', 'devices'];
  for (const { node: n } of walk(ast)) {
    if (n.type === 'ImportDeclaration') {
      const src = n.source.value;
      for (const s of n.specifiers) {
        const local = s.local.name;
        if (local === 'path' && !((src === 'path' || src === 'node:path') && s.type !== 'ImportSpecifier')) out.push(`path bound to ${src}`);
        if (local === 'fileURLToPath' && !((src === 'url' || src === 'node:url') && s.type === 'ImportSpecifier' && (s.imported.name || s.imported.value) === 'fileURLToPath')) out.push(`fileURLToPath bound to ${src}`);
        if (['__dirname', 'require', 'defineConfig', 'devices'].includes(local) && !(['defineConfig', 'devices'].includes(local) && src === '@playwright/test' && s.type === 'ImportSpecifier')) out.push(`${local} bound by import from ${src}`);
      }
    }
    const declared = n.type === 'VariableDeclarator' || n.type === 'FunctionDeclaration' || n.type === 'ClassDeclaration' ? n.id : null;
    if (declared && !isId(declared)) {
      for (const { node: b } of walk({ program: declared })) if (isId(b) && GUARDED.includes(b.name)) out.push(`${b.name} redeclared by destructuring`);
    } else if (declared && GUARDED.includes(declared.name) && declared.name !== '__dirname') out.push(`${declared.name} redeclared`);
    else if (declared && declared.name === '__dirname' && !(n.type === 'VariableDeclarator' && CANON(n.init))) out.push('__dirname defined other than path.dirname(fileURLToPath(import.meta.url))');
    if (n.type === 'AssignmentExpression' && isId(n.left) && GUARDED.includes(n.left.name)) out.push(`${n.left.name} reassigned`);
  }
  return out;
}

function scanConfig(ast, root, cfgFile) {
  const out = [];
  for (const s of specifiers(ast)) {
    if (s.bad) out.push(s.bad);
    else if (!CONFIG_IMPORTS.has(s.spec) && !((s.spec.startsWith('.') || path.isAbsolute(s.spec)) && underTests(root, path.resolve(root, s.spec)))) {
      out.push(`import "${s.spec}" — not in the config import allowlist`);
    }
  }
  out.push(...dangerous(ast), ...bindingOffences(ast));
  try { exportedConfigs(ast); } catch (e) { out.push(e.message); }
  // Every lifecycle key anywhere in the file, not only in the exported object:
  // Object.assign(config, { globalSetup }) is the same channel.
  for (const { node: n, parent: p, key } of walk(ast)) {
    if (n.type === 'ObjectProperty' || n.type === 'ObjectMethod') {
      if (n.computed && !isStr(n.key)) { out.push('a computed property key'); continue; }
      if (n.key.type === 'NumericLiteral') continue;
      const k = isId(n.key) ? n.key.name : isStr(n.key) ? n.key.value : null;
      if (k === null) { out.push(`a ${n.key.type} property key`); continue; }
      if (!LIFECYCLE.has(k)) continue;
      if (n.type === 'ObjectMethod') out.push(`${k} defined as a method or accessor`);
      else out.push(...lifecycleOffences(k, n.value, root, cfgFile));
    } else if (n.type === 'SpreadElement' && p && p.type === 'ObjectExpression') {
      const a = unwrap(n.argument);
      const fromDevices = isMember(a) && isId(unwrap(a.object), 'devices');
      if (!fromDevices) out.push('an object spread other than ...devices[…]');
    } else if (n.type === 'AssignmentExpression' && isMember(n.left)) {
      const k = propName(n.left);
      if (k === null) out.push('an assignment through a computed member');
      else if (LIFECYCLE.has(k)) out.push(`.${k} = … assigned outside the config literal`);
    } else if ((isStr(n) || n.type === 'TemplateLiteral') && !(p && (p.type === 'ObjectProperty' || p.type === 'ObjectMethod') && key === 'key')) {
      const v = isStr(n) ? n.value : n.quasis.map((q) => q.value.cooked).join('');
      if (LIFECYCLE.has(v)) out.push(`"${v}" names a lifecycle key outside a property`);
    } else if (n.type === 'Identifier' && ['defineProperty', 'defineProperties', 'Reflect', 'setPrototypeOf', '__proto__', 'fromEntries'].includes(n.name)) {
      out.push(`${n.name} — the config's keys must be literal properties`);
    } else if (isMember(n) && isId(unwrap(n.object), 'JSON') && propName(n) === 'parse') {
      out.push("JSON.parse — the config's keys must be literal properties");
    }
  }
  return out;
}

// ── tests/ ─────────────────────────────────────────────────────────────────

// A relative specifier's target is loaded as code whatever its extension, so it
// must be code or JSON: `./auth.setup` passes when auth.setup.ts is on disk,
// `../helper.txt` and an extensionless file on disk do not.
function targetProblem(target) {
  const ext = path.extname(target).toLowerCase();
  if (CODE_EXT.includes(ext) || ext === '.json') return null;
  let stat = null;
  try { stat = fs.statSync(target); } catch { /* not on disk yet */ }
  if (stat && stat.isFile()) return 'loads a file that is not code or JSON';
  if (!ext) return null;
  const twin = CODE_EXT.some((e) => fs.existsSync(target + e) || fs.existsSync(path.join(target, 'index' + e)));
  return twin ? null : `has extension ${ext}, which is not code or JSON (write the module it names first)`;
}

const hasTwin = (file) => CODE_EXT.some((e) => fs.existsSync(file + e) || fs.existsSync(path.join(file, 'index' + e)));

function scanTestCode(src, file, root, parser) {
  const ext = path.extname(file).toLowerCase();
  let ast;
  try { ast = parseCode(src, file, parser); } catch (e) {
    // Prose that does not parse cannot run, unless node would load it in place of a code twin.
    if (CODE_EXT.includes(ext) || hasTwin(file)) return [`does not parse: ${e.message}`];
    return [];
  }
  const out = [];
  const base = path.dirname(file);
  const pkg = readJsonc(path.join(root, 'package.json')) || {};
  const own = typeof pkg.name === 'string' ? pkg.name : null;
  for (const s of specifiers(ast)) {
    if (s.bad) { out.push(s.bad); continue; }
    const spec = s.spec;
    if (spec.startsWith('#')) { out.push(`import "${spec}" — package imports map outside the screen`); continue; }
    if (own && (spec === own || spec.startsWith(own + '/'))) { out.push(`import "${spec}" — the project's own package (self-reference)`); continue; }
    if (!(spec.startsWith('.') || path.isAbsolute(spec))) continue;
    const target = path.resolve(base, spec);
    if (!underTests(root, target)) { out.push(`import "${spec}" — resolves outside tests/`); continue; }
    const t = targetProblem(target);
    if (t) out.push(`import "${spec}" — ${t}`);
  }
  out.push(...dangerous(ast));
  return out;
}

// JSON under tests/ is data, except the files that steer resolution.
function scanTestJson(src, file, root) {
  const name = path.basename(file).toLowerCase();
  const base = path.dirname(file);
  const resolution = name === 'package.json' || /^(?:ts|js)config.*\.json$/.test(name);
  if (!resolution) return [];
  let json;
  try { json = parseJsonc(src); } catch (e) { return [`${name} does not parse: ${e.message}`]; }
  const out = [];
  const inside = (v, from) => typeof v === 'string' && underTests(root, path.resolve(from, v));
  if (name === 'package.json') {
    for (const field of ['main', 'module', 'exports', 'imports', 'browser']) {
      for (const v of stringLeaves(json[field])) if (!v.startsWith('.') || !inside(v, base)) out.push(`package.json ${field}: "${v}" resolves outside tests/`);
    }
    return out;
  }
  if ('extends' in json) out.push(`${name} extends — the screen does not follow inherited config`);
  if ('references' in json) out.push(`${name} references — the screen does not follow project references`);
  const co = json.compilerOptions || {};
  if ('baseUrl' in co && !inside(co.baseUrl, base)) out.push(`${name} baseUrl "${co.baseUrl}" resolves outside tests/`);
  const pathsBase = typeof co.baseUrl === 'string' ? path.resolve(base, co.baseUrl) : base;
  for (const v of stringLeaves(co.paths)) if (!inside(v, pathsBase)) out.push(`${name} paths "${v}" resolves outside tests/`);
  for (const v of stringLeaves(co.rootDirs)) if (!inside(v, base)) out.push(`${name} rootDirs "${v}" resolves outside tests/`);
  return out;
}

// ── root package.json ──────────────────────────────────────────────────────

// name, exports and imports decide what `import "<name>"` and `#x` load.
function scanPackage(src, file) {
  let after;
  try { after = parseJsonc(src); } catch (e) { return [`package.json does not parse: ${e.message}`]; }
  const before = readJsonc(file) || {};
  const out = [];
  for (const f of ['name', 'exports', 'imports']) {
    if (JSON.stringify(canonical(before[f])) !== JSON.stringify(canonical(after[f]))) out.push(`package.json ${f} changed — it decides what a bare or # specifier resolves to`);
  }
  return out;
}

// ── main ───────────────────────────────────────────────────────────────────

function postWrite(payload, file) {
  const t = payload.tool_input || {};
  if (payload.tool_name === 'Write') return t.content || '';
  const before = fs.readFileSync(file, 'utf8');
  if (t.replace_all) return before.split(t.old_string).join(t.new_string);
  const i = before.indexOf(t.old_string);
  return i === -1 ? before : before.slice(0, i) + t.new_string + before.slice(i + t.old_string.length);
}

function scopeOf(file, root) {
  const name = path.basename(file);
  if (fold(path.dirname(file)) === fold(root)) {
    if (/^playwright.*\.config\.ts$/i.test(name)) return 'config';
    if (fold(name) === 'package.json') return 'package';
  }
  if (within(testsDir(root), file) && fold(file) !== fold(testsDir(root))) return 'tests';
  return 'none';
}

const [fileArg, cwdArg] = process.argv.slice(2);
const cwd = path.resolve(cwdArg);
const file = real(path.resolve(cwd, fileArg));
const root = projectRoot(file, cwd);
const scope = scopeOf(file, root);
const payload = JSON.parse(fs.readFileSync(0, 'utf8'));
let offenders = [];
if (scope !== 'none') {
  const src = postWrite(payload, file);
  const ext = path.extname(file).toLowerCase();
  if (Buffer.byteLength(src) > MAX_BYTES) offenders = [`${Buffer.byteLength(src)} bytes — config/spec too large to screen (cap ${MAX_BYTES})`];
  else if (scope === 'package') offenders = scanPackage(src, file);
  else if (scope === 'tests' && fold(path.basename(file)) === '.git') offenders = ['a .git file under tests/ would move the project root'];
  else if (scope === 'tests' && ext === '.json') offenders = scanTestJson(src, file, root);
  else {
    const parser = loadParser(root);
    if (scope === 'config') {
      let ast;
      try { ast = parseCode(src, file, parser); } catch (e) { ast = null; offenders = [`does not parse: ${e.message}`]; }
      if (ast) offenders = scanConfig(ast, root, file);
    } else offenders = scanTestCode(src, file, root, parser);
  }
}
process.stdout.write(JSON.stringify({ scope, offenders: [...new Set(offenders)].slice(0, 50) }));
