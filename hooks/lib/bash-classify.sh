#!/bin/bash
# bash-classify.sh — which git/gh invocation a Bash command is. Pure string tests,
# no JQ. Not quote-aware, except where noted: a quoted mention of the command can match.
#
# The gh detectors are three differently-shaped tests and stay apart on purpose:
# unifying them would change which commands each gate sees.

# bash_classify_is_git_commit <cmd> — `git commit`, through `command`/`env` wrappers and `-c k=v` / `--long[=v]` flags.
bash_classify_is_git_commit() {
  local re='(^|[;&|][[:space:]]*)((command|env)[[:space:]]+)?git([[:space:]]+(-[cC][[:space:]]+[^[:space:]]+|--[a-z-]+(=[^[:space:]]+)?))*[[:space:]]+commit([[:space:]]|$)'
  echo "$1" | grep -qE "$re"
}

# bash_classify_is_gh_pr <cmd> [create|edit] — `gh pr create|edit` (default: either), through wrappers and global flags.
bash_classify_is_gh_pr() {
  local sub="${2:-create|edit}"
  local re='(^|[;&|][[:space:]]*)((command|env)[[:space:]]+)?gh([[:space:]]+--[a-z-]+(=[^[:space:]]+)?)*[[:space:]]+pr[[:space:]]+('"$sub"')([[:space:]]|$)'
  echo "$1" | grep -qE "$re"
}

# bash_classify_is_gh_pr_publish <cmd> — `gh pr create|ready` with `gh` first in the command or after a separator; no wrappers.
bash_classify_is_gh_pr_publish() {
  printf '%s' "$1" | grep -qE '(^|[;&|])[[:space:]]*gh[[:space:]]+pr[[:space:]]+(create|ready)([[:space:]]|$)'
}

# bash_classify_has_draft_flag <cmd> — bare `--draft` / `-d` anywhere in the command.
bash_classify_has_draft_flag() {
  printf '%s' "$1" | grep -qE '(^|[[:space:]])(--draft|-d)([[:space:]]|$)'
}

# ─── Segment-level `gh pr create|ready` detector (evidence-bundle-gate) ─────
# Strip quoted strings and trailing comments before looking at flags. Scanning
# the raw command for `-d` matched flags mentioned inside a PR title or body,
# which silently disabled the gate on ordinary commands.
# The `#` arm only fires at a word boundary. A shell comment must start a word;
# `#` inside one is literal, so stripping it context-free ate the rest of the
# line — `gh pr create --title issue#5 --draft` lost its `--draft` and denied a
# genuine draft PR with nothing in the message to explain why.
strip_quoted() {
  printf '%s' "$1" | sed -E "s/'[^']*'/ /g; s/\"[^\"]*\"/ /g; s/(^|[[:space:]])#.*$/\1/"
}

