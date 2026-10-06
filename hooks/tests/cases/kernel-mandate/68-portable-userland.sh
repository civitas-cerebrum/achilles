#!/bin/bash
# 68-portable-userland.sh — the kernel gives the same verdicts with BSD sed as with GNU sed.
#
# BSD sed (macOS) rejects a label or branch followed by `;` and inserts a
# literal `n` for `\n` in a replacement. Under it the import screen came
# back empty and write.codeImports allowed every package. On a GNU host a
# shim reproduces those failure modes, so every CI runner checks both.

H="$HOOK_DIR/kernel-mandate-role-gate.sh"

PU_TMP=$(mktemp -d)
mkdir -p "$PU_TMP/bin" "$PU_TMP/proj/.claude" "$PU_TMP/proj/tests"
if sed --version >/dev/null 2>&1; then
  PU_REAL_SED=$(command -v sed)
  cat > "$PU_TMP/bin/sed" <<EOF
#!/bin/bash
for a in "\$@"; do
  case "\$a" in ':'[a-z]*';'*|*[';{ ']':'[a-z]*';'*|*[';{ '][bt]';'*|*[';{ ']b[a-z]*'}'*) echo "sed: undefined label" >&2; exit 1 ;; esac
  case "\$a" in s*'\n'*) echo "sed: BSD would insert a literal n" >&2; exit 1 ;; esac
done
exec "$PU_REAL_SED" "\$@"
EOF
  chmod +x "$PU_TMP/bin/sed"
fi
cat > "$PU_TMP/proj/.claude/kernel-mandate.json" <<'JSON'
{ "kernelMandateVersion": 1, "name": "portable", "settings": { "mainSessionRole": "author" },
  "roles": { "author": { "description": "authors and runs tests", "tools": { "allow": ["Bash", "Write", "Edit", "Read"] },
    "read": { "allow": ["tests/**"] }, "write": { "allow": ["tests/**"], "codeImports": ["@playwright/test"] },
    "bash": { "groups": ["runs"] } } },
  "commandGroups": { "runs": ["^npx playwright test\\b", "^jq\\b"] } }
JSON
export KERNEL_MANDATE_MANIFEST="$PU_TMP/proj/.claude/kernel-mandate.json" KERNEL_MANDATE_STATE_DIR="$PU_TMP/state"
PU_PATH="$PATH"
export PATH="$PU_TMP/bin:$PATH"
pu_write() { payload tool_name=Write file_path="$PU_TMP/proj/tests/a.spec.ts" content="$1" cwd="$PU_TMP/proj"; }
pu_bash() { payload tool_name=Bash command="$1" cwd="$PU_TMP/proj"; }

section "portable userland: import screen"
assert_deny  "$H" "$(pu_write 'import "dotenv/config";')"                 "side-effect import of an undeclared package → DENY" "dotenv"
assert_deny  "$H" "$(pu_write 'const g = require("glob");')"              "require of an undeclared package → DENY" "glob"
assert_deny  "$H" "$(pu_write 'import { test } from "@playwright/test"; import "dotenv/config";')" \
  "undeclared import after a declared one → DENY" "dotenv"
assert_allow "$H" "$(pu_write 'import { test } from "@playwright/test";')" "declared package → ALLOW"
assert_allow "$H" "$(pu_write 'import x from "./helpers";')"              "relative import → ALLOW"
assert_allow "$H" "$(pu_write 'const n = 1;')"                            "code without imports → ALLOW"

section "portable userland: command segmentation"
assert_deny  "$H" "$(pu_bash 'npx playwright test && cat .env')"          "second segment outside the group → DENY"
assert_allow "$H" "$(pu_bash 'npx playwright test \
  --list')"                                                              "backslash-continued allowed command → ALLOW"
assert_deny  "$H" "$(pu_bash 'npx playwright test \
  .claude/kernel-mandate.json')"                                         "continued operand naming the manifest → DENY"

