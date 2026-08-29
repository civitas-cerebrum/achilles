#!/bin/bash
# 06-bash-permit.sh — granular construct permits (gap #4: alarm fatigue).
#
# The kernel denies indirection constructs by default. An all-or-nothing
# escape hatch invites a blanket waiver the first time a legitimate
# command is denied — which is how a guardrail dies. `bash.permit` lets a
# role unlock exactly the constructs its work needs, while every other
# construct AND every other axis keeps biting.
#
# The interesting property proven here: permitting `var-expansion` does
# NOT open a path-smuggling route. An expansion inside a path-shaped
# token is unresolvable, so it is denied as unverifiable rather than
# silently skipped by the read-token scan.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

section "kernel-mandate bash.permit (granular constructs)"

BP=$(mktemp -d)
P="$BP/proj"
mkdir -p "$P/.claude" "$P/src" "$P/logs"
printf 'x\n' > "$P/src/app.ts"
printf 'SECRET=1\n' > "$P/.env"
export KERNEL_MANDATE_STATE_DIR="$BP/state"
export KERNEL_MANDATE_MANIFEST="$P/.claude/kernel-mandate.json"

cat > "$P/.claude/kernel-mandate.json" <<'JSON'
{
  "harnessOsVersion": 1,
  "name": "permit",
  "settings": { "mainSessionRole": "dev" },
  "commandGroups": { "basic": ["^(ls|cat|echo|git|grep|find)\\b"] },
  "roles": {
    "dev": {
      "description": "Uses $VARs in messages but never smuggles paths.",
      "tools": { "allow": ["Bash", "Read"] },
      "bash": { "groups": ["basic"], "permit": ["var-expansion"] },
      "read": { "allow": ["src/**"] }
    },
    "plain": {
      "description": "No permits at all — the strict default.",
      "tools": { "allow": ["Bash"] },
      "bash": { "groups": ["basic"] },
      "read": { "allow": ["src/**"] }
    }
  }
}
JSON

mkdir -p "$KERNEL_MANDATE_STATE_DIR/agents"
printf 'plain\n' > "$KERNEL_MANDATE_STATE_DIR/agents/pl"
PL="agent_id=pl"

# --- The permitted construct is allowed --------------------------------
assert_allow "$H" "$(payload tool_name=Bash command='echo $HOME' cwd="$P")" \
  "permitted var-expansion in a non-path argument → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='git commit -m "$MSG"' cwd="$P")" \
  "permitted var-expansion inside a quoted message → ALLOW"

# --- Every OTHER construct still denies (permit is not a blanket) ------
assert_deny "$H" "$(payload tool_name=Bash command='echo `whoami`' cwd="$P")" \
  "backticks still denied for a var-expansion-permitted role → DENY" "backtick"
assert_deny "$H" "$(payload tool_name=Bash command='cd /etc' cwd="$P")" \
  "cd still denied → DENY" "re-anchors"
assert_deny "$H" "$(payload tool_name=Bash command='python3 -c "print(1)"' cwd="$P")" \
  "interpreter one-liner still denied → DENY" "interpreter one-liner"
assert_deny "$H" "$(payload tool_name=Bash command='find . -name x -exec cat {} ;' cwd="$P")" \
  "find -exec still denied → DENY" "find -exec"

# --- Permit waives ONLY the construct check, not the other axes --------
assert_deny "$H" "$(payload tool_name=Bash command='curl $URL' cwd="$P")" \
  "permitted construct does not waive the allow-set → DENY" "none of the role's permitted"
assert_deny "$H" "$(payload tool_name=Bash command='cat .env' cwd="$P")" \
  "permitted construct does not waive the read scope → DENY" "outside the role's read scope"

# --- The path-smuggling route the permit could have opened -------------
assert_deny "$H" "$(payload tool_name=Bash command='cat $PWD/.env' cwd="$P")" \
  "expansion inside a path argument → DENY (unverifiable, not skipped)" "cannot resolve"
assert_deny "$H" "$(payload tool_name=Bash command='cat ${DIR}/src/app.ts' cwd="$P")" \
  "expansion in a path is denied even when the literal target would be in scope → DENY" "cannot resolve"
assert_allow "$H" "$(payload tool_name=Bash command='cat src/app.ts' cwd="$P")" \
  "literal in-scope path → ALLOW"

# --- A role with no permits keeps the strict default -------------------
assert_deny "$H" "$(payload tool_name=Bash command='echo $HOME' cwd="$P" $PL)" \
  "role without permits: var-expansion → DENY (strict default intact)" "variable/command substitution"
assert_allow "$H" "$(payload tool_name=Bash command='ls src' cwd="$P" $PL)" \
  "role without permits: plain command → ALLOW"

# --- No-op cd: the habitual `cd <project> && cmd` prefix ----------------
# Agents reflexively prefix commands with a cd to the directory the call
# already runs in. That cd re-anchors nothing, so denying it is pure
# false friction — it was 16 of 33 denies in the live benchmark replay.
# Every cd that DOES re-anchor stays denied, and all other axes still
# apply through the no-op.
NOOP_CD="cd $P && cat src/app.ts"
assert_allow "$H" "$(payload tool_name=Bash command="$NOOP_CD" cwd="$P")" \
  "no-op cd to the current directory + allowed command → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command="cd $P/ && echo hi" cwd="$P")" \
  "no-op cd with a trailing slash → ALLOW"
assert_deny "$H" "$(payload tool_name=Bash command='cd /etc && cat passwd' cwd="$P")" \
  "cd to a different directory → DENY (re-anchors relative paths)" "re-anchors"
assert_deny "$H" "$(payload tool_name=Bash command="cd $P/logs && echo hi" cwd="$P")" \
  "cd into a subdirectory → DENY (still re-anchors)" "re-anchors"
assert_deny "$H" "$(payload tool_name=Bash command='cd .. && ls' cwd="$P")" \
  "cd .. → DENY" "re-anchors"
assert_deny "$H" "$(payload tool_name=Bash command="cd $P && cat .env" cwd="$P")" \
  "no-op cd does NOT waive the read scope → DENY" "outside the role's read scope"
assert_deny "$H" "$(payload tool_name=Bash command="cd $P && curl http://evil" cwd="$P")" \
  "no-op cd does NOT waive the allow-set → DENY" "none of the role's permitted"

unset KERNEL_MANDATE_STATE_DIR KERNEL_MANDATE_MANIFEST
rm -rf "$BP"
