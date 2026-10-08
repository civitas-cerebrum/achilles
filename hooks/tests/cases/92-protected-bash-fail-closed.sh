#!/bin/bash
# protected-artifact-bash-guard fails closed: a line that names a protected path, or a directory one
# lives in, is denied unless every command on it is a provably read-only command or a recognised
# writer whose targets all resolve outside the protected set. The probe list is the fix-round-1
# security review: every probe there is a write (or a metadata write) to a protected path.
HOOK="$HOOK_DIR/protected-artifact-bash-guard.sh"
bash_payload() { "$JQ" -n --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }

section "protected-bash fail-closed: writes, metadata writes and unprovable commands DENY"
while IFS= read -r c; do
  assert_deny "$HOOK" "$(bash_payload "$c")" "$c" "protected"
done <<'PROBES'
cat x > ~/.claude/settings.json
cat x >| ~/.claude/settings.json
cat x 1> ~/.claude/settings.json
cat x &> ~/.claude/settings.json
cat x >> ~/.claude/settings.json
cat x 2>&1 >~/.claude/settings.json
cat x>~/.claude/settings.json
echo x >~/.claude/hooks/a.sh
exec 3>~/.claude/settings.json; echo x >&3
exec 3<>~/.claude/settings.json; echo x >&3
echo x 1<>~/.claude/settings.json
echo x <>~/.claude/settings.json
echo x | tee -a ~/.claude/settings.json
echo x | tee --append ~/.claude/settings.json
dd if=x of=~/.claude/settings.json
dd if=x of=$HOME/.claude/settings.json
install -m 644 x ~/.claude/settings.json
install -m 644 -t ~/.claude/hooks x
install -D x ~/.claude/hooks/a.sh
cp -t ~/.claude/hooks x
cp --target-directory ~/.claude/hooks x
cp x y ~/.claude/hooks
cp x ~/.claude/hooks/
cp -r dir ~/.claude
cp x ~/.claude
mv x ~/.claude
mv -t ~/.claude/hooks x
mv x ~/.claude/settings.json
ln -sf /tmp/evil ~/.claude/settings.json
ln -sf /tmp/evil ~/.claude/hooks
ln -s /tmp/x ~/.claude/hooks/a.sh
rsync x ~/.claude/settings.json
rsync -a x/ ~/.claude/hooks/
patch ~/.claude/settings.json < p.diff
patch -p1 -d ~/.claude < p.diff
git -C ~/.claude checkout -- settings.json
git checkout -- ~/.claude/settings.json
git apply --directory=.claude p.diff
python3 -c 'open("/home/u/.claude/settings.json","w").write("x")'
python3 -c "import pathlib;pathlib.Path('/home/u/.claude/settings.json').write_text('x')"
node -e 'require("fs").writeFileSync("/home/u/.claude/settings.json","x")'
node -e 'require("fs").writeFileSync(process.env.HOME+"/.claude/settings.json","x")'
perl -pi -e 's/a/b/' ~/.claude/settings.json
perl -i -pe 's/a/b/' ~/.claude/settings.json
perl -i.bak -pe 's/a/b/' ~/.claude/settings.json
perl -e 'open F,">","/home/u/.claude/settings.json"'
ruby -i -pe 'gsub(/a/,"b")' ~/.claude/settings.json
ruby -e 'File.write("/home/u/.claude/settings.json","x")'
awk -i inplace '{print}' ~/.claude/settings.json
gawk -i inplace '{print}' ~/.claude/settings.json
awk '{print > "/home/u/.claude/settings.json"}' x
sed -i 's/a/b/' ~/.claude/settings.json
sed -i '' 's/a/b/' ~/.claude/settings.json
sed -i.bak 's/a/b/' ~/.claude/settings.json
sed -e 's/a/b/' -i ~/.claude/settings.json
sed --in-place=.bak 's/a/b/' ~/.claude/settings.json
sed -i -e 's/a/b/' ~/.claude/settings.json
sed -ie 's/a/b/' ~/.claude/settings.json
sed -Ei 's/a/b/' ~/.claude/settings.json
sed -n -i 's/a/b/p' ~/.claude/settings.json
sed 's/a/b/w /home/u/.claude/settings.json' x
sed -i -f script.sed ~/.claude/settings.json
sed -i -- 's/a/b/' ~/.claude/settings.json
ex -sc '%s/a/b/|x' ~/.claude/settings.json
vim -c '%s/a/b/|wq' ~/.claude/settings.json
vi -es -c 'wq' ~/.claude/settings.json
truncate -s0 ~/.claude/settings.json
chmod 777 ~/.claude/settings.json
chmod -R 777 ~/.claude/hooks
chown x ~/.claude/settings.json
touch ~/.claude/settings.json
touch ~/.claude/hooks/new.sh
rm ~/.claude/settings.json
rm -rf ~/.claude/hooks
unlink ~/.claude/settings.json
echo ~/.claude/settings.json | xargs rm
echo ~/.claude/settings.json | xargs -I{} cp x {}
find ~/.claude -name settings.json -delete
find ~/.claude -fprint ~/.claude/settings.json
find . -fprint ~/.claude/settings.json
curl -o ~/.claude/settings.json http://x
curl http://x -o ~/.claude/settings.json
curl --output ~/.claude/settings.json http://x
wget -O ~/.claude/settings.json http://x
tar -x -C ~/.claude -f a.tar
tar -xf a.tar -C ~/.claude/hooks
unzip -o a.zip -d ~/.claude
unzip -o a.zip -d ~/.claude/hooks
cpio -i -D ~/.claude/hooks
PROBES

