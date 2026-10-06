// import-boundary-scan.js — import-boundary screen for
// hooks/achilles-import-boundary-gate.sh.
//
// `npx playwright test` runs under the orchestrator and executes the root
// config, every file it names, and every test file with its imports. None of
// that may reach code outside tests/. A static floor, not a sandbox: it denies
// what it cannot read, and reads with patterns, not a parser.
//
//   config   root playwright*.config.ts: imports from a fixed allowlist or
//            relative under tests/; globalSetup / globalTeardown / testDir and
//            file reporters resolve under tests/; anything the screen cannot
//            read statically is denied.
//   tests    every file under tests/, whatever its extension (node's CJS
//            loader runs any extension as JS): relative specifiers resolve
//            under tests/ and load code or JSON; no `#` imports, no
//            self-reference to the project's own package. Bare package
//            specifiers are otherwise the kernel's codeImports screen.
//            package.json and tsconfig/jsconfig under tests/ may not point
//            outside tests/.
//   package  root package.json: name, exports and imports may not change, since
//            they decide what a bare or `#` specifier resolves to.
//
// Comments are screened as code: a stripper that does not parse regex
// literals can be steered into eating real code.
//
// Usage: <PreToolUse payload> | node import-boundary-scan.js <file> <cwd>
//   → {"scope":"config"|"tests"|"package"|"none","offenders":["…", …]}
// The payload's Write content, or its Edit applied to <file>, is what is screened.

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

// Well under the size where the patterns below cost a hook's 10s timeout,
// which does not block.
const MAX_BYTES = 256 * 1024;

const CONFIG_IMPORTS = new Set([
  '@playwright/test',
  '@civitas-cerebrum/element-interactions',
  'dotenv',
  'dotenv/config',
  'node:path',
  'path',
  'node:url',
  'url',
]);
const CODE_EXT = new Set(['.ts', '.tsx', '.mts', '.cts', '.js', '.jsx', '.mjs', '.cjs']);
const CASE_FOLD = process.platform === 'darwin' || process.platform === 'win32';
const fold = (s) => (CASE_FOLD ? s.toLowerCase() : s);

