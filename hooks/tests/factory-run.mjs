#!/usr/bin/env node
// factory-run.mjs — offline fixture runner for the factory gates (hooks/factory/*.sh).
//
// Usage: CLAUDE_PROJECT_DIR=hooks/tests/fixtures/factory-project [FACTORY_RULES=<rule file>] node hooks/tests/factory-run.mjs [<filter>]
//   CLAUDE_PROJECT_DIR — the project a non-temp case runs against; default (unset): the shipped fixture project
//                        hooks/tests/fixtures/factory-project/ (rule file = a copy of hooks/data/factory-rules.example.json,
//                        the spend list, stub specs; see references/factory-gates.md#running-the-cases). Inside a
//                        Claude Code session CLAUDE_PROJECT_DIR is usually set to the repo root: pass the fixture explicitly.
//   FACTORY_RULES      — the rule file (default <CLAUDE_PROJECT_DIR>/achilles-factory-rules.json); passed through to
//                        non-temp cases, and the source of the "achilles-factory-rules.json" copy key in temp cases.
//   <filter>           — run only the cases whose file name contains it.
//
// Each case is hooks/tests/cases/factory/<gate>.<name>.json:
//   { "input": {…PreToolUse payload…} | "<raw stdin string>",
//     "expect": "allow" | "deny",
//     "messageContains"?: [...],   deny: substrings of the deny reason (which must be the three-line shape)
//     "stderrContains"?: [...],    substrings of the gate's stderr
//     "warn"?: false | true,       allow: false = a clean allow (no "[factory] " line), true = must warn
//     "hook"?: "<gate>",           default: the file-name prefix before the first "." (a "common." case must set it)
//     "env"?: {…},                 overrides the gate's environment (e.g. { "PATH": "", "FACTORY_JQ": "/nonexistent" })
//     "cwd"?: "temp",              run against an empty temp project instead of CLAUDE_PROJECT_DIR, into which
//     "copy"?: ["<rel path>"],       these paths are copied from CLAUDE_PROJECT_DIR ("achilles-factory-rules.json"
//                                    comes from FACTORY_RULES when set), and
//     "write"?: {"<rel>": "<text>"}, these files are written; then
//     "stamp"?: "fresh" | "<hash>" process.evidence.stamp is written as { treeHash }: "fresh" = what the rule's
//                                    hashCommand prints in the temp project now; any other value verbatim.
//     "_comment"?: "…" }
// "{{ROOT}}" in any "input" or "env" string is replaced by the project directory the gate sees, and "{{JQ}}" by the
// jq the gates resolve ($FACTORY_JQ, else hooks/bin/jq, else jq on PATH) — the latter is what lets a case empty PATH
// to prove a gate's behaviour when grep/sed/tr are missing while still giving it a usable jq, e.g.
// "env": { "PATH": "", "FACTORY_JQ": "{{JQ}}" }. A temp case runs with FACTORY_RULES unset, so it reads the temp
// project's own rule file (or none). bash runs by absolute path.
// A case whose stderr carries a "[factory] " line counts as a warn (allow-with-warning) in the summary.
import { readdirSync, readFileSync, writeFileSync, mkdtempSync, mkdirSync, copyFileSync, rmSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const hooksDir = path.resolve(here, '..');
const casesDir = path.join(here, 'cases', 'factory');
const project = path.resolve(process.env.CLAUDE_PROJECT_DIR || path.join(here, 'fixtures', 'factory-project'));
if (!existsSync(project)) { console.error(`factory-run: fixture project ${project} not found (set CLAUDE_PROJECT_DIR)`); process.exit(2); }
const RULES_KEY = 'achilles-factory-rules.json';
const rulesFile = process.env.FACTORY_RULES ? path.resolve(project, process.env.FACTORY_RULES) : path.join(project, RULES_KEY);
const filter = process.argv[2] ?? '';
// The jq a gate would resolve, for cases that empty PATH on purpose (see "{{JQ}}" above).
const JQ_PATH = process.env.FACTORY_JQ
  ?? (existsSync(path.join(hooksDir, 'bin', 'jq')) ? path.join(hooksDir, 'bin', 'jq')
    : (spawnSync('/bin/sh', ['-c', 'command -v jq'], { encoding: 'utf8' }).stdout ?? '').trim());
const rows = [];
let failed = 0;

const subst = (v, root) =>
  typeof v === 'string' ? v.split('{{ROOT}}').join(root).split('{{JQ}}').join(JQ_PATH)
  : Array.isArray(v) ? v.map((x) => subst(x, root))
  : v && typeof v === 'object' ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, subst(x, root)]))
  : v;