section "protected-bash fail-closed: a write into any ancestor of a protected path DENIES"
while IFS= read -r c; do
  assert_deny "$HOOK" "$(bash_payload "$c")" "$c" "Writes into"
done <<'ANCESTORS'
rm -rf ~
rm -rf $HOME
rm -rf tests
rm -rf .
rm -rf ..
rm -rf /
rm -rf *
rm -rf tests/e2e/*
mv ~/.claude /tmp/x
chmod -R 777 ~
cp -r somedir/.claude ~
cp settings.json ~/.claude/
cp -r $SRC .
ANCESTORS

section "protected-bash fail-closed: git commands that can rewrite worktree files stay unprovable"
assert_deny "$HOOK" "$(bash_payload 'git checkout -- ~/.claude/settings.json')" "git checkout of a protected path" "Cannot prove"
assert_deny "$HOOK" "$(bash_payload 'git restore tests/e2e/docs/onboarding-status.json')" "git restore of the ledger" "Cannot prove"
assert_deny "$HOOK" "$(bash_payload 'git branch topic tests/e2e/docs/journey-map.md')" "git branch creating, on a line naming the journey map" "Cannot prove"

section "protected-bash fail-closed: writes beside, not above, protected paths ALLOW"
while IFS= read -r c; do
  assert_allow "$HOOK" "$(bash_payload "$c")" "$c"
done <<'NOT_ANCESTORS'
rm -rf /tmp/scratch
rm -rf node_modules
rm -f *.log
rm -rf tests/e2e/specs
cp x .
cp a.txt tests/e2e/
ln -s ../x .
mv build/out.js .
cp -r x ~
cp -r dist/* /tmp/out
git commit -m "fix: rebuild tests/e2e/docs/onboarding-status.json"
git -C . commit -m "docs: ~/.claude/settings.json" -- README.md
git add tests/e2e/docs/journey-map.md
git branch --list
git -c user.name=x commit -m "x" -- README.md
NOT_ANCESTORS

section "protected-bash fail-closed: provably safe lines naming a protected path ALLOW"
while IFS= read -r c; do
  assert_allow "$HOOK" "$(bash_payload "$c")" "$c"
done <<'SAFE'
sed -i '' 's/LEDGER_APPROVERS_NAME=.*/LEDGER_APPROVERS_NAME=".workflow-approvers.json"/' hooks/lib/ledger.sh
printf 'see ~/.claude/settings.json and tests/e2e/docs/journey-map.md\n'
cat ~/.claude/settings.json | grep hooks > /tmp/hooks.txt
jq .currentPhase tests/e2e/docs/onboarding-status.json
git -C ~/.claude log --oneline -3
git diff -- tests/e2e/docs/journey-map.md
sed -n 1,5p tests/e2e/docs/journey-map.md
find tests/e2e/docs -name '*.json'
cp tests/e2e/docs/onboarding-status.json /tmp/ledger.bak
ls -la ~/.claude/hooks 2>/dev/null | wc -l
SAFE

section "protected-bash fail-closed: the deny says what could not be proved"
assert_deny "$HOOK" "$(bash_payload 'awk 1 ~/.claude/settings.json')" "unknown command on a protected line" "Cannot prove this command does not write: .claude/settings.json"
assert_deny "$HOOK" "$(bash_payload 'cp x ~/.claude')" "cp into the directory the hook install lives in" "Writes into: .claude"

