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
#   CMD_ARGS    command word (basename; assignments, the shell keywords if/then/else/while/do/!…,
#               the reserved words { and } of a brace group or function body, `function NAME`,
#               `coproc [NAME]` and the wrappers env, command, builtin, exec, nohup, time, nice,
#               sudo, doas, stdbuf, timeout, xargs, npx, bunx and npm|pnpm|yarn exec peeled, with
#               the values of their options; an npx package spec keeps its @scope and drops its @version)
#               then its arguments
#   CMD_PATH    the command word's directory when it is not a system bin dir, else empty: a
#               wrapper or program run from elsewhere is not the one its basename names
#   CMD_ASSIGN  the assignment words peeled before the command word
#   CMD_ENV     1 when an assignment or env preceded the command: its environment is the line's
#   CMD_WRITES  targets of the writing redirections (> >> >| &> &>> >&file <>, with any fd number)
#               and the file named by time -o / --output
#   CMD_SNEST   strings a known wrapper runs as a command (env -S, npx -c), re-split as nested commands
#   CMD_WRAP_BAD 1 when a wrapper carried an option the peeler does not recognise: the command word
#               is then unknown and the caller must not treat the command as judged
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
            \') shell__ansic ;;
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

# $'…' — ANSI-C quotes. A backslash escapes the next character, so the closing quote is the first
# ' not preceded by an odd run of backslashes. The escaping backslash before a quote is dropped and
# a literal quote kept; every other escape (\x2e, \056, \141, \\) is left for printf %b.
shell__ansic() {
  local rest="${t:i+2}" piece bs body="" consumed=0
  while :; do
    piece="${rest%%\'*}"
    if [ "$piece" = "$rest" ]; then body="$body$piece"; consumed=$((consumed + ${#piece})); break; fi
    bs="${piece##*[!\\]}"
    if [ $(( ${#bs} % 2 )) -eq 1 ]; then
      body="$body${piece%\\}'"; consumed=$((consumed + ${#piece} + 1)); rest="${rest:${#piece}+1}"
    else
      body="$body$piece"; consumed=$((consumed + ${#piece} + 1)); break
    fi
  done
  w="$w$(printf '%b' "$body")"; have=1; i=$((i + 2 + consumed))
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
  local b
  for b in ${CMD_SNEST[@]+"${CMD_SNEST[@]}"}; do shell__nested "$b"; done
  case "${CMD_ARGS[0]:-}" in
    sh|bash|zsh|dash|ksh)
      shell_script_arg
      [ "$SW_SCRIPT_C" = 1 ] && shell__nested "${CMD_ARGS[SW_SCRIPT]}"
      for b in ${CMD_HEREDOCS[@]+"${CMD_HEREDOCS[@]}"}; do shell__nested "$b"; done ;;
    eval) [ "${#CMD_ARGS[@]}" -gt 1 ] && shell__nested "${CMD_ARGS[*]:1}" ;;
  esac
  return 0
}

# shell_script_arg — for CMD_ARGS of a shell: SW_SCRIPT is the index of its script operand (the -c
# string, or the script file) and SW_SCRIPT_C is 1 for a -c string; 0 and 0 when there is none.
# Every later word is a positional parameter.
shell_script_arg() {
  local a k=1
  SW_SCRIPT=0; SW_SCRIPT_C=0
  while [ "$k" -lt "${#CMD_ARGS[@]}" ]; do
    a="${CMD_ARGS[k]}"; k=$((k + 1))
    case "$a" in
      -o|-O|+o|+O|--init-file|--rcfile) k=$((k + 1)) ;;
      --*) ;;
      -*c*) if [ "$k" -lt "${#CMD_ARGS[@]}" ]; then SW_SCRIPT=$k; SW_SCRIPT_C=1; fi; return 0 ;;
      -*) ;;
      *) SW_SCRIPT=$((k - 1)); return 0 ;;
    esac
  done
  return 0
}

# shell_word_literal <word> — 0 when the shell would run or read the word as written: no variable,
# command substitution, backtick or glob character. A quoted one counts too: the splitter drops quotes.
shell_word_literal() {
  case "$1" in *[\$\`*?[]*) return 1 ;; esac
  return 0
}

# shell_git_exec_option <word> — 0 when a git option makes git run a program or write a file named
# by its value, whatever the subcommand.
shell_git_exec_option() {
  case "$1" in
    --exec-path|--exec-path=*|--config-env|--config-env=*|--output*|--upload-pack*|--receive-pack*|--ext-diff|--textconv|-O*|--open-files-in-pager*) return 0 ;;
  esac
  return 1
}

# shell__wrapopt <wrapper> <option> — classify <option> for <wrapper>, inverting to unknown=unsafe.
# Sets WOPT to: val (value is the next word), self (value glued or a flag), snest / snestnext
# (env -S, npx -c: a command string, glued in WVAL or the next word), wself / wnext (time -o: a file
# the wrapper writes, glued in WVAL or the next word), or bad (unrecognised → the command is unsafe).
# Only options the peeler must skip to reach the real command are listed.
shell__wrapopt() {
  local w="$1" o="$2" base letters m ch rest
  WOPT=bad; WVAL=""
  case "$o" in
    --*)
      base="${o%%=*}"
      case "$w:$base" in
        env:--split-string|npx:--call) case "$o" in *=*) WVAL="${o#*=}"; WOPT=snest ;; *) WOPT=snestnext ;; esac; return 0 ;;
        time:--output) case "$o" in *=*) WVAL="${o#*=}"; WOPT=wself ;; *) WOPT=wnext ;; esac; return 0 ;;
        env:--unset|env:--argv0|env:--chdir|env:--block-signal|env:--default-signal|env:--ignore-signal|\
        nice:--adjustment|time:--format|timeout:--signal|timeout:--kill-after|\
        stdbuf:--input|stdbuf:--output|stdbuf:--error|\
        sudo:--user|sudo:--group|sudo:--close-from|sudo:--host|sudo:--prompt|sudo:--role|sudo:--type|sudo:--other-user|sudo:--command-timeout|\
        doas:--user|\
        xargs:--max-args|xargs:--max-lines|xargs:--max-procs|xargs:--max-chars|xargs:--delimiter|xargs:--arg-file|xargs:--eof|xargs:--replace|xargs:--process-slot-var|\
        npx:--package|npx:--loglevel|npx:--userconfig|npx:--cache)
          case "$o" in *=*) WOPT=self ;; *) WOPT=val ;; esac; return 0 ;;
        env:--null|env:--ignore-environment|env:--debug|env:--version|env:--help|\
        nice:--help|nice:--version|\
        time:--portability|time:--verbose|time:--append|time:--quiet|time:--help|time:--version|\
        timeout:--preserve-status|timeout:--foreground|timeout:--verbose|timeout:--help|timeout:--version|\
        stdbuf:--help|stdbuf:--version|\
        sudo:--preserve-env|sudo:--background|sudo:--login|sudo:--non-interactive|sudo:--stdin|sudo:--shell|sudo:--set-home|sudo:--remove-timestamp|sudo:--reset-timestamp|sudo:--validate|sudo:--list|sudo:--help|sudo:--version|\
        doas:--*|\
        xargs:--null|xargs:--no-run-if-empty|xargs:--verbose|xargs:--exit|xargs:--interactive|xargs:--open-tty|xargs:--help|xargs:--version|\
        npx:--yes|npx:--no-yes|npx:--quiet|npx:--no-install|npx:--prefer-online|npx:--prefer-offline|npx:--offline|npx:--ignore-existing)
          WOPT=self; return 0 ;;
        *) WOPT=bad; return 0 ;;
      esac ;;
    -)  WOPT=bad; return 0 ;;
    -?*)
      letters="${o#-}"; m=0
      while [ "$m" -lt "${#letters}" ]; do
        ch="${letters:m:1}"; m=$((m + 1)); rest="${letters:m}"
        case "$w:$ch" in
          exec:a|env:u|env:C|env:P|env:a|nice:n|time:f|timeout:s|timeout:k|stdbuf:i|stdbuf:o|stdbuf:e|\
          sudo:u|sudo:g|sudo:C|sudo:h|sudo:p|sudo:r|sudo:t|sudo:U|sudo:T|\
          doas:u|doas:C|\
          xargs:I|xargs:i|xargs:n|xargs:L|xargs:P|xargs:s|xargs:d|xargs:a|xargs:E|xargs:e|xargs:J|xargs:R|xargs:S|\
          npx:p)
            if [ -n "$rest" ]; then WOPT=self; else WOPT=val; fi; return 0 ;;
          env:S|npx:c)
            if [ -n "$rest" ]; then WVAL="$rest"; WOPT=snest; else WOPT=snestnext; fi; return 0 ;;
          time:o)
            if [ -n "$rest" ]; then WVAL="$rest"; WOPT=wself; else WOPT=wnext; fi; return 0 ;;
          env:i|env:0|env:v|exec:c|exec:l|nice:[0-9]|time:p|time:l|time:a|time:h|time:v|time:q|time:V|\
          timeout:v|\
          sudo:E|sudo:H|sudo:i|sudo:n|sudo:S|sudo:s|sudo:b|sudo:k|sudo:K|sudo:v|sudo:l|sudo:A|sudo:P|sudo:e|\
          doas:L|doas:n|doas:s|\
          xargs:0|xargs:r|xargs:t|xargs:x|xargs:p|xargs:o|\
          command:p|\
          npx:y|npx:q)
            : ;;
          *) WOPT=bad; return 0 ;;
        esac
      done
      WOPT=self; return 0 ;;
  esac
}

shell_each_command() {
  local fn="$1" k=0 word op wrapped dir peel skip snest_pending write_pending
  while [ "$k" -le "${#SW[@]}" ]; do
    CMD_ARGS=(); CMD_WRITES=(); CMD_HEREDOCS=(); CMD_SNEST=(); CMD_ASSIGN=(); CMD_XARGS=0; CMD_ENV=0; CMD_WRAP_BAD=0
    CMD_PATH=""; wrapped=""; peel=1; skip=0; snest_pending=0; write_pending=0
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
        if [ "$snest_pending" = 1 ]; then CMD_SNEST+=("$word"); snest_pending=0; continue; fi
        if [ "$write_pending" = 1 ]; then CMD_WRITES+=("$word"); write_pending=0; continue; fi
        case "$word" in
          [A-Za-z_]*=*) case "${word%%=*}" in *[!A-Za-z0-9_]*) ;; *) CMD_ENV=1; CMD_ASSIGN+=("$word"); continue ;; esac ;;
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
            if|then|elif|else|fi|while|until|do|done|'!'|'{'|'}') continue ;;
            function) skip=1; continue ;;
            coproc) if [ "${SW[k+1]:-}" = '{' ]; then skip=1; fi; continue ;;
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
            --) wrapped=""; continue ;;
            -*) shell__wrapopt "$wrapped" "$word"
                case "$WOPT" in
                  val) skip=1; continue ;;
                  self) continue ;;
                  snest) CMD_SNEST+=("$WVAL"); CMD_WRAP_BAD=1; continue ;;
                  snestnext) snest_pending=1; CMD_WRAP_BAD=1; continue ;;
                  wself) CMD_WRITES+=("$WVAL"); continue ;;
                  wnext) write_pending=1; continue ;;
                  *) CMD_WRAP_BAD=1 ;;
                esac ;;
            *) [ "$wrapped" = timeout ] && case "$word" in [0-9]*) continue ;; esac ;;
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
    if [ "${#CMD_ARGS[@]}" -gt 0 ] || [ "${#CMD_WRITES[@]}" -gt 0 ] || [ "$CMD_ENV" = 1 ] || [ "${#CMD_SNEST[@]}" -gt 0 ]; then "$fn"; fi
    k=$((k + 1))
  done
}
