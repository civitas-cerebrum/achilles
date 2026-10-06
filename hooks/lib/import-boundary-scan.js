// import-boundary-scan.js — import-boundary screen for
// hooks/achilles-import-boundary-gate.sh.
//
// `npx playwright test` runs under the orchestrator and executes the root
// config, every file it names, and every test file with its imports. None of
// that may reach code outside tests/. A static floor, not a sandbox: the
// source is parsed with @babel/parser and anything the screen cannot read is
// denied.
//
//   config   root playwright*.config.ts: bare imports from a fixed allowlist,
//            no value-producing relative import; exactly one export, of an
//            object literal / defineConfig(object literals) / a const bound to
//            one and referenced nowhere else; a top-level testDir, and every
//            globalSetup / globalTeardown / testDir / tsconfig / file reporter
//            evaluating statically to a path under tests/; projects as an
//            array of object literals; no Object.* / Reflect / JSON / exports.
//   tests    every file under tests/, whatever its extension (node's CJS
//            loader runs any extension as JS): every specifier is one string
//            literal; relative ones resolve under tests/ and load code or JSON;
//            no `#` imports, no self-reference, no module / vm / child_process /
//            worker_threads / process modules. package.json and tsconfig /
//            jsconfig there may not point outside.
//   both     no eval / Function / createRequire / Reflect; process, module,
//            globalThis and global only as the object of a static member read
//            (never a value); require only as require("…") / require.resolve;
//            no .require / ._load / ._compile / .constructor / process loader
//            members on any object; no loader names as pattern keys or bare
//            strings; no computed key assembled from strings.
//   package  root package.json: name, exports and imports may not change.
//
// Usage: <PreToolUse payload> | node import-boundary-scan.js <file> <cwd>
//   → {"scope":"config"|"tests"|"package"|"none","offenders":["…", …]}
// Exit 3 when the time budget runs out; any non-zero exit is a deny, with one
// reason line on stderr.

'use strict';

const fs = require('fs');
const path = require('path');
const { createRequire } = require('module');
const { execFileSync } = require('child_process');

const MAX_BYTES = 256 * 1024;
const DEADLINE = Date.now() + 5000;
const CONFIG_IMPORTS = new Set(['@playwright/test', '@civitas-cerebrum/element-interactions', 'dotenv', 'dotenv/config', 'node:path', 'path', 'node:url', 'url']);
// Modules that load or run code by path, or hand out the loader; a tests/ file never needs them.
const LOADER_MODULES = new Set(['module', 'vm', 'child_process', 'worker_threads', 'process']);
const CODE_EXT = ['.ts', '.tsx', '.mts', '.cts', '.js', '.jsx', '.mjs', '.cjs'];
const PATH_KEYS = new Set(['globalSetup', 'globalTeardown', 'testDir', 'tsconfig', 'reporter']);
// Members that reach the loader from any object: Module.prototype, process, Function.prototype.
const LOADER_MEMBERS = new Set(['constructor', 'require', '_load', '_compile', 'mainModule', 'binding', '_linkedBinding', 'getBuiltinModule', 'dlopen']);
const MODULE_MEMBERS = new Set(['exports', 'id', 'filename', 'path', 'loaded']);
const GLOBAL_OBJECTS = new Set(['process', 'module', 'globalThis', 'global']);
const CODE_RUNNERS = new Set(['eval', 'Function', 'createRequire', 'Reflect']);
const CASE_FOLD = process.platform === 'darwin' || process.platform === 'win32';
const fold = (s) => (CASE_FOLD ? s.toLowerCase() : s);
const SKIP_KEYS = new Set(['loc', 'start', 'end', 'extra', 'range', 'leadingComments', 'trailingComments', 'innerComments', 'comments', 'tokens', 'errors']);

