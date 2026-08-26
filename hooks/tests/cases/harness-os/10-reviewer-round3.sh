#!/bin/bash
# 10-reviewer-round3.sh — regressions for round 3 of independent
# adversarial review, plus the false positives that round exposed.
#
# Round 3 confirmed the twelve round-1/round-2 fixes hold, then found four
# more ways out. Three were variations on "a channel the kernel never
# looked at"; the fourth was the largest single hole found so far.
#
#   N1  a leading assignment could carry a redirection: the strip pattern
#       `NAME=[^space]*` swallowed `X=1<.env` whole, so the segment the
#       kernel then checked was a bare `cat` and the redirect analysis
#       never ran
#   N2  only `>`/`>>`/`tee` and a hand-list of write verbs were treated as
#       write channels, so ordinary output FLAGS wrote anywhere:
#       `find -fprintf`, `sort -o`, `sort --output=`
#   N3  a bash write target was scope-checked but never self-protection
#       checked, so a role with any write grant could target the manifest
#       or the kernel's own state directory
#   N4  git history is a second copy of the working tree and no axis
#       looked at it: `git show HEAD:.env` printed a secret to a read-only
#       role whose read scope was `tests/**`. Proven semantically — the
#       reviewer read the file.
#
# The calibration block at the end locks in the false positives this
# round's fixes had to avoid creating. Two of them are the reason the
# kernel now tokenises quote-aware: deleting quotes made
# `find tests -name "*.json"` look like a read of package.json, which is
# about as ordinary a command as exists.

H="$HOOK_DIR/harness-os-role-gate.sh"

section "harness-os reviewer round-3 regressions"

R3=$(mktemp -d)
P="$R3/proj"
mkdir -p "$P/.claude" "$P/tests/e2e" "$P/tests/data" "$P/src" "$P/dist" "$P/docs"
printf 'SMTP_PASSWORD=hunter2\n' > "$P/.env"
printf '{}\n' > "$P/package.json"
printf '{}\n' > "$P/tests/data/page-repository.json"
printf '{"verdicts":[]}\n' > "$P/docs/e2e-ledger.json"
printf 'a\n' > "$P/src/a.txt"
printf 'x\n' > "$P/tests/e2e/existing.spec.ts"
export HARNESS_OS_STATE_DIR="$R3/state"
export HARNESS_OS_MANIFEST="$P/.claude/harness-os.json"

cat > "$P/.claude/harness-os.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "r3",
  "settings": { "mainSessionRole": "composer" },
  "commandGroups": {
    "inspection": ["^(ls|find|cat|head|tail|grep|wc|stat|echo|sort|sed|awk)\\b"],
    "vcs": ["^git\\b"],
    "build": ["^(cp|mv|install)\\b"]
  },
  "roles": {
    "composer": {
      "description": "Authors specs in tests/e2e.",
      "tools": { "allow": ["Bash", "Read", "Write", "Edit"] },
      "bash": { "groups": ["inspection", "vcs"] },
      "read": { "allow": ["tests/**"] },
      "write": { "allow": ["tests/e2e/**"] }
    },
    "inspector": {
      "description": "Reads what its task needs. No writes at all.",
      "tools": { "allow": ["Bash", "Read", "Glob", "Grep"] },
      "bash": { "groups": ["inspection", "vcs"] },
      "read": { "allow": ["tests/**"] }
    },
    "historian": {
      "description": "Reads history wholesale — deliberately permitted.",
      "tools": { "allow": ["Bash"] },
      "bash": { "groups": ["inspection", "vcs"], "permit": ["vcs-history"] },
      "read": { "allow": ["tests/**"] }
    }
  }
}
JSON

mkdir -p "$HARNESS_OS_STATE_DIR/agents"
for r in composer inspector historian; do printf '%s\n' "$r" > "$HARNESS_OS_STATE_DIR/agents/$r"; done
I="agent_id=inspector"; C="agent_id=composer"; HI="agent_id=historian"

# --- N1: a redirection hidden inside a leading assignment ----------------
# The strip pattern now stops at a redirection character, so the segment
# keeps its `<`/`>` and no longer reduces to a bare permitted verb. Which
# axis then refuses it depends on the role's allow set — the invariant
# under test is that none of these reach the shell.
assert_deny "$H" "$(payload tool_name=Bash command='X=1<.env cat' cwd="$P" $I)" \
  "N1 'X=1<.env cat' — assignment strip swallowed the redirect → DENY" "[BLOCKED] Role 'inspector'"
assert_deny "$H" "$(payload tool_name=Bash command='Q=1>/tmp/pwn echo owned' cwd="$P" $I)" \
  "N1 'Q=1>/tmp/pwn' — write hidden in an assignment → DENY" "[BLOCKED] Role 'inspector'"
