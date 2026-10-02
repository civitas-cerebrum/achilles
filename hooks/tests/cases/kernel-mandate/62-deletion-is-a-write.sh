#!/bin/bash
# 62-deletion-is-a-write.sh — rm, rmdir and unlink are held to WRITE scope.
#
# Destroying a file's contents was a write; unlinking the same file was
# not. `shred`, `truncate`, `cp`, `mv`, `chmod` all routed their operands
# through the write axis; `rm` did not appear in the verb table at all,
# so a role with ZERO write grants whose command group admitted `rm`
# could delete anything inside its READ scope — a judge verified
# `rm -rf docs` and `rm -rf src` as ALLOW for such a role, and `validate`
# said OK. The kernel's own self-protection regex listed
# `rm|rmdir|unlink` the whole time: it defended its manifest from
# deletion while the project's files were not routed through the write
# axis at all.
#
# The factory makes this concrete: an implementer READS its dependencies'
# api.sig and must not be able to delete them.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

section "deletion is a write (round 58)"

R58=$(mktemp -d)
P="$R58/proj"
mkdir -p "$P/.claude" "$P/modules/a/src" "$P/modules/b" "$P/docs"
echo 'x' > "$P/modules/a/src/index.js"
echo 'sig' > "$P/modules/b/api.sig"
echo '{}' > "$P/docs/ledger.json"
export KERNEL_MANDATE_STATE_DIR="$R58/state"
export KERNEL_MANDATE_MANIFEST="$P/.claude/kernel-mandate.json"

# mk <write-allow-array>  — default "[]" means no write grants. The write
# block is always present (an empty allow-list writes nothing), so there
# is no conditional-with-braces inside the heredoc to corrupt the JSON.
mk() {
  local writes="${1:-[]}"
  cat > "$P/.claude/kernel-mandate.json" <<JSON
{
  "kernelMandateVersion": 1,
  "name": "round58",
  "settings": { "mainSessionRole": "worker" },
  "commandGroups": { "housekeeping": ["^(ls|cat|rm|rmdir|unlink|shred|truncate)\\\\b"] },
  "roles": {
    "worker": {
      "description": "Reads modules and docs; writes only what it is granted.",
      "tools": { "allow": ["Bash", "Read"] },
      "read":  { "allow": ["modules/**", "docs/**"] },
      "write": { "allow": ${writes} },
      "bash":  { "groups": ["housekeeping"] }
    }
  }
}
JSON
}
b() { payload tool_name=Bash command="$1" cwd="$P"; }

# ── Zero write grants: deletion is refused like every other write ────
mk "[]"
assert_deny "$H" "$(b 'shred docs/ledger.json')"      "R58 control: shred with no write grants → DENY" "write"
assert_deny "$H" "$(b 'rm docs/ledger.json')"         "R58 rm with no write grants → DENY" "write"
assert_deny "$H" "$(b 'rm -f docs/ledger.json')"      "R58 rm -f → DENY" "write"
assert_deny "$H" "$(b 'rm -rf docs')"                 "R58 rm -rf a directory → DENY" "write"
assert_deny "$H" "$(b 'rm -rf modules')"              "R58 rm -rf the entire read scope → DENY" "write"
assert_deny "$H" "$(b 'rmdir docs')"                  "R58 rmdir → DENY" "write"
assert_deny "$H" "$(b 'unlink modules/b/api.sig')"    "R58 unlink → DENY" "write"
assert_deny "$H" "$(b 'rm -- docs/ledger.json')"      "R58 rm with end-of-options marker → DENY" "write"
assert_deny "$H" "$(b 'ls && rm docs/ledger.json')"   "R58 rm as a later segment → DENY" "write"
assert_deny "$H" "$(b 'rm docs/ledger.json')"         "R58 rm a real in-read-scope file → DENY" "write"

# ── Scoped write grants: deletion inside is fine, outside is not ─────
mk '["modules/a/**"]'
assert_allow "$H" "$(b 'rm modules/a/src/index.js')"  "R58 calibration: rm inside write scope → ALLOW"
assert_allow "$H" "$(b 'rm -rf modules/a/src')"       "R58 calibration: rm -rf a dir inside write scope → ALLOW"
assert_deny  "$H" "$(b 'rm modules/b/api.sig')"       "R58 the factory case: implementer deletes a dependency's signature → DENY" "write"
assert_deny  "$H" "$(b 'rm modules/a/src/index.js modules/b/api.sig')" \
  "R58 one in-scope and one out-of-scope operand → DENY" "write"
assert_deny  "$H" "$(b 'rm -rf modules')"             "R58 rm -rf the parent of the write scope → DENY" "write"

# ── Calibration: the read side is untouched ──────────────────────────
mk "[]"
assert_allow "$H" "$(b 'ls docs')"                    "R58 calibration: ls → ALLOW"
assert_allow "$H" "$(b 'cat docs/ledger.json')"       "R58 calibration: cat → ALLOW"

unset KERNEL_MANDATE_STATE_DIR KERNEL_MANDATE_MANIFEST
rm -rf "$R58"
