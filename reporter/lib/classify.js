'use strict';
// classify.js — pure outcome logic. No I/O, no Playwright imports.
//
// Playwright reports one TestResult per ATTEMPT. The distinction this file
// exists to preserve is flaky vs failed: a test whose first attempt failed and
// whose retry passed is a different problem from one that never passed, and
// the two need different reactions. Everything here is a function of the
// attempt list plus the test's expected status, so it is directly testable.

const OUTCOMES = { PASSED: 'passed', FAILED: 'failed', FLAKY: 'flaky', SKIPPED: 'skipped', EXPECTED_FAILURE: 'expectedFailure' };

/**
 * @param {{status: string, retry: number}[]} attempts  in attempt order
 * @param {string} expectedStatus                       test.expectedStatus
 */
function classify(attempts, expectedStatus) {
  const list = (attempts || []).slice().sort((a, b) => (a.retry || 0) - (b.retry || 0));
  if (list.length === 0) return OUTCOMES.SKIPPED;

  const expected = expectedStatus || 'passed';
  const isExpected = (s) => s === expected;

  if (list.every((a) => a.status === 'skipped')) return OUTCOMES.SKIPPED;

  const effective = list.filter((a) => a.status !== 'skipped');
  if (effective.length === 0) return OUTCOMES.SKIPPED;

  // `expected` carries test.fail(): for such a test, failing IS the expected
  // status and passing is the unexpected one.
  const anyExpected = effective.some((a) => isExpected(a.status));
  if (!anyExpected) return OUTCOMES.FAILED;
  if (effective.length === 1) {
    return expected === 'failed' ? OUTCOMES.EXPECTED_FAILURE : OUTCOMES.PASSED;
  }
  // More than one attempt and at least one landed on the expected status: the
  // earlier attempts did not, or Playwright would not have retried.
  return OUTCOMES.FLAKY;
}

/** True when this outcome should be surfaced as an actionable failure. */
function isFailure(outcome) { return outcome === OUTCOMES.FAILED; }

/** Attempts whose evidence is worth preserving: everything that did not pass. */
function isEvidenceWorthy(result, expectedStatus) {
  if (!result) return false;
  if (result.status === 'skipped') return false;
  return result.status !== (expectedStatus || 'passed');
}

function median(values) {
  const nums = values.filter((n) => typeof n === 'number' && Number.isFinite(n)).slice().sort((a, b) => a - b);
  if (nums.length === 0) return null;
  const mid = Math.floor(nums.length / 2);
  return nums.length % 2 ? nums[mid] : Math.round((nums[mid - 1] + nums[mid]) / 2);
}

/**
 * Reduce a test's prior history entries (oldest → newest, current run excluded)
 * into the few numbers a reader can act on.
 */
function aggregate(entries) {
  const list = (entries || []).slice();
  const runs = list.length;
  if (runs === 0) {
    return { runs: 0, fails: 0, flakes: 0, passes: 0, failRate: 0, runsSincePass: null, lastChange: null, medianMs: null };
  }
  let fails = 0;
  let flakes = 0;
  let passes = 0;
  for (const e of list) {
    if (e.status === OUTCOMES.FAILED) fails += 1;
    else if (e.status === OUTCOMES.FLAKY) flakes += 1;
    else if (e.status === OUTCOMES.PASSED || e.status === OUTCOMES.EXPECTED_FAILURE) passes += 1;
  }

  let runsSincePass = null;
  for (let i = list.length - 1; i >= 0; i -= 1) {
    if (list[i].status === OUTCOMES.PASSED || list[i].status === OUTCOMES.EXPECTED_FAILURE) {
      runsSincePass = list.length - 1 - i;
      break;
    }
  }

  let lastChange = null;
  for (let i = list.length - 1; i > 0; i -= 1) {
    if (list[i].status !== list[i - 1].status) {
      lastChange = { runId: list[i].runId, from: list[i - 1].status, to: list[i].status, runsAgo: list.length - 1 - i };
      break;
    }
  }

  return {
    runs,
    fails,
    flakes,
    passes,
    failRate: (fails + flakes) / runs,
    runsSincePass,
    lastChange,
    medianMs: median(list.map((e) => e.ms)),
  };
}

/**
 * The heel: a test that keeps giving way in the same place. Marked only when
 * there is enough history to mean something, so a first-time failure is never
 * dressed up as a chronic one.
 */
function isHeel(agg, opts) {
  const minRuns = (opts && opts.minRuns) || 3;
  const threshold = (opts && opts.threshold) || 0.5;
  if (!agg || agg.runs < minRuns) return false;
  return agg.failRate >= threshold;
}

/** Duration outliers: slowest first, with the delta against their own median. */
function slowest(tests, limit) {
  return tests
    .filter((t) => typeof t.ms === 'number' && t.ms > 0)
    .slice()
    .sort((a, b) => b.ms - a.ms)
    .slice(0, limit || 3)
    .map((t) => {
      const med = t.history && t.history.medianMs;
      const deltaPct = med && med > 0 ? Math.round(((t.ms - med) / med) * 100) : null;
      return { ...t, deltaPct };
    });
}

module.exports = { OUTCOMES, classify, isFailure, isEvidenceWorthy, aggregate, isHeel, slowest, median };
