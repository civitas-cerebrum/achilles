#!/bin/bash
# protected-artifact-bash-guard.sh — denies Bash commands that mutate the
#                                    pipeline-state artifacts out of band.
#
# Hook    : PreToolUse:Bash
# Mode    : DENY
# State   : none (stateless pattern check)
# Env     : none
#
# Why
# ---
# Every Write|Edit gate (ledger write-gate, sentinel gate, integrity chain)
# inspects ONLY the Write/Edit tools. A `cat > onboarding-status.json` from
# Bash sidesteps them all.
#
# Rule (fail closed): a command line that names a protected path, or a
# directory one lives in, is denied unless every command on it, as the shell
# would split it (lib/shell-words.sh), is provably safe:
#   - a read-only command (READERS, git log/show/diff/status/blame, sed and
#     yq without -i, find without an action) whose write redirections all
#     resolve to unprotected paths, or
#   - a recognised writer (tee, rm, unlink, rmdir, truncate, shred, sponge,
#     mv, cp, install, ln, dd, sed -i, yq -i, touch, mkdir) whose write
#     targets all resolve to unprotected paths outside every protected
#     directory (mkdir: outside every protected entry; it creates, never
#     alters, so `mkdir -p .claude` for the sanctioned early stop passes).
# Anything else on such a line (interpreters, awk, eval, sh -c, xargs,
# find -delete/-exec/-fprint, command substitution, a target behind a
# variable or glob, any other program) denies: the guard cannot prove it
# does not write. Within a line the guard inverts to UNRECOGNISED = UNSAFE:
# a sed script is safe only if it parses under a read-only grammar
# (sed_script_safe) and sed's options are only the listed ones; cp/mv/
# install/ln options are parsed as full short clusters (-vt DIR) and any
# unknown option is unsafe; a wrapper (env, exec, nice, sudo, …) is peeled
# only past options the splitter knows; git -c is inert only for user.*,
# core.quotepath, color.*, advice.*, i18n.*, init.defaultbranch. Nor is a
# command safe when something earlier on the line can change what it runs:
# a command word outside the system bin dirs, an assignment or `env` before
# it, an assignment-only command, export/declare/alias/hash/eval/read/
# printf -v/let before it,
# git's --config-env/--exec-path or the options that name a program
# (--upload-pack, --ext-diff, --textconv, -O), `rg --pre`, `file -C`,
# `yq -s`, or an ln whose source is protected. Paths are normalised
# (lib/protected-paths.sh) first, so quoting, escapes, //, /./, .., ~ and
# case do not change the verdict; unquoted {a,b} is expanded as bash would.
# A line the splitter cannot finish (over 32 KB, 16 nested shells, 64
# brace words) denies as unverifiable; one with more than 40 paths to
# normalise counts as naming protected state.
#
# Independently of naming, a write target that is a protected path, the
# directory one lives in, or ANY ancestor of one (`~`, `/`, `.`, `..`, `tests`,
# resolved against the call's cwd) denies, for every writer whose targets the
# guard reads: rm, mv, cp/install/ln into, tee, truncate, dd of=, sed/yq -i,
# chmod/chown/chgrp/touch, tar -C, rsync, unzip -d, curl -o, wget -O, the
# git subcommands that rewrite the work tree or the index (git_targets) and the
# start paths of find -delete or of an -exec whose command is not a reader. A
# copy, move or link INTO a directory writes <dir>/<basename src>; that path is
# judged, so `cp x .` passes and `cp -r somedir/.claude ~` does not.
#
# git commit, add, status, log, show, diff, blame, rev-parse, ls-files, grep,
# fetch, stash list|show and branch/tag listing write only under .git and
# count as safe.
#
# The tamper-evident ledger chain (ledger-integrity-chain.sh) DETECTS
# whatever this guard fails to PREVENT. The two ship as a pair.
#
# settings.local.json: coverage is a deliberate superset of spec §A3's
# settings.json — local overrides carry the same mutation risk.
#
# Canonical reference
# -------------------
# skills/achilles-protocol/references/harness-hooks.md

set -uo pipefail

# Methodology pointers appended to every deny/warn message this hook
# can emit (repo convention: contributing-to-achilles-protocol/SKILL.md
# §"Hook error message format — repo standard").
printf -v HOOK_REFS -- "\n\nReferences:\n  skills/achilles-protocol/references/harness-hooks.md §Bash\n  skills/onboarding/SKILL.md §\"Status ledger + workflow reviewer\""


# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/hook-io.sh"
hook_jq_init fatal

hook_lib hook-emit.sh protected-paths.sh shell-words.sh

hook_read_input

hook_lib achilles-activation.sh
TOOL_NAME=$(echo "$INPUT" | "$JQ" -r '.tool_name // empty' 2>/dev/null || echo "")
[ "$TOOL_NAME" = "Bash" ] || exit 0
CMD=$(echo "$INPUT" | "$JQ" -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -n "$CMD" ] || exit 0
CWD=$(echo "$INPUT" | "$JQ" -r '.cwd // empty' 2>/dev/null || echo "")
[ -n "$CWD" ] || CWD="$PWD"
LOCATIONS=""  # protected_locations "$CWD", computed at the first write target

