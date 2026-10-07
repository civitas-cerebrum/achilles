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