# the words bash runs are not the words typed (braces), a reader or writer is only
# itself when nothing on the line changes what it runs, and a line the guard cannot finish denies.
section "protected-bash fail-closed: brace expansion is judged as bash expands it"
while IFS= read -r c; do
  assert_deny "$HOOK" "$(bash_payload "$c")" "$c" "protected"
done <<'BRACES'
tee ~/.claude/settings{,}.json < x
tee ~/.claude/settings.{json,bak} < x
echo x | tee ~/.cl{a,}ude/settings.json
cp x ~/.cl{a,}ude/settings.json
rm -rf ~/.claude/hook{s,}
rm -rf ~/.claude/hook{a..z}
rm -rf tests/e2e/do{c,}s
BRACES
assert_deny "$HOOK" "$(bash_payload 'tee ~/.claude/settings{,}.json < x')" "the expanded word is the write target" "Writes into: .claude/settings.json"
for c in 'rm -rf {dist,build}' 'rm -rf dist/{a,b}' 'mkdir -p dist/{a,b}' "printf '%s\\n' {1..3} > /tmp/n" 'find . -name "*.json" -exec rm {} \;'; do
  assert_allow "$HOOK" "$(bash_payload "$c")" "$c"
done

section "protected-bash fail-closed: programs that run or write what the line hands them"
while IFS= read -r c; do
  assert_deny "$HOOK" "$(bash_payload "$c")" "$c" "Cannot prove"
done <<'HANDED'
sed -n '1w/home/u/.claude/settings.json' x
sed 's/a/b/w/home/u/.claude/settings.json' x
sed -n '1,3w /tmp/x' tests/e2e/docs/journey-map.md
sed '1e touch ~/.claude/settings.json' x
yq -s '"/home/u/.claude/hooks/evil"' x.yml
file -C -m ~/.claude/hooks/evil
echo 'echo x > ~/.claude/settings.json' > /tmp/p.sh; rg --pre bash . /tmp/p.sh
rg --pre=/tmp/p.sh x ~/.claude/settings.json
LESSOPEN='|sh -c "echo x > ~/.claude/settings.json" %s' less /etc/hosts
git -c core.fsmonitor='echo x > ~/.claude/settings.json' status
git -c diff.external='sh -c "echo x > ~/.claude/settings.json"' diff
git -c core.hooksPath=/tmp/h commit -m x ~/.claude/settings.json
git --exec-path=/tmp/x log ~/.claude/settings.json
git --config-env=core.pager=X log ~/.claude/settings.json
GIT_EXTERNAL_DIFF='sh -c "echo x > ~/.claude/settings.json"' git diff
git fetch --upload-pack='sh -c "echo x > ~/.claude/settings.json"' .
git grep --open-files-in-pager='sh -c "echo x>~/.claude/settings.json"' foo
git log --ext-diff -p ~/.claude/settings.json
PATH=/tmp cat ~/.claude/settings.json
env cat ~/.claude/settings.json
/tmp/grep -c 'echo x > ~/.claude/settings.json'
/tmp/cat -c 'echo x > ~/.claude/settings.json'
./cat ~/.claude/settings.json
/tmp/env cat ~/.claude/settings.json
HANDED
assert_deny "$HOOK" "$(bash_payload "/tmp/grep -c 'echo x > ~/.claude/settings.json'")" "a command word outside the system bin dirs is named" "grep: run from /tmp"
assert_allow "$HOOK" "$(bash_payload '/usr/bin/grep hooks ~/.claude/settings.json')" "a reader from a system bin dir"
assert_allow "$HOOK" "$(bash_payload 'LC_ALL=C sort x')" "an assignment before a command on a line naming nothing protected"

section "protected-bash fail-closed: an ln whose source is protected state is a write to it"
assert_deny "$HOOK" "$(bash_payload 'ln -s ~/.claude /tmp/l; echo x > /tmp/l/settings.json')" "link to the hook install dir" "Writes into"
assert_deny "$HOOK" "$(bash_payload 'ln -sf ~/.claude/settings.json /tmp/s && tee /tmp/s < x')" "link to a settings file" "Writes into"
assert_deny "$HOOK" "$(bash_payload 'ln -s ~ /tmp/h')" "link to an ancestor" "Writes into"
assert_allow "$HOOK" "$(bash_payload 'ln -s /bin/bash /tmp/sh2')" "link to an unrelated file"

