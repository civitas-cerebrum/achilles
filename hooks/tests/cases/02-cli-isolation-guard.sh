#!/bin/bash
H="$HOOK_DIR/playwright-cli-isolation-guard.sh"

section "cli-isolation: role-prefix slugs allowed"
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=composer-j-checkout-1-c1 open --browser=chromium http://app')" "composer-j- slug → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=reviewer-j-checkout-1-c1 open --browser=chromium http://app')" "reviewer-j- slug → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=probe-j-checkout-4 open --browser=chromium http://app')" "probe-j- slug → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=composer-sj-pay-1-c1 open --browser=chromium http://app')" "composer-sj- slug → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=test-composer-j-x-1-c1 open --browser=chromium http://app')" "test-composer-j- slug (kernel-mandate role spelling) → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=phase1-root open --browser=chromium http://app')" "phase1- slug → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=phase2-mkt open --browser=chromium http://app')" "phase2- slug → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=stage2-cart-form open --browser=chromium http://app')" "stage2- slug → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=cleanup-ledger open --browser=chromium http://app')" "cleanup- slug → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=companion-onb-form open --browser=chromium http://app')" "companion- slug → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=fd-cart-flake open --browser=chromium http://app')" "fd- slug → ALLOW"

section "cli-isolation: bare j- / sj- slugs denied (role-ambiguous)"
assert_deny "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=j-checkout-3-stage-a open --browser=chromium http://app')" "bare j- slug → DENY" "missing role prefix"
assert_deny "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=sj-checkout-pay-1 open --browser=chromium http://app')" "bare sj- slug → DENY" "missing role prefix"

section "cli-isolation: missing -s= flag"
assert_deny "$H" "$(payload tool_name=Bash command='npx playwright-cli open --browser=chromium http://app')" "no -s= → DENY" "Missing -s=<slug> flag"
assert_deny "$H" "$(payload tool_name=Bash command='npx playwright-cli snapshot')" "no -s= on snapshot → DENY"

section "cli-isolation: collision-prone reserved slugs"
for reserved in default test session temp tmp x y main; do
  assert_deny "$H" "$(payload tool_name=Bash command="npx playwright-cli -s=${reserved} open --browser=chromium http://app")" "reserved slug '${reserved}' → DENY" "collision-prone"
done

section "cli-isolation: length cap (≥6, ≤28)"
assert_deny "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=fd-x open --browser=chromium http://app')" "5-char slug 'fd-x' → DENY" "too short"
assert_deny "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=composer-j-marketplace-buy-1-c1 open --browser=chromium http://app')" "31-char slug → DENY" "too long"
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=composer-j-x-1-c1 open --browser=chromium http://app')" "17-char slug → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=composer-j-checkout-bd-1c-c1 open --browser=chromium http://app')" "28-char slug at cap → ALLOW"

section "cli-isolation: session-agnostic subcommands skip the gate"
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli close-all')" "close-all → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli kill-all')" "kill-all → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli list')" "list → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli install-browser chromium')" "install-browser → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli --version')" "--version → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli --help')" "--help → ALLOW"

section "cli-isolation: tool-name filtering"
assert_allow "$H" "$(payload tool_name=Read file_path=/tmp/x)" "Read invocation → silent allow"
assert_allow "$H" "$(payload tool_name=Agent description='composer-j-x:' prompt='x')" "Agent invocation → silent allow"

section "cli-isolation: command-line forms"
assert_allow "$H" "$(payload tool_name=Bash command='npx playwright-cli -s composer-j-x-1-c1 open --browser=chromium http://app')" "-s <slug> space form → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='bunx playwright-cli -s=composer-j-x-1-c1 open --browser=chromium http://app')" "bunx runner → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='pnpm exec playwright-cli -s=composer-j-x-1-c1 open --browser=chromium http://app')" "pnpm exec runner → ALLOW"

