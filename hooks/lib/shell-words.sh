#!/bin/bash
# shell-words.sh — the commands a Bash command line runs, as the shell would split them, so a guard
# judges invocations and write targets instead of text. Callers: protected-artifact-bash-guard.sh,
# playwright-cli-isolation-guard.sh.
#
# shell_words <command-line> fills SW with dequoted words. SW_SEP ends a command (; & | && || ( )
# newline); a redirection operator is one element prefixed with SW_OP, followed by its target (a
# heredoc's target is its body). The bodies of $( ) and backticks, and the scripts that
# `sh|bash|zsh|dash|ksh -c`, a heredoc fed to one of those shells, and `eval` run, are appended as
# further commands, up to SHELL_WORDS_NEST_CAP of them. An unquoted {a,b} expands to a word per
# alternative, as in bash; {a..b} and nested braces become a `*` so the word reads as a glob. Past
# the nest cap, SHELL_WORDS_BRACE_CAP words from one brace expansion, or SHELL_WORDS_MAX bytes
# (splitting costs ~0.1 ms a word, and a hook that times out allows), SW_OVERFLOW=1 and the
# split is partial or empty. Not expanded: variables, globs, aliases, functions — `$X/hooks`
# reaches the guard as written.
#
# shell_each_command <fn> calls <fn> once per command with
#   CMD_ARGS    command word (basename; assignments, the shell keywords if/then/else/while/do/!…
#               and the wrappers env, command, builtin, exec, nohup, time, nice, sudo, doas,
#               stdbuf, timeout, xargs, npx, bunx and npm|pnpm|yarn exec peeled, with the values
#               of their options; an npx package spec keeps its @scope and drops its @version)
#               then its arguments
#   CMD_PATH    the command word's directory when it is not a system bin dir, else empty: a
#               wrapper or program run from elsewhere is not the one its basename names
#   CMD_ENV     1 when an assignment or env preceded the command: its environment is the line's
#   CMD_WRITES  targets of the writing redirections (> >> >| &> &>> >&file <>, with any fd number)
#   CMD_HEREDOCS heredoc and here-string bodies
#   CMD_XARGS   1 when xargs supplies the operands
# The arrays can be empty: read them as ${A[@]+"${A[@]}"} (bash 3.2 under set -u).

SW_SEP=$'\036'
SW_OP=$'\037'
SHELL_WORDS_NEST_CAP=16
SHELL_WORDS_BRACE_CAP=64
SHELL_WORDS_MAX=32768
# Characters that end a run of plain word text, unquoted and inside double quotes.
SW__STOP=$'[\'" \t\n\\\\$`;&|()<>#]'
SW__DQ_STOP=$'["\\\\$`]'
# Unquoted braces are carried as these two bytes until the word is flushed, then expanded.
SW__LB=$'\035' SW__RB=$'\034' SW__OB='{' SW__CB='}' SW__STAR='*'

shell_words() {
  SW=(); SW_NESTED=0; SW_OVERFLOW=0
  if [ "${#1}" -gt "$SHELL_WORDS_MAX" ]; then SW_OVERFLOW=1; return 0; fi
  shell__split "$1"
  shell_each_command shell__expand
}