section "protected-bash fail-closed: nested shells reached past their options"
assert_deny "$HOOK" "$(bash_payload "bash -o pipefail -c 'echo x > ~/.cl\"\"aude/settings.json'")" "bash -o pipefail -c" "Writes into"
assert_deny "$HOOK" "$(bash_payload "sh -e -o errexit -c 'echo x > ~/.cl\"\"aude/settings.json'")" "sh -e -o errexit -c" "Writes into"
assert_deny "$HOOK" "$(bash_payload "bash -O extglob -c 'echo x > ~/.cl\"\"aude/settings.json'")" "bash -O extglob -c" "Writes into"
assert_deny "$HOOK" "$(bash_payload "bash <<< 'echo x > ~/.cl\"\"aude/settings.json'")" "here-string fed to bash" "Writes into"

section "protected-bash fail-closed: a line the guard cannot finish denies"
PAD=$(printf 'w%.0s ' $(seq 1 17000))
assert_deny "$HOOK" "$(bash_payload "echo $PAD > /tmp/pad")" "33 KB line naming nothing → DENY" "too long to verify"
DOTS=""; for i in $(seq 1 41); do DOTS="$DOTS a$i/../b"; done
assert_deny "$HOOK" "$(bash_payload "ls $DOTS; f=~/.claude/x/../settings.json; echo x > \"\$f\"")" "41 paths to normalise, then a write through a variable → DENY" "over 40 paths"
assert_allow "$HOOK" "$(bash_payload "ls $DOTS; cat x")" "41 paths to normalise, every command provably safe → ALLOW"

section "protected-bash fail-closed: mkdir and touch are writers with judged targets"
for c in 'mkdir -p .claude && touch .claude/onboarding-stop-authorized' 'touch .claude/onboarding-stop-authorized' \
         'mkdir -p tests/e2e/docs && echo hi' 'mkdir -p tests/e2e/docs/.subagent-returns' \
         'while ! mkdir tests/e2e/docs/.adversarial-findings.lock 2>/dev/null; do sleep 0.2; done' \
         'touch -r tests/e2e/docs/journey-map.md /tmp/stamp' 'if grep -q x ~/.claude/settings.json; then echo ok; fi'; do
  assert_allow "$HOOK" "$(bash_payload "$c")" "$c"
done
assert_deny "$HOOK" "$(bash_payload 'mkdir ~/.claude/hooks/evil')" "mkdir inside the hook install" "Writes into: .claude/hooks"
assert_deny "$HOOK" "$(bash_payload 'mkdir -p .claude/achilles')" "mkdir of the activation state dir" "Writes into: .claude/achilles"
assert_deny "$HOOK" "$(bash_payload 'touch -d yesterday ~/.claude/settings.json')" "touch past its option value" "Writes into: .claude/settings.json"


# the guard inverts to UNRECOGNISED = UNSAFE. A sed script is safe only if it parses
# under a read-only grammar; writer options are parsed as full short clusters; wrappers peel only
# known options; an assignment/alias/function earlier on the line poisons later commands; git -c
# accepts only inert keys; ANSI-C quotes are scanned honouring escapes.
section "protected-bash fail-closed r5: sed scripts outside the read-only grammar DENY"
while IFS= read -r c; do
  assert_deny "$HOOK" "$(bash_payload "$c")" "$c" "Cannot prove"
done <<'SEDBAD'
sed 's|a|b|w /home/u/.claude/settings.json' x
sed 's#a#b#w ~/.claude/settings.json' x
sed '\%a%w ~/.claude/settings.json' x
sed -n --expression=1w\ ~/.claude/settings.json x
sed -n '1,3w /tmp/x' tests/e2e/docs/journey-map.md
sed '$w /tmp/x' tests/e2e/docs/journey-map.md
sed '1e touch ~/.claude/settings.json' x
SEDBAD
section "protected-bash fail-closed r5: sed options outside the allowlist DENY"
while IFS= read -r c; do
  assert_deny "$HOOK" "$(bash_payload "$c")" "$c" "protected"
done <<'SEDOPT'
sed -n --expr='1w ~/.claude/settings.json' x
sed -n --exp '1w ~/.claude/settings.json' x
sed -nf /tmp/s ~/.claude/settings.json
sed -I '' s/a/b/ ~/.claude/settings.json
sed -I.bak s/a/b/ ~/.claude/settings.json
sed --in-pl s/a/b/ ~/.claude/settings.json
sed -ni s/a/b/ ~/.claude/settings.json
sed -i -f script.sed ~/.claude/settings.json
SEDOPT
section "protected-bash fail-closed r5: read-only sed on a protected file ALLOWs"
while IFS= read -r c; do
  assert_allow "$HOOK" "$(bash_payload "$c")" "$c"
