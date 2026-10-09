// shell-segments.cjs — the quote-aware command splitter the Bash-side factory gates share
// (hooks/factory/spend-gate.sh via spend-classify.cjs, hooks/factory/commit-gate.sh via
// commit-classify.cjs).
//
// One splitter for both gates, so they read the same shell; the splitter is shell-words.sh, the only parser in hooks/.
//
// Limits (shared with the gates that use it; known-limits.md KL-17): no expansion of $VAR, $(…) or `…`; no aliases,
// functions or scripts that call the runner; one level of nesting only, which is the callers' business, not this
// module's.
'use strict';

const { execFileSync } = require('child_process');
const path = require('path');

// shell-words.sh is the one shell parser; this asks it. Words arrive NUL-separated: SW_SEP (\036) ends
// a command, and a redirection is SW_OP (\037) plus its target, which no caller wants as an argument.
const SPLIT = 'source "$1"; shell_words "$2"; [ "$SW_OVERFLOW" = 1 ] && exit 3; ' +
  '[ "${#SW[@]}" -gt 0 ] && printf "%s\\0" "${SW[@]}"; exit 0';

/**
 * Splits a command line into segments of tokens, as hooks/lib/shell-words.sh reads it. An empty
 * argument ('' or "") survives as an empty string. A line over the parser's size cap is unusable:
 * the process exits 2, which the gates turn into an allow-with-warning.
 *
 * @param {string} s the command line
 * @returns {string[][]}
 */
function segments(s) {
  let out;
  try {
    out = execFileSync('bash', ['-c', SPLIT, 'bash', path.join(__dirname, 'shell-words.sh'), s], { encoding: 'utf8' });
  } catch (e) {
    process.stderr.write('command too long to classify\n');
    process.exit(2);
  }
  const segs = [];
  let toks = [];
  const words = out.split('\0');
  words.pop();
  for (let i = 0; i < words.length; i++) {
    if (words[i] === '\x1e') { if (toks.length) segs.push(toks); toks = []; }
    else if (words[i][0] === '\x1f') i++;
    else toks.push(words[i]);
  }
  if (toks.length) segs.push(toks);
  return segs;
}

const SHELLS = /(^|\/)(bash|sh|zsh|dash|ksh)$/;

/**
 * The command string a segment runs in a nested shell, or null when it runs none.
 *
 * Recognises `bash|sh|zsh|dash|ksh [-opts]c '<string>'` (the first option containing `c` takes the
 * command string, so `-lc` and `-ec` work) and `eval '<string>'` — the two shapes an agent reaches
 * for when it wants one quoted command, and the two that hid a `git commit` from the commit gate.
 *
 * @param {string[]} rest the segment's tokens, with leading assignments and prefixes already peeled
 * @returns {string|null}
 */
function nestedCommand(rest) {
  if (rest.length < 2) return null;
  if (SHELLS.test(rest[0])) {
    const ci = rest.findIndex((t, j) => j > 0 && /^-[A-Za-z]*c[A-Za-z]*$/.test(t));
    if (ci > 0 && rest[ci + 1] !== undefined) return rest[ci + 1];
    return null;
  }
  if (rest[0] === 'eval') return rest.slice(1).join(' ');
  return null;
}

module.exports = { segments, nestedCommand };