section "cli-isolation: noise (playwright-cli mentioned inside string)"
assert_allow "$H" "$(payload tool_name=Bash command='echo \"playwright-cli is great\"')" "playwright-cli inside echo → silent allow"
# Observed false positive: a quoted argument that contains a separator before the tool name.
assert_allow "$H" "$(payload tool_name=Bash command="printf 'Run: cd app && playwright-cli open http://x\n' > notes.md")" "printf of a usage line → silent allow"
assert_allow "$H" "$(payload tool_name=Bash command="printf 'step 1; npx playwright-cli open\n'")" "quoted ';' before the tool name → silent allow"
assert_allow "$H" "$(payload tool_name=Bash command="git commit -m 'docs: x | playwright-cli snapshot needs -s'")" "quoted '|' in a commit message → silent allow"
assert_allow "$H" "$(payload tool_name=Bash command='cat > notes.md <<EOF
npx playwright-cli open http://app
EOF')" "heredoc body written to a file → silent allow"
assert_allow "$H" "$(payload tool_name=Bash command='command -v playwright-cli')" "command -v lookup → silent allow"

section "cli-isolation: invocations are judged wherever the shell runs them"
assert_deny "$H" "$(payload tool_name=Bash command='cd app && npx playwright-cli open http://x')" "after && → DENY" "Missing -s=<slug> flag"
assert_deny "$H" "$(payload tool_name=Bash command='"playwright-cli" open http://x')" "quoted command word → DENY" "Missing -s=<slug> flag"
assert_deny "$H" "$(payload tool_name=Bash command='FOO=1 npx playwright-cli open http://x')" "after an assignment → DENY" "Missing -s=<slug> flag"
assert_deny "$H" "$(payload tool_name=Bash command="bash -c 'npx playwright-cli open http://x'")" "inside bash -c → DENY" "Missing -s=<slug> flag"
assert_deny "$H" "$(payload tool_name=Bash command='out=$(npx playwright-cli open http://x)')" "inside \$( ) → DENY" "Missing -s=<slug> flag"
assert_deny "$H" "$(payload tool_name=Bash command="echo '-s=composer-j-x-1-c1'; npx playwright-cli open http://x")" "a slug in another command does not count → DENY" "Missing -s=<slug> flag"
assert_deny "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=composer-j-x-1-c1 open; npx playwright-cli -s=j-x-1 open')" "every invocation is judged → DENY" "missing role prefix"

section "cli-isolation: package specs, wrapper options and shell keywords before the invocation"
for c in 'npx @playwright/cli open http://x' 'npx @playwright/cli@1.2.0 open http://x' 'npx playwright-cli@latest open http://x' \
         'npx -p @playwright/cli playwright-cli open http://x' 'npx --package=@playwright/cli playwright-cli open http://x' \
         'npm exec -- playwright-cli open http://x' 'sudo -u me playwright-cli open http://x' 'env -u FOO playwright-cli open http://x' \
         'env -C /tmp playwright-cli open http://x' 'env --chdir=/tmp playwright-cli open http://x' 'env --chdir /tmp playwright-cli open http://x' \
         'sudo -D /tmp playwright-cli open http://x' \
         './node_modules/.bin/playwright-cli open http://x' 'if npx playwright-cli open http://x; then echo ok; fi'; do
  assert_deny "$H" "$(payload tool_name=Bash command="$c")" "$c → DENY" "Missing -s=<slug> flag"
done
assert_allow "$H" "$(payload tool_name=Bash command='npx -p @playwright/cli playwright-cli -s=composer-j-x-1-c1 open http://x')" "-p package then a slugged invocation → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='npx @playwright/cli -s=composer-j-x-1-c1 open http://x')" "@playwright/cli with a slug → ALLOW"


# wrappers peel only known options, so an invocation reached through exec -a,
# stdbuf --output, sudo --user, nice --adjustment, xargs --max-args, env -S, doas -u, npx
# --package or after a bare assignment is still seen as a playwright-cli invocation.
section "cli-isolation r5: invocations behind wrapper options"
for c in \
  'exec -a foo playwright-cli open https://x' \
  'stdbuf --output L playwright-cli open https://x' \
  'sudo --user me playwright-cli open https://x' \
  'nice --adjustment 5 playwright-cli open https://x' \
  'doas -u me playwright-cli open https://x' \
  'npx --package @playwright/cli playwright-cli open https://x' \
  'PATH=/tmp; playwright-cli open https://x'; do
  assert_deny "$H" "$(payload tool_name=Bash command="$c")" "$c → DENY" "Missing -s=<slug> flag"
