// import-boundary-scan.js — import-boundary screen for
// hooks/achilles-import-boundary-gate.sh.
//
// `npx playwright test` runs under the orchestrator and executes the root
// config, every file it names, and every test file with its imports. None of
// that may reach code outside tests/.
//
//   config  root playwright*.config.ts: imports from a fixed allowlist or
//           relative under tests/; globalSetup / globalTeardown / testDir and
//           file reporters resolve under tests/; anything the screen cannot
//           read statically is denied.
//   tests   tests/**: every relative specifier resolves under tests/. Bare
//           package specifiers are the kernel's codeImports screen.
//
// Comments are screened as code: a stripper that does not parse regex
// literals can be steered into eating real code.
//
// Usage: <PreToolUse payload> | node import-boundary-scan.js <file> <project-root>
//   → {"scope":"config"|"tests"|"none","offenders":["…", …]}   (empty list = clean)
// The payload's Write content, or its Edit applied to <file>, is what is screened.

'use strict';

const fs = require('fs');
const path = require('path');

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

const STR = String.raw`(['"\x60])((?:\\.|(?!\1)[^\\])*)\1`;
const SPECIFIER_RES = [
  new RegExp(String.raw`\bimport\s+(?:[\w*{}\s,$]+\s+from\s+)?` + STR, 'g'),
  new RegExp(String.raw`\bexport\s+[\w*{}\s,$]+\s+from\s+` + STR, 'g'),
  new RegExp(String.raw`\bimport\s*\(\s*` + STR, 'g'),
  new RegExp(String.raw`\brequire\s*\(\s*` + STR, 'g'),
  new RegExp(String.raw`\brequire\.resolve\s*\(\s*` + STR, 'g'),
];

// What the config screen cannot read statically, it does not allow.
const CANONICAL_PATH_IMPORT = /\bimport\s*\*\s*as\s+path\s+from\s*(['"])(?:node:)?path\1/g;
const CANONICAL_DIRNAME = /^\s*const\s+__dirname\s*=\s*path\.dirname\(\s*fileURLToPath\(\s*import\.meta\.url\s*\)\s*\)\s*;?\s*$/gm;
const OPAQUE_RES = [
  [/\bimport\s*\(\s*(?!['"`])/g, 'dynamic import() of a non-literal'],
  [/\brequire\b(?!\s*\(\s*['"`])(?!\.resolve\s*\(\s*['"`])/g, 'require used other than require("<literal>")'],
  [/\bcreateRequire\b/g, 'createRequire'],
  [/\[[^[\]\n]*\]\s*:(?!:)/g, 'computed property key'],
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
function valueAt(src, i) {
  let depth = 0;
  for (let j = i; j < src.length; j++) {
    const c = src[j];
    if (c === '"' || c === "'" || c === '`') {
      for (j++; j < src.length && src[j] !== c; j += src[j] === '\\' ? 2 : 1);
    } else if ('([{'.includes(c)) depth++;
    else if (')]}'.includes(c)) { if (depth-- === 0) return src.slice(i, j); }
    else if ((c === ',' || c === ';') && depth === 0) return src.slice(i, j);
  }
  return src.slice(i);
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

function underTests(root, base, p) {
  const rel = path.relative(root, path.resolve(base, p));
  return rel === 'tests' || (rel.startsWith('tests' + path.sep) && !rel.startsWith('..'));
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
    if (!lit) { out.push(`reporter: ${name} — the reporter name must be a string literal`); continue; }
    const spec = lit[2];
    if ((spec.startsWith('.') || spec.startsWith('/')) && !underTests(root, root, spec)) {
      out.push(`reporter: "${spec}" — resolves outside tests/`);
    }
  }
  return out;
}

function relativeOffences(src, base, root) {
  const out = [];
  for (const re of SPECIFIER_RES) {
    for (const m of src.matchAll(re)) {
      const spec = m[2];
      if ((spec.startsWith('.') || path.isAbsolute(spec)) && !underTests(root, base, spec)) {
        out.push(`import "${spec}" — resolves outside tests/`);
      }
    }
  }
  return out;
}

function scanConfig(src, root) {
  const offenders = [];
  for (const re of SPECIFIER_RES) {
    for (const m of src.matchAll(re)) {
      const spec = m[2];
      if (CONFIG_IMPORTS.has(spec)) continue;
      if ((spec.startsWith('.') || path.isAbsolute(spec)) && underTests(root, root, spec)) continue;
      offenders.push(`import "${spec}" — not in the config import allowlist`);
    }
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
  for (const re of [KEY_RE, ASSIGN_RE]) {
    for (const m of src.matchAll(re)) {
      const value = valueAt(src, m.index + m[0].length).trim();
      if (m[1] === 'reporter') offenders.push(...reporterOffences(value, root));
      else {
        const o = pathOffence(m[1], value, root);
        if (o) offenders.push(o);
      }
    }
  }
  return offenders;
}

function postWrite(payload, file) {
  const t = payload.tool_input || {};
  if (payload.tool_name === 'Write') return t.content || '';
  const before = fs.readFileSync(file, 'utf8');
  if (t.replace_all) return before.split(t.old_string).join(t.new_string);
  const i = before.indexOf(t.old_string);
  return i === -1 ? before : before.slice(0, i) + t.new_string + before.slice(i + t.old_string.length);
}

// Symlinks resolved, so tests/ means the project's tests/ wherever the path came from.
function real(p) {
  let head = p, tail = '';
  while (!fs.existsSync(head) && path.dirname(head) !== head) {
    tail = path.join(path.basename(head), tail);
    head = path.dirname(head);
  }
  return path.join(fs.realpathSync(head), tail);
}

const TEST_CODE = /\.(?:ts|js|mjs|cjs|mts|cts|tsx|jsx)$/;
function scopeOf(file, root) {
  if (path.dirname(file) === root && /^playwright.*\.config\.ts$/.test(path.basename(file))) return 'config';
  if (file.startsWith(path.join(root, 'tests') + path.sep) && TEST_CODE.test(file)) return 'tests';
  return 'none';
}

const [fileArg, rootArg] = process.argv.slice(2);
const root = real(path.resolve(rootArg));
const file = real(path.resolve(root, fileArg));
const scope = scopeOf(file, root);
const payload = JSON.parse(fs.readFileSync(0, 'utf8'));
let offenders = [];
if (scope !== 'none') {
  const src = postWrite(payload, file);
  offenders = scope === 'config' ? scanConfig(src, root) : relativeOffences(src, path.dirname(file), root);
}
process.stdout.write(JSON.stringify({ scope, offenders }));