function freshHash(root) {  // run process.evidence.hashCommand in the temp project, as the commit gate will
  const rule = JSON.parse(readFileSync(path.join(root, RULES_KEY), 'utf8')).rules['process.evidence'];
  const [cmd, ...args] = rule.hashCommand;
  const r = spawnSync(cmd === 'node' ? process.execPath : cmd, args, { cwd: root, encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`hashCommand failed: ${(r.stderr ?? '').trim().slice(0, 120)}`);
  return r.stdout.trim().split(/\s+/)[0];
}

for (const file of readdirSync(casesDir).filter((f) => f.endsWith('.json') && f.includes(filter)).sort()) {
  const name = file.replace(/\.json$/, '');
  const c = JSON.parse(readFileSync(path.join(casesDir, file), 'utf8'));
  const hook = c.hook ?? name.split('.')[0];
  const script = path.join(hooksDir, 'factory', `${hook}.sh`);
  const env = { ...process.env, ...(c.env ?? {}) };
  let root = project, tmp, r, problem = '';
  try {
    if (!existsSync(script)) throw new Error(`no gate ${hook}.sh (set "hook")`);
    if (c.cwd === 'temp') {
      tmp = root = mkdtempSync(path.join(os.tmpdir(), 'factory-gate-'));
      // copy/write keys must stay inside the temp project (a "../" key would touch the fixture project or the machine)
      const inside = (p) => { const t = path.resolve(tmp, p); if (!t.startsWith(tmp + path.sep)) throw new Error(`case path escapes the temp dir: ${p}`); return t; };
      for (const p of c.copy ?? []) {
        const t = inside(p); mkdirSync(path.dirname(t), { recursive: true });
        copyFileSync(p === RULES_KEY ? rulesFile : path.join(project, p), t);
      }
      for (const [p, body] of Object.entries(c.write ?? {})) { const t = inside(p); mkdirSync(path.dirname(t), { recursive: true }); writeFileSync(t, body); }
      if (c.stamp) {
        const rule = JSON.parse(readFileSync(path.join(tmp, RULES_KEY), 'utf8')).rules['process.evidence'];
        const t = inside(rule.stamp); mkdirSync(path.dirname(t), { recursive: true });
        writeFileSync(t, JSON.stringify({ treeHash: c.stamp === 'fresh' ? freshHash(tmp) : c.stamp, at: new Date().toISOString() }));
      }
      delete env.FACTORY_RULES;
      if (c.env && 'FACTORY_RULES' in c.env) env.FACTORY_RULES = c.env.FACTORY_RULES;
    } else {
      if (c.copy || c.write || c.stamp) throw new Error('"copy"/"write"/"stamp" need "cwd": "temp"');
      if (process.env.FACTORY_RULES && !(c.env && 'FACTORY_RULES' in c.env)) env.FACTORY_RULES = rulesFile;
    }
    const input = subst(c.input, root);
    // "env" is substituted too, so a case can hand the gate an absolute FACTORY_JQ while emptying PATH.
    r = spawnSync('/bin/bash', [script], { input: typeof input === 'string' ? input : JSON.stringify(input), encoding: 'utf8', cwd: root, env: { ...subst(env, root), CLAUDE_PROJECT_DIR: root }, timeout: 10000 });
  } catch (e) { problem = `case setup failed: ${e.message}`; r = { status: null, stdout: '', stderr: '' }; }
  finally { if (tmp) rmSync(tmp, { recursive: true, force: true }); }
  let decision = 'allow', reason = '';
  const out = (r.stdout ?? '').trim();
  if (out) {
    try {
      const j = JSON.parse(out);
      if (j?.hookSpecificOutput?.permissionDecision === 'deny') { decision = 'deny'; reason = j.hookSpecificOutput.permissionDecisionReason ?? ''; }
    } catch { problem ||= `stdout is not JSON: ${out.slice(0, 80)}`; }
  }
  if (r.status !== 0) problem ||= `exit ${r.status}${r.error ? ` (${r.error.message})` : ''}: ${(r.stderr ?? '').trim().slice(0, 120)}`;
  if (!problem && decision !== c.expect) problem = `expected ${c.expect}, got ${decision}${reason ? `: ${reason.split('\n')[0].slice(0, 100)}` : ''}`;
  if (!problem && decision === 'deny') {
    const lines = reason.split('\n');
    if (lines.length !== 3 || !/^\[[a-z.-]+\] /.test(lines[0]) || !lines[1].startsWith('→ Do: ') || !lines[2].startsWith('→ Why/how: '))
      problem = 'deny message is not the three-line [id] / → Do: / → Why/how: shape';
    const missing = (c.messageContains ?? []).filter((s) => !reason.includes(s));
    if (!problem && missing.length) problem = `message lacks ${missing.map((s) => JSON.stringify(s)).join(', ')}`;
  }
  const stderr = r.stderr ?? '';
  const lacking = (c.stderrContains ?? []).filter((x) => !stderr.includes(x));
  if (!problem && lacking.length) problem = `stderr lacks ${lacking.map((x) => JSON.stringify(x)).join(', ')}`;
  const warn = decision === 'allow' && /^\[factory\] /m.test(stderr);
  if (!problem && c.warn === false && warn) problem = `expected a clean allow, got allow-with-warning: ${stderr.trim().split('\n')[0].slice(0, 100)}`;
  if (!problem && c.warn === true && !warn) problem = 'expected an allow-with-warning ([factory] line on stderr)';
  if (problem) failed++;
  rows.push({ hook, case: name.slice(name.indexOf('.') + 1), expect: c.expect, got: warn ? 'allow (warn)' : decision, exit: r.status, result: problem ? `FAIL — ${problem}` : 'pass' });
}

const cols = ['hook', 'case', 'expect', 'got', 'exit', 'result'];
const w = Object.fromEntries(cols.map((k) => [k, Math.max(k.length, ...rows.map((x) => String(x[k]).length))]));
const line = (x) => cols.map((k) => String(x[k]).padEnd(w[k])).join(' | ');
console.log(line(Object.fromEntries(cols.map((k) => [k, k]))));
console.log(cols.map((k) => '-'.repeat(w[k])).join('-|-'));
rows.forEach((x) => console.log(line(x)));
const n = (e) => rows.filter((x) => x.expect === e).length;
const warns = rows.filter((x) => x.got === 'allow (warn)').length;
console.log(`\n${rows.length - failed}/${rows.length} cases passed (${n('allow')} allow, ${n('deny')} deny; ${warns} of the allows warned)`);
process.exit(failed || rows.length === 0 ? 1 : 0);
