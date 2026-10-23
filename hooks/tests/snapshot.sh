#!/bin/bash
# snapshot.sh — record or diff stdout+exit of every hook script the test suite runs.
# A refactor that claims to preserve behaviour must leave this diff empty.
#
#   bash hooks/tests/snapshot.sh record <out.tsv> [-- <command…>]
#   bash hooks/tests/snapshot.sh diff   <baseline.tsv> [-- <command…>]
#
# Default command: bash hooks/tests/run.sh. Run from the repo root (relative command paths).
#
# Mechanism: a `bash` shim is put first on PATH. The suite calls hooks as `bash <hook>`
# (lib.sh run_hook); the shim logs one TSV line per call and otherwise execs the real bash.
# It records what the hook did, never whether the case passed.
# Only calls of hooks/*.sh and hooks/factory/*.sh are logged; a hook run any other way
# (direct exec, deeper subdirectories) is not seen. A hook killed by TERM/INT sent to its
# shim is logged with exit 143/130; a SIGKILL to the shim loses that line, and the hook it
# started is then orphaned.
#
# TSV line: <hook path relative to hooks/>  <exit>  <sha256(normalised stdin)[:16]>  <normalised stdout, newlines and tabs→spaces>
#
# Normalisations (applied to stdin before hashing and to stdout; each maps to a placeholder):
#   macOS temp dirs  (/private)/var/folders/…/T/                -> <TMP>/
#   run sandbox      /tmp/…achilles-hooktests.XXXXXX            -> <RUN>
#   sandbox suffix   achilles-hooktests.AbCdEf (after <TMP>/)     -> achilles-hooktests.X
#   mktemp suffixes  tmp.XXXXXXXX                               -> tmp.X
#   /tmp/<name>-XXXXXX mktemp-style names                       -> /tmp/<name>-XXXXXX
#   ISO timestamps   2026-10-06T12:34:56.789Z                   -> <TS>
#   epoch seconds    10-digit 16xxxxxxxx–19xxxxxxxx             -> <EPOCH>
#   $RANDOM nonce    kernel-mandate-role: <role>#ab12c<digits>   -> …#ab12c<RANDOM>
#   clock-derived    "age 3602s" in approver-expiry denials      -> age <N>s
#   archiver run ids 20261006T012452Z, optional -N collision     -> <RUNID>
#   deck inspection dirs  deck-inspection-20261007T085804        -> deck-inspection-<RUNID>
# (No \b: BSD sed -E has no word-boundary escape.)
set -uo pipefail
mode="${1:?record|diff}"; target="${2:?file}"; shift 2
[ "${1:-}" = "--" ] && shift
[ "$#" -gt 0 ] || set -- bash hooks/tests/run.sh
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks="$(cd "$here/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
real_bash="$(command -v bash)"
mkdir -p "$work/bin"
cat > "$work/bin/bash" <<'EOF'
#!@REAL@
case "${1:-}" in
  @HOOKS@/*.sh|@HOOKS@/factory/*.sh) ;;
  *) exec @REAL@ "$@" ;;
esac
in="$(mktemp)"; out="$(mktemp)"
cat > "$in"
log() {  # <exit>; the whole line goes out in one append so nested or killed calls cannot garble it
  local h o t=$'\t'
  h="$(@WORK@/norm < "$in" | { command -v sha256sum >/dev/null && sha256sum || shasum -a 256; } | cut -c1-16)"
  o="$(@WORK@/norm < "$out" | tr '\n\t' '  ')"
  printf '%s\n' "${1#@HOOKS@/}$t$2$t$h$t$o" >> @WORK@/raw.tsv
}
hook="$1"; child=
# The hook runs in the background so a TERM/INT aimed at this shim (assert_terminates'
# pkill -P) reaches it and the hung call is still logged, with the signal's exit status.
fwd() { kill "$1" "$child" 2>/dev/null; wait "$child" 2>/dev/null; rc=$?; log "$hook" "$rc"; cat "$out"; rm -f "$in" "$out"; exit "$rc"; }
trap 'fwd -TERM' TERM
trap 'fwd -INT' INT
@REAL@ "$@" < "$in" > "$out" & child=$!
wait "$child"; rc=$?
log "$hook" "$rc"
cat "$out"; rm -f "$in" "$out"; exit "$rc"
EOF
sed -i.bak -e "s#@REAL@#$real_bash#g" -e "s#@HOOKS@#$hooks#g" -e "s#@WORK@#$work#g" "$work/bin/bash"
cat > "$work/norm" <<'EOF'
#!/bin/sh
sed -E \
  -e 's#(/private)?/var/folders/[^"[:space:]]*/T/#<TMP>/#g' \
  -e 's#/tmp/[A-Za-z0-9._-]*achilles-hooktests\.[A-Za-z0-9]+#<RUN>#g' \
  -e 's#achilles-hooktests\.[A-Za-z0-9]+#achilles-hooktests.X#g' \
  -e 's#tmp\.[A-Za-z0-9]{6,}#tmp.X#g' \
  -e 's#(/tmp/[a-z-]+-)[A-Za-z0-9]{6}#\1XXXXXX#g' \
  -e 's#[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z?#<TS>#g' \
  -e 's#(kernel-mandate-role: [A-Za-z0-9_-]+\#ab12c)[0-9]+#\1<RANDOM>#g' \
  -e 's#age [0-9]+s#age <N>s#g' \
  -e 's#deck-inspection-[0-9]{8}T[0-9]{6}#deck-inspection-<RUNID>#g' \
  -e 's#[0-9]{8}T[0-9]{6}Z(-[0-9]+)?#<RUNID>#g' \
  -e 's#(^|[^0-9])1[6-9][0-9]{8}([^0-9]|$)#\1<EPOCH>\2#g'
EOF
chmod +x "$work/bin/bash" "$work/norm"
: > "$work/raw.tsv"
PATH="$work/bin:$PATH" "$@" > "$work/run.log" 2>&1
# A failing suite is expected; a crashed one is not. run.sh always ends with a summary line, and
# any command must have invoked at least one hook, else the snapshot would be silently truncated.
crashed=
case "$*" in *run.sh*) grep -qE '(all [0-9]+ tests passed|[0-9]+ of [0-9]+ tests failed)' "$work/run.log" || crashed="no run.sh summary line" ;; esac
[ -s "$work/raw.tsv" ] || crashed="${crashed:-no hook invocations recorded}"
if [ -n "$crashed" ]; then echo "[snapshot] wrapped command did not complete ($crashed); tail of its output:" >&2; tail -n 30 "$work/run.log" >&2; exit 3; fi
case "$mode" in
  record) cp "$work/raw.tsv" "$target"; echo "[snapshot] $(wc -l < "$target" | tr -d ' ') hook invocations → $target" ;;
  diff)   if diff -u "$target" "$work/raw.tsv" > "$work/d"; then echo "[snapshot] identical ($(wc -l < "$target" | tr -d ' ') invocations)"; else cat "$work/d"; echo "[snapshot] DIFFERS from $target"; exit 1; fi ;;
  *) echo "usage: snapshot.sh record|diff <file> [-- command…]" >&2; exit 2 ;;
esac
