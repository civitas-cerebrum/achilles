#!/bin/bash
# shell-words.sh — the commands a Bash line runs, split as the shell would, so a hook judges invocations
# and write targets instead of text. The only shell parser in hooks/.
#
# shell_words <line> fills SW with dequoted words. SW_SEP ends a command (; & | && || ( ) newline); a
# redirection is one element prefixed with SW_OP, followed by its target (a heredoc's target is its
# body). $( ), backticks, $'…' and ${…} stay in their word as written: nothing is expanded, so a hook
# sees them as unresolved. Over SHELL_WORDS_MAX bytes SW is empty and SW_OVERFLOW=1; callers deny.
#
# shell_each_command <fn> calls <fn> once per command with
#   CMD_ARGS     the command word (basename; an npx package spec keeps its @scope, drops its @version)
#                and its arguments. Peeled first: assignments, the keywords if then elif else fi while
#                until do done ! { }, and the wrappers command, exec, nohup, time, timeout N, env, npx,
#                bunx and npm|pnpm|yarn|bun exec|dlx.
#   CMD_ASSIGN   the assignment words peeled
#   CMD_ENV      1 when an assignment or env preceded the command
#   CMD_CHDIR    the directory of env -C DIR, else empty
#   CMD_WRAP_BAD 1 when a wrapper carried an option the peeler does not know: the command is unknown
#   CMD_WRITES   targets of > >> >| &> &>> >&file <> (with any fd number)
#   CMD_HEREDOCS heredoc and here-string bodies
# The arrays can be empty: read them as ${A[@]+"${A[@]}"} (bash 3.2 under set -u).
#
# shell_is_reader is the one allowlist of commands that only read.

SW_SEP=$'\036'
SW_OP=$'\037'
SHELL_WORDS_MAX=32768
# Characters that end a run of plain word text, unquoted and inside double quotes.
SW__STOP=$'[\'" \t\n\\\\$`;&|()<>#]'
SW__DQ_STOP=$'["\\\\$`]'
SW__CB='}'
# Programs that read their operands and run nothing they are handed, and the git subcommands that
# write only under .git.
SHELL_READERS=' cat head tail grep egrep fgrep rg ls stat wc diff cmp file sha256sum shasum md5 md5sum jq echo printf test [ which type pgrep '
SHELL_GIT_READS=' status diff log show ls-files blame commit add rev-parse grep fetch '

shell_words() {
  SW=(); SW_OVERFLOW=0
  if [ "${#1}" -gt "$SHELL_WORDS_MAX" ]; then SW_OVERFLOW=1; return 0; fi
  shell__split "$1"
}

