#!/usr/bin/env node
// bin/scenario-lint.mjs — the scenario-block lint (rule specs.shape; skill requirement-intake).
//
//   achilles-scenario-lint [files…] [--id <ID>] [--quiet] [--json]
//
// Project values come from the factory rule file — $FACTORY_RULES (absolute, or relative to the project root) or
// <project>/achilles-factory-rules.json — rule `specs.shape`:
//   titleIdPattern  (required) the id grammar, e.g. "^[A-Z]{2,5}-\\d{2,3}[a-z]? — " (a leading ^ and a trailing " — "
//                   are stripped to get the id core)
//   scenarioDocs    the documents linted when no file is given
//   doc             the anchor quoted on the third line of every message
//   blockEnums      optional { type, oracle, spendPolicy, status } (string arrays): the allowed tags of **Type** and
//                   the allowed leading token of **Oracle**, **Spend policy** and **Status**. A missing array falls
//                   back to the built-in default below; **Type** falls back to specs.shape.tags, then to "any @tag".
// Tokens are hyphenated (`one-confirming-run`, `red-by-design`, `omitted-by-ruling`). Before matching, the lint
// normalises the value's first line and every token: lower case, counts such as `3×` / `n×` removed, runs of spaces
// turned into hyphens — so the prose a person writes (`green 3× (date)`, `red by design (reason)`,
// `one confirming run`) matches `green`, `red-by-design`, `one-confirming-run`. The token must be followed by the end
// of the value or a character that is not a letter or digit.
// **Contexts** is free text (one or more names of whatever the project shards by: region, tenant, browser…).
// The project root is $CLAUDE_PROJECT_DIR, else the current directory.
//
// A block starts at a `#### <ID> — <title>` heading and ends at the next heading of level 1–4 or a `---` rule. Other
// `####` headings are not blocks (listed as `skipped`), except a heading that starts with an ID-like token but fails
// the grammar: that is an error. Each block needs the nine fields as top-level bullets (`- **<Field>**: …`); Steps
// are numbered, in user language, with no selectors and no fixed waits; an ID may appear once per context across all
// given files. A block whose normalised Status starts with `omitted-by-ruling` needs only Contexts, Purpose and Status
// (a project that customises blockEnums.status keeps that token to keep the minimal form).
//
// Exit 0 = every (selected) block passes; exit 1 = a block is rejected, `--id` matched no block, or a file/rules
// problem. Messages have three lines: `[specs.shape] <file>:<line> <ID>: <what>` / `→ Do: …` / `→ Why/how: <doc>`.
// `--json` prints { ok, blocks: [{ id, title, line, file, fields, errors }], skipped }: `blocks` holds the selected
// blocks (only the `--id` match when given); `skipped` always lists every non-block `####` heading of the given files.
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { DEFAULT_RULES_FILE, projectRoot, rulesPath } from './lib/project-root.mjs';

export const RULE_ID = 'specs.shape';
export const FIELDS = ['Contexts', 'Type', 'Purpose', 'Preconditions / test data', 'Steps', 'Expected', 'Oracle', 'Spend policy', 'Status'];
const OMITTED_REQUIRED = ['Contexts', 'Purpose', 'Status'];
export const DEFAULT_ENUMS = {
  oracle: ['UI-only', 'api', 'db'],
  spendPolicy: ['none', 'disposable', 'released', 'one-confirming-run'],
  status: ['proposed', 'implemented', 'green', 'red-by-design', 'blocked', 'omitted-by-ruling'],
};
const OMITTED = 'omitted-by-ruling';
const DEFAULT_DOC = 'skills/requirement-intake/SKILL.md#the-block';

