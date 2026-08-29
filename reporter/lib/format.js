'use strict';
// format.js — the end-of-run summary. Pure: takes a model, returns a string.
//
// What `list` does not say, and this does:
//   - flaky is its own section, never folded into failures;
//   - each failure carries what the local ledger knows about it, so "failed 6
//     of the last 10 runs" and "first failure" read differently;
//   - the archived evidence path sits under the failure that produced it;
//   - the slowest tests are named, with the delta against their own median.

const ANSI = {
  reset: '[0m',
  dim: '[2m',
  bold: '[1m',
  red: '[31m',
  yellow: '[33m',
  green: '[32m',
};

/**
 * ANSI is emitted only into a colour-capable terminal the user has not opted
 * out of. Piping, redirecting, NO_COLOR and TERM=dumb all mean plain text.
 */
function colorEnabled(stream, env) {
  const e = env || process.env;
  if (e.FORCE_COLOR && e.FORCE_COLOR !== '0') return true;
  if (e.NO_COLOR !== undefined && e.NO_COLOR !== '') return false;
  if (e.TERM === 'dumb') return false;
  return Boolean(stream && stream.isTTY);
}

function painter(enabled) {
  return (code, text) => (enabled ? `${ANSI[code]}${text}${ANSI.reset}` : text);
}

function duration(ms) {
  if (typeof ms !== 'number' || !Number.isFinite(ms)) return '';
  if (ms < 1000) return `${Math.round(ms)}ms`;
  if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`;
  const mins = Math.floor(ms / 60000);
  return `${mins}m${Math.round((ms % 60000) / 1000)}s`;
}

/**
 * What the local ledger knows about this test, in one line. "failed 6 of last
 * 10 runs" and "no prior local runs" are different signals and the reader is
 * making a different decision in each case.
 */
function historyLine(agg) {
  if (!agg || agg.runs === 0) return 'no prior local runs';
  const of = `of last ${agg.runs} run${agg.runs === 1 ? '' : 's'}`;
  const parts = [];
  if (agg.fails > 0 && agg.flakes > 0) parts.push(`${agg.fails} failed, ${agg.flakes} flaky ${of}`);
  else if (agg.fails > 0) parts.push(`failed ${agg.fails} ${of}`);
  else if (agg.flakes > 0) parts.push(`flaky in ${agg.flakes} ${of}`);
  else parts.push(`clean ${of}`);

  if (agg.fails + agg.flakes > 0) {
    if (agg.runsSincePass === null) parts.push('no clean run recorded');
    else if (agg.runsSincePass > 0) parts.push(`last clean run ${agg.runsSincePass} ago`);
  }
  if (agg.lastChange) parts.push(`${agg.lastChange.from} → ${agg.lastChange.to} ${agg.lastChange.runsAgo === 0 ? 'last run' : `${agg.lastChange.runsAgo} runs ago`}`);
  return parts.join(' · ');
}

/**
 * @param {{counts:object, failed:array, flaky:array, knownDefectPassed:string[],
 *          slowest:array, durationMs:number, evidenceDir:string|null,
 *          notes:string[]}} model
 */
function render(model, opts) {
  const o = opts || {};
  const width = Math.max(40, Math.min(o.width || 72, 100));
  const c = painter(Boolean(o.color));
  const out = [];
  const rule = '─'.repeat(Math.max(1, width - 12));

  out.push('');
  out.push(c('dim', `── ${c('bold', 'achilles')} ${rule}`));

  const counts = model.counts || {};
  const tally = [];
  if (counts.passed) tally.push(c('green', `${counts.passed} passed`));
  if (counts.flaky) tally.push(c('yellow', `${counts.flaky} flaky`));
  if (counts.failed) tally.push(c('red', `${counts.failed} failed`));
  if (counts.skipped) tally.push(`${counts.skipped} skipped`);
  if (tally.length === 0) tally.push('no tests ran');
  out.push(`   ${tally.join(c('dim', ' · '))}${model.durationMs ? c('dim', `   in ${duration(model.durationMs)}`) : ''}`);

  // Warnings: printed only when there is something to warn about — a clean
  // run carries no warning block at all. Known defects are red by design
  // (each maps to a filed ticket), flaky passes hide a failing attempt, and
  // a PASS under @known-defect is the anomaly test-identity.md §2 names:
  // never silently green.
  const warnings = [];
  if (counts.knownDefect) {
    warnings.push(`${c('yellow', `⚠ known defects: ${counts.knownDefect}`)}${c('dim', ' (red by design — each maps to a filed ticket)')}`);
  }
  if (counts.flaky) {
    warnings.push(`${c('yellow', `⚠ flaky: ${counts.flaky}`)}${c('dim', ' (passed only on retry — the failing attempts are listed below)')}`);
  }
  for (const title of model.knownDefectPassed || []) {
    warnings.push(c('yellow', `⚠ passed despite @known-defect: ${title}`));
    warnings.push(`  ${c('dim', 'defect fixed (drop the tag) or test flaky (retag @flaky) — see achilles-protocol/references/test-identity.md §2')}`);
  }
  if (warnings.length) {
    out.push('');
    for (const w of warnings) out.push(`   ${w}`);
  }

  if (model.failed && model.failed.length) {
    out.push('');
    out.push(`   ${c('red', 'failed')}`);
    for (const t of model.failed) {
      const heel = t.heel ? `${c('dim', ' · ')}${c('red', 'heel')}` : '';
      out.push(`     ${c('red', '✗')} ${t.title}${heel}`);
      out.push(`       ${c('dim', historyLine(t.history))}`);
      for (const file of (t.evidence || []).slice(0, 3)) out.push(`       ${c('dim', file)}`);
    }
  }

  if (model.flaky && model.flaky.length) {
    out.push('');
    out.push(`   ${c('yellow', 'flaky')}${c('dim', '  — passed on retry; the failing attempt is archived')}`);
    for (const t of model.flaky) {
      out.push(`     ${c('yellow', '~')} ${t.title}${c('dim', ` · passed on attempt ${t.passedOnAttempt + 1} of ${t.attempts}`)}`);
      out.push(`       ${c('dim', historyLine(t.history))}`);
      for (const file of (t.evidence || []).slice(0, 2)) out.push(`       ${c('dim', file)}`);
    }
  }

  if (model.slowest && model.slowest.length) {
    out.push('');
    out.push(`   ${c('dim', 'slowest')}`);
    for (const t of model.slowest) {
      const delta = typeof t.deltaPct === 'number' && Math.abs(t.deltaPct) >= 20
        ? c('dim', `  (${t.deltaPct > 0 ? '+' : ''}${t.deltaPct}% vs median)`)
        : '';
      out.push(`     ${duration(t.ms).padStart(7)}  ${t.title}${delta}`);
    }
  }

  if (model.evidenceDir) {
    out.push('');
    out.push(`   ${c('dim', 'evidence')}  ${model.evidenceDir}`);
  }
  for (const note of model.notes || []) out.push(`   ${c('dim', note)}`);
  out.push('');
  return out.join('\n');
}

module.exports = { render, historyLine, duration, colorEnabled, painter, ANSI };
