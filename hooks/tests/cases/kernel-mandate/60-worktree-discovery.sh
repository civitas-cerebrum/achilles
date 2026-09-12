#!/bin/bash
# 60-worktree-discovery.sh — a git worktree is governed by the main
# worktree's manifest when it has none of its own.
#
# Discovery walks UP from cwd. A worktree at <repo>/wt-a is a SIBLING of
# <repo>/main, not a descendant, so a manifest the operator keeps
# untracked exists in main and in no worktree. Round 57 checked one out
# for a parallel implementer and read `.env` from it: nothing found,
# "nothing" means "never opted in", state dir written, nothing governed.
#
# Now: no manifest above cwd + cwd inside a worktree → the main
# worktree's manifest is the law, and THIS checkout's root is the base
# its scopes resolve against.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

section "worktree discovery (round 57)"

command -v git >/dev/null 2>&1 || { echo "  (git not available; skipping)"; return 0 2>/dev/null || exit 0; }

R57=$(mktemp -d)
export KERNEL_MANDATE_STATE_DIR="$R57/state"
unset KERNEL_MANDATE_MANIFEST

MAIN="$R57/main"
( set -e
  git init -q "$MAIN"; cd "$MAIN"
  git config user.email t@t; git config user.name t
  mkdir -p .claude modules/a/src modules/b
  echo 'sig' > modules/b/api.sig; echo 'SECRET=1' > .env
  cat > .claude/kernel-mandate.json <<'JSON'
{
  "kernelMandateVersion": 1,
  "name": "round57",
  "settings": { "mainSessionRole": "implementer" },
  "commandGroups": { "t": ["^npm test\\b", "^cat\\b"] },
  "roles": {
    "implementer": {
      "description": "Builds module a; may read b's signature only.",
      "tools": { "allow": ["Read", "Write", "Bash"] },
      "read":  { "allow": ["modules/a/**", "modules/b/api.sig"] },
      "write": { "allow": ["modules/a/**"] },
      "bash":  { "groups": ["t"] }
    }
  }
}
JSON
  echo '.claude/kernel-mandate.json' > .gitignore
  git add -A; git commit -qm init
  git worktree add -q "$R57/wt-a" -b impl-a
) || { echo "  (worktree setup failed; skipping)"; rm -rf "$R57"; return 0 2>/dev/null || exit 0; }

WT="$R57/wt-a"
[ -f "$WT/.claude/kernel-mandate.json" ] && assert_eq 1 0 "R57 precondition: worktree has NO manifest of its own"

rd() { payload tool_name=Read file_path="$1" cwd="${2:-$WT}"; }
wr() { payload tool_name=Write file_path="$1" content=x cwd="${2:-$WT}"; }

# ── The bug: an untracked manifest left the worktree ungoverned ──────
assert_deny "$H" "$(rd "$WT/.env")" \
  "R57 worktree with no manifest: Read .env → DENY (main's law applies)" "read scope"
assert_deny "$H" "$(wr "$WT/modules/b/api.sig")" \
  "R57 worktree: write outside scope → DENY" "write"
assert_deny "$H" "$(payload tool_name=Bash command='cat .env' cwd="$WT")" \
  "R57 worktree: bash read of .env → DENY" "read scope"

# ── Scopes resolve against THIS checkout, not main ───────────────────
assert_allow "$H" "$(rd "$WT/modules/b/api.sig")" \
  "R57 worktree: in-scope read of the worktree's own file → ALLOW"
assert_allow "$H" "$(wr "$WT/modules/a/src/index.js")" \
  "R57 worktree: in-scope write to the worktree's own tree → ALLOW"
# The same relative path in MAIN is outside the worktree's root: a
# worktree implementer may not reach into the main checkout.
assert_deny "$H" "$(rd "$MAIN/modules/b/api.sig")" \
  "R57 worktree: reading main's copy of an in-scope path → DENY (different root)" ""

# ── Round 44 in a new coat: the worktree must not mint its own law ───
assert_deny "$H" "$(wr "$WT/.claude/kernel-mandate.json")" \
  "R57 worktree: authoring a shadowing manifest → DENY" "kernel mandate itself"
assert_deny "$H" "$(payload tool_name=Bash command='mkdir -p .claude && echo "{}" > .claude/kernel-mandate.json' cwd="$WT")" \
  "R57 worktree: ...via Bash → DENY" "kernel mandate itself"

# ── Calibration ──────────────────────────────────────────────────────
assert_deny "$H" "$(rd "$MAIN/.env" "$MAIN")" \
  "R57 calibration: main checkout is governed as before" "read scope"
# A broken manifest in main is not a licence to govern nothing — but it
# is not silently applied either: the fallback requires a parse.
cp "$MAIN/.claude/kernel-mandate.json" "$R57/good.json"
echo '{ not json' > "$MAIN/.claude/kernel-mandate.json"
out=$(rd "$WT/.env" | bash "$H" 2>/dev/null)
assert_eq "$([ -z "$out" ] && echo ungoverned || echo governed)" "ungoverned" \
  "R57 calibration: a BROKEN main manifest is not applied to the worktree (walk rule)"
cp "$R57/good.json" "$MAIN/.claude/kernel-mandate.json"
# A worktree that DOES carry its own manifest uses its own.
mkdir -p "$WT/.claude"; sed 's/"modules\/b\/api.sig"/"modules\/b\/api.sig", ".env"/' "$R57/good.json" > "$WT/.claude/kernel-mandate.json"
assert_allow "$H" "$(rd "$WT/.env")" \
  "R57 calibration: a worktree with its OWN manifest is governed by that one"
# ...and the nearest-manifest rule still wins over the fallback.
rm -f "$WT/.claude/kernel-mandate.json"
# Not a worktree at all: a plain directory with no manifest stays ungoverned.
mkdir -p "$R57/plain"; echo 'x' > "$R57/plain/.env"
out=$(rd "$R57/plain/.env" "$R57/plain" | bash "$H" 2>/dev/null)
assert_eq "$([ -z "$out" ] && echo ungoverned || echo governed)" "ungoverned" \
  "R57 calibration: a plain ungoverned directory is still ungoverned"

unset KERNEL_MANDATE_STATE_DIR
( cd "$MAIN" && git worktree remove --force "$WT" 2>/dev/null ) || true
rm -rf "$R57"
