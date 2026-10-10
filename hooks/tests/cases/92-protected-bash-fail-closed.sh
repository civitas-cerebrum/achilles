#!/bin/bash
# protected-artifact-bash-guard fails closed on the primary write forms: a line that names a protected
# path, or a directory one lives in, is denied unless every command on it is a reader or a recognised
# writer whose targets all resolve outside the protected set. Exotic shell forms are out of scope (KL-15).
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
assert_deny "$HOOK" "$(bash_payload 'git checkout -- ~/.claude/settings.json')" "git checkout of a protected path" "Writes into"
assert_deny "$HOOK" "$(bash_payload 'git restore tests/e2e/docs/onboarding-status.json')" "git restore of the ledger" "Writes into"
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
cat ~/.claude/settings.json | tee /tmp/out
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


section "protected-bash fail-closed: a reader by absolute path, an assignment before a command"
assert_allow "$HOOK" "$(bash_payload '/usr/bin/grep hooks ~/.claude/settings.json')" "a reader from a system bin dir"
assert_allow "$HOOK" "$(bash_payload 'LC_ALL=C sort x')" "an assignment before a command on a line naming nothing protected"

section "protected-bash fail-closed: an ln whose source is protected state is a write to it"
assert_deny "$HOOK" "$(bash_payload 'ln -s ~/.claude /tmp/l; echo x > /tmp/l/settings.json')" "link to the hook install dir" "Writes into"
assert_deny "$HOOK" "$(bash_payload 'ln -sf ~/.claude/settings.json /tmp/s && tee /tmp/s < x')" "link to a settings file" "Writes into"
assert_deny "$HOOK" "$(bash_payload 'ln -s ~ /tmp/h')" "link to an ancestor" "Writes into"
assert_allow "$HOOK" "$(bash_payload 'ln -s /bin/bash /tmp/sh2')" "link to an unrelated file"

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

section "protected-bash fail-closed: read-only sed on a protected file ALLOWs"
while IFS= read -r c; do
  assert_allow "$HOOK" "$(bash_payload "$c")" "$c"
done <<'SEDOK'
sed -n /error/p tests/e2e/docs/journey-map.md
sed -n '/^## Journey/p' tests/e2e/docs/journey-map.md
sed -n s/x/eat/p tests/e2e/docs/journey-map.md
sed -n 1,5p tests/e2e/docs/onboarding-status.json
SEDOK

section "protected-bash fail-closed: writer short-cluster and target-dir forms DENY"
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
section "protected-bash fail-closed: git -c / -C before a read or a commit ALLOW"
while IFS= read -r c; do
  assert_allow "$HOOK" "$(bash_payload "$c")" "$c"
done <<'GITOK'
git -c user.name=Feyzabora -c user.email=x commit -m "fix tests/e2e/docs/onboarding-status.json"
git commit -m "fix tests/e2e/docs/onboarding-status.json"
git -c core.quotepath=off status tests/e2e/docs/onboarding-status.json
git -C . commit -m "touch tests/e2e/docs/onboarding-status.json"
GITOK
# env -C DIR runs the command in DIR: its relative operands are judged there, not in the call's cwd.
section "protected-bash fail-closed: env -C / --chdir move the directory relative operands resolve in"
tmp_into CHDIR_TMP
mkdir -p "$CHDIR_TMP/proj/tests/e2e/docs" "$CHDIR_TMP/proj/src" "$CHDIR_TMP/elsewhere"
chdir_payload() { "$JQ" -n --arg c "$1" --arg d "$CHDIR_TMP/proj" '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}'; }
while IFS= read -r c; do
  assert_deny "$HOOK" "$(chdir_payload "$c")" "$c" "protected"
done <<'CHDIR'
env -C tests rm -r e2e
env -Ctests rm -r e2e
env --chdir=tests rm -r e2e
env --chdir tests rm -r e2e
env -C . -C tests rm -r e2e
env -C .. rm -r proj
CHDIR
assert_allow "$HOOK" "$(chdir_payload 'env -C src cat notes.txt')" "env -C into an unprotected directory, read"
# "Elsewhere" must be a sibling of proj: on Linux the temp root is under /tmp, an ancestor of the protected state.
assert_allow "$HOOK" "$(chdir_payload "env -C $CHDIR_TMP/elsewhere rm junk.txt")" "env -C elsewhere, unprotected write"

section "protected-bash fail-closed: git -C, git rewrites and find -delete|-exec judge their target set"
while IFS= read -r c; do
  assert_deny "$HOOK" "$(chdir_payload "$c")" "$c" "protected"
done <<'WIDEN'
git rm -r tests/e2e
git -C tests rm -r e2e
git -C tests/e2e rm -r docs
git -C src rm -r ../tests/e2e
git -C tests restore e2e
git -C tests mv e2e /tmp/z
git -C tests stash -u
git -C tests clean -fdx
git -C .. clean -fdx
git clean -fdx
git clean -fdx tests
git checkout -- .
git checkout -- tests/e2e
git reset --hard
git reset --hard HEAD~1
git stash
git stash pop
find . -delete
find tests -delete
find tests -exec rm {} \;
WIDEN
while IFS= read -r c; do
  assert_allow "$HOOK" "$(chdir_payload "$c")" "$c"