done <<'SEDOK'
sed -n /error/p tests/e2e/docs/journey-map.md
sed -n '/^## Journey/p' tests/e2e/docs/journey-map.md
sed -n s/x/eat/p tests/e2e/docs/journey-map.md
sed -n 1,5p tests/e2e/docs/onboarding-status.json
SEDOK

section "protected-bash fail-closed r5: writer short-cluster and target-dir forms DENY"
while IFS= read -r c; do
  assert_deny "$HOOK" "$(bash_payload "$c")" "$c" "protected"
done <<'WRITERS'
cp -t~/.claude/hooks /tmp/evil.sh
cp -vt ~/.claude/hooks /tmp/evil.sh
cp --target-dir=~/.claude/hooks /tmp/evil.sh
ln -sft ~/.claude/hooks /tmp/evil.sh
ln -sT /tmp/evil.sh ~/.claude/settings.json
mv -t~/.claude/hooks /tmp/evil.sh
install -Dt ~/.claude/hooks /tmp/evil.sh
WRITERS

section "protected-bash fail-closed r5: a wrapper's unrecognised/known options"
assert_deny "$HOOK" "$(bash_payload "exec -a grep sh -c 'echo x > ~/.claude/settings.json'")" "exec -a NAME peeled, then sh -c writes" "protected"
assert_deny "$HOOK" "$(bash_payload "exec -c sh -c 'echo x > ~/.claude/settings.json'")" "exec -c peeled, then sh -c writes" "protected"
assert_deny "$HOOK" "$(bash_payload "nice -n 5 sh -c 'echo x > ~/.claude/settings.json'")" "nice -n 5 peeled" "protected"
assert_deny "$HOOK" "$(bash_payload 'stdbuf -oL tee ~/.claude/settings.json < x')" "stdbuf -oL then tee" "protected"
assert_deny "$HOOK" "$(bash_payload "env -S 'sh -c \"echo x > ~/.claude/settings.json\"'")" "env -S runs its string" "protected"
assert_deny "$HOOK" "$(bash_payload 'sudo -E tee ~/.claude/settings.json < x')" "sudo -E flag then tee" "protected"
assert_allow "$HOOK" "$(bash_payload 'nice --adjustment 5 cat ~/.claude/settings.json')" "nice before a read ALLOWs"
assert_allow "$HOOK" "$(bash_payload 'timeout -s KILL 5 cat ~/.claude/settings.json')" "timeout before a read ALLOWs"
assert_allow "$HOOK" "$(bash_payload 'stdbuf --output=L cat ~/.claude/settings.json')" "stdbuf before a read ALLOWs"
assert_deny "$HOOK" "$(bash_payload 'nice --bogus cat ~/.claude/settings.json')" "an unrecognised wrapper option stays unsafe" "unrecognised option"

section "protected-bash fail-closed H1: brace groups, function bodies and wrapper options are peeled to the real command"
while IFS= read -r c; do
  assert_deny "$HOOK" "$(bash_payload "$c")" "$c" "protected"
done <<'PEELED_WRITES'
{ rm ~/.claude/settings.json; }
true && { rm ~/.claude/settings.json; }
f() { rm ~/.claude/settings.json; }; f
function f { rm ~/.claude/settings.json; }; f
function f() { rm ~/.claude/settings.json; }; f
coproc rm ~/.claude/settings.json
coproc P { rm ~/.claude/settings.json; }
nice -5 rm ~/.claude/settings.json
time -p rm ~/.claude/settings.json
env -P /bin rm ~/.claude/settings.json
exec -c rm ~/.claude/settings.json
{ nice -5 tee ~/.claude/settings.json < x; }
nice -5 sh -c 'echo x > ~/.claude/settings.json'
PEELED_WRITES
while IFS= read -r c; do
  assert_allow "$HOOK" "$(bash_payload "$c")" "$c"
done <<'PEELED_READS'
{ cat ~/.claude/settings.json; }
nice -5 cat ~/.claude/settings.json
time -p cat ~/.claude/settings.json
exec -c cat ~/.claude/settings.json
{ rm /tmp/junk; } ; cat ~/.claude/settings.json
echo "{ rm ~/.claude/settings.json; }"
echo "f() { rm ~/.claude/settings.json; }"
PEELED_READS
# The function name is a command word the guard cannot resolve, so a definition stays unsafe.
assert_deny "$HOOK" "$(bash_payload 'f() { cat ~/.claude/settings.json; }; f')" "a function definition names an unknown command" "protected"