section "portable userland: a failing screen denies"
# pu_break <tool> <substring> — PATH gains a <tool> that exits 2 when any
# argument contains the substring and runs the real tool otherwise, so
# one stage of one pipeline fails while everything around it works.
pu_break() {
  local real; real=$(PATH="$PU_TMP/bin:$PU_PATH" command -v "$1")
  rm -rf "$PU_TMP/broken"; mkdir -p "$PU_TMP/broken"
  printf '#!/bin/bash\nsub=%q\nfor a in "$@"; do case "$a" in *"$sub"*) exit 2 ;; esac; done\nexec %q "$@"\n' "$2" "$real" > "$PU_TMP/broken/$1"
  chmod +x "$PU_TMP/broken/$1"
  export PATH="$PU_TMP/broken:$PU_TMP/bin:$PU_PATH"
}
pu_break sort -u
assert_deny  "$H" "$(pu_write 'import { test } from "@playwright/test";')" \
  "import screen whose last stage (sort) fails → DENY" "could not screen this file's imports"
pu_break sed '"([^"]+)"'
assert_deny  "$H" "$(pu_write 'import { test } from "@playwright/test";')" \
  "import screen whose specifier sed fails mid-pipeline → DENY" "could not screen this file's imports"
pu_break awk 'gsub(/&&'
assert_deny  "$H" "$(pu_bash 'npx playwright test')" \
  "command segmenter whose awk fails → DENY" "could not screen this command's segments"
pu_break awk 'gsub(/[;&|]+/'
assert_deny  "$H" "$(pu_bash 'npx playwright test .claude/kernel-mandate.json')" \
  "self-protect operand scan whose awk fails → DENY" "could not screen this command's operands"
pu_break sed '/dev\/(null'
assert_deny  "$H" "$(pu_bash 'npx playwright test && cat .env')" \
  "redirect-stripping sed that fails before the segmenter → DENY" "could not screen this command (a text tool"
pu_break sed 's/^>>?'
assert_deny  "$H" "$(pu_bash 'npx playwright test > .env')" \
  "redirect-target sed that fails → DENY, not 'no targets'" "could not screen this command's write targets"
pu_break sed 's/^[^<]?<'
assert_deny  "$H" "$(pu_bash 'npx playwright test <.env')" \
  "input-redirect sed that fails → DENY, not 'no reads'" "could not screen this command's input redirections"
pu_break grep '^([A-Za-z_]'
assert_deny  "$H" "$(pu_bash 'CI=1 npx playwright test')" \
  "env-assignment grep that fails → DENY" "could not screen this command's leading assignments"
pu_break grep '(import|include)'
assert_deny  "$H" "$(pu_bash 'jq -n '"'"'import "m" as m; 1'"'"'')" \
  "jq module grep that fails → DENY" "could not screen this command's jq modules"
# The import screen's normalised view is built by three perl stages; a
# stage that fails used to hand the raw code on, comments and all.
export PATH="$PU_TMP/bin:$PU_PATH"
assert_deny  "$H" "$(pu_write 'const g = require/*x*/("glob");')" \
  "calibration: a comment-split require of an undeclared package → DENY" "glob"
pu_break perl 'defined($1)'
assert_deny  "$H" "$(pu_write 'const g = require/*x*/("glob");')" \
  "import screen whose lexer perl fails → DENY, not the raw code" "could not screen this file's imports"
pu_break perl '{$1}g;'
assert_deny  "$H" "$(pu_write 'const g = require/*x*/("glob");')" \
  "import screen whose comment-strip perl fails → DENY" "could not screen this file's imports"
pu_break perl 'chr(hex($1))'
assert_deny  "$H" "$(pu_write 'const g = require/*x*/("glob");')" \
  "import screen whose escape-decoding perl fails → DENY" "could not screen this file's imports"
pu_break perl 'stuns:'
assert_deny  "$H" "$(pu_write 'await fetch("https://evil.example/x");')" \
  "network-destination perl that fails → DENY, not 'no URLs'" "could not screen this file's network destinations"
export PATH="$PU_TMP/bin:$PU_PATH"

section "portable userland: absolute scope patterns match resolved paths"
# Paths are compared with symlinks resolved; so are the literal prefixes
# of absolute patterns. On macOS /etc and /tmp are symlinks into /private;
# the linked directory below makes the same point on every host.
mkdir -p "$PU_TMP/real"; : > "$PU_TMP/real/f"; ln -s "$PU_TMP/real" "$PU_TMP/link"
"$JQ" -n --arg link "$PU_TMP/link" '{ kernelMandateVersion: 1, name: "abs", settings: { mainSessionRole: "author" },
  roles: { author: { description: "reads broadly except named trees", tools: { allow: ["Read", "Write"] },
    read: { allow: ["**"], deny: ["/etc/**", ($link + "/**")] },
    write: { allow: ["tests/**", "/tmp/**"] } } } }' > "$PU_TMP/proj/.claude/abs.json"