// The hook runs from ~/.claude/hooks/lib, outside any node_modules tree, so
// the build bundles the parser beside it. Project lookups go through realpath:
// a pnpm store keeps a package's dependencies next to its real directory.
function loadParser(root) {
  try { return require(path.join(__dirname, 'babel-parser.bundle.js')); } catch { /* unbuilt checkout */ }
  const bases = [__filename, path.join(root, 'package.json'), path.join(root, 'node_modules', '@civitas-cerebrum', 'achilles', 'package.json')];
  for (const b of bases) {
    try { return createRequire(fs.realpathSync.native(b))('@babel/parser'); } catch { /* next */ }
  }
  throw new Error('@babel/parser not found; reinstall @civitas-cerebrum/achilles');
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

// The project directory above the shallowest `tests` segment of p, when that
// directory has a package.json; null when p is not inside a project's tests/.
function projectAbove(p) {
  const parts = p.split(path.sep);
  for (let i = 1; i < parts.length; i++) {
    const above = parts.slice(0, i).join(path.sep) || path.sep;
    if (fold(parts[i]) === 'tests' && fs.existsSync(path.join(above, 'package.json'))) return above;
  }
  return null;
}

// $CLAUDE_PROJECT_DIR, else the git toplevel unless it sits inside a project's
// tests/ (a gitfile there would move the root), else cwd cut above tests/.
function projectRoot(file, cwd) {
  if (process.env.CLAUDE_PROJECT_DIR) return real(path.resolve(process.env.CLAUDE_PROJECT_DIR));
  let dir = path.dirname(file);
  while (!fs.existsSync(dir) && path.dirname(dir) !== dir) dir = path.dirname(dir);
  try {
    const top = execFileSync('git', ['-C', dir, 'rev-parse', '--show-toplevel'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    if (top && projectAbove(real(top)) === null) return real(top);
  } catch { /* not a git work tree */ }
  const c = real(cwd);
  return projectAbove(c) || c;
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
    if (Date.now() > DEADLINE) throw Object.assign(new Error('time budget exceeded'), { exitCode: 3 });
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

const isId = (n, name) => !!n && n.type === 'Identifier' && (name === undefined || n.name === name);
const isStr = (n) => !!n && n.type === 'StringLiteral';
const isMember = (n) => !!n && (n.type === 'MemberExpression' || n.type === 'OptionalMemberExpression');
const isCall = (n) => !!n && (n.type === 'CallExpression' || n.type === 'OptionalCallExpression' || n.type === 'NewExpression');
const isObj = (n) => !!n && n.type === 'ObjectExpression';
// A member's property name when it is statically known; null when computed from code.
function propName(m) {
  if (!m.computed && m.property.type === 'Identifier') return m.property.name;
  if (isStr(m.property)) return m.property.value;
  return null;
}
// A property or pattern key's name; null when computed from code.
function keyName(p) {
  if (p.computed && !isStr(p.key)) return null;
  return isId(p.key) ? p.key.name : isStr(p.key) ? p.key.value : p.key.type === 'NumericLiteral' ? String(p.key.value) : null;
}
function unwrap(n) {
  while (n && ['TSAsExpression', 'TSSatisfiesExpression', 'TSNonNullExpression', 'TSTypeAssertion', 'ParenthesizedExpression'].includes(n.type)) n = n.expression;
  return n;
}
const isKeyOf = (p, key) => !!p && key === 'key' && !p.computed && /^(?:Object|Class)(?:Property|Method|Accessor|PrivateProperty)$|^TS(?:Property|Method)Signature$/.test(p.type);
const isStaticProp = (p, key) => isMember(p) && key === 'property' && !p.computed;
// A TS node's child is a type unless it is the wrapped expression, a parameter
// property or an enum initializer.
const inTypePosition = (p, key) => !!p && p.type.startsWith('TS') && !['expression', 'parameter', 'initializer'].includes(key);
const isLiteralText = (n) => isStr(n) || (n.type === 'TemplateLiteral' && n.expressions.length === 0);
const literalText = (n) => (isStr(n) ? n.value : n.quasis.map((q) => q.value.cooked).join(''));

// A call that loads a module: import(), require(), require.resolve().
function isLoaderCall(n) {
  if (n.type === 'ImportExpression') return true;
  if (!isCall(n)) return false;
  const c = unwrap(n.callee);
  if (c.type === 'Import' || isId(c, 'require')) return true;
  return isMember(c) && propName(c) === 'resolve' && isId(unwrap(c.object), 'require');
}

// Each loaded specifier with its node, or the reason it cannot be read.
function specifiers(ast) {
  const out = [];
  const take = (n, lit, where) => {
    if (!isStr(lit)) out.push({ bad: `${where} is not one string literal` });
    else if (/\\/.test((lit.extra && lit.extra.raw) || '')) out.push({ bad: `${where} "${lit.value}" contains an escape` });
    else out.push({ node: n, spec: lit.value, typeOnly: n.importKind === 'type' || n.exportKind === 'type' });
  };
  for (const { node: n } of walk(ast)) {
    if (n.type === 'ImportDeclaration' || n.type === 'ExportAllDeclaration') take(n, n.source, 'import source');
    else if (n.type === 'ExportNamedDeclaration' && n.source) take(n, n.source, 'export source');
    else if (n.type === 'TSImportEqualsDeclaration' && n.moduleReference.type === 'TSExternalModuleReference') take(n, n.moduleReference.expression, 'import = require()');
    else if (isLoaderCall(n)) {
      const args = n.type === 'ImportExpression' ? [n.source, ...(n.options ? [n.options] : [])] : n.arguments;
      const extraOk = args.length === 2 && isObj(args[1]) && (n.type === 'ImportExpression' || unwrap(n.callee).type === 'Import');
      if (args.length !== 1 && !extraOk) out.push({ bad: 'a loader call takes other than one argument' });
      else take(n, args[0], 'loader argument');
    }
  }
  return out;
}

// Constructs that reach the loader or run code the specifier walk cannot see.
function aliasOffences(ast) {
  const out = [];
  for (const { node: n, parent: p, key } of walk(ast)) {
    if (n.type === 'Identifier') {
      if (isStaticProp(p, key) || isKeyOf(p, key) || inTypePosition(p, key)) continue;
      const name = n.name;
      const isTypeof = p && p.type === 'UnaryExpression' && p.operator === 'typeof';
      if (CODE_RUNNERS.has(name) && !isTypeof && !(name === 'Function' && p && p.type === 'BinaryExpression' && p.operator === 'instanceof' && key === 'right')) {
        out.push(`${name} — code the screen cannot read`);
      } else if (name === 'require') {
        const callee = isCall(p) && key === 'callee';
        const resolveObj = isMember(p) && key === 'object' && propName(p) === 'resolve';
        if (!callee && !resolveObj && !isTypeof) out.push('require used other than require("<literal>") or require.resolve("<literal>")');
      } else if (GLOBAL_OBJECTS.has(name) && !isTypeof && !(isMember(p) && key === 'object' && propName(p) !== null)) {
        out.push(`${name} used as a value — only static member reads (${name}.x) are readable`);
      }
    } else if (isMember(n)) {
      const obj = unwrap(n.object);
      const name = propName(n);
      if (name === null) {
        const k = n.property;
        const strOperand = (e) => isStr(e) || e.type === 'TemplateLiteral';
        if (isId(obj) && GLOBAL_OBJECTS.has(obj.name)) out.push(`${obj.name}[…] computed from code`);
        else if ((k.type === 'TemplateLiteral' && k.expressions.length) || (k.type === 'BinaryExpression' && k.operator === '+' && (strOperand(k.left) || strOperand(k.right)))) out.push('a computed member key assembled from strings');
      } else if (LOADER_MEMBERS.has(name)) {
        out.push(`.${name} reaches the module loader or Function`);
      } else if (isId(obj, 'module') && !MODULE_MEMBERS.has(name)) out.push(`module.${name}`);
      else if (isId(obj) && (obj.name === 'globalThis' || obj.name === 'global') && (GLOBAL_OBJECTS.has(name) || CODE_RUNNERS.has(name) || name === 'require')) out.push(`${obj.name}.${name} — the global reached through another name`);
    } else if (n.type === 'ObjectProperty' && p && p.type === 'ObjectPattern') {
      const k = keyName(n);
      if (k === null) out.push('a destructuring pattern with a computed key');
      else if (LOADER_MEMBERS.has(k)) out.push(`{ ${k} } destructured — it reaches the module loader or Function`);
    } else if (n.type === 'ObjectProperty' && keyName(n) === 'constructor') out.push('a constructor property key');
    else if ((isStr(n) || n.type === 'TemplateLiteral') && !isKeyOf(p, key) && !(isMember(p) && key === 'property') && isLiteralText(n) && LOADER_MEMBERS.has(literalText(n))) {
      out.push(`"${literalText(n)}" names a loader member`);
    }
  }
  return out;
}

// ── config ─────────────────────────────────────────────────────────────────

// Statically evaluates a path expression the config may use; throws otherwise.
// require.resolve calls it accepts are recorded: the config may use no other.
function evalPath(n, root, cfgFile, resolves) {
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
    const args = () => n.arguments.map((a) => evalPath(a, root, cfgFile, resolves));
    if (isId(obj, 'path') && fn === 'join') return path.join(...args());
    if (isId(obj, 'path') && fn === 'resolve') return path.resolve(root, ...args());
    if (isId(obj, 'path') && fn === 'dirname' && n.arguments.length === 1) return path.dirname(args()[0]);
    if (isId(obj, 'require') && fn === 'resolve' && n.arguments.length === 1) { resolves.add(n); return path.resolve(root, args()[0]); }
  }
  if (n.type === 'CallExpression' && isId(n.callee, 'fileURLToPath') && n.arguments.length === 1) {
    const u = evalPath(n.arguments[0], root, cfgFile, resolves);
    if (!u.startsWith('file://')) throw new Error('fileURLToPath of something other than import.meta.url');
    return u.slice('file://'.length);
  }
  throw new Error(`${n.type} is not a literal or path helper`);
}

function pathKeyOffences(key, value, root, cfgFile, resolves) {
  const v = unwrap(value);
  const out = [];
  const check = (n, label) => {
    let p;
    try { p = evalPath(n, root, cfgFile, resolves); } catch (e) { out.push(`${label}: ${e.message}`); return; }
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

// The object literals the config exports. Exactly one export: `export default`
// or `module.exports =` of an object literal, defineConfig(object literals),
// or a top-level const bound to one of those and referenced nowhere else.
function exportedConfigs(ast) {
  const top = new Map();
  for (const s of ast.program.body) {
    if (s.type === 'VariableDeclaration') for (const d of s.declarations) if (isId(d.id)) top.set(d.id.name, { kind: s.kind, init: d.init });
  }
  const exported = [];
  for (const s of ast.program.body) {
    if (s.type === 'ExportDefaultDeclaration') exported.push(s.declaration);
    else if (s.type === 'ExportNamedDeclaration' && s.exportKind !== 'type' && !(s.declaration && /^TS(?:Interface|TypeAlias|Enum|Module|Declare)/.test(s.declaration.type))) throw new Error('a named export — the config exports exactly one default');
    else if (s.type === 'ExportAllDeclaration' || s.type === 'TSExportAssignment') throw new Error(`${s.type} — the config exports exactly one default`);
    else if (s.type === 'ExpressionStatement' && s.expression.type === 'AssignmentExpression' && isMember(s.expression.left)
      && isId(unwrap(s.expression.left.object), 'module') && propName(s.expression.left) === 'exports') exported.push(s.expression.right);
  }
  if (exported.length !== 1) throw new Error(`${exported.length} config exports — exactly one is readable`);
  const objects = [];
  const literals = (n) => {
    n = unwrap(n);
    if (isObj(n)) return objects.push(n);
    if (n && n.type === 'CallExpression' && isId(n.callee, 'defineConfig') && n.arguments.length && n.arguments.every((a) => isObj(unwrap(a)))) return n.arguments.forEach((a) => objects.push(unwrap(a)));
    throw new Error(`the exported config is ${n ? n.type : 'empty'}, not an object literal or defineConfig(object literals)`);
  };
  const e = unwrap(exported[0]);
  if (isId(e) && top.has(e.name)) {
    const b = top.get(e.name);
    if (b.kind !== 'const') throw new Error(`${e.name} is ${b.kind}, not const — the exported binding may not change`);
    let refs = 0;
    for (const { node: n, parent: p, key } of walk(ast)) if (isId(n, e.name) && !isStaticProp(p, key) && !isKeyOf(p, key) && !inTypePosition(p, key)) refs++;
    if (refs !== 2) throw new Error(`${e.name} is referenced outside its declaration and export — the exported object may not be touched`);
    literals(b.init);
  } else literals(e);
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
  const resolves = new Set();
  let configs = [];
  try { configs = exportedConfigs(ast); } catch (e) { out.push(e.message); }
  if (configs.length && !configs.some((o) => o.properties.some((p) => p.type === 'ObjectProperty' && keyName(p) === 'testDir'))) {
    out.push('no top-level testDir — Playwright would default to the config directory, which holds src/');
  }
  const exportLeft = new Set(ast.program.body.filter((s) => s.type === 'ExpressionStatement' && s.expression.type === 'AssignmentExpression').map((s) => s.expression.left));
  // Every path key anywhere in the file, not only in the exported object.
  for (const { node: n, parent: p, key } of walk(ast)) {
    if (isMember(n) && isId(unwrap(n.object), 'module') && !exportLeft.has(n)) {
      out.push(`module.${propName(n) || '[…]'} — the config writes module.exports once, as its only export`);
    }
    if (n.type === 'ObjectProperty' || n.type === 'ObjectMethod') {
      const k = keyName(n);
      if (k === null) { out.push('a computed property key'); continue; }
      if (k === '__proto__') { out.push('a __proto__ key'); continue; }
      if (k === 'projects' && n.type === 'ObjectProperty') {
        const v = unwrap(n.value);
        if (!(v.type === 'ArrayExpression' && v.elements.every((e) => isObj(unwrap(e))))) out.push('projects is not an array of object literals');
      }
      if (!PATH_KEYS.has(k)) continue;
      if (n.type === 'ObjectMethod') out.push(`${k} defined as a method or accessor`);
      else out.push(...pathKeyOffences(k, n.value, root, cfgFile, resolves));
    } else if (n.type === 'SpreadElement' && p && p.type === 'ObjectExpression') {
      const a = unwrap(n.argument);
      if (!(isMember(a) && isId(unwrap(a.object), 'devices'))) out.push('an object spread other than ...devices[…]');
    } else if (n.type === 'AssignmentExpression' && isMember(n.left)) {
      const k = propName(n.left);
      if (k === null) out.push('an assignment through a computed member');
      else if (PATH_KEYS.has(k)) out.push(`.${k} = … assigned outside the config literal`);
    } else if ((isStr(n) || n.type === 'TemplateLiteral') && !isKeyOf(p, key) && isLiteralText(n) && PATH_KEYS.has(literalText(n))) {
      out.push(`"${literalText(n)}" names a path key outside a property`);
    } else if (n.type === 'Identifier' && ['Object', 'Reflect', 'Proxy', 'JSON', 'exports'].includes(n.name) && !isStaticProp(p, key) && !isKeyOf(p, key) && !inTypePosition(p, key)) {
      out.push(`${n.name} — the config's keys must be literal properties`);
    } else if (isMember(n) && ['prototype', '__proto__'].includes(propName(n))) out.push(`.${propName(n)} — the config's keys must be literal properties`);
  }
  for (const s of specifiers(ast)) {
    if (s.bad) { out.push(s.bad); continue; }
    if (s.typeOnly) continue;
    const relative = s.spec.startsWith('.') || path.isAbsolute(s.spec);
    if (isCall(s.node) && isMember(unwrap(s.node.callee))) {
      if (!resolves.has(s.node)) out.push(`require.resolve("${s.spec}") outside a globalSetup / globalTeardown / testDir value`);
    } else if (relative) out.push(`import "${s.spec}" — the config loads no relative module (name files under tests/ in globalSetup / testDir / reporter instead)`);
    else if (!CONFIG_IMPORTS.has(s.spec)) out.push(`import "${s.spec}" — not in the config import allowlist`);
  }
  out.push(...aliasOffences(ast), ...bindingOffences(ast));
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
    if (LOADER_MODULES.has(spec.replace(/^node:/, '')) && !s.typeOnly) { out.push(`import "${spec}" — a module that loads or runs code by path`); continue; }
    if (!(spec.startsWith('.') || path.isAbsolute(spec))) continue;
    const target = path.resolve(base, spec);
    if (!underTests(root, target)) { out.push(`import "${spec}" — resolves outside tests/`); continue; }
    const t = targetProblem(target);
    if (t) out.push(`import "${spec}" — ${t}`);
  }
  out.push(...aliasOffences(ast));
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
    if (/^playwright.*\.config\.[cm]?[jt]s$/i.test(name)) return 'config-ext';
    if (fold(name) === 'package.json') return 'package';
  }
  if (within(testsDir(root), file) && fold(file) !== fold(testsDir(root))) return 'tests';
  return 'none';
}

function main() {
  const [fileArg, cwdArg] = process.argv.slice(2);
  const cwd = path.resolve(cwdArg);
  const file = real(path.resolve(cwd, fileArg));
  const root = projectRoot(file, cwd);
  const scope = scopeOf(file, root);
  const payload = JSON.parse(fs.readFileSync(0, 'utf8'));
  let offenders = [];
  if (scope === 'config-ext') offenders = [`${path.basename(file)} — the runner config is playwright*.config.ts; Playwright would load this one too`];
  else if (scope !== 'none') {
    const src = postWrite(payload, file);
    const ext = path.extname(file).toLowerCase();
    const relSegments = path.relative(testsDir(root), file).split(path.sep);
    if (Buffer.byteLength(src) > MAX_BYTES) offenders = [`${Buffer.byteLength(src)} bytes — config/spec too large to screen (cap ${MAX_BYTES})`];
    else if (scope === 'package') offenders = scanPackage(src, file);
    else if (scope === 'tests' && relSegments.some((s) => fold(s) === '.git')) offenders = ['a .git entry under tests/ would move the project root'];
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
  process.stdout.write(JSON.stringify({ scope: scope === 'config-ext' ? 'config' : scope, offenders: [...new Set(offenders)].slice(0, 50) }));
}

try { main(); } catch (e) {
  process.stderr.write(`${e.message}\n`);
  process.exit(e.exitCode || 2);
}