# shell__split <text> — append <text>'s words to SW. The helpers below share its locals.
# Characters are read from W, a 512-byte window of t at offset B: bash copies the whole string
# for every ${t:i:1}, which costs seconds on a 20 KB command; runs and bulk scans read t directly.
shell__split() {
  local LC_ALL=C t="$1" n=${#1} i=0 B=0 W="${1:0:512}" c w="" have=0 hd_next="" j
  local hds=()
  while [ "$i" -lt "$n" ]; do
    [ $((i - B)) -lt 256 ] || { B=$i; W="${t:i:512}"; }
    c="${W:i-B:1}"
    case "$c" in
      \') j="${t:i+1}"; j="${j%%\'*}"; w="$w$j"; have=1; i=$((i + ${#j} + 2)) ;;
      \") i=$((i + 1)); shell__dquote; have=1 ;;
      \\) [ "${W:i-B+1:1}" = $'\n' ] || { w="$w${W:i-B+1:1}"; have=1; }; i=$((i + 2)) ;;
      \$) case "${W:i-B+1:1}" in
            \() shell__subst ;;
            \{) j="${t:i}"; j="${j%%"$SW__CB"*}"; w="$w$j$SW__CB"; have=1; i=$((i + ${#j} + 1)) ;;
            *) w="$w\$"; have=1; i=$((i + 1)) ;;
          esac ;;
      \`) shell__backtick ;;
      ' '|$'\t') shell__flush; i=$((i + 1)) ;;
      $'\n') shell__flush; SW+=("$SW_SEP"); i=$((i + 1)); shell__heredocs ;;
      ';'|'|'|'('|')') shell__flush; SW+=("$SW_SEP"); i=$((i + 1)) ;;
      '&') shell__flush
           if [ "${W:i-B+1:1}" = '>' ]; then shell__redir; else SW+=("$SW_SEP"); i=$((i + 1)); fi ;;
      # Digits glued to the operator are its fd number, not a word.
      '<'|'>') case "$w" in ''|*[!0-9]*) shell__flush ;; *) w=""; have=0 ;; esac; shell__redir ;;
      '#') if [ "$have" = 0 ]; then j="${t:i}"; j="${j%%$'\n'*}"; i=$((i + ${#j})); else w="$w#"; i=$((i + 1)); fi ;;
      *) j="${W:i-B:256}"; j="${j%%$SW__STOP*}"; [ -n "$j" ] || j="$c"; i=$((i + ${#j})); w="$w$j"; have=1 ;;
    esac
  done
  shell__flush
}

shell__flush() {
  [ "$have" = 1 ] || return 0
  SW+=("$w")
  if [ -n "$hd_next" ]; then hds+=("$((${#SW[@]} - 1)):$hd_next:$w"); hd_next=""; fi
  w=""; have=0
}

# Longest operator first.
shell__redir() {
  local op
  for op in '<<<' '<<-' '&>>' '>>' '>|' '>&' '<<' '<>' '<&' '&>' '>' '<'; do
    [ "${W:i-B:${#op}}" = "$op" ] && break
  done
  i=$((i + ${#op}))
  SW+=("$SW_OP$op")
  case "$op" in '<<'|'<<-') hd_next="$op" ;; esac
}

# At the start of the line after a heredoc operator: each pending body replaces its delimiter word.
shell__heredocs() {
  local h idx op d line body
  for h in ${hds[@]+"${hds[@]}"}; do
    idx="${h%%:*}"; h="${h#*:}"; op="${h%%:*}"; d="${h#*:}"; body=""
    while [ "$i" -lt "$n" ]; do
      line="${t:i}"; line="${line%%$'\n'*}"; i=$((i + ${#line} + 1))
      [ "$op" = '<<-' ] && line="${line#"${line%%[!$'\t']*}"}"
      [ "$line" = "$d" ] && break
      body="$body$line"$'\n'
    done
    SW[idx]="$body"
  done
  hds=()
}

shell__dquote() {
  while [ "$i" -lt "$n" ]; do
    [ $((i - B)) -lt 256 ] || { B=$i; W="${t:i:512}"; }
    c="${W:i-B:1}"
    case "$c" in
      \") i=$((i + 1)); return 0 ;;
      \\) case "${W:i-B+1:1}" in
            \"|\\|\$|\`) w="$w${W:i-B+1:1}" ;;
            $'\n') ;;
            *) w="$w\\${W:i-B+1:1}" ;;
          esac
          i=$((i + 2)) ;;
      \$) if [ "${W:i-B+1:1}" = "(" ]; then shell__subst; else w="$w\$"; i=$((i + 1)); fi ;;
      \`) shell__backtick ;;
      *) j="${W:i-B:256}"; j="${j%%$SW__DQ_STOP*}"; [ -n "$j" ] || j="$c"; w="$w$j"; i=$((i + ${#j})) ;;
    esac
  done
}

# $( … ) stays in the word as written; its separators do not split the line.
shell__subst() {
  local k=$((i + 2)) depth=1 ch
  while [ "$k" -lt "$n" ]; do
    [ $((k - B)) -lt 256 ] || { B=$k; W="${t:k:512}"; }
    ch="${W:k-B:1}"
    case "$ch" in
      \() depth=$((depth + 1)) ;;
      \)) depth=$((depth - 1)); [ "$depth" = 0 ] && break ;;
      \') ch="${t:k+1}"; ch="${ch%%\'*}"; k=$((k + ${#ch} + 1)) ;;
      \") ch="${t:k+1}"; ch="${ch%%[\"\\]*}"; k=$((k + ${#ch} + 1))
          while [ "${t:k:1}" = '\\' ]; do ch="${t:k+2}"; ch="${ch%%[\"\\]*}"; k=$((k + ${#ch} + 2)); done ;;
      \\) k=$((k + 1)) ;;
    esac
    k=$((k + 1))
  done
  w="$w${t:i:k-i+1}"; have=1; i=$((k + 1))
}

shell__backtick() {
  local k=$((i + 1)) ch
  while :; do
    ch="${t:k}"; ch="${ch%%[\`\\]*}"; k=$((k + ${#ch}))
    [ "${t:k:1}" = '\\' ] || break
    k=$((k + 2))
  done
  w="$w${t:i:k-i+1}"; have=1; i=$((k + 1))
}

# shell_is_reader — 0 when CMD_ARGS only reads: a SHELL_READERS program, command -v|-V,
# npm ls|list|view|info, or git with a SHELL_GIT_READS subcommand.
shell_is_reader() {
  case "$SHELL_READERS" in *" ${CMD_ARGS[0]:-} "*) return 0 ;; esac
  case "${CMD_ARGS[0]:-}:${CMD_ARGS[1]:-}" in
    command:-v|command:-V|npm:ls|npm:list|npm:view|npm:info) return 0 ;;
    git:?*) case "$SHELL_GIT_READS" in *" ${CMD_ARGS[1]} "*) return 0 ;; esac ;;
  esac
  return 1
}

shell_each_command() {
  local fn="$1" k=0 word op wrapped skip
  while [ "$k" -le "${#SW[@]}" ]; do
    CMD_ARGS=(); CMD_WRITES=(); CMD_HEREDOCS=(); CMD_ASSIGN=(); CMD_ENV=0; CMD_WRAP_BAD=0; CMD_CHDIR=""
    wrapped=""; skip=""
    while [ "$k" -lt "${#SW[@]}" ] && [ "${SW[k]}" != "$SW_SEP" ]; do
      word="${SW[k]}"; k=$((k + 1))
      case "$word" in
        "$SW_OP"*)
          op="${word#"$SW_OP"}"
          [ "$k" -lt "${#SW[@]}" ] && [ "${SW[k]}" != "$SW_SEP" ] || continue
          case "$op:${SW[k]}" in
            '>&:-'|'>&:'[0-9]*) ;;
            '>:'*|'>>:'*|'>|:'*|'&>:'*|'&>>:'*|'>&:'*|'<>:'*) CMD_WRITES+=("${SW[k]}") ;;
            '<<:'*|'<<-:'*|'<<<:'*) CMD_HEREDOCS+=("${SW[k]}") ;;
          esac
          k=$((k + 1)); continue ;;
      esac
      if [ "${#CMD_ARGS[@]}" = 0 ]; then
        case "$skip" in chdir) CMD_CHDIR="$word"; skip=""; continue ;; value) skip=""; continue ;; esac
        case "$word" in
          [A-Za-z_]*=*) case "${word%%=*}" in *[!A-Za-z0-9_]*) ;; *) CMD_ENV=1; CMD_ASSIGN+=("$word"); continue ;; esac ;;
          if|then|elif|else|fi|while|until|do|done|'!'|'{'|'}') [ -z "$wrapped" ] && continue ;;
        esac
        case "$wrapped:$word" in
          ?*:--) wrapped="$wrapped--"; continue ;;
          env:-C|env:--chdir) skip=chdir; continue ;;
          env:-C?*) CMD_CHDIR="${word#-C}"; continue ;;
          env:--chdir=*) CMD_CHDIR="${word#*=}"; continue ;;
          env:-u) skip=value; continue ;;
          env:-i|time:-p|npx:-y|npx:--yes|npx:--no|npx:--no-install|timeout:[0-9]*) continue ;;
          env:-*|exec:-*|nohup:-*|time:-*|timeout:-*|npx:-*) CMD_WRAP_BAD=1; continue ;;
        esac
        case "${word##*/}" in
          command) case "${SW[k]:-}" in -v|-V) ;; *) wrapped=command; continue ;; esac ;;
          env) CMD_ENV=1; wrapped=env; continue ;;
          exec|nohup|time|timeout) wrapped="${word##*/}"; continue ;;
          npx|bunx) wrapped=npx; continue ;;
          npm|pnpm|yarn|bun) case "${SW[k]:-}" in exec|dlx) k=$((k + 1)); wrapped=npx; continue ;; esac ;;
        esac
        case "$word" in
          @*) word="${word#@}"; word="@${word%%@*}" ;;
          *) case "$wrapped" in npx*) word="${word%%@*}" ;; esac; word="${word##*/}" ;;
        esac
      fi
      CMD_ARGS+=("$word")
    done
    if [ "${#CMD_ARGS[@]}" -gt 0 ] || [ "${#CMD_WRITES[@]}" -gt 0 ] || [ "$CMD_ENV" = 1 ]; then "$fn"; fi
    k=$((k + 1))
  done
}