# No pagers: less and more run $LESSOPEN.
READERS=' cat head tail grep egrep fgrep rg ls stat wc diff cmp file sha256sum shasum md5 md5sum jq echo printf test [ '
NAMED=""    # protected entries and directories the line names, one per line
HITS=""     # protected entries or directories a write reaches
UNSAFE=""   # why a command on the line cannot be proved safe
OVERFLOW="" # 1 when the line could not be split whole
GBASE=""   # the -C / --work-tree directory of the git command being judged
TGT_BASE="" # the env -C directory the command being judged runs in
POISON=0    # a PATH/alias/function/assignment-only command earlier on the line can redefine later ones

# unresolved <word> — 0 when <word> holds an unexpanded variable, substitution or glob.
unresolved() { case "$1" in *'$'*|*'`'*|*'*'*|*'?'*|*'['*) return 0 ;; esac; return 1; }

# names <word> — record the protected entry or directory <word> (or its --opt= value) names.
names() {
  local w e
  for w in "$1" "${1#*=}"; do
    e=$(protected_bash_match "$w") || e=$(protected_parent_match "$w") || continue
    NAMED="$NAMED$e"$'\n'; return 0
  done
}

# target <word> — a write target: unresolvable (variable, substitution, glob) is unsafe;
# a protected entry or a protected directory is a hit. An operand of a command run under env -C
# (TGT_BASE) is judged under that directory; a redirection target is not (the outer shell opens it).
target() {
  local e
  case "$1" in
    /*|'~'*|'$HOME'*|'${HOME}'*) ;;
    *) [ -z "$TGT_BASE" ] || set -- "$TGT_BASE/$1" ;;
  esac
  case "$1" in
    '${workspace}'*) HITS="${HITS}a workspace directory: $1 is not resolvable"$'\n'; return 0 ;;
  esac
  case "$1" in
    '~'|'~/'*|'$HOME'|'$HOME/'*|'${HOME}'|'${HOME}/'*) ;;
    *'$'*|*'`'*) UNSAFE="$UNSAFE${CMD_ARGS[0]:-redirect}: write target $1 does not resolve"$'\n'; return 0 ;;
    *'*'*|*'?'*|*'['*) UNSAFE="$UNSAFE${CMD_ARGS[0]:-redirect}: write target $1 is a glob"$'\n' ;;
  esac
  [ -n "$LOCATIONS" ] || LOCATIONS=$(protected_locations "$CWD")
  e=$(protected_bash_match "$1") || e=$(protected_parent_match "$1") ||
    e=$(protected_ancestor_match "$1" "$CWD" "$LOCATIONS") || return 0
  HITS="$HITS$e"$'\n'
}

# chdir_named <dir> — env -C <dir>: a command run there reads its operands under <dir>, so a <dir>
# that is protected, inside a protected directory, above one or unresolvable counts as naming protected
# state (env already makes every command on the line unsafe). A nested shell does not carry <dir>
# into the commands it runs; this covers it.
chdir_named() {
  local e
  [ -n "$LOCATIONS" ] || LOCATIONS=$(protected_locations "$CWD")
  case "$1" in
    '${workspace}'*) # a writer's operands deny in target(); only a shell here can run what the guard cannot see
      case "${CMD_ARGS[0]:-}" in sh|bash|zsh|dash|ksh|eval) NAMED="${NAMED}workspace directory (does not resolve)"$'\n' ;; esac
      return 0 ;;
  esac
  if unresolved "$1"; then NAMED="${NAMED}env -C $1 (does not resolve)"$'\n'; return 0; fi
  e=$(protected_bash_match "$1") || e=$(protected_parent_match "$1") ||
    e=$(protected_ancestor_match "$1" "$CWD" "$LOCATIONS") || return 0
  NAMED="$NAMED$e"$'\n'
}

# judge_git — git's global options (-c keys, exec options, the -C / --work-tree directory GBASE), then the
# subcommand: a read passes; one that rewrites the work tree or the index has its target set judged.
judge_git() {
  local gi=1 a sub="" gval gkey e
  GBASE="$CMD_CHDIR"
  # An option that makes git run a program or write a file denies whatever the line names.
  for a in "${CMD_ARGS[@]:1}"; do
    shell_git_exec_option "$a" && { UNSAFE="${UNSAFE}git $a"$'\n'; NAMED="${NAMED}git $a runs a program or writes a file"$'\n'; }
  done
  while [ "$gi" -lt "${#CMD_ARGS[@]}" ] && [ -z "$sub" ]; do
    a="${CMD_ARGS[gi]}"; gi=$((gi + 1))
    case "$a" in
      -c|-c?*)
        if [ "$a" = -c ]; then gval="${CMD_ARGS[gi]:-}"; gi=$((gi + 1)); else gval="${a#-c}"; fi
        gkey=$(printf '%s' "${gval%%=*}" | tr '[:upper:]' '[:lower:]')
        case "$gkey" in
          user.name|user.email|core.quotepath|init.defaultbranch) ;;
          color.*|advice.*|i18n.*) ;;
          *) # A non-inert key (alias.X=!body, core.pager=…) runs through git's own sh -c,
             # which strips a second level of quotes; reveal a protected name hidden that way.
             gval="${gval//\"/}"; gval="${gval//\'/}"
             e=$(protected_bash_mention "$gval") && NAMED="$NAMED$e"$'\n'
             UNSAFE="${UNSAFE}git -c"$'\n' ;;
        esac ;;
      -C|--work-tree) shell_dir_join "$GBASE" "${CMD_ARGS[gi]:-}"; GBASE="$SW_JOIN"; gi=$((gi + 1)) ;;
      -C?*) shell_dir_join "$GBASE" "${a#-C}"; GBASE="$SW_JOIN" ;;
      --work-tree=*) shell_dir_join "$GBASE" "${a#*=}"; GBASE="$SW_JOIN" ;;
      --git-dir|--namespace|--super-prefix|--config-env|--attr-source) gi=$((gi + 1)) ;;
      --*=*|-p|-P|--paginate|--no-pager|--bare|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|\
      --noglob-pathspecs|--icase-pathspecs|--no-optional-locks|--no-advice|--exec-path|--html-path|--man-path|\
      --info-path|--version|--help|-h|-v) ;;
      # An option the guard does not know may take the next word, which would then pass for the subcommand.
      -*) UNSAFE="${UNSAFE}git $a"$'\n'; NAMED="${NAMED}git option $a the guard cannot read"$'\n' ;;
      *) sub="$a" ;;
    esac
  done
  [ "$GBASE" = "$CMD_CHDIR" ] || chdir_named "$GBASE"
  case "$sub" in
    status|diff|log|show|ls-files|blame|commit|add|rev-parse|grep|fetch) return 0 ;;
    branch|tag)
      case " ${CMD_ARGS[*]} " in *" -l "*|*" --list "*) return 0 ;; esac
      for a in "${CMD_ARGS[@]:gi}"; do case "$a" in -*) ;; *) UNSAFE="${UNSAFE}git $sub creating"$'\n'; break ;; esac; done
      return 0 ;;
    stash) case "${CMD_ARGS[gi]:-}" in list|show) return 0 ;; esac ;;
    sparse-checkout) [ "${CMD_ARGS[gi]:-}" != list ] || return 0 ;;
    rm|checkout|restore|clean|reset|mv|switch|read-tree|checkout-index) ;;
    *) UNSAFE="${UNSAFE}git $sub"$'\n'; return 0 ;;
  esac
  UNSAFE="${UNSAFE}git $sub"$'\n'
  git_targets "$sub" "$gi"
}

# git_targets <subcommand> <index> — the target set of a work-tree or index rewrite, under GBASE: every
# operand (a new branch name counts as one), and the work tree itself when there is none, when one does not
# resolve, when an option is not known here (it may take the next word), or when the subcommand takes the
# whole tree (stash, read-tree, sparse-checkout, a forced checkout or switch, checkout-index -a,
# reset --hard|--merge|--keep). A short-option cluster ends at the subcommand's own value letter.
# Only clean, rm, mv and restore stay inside a relative -C directory; the rest act from the repository top.
git_targets() {
  local sub="$1" gi="$2" a t ops=() whole=0 open=0 vl=""
  TGT_BASE="$GBASE"
  case "$sub" in
    stash) whole=1; vl=m ;;
    read-tree|sparse-checkout) whole=1 ;;
    restore) vl=sU ;;
    clean) vl=e ;;
    checkout|switch) vl=bBcC ;;
  esac
  while [ "$gi" -lt "${#CMD_ARGS[@]}" ]; do
    a="${CMD_ARGS[gi]}"; gi=$((gi + 1))
    case "$a" in
      --) ops+=("${CMD_ARGS[@]:gi}"); break ;;
      --hard|--merge|--keep|--force|--discard-changes|--reset|--all) whole=1 ;;
      --cached|--staged|--worktree|--dry-run|--quiet|--ignore-unmatch|--soft|--mixed|--detach|--ours|--theirs|--patch|--track|--no-track) ;;
      --source|--exclude|--message) gi=$((gi + 1)) ;;
      --orphan) ops+=("${CMD_ARGS[gi]:-}"); gi=$((gi + 1)) ;;
      --pathspec-fr*) open=1 ;;
      --*=*) ;;
      --*) whole=1 ;;
      -?*)
        shell_opt_split "$a" "$vl"
        case "$SW_FLAGS" in *[!qfnrkvdxXiuapmSWNlt23z]*) whole=1 ;; esac
        case "$sub:$SW_FLAGS" in checkout:*f*|switch:*f*|checkout-index:*a*) whole=1 ;; esac
        if [ -n "$SW_VOPT" ] && [ -z "$SW_VAL" ]; then SW_VAL="${CMD_ARGS[gi]:-}"; gi=$((gi + 1)); fi
        case "$SW_VOPT" in [bBcC]) ops+=("$SW_VAL") ;; esac ;;
      *) ops+=("$a") ;;
    esac
  done
  for t in ${ops[@]+"${ops[@]}"}; do
    case "$t" in :*) open=1 ;; *) target "$t"; unresolved "$t" && whole=1 ;; esac
  done
  [ "$open" = 0 ] || { whole=1; NAMED="${NAMED}git $sub: its paths are not on the line"$'\n'; }
  [ "${#ops[@]}" -gt 0 ] && [ "$whole" = 0 ] && return 0
  case "$sub:$GBASE" in clean:*|rm:*|mv:*|restore:*|*:/*|*:'~'*|*:'$'*) ;; *) TGT_BASE="" ;; esac
  target .
}

# find_exec <word>… — judge the command an -exec-style action runs as a command of its own, by every rule
# here (its wrappers, nested shells and options); 0 when it is a reader and added no reason to deny.
find_exec() {
  local saved=("${SW[@]}") unsafe="$UNSAFE" hits="$HITS"
  local FIND_CMD=""
  shell_words_args "$@"
  shell_each_command find__judge
  [ "$SW_OVERFLOW" = 0 ] || OVERFLOW=1
  SW=("${saved[@]}")
  [ "$UNSAFE" = "$unsafe" ] && [ "$HITS" = "$hits" ] || return 1
  case "$READERS" in *" $FIND_CMD "*) return 0 ;; esac
  return 1
}
find__judge() { [ -n "$FIND_CMD" ] || FIND_CMD="${CMD_ARGS[0]:-}"; judge_command; }

# find_start_targets — find with -delete, or with an -exec-style action whose command is not a reader,
# removes or rewrites files under its start paths (. when none).
find_start_targets() {
  local k=1 n=0 a
  while [ "$k" -lt "${#CMD_ARGS[@]}" ]; do
    a="${CMD_ARGS[k]}"; k=$((k + 1))
    case "$a" in
      -H|-L|-P|-O?|-D*) ;;
      -*|'('|'!') break ;;
      *) target "$a"; n=$((n + 1)) ;;
    esac
  done
  [ "$n" -gt 0 ] || target .
}

# optval <short> <long> — target every value of -<short> X, -<short>X, --<long> X, --<long>=X.
optval() {
  local a last=""
  for a in "${CMD_ARGS[@]:1}"; do
    case "$last" in "-$1"|"--$2") target "$a" ;; esac
    case "$a" in "--$2="*) target "${a#*=}" ;; "-$1"?*) target "${a#-$1}" ;; esac
    last="$a"
  done
}

# operands [letters] — OPERANDS: the arguments after the command word that are not options;
# -<letter> options whose value is the next word are skipped with it.
operands() {
  local a opts=1 skip=0
  OPERANDS=()
  for a in "${CMD_ARGS[@]:1}"; do
    if [ "$opts" = 1 ]; then
      [ "$skip" = 0 ] || { skip=0; continue; }
      case "$a" in --) opts=0; continue ;; -?*) [ -z "${1:-}" ] || case "$a" in -[$1]) skip=1 ;; esac; continue ;; esac
    fi
    OPERANDS+=("$a")
  done
}

# sed_parse — fills SED_SCRIPTS and OPERANDS (the files an in-place edit writes), sets SED_INPLACE.
# Options invert to unknown=unsafe: only -n -E -r -s -u -z (flags), -e/--expression (script),
# -i/-I/--in-place (writer) and the exact long forms --quiet --silent --regexp-extended are known.
# -f/--file (script from a file), any abbreviation and any other option make the command unsafe.
sed_parse() {
  local a k=1 letters m ch rest sawscript=0
  SED_SCRIPTS=(); OPERANDS=(); SED_INPLACE=0
  while [ "$k" -lt "${#CMD_ARGS[@]}" ]; do
    a="${CMD_ARGS[k]}"; k=$((k + 1))
    case "$a" in
      --) while [ "$k" -lt "${#CMD_ARGS[@]}" ]; do
            if [ "$sawscript" = 0 ]; then SED_SCRIPTS+=("${CMD_ARGS[k]}"); sawscript=1; else OPERANDS+=("${CMD_ARGS[k]}"); fi; k=$((k + 1))
          done; break ;;
      --expression=*) SED_SCRIPTS+=("${a#*=}"); sawscript=1 ;;
      --expression) SED_SCRIPTS+=("${CMD_ARGS[k]:-}"); k=$((k + 1)); sawscript=1 ;;
      --in-place=*|--in-place) SED_INPLACE=1 ;;
      --quiet|--silent|--regexp-extended) ;;
      --*) UNSAFE="${UNSAFE}sed: unrecognised option $a"$'\n'; return 1 ;;
      '') ;;
      -)  if [ "$sawscript" = 0 ]; then SED_SCRIPTS+=("$a"); sawscript=1; else OPERANDS+=("$a"); fi ;;
      -*) letters="${a#-}"; m=0
          while [ "$m" -lt "${#letters}" ]; do
            ch="${letters:m:1}"; m=$((m + 1)); rest="${letters:m}"
            case "$ch" in
              n|E|r|s|u|z) : ;;
              e) if [ -n "$rest" ]; then SED_SCRIPTS+=("$rest"); else SED_SCRIPTS+=("${CMD_ARGS[k]:-}"); k=$((k + 1)); fi; sawscript=1; break ;;
              i|I) SED_INPLACE=1; break ;;
              f) UNSAFE="${UNSAFE}sed: script read from a file"$'\n'; return 1 ;;
              *) UNSAFE="${UNSAFE}sed: unrecognised option -$ch"$'\n'; return 1 ;;
            esac
          done ;;
      *) if [ "$sawscript" = 0 ]; then SED_SCRIPTS+=("$a"); sawscript=1; else OPERANDS+=("$a"); fi ;;
    esac
  done
  return 0
}

# sed_script_safe <script> — 0 when every command in <script> parses under the read-only grammar:
# [addr[,addr]][!] then one of p d q Q = n N g G h H x l (or a { } block), or s<d>…<d>…<d>[gpiI0-9]*,
# or y<d>…<d>…<d>. No w W e r R F command or w/e flag. Anything else, or any unparsed text, is unsafe.
sed__until() { local d="$1" c; while [ "$SI" -lt "$SN" ]; do c="${SP:SI:1}"; case "$c" in '\') SI=$((SI + 2)); continue ;; "$d") SI=$((SI + 1)); return 0 ;; esac; SI=$((SI + 1)); done; return 1; }
sed__digits() { while [ "$SI" -lt "$SN" ]; do case "${SP:SI:1}" in [0-9]) SI=$((SI + 1)) ;; *) break ;; esac; done; }
sed__addr() {
  case "${SP:SI:1}" in
    [0-9]) sed__digits; case "${SP:SI:1}" in '~') SI=$((SI + 1)); sed__digits ;; esac; return 0 ;;
    '+') SI=$((SI + 1)); sed__digits; return 0 ;;
    '$') SI=$((SI + 1)); return 0 ;;
    '/') SI=$((SI + 1)); sed__until '/'; return $? ;;
    '\') SI=$((SI + 2)); sed__until "${SP:SI-1:1}"; return $? ;;
    *) return 1 ;;
  esac
}
sed_script_safe() {
  [ "${#1}" -le 4096 ] || return 1
  local SP="$1" SN=${#1} SI=0 c d
  while [ "$SI" -lt "$SN" ]; do
    c="${SP:SI:1}"
    case "$c" in
      ' '|$'\t'|$'\n'|';'|'{'|'}') SI=$((SI + 1)); continue ;;
      '#') while [ "$SI" -lt "$SN" ] && [ "${SP:SI:1}" != $'\n' ]; do SI=$((SI + 1)); done; continue ;;
    esac
    if sed__addr; then case "${SP:SI:1}" in ',') SI=$((SI + 1)); sed__addr || return 1 ;; esac; fi
    while [ "$SI" -lt "$SN" ]; do case "${SP:SI:1}" in ' '|$'\t'|'!') SI=$((SI + 1)) ;; *) break ;; esac; done
    c="${SP:SI:1}"
    case "$c" in
      p|d|q|Q|'='|n|N|g|G|h|H|x|l) SI=$((SI + 1)); sed__digits ;;
      s|y)
        d="${SP:SI+1:1}"; [ -n "$d" ] || return 1; SI=$((SI + 2))
        sed__until "$d" || return 1
        sed__until "$d" || return 1
        if [ "$c" = s ]; then
          while [ "$SI" -lt "$SN" ]; do
            case "${SP:SI:1}" in [gpiI0-9]) SI=$((SI + 1)) ;; ' '|$'\t'|$'\n'|';'|'}') break ;; *) return 1 ;; esac
          done
        fi ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# yq: OPERANDS gets the files an in-place edit writes (empty without -i); SCRIPTS the
# expressions. 1 when a script cannot be read (-f, --from-file).
editor_parse() {
  local a k=1 inplace=0 script=0
  OPERANDS=(); SCRIPTS=()
  while [ "$k" -lt "${#CMD_ARGS[@]}" ]; do
    a="${CMD_ARGS[k]}"; k=$((k + 1))
    case "$a" in
      -f|--file|--from-file|-f*|--file=*|--from-file=*) return 1 ;;
      --in-place*|--inplace) inplace=1 ;;
      -e|--expression) script=1; SCRIPTS+=("${CMD_ARGS[k]:-}"); k=$((k + 1)) ;;
      --expression=*) script=1; SCRIPTS+=("${a#*=}") ;;
      --) ;;
      -[!-]*) case "$a" in -*i*) inplace=1 ;; esac
              case "$a" in -*e) script=1; SCRIPTS+=("${CMD_ARGS[k]:-}"); k=$((k + 1)) ;; esac ;;
      -*) ;;
      '') ;;
      *) if [ "$script" = 0 ]; then script=1; SCRIPTS+=("$a"); else OPERANDS+=("$a"); fi ;;
    esac
  done
  [ "$inplace" = 1 ] || OPERANDS=()
  return 0
}

# is_dir <path> — <path>, against CWD, names an existing directory (or says so with a trailing /).
is_dir() {
  local p="$1"
  case "$p" in */|.|..|'~') return 0 ;; '~/'*) p="$HOME/${p#\~/}" ;; /*) ;; *) p="$CWD/$p" ;; esac
  [ -d "$p" ]
}

# cp / mv / install / ln. Into a directory, each source lands at <dir>/<basename>, and that path is
# judged rather than the directory; a source ending in / copies its contents, each child judged.
# A directory that holds protected entries is itself a protected destination. mv also removes its
# sources; ln makes its sources reachable under another name, so they are judged too. A recursive
# source that cannot be resolved denies when the directory is above protected state.
copy_targets() {
  local a dir="" notdir=0 recursive=0 dest src p base letters m ch rest cmd0="${CMD_ARGS[0]}"
  local srcs=() gi=1 nargs=${#CMD_ARGS[@]}
  [ "$cmd0" = mv ] && recursive=1
  while [ "$gi" -lt "$nargs" ]; do
    a="${CMD_ARGS[gi]}"; gi=$((gi + 1))
    case "$a" in
      --) while [ "$gi" -lt "$nargs" ]; do srcs+=("${CMD_ARGS[gi]}"); gi=$((gi + 1)); done; break ;;
      --target-directory=*) dir="${a#*=}" ;;
      --no-target-directory) notdir=1 ;;
      --recursive|--archive) recursive=1 ;;
      --*)
        base="${a%%=*}"
        if [ "${#base}" -ge 3 ] && case "--target-directory" in "$base"*) true ;; *) false ;; esac; then
          case "$a" in *=*) dir="${a#*=}" ;; *) dir="${CMD_ARGS[gi]:-}"; gi=$((gi + 1)) ;; esac
        elif [ "${#base}" -ge 4 ] && case "--no-target-directory" in "$base"*) true ;; *) false ;; esac; then
          notdir=1
        else
          case "$base" in
            --recursiv*|--archiv*) recursive=1 ;;
            --verbose|--force|--no-clobber|--interactive|--symbolic|--logical|--relative|--backup|--suffix|--preserve|--no-preserve|--parents|--update|--link|--dereference|--no-dereference|--remove-destination|--strip-trailing-slashes|--mode|--owner|--group|--directory|--sparse|--reflink|--attributes-only|--one-file-system|--context|--copy-contents|--debug|--help|--version) ;;
            *) UNSAFE="${UNSAFE}$cmd0: unrecognised option $a"$'\n' ;;
          esac
        fi ;;
      -)  srcs+=("$a") ;;
      -*) letters="${a#-}"; m=0
          while [ "$m" -lt "${#letters}" ]; do
            ch="${letters:m:1}"; m=$((m + 1)); rest="${letters:m}"
            case "$ch" in
              t) if [ -n "$rest" ]; then dir="$rest"; else dir="${CMD_ARGS[gi]:-}"; gi=$((gi + 1)); fi; break ;;
              T) notdir=1 ;;
              r|R|a) recursive=1 ;;
              f|s|v|n|L|P|H|d|D|u|b|p|l|c|i|S|x|e) : ;;
              *) UNSAFE="${UNSAFE}$cmd0: unrecognised option -$ch"$'\n' ;;
            esac
          done ;;
      *) srcs+=("$a") ;;
    esac
  done
  if [ -z "$dir" ]; then
    [ "${#srcs[@]}" -gt 0 ] || return 0
    dest="${srcs[${#srcs[@]}-1]}"
    srcs=("${srcs[@]:0:${#srcs[@]}-1}")
    if [ "$notdir" = 1 ] || { [ "${#srcs[@]}" -le 1 ] && ! is_dir "$dest"; }; then
      target "$dest"; dir=""
    else
      # Several sources need a directory; what the program does with anything else is not known.
      is_dir "$dest" || UNSAFE="$UNSAFE$cmd0: destination $dest is not a directory"$'\n'
      dir="${dest%/}"; [ -n "$dir" ] || dir=/
    fi
  fi
  case "$cmd0" in mv|ln) for src in ${srcs[@]+"${srcs[@]}"}; do target "$src"; done ;; esac
  [ -n "$dir" ] || return 0
  if e=$(protected_parent_match "$dir"); then HITS="$HITS$e"$'\n'; return 0; fi
  for src in ${srcs[@]+"${srcs[@]}"}; do
    if [ "$recursive" = 1 ]; then
      case "$src" in
        *'$'*|*'`'*|*'*'*|*'?'*|*'['*|*/)
          [ -n "$LOCATIONS" ] || LOCATIONS=$(protected_locations "$CWD")
          protected_ancestor_match "$dir" "$CWD" "$LOCATIONS" >/dev/null || continue
          case "$src" in
            */) p="$src"; case "$p" in '~/'*) p="$HOME/${p#\~/}" ;; /*) ;; *) p="$CWD/$p" ;; esac
                if [ -d "$p" ]; then
                  for p in "$p"* "$p".[!.]*; do [ -e "$p" ] && target "$dir/${p##*/}"; done
                  continue
                fi ;;
          esac
          HITS="${HITS}source tree of $src under $dir"$'\n'; continue ;;
      esac
    fi
    src="${src%/}"; target "$dir/${src##*/}"
  done
}