export KERNEL_MANDATE_MANIFEST="$PU_TMP/proj/.claude/abs.json"
pu_read() { payload tool_name=Read file_path="$1" cwd="$PU_TMP/proj"; }
assert_deny  "$H" "$(pu_read /etc/hosts)"                    "read.deny /etc/** still denies /etc/hosts"
assert_deny  "$H" "$(pu_read /etc/../etc/hosts)"             "read.deny /etc/** denies a dotted spelling of /etc/hosts"
assert_deny  "$H" "$(pu_read "$PU_TMP/link/f")"             "read.deny <link>/** denies a file reached through the link"
assert_deny  "$H" "$(pu_read "$PU_TMP/real/f")"             "read.deny <link>/** denies the same file by its real path"
assert_allow "$H" "$(pu_read "$PU_TMP/proj/tests/a.spec.ts")" "calibration: read outside the denied trees → ALLOW"
assert_allow "$H" "$(payload tool_name=Write file_path=/tmp/km-68-probe.txt content=x cwd="$PU_TMP/proj")" \
  "write.allow /tmp/** allows /tmp/x"

# A wildcard at or above the link has no literal prefix to resolve, so a
# deny list is also matched against the path as written.
"$JQ" -n --arg link "$PU_TMP/lin" '{ kernelMandateVersion: 1, name: "wild", settings: { mainSessionRole: "author" },
  roles: { author: { description: "reads broadly except named trees", tools: { allow: ["Read"] },
    read: { allow: ["**"], deny: ["/*/hosts", "/e*/**", "/tm?/**", ($link + "?/**")] } } } }' > "$PU_TMP/proj/.claude/wild.json"
export KERNEL_MANDATE_MANIFEST="$PU_TMP/proj/.claude/wild.json"
assert_deny  "$H" "$(pu_read /etc/hosts)"                    "read.deny /*/hosts denies /etc/hosts" "explicitly denied"
assert_deny  "$H" "$(pu_read /etc/passwd)"                   "read.deny /e*/** denies /etc/passwd" "explicitly denied"
assert_deny  "$H" "$(pu_read /tmp/zz)"                       "read.deny /tm?/** denies /tmp/zz" "explicitly denied"
assert_deny  "$H" "$(pu_read "$PU_TMP/link/f")"             "read.deny <lin>?/** denies a file reached through the link" "explicitly denied"
assert_allow "$H" "$(pu_read "$PU_TMP/proj/tests/a.spec.ts")" "calibration: wildcard denies leave other paths alone → ALLOW"

# Scope matching runs no text tool: with every sed broken, a deny still
# denies on its pattern and an allow still allows.
pu_break sed ''
assert_deny  "$H" "$(pu_read /etc/passwd)"                   "with sed broken, read.deny still matches" "explicitly denied"
assert_allow "$H" "$(pu_read "$PU_TMP/proj/tests/a.spec.ts")" "with sed broken, an in-scope read → ALLOW"

section "portable userland: dispatch tags"
cat > "$PU_TMP/proj/.claude/dispatch.json" <<'JSON'
{ "kernelMandateVersion": 1, "name": "dispatch", "settings": { "mainSessionRole": "orch" },
  "roles": { "orch": { "description": "dispatches", "tools": { "allow": ["Agent"] }, "dispatch": ["worker"] },
    "worker": { "description": "works", "tools": { "allow": ["Read"] }, "read": { "allow": ["tests/**"] } } } }
JSON
export KERNEL_MANDATE_MANIFEST="$PU_TMP/proj/.claude/dispatch.json"
pu_dispatch() { payload tool_name=Agent description='worker-x: work' prompt="$1" tool_use_id="$2" cwd="$PU_TMP/proj"; }
export PATH="$PU_TMP/bin:$PU_PATH"
assert_allow "$H" "$(pu_dispatch '<<kernel-mandate-role: worker>>
do it' pt1)" "calibration: a clean tagged dispatch → ALLOW"
pu_break grep 'kernel-mandate-role[^>]*'
assert_deny  "$H" "$(pu_dispatch '<<kernel-mandate-role: worker>>
do it' pt2)" "near-tag grep that fails → DENY, not 'no foreign tags'" "could not screen this dispatch's role tags"
# This sed runs only in kernel_mandate_tag_roles: the near-tag and
# binding-tag checks before it are grep alone, so the foreign-tag
# extraction is the stage that fails.
pu_break sed 'kernel-mandate-role: ([a-z]'
assert_deny  "$H" "$(pu_dispatch '<<kernel-mandate-role: worker>>
do it' pt3)" "foreign-tag sed that fails → DENY, not 'no foreign tags'" "could not screen this dispatch's role tags"

