// spend-classify.cjs — helper of hooks/factory/spend-gate.sh (rule spend.opt-in).
//
// argv: <command> <projectRoot> <cwd> <rules.json path>
// Reads the spend.opt-in rule (list, optInEnv, optInFlag, wrapper, spendProjects, spendScripts) and the list file,
// then prints the first "what happened" sentence of a deny, or nothing. Exit 2 = the rule or the list is unusable
// (the gate turns that into an allow-with-warning).
//
// Quote-aware: the command is split into segments at unquoted && || ; | & and newlines, and each segment into
// tokens honouring '…', "…" and \ escapes. Each segment is judged on its own: <optInEnv>=1 as a leading assignment
// of a `playwright test` / `npm run <spendScript>` segment, or <optInFlag> inside a <wrapper> segment, opts THAT
// segment in — nothing in another segment counts (`export X=1; …` does not opt the next segment in).
// Nested commands (one level): `bash|sh|zsh [-opts]c '<string>'` and `eval '<string>'` are classified as commands
// of their own (the outer segment's leading assignments are inherited, as the shell would). A spec argument or
// --project value that holds a shell expansion ($VAR, ${…}, $(…), `…`) cannot be judged → deny, asking for a
// literal path.
'use strict';
const fs = require('fs');
const path = require('path');
const [command, root, cwd, rulesFile] = process.argv.slice(2);

const fail = (msg) => { process.stderr.write(`${msg}\n`); process.exit(2); };
let rule;
try { rule = JSON.parse(fs.readFileSync(rulesFile, 'utf8')).rules['spend.opt-in']; } catch (e) { fail(`rule file unreadable: ${e.message}`); }
if (!rule || !rule.list || !rule.optInEnv || !rule.optInFlag) fail('spend.opt-in list/optInEnv/optInFlag missing');
const listFile = rule.list;
let listed;
try { listed = JSON.parse(fs.readFileSync(path.join(root, listFile), 'utf8')).specs; } catch (e) { fail(`${listFile} missing or not JSON`); }
if (!Array.isArray(listed)) fail(`${listFile} has no "specs" array`);
listed = listed.filter((e) => typeof e === 'string' && e).map((e) => path.normalize(e));
const envName = rule.optInEnv, flag = rule.optInFlag;
const wrapper = rule.wrapper ? path.basename(rule.wrapper) : null;
const spendProjects = new Set(rule.spendProjects ?? []);
const spendScripts = new Set(rule.spendScripts ?? []);

function segments(s) {
  const segs = []; let toks = [], tok = '', has = false, q = null;
  const endTok = () => { if (has) toks.push(tok); tok = ''; has = false; };
  const endSeg = () => { endTok(); if (toks.length) segs.push(toks); toks = []; };
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q === "'") { if (c === "'") q = null; else tok += c; continue; }
    if (q === '"') { if (c === '"') q = null; else if (c === '\\' && i + 1 < s.length && '"\\$`'.includes(s[i + 1])) tok += s[++i]; else tok += c; continue; }
    if (c === "'" || c === '"') { q = c; has = true; continue; }
    if (c === '\\') { if (i + 1 < s.length) { if (s[i + 1] !== '\n') { tok += s[i + 1]; has = true; } i++; } continue; }
    if (c === ';' || c === '|' || c === '&' || c === '\n') { endSeg(); continue; }
    if (c === ' ' || c === '\t') { endTok(); continue; }
    tok += c; has = true;
  }
  endSeg();
  return segs;
}

// Playwright options that take a separate value (their value is never a file argument).
const VALUE_OPTS = new Set(['-c', '--config', '-g', '--grep', '-G', '--grep-invert', '--project', '--reporter', '--output',
  '--workers', '-j', '--retries', '--repeat-each', '--timeout', '--max-failures', '-x', '--shard', '--trace', '--test-list',
  '--test-list-invert', '--update-snapshots', '-u', '--tsconfig', '--global-timeout']);