# shell__split <text> — append <text>'s words to SW. The helpers below share its locals.
# Characters are read from W, a 512-byte window of t at offset B: bash copies the whole string
# for every ${t:i:1}, which costs seconds on a 20 KB command; runs and bulk scans read t directly.
shell__split() {
  local LC_ALL=C t="$1" n=${#1} i=0 B=0 W="${1:0:512}" c w="" have=0 hd_next="" j sub
  local subs=() hds=()
  while [ "$i" -lt "$n" ]; do
    [ $((i - B)) -lt 256 ] || { B=$i; W="${t:i:512}"; }
    c="${W:i-B:1}"
    case "$c" in
      \') j="${t:i+1}"; j="${j%%\'*}"; w="$w$j"; have=1; i=$((i + ${#j} + 2)) ;;
      \") i=$((i + 1)); shell__dquote; have=1 ;;
      \\) [ "${W:i-B+1:1}" = $'\n' ] || { w="$w${W:i-B+1:1}"; have=1; }; i=$((i + 2)) ;;
      \$) case "${W:i-B+1:1}" in
            \() shell__subst ;;
            \') j="${t:i+2}"; j="${j%%\'*}"; w="$w$(printf '%b' "$j")"; have=1; i=$((i + ${#j} + 3)) ;;
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
      *) j="${W:i-B:256}"; j="${j%%$SW__STOP*}"; [ -n "$j" ] || j="$c"; i=$((i + ${#j}))
         case "$j" in *[{}]*) j="${j//"$SW__OB"/$SW__LB}"; j="${j//"$SW__CB"/$SW__RB}" ;; esac
         w="$w$j"; have=1 ;;
    esac
  done
  shell__flush
  for sub in ${subs[@]+"${subs[@]}"}; do shell__nested "$sub"; done
}

shell__flush() {
  [ "$have" = 1 ] || return 0
  case "$w" in
    *"$SW__LB"*|*"$SW__RB"*)
      if [ -z "$hd_next" ]; then SW__BRACE_N=0; shell__brace "" "$w"; w=""; have=0; return 0; fi
      w="${w//"$SW__LB"/$SW__OB}"; w="${w//"$SW__RB"/$SW__CB}" ;;
  esac
  SW+=("$w")
  if [ -n "$hd_next" ]; then hds+=("$((${#SW[@]} - 1)):$hd_next:$w"); hd_next=""; fi
  w=""; have=0
}

# shell__brace <literal prefix> <rest with SW__LB/SW__RB> — append the words bash makes of the
# unquoted braces: one per alternative of the first {a,b}, recursing into the rest; a range or a
# nested group turns the remainder into a glob; an unpaired or plain {x} brace is literal.
shell__brace() {
  local pre="$1" rest="$2" body post
  case "$rest" in
    *"$SW__LB"*"$SW__RB"*) ;;
    *) rest="${rest//"$SW__LB"/$SW__OB}"; SW+=("$pre${rest//"$SW__RB"/$SW__CB}"); SW__BRACE_N=$((SW__BRACE_N + 1)); return 0 ;;
  esac
  pre="$pre${rest%%"$SW__LB"*}"; rest="${rest#*"$SW__LB"}"; body="${rest%%"$SW__RB"*}"; post="${rest#*"$SW__RB"}"
  case "$body" in
    *"$SW__LB"*|?*..?*) post="${post//"$SW__LB"/$SW__STAR}"; SW+=("$pre$SW__STAR${post//"$SW__RB"/$SW__STAR}") ;;
    *,*) while :; do
           [ "$SW__BRACE_N" -lt "$SHELL_WORDS_BRACE_CAP" ] || { SW_OVERFLOW=1; return 0; }
           shell__brace "$pre${body%%,*}" "$post"
           case "$body" in *,*) body="${body#*,}" ;; *) return 0 ;; esac
         done ;;
    *) shell__brace "$pre$SW__OB$body$SW__CB" "$post" ;;
  esac
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

# $( … ): the word keeps the text; the body is split later as its own commands.
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
  subs+=("${t:i+2:k-i-2}")
  w="$w${t:i:k-i+1}"; have=1; i=$((k + 1))
}

shell__backtick() {
  local k=$((i + 1)) ch
  while :; do
    ch="${t:k}"; ch="${ch%%[\`\\]*}"; k=$((k + ${#ch}))
    [ "${t:k:1}" = '\\' ] || break
    k=$((k + 2))
  done
  subs+=("${t:i+1:k-i-1}")
  w="$w${t:i:k-i+1}"; have=1; i=$((k + 1))
}

shell__nested() {
  if [ "$SW_NESTED" -ge "$SHELL_WORDS_NEST_CAP" ]; then SW_OVERFLOW=1; return 0; fi
  SW_NESTED=$((SW_NESTED + 1))
  SW+=("$SW_SEP")
  shell__split "$1"
}

# The scripts a shell or eval runs.
shell__expand() {
  local a k=1 b
  case "${CMD_ARGS[0]:-}" in
    sh|bash|zsh|dash|ksh)
      while [ "$k" -lt "${#CMD_ARGS[@]}" ]; do
        a="${CMD_ARGS[k]}"; k=$((k + 1))
        case "$a" in
          -o|-O|+o|+O|--init-file|--rcfile) k=$((k + 1)) ;;
          --*) ;;
          -*c*) [ "$k" -lt "${#CMD_ARGS[@]}" ] && shell__nested "${CMD_ARGS[k]}"; break ;;
          -*) ;;
          *) break ;;
        esac
      done
      for b in ${CMD_HEREDOCS[@]+"${CMD_HEREDOCS[@]}"}; do shell__nested "$b"; done ;;
    eval) [ "${#CMD_ARGS[@]}" -gt 1 ] && shell__nested "${CMD_ARGS[*]:1}" ;;
  esac
  return 0
}