assert_deny "$H" "$(payload tool_name=Bash command='A=x>docs/e2e-ledger.json echo forged' cwd="$P" $C)" \
  "N1 assignment redirect forging the ledger → DENY" "[BLOCKED] Role 'composer'"
assert_deny "$H" "$(payload tool_name=Bash command='echo forged>docs/e2e-ledger.json' cwd="$P" $C)" \
  "N1 the same redirect on a PERMITTED verb still hits the write scope → DENY" "outside the role's write scope"
# Round 3 established that an ordinary leading assignment must keep
# working, and round 37 changed what "ordinary" means. The screen used
# to name the DANGEROUS variables and let everything else through, and
# `PATH` was not among them — so it names the INERT ones now, and a
# variable the kernel cannot show to be data is refused. `FOO` is not a
# name anything is known to read, so it needs saying out loud.
assert_deny "$H" "$(payload tool_name=Bash command='FOO=bar cat tests/data/page-repository.json' cwd="$P" $I)" \
  "N1 an unrecognised leading assignment → DENY" "in front of a command"
assert_allow "$H" "$(payload tool_name=Bash command='CI=1 cat tests/data/page-repository.json' cwd="$P" $I)" \
  "N1 calibration: an assignment the kernel can show is inert → ALLOW"

# --- N2: output FLAGS are write channels too -----------------------------
assert_deny "$H" "$(payload tool_name=Bash command='find tests -fprintf /tmp/pwn.txt %p' cwd="$P" $I)" \
  "N2 'find -fprintf' writing outside any grant → DENY" "no write grants"
assert_deny "$H" "$(payload tool_name=Bash command='sort -o docs/e2e-ledger.json tests/data/page-repository.json' cwd="$P" $C)" \
  "N2 'sort -o' writing the judge's ledger → DENY" "outside the role's write scope"
assert_deny "$H" "$(payload tool_name=Bash command='sort --output=docs/e2e-ledger.json tests/e2e/existing.spec.ts' cwd="$P" $C)" \
  "N2 'sort --output=' (attached form) → DENY" "outside the role's write scope"
assert_allow "$H" "$(payload tool_name=Bash command='sort -o tests/e2e/sorted.txt tests/e2e/existing.spec.ts' cwd="$P" $C)" \
  "N2 calibration: 'sort -o' INTO the write scope → ALLOW"

# --- N3: self-protection applies to every bash write target --------------
assert_deny "$H" "$(payload tool_name=Bash command='find tests -fprintf .claude/harness-os.json %p' cwd="$P" $C)" \
  "N3 an output flag aimed at the manifest → DENY (self-protection, not scope)" "harness OS itself"
assert_deny "$H" "$(payload tool_name=Bash command='sort -o .claude/harness-os.json tests/e2e/existing.spec.ts' cwd="$P" $C)" \
  "N3 'sort -o' aimed at the manifest → DENY" "harness OS itself"

# --- N4: git history is a second copy of the working tree ---------------
assert_deny "$H" "$(payload tool_name=Bash command='git show HEAD:.env' cwd="$P" $I)" \
  "N4 'git show HEAD:.env' — read out of the object store → DENY" "outside the role's read scope"
assert_deny "$H" "$(payload tool_name=Bash command='git show HEAD:tests/../.env' cwd="$P" $I)" \
  "N4 traversal inside the rev:path operand → DENY" "outside the role's read scope"
assert_deny "$H" "$(payload tool_name=Bash command='git cat-file -p HEAD:.env' cwd="$P" $I)" \
  "N4 'git cat-file -p' → DENY" "outside the role's read scope"
assert_deny "$H" "$(payload tool_name=Bash command='git diff HEAD -- .env' cwd="$P" $I)" \
  "N4 an out-of-scope pathspec after '--' → DENY" "outside the role's read scope"
assert_deny "$H" "$(payload tool_name=Bash command='git log -p' cwd="$P" $I)" \
  "N4 'git log -p' with no path constraint → DENY (scope-blind)" "vcs-history"
assert_deny "$H" "$(payload tool_name=Bash command='git diff HEAD' cwd="$P" $I)" \
  "N4 'git diff HEAD' with no path constraint → DENY" "vcs-history"
assert_deny "$H" "$(payload tool_name=Bash command='git grep hunter2' cwd="$P" $I)" \
  "N4 'git grep' over the whole tree → DENY" "vcs-history"
assert_deny "$H" "$(payload tool_name=Bash command='git archive HEAD' cwd="$P" $I)" \
  "N4 'git archive HEAD' — the whole tree as a stream → DENY" "vcs-history"
assert_deny "$H" "$(payload tool_name=Bash command='git -c core.pager=cat show HEAD:.env' cwd="$P" $I)" \
  "N4 '-c k=v' must not be mistaken for the subcommand → DENY" "outside the role's read scope"