section "portable userland: the resolver's tag extraction fails closed"
# Rung 4b binds a child by the tag in its transcript. A failure there left
# the agent unbound, and the unboundAgentPolicy default (readonly: the
# union of every role's read.allow) is wider than the role it was sent as.
printf '%s\n' '{"type":"user","content":"<<kernel-mandate-role: worker>> do it"}' > "$PU_TMP/child.jsonl"
pu_child() { payload tool_name=Read file_path="$PU_TMP/proj/tests/a.spec.ts" agent_id="$1" transcript_path="$PU_TMP/child.jsonl" cwd="$PU_TMP/proj"; }
export PATH="$PU_TMP/bin:$PU_PATH"
assert_allow "$H" "$(pu_child child-1)" "calibration: a tagged child binds worker and reads in scope → ALLOW"
pu_break sed 'kernel-mandate-role: ([a-z]'
assert_deny  "$H" "$(pu_child child-2)" "tag sed that fails while binding → DENY, not unbound" "could not screen this dispatch's role tags"
# The two stages before it: the awk that selects the dispatch line, and
# the grep that lifts the tags from it.
pu_break awk '"(type|role)"'
assert_deny  "$H" "$(pu_child child-3)" "transcript-line awk that fails → DENY, not unbound" "could not screen this dispatch's role tags"
pu_break grep 'kernel-mandate-role: [a-z]'
assert_deny  "$H" "$(pu_child child-4)" "tag-lifting grep that fails → DENY, not unbound" "could not screen this dispatch's role tags"
# And a child whose transcript is not its own stays unbound rather than
# denied: the judge-only read is refused under the unboundAgentPolicy.
printf '%s\n' '{"type":"user","content":"no tag here"}' > "$PU_TMP/child.jsonl"
export PATH="$PU_TMP/bin:$PU_PATH"
assert_allow "$H" "$(pu_child child-5)" "calibration: an untagged transcript with the tools working → unbound, readonly ALLOW"

section "portable userland: relative denies stay inside the project"
# The lexical half of a deny check is project-relative: `**/build/**`
# must not match a `build/` directory ABOVE the project.
mkdir -p "$PU_TMP/build/proj/.claude" "$PU_TMP/build/proj/src" "$PU_TMP/build/proj/build"
: > "$PU_TMP/build/proj/src/a.ts"; : > "$PU_TMP/build/proj/build/out.js"
cat > "$PU_TMP/build/proj/.claude/kernel-mandate.json" <<'JSON'
{ "kernelMandateVersion": 1, "name": "nested", "settings": { "mainSessionRole": "author" },
  "roles": { "author": { "description": "reads all but build output", "tools": { "allow": ["Read", "Bash"] },
    "read": { "allow": ["**"], "deny": ["**/build/**"] }, "bash": { "groups": ["look"] } } },
  "commandGroups": { "look": ["^cat\\b"] } }
JSON
export KERNEL_MANDATE_MANIFEST="$PU_TMP/build/proj/.claude/kernel-mandate.json" PATH="$PU_TMP/bin:$PU_PATH"
pu_nread() { payload tool_name=Read file_path="$1" cwd="$PU_TMP/build/proj"; }
assert_allow "$H" "$(pu_nread src/a.ts)"                       "project under build/: relative read → ALLOW"
assert_allow "$H" "$(pu_nread "$PU_TMP/build/proj/src/a.ts")"  "project under build/: absolute read → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='cat src/a.ts' cwd="$PU_TMP/build/proj")" \
  "project under build/: Bash read → ALLOW"
assert_deny  "$H" "$(pu_nread build/out.js)"                   "the project's own build/ is still denied" "explicitly denied"
# The same project reached through a symlinked spelling of its root; the
# spelling keeps a `build/` component so a relative `**/build/**` could
# match it as written.
mkdir -p "$PU_TMP/alt"; ln -s "$PU_TMP/build" "$PU_TMP/alt/build"
PU_PHYS=$(cd "$PU_TMP/build/proj" && pwd -P); PU_LINK="$PU_TMP/alt/build/proj"
assert_allow "$H" "$(payload tool_name=Read file_path=src/a.ts cwd="$PU_LINK")" \
  "project under build/, cwd through a link: relative read → ALLOW"
