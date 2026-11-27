#!/usr/bin/env node
// bin/spec-lint.mjs — the test-code lint of the test baseline (skills/achilles-orchestrator/references/test-baseline.md).
//
//   achilles-spec-lint [paths…] [--json] [--quiet] [--budget-ms <n>]
//                      [--staged | --base <ref>] [--suite] [--stdin] [--id-index [--check]]
//
// Lints every in-scope spec and support file of the project (or only the given paths) against the mechanical
// rules the engine implements (bin/lib/spec-lint/rules/*.mjs). The project root is $CLAUDE_PROJECT_DIR, else
// the current directory; path arguments resolve against it. The Steps surface comes from the worktree's
// node_modules, else a workspace root's above it (hoisted), else the main checkout's, else the snapshot shipped
// for the pinned framework version (the project's own pin, else its workspace root's).
//
//   --staged          lint the staged change (index against HEAD): only the changed files, and only findings
//                     in a touched test, describe or file scope count; the others are reported as legacy
//   --base <ref>      the same against the merge-base of HEAD and <ref> (working tree and untracked files)
//   --suite           ids across the whole suite (TB-I2), and the support modules the linted specs import are
//                     linted too (their findings carry `followedFrom`)
//   --stdin           write mode: reads {"file","before","after"} and reports only the findings new in "after"
//   --id-index        writes the suite's id index (tests/e2e/docs/test-ids.md); with --check, compares instead
//
// The compliance baseline (tests/compliance-baseline.json, lib/spec-lint/commands.mjs):
//   --init-baseline   records the baseline from HEAD, pins the id pattern, installs the pre-commit check
//   --update-baseline lowers the recorded counts to the content (never raises); --ruleset-upgrade also records
//                     the rules a newer ruleset added or promoted
//   --ratchet --base <ref>  the change against the baseline at the merge-base (touched tests clean, untouched
//                     counts not above it, the change's own copy only lowered, never deleted); --ci also lists
//                     deleted test ids and waiver changes
//   --pre-commit      the git hook entry point: the same on the index against HEAD's baseline; when it cannot
//                     run it warns and exits 0
//   --install-hook    installs the pre-commit check alone (in every other clone). Exit 0 when it is installed or
//                     already was, also under a hooks path outside the work tree (a global or system setting, a
//                     shared directory): nothing is written there, the committed `.githooks/achilles-pre-commit`
//                     is written and the one line to add to the shared pre-commit is printed; exit 2 when it
//                     cannot be installed (a symbolic link on the way, dormant hooks not named with
//                     --activate-hooks, the repository's check script already serving another project)
//
// Nothing here is wired into an Achilles hook or refuses a workflow step; the project's own pre-commit hook
// and CI run these commands.
//
// Exit 0 = no unwaived blocking finding (in touched code, with --staged / --base); 1 = blocking findings, a
// ratchet or baseline-file violation, or an id index that is out of date; 2 = usage or configuration (including no Steps surface resolved, no git);
// 3 = a file ran past the time budget (default 5000 ms per file). Messages have three lines:
// `[TB-<id>] <file>:<line> <test id>: <what>` / `→ Do: …` / `→ Why/how: <rulebook anchor>`.
// `--json` prints the report of schemas/spec-lint-report.schema.json.
import { existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { projectRoot } from './lib/project-root.mjs';
import { lintProject, lintWrite, BudgetError, DEFAULT_FILE_BUDGET_MS, RULEBOOK } from './lib/spec-lint/engine.mjs';
import { SurfaceError } from './lib/spec-lint/surface.mjs';
import { stagedChange, baseChange, ChangeError } from './lib/spec-lint/touched.mjs';
import { renderIndex, indexIds } from './lib/spec-lint/rules/identity.mjs';
import { INDEX_FILE } from './lib/spec-lint/ids.mjs';
import { initBaseline, updateBaselineCmd, ratchetCmd, preCommit, installHookCmd, UsageError, HookError } from './lib/spec-lint/commands.mjs';

const USAGE = 'achilles-spec-lint [paths…] [--json] [--quiet] [--budget-ms <n>] [--staged | --base <ref>] [--suite] [--stdin] [--id-index [--check]] | --init-baseline | --update-baseline [--ruleset-upgrade] | --ratchet --base <ref> [--ci] | --ci --base <ref> | --pre-commit | --install-hook [--activate-hooks <names>]';
const DOC = RULEBOOK;

const fail = (code, what, todo) => {
  process.stderr.write(`[spec-lint] ${what}\n→ Do: ${todo}\n→ Why/how: ${DOC}\n`);
  return code;
};

function format(f) {
  const where = f.line ? `${f.file}:${f.line}` : f.file || 'project';
  const id = f.test && f.test.id ? ` ${f.test.id}` : '';
  const sev = f.severity === 'advisory' && !/advisory/.test(f.message) ? ' (advisory)' : '';
  const legacy = f.touched === false && f.severity === 'blocking' ? ' (legacy: not in a touched test, not charged to this change)' : '';
  const from = f.followedFrom ? ` (reached from ${f.followedFrom})` : '';
  return `[${f.rule}] ${where}${id}: ${f.message}${sev}${legacy}${from}\n→ Do: ${f.do}\n→ Why/how: ${f.why}`;
}

function parseArgs(argv) {
  const args = { paths: [], json: false, quiet: false, budgetMs: DEFAULT_FILE_BUDGET_MS, staged: false, base: null, suite: false, stdin: false, idIndex: false, check: false, init: false, update: false, upgrade: false, ratchet: false, ci: false, preCommit: false, installHook: false, activate: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const value = () => (a.includes('=') ? a.slice(a.indexOf('=') + 1) : argv[++i]);
    if (a === '--json') args.json = true;
    else if (a === '--quiet') args.quiet = true;
    else if (a === '--staged') args.staged = true;
    else if (a === '--suite') args.suite = true;
    else if (a === '--stdin') args.stdin = true;
    else if (a === '--id-index') args.idIndex = true;
    else if (a === '--check') args.check = true;
    else if (a === '--init-baseline') args.init = true;
    else if (a === '--update-baseline') args.update = true;
    else if (a === '--ruleset-upgrade') args.upgrade = true;
    else if (a === '--ratchet') args.ratchet = true;
    else if (a === '--ci') { args.ci = true; args.ratchet = true; }
    else if (a === '--pre-commit') args.preCommit = true;
    else if (a === '--install-hook') args.installHook = true;
    else if (a === '--activate-hooks' || a.startsWith('--activate-hooks=')) {
      const v = value();
      if (!v || v.startsWith('-')) return { error: '--activate-hooks needs the hook names, comma-separated (e.g. commit-msg,pre-push)' };
      args.activate = v.split(",").map((x) => x.trim()).filter(Boolean);
    }
    else if (a === '--base' || a.startsWith('--base=')) {
      args.base = value();
      if (!args.base || args.base.startsWith('-')) return { error: `--base needs a git ref (got ${JSON.stringify(args.base)})` };
    } else if (a === '--budget-ms' || a.startsWith('--budget-ms=')) {
      const v = value();
      if (!/^\d+$/.test(v ?? '')) return { error: `--budget-ms needs a number of milliseconds (got ${JSON.stringify(v)})` };
      args.budgetMs = Number(v);
    } else if (a.startsWith('-')) return { error: `unknown option ${a}` };
    else args.paths.push(a);
  }
  if (args.staged && args.base) return { error: '--staged and --base are two ways to name the change: pass one' };
  if (args.stdin && (args.staged || args.base || args.paths.length || args.idIndex)) return { error: '--stdin lints one write; it takes no paths, --staged, --base or --id-index' };
  if (args.check && !args.idIndex) return { error: '--check goes with --id-index' };
  const modes = ['init', 'update', 'ratchet', 'preCommit', 'installHook'].filter((m) => args[m]);
  if (args.upgrade && !args.update) return { error: '--ruleset-upgrade goes with --update-baseline' };
  if (args.activate.length && !args.init && !args.installHook) return { error: '--activate-hooks goes with --init-baseline or --install-hook' };
  if (modes.length > 1) return { error: 'pass one of --init-baseline, --update-baseline, --ratchet (or --ci), --pre-commit and --install-hook' };
  if (modes.length) {
    if (args.paths.length || args.stdin || args.idIndex || args.suite || args.staged) return { error: 'the baseline commands lint the whole suite: they take no paths, --stdin, --id-index, --suite or --staged' };
    if (args.ratchet && !args.base) return { error: `${args.ci ? '--ci' : '--ratchet'} needs --base <ref> (the branch the change merges into, e.g. origin/main)` };
    if (!args.ratchet && args.base) return { error: '--base goes with --ratchet here; the other baseline commands take no ref' };
    args.mode = modes[0];
  }
  return args;
}

function readStdin() {
  try { return readFileSync(0, 'utf8'); } catch { return ''; }
}

function print(report, args) {
  if (args.json) { process.stdout.write(`${JSON.stringify(report, null, 2)}\n`); return; }
  const shown = report.findings.filter((f) => !f.waived);
  const charged = (f) => f.severity === 'blocking' && f.touched !== false;
  const out = [...shown.filter(charged), ...shown.filter((f) => !charged(f) && f.severity === 'blocking'), ...shown.filter((f) => f.severity !== 'blocking'), ...report.project].map(format);
  if (out.length) process.stderr.write(`${out.join('\n')}\n`);
  if (!args.quiet) {
    const s = report.summary;
    const legacy = s.legacy !== undefined ? `, ${s.legacy} legacy` : '';
    const change = report.change ? `; change: ${report.change.from}` : '';
    process.stdout.write(`spec-lint: ${s.files} file(s), ${s.blocking} blocking, ${s.advisory} advisory, ${s.waived} waived${legacy}; Steps surface ${report.stepsSurface.version} (${report.stepsSurface.source})${change}; ${report.timing.ms} ms\n`);
  }
}

function main(argv) {
  const args = parseArgs(argv);
  if (args.error) return fail(2, args.error, `use ${USAGE}`);
  const root = projectRoot();
  for (const p of args.paths) {
    if (!existsSync(path.resolve(root, p))) return fail(2, `${p} not found under ${root}`, 'pass existing spec or support files, or no paths to lint the whole suite');
  }
  if (args.mode) return baselineMode(root, args);
  try {
    if (args.stdin) {
      let input;
      try { input = JSON.parse(readStdin()); } catch (e) { return fail(2, `--stdin needs a JSON object {"file","before","after"} (${e.message})`, 'pipe the write as JSON on standard input'); }
      if (!input || typeof input.file !== 'string' || typeof input.after !== 'string') return fail(2, '--stdin needs "file" and "after" strings ("before" is null for a new file)', 'pipe {"file":"tests/e2e/a.spec.ts","before":null,"after":"…"}');
      const report = lintWrite({ root, file: input.file, before: input.before ?? null, after: input.after, budgetMs: args.budgetMs });
      print(report, args);
      return report.ok ? 0 : 1;
    }
    let change = null;
    if (args.staged) change = stagedChange(root);
    else if (args.base) change = baseChange(root, args.base);
    const suite = args.suite || args.idIndex;
    const report = lintProject({ root, paths: args.paths.length ? args.paths : null, budgetMs: args.budgetMs, change, suite });
    if (args.idIndex) return idIndex(root, report, args);
    print(report, args);
    return report.ok ? 0 : 1;
  } catch (e) {
    if (e instanceof SurfaceError) return fail(2, `spec lint cannot run: ${e.message}`, 'install the project dependencies (npm ci), or pin @civitas-cerebrum/element-interactions in package.json to a published release');
    if (e instanceof BudgetError) return fail(3, `${e.message}`, 'split the file, or raise --budget-ms when the machine is slow');
    if (e instanceof ChangeError) return fail(2, `the change cannot be read: ${e.message}`, 'run inside the git work tree, and name a ref that exists (git fetch it first)');
    throw e;
  }
}

/** The baseline commands: their own report (`--json`) or lines; exit 0, 1, 2 or 3. */
function baselineMode(root, args) {
  const lines = { out: [], err: [] };
  const io = { out: (s) => lines.out.push(s), err: (s) => lines.err.push(s), budgetMs: args.budgetMs, activate: args.activate };
  const flush = (r) => {
    if (lines.err.length) process.stderr.write(`${lines.err.join('\n')}\n`);
    // time since this process started (module loading included): the figure the commit-gate budget is about
    if (args.json) process.stdout.write(`${JSON.stringify({ ...r.report, elapsedMs: Math.round(performance.now()) }, null, 2)}\n`);
    else if (!args.quiet && lines.out.length) process.stdout.write(`${lines.out.join('\n')}\n`);
    return r.code;
  };
  if (args.mode === 'preCommit') return flush(preCommit(root, io));
  try {
    if (args.mode === 'init') return flush(initBaseline(root, io));
    if (args.mode === 'installHook') return flush(installHookCmd(root, io));
    if (args.mode === 'update') return flush(updateBaselineCmd(root, { ...io, upgrade: args.upgrade }));
    return flush(ratchetCmd(root, { ...io, base: args.base, ci: args.ci }));
  } catch (e) {
    if (lines.err.length) process.stderr.write(`${lines.err.join('\n')}\n`);
    if (e instanceof HookError) return fail(2, `the pre-commit check was not installed: ${e.message}`, e.todo || 'fix the hooks setup as the message says and install again; CI still checks every change');
    if (e instanceof UsageError) return fail(2, e.message, args.mode === 'init' ? 'see the message; the baseline is recorded once per project' : `use ${USAGE}`);
    if (e instanceof SurfaceError) return fail(2, `spec lint cannot run: ${e.message}`, 'install the project dependencies (npm ci), or pin @civitas-cerebrum/element-interactions in package.json to a published release');
    if (e instanceof BudgetError) return fail(3, `${e.message}`, 'split the file, or raise --budget-ms when the machine is slow');
    if (e instanceof ChangeError) return fail(2, `the change cannot be read: ${e.message}`, 'run inside the git work tree, and name a ref that exists (git fetch it first)');
    if (e && typeof e.status === 'number' && e.stderr !== undefined) return fail(2, `git failed: ${String(e.stderr || e.message).trim().split('\n')[0]}`, 'run inside the git work tree with at least one commit');
    throw e;
  }
}

/** --id-index: write (or with --check, compare) the suite's id index. */
function idIndex(root, report, args) {
  const ids = report.ids || [];
  const abs = path.join(root, INDEX_FILE);
  const before = existsSync(abs) ? indexIds(readFileSync(abs, 'utf8')) : null;
  const inUse = new Set(ids.map((x) => x.id));
  // an id listed before and no longer used is retired; retired ids stay listed
  const retired = before ? [...before.retired, ...[...before.active].filter((x) => !inUse.has(x))] : [];
  const text = renderIndex(ids, retired);
  const dupes = report.findings.filter((f) => f.rule === 'TB-I2' && /also used by/.test(f.message));
  if (args.check) {
    const listed = before ? before.active : null;
    const missing = listed ? [...inUse].filter((x) => !listed.has(x) && !before.retired.has(x)).sort() : [...inUse].sort();
    const stale = listed ? [...listed].filter((x) => !inUse.has(x)).sort() : [];
    const reused = before ? [...inUse].filter((x) => before.retired.has(x)).sort() : [];
    const upToDate = !!listed && !missing.length && !stale.length && !reused.length;
    const list = (xs) => `${xs.slice(0, 10).join(', ')}${xs.length > 10 ? ', …' : ''}`;
    if (args.json) process.stdout.write(`${JSON.stringify({ index: INDEX_FILE, exists: !!listed, upToDate, ids: inUse.size, missing, stale, reused, duplicates: dupes.map((f) => ({ file: f.file, line: f.line, message: f.message })) }, null, 2)}\n`);
    else {
      if (!upToDate) process.stderr.write(`[TB-I2] ${INDEX_FILE}: ${!listed ? 'the id index does not exist' : `the id index is out of date${missing.length ? `; not listed: ${list(missing)}` : ''}${stale.length ? `; listed but not in use (retire them): ${list(stale)}` : ''}${reused.length ? `; retired ids in use again: ${list(reused)}` : ''}`}\n→ Do: ${reused.length ? 'give the reused cases fresh ids, then ' : ''}run \`achilles-spec-lint --id-index\` and commit the index with the tests\n→ Why/how: ${RULEBOOK}#tb-i2\n`);
      for (const f of dupes) process.stderr.write(`${format(f)}\n`);
      if (!args.quiet) process.stdout.write(`spec-lint: id index ${upToDate ? 'up to date' : 'out of date'}, ${inUse.size} id(s), ${dupes.length} duplicate(s)\n`);
    }
    return upToDate && !dupes.length ? 0 : 1;
  }
  mkdirSync(path.dirname(abs), { recursive: true });
  writeFileSync(abs, text);
  for (const f of dupes) process.stderr.write(`${format(f)}\n`);
  if (args.json) process.stdout.write(`${JSON.stringify({ index: INDEX_FILE, written: true, ids: ids.length, duplicates: dupes.length }, null, 2)}\n`);
  else if (!args.quiet) process.stdout.write(`spec-lint: wrote ${INDEX_FILE} (${ids.length} id(s)${dupes.length ? `, ${dupes.length} duplicate(s) to fix` : ''})\n`);
  return dupes.length ? 1 : 0;
}

const isMain = () => { try { return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url)); } catch { return false; } };
if (process.argv[1] && isMain()) process.exitCode = main(process.argv.slice(2));