section "protected-bash fail-closed r5: an assignment/alias/function poisons later commands"
while IFS= read -r c; do
  assert_deny "$HOOK" "$(bash_payload "$c")" "$c" "protected"
done <<'POISON'
PATH=/tmp/zz; cat -c 'echo x > ~/.claude/settings.json'
PATH=/tmp/zz:$PATH; grep -c 'echo x > ~/.claude/settings.json'
BASH_ENV=/tmp/e; bash -c 'cat ~/.claude/settings.json'
x=1; cat ~/.claude/settings.json
export PATH=/tmp; cat ~/.claude/settings.json
POISON
assert_allow "$HOOK" "$(bash_payload 'cat ~/.claude/settings.json; PATH=/usr/bin')" "an assignment AFTER a read does not poison it"

section "protected-bash fail-closed r5: git -c accepts only inert keys"
while IFS= read -r c; do
  assert_allow "$HOOK" "$(bash_payload "$c")" "$c"
done <<'GITOK'
git -c user.name=Feyzabora -c user.email=x commit -m "fix tests/e2e/docs/onboarding-status.json"
git commit -m "fix tests/e2e/docs/onboarding-status.json"
git -c core.quotepath=off status tests/e2e/docs/onboarding-status.json
git -C . commit -m "touch tests/e2e/docs/onboarding-status.json"
GITOK
assert_deny "$HOOK" "$(bash_payload "git -c alias.x='!echo x > ~/.cl\"\"aude/settings.json' x")" "git -c alias body runs through sh -c" "git -c"
assert_deny "$HOOK" "$(bash_payload 'git -c core.pager=x log tests/e2e/docs/journey-map.md')" "git -c core.pager is not inert" "git -c"
assert_deny "$HOOK" "$(bash_payload 'git log --output=tests/e2e/docs/onboarding-status.json')" "git --output writes a file" "git --output"

section "protected-bash fail-closed r5: ANSI-C quotes are scanned honouring escaped quotes"
assert_deny "$HOOK" "$(bash_payload "echo \$'a\\' b' >~/.claude/settings.json #'")" "escaped quote inside \$'...' does not end the string" "protected"
assert_deny "$HOOK" "$(bash_payload "echo \$'\\'' > ~/.claude/settings.json #'")" "\$'\\'' is a single quote, not the end of the word" "protected"
assert_deny "$HOOK" "$(bash_payload "echo x > \$'/home/u/\\x2eclaude/settings.json'")" "hex escape \\x2e decodes to a dot" "protected"


# Task F1b: assignment builtins poison the line like PATH=; a glued git -c<key>=<value> is parsed
# like the spaced form.
section "protected-bash fail-closed F1b: assignment builtins poison every later command"
while IFS= read -r c; do
  assert_deny "$HOOK" "$(bash_payload "$c")" "$c" "earlier on the line can redefine"
done <<'ASSIGN'
printf -v PATH /tmp/x; cat -c 'echo PWNED > ~/.claude/settings.json'
read PATH <<< /tmp/x; cat -c 'echo PWNED > ~/.claude/settings.json'
declare -n p=PATH; p=/tmp/x; cat -c 'echo PWNED > ~/.claude/settings.json'
printf -v x %s y; cat tests/e2e/docs/onboarding-status.json
mapfile -t PATH < /tmp/p; cat ~/.claude/settings.json
let x=1; cat ~/.claude/settings.json
ASSIGN
assert_allow "$HOOK" "$(bash_payload "printf '%s\\n' tests/e2e/docs/onboarding-status.json")" "printf without -v assigns nothing"
assert_allow "$HOOK" "$(bash_payload 'cat tests/e2e/docs/onboarding-status.json; printf -v x %s y')" "printf -v AFTER the read does not poison it"

section "protected-bash fail-closed F1b: glued git -c<key>=<value>"
assert_deny "$HOOK" "$(bash_payload 'git -ccore.pager=x log ~/.claude/settings.json')" "glued -c with a non-inert key" "git -c"
assert_allow "$HOOK" "$(bash_payload 'git -cuser.name=x commit -m "fix tests/e2e/docs/onboarding-status.json"')" "glued -c with an inert key"