function normArg(a) {
  a = a.replace(/:\d+(:\d+)?$/, '');               // checkout-order.spec.ts:42[:7] → checkout-order.spec.ts
  if (!a) return '';
  const abs = path.isAbsolute(a) ? path.normalize(a) : null;
  if (abs) { const rel = path.relative(root, abs); return rel.startsWith('..') ? abs : rel || '.'; }
  if (a.includes('..')) { const rel = path.relative(root, path.resolve(cwd || root, a)); if (!rel.startsWith('..')) return rel || '.'; }
  return path.normalize(a);
}
// Playwright file filters are path regexes matched as substrings: an argument hits a listed spec when it is part
// of the listed path (basename, stem, directory) or contains it.
const hits = (a) => listed.filter((e) => e.includes(a) || a.includes(e));

const say = (msg) => { console.log(msg); process.exit(0); };
const SHELLS = /(^|\/)(bash|sh|zsh)$/;
const EXPANSION = /\$|`/;

function classify(cmd, depth, inherited) {
  for (const toks of segments(cmd)) {
    let i = 0; const env = { ...inherited };
    while (i < toks.length && (/^[A-Za-z_][A-Za-z0-9_]*=/.test(toks[i]) || toks[i] === 'env')) {
      if (toks[i] !== 'env') { const k = toks[i].slice(0, toks[i].indexOf('=')); env[k] = toks[i].slice(k.length + 1); }
      i++;
    }
    const envOk = env[envName] === '1';
    const rest = toks.slice(i);
    if (depth === 0 && rest.length > 1) {
      // bash -c '<cmd>' / sh -lc "<cmd>" / zsh -c … : the first -…c… option takes the command string.
      if (SHELLS.test(rest[0])) {
        const ci = rest.findIndex((t, j) => j > 0 && /^-[A-Za-z]*c[A-Za-z]*$/.test(t));
        if (ci > 0 && rest[ci + 1] !== undefined) { classify(rest[ci + 1], depth + 1, env); continue; }
      }
      if (rest[0] === 'eval') { classify(rest.slice(1).join(' '), depth + 1, env); continue; }
    }
    let mode = null, args = [];
    const pw = rest.findIndex((t, j) => /(^|\/)playwright$/.test(t) && rest[j + 1] === 'test');
    const wr = wrapper ? rest.findIndex((t) => path.basename(t) === wrapper) : -1;
    if (pw >= 0) { mode = 'pw'; args = rest.slice(pw + 2); }
    else if (wr >= 0) { mode = 'wrapper'; args = rest.slice(wr + 1); }
    else if (rest[0] === 'npm' && rest[1] === 'run' && spendScripts.has(rest[2] ?? '')) {
      if (!envOk) say(`Command runs a whole spend-incurring project (npm run ${rest[2]}), which includes the specs in ${listFile}.`);
      continue;
    } else continue;
    if (mode === 'pw' && envOk) continue;
    if (mode === 'wrapper' && args.includes(flag)) continue;
    const files = [], projects = []; let expect = null;
    for (const t of args) {
      if (expect) { if (expect === '--project') projects.push(t); expect = null; continue; }
      if (t.startsWith('--project=')) projects.push(t.slice(10));
      else if (t.startsWith('-')) { if (!t.includes('=') && VALUE_OPTS.has(t)) expect = t; }
      else files.push(t);
    }
    const optIn = mode === 'pw' ? `${envName}=1` : flag;
    for (const f of files) {
      const a = normArg(f); if (!a) continue;
      const h = hits(a);
      if (h.length) say(`Command runs the spend-incurring spec ${path.basename(h[0])} (listed in ${listFile}) without ${optIn}.`);
    }
    const unknown = [...files, ...projects].find((t) => EXPANSION.test(t));
    if (unknown) say(`Command passes ${unknown} (a shell expansion) as a spec or project argument; the gate cannot tell whether it names a spend-incurring spec in ${listFile} — use a literal path (or ${optIn} for an owner-approved run).`);
    if (mode === 'pw' && files.length === 0) {
      if (projects.length === 0) say(`\`playwright test\` with no --project and no file argument runs every project, including the spend-incurring specs in ${listFile}.`);
      const p = projects.find((x) => spendProjects.has(x));
      if (p) say(`\`playwright test --project=${p}\` with no file argument would run the spend-incurring specs in ${listFile}.`);
    }
  }
}

classify(command, 0, {});