# Peel wrapper prefixes off one command segment so the real program is first.
# `env`, `command`, `time`, `nohup`, `exec`, `eval`, `sh -c`, `bash -lc` and
# leading `VAR=val` assignments are how people actually script `gh` — treating
# them as evasions to be ignored left every one of them ungated.
#
# The assignment arm is matched against the FIRST TOKEN ONLY, and its name part
# must be identifier characters. An earlier version used the glob
# `[A-Za-z_]*=*\ *`, which does not mean "starts with an assignment" — it means
# "contains `=` with a space somewhere after it", so it matched the gh command
# itself and peeled `gh` away word by word. `gh pr create --base=main --fill`
# (the flag form in gh's own documentation, with any argument after it) silently
# disabled the gate. That regression was strictly worse than the hole it was
# written to close, because it fired on ordinary interactive use rather than on
# opt-in scripting forms.
#
# EVERY arm below must consume at least one character before it `continue`s, and
# the assignment arm strips the TOKEN rather than "up to the first space" for
# exactly that reason: `${s#* }` on a segment with no space is a no-op, so the
# first draft of the fix above spun forever on a bare `A=1` — an ordinary Bash
# command, on which the gate then rendered no decision at all until the harness
# timed it out. A hook that never returns is a hook that is off, and it takes
# the tool call with it. PEEL_CAP is the belt to that braces: if a future arm is
# added that can fail to consume, the loop gives up and lets the segment be
# judged as-is instead of hanging the tool call.
PEEL_CAP=32
normalise_segment() {
  local s="$1" peeled=0 tok name i=0
  while [ "$i" -lt "$PEEL_CAP" ]; do
    i=$((i + 1))
    s="${s#"${s%%[![:space:]]*}"}"
    case "$s" in
      \"*|\'*|\\*|\`*) s="${s#?}"; peeled=1; continue ;;
      env\ *|command\ *|time\ *|nohup\ *|exec\ *|eval\ *|sudo\ *|npx\ *) s="${s#* }"; peeled=1; continue ;;
      sh\ *|bash\ *|zsh\ *|dash\ *)              s="${s#* }"   ; peeled=1; continue ;;
      */sh\ *|*/bash\ *|*/zsh\ *|*/dash\ *)      s="${s#* }"   ; peeled=1; continue ;;
    esac
    tok="${s%%[[:space:]]*}"
    case "$tok" in
      [A-Za-z_]*=*)
        name="${tok%%=*}"
        case "$name" in
          *[!A-Za-z0-9_]*) ;;
          # Strip the token itself — never "up to the first space", which does
          # nothing when the segment IS the assignment.
          #
          # Except when the VALUE opens a substitution or a quote: `OUT=`gh pr
          # create`` has no space to stop at, so the token runs to `OUT=`gh` and
          # stripping it swallows the backtick and the program name together.
          # Strip just `NAME=` there and let the peel arm above take the opener.
          # Found by the suite when the segment splitter stopped breaking on
          # backticks — the two changes are only safe as a pair.
          *)
            case "${tok#*=}" in
              \`*|\"*|\'*) s="${s#*=}" ;;
              *)              s="${s#"$tok"}" ;;
            esac
            peeled=1; continue ;;
        esac
        ;;
    esac
    # A flag can only belong to a wrapper we already peeled (`sh -c`, `bash -lc`).
    if [ "$peeled" = "1" ]; then
      case "$s" in -*\ *) s="${s#* }"; continue ;; esac
    fi
    break
  done
  printf '%s' "$s"
}

# bash_classify_gh_pr_publish_segment <cmd> — prints the first segment of <cmd> that is a
# `gh pr create|ready` (wrappers, quoting and continuations normalised), else nothing.
bash_classify_gh_pr_publish_segment() {
  local CMD_JOINED seg norm probe first rest
  # Join backslash-newline continuations before segmenting: `gh pr \` + newline +
  # `create` is one command to the shell and was two segments to the gate, so the
  # subcommand test never saw `pr create`.
  CMD_JOINED="$(printf '%s' "$1" | sed -e :a -e '/\\$/N; s/\\\n/ /; ta')"
  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    # The probe costs two forks per segment. A segment with no `gh` substring
    # anywhere cannot normalise INTO one — peeling only removes prefixes — so
    # skipping here is free correctness-wise and keeps a many-segment command
    # from eating the budget before the HAR scan starts.
    case "$seg" in *gh*) ;; *) continue ;; esac
    norm="$(normalise_segment "$seg")"
    # Classification runs on a normalised PROBE, never on `norm` itself: quotes
    # are removed and whitespace runs collapsed, so `"gh" pr create`,
    # `gh pr "create"`, `gh pr<TAB>create` and `gh pr  create` classify like the
    # plain form. All are valid shell that publishes a PR, and all were silently
    # allowed — the old code peeled a LEADING quote only, which left the closing
    # one glued to the token so `first` was `gh"` and matched nothing. A half-
    # handled quote arm is worse than none: it reads as though quoting is covered.
    #
    # GH_SEGMENT keeps the ORIGINAL text, because the --draft scan below needs
    # `strip_quoted` to blank quoted regions — a probe with quotes already
    # removed would let a `-d` mentioned inside a PR title read as the flag.
    probe="$(printf '%s' "$norm" | tr -d '"'"'" | tr -s '[:space:]' ' ')"
    first="${probe%%[[:space:]]*}"
    case "$first" in
      gh|*/gh) ;;
      *) continue ;;
    esac
    rest="${probe#"$first"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    case "$rest" in
      pr\ create*|pr\ ready*) printf '%s' "$norm"; return 0 ;;
    esac
  done < <(printf '%s\n' "$CMD_JOINED" | tr ';&|(){}' '\n')
}