done <<'NARROW'
npx playwright test tests/e2e
pnpm exec playwright test
git status
git diff
git log
git -C tests status
git -C src rm x.txt
git checkout -b feature
git add src
git reset HEAD
git stash list
find tests -name x
find src -delete
cat tests/e2e/notes.txt
NARROW

section "protected-bash fail-closed: git rm --cached and find -exec rm"
while IFS= read -r c; do
  assert_deny "$HOOK" "$(chdir_payload "$c")" "$c" "protected"
done <<'CACHED'
find . -exec rm {} \;
git rm --cached tests/e2e/docs/onboarding-status.json
git -C tests/e2e/docs rm --cached onboarding-status.json
CACHED
while IFS= read -r c; do
  assert_allow "$HOOK" "$(chdir_payload "$c")" "$c"
done <<'READONLY'
git stash list
git stash show
git rm --cached x.txt
git clean -fdx src
git -C src clean -fdx
find . -exec grep foo {} \;
find . -exec grep -l foo {} +
find . -name '*.ts' -exec cat {} \;
READONLY

# git index operations judge their operands, or the work tree when there are none.
section "protected-bash fail-closed: git restore --staged and git rm --cached on protected paths"
while IFS= read -r c; do
  assert_deny "$HOOK" "$(chdir_payload "$c")" "$c" "protected"
done <<'STAGED'
git restore --staged tests/e2e
git restore --staged .
git rm --cached -r tests/e2e
STAGED
while IFS= read -r c; do
  assert_allow "$HOOK" "$(chdir_payload "$c")" "$c"
done <<'STAGED_ALLOW'
git status
git diff
git log
git show
git ls-files
git blame src/x.ts
git stash list
git stash show -p
git rm --cached src/x.ts
git restore --staged src/x.ts
git switch -c topic
find . -exec grep foo {} \;
find . -exec cat {} \;
find src -exec rm {} \;
STAGED_ALLOW

while IFS= read -r c; do
  assert_allow "$HOOK" "$(chdir_payload "$c")" "$c"
done <<'GIT_OPTIONS_ALLOW'
git restore -s HEAD src
git --no-pager log
GIT_OPTIONS_ALLOW

# A forced checkout or switch, reset --hard and clean overwrite the tree they act on: the cwd, or a
# literal -C directory judged by the protected state it holds.
section "protected-bash fail-closed: destructive git on a tree holding protected state"
assert_deny "$HOOK" "$(chdir_payload 'git checkout -f main')" "git checkout -f" "Writes into"
assert_deny "$HOOK" "$(chdir_payload 'git switch -f main')" "git switch -f" "Writes into"
else_payload() { "$JQ" -n --arg c "$1" --arg d "$CHDIR_TMP/elsewhere" '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}'; }
assert_deny "$HOOK" "$(else_payload "git -C $CHDIR_TMP/proj reset --hard")" "git -C <project> reset --hard from another directory" "Writes into"
assert_deny "$HOOK" "$(else_payload 'git -C ../proj clean -fd')" "git -C <project> clean -fd from another directory" "Writes into"

# A literal cd on the line moves the directory later commands resolve in; a cd that does not resolve unproves
# the writes after it.
section "protected-bash fail-closed: a same-line cd"
for c in 'cd tests/e2e && rm -rf docs' 'cd tests && rm -rf e2e' 'cd tests/e2e && git checkout -- docs' 'cd tests/e2e && git restore docs' 'cd "$D" && rm -rf docs' 'cd "$(git rev-parse --show-toplevel)/tests/e2e" && rm -rf docs'; do
  assert_deny "$HOOK" "$(chdir_payload "$c")" "$c" "Writes into"
done
assert_allow "$HOOK" "$(chdir_payload 'cd src && rm x')" "cd src && rm x"

# Claude Code's commit form: the message is read from a quoted heredoc, so it is text, not a command.
section "protected-bash fail-closed: a commit message from a quoted heredoc"
HEREDOC_COMMIT="git commit -m \"\$(cat <<'EOF'
docs: refresh journey-map.md

Keeps \`onboarding-status.json\` in step.
EOF
)\""
assert_allow "$HOOK" "$(bash_payload "$HEREDOC_COMMIT")" "git commit -m \"\$(cat <<'EOF' … EOF)\" naming a protected file → ALLOW"
assert_deny "$HOOK" "$(bash_payload "git commit -m \"\$(cat <<EOF
docs: \$(rm -rf tests) journey-map.md
EOF
)\"")" "an unquoted heredoc expands its body → DENY" "command substitution"

section "protected-bash fail-closed: tee writes its operands, not what it reads"
assert_deny "$HOOK" "$(bash_payload 'cat x | tee .claude/hooks/x')" "tee into the hook install → DENY" "Writes into: .claude/hooks"
