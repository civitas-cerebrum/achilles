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
# It records what the hook did, never whether the case passed, so cases that fail on a
# given platform (e.g. BSD-sed failures in vendored kernel cases) are still captured.
# Only calls of hooks/*.sh and hooks/factory/*.sh are logged; a hook run any other way
# (direct exec, deeper subdirectories) is not seen.
#
# TSV line: <hook path relative to hooks/>  <exit>  <sha256(normalised stdin)[:16]>  <normalised stdout, newlines→spaces>
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
cat > "$work/bin/bash" <<EOF
#!$real_bash
case "\${1:-}" in
  "$hooks"/*.sh|"$hooks"/factory/*.sh) ;;
  *) exec "$real_bash" "\$@" ;;
esac
in="\$(mktemp)"; out="\$(mktemp)"
cat > "\$in"
"$real_bash" "\$@" < "\$in" > "\$out"; rc=\$?
{ printf '%s\t%s\t' "\${1#$hooks/}" "\$rc"
  "$work/norm" < "\$in" | { command -v sha256sum >/dev/null && sha256sum || shasum -a 256; } | cut -c1-16 | tr -d '\n'; printf '\t'
  "$work/norm" < "\$out" | tr '\n' ' '; printf '\n'; } >> "$work/raw.tsv"
cat "\$out"; rm -f "\$in" "\$out"; exit \$rc
EOF
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
  -e 's#[0-9]{8}T[0-9]{6}Z(-[0-9]+)?#<RUNID>#g' \
  -e 's#(^|[^0-9])1[6-9][0-9]{8}([^0-9]|$)#\1<EPOCH>\2#g'
EOF
chmod +x "$work/bin/bash" "$work/norm"
: > "$work/raw.tsv"
PATH="$work/bin:$PATH" "$@" > "$work/run.log" 2>&1
case "$mode" in
  record) cp "$work/raw.tsv" "$target"; echo "[snapshot] $(wc -l < "$target" | tr -d ' ') hook invocations → $target" ;;
  diff)   if diff -u "$target" "$work/raw.tsv" > "$work/d"; then echo "[snapshot] identical ($(wc -l < "$target" | tr -d ' ') invocations)"; else cat "$work/d"; echo "[snapshot] DIFFERS from $target"; exit 1; fi ;;
  *) echo "usage: snapshot.sh record|diff <file> [-- command…]" >&2; exit 2 ;;
esac