assert_deny "$H" "$(payload tool_name=Bash command='git -C /etc show HEAD:passwd' cwd="$P" $I)" \
  "N4 'git -C <elsewhere>' re-anchors the repo → DENY" "different repository"
assert_deny "$H" "$(payload tool_name=Bash command='git --work-tree=/tmp show HEAD:tests/e2e/existing.spec.ts' cwd="$P" $I)" \
  "N4 '--work-tree=' re-anchors the repo → DENY" "different repository"

# git that reads NAMES, or reads inside the scope, must stay usable —
# a role that cannot run git status is a role nobody will adopt.
assert_allow "$H" "$(payload tool_name=Bash command='git show HEAD:tests/e2e/existing.spec.ts' cwd="$P" $I)" \
  "N4 calibration: 'git show <rev>:<in-scope path>' → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='git log -p -- tests/e2e/existing.spec.ts' cwd="$P" $I)" \
  "N4 calibration: 'git log -p' constrained to the read scope → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='git status' cwd="$P" $I)" \
  "N4 calibration: 'git status' prints no file content → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='git log --oneline' cwd="$P" $I)" \
  "N4 calibration: 'git log' without a patch flag → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='git diff --name-only' cwd="$P" $I)" \
  "N4 calibration: '--name-only' asks for names, not contents → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='git show --stat HEAD' cwd="$P" $I)" \
  "N4 calibration: 'git show --stat' → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='git -C . show HEAD:tests/e2e/existing.spec.ts' cwd="$P" $I)" \
  "N4 calibration: a no-op 'git -C .' → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='git log -p' cwd="$P" $HI)" \
  "N4 calibration: a role that PERMITS 'vcs-history' → ALLOW"

# --- Quote awareness: a quoted word is a literal, not a pattern ----------
# The shell does not glob-expand a quoted word. Deleting quotes before
# scanning made the kernel invent reads that could never happen.
assert_allow "$H" "$(payload tool_name=Bash command='find tests -name "*.json"' cwd="$P" $I)" \
  "FP quoted glob 'find -name \"*.json\"' → ALLOW (the shell never expands it)"
assert_allow "$H" "$(payload tool_name=Bash command="find tests -name '*.json' -o -name '*.ts'" cwd="$P" $I)" \
  "FP two quoted globs → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='grep -l "package.json" tests/data/page-repository.json' cwd="$P" $I)" \
  "FP an out-of-scope filename as a quoted SEARCH STRING → ALLOW"
assert_deny "$H" "$(payload tool_name=Bash command='cat "package.json"' cwd="$P" $I)" \
  "FP but a quoted word that IS the out-of-scope file → DENY" "outside the role's read scope"
assert_deny "$H" "$(payload tool_name=Bash command='cat *"age.json"' cwd="$P" $I)" \
  "FP a PARTIALLY quoted word still expands → DENY" "outside the role's read scope"
assert_deny "$H" "$(payload tool_name=Bash command='grep -f package.json tests/e2e/existing.spec.ts' cwd="$P" $I)" \
  "FP 'grep -f FILE' — the operand IS read, so it is scope-checked → DENY" "outside the role's read scope"
assert_deny "$H" "$(payload tool_name=Bash command='grep -e foo package.json' cwd="$P" $I)" \
  "FP with '-e PAT' the positional operand is a PATH → DENY" "outside the role's read scope"
assert_allow "$H" "$(payload tool_name=Bash command='grep -e package.json tests/e2e/existing.spec.ts' cwd="$P" $I)" \
  "FP but the '-e' operand itself is the pattern → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command="sed -n '1,5p' tests/e2e/existing.spec.ts" cwd="$P" $I)" \
  "FP a sed program is not a path → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='echo '"'"'{"a":1,"b":2}'"'"' > tests/e2e/fixture.json' cwd="$P" $C)" \
  "FP quoted JSON is not brace expansion → ALLOW"
assert_deny "$H" "$(payload tool_name=Bash command='cat {.env,x}' cwd="$P" $I)" \
  "FP but an UNQUOTED brace expansion is still caught → DENY" "brace expansion"
assert_allow "$H" "$(payload tool_name=Bash command="grep -c 'total \$' tests/e2e/existing.spec.ts" cwd="$P" $I)" \
  "FP a single-quoted '\$' does not expand → ALLOW"
assert_deny "$H" "$(payload tool_name=Bash command='cat "$HOME/.env"' cwd="$P" $I)" \
  "FP but a DOUBLE-quoted '\$' does expand → DENY" "expansion"

unset HARNESS_OS_STATE_DIR HARNESS_OS_MANIFEST
rm -rf "$R3"