judge_command() {
  local cmd="${CMD_ARGS[0]:-}" a t e gi gdd args words prev chdir="$CMD_CHDIR"
  TGT_BASE=""
  for t in ${CMD_WRITES[@]+"${CMD_WRITES[@]}"}; do target "$t"; done
  TGT_BASE="$CMD_CHDIR"
  [ -z "$CMD_CHDIR" ] || chdir_named "$CMD_CHDIR"
  if [ -z "$cmd" ]; then
    # Assignment-only (PATH=…; ) or a bare env/wrapper: it reshapes the environment of every
    # command that follows on the line.
    { [ "$CMD_ENV" = 1 ] || [ "${#CMD_SNEST[@]}" -gt 0 ]; } && POISON=1
    return 0
  fi
  [ "$POISON" = 0 ] || UNSAFE="${UNSAFE}a PATH/alias/function/assignment earlier on the line can redefine $cmd"$'\n'
  # A wrapper option the splitter does not know may hide the command's directory (env --chd=DIR), so
  # the line is denied whatever it names. A nested env -S / npx -c string is judged where it is written.
  if [ "${CMD_WRAP_BAD:-0}" = 1 ]; then
    UNSAFE="${UNSAFE}$cmd: a wrapper carried an unrecognised option"$'\n'
    [ "${#CMD_SNEST[@]}" -gt 0 ] || NAMED="${NAMED}a wrapper option the guard cannot read"$'\n'
  fi
  [ "$CMD_XARGS" = 1 ] && { UNSAFE="${UNSAFE}xargs $cmd: operands arrive on stdin"$'\n'; return 0; }
  for a in "${CMD_ARGS[@]}"; do
    case "$a" in *'$('*|*'`'*) UNSAFE="$UNSAFE$cmd: command substitution"$'\n'; return 0 ;; esac
  done
  # These assign variables or redefine how later commands resolve: the rest of the line is tainted.
  case "$cmd" in
    export|declare|typeset|readonly|local|alias|unalias|hash|set|shopt|enable|eval|source|.|read|mapfile|readarray|let) POISON=1 ;;
    printf) for a in "${CMD_ARGS[@]:1}"; do case "$a" in -v|-v?*) POISON=1; break ;; --) break ;; esac; done ;;
  esac
  # The allowlist names programs in the system bin dirs, run with the session's environment.
  [ -z "$CMD_PATH" ] || UNSAFE="$UNSAFE$cmd: run from $CMD_PATH"$'\n'
  [ "$CMD_ENV" = 0 ] || UNSAFE="$UNSAFE$cmd: environment set on the command line"$'\n'
  case "$cmd" in
    rg) for a in "${CMD_ARGS[@]:1}"; do case "$a" in --pre|--pre=*|--pre-glob|--pre-glob=*) UNSAFE="${UNSAFE}rg $a"$'\n'; return 0 ;; esac; done ;;
    file) for a in "${CMD_ARGS[@]:1}"; do case "$a" in --compile|-C*|-[!-]*C*) UNSAFE="${UNSAFE}file -C writes a magic file"$'\n'; return 0 ;; esac; done ;;
  esac
  case "$READERS" in *" $cmd "*) return 0 ;; esac
  case "$cmd" in
    git) judge_git ;;
    sed)
      sed_parse || return 0
      for a in ${SED_SCRIPTS[@]+"${SED_SCRIPTS[@]}"}; do
        sed_script_safe "$a" || { UNSAFE="${UNSAFE}sed: not a provably read-only script: $a"$'\n'; return 0; }
      done
      [ "$SED_INPLACE" = 1 ] && for t in ${OPERANDS[@]+"${OPERANDS[@]}"}; do target "$t"; done ;;
    yq)
      editor_parse || { UNSAFE="$UNSAFE$cmd: script read from a file"$'\n'; return 0; }
      for a in "${CMD_ARGS[@]:1}"; do case "$a" in -s|-s*|--split-exp*) UNSAFE="${UNSAFE}yq $a writes files"$'\n'; return 0 ;; esac; done
      for t in ${OPERANDS[@]+"${OPERANDS[@]}"}; do target "$t"; done ;;
    find)
      args=("${CMD_ARGS[@]}")
      gdd=0; gi=1
      while [ "$gi" -lt "${#args[@]}" ]; do
        a="${args[gi]}"; gi=$((gi + 1))
        case "$a" in
          -delete) gdd=1; UNSAFE="${UNSAFE}find $a"$'\n' ;;
          -exec|-execdir|-ok|-okdir)
            UNSAFE="${UNSAFE}find $a"$'\n'
            words=(); prev=""
            while [ "$gi" -lt "${#args[@]}" ]; do
              e="${args[gi]}"; gi=$((gi + 1))
              { [ "$e" = ';' ] || { [ "$e" = + ] && [ "$prev" = '{}' ]; }; } && break
              words+=("$e"); prev="$e"
            done
            find_exec ${words[@]+"${words[@]}"} || gdd=1 ;;
          -fprint|-fprint0|-fprintf|-fls) UNSAFE="${UNSAFE}find $a"$'\n' ;;
        esac
      done
      CMD_ARGS=("${args[@]}"); CMD_CHDIR="$chdir"; TGT_BASE="$chdir"
      [ "$gdd" = 0 ] || find_start_targets ;;
    tee|rm|unlink|rmdir|truncate|shred|sponge)
      operands; for t in ${OPERANDS[@]+"${OPERANDS[@]}"}; do target "$t"; done ;;
    touch) operands rdt; for t in ${OPERANDS[@]+"${OPERANDS[@]}"}; do target "$t"; done ;;
    mkdir)
      # Creates only the directory named: a protected entry or a path inside one is a hit; the
      # directories above (.claude, tests/e2e/docs) are not.
      operands m
      for t in ${OPERANDS[@]+"${OPERANDS[@]}"}; do
        if unresolved "$t"; then UNSAFE="${UNSAFE}mkdir: $t does not resolve"$'\n'
        else e=$(protected_bash_match "$t") && HITS="$HITS$e"$'\n'; fi
      done ;;
    cp|mv|install|ln) copy_targets ;;
    dd) for a in "${CMD_ARGS[@]}"; do case "$a" in of=*) target "${a#of=}" ;; esac; done ;;
    # Writers the guard reads targets from but cannot prove safe: what they write is not only those.
    chmod|chown|chgrp)
      operands
      [ "${#OPERANDS[@]}" = 0 ] || OPERANDS=("${OPERANDS[@]:1}")
      for t in ${OPERANDS[@]+"${OPERANDS[@]}"}; do target "$t"; done
      UNSAFE="$UNSAFE$cmd"$'\n' ;;
    rsync) operands; [ "${#OPERANDS[@]}" -gt 0 ] && target "${OPERANDS[${#OPERANDS[@]}-1]}"; UNSAFE="$UNSAFE$cmd"$'\n' ;;
    tar) optval C directory; UNSAFE="$UNSAFE$cmd"$'\n' ;;
    unzip) optval d d; UNSAFE="$UNSAFE$cmd"$'\n' ;;
    curl) optval o output; UNSAFE="$UNSAFE$cmd"$'\n' ;;
    wget) optval O output-document; UNSAFE="$UNSAFE$cmd"$'\n' ;;
    *) UNSAFE="$UNSAFE$cmd"$'\n' ;;
  esac
  return 0
}