/** Step lines must read as user language: no selectors, no raw locators, no fixed waits. */
const STEP_FORBIDDEN = [
  { re: /data-test(?:id)?/i, what: 'a test-id selector' },
  { re: /\[/, what: 'a "[" (selector/attribute syntax)' },
  { re: /#[a-z][\w-]*/, what: 'a "#id" selector' }, // "#" followed by a digit (an order reference) is not a selector
  { re: /getBy/, what: 'a getBy… locator' },
  { re: /locator/i, what: 'a locator' },
  { re: /\bwait(?:s|ing)?\s+(?:up to\s+|for\s+|about\s+)?\d+(?:[.,]\d+)?/i, what: 'a fixed wait' },
  { re: /\b\d+(?:[.,]\d+)?\s?(?:s|ms|secs?|seconds?)\b/, what: 'a duration (fixed wait)' },
];

const DO_ACTION = 'Bring the block in line with skills/requirement-intake/references/scenario-block.md (all nine fields as '
  + '"- **<Field>**: …" bullets, enum values from specs.shape.blockEnums or the defaults, numbered user-language Steps with no selectors or waits, '
  + 'one block per ID and context), then re-run the lint.';

/** Normalises an enum token or a field value: lower case, counts (`3×`, `n×`) removed, spaces → hyphens. */
export const normalise = (s) => String(s).replace(/\*\*|`/g, '').toLowerCase()
  .replace(/\s*\b(?:\d+|n)\s?×/g, '').trim().replace(/\s+/g, '-');

/** True when the normalised value starts with one of the normalised tokens, followed by a non-alphanumeric or the end. */
const startsWithToken = (value, allowed) => {
  const v = normalise(value.split('\n')[0]);
  return allowed.some((t) => { const n = normalise(t); return v.startsWith(n) && !/[a-z0-9]/.test(v.charAt(n.length)); });
};

/** Reads rule specs.shape and fills the lint's defaults. Throws with a readable message on any problem. */
export function loadRule(root = projectRoot()) {
  const file = rulesPath(root);
  if (!existsSync(file)) throw new Error(`rule file not found at ${file}`);
  let rules;
  try { rules = JSON.parse(readFileSync(file, 'utf8')); } catch (e) { throw new Error(`rule file ${file} is not JSON (${e.message})`); }
  const r = rules?.rules?.[RULE_ID];
  if (!r?.titleIdPattern) throw new Error(`${RULE_ID}.titleIdPattern missing in ${file}`);
  const list = (v, d) => (Array.isArray(v) && v.length ? v.map(String) : d);
  const e = r.blockEnums && typeof r.blockEnums === 'object' ? r.blockEnums : {};
  return {
    ...r,
    doc: r.doc || DEFAULT_DOC,
    types: list(e.type, list(r.tags, null)), // null = any @tag
    oracles: list(e.oracle, DEFAULT_ENUMS.oracle),
    spendPolicies: list(e.spendPolicy, DEFAULT_ENUMS.spendPolicy),
    statuses: list(e.status, DEFAULT_ENUMS.status),
  };
}

const plain = (s) => s.replace(/\*\*/g, '').replace(/`/g, '').trim();
const tokens = (v, sep = /[\s,|/+]+/) => plain(v).replace(/\([^)]*\)/g, ' ').split(sep).filter(Boolean);

function headingParser(rule) {
  const core = String(rule.titleIdPattern).replace(/^\^/, '').replace(/ — $/, '');
  return new RegExp(`^(${core}) — (.+)$`);
}

/** A heading that starts like a scenario ID (upper-case letters/digits, a dash, more) — checked against the grammar. */
const ID_LIKE = /^([A-Z][A-Z0-9]*(?:-[A-Za-z0-9]+)+)(?=\s|$)/;

/** Splits a document into scenario blocks and skipped `####` headings (no validation). */
function parseBlocks(text, file, rule) {
  const lines = text.split(/\r?\n/);
  const direct = headingParser(rule);
  const blocks = [];
  const skipped = [];
  let cur = null;
  const close = () => { if (cur) blocks.push(cur); cur = null; };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (/^#{1,4}\s/.test(line) || /^---\s*$/.test(line)) {
      close();
      const h = /^####\s+(.+?)\s*$/.exec(line);
      if (!h) continue;
      const heading = h[1];
      let m = direct.exec(heading);
      if (m) cur = { id: m[1], title: m[m.length - 1], heading, line: i + 1, file, body: [] };
      else if ((m = ID_LIKE.exec(heading))) {
        cur = { id: m[1], title: heading.slice(m[0].length).replace(/^\s*—\s*/, ''), heading, line: i + 1, file, body: [], badHeading: true };
      } else skipped.push({ heading, line: i + 1, file });
      continue;
    }
    if (cur) cur.body.push({ text: line, line: i + 1 });
  }
  close();
  for (const b of blocks) b.rawFields = parseFields(b.body);
  return { blocks, skipped };
}

/** Top-level `- **Name**…` bullets and their indented continuation lines. */
function parseFields(body) {
  const fields = [];
  let cur = null;
  for (const { text, line } of body) {
    const m = /^- \*\*([^*]+)\*\*(.*)$/.exec(text);
    if (m) {
      cur = { name: m[1].trim().replace(/:$/, '').trim(), line, value: m[2].replace(/^\s*:/, '').trim(), cont: [] };
      fields.push(cur);
    } else if (cur && (text === '' || /^\s/.test(text))) {
      cur.cont.push({ text, line });
    } else {
      if (cur && /^\d+\.\s/.test(text)) cur.unindentedSteps = true; // "1. …" at column 0 right under a bullet
      cur = null;
    }
  }
  for (const f of fields) {
    while (f.cont.length && f.cont[f.cont.length - 1].text.trim() === '') f.cont.pop();
    f.text = [f.value, ...f.cont.map((c) => c.text.trim())].filter(Boolean).join('\n');
  }
  return fields;
}

