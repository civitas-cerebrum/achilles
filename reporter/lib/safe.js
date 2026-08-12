'use strict';
// safe.js — the containment layer.
//
// A Playwright reporter runs IN-PROCESS. An exception thrown from any reporter
// callback is surfaced by the runner as a run-level error and turns exit code 0
// into 1 — a green suite goes red because the reporting broke. Every side
// effect in this reporter therefore goes through `guard.run(...)`, which
// swallows the failure, emits at most one concise line per distinct operation,
// and returns a caller-supplied fallback.

const MAX_NOTICES = 5;

function createGuard(write) {
  const emit = write || ((line) => { try { process.stderr.write(line); } catch { /* ignore */ } });
  const seen = new Set();
  let notices = 0;

  return {
    /** Run `fn`; on any throw return `fallback` and report once per operation. */
    run(op, fn, fallback) {
      try {
        return fn();
      } catch (err) {
        this.note(op, err);
        return fallback;
      }
    },

    /** Report a failure without running anything (async callers). */
    note(op, err) {
      if (seen.has(op)) return;
      seen.add(op);
      if (notices >= MAX_NOTICES) return;
      notices += 1;
      const msg = (err && err.message) || String(err);
      emit(`achilles-reporter: ${op} skipped — ${msg}\n`);
      if (notices === MAX_NOTICES) emit('achilles-reporter: further notices suppressed\n');
    },

    /** Test seam. */
    stats() {
      return { notices, ops: [...seen] };
    },
  };
}

module.exports = { createGuard };