shell_words "$CMD"
if [ "$SW_OVERFLOW" = 1 ]; then
  # Not split whole, so nothing on it is proved; the mention still keys the .claude/achilles rule.
  OVERFLOW=1
  e=$(protected_bash_mention "$CMD") && NAMED="$NAMED$e"$'\n'
else
  # The dequoted words, case-folded, catch every plain spelling at once. Words a substring test
  # can miss (//, /./, .., or a protected directory itself) are normalised one by one, a few
  # forks each; past 40 of them the line counts as unprovable.
  e=$(protected_bash_mention "${SW[*]}") && NAMED="$NAMED$e"$'\n'
  n=0
  for w in "${SW[@]}"; do
    case "$w" in
      *//*|*/./*|*..*|*[cC][lL][aA][uU][dD][eE]|*[cC][lL][aA][uU][dD][eE]/|*[dD][oO][cC][sS]|*[dD][oO][cC][sS]/)
        n=$((n + 1)); [ "$n" -le 40 ] && names "$w" ;;
    esac
  done
  [ "$n" -le 40 ] || NAMED="${NAMED}(over 40 paths: not every one was checked)"$'\n'
  shell_each_command judge_command
fi
# A protected write target or an unsplittable line denies; anything unprovable denies only on a
# line naming protected state.
[ -n "$HITS" ] || [ -n "$OVERFLOW" ] || { [ -n "$NAMED" ] && [ -n "$UNSAFE" ]; } || exit 0

