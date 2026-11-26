#!/usr/bin/env node
// bin/spec-lint.mjs — the test-code lint of the test baseline (skills/achilles-orchestrator/references/test-baseline.md).
//
//   achilles-spec-lint [paths…] [--json] [--quiet] [--budget-ms <n>]
//
// Lints every in-scope spec and support file of the project (or only the given paths) against the mechanical
// rules the engine implements (bin/lib/spec-lint/rules/*.mjs). The project root is $CLAUDE_PROJECT_DIR, else
// the current directory; path arguments resolve against it. The Steps surface comes from the worktree's
// node_modules, else the main checkout's, else the snapshot shipped for the pinned framework version.
//
// It advises: nothing here is wired into a hook or refuses a workflow step.
//
// Exit 0 = no unwaived blocking finding; 1 = blocking findings; 2 = usage or configuration (including no Steps
// surface resolved); 3 = a file ran past the time budget (default 5000 ms per file). Messages have three lines:
// `[TB-<id>] <file>:<line> <test id>: <what>` / `→ Do: …` / `→ Why/how: <rulebook anchor>`.
// `--json` prints the report of schemas/spec-lint-report.schema.json.
import { existsSync, realpathSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { projectRoot } from './lib/project-root.mjs';
import { lintProject, BudgetError, DEFAULT_FILE_BUDGET_MS, RULEBOOK } from './lib/spec-lint/engine.mjs';
import { SurfaceError } from './lib/spec-lint/surface.mjs';

const USAGE = 'achilles-spec-lint [paths…] [--json] [--quiet] [--budget-ms <n>]';
const DOC = RULEBOOK;

const fail = (code, what, todo) => {
  process.stderr.write(`[spec-lint] ${what}\n→ Do: ${todo}\n→ Why/how: ${DOC}\n`);
  return code;
};

function format(f) {
  const where = f.line ? `${f.file}:${f.line}` : f.file || 'project';
  const id = f.test && f.test.id ? ` ${f.test.id}` : '';
  const sev = f.severity === 'advisory' && !/advisory/.test(f.message) ? ' (advisory)' : '';
  return `[${f.rule}] ${where}${id}: ${f.message}${sev}\n→ Do: ${f.do}\n→ Why/how: ${f.why}`;
}

function main(argv) {
  const args = { paths: [], json: false, quiet: false, budgetMs: DEFAULT_FILE_BUDGET_MS };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--json') args.json = true;
    else if (a === '--quiet') args.quiet = true;
    else if (a === '--budget-ms' || a.startsWith('--budget-ms=')) {
      const v = a.includes('=') ? a.slice(a.indexOf('=') + 1) : argv[++i];
      if (!/^\d+$/.test(v ?? '')) return fail(2, `--budget-ms needs a number of milliseconds (got ${JSON.stringify(v)})`, `use ${USAGE}`);
      args.budgetMs = Number(v);
    } else if (a.startsWith('-')) return fail(2, `unknown option ${a}`, `use ${USAGE}`);
    else args.paths.push(a);
  }
  const root = projectRoot();
  for (const p of args.paths) {
    if (!existsSync(path.resolve(root, p))) return fail(2, `${p} not found under ${root}`, 'pass existing spec or support files, or no paths to lint the whole suite');
  }
  let report;
  try {
    report = lintProject({ root, paths: args.paths.length ? args.paths : null, budgetMs: args.budgetMs });
  } catch (e) {
    if (e instanceof SurfaceError) return fail(2, `spec lint cannot run: ${e.message}`, 'install the project dependencies (npm ci), or pin @civitas-cerebrum/element-interactions in package.json to a published release');
    if (e instanceof BudgetError) return fail(3, `${e.message}`, 'split the file, or raise --budget-ms when the machine is slow');
    throw e;
  }
  if (args.json) {
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    return report.ok ? 0 : 1;
  }
  const shown = report.findings.filter((f) => !f.waived);
  const out = [...shown.filter((f) => f.severity === 'blocking'), ...shown.filter((f) => f.severity !== 'blocking'), ...report.project].map(format);
  if (out.length) process.stderr.write(`${out.join('\n')}\n`);
  if (!args.quiet) {
    const s = report.summary;
    process.stdout.write(`spec-lint: ${s.files} file(s), ${s.blocking} blocking, ${s.advisory} advisory, ${s.waived} waived; Steps surface ${report.stepsSurface.version} (${report.stepsSurface.source}); ${report.timing.ms} ms\n`);
  }
  return report.ok ? 0 : 1;
}

const isMain = () => { try { return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url)); } catch { return false; } };
if (process.argv[1] && isMain()) process.exitCode = main(process.argv.slice(2));
