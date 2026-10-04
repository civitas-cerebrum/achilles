// shell-segments.cjs — the quote-aware command splitter the Bash-side factory gates share
// (hooks/factory/spend-gate.sh via spend-classify.cjs, hooks/factory/commit-gate.sh via
// commit-classify.cjs).
//
// Extracted from spend-classify.cjs, where it was the only quote-aware splitter in the repo.
// commit-gate.sh had its own, written in bash as a chain of `${VAR//x/y}` substitutions over the
// raw command, and it had the defect that shape makes inevitable: it tokenised each segment with
// `read -a` and then required token 0 to be literally `git`, so `sh -c 'git commit -m x'` had
// token 0 `sh`, hit `continue`, and committed with no gate at all. Same for `bash -c …` and for
// `env git commit`. Every one of those is a thing an agent writes by itself. One splitter, used by
// both gates, is the only way the two stay honest about the same shell.
//
// Deliberate limits (shared with the gates that use it, documented in their headers and in
// references/factory-gates.md §"What the gates deliberately do not do"): no expansion of $VAR,
// $(…) or `…`; no aliases, functions or scripts that call the runner; one level of nesting only,
// which is the callers' business, not this module's.
'use strict';

// Unquoted shell metacharacters that end a command: the control operators, plus the subshell
// parentheses. A `(` or `)` ends a command the way `;` does, which is what lets a caller see the
// `git commit` in `(cd sub && git commit -m x)` as a command of its own.
const SEPARATORS = new Set([';', '|', '&', '\n', '(', ')']);

/**
 * Splits a command line into segments of tokens, honouring '…', "…" and backslash escapes.
 *
 * Returns an array of segments; each segment is an array of tokens. Quotes are consumed, so a
 * token that was written '' or "" survives as an empty string (it was an argument) while plain
 * whitespace produces no token at all.
 *
 * @param {string} s the command line
 * @returns {string[][]}
 */
function segments(s) {
  const segs = [];
  let toks = [], tok = '', has = false, q = null;
  const endTok = () => { if (has) toks.push(tok); tok = ''; has = false; };
  const endSeg = () => { endTok(); if (toks.length) segs.push(toks); toks = []; };
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q === "'") { if (c === "'") q = null; else tok += c; continue; }
    if (q === '"') { if (c === '"') q = null; else if (c === '\\' && i + 1 < s.length && '"\\$`'.includes(s[i + 1])) tok += s[++i]; else tok += c; continue; }
    if (c === "'" || c === '"') { q = c; has = true; continue; }
    if (c === '\\') { if (i + 1 < s.length) { if (s[i + 1] !== '\n') { tok += s[i + 1]; has = true; } i++; } continue; }
    if (SEPARATORS.has(c)) { endSeg(); continue; }
    if (c === ' ' || c === '\t') { endTok(); continue; }
    tok += c; has = true;
  }
  endSeg();
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

module.exports = { segments, nestedCommand, SHELLS };