# Session-scope gate: this guard applies only to achilles-activated
# sessions (lib/achilles-activation.sh) — EXCEPT for lines that name the
# session-activation state dir itself (.claude/achilles). That dir is the
# root of trust for every gate in the suite, so its protection is
# unconditional: an inactive session must not be able to strip another
# session's activation marker, and an active session must not deactivate
# itself by deleting its own.
case "$NAMED$HITS" in *.claude/achilles*) ;; *) achilles_require_active "$INPUT" ;; esac

if [ -n "$HITS" ]; then
  WHY="Writes into: $(printf '%s' "$HITS" | sort -u | tr '\n' ' ')"
elif [ -n "$OVERFLOW" ]; then
  WHY="Command too long to verify (over 32 KB, 16 nested shells or 64 brace expansions); split it."
else
  WHY="Cannot prove this command does not write: $(printf '%s' "$NAMED" | sort -u | tr '\n' ' ')
Because of: $(printf '%s' "$UNSAFE" | sort -u | tr '\n' ';')"
fi

REASON="[BLOCKED] This Bash command would mutate (or could mutate) a protected pipeline-state artifact out of band.

Command: ${CMD}
${WHY}

Protected artifacts (ledger, journey map, cycle/coverage state, approver
registry, findings ledger, integrity sidecar, the hook installation) may
only change through the Write/Edit tools — that is where the harness
gates (schema validation, state-machine checks, separation-of-duties,
integrity chain) live. A shell write would bypass them all.

Fix:
  - To change the artifact: use the Write or Edit tool on the file.
  - To read it: use a read-only command (cat, grep, jq, head, git diff …)
    on a line without interpreters, awk, eval or other programs.
  - Deleting a pipeline-state artifact is an operator decision: ask the
    user to remove it in their own terminal if a reset is intended.

$(no_skip_messaging_block)"

"$JQ" -n --arg r "$REASON${HOOK_REFS}$(achilles_scope_notice)" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": $r
  }
}'
exit 0
