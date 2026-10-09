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
assert_deny "$H" "$(payload tool_name=Bash command="echo '-s=composer-j-x-1-c1'; npx playwright-cli open http://x")" "a slug in another command does not count → DENY" "Missing -s=<slug> flag"
assert_deny "$H" "$(payload tool_name=Bash command='npx playwright-cli -s=composer-j-x-1-c1 open; npx playwright-cli -s=j-x-1 open')" "every invocation is judged → DENY" "missing role prefix"

section "cli-isolation: package specs and runners before the invocation"
for c in 'npx @playwright/cli open http://x' 'npx @playwright/cli@1.2.0 open http://x' 'npx playwright-cli@latest open http://x' \
         'npm exec -- playwright-cli open http://x' 'env -C /tmp playwright-cli open http://x' \
         './node_modules/.bin/playwright-cli open http://x' 'if npx playwright-cli open http://x; then echo ok; fi'; do
  assert_deny "$H" "$(payload tool_name=Bash command="$c")" "$c → DENY" "Missing -s=<slug> flag"
done
assert_allow "$H" "$(payload tool_name=Bash command='npx @playwright/cli -s=composer-j-x-1-c1 open http://x')" "@playwright/cli with a slug → ALLOW"

# playwright-cli in a command the guard cannot identify as playwright-cli itself or a reader is DENY.
section "cli-isolation: unrecognised = unsafe for any command that mentions playwright-cli"
for c in 'setsid playwright-cli open https://x' 'someunknownwrapper playwright-cli open https://x'; do
  assert_deny "$H" "$(payload tool_name=Bash command="$c")" "$c → DENY" "Cannot judge"
done

section "cli-isolation: spellings and readers"
assert_deny "$H" "$(payload tool_name=Bash command='npx PLAYWRIGHT-CLI open http://a')" "case-variant name → DENY" "Missing -s=<slug> flag"
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