// Every pattern is linear: bounded clauses, no nested unbounded classes.
const STR = String.raw`(['"\x60])((?:\\.|(?!\1)[^\\\n]){0,1024})\1`;
const SPECIFIER_RES = [
  // import 'x' | import a from 'x' | import a, { b } from 'x' | import * as a from 'x' | import type …
  new RegExp(String.raw`\bimport\s*(?:type\s+)?(?:[\w$]{1,256}\s*,?\s*)?(?:\*\s*as\s+[\w$]{1,256}\s*|\{[^}]{0,1024}\}\s*)?(?:from\s*)?` + STR + String.raw`(?<tail>[ \t]*(?:\S{1,6})?)`, 'g'),
  new RegExp(String.raw`\bexport\s*(?:type\s+)?(?:\*\s*(?:as\s+[\w$]{1,256}\s*)?|\{[^}]{0,1024}\}\s*)from\s*` + STR + String.raw`(?<tail>[ \t]*(?:\S{1,6})?)`, 'g'),
  new RegExp(String.raw`\b(?:import|require(?:\.resolve)?)\s*\(\s*` + STR + String.raw`(?<tail>\s*\S?)`, 'g'),
];
// A specifier is exactly one plain literal: `'./tests/' + '../src'`,
// `${…}` and escapes (`.\x2e`) make the text the screen reads differ from the
// path node loads.
function specifierProblem(m) {
  const [, quote, spec] = m;
  if (/\\/.test(spec)) return 'contains an escape';
  if (quote === '`' && spec.includes('${')) return 'is a template with a substitution';
  const tail = m.groups.tail.trim();
  if (m[0].trimStart().match(/^(?:import|require(?:\.resolve)?)\s*\(/)) {
    if (tail !== ')') return 'is not a single literal argument';
  } else if (tail && !/^(?:;|\/\/|\/\*|with\b|assert\b)/.test(tail)) {
    return 'is not a single literal';
  }
  return null;
}
function* specifiers(src) {
  for (const re of SPECIFIER_RES) for (const m of src.matchAll(re)) yield m;
}

// What the screen cannot read statically, it does not allow.
const CANONICAL_PATH_IMPORT = /\bimport\s*\*\s*as\s+path\s+from\s*(['"])(?:node:)?path\1/g;
const CANONICAL_DIRNAME = /^[ \t]*const[ \t]+__dirname[ \t]*=[ \t]*path\.dirname\([ \t]*fileURLToPath\([ \t]*import\.meta\.url[ \t]*\)[ \t]*\)[ \t]*;?[ \t]*$/gm;
const LOADER_RES = [
  [/\bimport\s*\(\s*(?!['"`])/g, 'dynamic import() of a non-literal'],
  [/\brequire\b(?!\s*\(\s*['"`])(?!\.resolve\s*\(\s*['"`])/g, 'require used other than require("<literal>")'],
  [/\bcreateRequire\b/g, 'createRequire'],
];
// Prose under tests/ (docs, notes) says "require" in sentences; only a
// code-shaped use counts there. Such a file loads as code only through a
// specifier that targetProblem() already bounds.
const PROSE_LOADER_RES = [
  LOADER_RES[0],
  [/\brequire[ \t]*(?:[;,)\]}=.[]|\((?![ \t]*['"`])|$)/gm, 'require used other than require("<literal>")'],
  LOADER_RES[2],
];
const OPAQUE_RES = [
  ...LOADER_RES,
  [/\\(?:x|u|[0-7])/g, 'escape sequence (node decodes it; the screen reads it raw)'],
  [/\[[^[\]\n]{0,1024}\]\s*:(?!:)/g, 'computed property key'],
  [/\]\s*=(?![=>])/g, 'assignment through a computed member'],
  [/\b(?:eval|Function|JSON\.parse|defineProperty|defineProperties|Reflect|setPrototypeOf|__proto__|fromEntries|constructor|binding|dlopen|mainModule|_load|child_process)\b/g, 'reflective or dynamic code'],
  [/\b(?:const|let|var|function|class)\s+(?:path|fileURLToPath|require)\b/g, 'a path helper redefined'],
  [/\b(?:path|fileURLToPath|__dirname)\s*=(?![=>])|\bpath\.[\w$]+\s*=(?![=>])/g, 'a path helper reassigned'],
  [/\bas\s+(?:path|fileURLToPath|__dirname)\b/g, 'a path helper bound by alias'],
  [/\b(?:const|let|var)\s+__dirname\b/g, '__dirname defined other than path.dirname(fileURLToPath(import.meta.url))'],
];

const LIFECYCLE = 'globalSetup|globalTeardown|testDir';
const KEY_RE = new RegExp(String.raw`["']?\b(${LIFECYCLE}|reporter)\b["']?\s*:(?!:)\s*`, 'g');
const ASSIGN_RE = new RegExp(String.raw`\.(${LIFECYCLE}|reporter)\s*=(?![=>])\s*`, 'g');
// A lifecycle key named any other way (string argument, computed access) is unreadable.
const STRAY_RES = [
  new RegExp(String.raw`(?<!\.)\b(?:${LIFECYCLE})\b(?!["']?\s*:)|\.(?:${LIFECYCLE})\b(?!\s*=(?![=>]))`, 'g'),
  /(['"`])reporter\1(?!\s*:)/g,
];

// A value may hold only literals and the path helpers: no env, no operators.
const VALUE_TOKENS = /path\.(?:join|resolve)|require\.resolve|fileURLToPath\(\s*import\.meta\.url\s*\)|__dirname/g;

// The value runs to the first `,` / `;` or closing bracket outside brackets and
// strings. Not to a newline: `"./tests/a"\n  ? "./src/b" : …` continues the expression.
// Bounded so that many keys cannot make the screen quadratic; an unterminated
// value is null, and unreadable.
const MAX_VALUE = 8192;
const MAX_KEYS = 64;
function valueAt(src, i) {
  let depth = 0;
  const end = Math.min(src.length, i + MAX_VALUE);
  for (let j = i; j < end; j++) {
    const c = src[j];
    if (c === '"' || c === "'" || c === '`') {
      for (j++; j < src.length && src[j] !== c; j += src[j] === '\\' ? 2 : 1);
    } else if ('([{'.includes(c)) depth++;
    else if (')]}'.includes(c)) { if (depth-- === 0) return src.slice(i, j); }
    else if ((c === ',' || c === ';') && depth === 0) return src.slice(i, j);
  }
  return end === src.length ? src.slice(i) : null;
}

// Top-level elements of an array literal `[a, [b, c], …]`.
function elements(arr) {
  const inner = arr.trim().slice(1, -1);
  const out = [];
  let depth = 0, start = 0;
  for (let j = 0; j < inner.length; j++) {
    const c = inner[j];
    if (c === '"' || c === "'" || c === '`') {
      for (j++; j < inner.length && inner[j] !== c; j += inner[j] === '\\' ? 2 : 1);
    } else if ('([{'.includes(c)) depth++;
    else if (')]}'.includes(c)) depth--;
    else if (c === ',' && depth === 0) { out.push(inner.slice(start, j)); start = j + 1; }
  }
  out.push(inner.slice(start));
  return out.map((e) => e.trim()).filter(Boolean);
}

// Symlinks and (on case-insensitive filesystems) case resolved for the part
// that exists, so tests/ means the project's tests/ however the path is spelled.
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

function underTests(root, base, p) {
  return within(path.join(root, 'tests'), real(path.resolve(base, p)));
}

function literalsOf(value) {
  return [...value.matchAll(new RegExp(STR, 'g'))].map((s) => s[2]);
}

// A path-shaped value: literals composed by the path helpers only.
function pathOffence(key, value, root) {
  const shape = value.replace(new RegExp(STR, 'g'), 'S').replace(VALUE_TOKENS, '');
  if (!/^[\sS,()[\]]*$/.test(shape)) return `${key}: ${value} — only string literals and path helpers may build it`;
  const literals = literalsOf(value);
  if (literals.length === 0) return `${key}: ${value} — names no path`;
  if (literals.some((l) => l.includes('${'))) return `${key}: ${value} — a template substitution`;
  // `[a, b]` lists independent files; `path.join(__dirname, 'tests', 'x')` composes one.
  const paths = value.startsWith('[') ? literals.map((l) => [l]) : [literals];
  for (const parts of paths) {
    const joined = path.join(...parts);
    if (!underTests(root, root, joined) || !underTests(root, root, path.resolve(root, ...parts))) {
      return `${key}: "${joined}" — resolves outside tests/`;
    }
  }
  return null;
}

// A reporter is a package name or a file; a file must sit under tests/.
function reporterOffences(value, root) {
  const names = value.startsWith('[')
    ? elements(value).map((e) => (e.startsWith('[') ? elements(e)[0] || '' : e))
    : [value];
  const out = [];
  for (const name of names) {
    const lit = name.match(new RegExp('^' + STR + '$'));
    if (!lit || lit[2].includes('${')) { out.push(`reporter: ${name} — the reporter name must be a plain string literal`); continue; }
    const spec = lit[2];
    if ((spec.startsWith('.') || spec.startsWith('/')) && !underTests(root, root, spec)) {
      out.push(`reporter: "${spec}" — resolves outside tests/`);
    }
  }
  return out;
}

function readJson(p) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; }
}

function stringLeaves(v, out = []) {
  if (typeof v === 'string') out.push(v);
  else if (v && typeof v === 'object') for (const x of Object.values(v)) stringLeaves(x, out);
  return out;
}

// A relative specifier's target is loaded as code whatever its extension, so it
// must be code or JSON: `./auth.setup` passes when auth.setup.ts is on disk,
// `../helper.txt` and an extensionless file on disk do not.
function targetProblem(target) {
  const ext = path.extname(target).toLowerCase();
  if (CODE_EXT.has(ext) || ext === '.json') return null;
  let stat = null;
  try { stat = fs.statSync(target); } catch { /* not on disk yet */ }
  if (stat && stat.isFile()) return 'loads a file that is not code or JSON';
  if (!ext) return null;
  const asCode = [...CODE_EXT].some((e) => fs.existsSync(target + e) || fs.existsSync(path.join(target, 'index' + e)));
  return asCode ? null : `has extension ${ext}, which is not code or JSON (write the module it names first)`;
}

function scanTestCode(src, file, root) {
  const out = [];
  const base = path.dirname(file);
  const own = (readJson(path.join(root, 'package.json')) || {}).name;
  for (const m of specifiers(src)) {
    const spec = m[2];
    const problem = specifierProblem(m);
    if (problem) { out.push(`specifier ${m[1]}${spec}${m[1]} ${problem}`); continue; }
    if (spec.startsWith('#')) { out.push(`import "${spec}" — package imports map outside the screen`); continue; }
    if (own && (spec === own || spec.startsWith(own + '/'))) { out.push(`import "${spec}" — the project's own package (self-reference)`); continue; }
    if (!(spec.startsWith('.') || path.isAbsolute(spec))) continue;
    if (!underTests(root, base, spec)) { out.push(`import "${spec}" — resolves outside tests/`); continue; }
    const t = targetProblem(path.resolve(base, spec));
    if (t) out.push(`import "${spec}" — ${t}`);
  }
  const ext = path.extname(file).toLowerCase();
  for (const [re, what] of CODE_EXT.has(ext) || !ext ? LOADER_RES : PROSE_LOADER_RES) {
    const m = src.match(re);
    if (m) out.push(`${what}: ${m[0].trim()}`);
  }
  return out;
}

// JSON under tests/ is data, except the two files that steer resolution.
function scanTestJson(src, file, root) {
  const name = path.basename(file).toLowerCase();
  const base = path.dirname(file);
  let json;
  try { json = JSON.parse(src); } catch { return []; }
  const out = [];
  if (name === 'package.json') {
    for (const field of ['main', 'module', 'exports', 'imports', 'browser']) {
      for (const v of stringLeaves(json[field])) {
        if (!v.startsWith('.') || !underTests(root, base, v)) out.push(`package.json ${field}: "${v}" — resolves outside tests/`);
      }
    }
  } else if (/^(?:ts|js)config.*\.json$/.test(name)) {
    const co = json.compilerOptions || {};
    for (const [field, vals] of [['baseUrl', [co.baseUrl]], ['paths', stringLeaves(co.paths)], ['rootDirs', stringLeaves(co.rootDirs)]]) {
      for (const v of vals.filter((x) => typeof x === 'string')) {
        if (!underTests(root, base, v)) out.push(`${name} ${field}: "${v}" — resolves outside tests/`);
      }
    }
  }
  return out;
}

function scanConfig(src, root) {
  const offenders = [];
  for (const m of specifiers(src)) {
    const spec = m[2];
    const problem = specifierProblem(m);
    if (problem) { offenders.push(`specifier ${m[1]}${spec}${m[1]} ${problem}`); continue; }
    if (CONFIG_IMPORTS.has(spec)) continue;
    if ((spec.startsWith('.') || path.isAbsolute(spec)) && underTests(root, root, spec)) continue;
    offenders.push(`import "${spec}" — not in the config import allowlist`);
  }
  const unreadable = src.replace(CANONICAL_DIRNAME, '').replace(CANONICAL_PATH_IMPORT, '');
  for (const [re, what] of OPAQUE_RES) {
    const m = unreadable.match(re);
    if (m) offenders.push(`${what}: ${m[0].trim()}`);
  }
  for (const re of STRAY_RES) {
    const m = src.match(re);
    if (m) offenders.push(`${m[0]} named outside a literal property or .${m[0].replace(/['"`]/g, '')} = assignment`);
  }
  const keys = [...src.matchAll(KEY_RE), ...src.matchAll(ASSIGN_RE)];
  if (keys.length > MAX_KEYS) return [...offenders, `${keys.length} lifecycle/reporter keys — too many to screen (cap ${MAX_KEYS})`];
  for (const m of keys) {
    const raw = valueAt(src, m.index + m[0].length);
    if (raw === null) { offenders.push(`${m[1]}: value longer than ${MAX_VALUE} characters — too long to screen`); continue; }
    const value = raw.trim();
    if (m[1] === 'reporter') offenders.push(...reporterOffences(value, root));
    else {
      const o = pathOffence(m[1], value, root);
      if (o) offenders.push(o);
    }
  }
  return offenders;
}

// name, exports and imports decide what `import "<name>"` and `#x` load.
function scanPackage(src, file) {
  let after;
  try { after = JSON.parse(src); } catch { return []; }
  const before = readJson(file) || {};
  const out = [];
  for (const f of ['name', 'exports', 'imports']) {
    if (JSON.stringify(before[f]) !== JSON.stringify(after[f])) out.push(`package.json ${f} changed — it decides what a bare or # specifier resolves to`);
  }
  return out;
}

function postWrite(payload, file) {
  const t = payload.tool_input || {};
  if (payload.tool_name === 'Write') return t.content || '';
  const before = fs.readFileSync(file, 'utf8');
  if (t.replace_all) return before.split(t.old_string).join(t.new_string);
  const i = before.indexOf(t.old_string);
  return i === -1 ? before : before.slice(0, i) + t.new_string + before.slice(i + t.old_string.length);
}

// $CLAUDE_PROJECT_DIR, else the file's git toplevel, else cwd cut above any
// tests/ segment: a session that cd's into tests/e2e does not move the root.
function projectRoot(file, cwd) {
  if (process.env.CLAUDE_PROJECT_DIR) return real(path.resolve(process.env.CLAUDE_PROJECT_DIR));
  let dir = path.dirname(file);
  while (!fs.existsSync(dir) && path.dirname(dir) !== dir) dir = path.dirname(dir);
  try {
    const top = execFileSync('git', ['-C', dir, 'rev-parse', '--show-toplevel'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    if (top) return real(top);
  } catch { /* not a git work tree */ }
  const parts = real(cwd).split(path.sep);
  const t = parts.findIndex((s) => fold(s) === 'tests');
  return t > 0 ? parts.slice(0, t).join(path.sep) : real(cwd);
}

function scopeOf(file, root) {
  const name = path.basename(file);
  if (fold(path.dirname(file)) === fold(root)) {
    if (/^playwright.*\.config\.ts$/i.test(name)) return 'config';
    if (fold(name) === 'package.json') return 'package';
  }
  if (within(path.join(root, 'tests'), file) && fold(file) !== fold(path.join(root, 'tests'))) return 'tests';
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
  if (Buffer.byteLength(src) > MAX_BYTES) offenders = [`${Buffer.byteLength(src)} bytes — config/spec too large to screen (cap ${MAX_BYTES})`];
  else if (scope === 'config') offenders = scanConfig(src, root);
  else if (scope === 'package') offenders = scanPackage(src, file);
  else if (path.extname(file).toLowerCase() === '.json') offenders = scanTestJson(src, file, root);
  else offenders = scanTestCode(src, file, root);
}
process.stdout.write(JSON.stringify({ scope, offenders: offenders.slice(0, 50) }));
