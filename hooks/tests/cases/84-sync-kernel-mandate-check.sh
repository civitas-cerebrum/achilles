#!/bin/bash
# sync-kernel-mandate.mjs --check: verifies vendored kernel bytes against scripts/kernel-mandate.lock.json.
REPO_ROOT="$(cd "$HOOK_DIR/.." && pwd)"
SK_TMP=$(mktemp -d)
sk_copy() { # copy the script, the lock and every locked file into $SK_TMP
  mkdir -p "$SK_TMP/scripts"
  cp "$REPO_ROOT/scripts/sync-kernel-mandate.mjs" "$SK_TMP/scripts/"
  cp "$REPO_ROOT/scripts/kernel-mandate.lock.json" "$SK_TMP/scripts/"
  "$JQ" -r '.files | keys[]' "$REPO_ROOT/scripts/kernel-mandate.lock.json" | while IFS= read -r rel; do
    mkdir -p "$SK_TMP/$(dirname "$rel")"; cp "$REPO_ROOT/$rel" "$SK_TMP/$rel"
  done
}
sk_run() { env -u KERNEL_MANDATE_SRC node "$SK_TMP/scripts/sync-kernel-mandate.mjs" --check > "$SK_TMP/out" 2>&1; echo $?; }

section "sync-kernel-mandate --check: lock mode"
sk_copy
assert_eq "$(sk_run)" "0" "untouched vendored files match the lock → exit 0"
printf '\n# drift\n' >> "$SK_TMP/hooks/lib/kernel-mandate.sh"
assert_eq "$(sk_run)" "1" "an edited vendored file → exit 1"
assert_eq "$(grep -c 'DRIFT: hooks/lib/kernel-mandate.sh' "$SK_TMP/out")" "1" "…and the drifted path is named"
cp "$REPO_ROOT/hooks/lib/kernel-mandate.sh" "$SK_TMP/hooks/lib/kernel-mandate.sh"
rm "$SK_TMP/hooks/tests/cases/kernel-mandate/01-role-gate.sh"
assert_eq "$(sk_run)" "1" "a deleted vendored file → exit 1"
cp "$REPO_ROOT/hooks/tests/cases/kernel-mandate/01-role-gate.sh" "$SK_TMP/hooks/tests/cases/kernel-mandate/"
printf '#!/bin/bash\n' > "$SK_TMP/hooks/tests/cases/kernel-mandate/99-extra.sh"
assert_eq "$(sk_run)" "1" "an extra file in the vendored case dir → exit 1"
rm "$SK_TMP/hooks/tests/cases/kernel-mandate/99-extra.sh" "$SK_TMP/scripts/kernel-mandate.lock.json"
assert_eq "$(sk_run)" "2" "no lock → exit 2"
assert_eq "$(env -u KERNEL_MANDATE_SRC node "$SK_TMP/scripts/sync-kernel-mandate.mjs" > /dev/null 2>&1; echo $?)" "2" "sync without a source → exit 2, never a silent pass"
rm -rf "$SK_TMP"
