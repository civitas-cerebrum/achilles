// commit-classify.cjs — helper of hooks/factory/commit-gate.sh (rule process.evidence).
//
// argv: <command> <projectRoot> <cwd>
// Prints "gated" when the command would run a `git commit` whose working directory is inside the
// project root, and nothing otherwise. Exit 2 = unusable argv (the gate turns that into an
// allow-with-warning).
//
// Quote-aware via hooks/lib/shell-segments.cjs, the splitter the spend gate uses. A commit behind `sh -c '…'`,
// `bash -c '…'` or `env git commit` is still a commit: an ungated one carries no stamp check at all.
//
// What a segment can do here:
//   * leading `VAR=value` assignments, and the prefixes a shell passes straight through
//     (`env`, `command`, `builtin`, `exec`, `sudo`, `nice`, `nohup`, `stdbuf`, `time`, `{`), are
//     peeled before the command is identified;
//   * `bash|sh|zsh|dash|ksh -c '<string>'` and `eval '<string>'` are classified one level deep;
//   * `cd <dir>` moves the working directory for the segments after it in the SAME level
//     (`cd` alone → $HOME, `cd -` is left alone as unknowable);
//   * `git [--opt | -c k=v | -C <dir>]… commit` is a commit, in the directory reached by that
//     same segment's `-C` options (cumulative, as git does).
//
// A commit inside the project is gated; a commit in another repository is not ours to gate.
//
// Known limits (documented in references/factory-gates.md): no expansion of $VAR
// or $(…), so `$GIT commit` is not seen; nesting deeper than one level is not followed; a `cd`
// inside a nested shell correctly does not escape it, but a `cd` inside a subshell at the SAME
// level does leak forward, because the splitter treats `(`/`)` as plain command boundaries.
'use strict';
const path = require('path');
const { segments, nestedCommand } = require('./shell-segments.cjs');

const [command, rootArg, cwdArg] = process.argv.slice(2);
if (typeof command !== 'string' || typeof rootArg !== 'string' || !rootArg) {
  process.stderr.write('usage: commit-classify.cjs <command> <projectRoot> <cwd>\n');
  process.exit(2);
}

const root = path.resolve(rootArg);
const home = process.env.HOME || '/';

// Lexical only: symlinks are not followed, so a symlinked directory is judged by its link path.
function resolveDir(base, target) {
  let t = target;
  if (t === '~') t = home;
  else if (t.startsWith('~/')) t = path.join(home, t.slice(2));
  return path.resolve(base, t);
}

const inside = (d) => d === root || d.startsWith(root + path.sep);

// Peeled before the command word; `env git commit` is a commit.
const PREFIXES = new Set(['env', 'command', 'builtin', 'exec', 'sudo', 'nice', 'nohup', 'stdbuf', 'time', '{', '}']);
const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=/;

function walk(cmd, depth, startDir) {
  let cur = startDir;
  for (const toks of segments(cmd)) {
    let i = 0;
    while (i < toks.length && (ASSIGNMENT.test(toks[i]) || PREFIXES.has(toks[i]))) i++;
    const rest = toks.slice(i);
    if (rest.length === 0) continue;

    if (depth === 0) {
      const inner = nestedCommand(rest);
      if (inner !== null) {
        // A `cd` inside the nested string belongs to that subshell: the nested walk starts from
        // the current directory and its moves are discarded when it returns.
        if (walk(inner, depth + 1, cur)) return true;
        continue;
      }
    }

    if (rest[0] === 'cd') {
      if (rest.length > 1 && rest[1] !== '-') cur = resolveDir(cur, rest[1]);
      else if (rest.length === 1) cur = path.resolve(home);
      continue;
    }

    // `git`, `/usr/bin/git` — the program, however it was spelled.
    if (path.basename(rest[0]) !== 'git') continue;

    let dir = cur, j = 1, isCommit = false;
    while (j < rest.length) {
      const t = rest[j];
      if (t === '-C') { j++; if (j < rest.length) dir = resolveDir(dir, rest[j]); }
      else if (t === '-c') j++;                        // -c key=value: skip the value
      else if (t === 'commit') { isCommit = true; break; }
      else if (!t.startsWith('-')) break;              // another subcommand (git log, git status)
      j++;
    }
    if (isCommit && inside(dir)) return true;
  }
  return false;
}

if (walk(command, 0, path.resolve(cwdArg || root))) console.log('gated');