done
assert_deny "$H" "$(payload tool_name=Bash command='xargs --max-args 1 playwright-cli open < /tmp/u')" "xargs --max-args peeled → DENY" "Missing -s=<slug> flag"

section "cli-isolation: brace groups, function bodies, reserved words and wrapper options with arguments"
for c in \
  '{ playwright-cli open https://x; }' \
  'true && { playwright-cli open https://x; }' \
  '{ { playwright-cli open https://x; }; }' \
  'f() { playwright-cli open https://x; }; f' \
  'function f { playwright-cli open https://x; }; f' \
  'function f() { playwright-cli open https://x; }; f' \
  'coproc playwright-cli open https://x' \
  'coproc P { playwright-cli open https://x; }' \
  'nice -5 playwright-cli open https://x' \
  'nice -n5 playwright-cli open https://x' \
  'time -p playwright-cli open https://x' \
  'time -o /tmp/t playwright-cli open https://x' \
  'env -P /usr/bin playwright-cli open https://x' \
  'env -i -P /usr/bin playwright-cli open https://x' \
  'exec -c playwright-cli open https://x' \
  'exec -cl -a n playwright-cli open https://x'; do
  assert_deny "$H" "$(payload tool_name=Bash command="$c")" "$c → DENY" "Missing -s=<slug> flag"