assert_deny  "$H" "$(payload tool_name=Read file_path=build/out.js cwd="$PU_LINK")" \
  "project under build/, cwd through a link: own build/ → DENY" "explicitly denied"
# Cross-spelling: the cwd is physical and the path is written through the
# link, so its lexical form never becomes project-relative; the physical
# half decides, and `**/build/**` must not reach the ancestor `build/`.
assert_allow "$H" "$(payload tool_name=Read file_path="$PU_LINK/src/a.ts" cwd="$PU_PHYS")" \
  "physical cwd, path written through the link: relative deny leaves src/ alone → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command="cat $PU_LINK/src/a.ts" cwd="$PU_PHYS")" \
  "physical cwd, Bash read written through the link → ALLOW"
assert_deny  "$H" "$(payload tool_name=Read file_path="$PU_LINK/build/out.js" cwd="$PU_PHYS")" \
  "physical cwd, own build/ written through the link → DENY" "explicitly denied"

section "portable userland: an absolute deny names a tree inside the project"
# `<root>/secret/**` denies `secret/k` whether the pattern spells the root
# physically or through the link, and whichever spelling cwd uses.
mkdir -p "$PU_TMP/build/proj/secret"; : > "$PU_TMP/build/proj/secret/k"
pu_abs_manifest() { # <root spelling>
  "$JQ" -n --arg root "$1" '{ kernelMandateVersion: 1, name: "abs-in", settings: { mainSessionRole: "author" },
    roles: { author: { description: "reads all but one tree", tools: { allow: ["Read", "Bash"] },
      read: { allow: ["**", "/**"], deny: [($root + "/secret/**")] }, bash: { groups: ["look"] } } },
    commandGroups: { look: ["^cat\\b"] } }' > "$PU_TMP/build/proj/.claude/abs-in.json"
}
export KERNEL_MANDATE_MANIFEST="$PU_TMP/build/proj/.claude/abs-in.json"
pu_abs_manifest "$PU_PHYS"
assert_deny  "$H" "$(payload tool_name=Read file_path=secret/k cwd="$PU_PHYS")" \
  "physical pattern, physical cwd, relative path → DENY" "explicitly denied"
assert_deny  "$H" "$(payload tool_name=Read file_path="$PU_PHYS/secret/k" cwd="$PU_PHYS")" \
  "physical pattern, physical cwd, absolute path → DENY" "explicitly denied"
assert_deny  "$H" "$(payload tool_name=Bash command='cat secret/k' cwd="$PU_PHYS")" \
  "physical pattern, physical cwd, Bash read → DENY"
assert_deny  "$H" "$(payload tool_name=Read file_path=secret/k cwd="$PU_LINK")" \
  "physical pattern, cwd through the link, relative path → DENY" "explicitly denied"
assert_deny  "$H" "$(payload tool_name=Read file_path="$PU_LINK/secret/k" cwd="$PU_LINK")" \
  "physical pattern, absolute path through the link → DENY" "explicitly denied"
assert_allow "$H" "$(payload tool_name=Read file_path=src/a.ts cwd="$PU_PHYS")" \
  "calibration: a sibling tree → ALLOW"
pu_abs_manifest "$PU_LINK"
assert_deny  "$H" "$(payload tool_name=Read file_path=secret/k cwd="$PU_LINK")" \
  "linked pattern, cwd through the link, relative path → DENY" "explicitly denied"
assert_deny  "$H" "$(payload tool_name=Read file_path=secret/k cwd="$PU_PHYS")" \
  "linked pattern, physical cwd, relative path → DENY" "explicitly denied"
assert_deny  "$H" "$(payload tool_name=Bash command="cat $PU_PHYS/secret/k" cwd="$PU_LINK")" \
  "linked pattern, Bash read by the physical absolute path → DENY"
assert_allow "$H" "$(payload tool_name=Read file_path=src/a.ts cwd="$PU_LINK")" \
  "calibration: a sibling tree through the link → ALLOW"

export PATH="$PU_PATH"
unset KERNEL_MANDATE_MANIFEST KERNEL_MANDATE_STATE_DIR PU_PATH PU_REAL_SED PU_PHYS PU_LINK
rm -rf "$PU_TMP"
