#!/bin/bash
# Tests for client-term-guard.sh — universality guard against client
# references entering the universal achilles repo.
#
# DENY when a Write|Edit into this package's repo matches a term from the
# operator-local denylist (<repo-root>/.achilles/client-terms.local.txt);
# silent allow when no denylist exists, the target is outside the repo,
# or nothing matches. Per the allow-test convention, deny cases ship with
# adjacent-traffic allow cases.
G="$HOOK_DIR/client-term-guard.sh"

# Fabricate the REAL current repo layout: root detection keys on the
# package.json "name" (rename-stable), NOT on any skills/<dir> path — the
# skill directories have been renamed once already (element-interactions →
# achilles-protocol) and a path-based fixture would mask a dead probe.
CTG_REPO=$(mktemp -d)
mkdir -p "$CTG_REPO/skills/contributing-to-achilles-protocol" "$CTG_REPO/skills/example-skill" "$CTG_REPO/.achilles"
printf '{"name":"@civitas-cerebrum/achilles","version":"0.0.0"}' > "$CTG_REPO/package.json"
touch "$CTG_REPO/skills/contributing-to-achilles-protocol/SKILL.md"
printf '# engagement vocabulary — operator-local, never committed\nexampleclientbrand\nWidgetShopDemo\nab\n\n' > "$CTG_REPO/.achilles/client-terms.local.txt"

section "client-term-guard: denies client terms in repo writes"
assert_deny "$G" "$(payload tool_name=Write file_path="$CTG_REPO/skills/example-skill/SKILL.md" content='A worked example from ExampleClientBrand checkout')" "Write with denylist term (case-insensitive) → DENY" "Client reference detected"
assert_deny "$G" "$(payload tool_name=Edit file_path="$CTG_REPO/skills/example-skill/SKILL.md" old_string='old text' new_string='see the widgetshopdemo grid')" "Edit new_string with denylist term → DENY" "genericise"
assert_deny "$G" "$(payload tool_name=Write file_path="$CTG_REPO/skills/exampleclientbrand-notes/SKILL.md" content='neutral body')" "target PATH carrying the term → DENY" "Client reference"

section "client-term-guard: adjacent traffic allows"
assert_allow "$G" "$(payload tool_name=Write file_path="$CTG_REPO/skills/example-skill/SKILL.md" content='A neutral mechanism example using «BASE_URL» and j-<slug> placeholders')" "clean content → silent allow"
assert_allow "$G" "$(payload tool_name=Write file_path="/tmp/somewhere-else/notes.md" content='ExampleClientBrand internal notes')" "write OUTSIDE this package repo → silent allow (out of scope)"
CTG_OTHER=$(mktemp -d)
mkdir -p "$CTG_OTHER/skills/x" "$CTG_OTHER/.achilles"
printf '{"name":"@example/other-package"}' > "$CTG_OTHER/package.json"
printf 'exampleclientbrand\n' > "$CTG_OTHER/.achilles/client-terms.local.txt"
assert_allow "$G" "$(payload tool_name=Write file_path="$CTG_OTHER/skills/x/SKILL.md" content='ExampleClientBrand')" "repo with a DIFFERENT package name → silent allow (marker is the name, not the tree shape)"
rm -rf "$CTG_OTHER"
assert_allow "$G" "$(payload tool_name=Bash command='echo ExampleClientBrand')" "non-Write|Edit tool → silent allow"
assert_allow "$G" "$(payload tool_name=Write file_path="$CTG_REPO/skills/example-skill/SKILL.md" content='the word about contains ab but 2-char terms are ignored')" "terms under 3 chars ignored → silent allow"

section "client-term-guard: no denylist → markdown-rule only"
rm "$CTG_REPO/.achilles/client-terms.local.txt"
assert_allow "$G" "$(payload tool_name=Write file_path="$CTG_REPO/skills/example-skill/SKILL.md" content='ExampleClientBrand appears but no denylist exists')" "no denylist file → silent allow"

section "client-term-guard: malformed input fails open"
assert_allow "$G" "" "empty stdin → silent allow"
assert_allow "$G" "not-json" "invalid JSON → silent allow"
assert_allow "$G" "{}" "empty object → silent allow"

rm -rf "$CTG_REPO"