done
assert_deny "$H" "$(payload tool_name=Bash command='{ playwright-cli -s=j-x-1 open https://x; }')" "brace group: the slug is judged too → DENY" "missing role prefix"
assert_deny "$H" "$(payload tool_name=Bash command='nice --bogus playwright-cli -s=composer-j-x-1-c1 open https://x')" "unrecognised wrapper option before the program → DENY" "wrapper option"
assert_allow "$H" "$(payload tool_name=Bash command='{ playwright-cli -s=composer-j-x-1-c1 open https://x; }')" "brace group with a slug → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='f() { playwright-cli -s=composer-j-x-1-c1 open https://x; }; f')" "function body with a slug → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='nice -5 playwright-cli -s=composer-j-x-1-c1 open https://x')" "nice -5 with a slug → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='time -p playwright-cli -s=composer-j-x-1-c1 open https://x')" "time -p with a slug → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='echo "{ playwright-cli open https://x; }"')" "quoted brace group → silent allow"
assert_allow "$H" "$(payload tool_name=Bash command='echo "f() { playwright-cli open; }"')" "quoted function definition → silent allow"
assert_allow "$H" "$(payload tool_name=Bash command='nice --bogus ls')" "unrecognised wrapper option before another program → silent allow"

# playwright-cli in any word of a command the guard cannot identify as playwright-cli itself, a
# shell whose script is judged as nested commands, or a closed list of non-executing readers is DENY.
section "cli-isolation: unrecognised = unsafe for any command that mentions playwright-cli"
for c in \
  "env -S 'playwright-cli\\_open\\_https://x'" \
  "env -S'playwright-cli\\_open'" \
  "env --split-string='playwright-cli\\_open'" \
  'setsid playwright-cli open https://x' \
  'watch playwright-cli open https://x' \
  'script -c "playwright-cli open https://x"' \
  'script -q /dev/null playwright-cli open https://x' \
  'flock /tmp/l playwright-cli open https://x' \
  'parallel playwright-cli open ::: https://x' \
  'chroot / playwright-cli open https://x' \
  'unshare playwright-cli open https://x' \
  'ionice -c3 playwright-cli open https://x' \
  'taskset 1 playwright-cli open https://x' \
  'caffeinate playwright-cli open https://x' \
  'someunknownwrapper playwright-cli open https://x'; do
  assert_deny "$H" "$(payload tool_name=Bash command="$c")" "$c → DENY" "Cannot judge"
done
# A command string a wrapper runs is split and judged as its own command, as sh -c is.
for c in "env -S 'playwright-cli open https://x'" "npx -c 'playwright-cli open https://x'" \
         "npm exec -c 'playwright-cli open https://x'" "npx --call='playwright-cli open https://x'"; do
  assert_deny "$H" "$(payload tool_name=Bash command="$c")" "$c → DENY" "Missing -s=<slug> flag"
done
assert_allow "$H" "$(payload tool_name=Bash command="npx -c 'playwright-cli -s=composer-j-x-1-c1 open https://x'")" "npx -c with a slugged invocation → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command="env -S 'playwright-cli -s=composer-j-x-1-c1 open https://x'")" "env -S with a slugged invocation → ALLOW"

section "cli-isolation: the name in a spelling, word or text the guard must still see"
for c in \
  'PLAYWRIGHT-CLI open http://a' 'Playwright-Cli open http://a' 'node_modules/.bin/PLAYWRIGHT-CLI open http://a' 'npx PLAYWRIGHT-CLI open http://a' \
  'playwright-cl{i..i} open http://a' 'node_modules/.bin/playwright-c{l..l}i open http://a' './node_modules/.bin/playwright-cl? open http://a' \
  'node_modules/.bin/playwr*ght-cli open http://a' './node_modules/.bin/playwright-cl[i] open http://a' \
  'x=playwright-cli; $x open http://a' 'printf -v x playwright-cli; $x open http://a' 'read x <<< playwright-cli; $x open http://a' \
  "x=playwright-cli
\$x open http://a" \
  "bash -c '\"\$@\"' _ playwright-cli open http://a" "sh -c '\$0 open http://a' playwright-cli" "bash -c 'exec \"\$1\" open http://a' _ playwright-cli" \
  'xargs -I{} {} open http://a <<< playwright-cli' \
  "git grep -O'playwright-cli open http://a' hi" "git grep --open-files-in-pager='playwright-cli open' hi" \
  'FOO=playwright-cli env true'; do
  assert_deny "$H" "$(payload tool_name=Bash command="$c")" "$c → DENY"
done
assert_allow "$H" "$(payload tool_name=Bash command='PLAYWRIGHT-CLI -s=composer-j-x-1-c1 open http://a')" "case-variant name with a slug → ALLOW"
assert_allow "$H" "$(payload tool_name=Bash command='[ -f x ] && ls ./*.md')" "[ as a command word, glob in an operand → silent allow"
assert_allow "$H" "$(payload tool_name=Bash command='jq ".dependencies[\"@playwright/cli\"]" package.json')" "jq → silent allow"
assert_allow "$H" "$(payload tool_name=Bash command='pgrep -f playwright-cli')" "pgrep → silent allow"
assert_allow "$H" "$(payload tool_name=Bash command='npm ls @playwright/cli')" "npm ls → silent allow"
assert_allow "$H" "$(payload tool_name=Bash command='npm view @playwright/cli version')" "npm view → silent allow"
assert_allow "$H" "$(payload tool_name=Bash command='bash hooks/tests/cases/02-cli-isolation-guard.sh')" "a shell running a script whose path names the guard → silent allow"
assert_allow "$H" "$(payload tool_name=Bash command='printf "%s\n" "x=playwright-cli"')" "printf of an assignment-shaped string → silent allow"

assert_allow "$H" "$(payload tool_name=Bash command='grep -rn playwright-cli hooks/')" "grep for the name → silent allow"
assert_allow "$H" "$(payload tool_name=Bash command='cat playwright-cli-notes.md | head')" "cat of a file named after it → silent allow"
assert_allow "$H" "$(payload tool_name=Bash command='which playwright-cli')" "which → silent allow"
assert_allow "$H" "$(payload tool_name=Bash command='git log --grep playwright-cli')" "git log --grep → silent allow"
assert_allow "$H" "$(payload tool_name=Bash command='printf "%s\n" "npx playwright-cli open"')" "printf of a usage line → silent allow"
assert_allow "$H" "$(payload tool_name=Bash command='env -S "ls -l"')" "env -S naming another program → silent allow"
