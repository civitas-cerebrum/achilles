// config-import-scan.js — runner-config screen for
// hooks/achilles-config-import-gate.sh.
//
// `npx playwright test` loads the root config and every file it names, under
// the orchestrator. A config that imports project code or points a lifecycle
// file into src/** makes the orchestrator's run execute it, so the config may
// import only the runner, the framework, dotenv and path helpers, and every
// file path it names must sit under tests/.
//
// Usage: <PreToolUse payload> | node config-import-scan.js <config-file> <project-root>
//   → {"offenders":["…", …]}   (empty list = clean)
// The payload's Write content, or its Edit applied to <config-file>, is what is screened.

'use strict';

const fs = require('fs');
const path = require('path');

const ALLOWED = new Set([
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
// A specifier the screen cannot read is a specifier it cannot allow.
const OPAQUE_RES = [
  [/\bimport\s*\(\s*(?!['"`])/g, 'dynamic import() of a non-literal'],
  [/\brequire\b(?!\s*\(\s*['"`])(?!\.resolve\s*\(\s*['"`])/g, 'require used other than require("<literal>")'],
  [/\bcreateRequire\b/g, 'createRequire'],
];
const PATH_KEY_RE = /["']?\b(globalSetup|globalTeardown|testDir)\b["']?\s*:\s*/g;

// The value runs to the first `,` or `}` outside brackets and strings.
function valueAt(src, i) {
  let depth = 0;
  for (let j = i; j < src.length; j++) {
    const c = src[j];
    if (c === '"' || c === "'" || c === '`') {
      for (j++; j < src.length && src[j] !== c; j += src[j] === '\\' ? 2 : 1);
    } else if ('([{'.includes(c)) depth++;
    else if (')]}'.includes(c)) { if (depth-- === 0) return src.slice(i, j); }
    else if (c === ',' && depth === 0) return src.slice(i, j);
  }
  return src.slice(i);
}

function underTests(root, base, p) {
  const rel = path.relative(root, path.resolve(base, p));
  return rel === 'tests' || (rel.startsWith('tests' + path.sep) && !rel.startsWith('..'));
}

// Comments are screened as code: a stripper that does not parse regex
// literals can be steered into eating real code, and a config has no need to
// mention `require` in prose.
function scan(src, root) {
  const offenders = [];
  for (const re of SPECIFIER_RES) {
    for (const m of src.matchAll(re)) {
      const spec = m[2];
      if (ALLOWED.has(spec)) continue;
      if ((spec.startsWith('.') || path.isAbsolute(spec)) && underTests(root, root, spec)) continue;
      offenders.push(`import "${spec}" — not in the config import allowlist`);
    }
  }
  for (const [re, what] of OPAQUE_RES) {
    if (re.test(src)) offenders.push(what);
  }
  for (const m of src.matchAll(PATH_KEY_RE)) {
    const value = valueAt(src, m.index + m[0].length).trim();
    const literals = [...value.matchAll(new RegExp(STR, 'g'))].map((s) => s[2]);
    if (literals.length === 0) {
      offenders.push(`${m[1]}: ${value} — not a string literal`);
      continue;
    }
    // `[a, b]` lists independent files; `path.join(__dirname, 'tests', 'x')` composes one.
    const paths = value.startsWith('[') ? literals : [path.join(...literals)];
    for (const p of paths) {
      if (!underTests(root, root, p)) offenders.push(`${m[1]}: "${p}" — resolves outside tests/`);
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

const [file, root] = process.argv.slice(2);
const payload = JSON.parse(fs.readFileSync(0, 'utf8'));
process.stdout.write(JSON.stringify({ offenders: scan(postWrite(payload, file), path.resolve(root)) }));