shell_each_command() {
  local fn="$1" k=0 word op wrapped dir peel skip
  while [ "$k" -le "${#SW[@]}" ]; do
    CMD_ARGS=(); CMD_WRITES=(); CMD_HEREDOCS=(); CMD_XARGS=0; CMD_ENV=0; CMD_PATH=""; wrapped=""; peel=1; skip=0
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
      if [ "$peel" = 1 ]; then
        [ "$skip" = 0 ] || { skip=0; continue; }
        case "$word" in
          [A-Za-z_]*=*) case "${word%%=*}" in *[!A-Za-z0-9_]*) ;; *) CMD_ENV=1; continue ;; esac ;;
        esac
        # A wrapper is only itself when it comes from a system bin dir; `@scope/name` is a package.
        dir=""
        case "$word" in
          @*) ;;
          */*) dir="${word%/*}"; dir="${dir:-/}"
               case "$dir" in /bin|/usr/bin|/usr/local/bin|/opt/homebrew/bin|/usr/sbin|/sbin) dir="" ;; esac ;;
        esac
        if [ -z "$dir" ]; then
          case "${word##*/}" in
            if|then|elif|else|fi|while|until|do|done|'!') continue ;;
            command) case "${SW[k]:-}" in -v|-V) ;; *) wrapped=command; continue ;; esac ;;
            env) CMD_ENV=1; wrapped=env; continue ;;
            builtin|exec|nohup|time|nice|sudo|doas|stdbuf|timeout) wrapped="${word##*/}"; continue ;;
            npx|bunx) wrapped=npx; continue ;;
            xargs) wrapped=xargs; CMD_XARGS=1; continue ;;
            npm|pnpm|yarn) if [ "${SW[k]:-}" = exec ]; then k=$((k + 1)); wrapped=npx; continue; fi ;;
          esac
        fi
        if [ -n "$wrapped" ]; then
          case "$word" in
            -*) case "$wrapped:$word" in
                  npx:-p|npx:--package|sudo:-u|sudo:-g|sudo:-U|sudo:-C|sudo:-D|sudo:-R|sudo:-T|sudo:-r|sudo:-t|sudo:-p| \
                  doas:-u|doas:-C|env:-u|env:--unset|env:-C|env:--chdir|timeout:-k|timeout:-s|timeout:--kill-after|timeout:--signal| \
                  nice:-n|stdbuf:-i|stdbuf:-o|stdbuf:-e|xargs:-I|xargs:-n|xargs:-L|xargs:-P|xargs:-s|xargs:-d|xargs:-a|xargs:-E|xargs:-J|xargs:-R|xargs:-S) skip=1 ;;
                esac; continue ;;
            [0-9]|[0-9]*[0-9smhd]) continue ;;
          esac
        fi
        peel=0; CMD_PATH="$dir"
        case "$word" in
          @*) word="${word#@}"; word="@${word%%@*}" ;;
          *) [ "$wrapped" = npx ] && word="${word%%@*}"; word="${word##*/}" ;;
        esac
      fi
      CMD_ARGS+=("$word")
    done
    if [ "${#CMD_ARGS[@]}" -gt 0 ] || [ "${#CMD_WRITES[@]}" -gt 0 ]; then "$fn"; fi
    k=$((k + 1))
  done
}