function validateBlock(b, rule) {
  const errors = [];
  const err = (line, message) => errors.push({ line, message });
  const fields = {};
  const byName = new Map();
  for (const f of b.rawFields) {
    if (byName.has(f.name) && FIELDS.includes(f.name)) err(f.line, `duplicate **${f.name}**`);
    else byName.set(f.name, f);
    fields[f.name] = f.text;
  }
  const status = byName.get('Status');
  const omitted = status && startsWithToken(status.text, [OMITTED]);
  for (const name of omitted ? OMITTED_REQUIRED : FIELDS) {
    const f = byName.get(name);
    if (!f) {
      const key = (s) => s.toLowerCase().replace(/[^a-z]/g, '');
      const near = b.rawFields.find((x) => !FIELDS.includes(x.name) && key(x.name).startsWith(key(name).slice(0, 6)));
      err(b.line, `missing **${name}**${near ? ` (found **${near.name}** — use the template's field name)` : ''}`);
    } else if (!f.text.trim()) err(f.line, f.unindentedSteps ? `indent numbered steps under **${name}** ("  1. …")` : `**${name}** is empty`);
  }
  const check = (name, fn) => { const f = byName.get(name); if (f && f.text.trim()) fn(f, plain(f.text)); };
  const firstWord = (f, v, name, allowed) => {
    if (!startsWithToken(v, allowed)) {
      err(f.line, `**${name}** must start with ${allowed.join(' | ')} (got "${v.split('\n')[0].slice(0, 40)}")`);
    }
  };

  check('Contexts', (f, v) => {
    if (!tokens(v).length) err(f.line, '**Contexts** needs one or more context names');
  });
  check('Type', (f, v) => {
    const toks = tokens(v, /[\s,|/]+/);
    const bad = toks.filter((t) => (rule.types ? !rule.types.includes(t) : !/^@[\w-]+$/.test(t)));
    if (!toks.length) err(f.line, '**Type** needs at least one tag');
    else if (bad.length) err(f.line, `**Type** has unknown tag(s) ${bad.map((t) => `"${t}"`).join(', ')} (known: ${rule.types ? rule.types.join(' ') : 'any @tag'})`);
  });
  check('Steps', (f) => {
    const all = [{ text: f.value, line: f.line }, ...f.cont];
    if (!all.some((l) => /^\s*\d+\.\s+\S/.test(l.text))) err(f.line, f.unindentedSteps ? 'indent numbered steps under **Steps** ("  1. …")' : '**Steps** needs at least one numbered step ("  1. …")');
    for (const l of all) {
      for (const p of STEP_FORBIDDEN) {
        const m = p.re.exec(l.text);
        if (m) err(l.line, `**Steps** mention ${p.what} ("${m[0]}") — write user language and the observable condition instead`);
      }
    }
  });
  check('Oracle', (f, v) => firstWord(f, v, 'Oracle', rule.oracles));
  check('Spend policy', (f, v) => firstWord(f, v, 'Spend policy', rule.spendPolicies));
  check('Status', (f, v) => firstWord(f, v, 'Status', rule.statuses));
  return { fields, errors };
}

const contextsOf = (block) => (block.fields.Contexts ? tokens(block.fields.Contexts) : []);

/** Flags an ID reused for an overlapping context (the same ID may exist once per context). */
function checkDuplicates(blocks) {
  const seen = new Map();
  for (const b of blocks) {
    const clash = new Set();
    for (const c of contextsOf(b)) {
      const prev = seen.get(`${b.id}\u0000${c}`);
      if (prev) clash.add(`${prev.file}:${prev.line} (${c})`);
      else seen.set(`${b.id}\u0000${c}`, b);
    }
    if (clash.size) b.errors.push({ line: b.line, message: `duplicate ID ${b.id} — already used for the same context at ${[...clash].join(', ')}` });
  }
}

function shape(parsed, rule) {
  return parsed.blocks.map((b) => {
    if (b.badHeading) {
      const fields = Object.fromEntries(b.rawFields.map((f) => [f.name, f.text]));
      const errors = [{ line: b.line, message: `heading "#### ${b.heading}" starts like a scenario ID but "${b.id}" does not match specs.shape.titleIdPattern` }];
      return { id: b.id, title: b.title, line: b.line, file: b.file, fields, errors };
    }
    const { fields, errors } = validateBlock(b, rule);
    return { id: b.id, title: b.title, line: b.line, file: b.file, fields, errors };
  });
}

/** Lints one document's text (duplicates checked within this text only). */
export function lintScenarioText(text, file = '<text>', rule = loadRule()) {
  const parsed = parseBlocks(text, file, rule);
  const blocks = shape(parsed, rule);
  checkDuplicates(blocks);
  return { blocks, skipped: parsed.skipped };
}

/** Lints several documents together (duplicates checked across all of them). files: [{ abs, display }]. */
export function lintFiles(files, rule = loadRule()) {
  const blocks = [];
  const skipped = [];
  for (const f of files) {
    const parsed = parseBlocks(readFileSync(f.abs, 'utf8'), f.display, rule);
    blocks.push(...shape(parsed, rule));
    skipped.push(...parsed.skipped);
  }
  checkDuplicates(blocks);
  return { blocks, skipped };
}

export function formatError(block, e, doc) {
  return `[${RULE_ID}] ${block.file}:${e.line} ${block.id}: ${e.message}\n→ Do: ${DO_ACTION}\n→ Why/how: ${doc}`;
}

function main(argv) {
  const args = { files: [], id: null, quiet: false, json: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--quiet') args.quiet = true;
    else if (a === '--json') args.json = true;
    else if (a === '--id') args.id = argv[++i] ?? '';
    else if (a.startsWith('--id=')) args.id = a.slice(5);
    else args.files.push(a);
  }
  const root = projectRoot();
  let rule;
  try { rule = loadRule(root); } catch (e) {
    process.stderr.write(`[${RULE_ID}] scenario lint cannot run: ${e.message}\n→ Do: create ${DEFAULT_RULES_FILE} at the project root (or point FACTORY_RULES at the rule file) with rule specs.shape and its titleIdPattern\n→ Why/how: ${DEFAULT_DOC}\n`);
    return 1;
  }
  if (!args.files.length) args.files = (rule.scenarioDocs ?? []).map((d) => path.join(root, d));
  if (!args.files.length) {
    process.stderr.write(`[${RULE_ID}] no scenario document to lint\n→ Do: pass a document or list it in specs.shape.scenarioDocs\n→ Why/how: ${rule.doc}\n`);
    return 1;
  }
  const files = [];
  for (const f of args.files) {
    const abs = path.resolve(f);
    const rel = path.relative(process.cwd(), abs);
    const display = rel && !rel.startsWith('..') ? rel : abs;
    if (!existsSync(abs)) {
      process.stderr.write(`[${RULE_ID}] scenario document ${display} not found\n→ Do: pass an existing scenario document (specs.shape.scenarioDocs)\n→ Why/how: ${rule.doc}\n`);
      return 1;
    }
    files.push({ abs, display });
  }
  const result = lintFiles(files, rule);
  let selected = result.blocks;
  let missingId = false;
  if (args.id !== null) {
    selected = result.blocks.filter((b) => b.id === args.id);
    missingId = selected.length === 0;
  }
  const rejected = selected.filter((b) => b.errors.length);
  const ok = !missingId && rejected.length === 0;
  if (args.json) {
    process.stdout.write(JSON.stringify({ ok, blocks: selected, skipped: result.skipped }, null, 2) + '\n');
    return ok ? 0 : 1;
  }
  const out = [];
  if (missingId) {
    out.push(`[${RULE_ID}] no scenario block with ID ${args.id} in ${files.map((f) => f.display).join(', ')}\n→ Do: add the block (requirement-intake skill, references/scenario-block.md), lint it, then title the test '${args.id} — <title>'\n→ Why/how: ${rule.doc}`);
  }
  for (const b of rejected) for (const e of b.errors) out.push(formatError(b, e, rule.doc));
  if (out.length) process.stderr.write(out.join('\n') + '\n');
  if (!args.quiet) {
    const skippedNote = args.id === null && result.skipped.length
      ? `; ${result.skipped.length} "####" heading(s) are not scenario blocks: ${result.skipped.map((s) => `${s.file}:${s.line} "${s.heading}"`).join(', ')}`
      : '';
    process.stdout.write(`scenario-lint: ${selected.length} block(s), ${rejected.length} rejected, ${rejected.reduce((n, b) => n + b.errors.length, 0)} error(s)${skippedNote}\n`);
  }
  return ok ? 0 : 1;
}

// Entry-point check on real paths: a symlinked path (a /var → /private/var alias, a linked checkout) must still run main().
const isMain = () => { try { return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url)); } catch { return false; } };
if (process.argv[1] && isMain()) {
  process.exitCode = main(process.argv.slice(2));
}
