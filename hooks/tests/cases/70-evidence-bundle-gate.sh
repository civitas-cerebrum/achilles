#!/bin/bash
# 70-evidence-bundle-gate.sh — no QA verdict without an evidence bundle for
# THIS ticket, and no sign-off while a captured artifact still holds a live
# credential.
#
# Two halves are pinned here and both matter equally:
#
#   1. The gate fires on the actions that constitute sign-off, and the binding
#      is PER TICKET — a bundle for one ticket must not unlock the next one.
#      That per-ticket binding is the whole point: the failure this hook exists
#      for is a second ticket in the same session riding on the first ticket's
#      work.
#   2. The gate stays silent everywhere else. A gate that fires on ordinary
#      tracker traffic gets disabled by the first person it annoys, which is the
#      same outcome as not having one — so every deny below ships with adjacent
#      ALLOW cases drawn from realistic traffic.
#
# Most of the sections below exist because adversarial review landed a bypass or
# a false-deny there. Each is labelled with what it is defending, so a future
# edit that "simplifies" one of these patterns finds out immediately.
#
# Fixture data is deliberately generic. Header names, ticket keys and token
# values here are invented; nothing in this file comes from any consumer's
# application.

H="$HOOK_DIR/evidence-bundle-gate.sh"

tracker() {
  local tool="$1" key="$2" val="$3" id="${4:-ABC-1}"
  "$JQ" -nc --arg t "$tool" --arg k "$key" --arg v "$val" --arg id "$id" \
    '{tool_name: $t, tool_input: {($k): $v, id: $id}}'
}

raw() { "$JQ" -nc "$1"; }

bash_cmd() {
  "$JQ" -nc --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}'
}

# A hook that never returns is a hook that is OFF — and it takes the tool call
# with it until the harness times it out. The runner sources case files into one
# shell, so a non-terminating hook HANGS the suite rather than failing it, which
# is the one failure mode a pass/fail assertion cannot report. This bounds the
# run at ~10s and calls a hang what it is.
assert_terminates() {
  local hook="$1" stdin="$2" name="$3" tmp n=0 p
  TESTS_RUN=$((TESTS_RUN + 1))
  tmp="$(mktemp)"
  printf '%s' "$stdin" > "$tmp.in"
  { bash "$hook" < "$tmp.in" > "$tmp" 2>/dev/null; } &
  p=$!
  while kill -0 "$p" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
  if kill -0 "$p" 2>/dev/null; then
    # Kill the `bash <hook>` grandchild BEFORE the subshell that owns it —
    # killing only the subshell leaves the spinning hook orphaned at 100% CPU
    # for the rest of the run, once per hung case.
    pkill -P "$p" 2>/dev/null || true
    kill -9 "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAIL_DETAILS+=("${name}: hook did not terminate within 10s")
    echo "${CLR_FAIL}  ✗${CLR_RST} ${name} ${CLR_DIM}(hook did not terminate)${CLR_RST}"
  else
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "${CLR_PASS}  ✓${CLR_RST} ${name}"
  fi
  rm -f "$tmp" "$tmp.in"
}

# Isolated workspace: a git repo with a real commit (so the branch name
# resolves) and a nested evidence directory, because bundles do not live at a
# fixed depth — projects put them under apps/<x>/tests/evidence as readily as
# tests/e2e/evidence.
EWS="$(mktemp -d)"
git init -q "$EWS" 2>/dev/null || true
git -C "$EWS" config user.email t@example.com 2>/dev/null || true
git -C "$EWS" config user.name t 2>/dev/null || true
mkdir -p "$EWS/apps/web/tests/evidence"
echo seed > "$EWS/README.md"
git -C "$EWS" add -A >/dev/null 2>&1 || true
git -C "$EWS" commit -qm seed >/dev/null 2>&1 || true
git -C "$EWS" checkout -q -b feat/widget-toggle 2>/dev/null || true
EVI="$EWS/apps/web/tests/evidence"
export WORKSPACE_ROOT="$EWS"
export ACHILLES_PROTOCOL=1

# A bundle that satisfies companion-mode's Phase 5 layout.
make_bundle() {
  local dir="$EVI/$1"
  mkdir -p "$dir/screenshots"
  echo "# Companion-mode evidence" > "$dir/summary.md"
  echo png > "$dir/screenshots/01-navigate.png"
  printf '%s\n' "$dir"
}

section "evidence-gate: sign-off with no bundle at all is denied"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "transition to Done, no bundle → DENY" "no evidence bundle"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Completed)" \
  "transition to Completed → DENY"
assert_deny "$H" "$(tracker mcp__atlassian__transitionJiraIssue transition Resolved)" \
  "Jira transition named Resolved → DENY"
assert_deny "$H" "$(bash_cmd 'gh pr create --title x --body y')" \
  "gh pr create, no bundle → DENY" "no evidence bundle"
assert_deny "$H" "$(bash_cmd 'gh pr ready 12')" \
  "gh pr ready, no bundle → DENY"

section "evidence-gate: the deny names the re-entry rule, not just the artifact"
# The artifact is the symptom. The message has to route the reader at the cause,
# because the reader's own inference ("the skill is already loaded") is what put
# them here.
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "deny message routes to a per-ticket re-run" "one ticket, one run of steps 1-9"

section "evidence-gate: verdict-shaped comments WARN, never block"
# A bundle-less verdict has one legitimate form — an unreachable app, reported
# as such. Blocking it would push an honest report into dishonesty.
assert_warn "$H" "$(tracker mcp__linear__save_comment body 'QA Test Report: AC-1 and AC-2 pass')" \
  "QA report comment → WARN" "no evidence bundle"
assert_warn "$H" "$(tracker mcp__linear__save_comment body 'Verdict: PASSED')" \
  "verdict comment → WARN"
assert_allow "$H" "$(tracker mcp__linear__save_comment body 'rebased onto main, retriggering CI')" \
  "ordinary comment → ALLOW"
assert_allow "$H" "$(tracker mcp__linear__save_comment body 'assigning this to the platform team')" \
  "handoff comment → ALLOW"

section "evidence-gate: running out of time is a verdict, not a silent pass"
# The hook is registered with a manifest timeout. If the harness kills it, it
# emits nothing — and nothing is an ALLOW, so the gate does not fail loudly, it
# evaporates. A byte cap cannot prevent that, because cost per MB swings ~2x
# with HAR shape and the cap is per file while the budget is per invocation.
# So the gate watches its own clock and stops on its own terms.
#
# Forcing the budget to 0 makes the deadline unreachable-by-construction, which
# is the only way to observe the exhausted path deterministically without
# fabricating a multi-second fixture.
B_TIME="$(make_bundle abc-1-timing-20260812-150715)"
printf '%s' '{"log":{"entries":[]}}' > "$B_TIME/network.har"
# NOT a subshell: assert_* increments the run/fail counters, and a subshell
# would discard them — the case would look green whatever it did.
export ACHILLES_EVIDENCE_GATE_BUDGET_S=0
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "budget exhausted → DENY naming the unscanned artifact" "NOT scanned"
unset ACHILLES_EVIDENCE_GATE_BUDGET_S
# ...and the control: the SAME bundle, the same artifact, a normal budget. If
# this allowed for any reason other than the scan completing, the case above
# would prove nothing.
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "the same bundle within budget → ALLOW (the deadline is not always-on)"
rm -rf "$B_TIME"

section "evidence-gate: only sign-off actions are gated"
assert_allow "$H" "$(tracker mcp__linear__save_issue state 'In Progress')" \
  "transition to In Progress → ALLOW"
assert_allow "$H" "$(tracker mcp__linear__save_issue state 'QA Testing')" \
  "transition to QA Testing → ALLOW"
assert_allow "$H" "$(tracker mcp__linear__get_issue id ABC-1)" \
  "tracker READ → ALLOW"
assert_allow "$H" "$(tracker mcp__slack__send_message text 'shipped')" \
  "unrelated MCP tool → ALLOW"
assert_allow "$H" "$(payload tool_name=Read file_path=/tmp/x)" \
  "Read → ALLOW"

section "evidence-gate: tracker transition shapes that are NOT {state: 'Done'}"
# Reading `.state` alone left the DENY branch effectively dead on Jira and on
# Linear's stateId form — the hook named tools it could not actually gate.
assert_deny "$H" "$(raw '{tool_name:"mcp__atlassian__editJiraIssue", tool_input:{issueIdOrKey:"ABC-2", fields:{status:{name:"Done"}}}}')" \
  "Jira fields.status.name = Done → DENY"
assert_deny "$H" "$(raw '{tool_name:"mcp__linear__save_issue", tool_input:{id:"ABC-2", stateId:"Done"}}')" \
  "Linear stateId = Done → DENY"
assert_deny "$H" "$(raw '{tool_name:"mcp__linear__save_issue", tool_input:{id:"ABC-2", state:{name:"Released"}}}')" \
  "state as an object → DENY"
assert_allow "$H" "$(raw '{tool_name:"mcp__atlassian__transitionJiraIssue", tool_input:{issueIdOrKey:"ABC-2", transition:{id:"31"}}}')" \
  "Jira numeric transition id → ALLOW (documented limit: not classifiable)"

section "evidence-gate: a closure that is not QA sign-off must not demand QA evidence"
for st in "Closed - Won't Do" "Closed - Duplicate" "Complete - superseded" "Cancelled" "Resolved - Invalid" "Closed (obsolete)"; do
  assert_allow "$H" "$(tracker mcp__linear__save_issue state "$st" ABC-2)" \
    "non-QA closure '$st' → ALLOW"
done

section "evidence-gate: Bash is only gated at the PR-publish boundary"
assert_allow "$H" "$(bash_cmd 'gh pr create --draft --title wip')" \
  "draft PR → ALLOW (sharing WIP is not a claim)"
assert_allow "$H" "$(bash_cmd 'gh pr view 12')" \
  "gh pr view → ALLOW"
assert_allow "$H" "$(bash_cmd 'gh pr list --state open')" \
  "gh pr list → ALLOW"
assert_allow "$H" "$(bash_cmd 'git commit -m "wip"')" \
  "ordinary git → ALLOW"
assert_allow "$H" "$(bash_cmd 'grep -rn "gh pr create" hooks/')" \
  "grepping for the trigger → ALLOW (a hook that fires on its own name gets disabled)"
assert_allow "$H" "$(bash_cmd 'echo gh pr create')" \
  "echoing the trigger → ALLOW"
# BACKTICKS: a code span in a PR body is not a command boundary.
# The splitter used to break on ` too, to catch the command-substitution form.
# It caught that — and also truncated the segment at the first backtick, so a
# REAL draft PR whose body contains a markdown code span lost its --draft to the
# split and was denied, with nothing in the message mentioning backticks. Same
# false-deny class as --draft=True, through a different door, and it blocks the
# very command the gate exempts on purpose. Substitution stays gated because
# normalise_segment peels a leading backtick instead — and the assignment arm
# had to learn about it in the same change (`OUT=`gh pr create`` has no space to
# peel to). The two edits are only correct as a pair, which is what these three
# cases pin.
assert_allow "$H" "$(bash_cmd 'gh pr create --body "supersedes `gh pr view`" --draft')" \
  "a draft PR whose body holds a code span keeps its exemption → ALLOW"
assert_allow "$H" "$(bash_cmd 'echo "see `gh pr create` docs"')" \
  "documenting the command inside a code span is not publishing → ALLOW"
assert_deny "$H" "$(bash_cmd 'OUT=`gh pr create --title x`')" \
  "assignment from command substitution still publishes → DENY" "no evidence bundle"
assert_allow "$H" "$(bash_cmd 'echo /opt/homebrew/bin/gh pr create')" \
  "echoing a PATH-qualified trigger → ALLOW"

section "evidence-gate: wrapper forms are how people actually script gh"
# Every one of these was an ALLOW before review. None is an evasion — they are
# ordinary scripting, and treating them as unreachable left the entry-B surface
# open by default.
for c in \
  'env gh pr create --fill' \
  'GH_TOKEN=x gh pr create --fill' \
  'command gh pr create --fill' \
  'time gh pr create --fill' \
  'nohup gh pr create --fill' \
  'eval "gh pr create --fill"' \
  'sh -c "gh pr create --fill"' \
  'bash -lc "gh pr create --fill"' \
  '/opt/homebrew/bin/gh pr create --fill' \
  './node_modules/.bin/gh pr create --fill' \
  '(gh pr create --fill)' \
  '{ gh pr create --fill; }' \
  'npm test && gh pr ready'
do
  assert_deny "$H" "$(bash_cmd "$c")" "wrapper form → DENY: $c"
done

section "evidence-gate: --draft detection is scoped to flags, not to the whole string"
# `-d` scanned context-free meant a PR whose TITLE mentioned a flag silently
# disabled the gate. No adversarial intent required.
assert_deny "$H" "$(bash_cmd 'gh pr create --title "add -d flag support" --body x')" \
  "-d inside a quoted title does NOT count as --draft"
assert_deny "$H" "$(bash_cmd 'gh pr create --fill --body "see -d option"')" \
  "-d inside a quoted body does NOT count as --draft"
assert_deny "$H" "$(bash_cmd 'gh pr create --fill # --draft')" \
  "--draft inside a comment does NOT count"
assert_allow "$H" "$(bash_cmd 'gh pr create -d --title wip')" \
  "a real -d flag still ALLOWs"

section "evidence-gate: a populated bundle for THIS ticket unlocks sign-off"
make_bundle "abc-1-widget-toggle-20260812-150715" >/dev/null
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "bundle present → ALLOW"
assert_allow "$H" "$(tracker mcp__linear__save_comment body 'QA Test Report: AC-1 pass')" \
  "bundle present → comment no longer warns"

section "evidence-gate: one ticket, one bundle — the second cannot ride on the first"
# This is the exact failure the hook exists for. ABC-1 was worked properly;
# ABC-2 was picked up in the same session and got an ad-hoc pass.
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done ABC-2)" \
  "second ticket in the same session → DENY" "no evidence bundle"
make_bundle "abc-2-second-thing-20260812-161500" >/dev/null
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done ABC-2)" \
  "second ticket, own bundle → ALLOW"

section "evidence-gate: bundle binding is anchored, not substring"
# The collision that actually happens in every tracker: ABC-1 and ABC-15 exist
# side by side and one must not sign off the other. A bundle stem is
# <key>-<slug>-<timestamp>, so the match is anchored at a separator — ABC-15's
# bundle is `abc-15-…`, and `abc-1` + separator does not reach it.
make_bundle "abc-15-other-thing-20260812-162000" >/dev/null
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done ABC-15)" \
  "exact key ALLOWs"
rm -rf "$EVI/abc-1-widget-toggle-20260812-150715"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done ABC-1)" \
  "ABC-15's bundle must NOT sign off ABC-1" "no evidence bundle"
make_bundle "abc-1-widget-toggle-20260812-150715" >/dev/null

section "evidence-gate: degenerate keys are rejected even when a matching dir exists"
# Both guards below used to pass vacuously — no directory of that name existed,
# so the tests proved nothing. Planting the directory is what makes them causal:
# delete the reject-list entry and these fail.
mkdir -p "$EVI/evidence/screenshots"
echo "# s" > "$EVI/evidence/summary.md"; echo png > "$EVI/evidence/screenshots/a.png"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done evidence)" \
  "skeleton key 'evidence' → DENY even with evidence/evidence/ populated"
make_bundle "head-run-20260812-170000" >/dev/null
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done head)" \
  "skeleton key 'head' → DENY even with head-* populated"
make_bundle "ab-short-key-20260812-171000" >/dev/null
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done ab)" \
  "key shorter than 3 chars → DENY even with ab-* populated"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done ---)" \
  "degenerate key → DENY"
assert_deny "$H" "$(raw '{tool_name:"mcp__linear__save_issue", tool_input:{state:"Done"}}')" \
  "payload with no ticket key → DENY (cannot verify whose evidence)" "no ticket key"

section "evidence-gate: a directory named right but empty is not evidence"
mkdir -p "$EVI/abc-3-empty-20260812-170000"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done ABC-3)" \
  "empty directory → DENY"
echo "# summary" > "$EVI/abc-3-empty-20260812-170000/summary.md"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done ABC-3)" \
  "summary.md with no captured artifact → DENY"
echo har > "$EVI/abc-3-empty-20260812-170000/network.har"
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done ABC-3)" \
  "summary.md + one artifact → ALLOW"

section "evidence-gate: the per-environment layout companion-mode mandates is recognised"
# companion-mode Phase 5 tells operators to give each environment its own
# subdirectory so the second run does not overwrite the first. A root-only
# check denied exactly that layout — the skill edit and the hook defeated each
# other in the shape the diff itself recommends.
SUB="$EVI/abc-6-multi-env-20260812-180000"
mkdir -p "$SUB/preview/screenshots" "$SUB/production/screenshots"
echo "# s" > "$SUB/summary.md"
echo png > "$SUB/preview/screenshots/01.png"
echo png > "$SUB/production/screenshots/01.png"
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done ABC-6)" \
  "artifacts only in per-environment subdirectories → ALLOW"
# Same layout, but the only artifacts are a recording and a HAR — no
# screenshots directory to fall back on. This is what makes the non-screenshot
# subdirectory globs causal rather than decorative.
SUB2="$EVI/abc-8-recorded-20260812-181000"
mkdir -p "$SUB2/preview"
echo "# s" > "$SUB2/summary.md"
echo webm > "$SUB2/preview/video.webm"
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done ABC-8)" \
  "only a per-environment video.webm → ALLOW"
printf '%s' '{"log":{"entries":[{"request":{"headers":[{"name":"authorization","value":"Bearer LIVEsubdirValue"}]}}]}}' > "$SUB/preview/network.har"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done ABC-6)" \
  "live credential in a per-environment subdirectory → DENY" "live credential"
rm -f "$SUB/preview/network.har"

section "evidence-gate: bundles foldered one level deeper are still found"
mkdir -p "$EVI/2026-08/abc-7-dated-20260812/screenshots"
echo "# s" > "$EVI/2026-08/abc-7-dated-20260812/summary.md"
echo png > "$EVI/2026-08/abc-7-dated-20260812/screenshots/01.png"
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done ABC-7)" \
  "date-foldered bundle → ALLOW"

section "evidence-gate: entry B binds to the branch when there is no ticket"
assert_deny "$H" "$(bash_cmd 'gh pr create --fill')" \
  "no branch bundle → DENY"
# Saying "this ticket" to a run that has no ticket sends the reader looking for
# a key that does not exist. The message has to name where the key came from.
assert_deny "$H" "$(bash_cmd 'gh pr create --fill')" \
  "the deny says the key is the BRANCH, not a ticket" "binds the bundle to the BRANCH"
assert_deny "$H" "$(bash_cmd 'gh pr create --fill')" \
  "the deny names the branch it looked for" "feat-widget-toggle"
make_bundle "feat-widget-toggle-20260812-180000" >/dev/null
assert_allow "$H" "$(bash_cmd 'gh pr create --fill')" \
  "branch-named bundle → ALLOW"

section "evidence-gate: UUID ids resolve via the bundle's own summary"
# Linear's save_issue commonly carries a UUID in .id. Matching directory names
# alone made every such payload a permanent DENY with the right bundle on disk.
UUID="9f8e7d6c-1234-4abc-9def-0123456789ab"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done "$UUID")" \
  "UUID with no bundle naming it → DENY"
echo "$UUID" >> "$EVI/abc-7-dated-20260812/summary.md" 2>/dev/null || \
  echo "$UUID" >> "$EVI/2026-08/abc-7-dated-20260812/summary.md"
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done "$UUID")" \
  "UUID named in a bundle's summary.md → ALLOW"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done '00000000-0000-4000-8000-000000000000')" \
  "an unrelated UUID → DENY (the cross-ticket hole stays closed)"
assert_allow "$H" "$(raw '{tool_name:"mcp__linear__save_issue", tool_input:{id:"11111111-2222-4333-8444-555555555555", identifier:"ABC-2", state:"Done"}}')" \
  ".identifier is preferred over a UUID .id → ALLOW"

section "evidence-gate: ACHILLES_EVIDENCE_DIR reaches bundles outside the repo"
OUTSIDE="$(mktemp -d)"
mkdir -p "$OUTSIDE/abc-9-elsewhere-20260812-190000/screenshots"
echo "# s" > "$OUTSIDE/abc-9-elsewhere-20260812-190000/summary.md"
echo png > "$OUTSIDE/abc-9-elsewhere-20260812-190000/screenshots/01.png"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done ABC-9)" \
  "bundle outside the repo, override unset → DENY"
export ACHILLES_EVIDENCE_DIR="$OUTSIDE"
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done ABC-9)" \
  "override set → ALLOW"
unset ACHILLES_EVIDENCE_DIR

section "evidence-gate: a live credential in a captured HAR blocks sign-off"
BUN="$EVI/abc-1-widget-toggle-20260812-150715"
HARB="$BUN/network.har"
# Minified, single-line HAR carrying one REDACTED header beside one live one.
# The line-oriented form of this check is defeated exactly here: a single
# placeholder anywhere on the line launders every live value next to it.
printf '%s' '{"log":{"entries":[{"request":{"headers":[{"name":"authorization","value":"REDACTED"},{"name":"x-deployment-protection-bypass","value":"aB3xQ9zzLiveValue"}]}}]}}' > "$HARB"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "unredacted bypass header in HAR → DENY" "live credential"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "deny names the field, not the value" "x-deployment-protection-bypass"

# The gate must never print what it found. A gate that echoes the credential it
# caught has published it into the transcript.
TESTS_RUN=$((TESTS_RUN + 1))
run_hook "$H" "$(tracker mcp__linear__save_issue state Done)"
if echo "$HOOK_OUT" | grep -q 'aB3xQ9zzLiveValue'; then
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAIL_DETAILS+=("secret value must never appear in the deny message")
  echo "  ✗ deny message leaks the secret value"
else
  TESTS_PASSED=$((TESTS_PASSED + 1))
  echo "  ✓ deny message withholds the secret value"
fi

section "evidence-gate: secrets DENY on the comment surface too"
# Unlike a missing bundle, an unredacted credential has no legitimate outcome —
# and a verdict comment is usually where the bundle's path gets published.
assert_deny "$H" "$(tracker mcp__linear__save_comment body 'Verdict: PASSED')" \
  "live credential + verdict comment → DENY (not WARN)" "live credential"

section "evidence-gate: credential-bearing field names beyond Authorization"
# `token` was absent from the vocabulary while companion-mode's text claimed the
# hook enforced `*-token`. Each of these carries a live value.
for hdr in x-auth-token x-csrf-token x-amz-security-token x-edge-jwt x-authorization x-api-key; do
  printf '{"log":{"entries":[{"request":{"headers":[{"name":"%s","value":"LIVEvalue12345"}]}}]}}' "$hdr" > "$HARB"
  assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
    "header $hdr with a live value → DENY"
done
printf '%s' '{"log":{"entries":[{"request":{"cookies":[{"name":"app_jwt","value":"eyJhbGciLIVE"}]}}]}}' > "$HARB"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "cookie named *_jwt with a live value → DENY"
printf '%s' '{"log":{"entries":[{"request":{"queryString":[{"name":"access_token","value":"LIVEqueryValue"}]}}]}}' > "$HARB"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "query-string access_token → DENY"
printf '%s' '{"log":{"entries":[{"request":{"headers":{"authorization":"Bearer LIVEmapValue"}}}]}}' > "$HARB"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "headers written as an object map → DENY"
printf '%s' '{"log":{"entries":[{"response":{"content":{"text":"{\"access_token\":\"eyJhbGciLIVE1234\"}"}}}]}}' > "$HARB"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "access_token in a response body → DENY (the deny message tells you to drop bodies)"

section "evidence-gate: names that merely LOOK secret-ish must not deny"
# There is nothing to redact in these, so a deny has no remedy but disabling the
# hook — which is the same outcome as not having one.
printf '%s' '{"log":{"entries":[{"request":{"headers":[{"name":"x-session-id","value":"anon-abc123"},{"name":"accept-language","value":"en-GB"},{"name":"user-agent","value":"Mozilla/5.0"},{"name":"content-type","value":"application/json"}],"cookies":[{"name":"sessionCartId","value":"cart-7"}]}}]}}' > "$HARB"
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "session/cart identifiers and ordinary headers → ALLOW"
printf '%s' '{"log":{"entries":[{"request":{"headers":[{"name":"authorization","value":"REDACTED"},{"name":"x-deployment-protection-bypass","value":"[REDACTED]"},{"name":"accept","value":"*/*"}]}}]}}' > "$HARB"
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "every credential-bearing field redacted → ALLOW"
assert_allow "$H" "$(tracker mcp__linear__save_comment body 'Verdict: PASSED')" \
  "redacted bundle → verdict comment ALLOW"

section "evidence-gate: a truncated HAR is not silently clean — but is not paranoid either"
printf '%s' '{"log":{"entries":[{"request":{"headers":[{"name":"authorization","value":"tr' > "$HARB"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "unparseable HAR with credential-bearing field names → DENY" "unparseable"
printf '%s' '{"log":{"entries":[{"request":{"headers":[{"name":"accept-lang' > "$HARB"
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "unparseable HAR with no credential-bearing names → ALLOW"
rm -f "$HARB"

section "evidence-gate: console.log is scanned per occurrence, not per line"
CLOG="$BUN/console.log"
printf 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload\n' > "$CLOG"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "bearer token in console.log → DENY" "console.log"
printf 'authorization: Token ghp_LIVEtokenvalue\n' > "$CLOG"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "the Token scheme is a credential too → DENY"
printf 'password=LIVEpassword1\n' > "$CLOG"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "password assignment → DENY"
# The same laundering the structural HAR walk exists to prevent: a redacted
# value earlier on the line must not vouch for a live one after it.
printf '[{"authorization":"Bearer [REDACTED]"},{"api_key":"LIVEVALUE1"}]\n' > "$CLOG"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "a placeholder earlier on the line does NOT launder a live value after it → DENY"

section "evidence-gate: application console output is not a credential"
printf 'Authorization: Bearer [REDACTED]\n[log] rendered 12 rows\n' > "$CLOG"
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "redacted console.log → ALLOW"
printf '[log] hydration complete\n[warn] slow image decode 412ms\n' > "$CLOG"
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "ordinary console output → ALLOW"
printf '[error] request failed: api_key= is required\n' > "$CLOG"
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "an app error naming a missing key → ALLOW (nothing to redact)"
printf '[log] endpoint expects authorization: bearer <token>\n' > "$CLOG"
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "documentation-shaped placeholder → ALLOW"
printf 'Authorization: Bearer\n' > "$CLOG"
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "a scheme with no value → ALLOW (nothing leaked)"
rm -f "$CLOG"

section "evidence-gate: an '=' inside a gh flag must not peel the gh away"
# `--base=main --fill` is the form in gh's own documentation. The wrapper-prefix
# peel was first written with the glob `[A-Za-z_]*=*\ *`, which does NOT mean
# "starts with a VAR=val assignment" — it means "contains `=` with a space
# somewhere after it", so it matched the gh command itself and peeled `gh` away
# word by word. Every one of these silently disabled the gate, on ordinary
# interactive use rather than on an opt-in scripting form.
#
# Both directions are pinned deliberately: the branch bundle is parked so these
# must DENY, then restored so the SAME commands must ALLOW. A gate that is
# simply off passes only half of this section.
# Park / restore the entry-B branch bundle so the same command can be asserted
# in both directions. A dot-prefixed name is invisible to the hook's `*/` globs.
park_branch_bundle()    { mv "$EVI/feat-widget-toggle-20260812-180000" "$EVI/.parked-branch-bundle"; }
restore_branch_bundle() { mv "$EVI/.parked-branch-bundle" "$EVI/feat-widget-toggle-20260812-180000"; }

park_branch_bundle
EQ_FORMS=(
  'gh pr create --base=main --fill'
  'gh pr create --title=x --body=y'
  'gh pr create --base=main --title x'
  'gh pr ready --repo=owner/name 12'
  '\gh pr create --fill'
  'GH_HOST=github.com gh pr create --base=main --fill'
)
for c in "${EQ_FORMS[@]}"; do
  assert_deny "$H" "$(bash_cmd "$c")" "no branch bundle → DENY: $c" "no evidence bundle"
done
restore_branch_bundle
for c in "${EQ_FORMS[@]}"; do
  assert_allow "$H" "$(bash_cmd "$c")" "branch bundle present → ALLOW: $c"
done

section "evidence-gate: quoting and whitespace do not hide the command"
# Every form below is valid shell that publishes a PR, and every one silently
# ALLOWed. The quote arm peeled the OPENING quote only, leaving the closing one
# glued to the token so the program name was `gh"` and matched nothing — a
# half-handled quote arm reads as though quoting is covered, which is worse than
# not peeling at all. The subcommand test was a literal one-space glob, so a tab,
# a double space or a line continuation between `pr` and `create` walked past it.
park_branch_bundle
HIDDEN_FORMS=(
  '"gh" pr create --fill'
  "'gh' pr create --fill"
  'gh pr "create" --fill'
  "gh 'pr create' --fill"
  'gh pr	create --fill'
  'gh pr  create --fill'
  'OUT=`gh pr create --fill`'
  '/bin/sh -c "gh pr create --fill"'
  '/bin/bash -lc "gh pr create --fill"'
  'sudo gh pr create --fill'
  'npx gh pr create --fill'
)
for c in "${HIDDEN_FORMS[@]}"; do
  assert_deny "$H" "$(bash_cmd "$c")" "hidden form → DENY: $c" "no evidence bundle"
done
assert_deny "$H" "$(bash_cmd 'gh pr \
create --fill')" "backslash-newline continuation → DENY" "no evidence bundle"
restore_branch_bundle
for c in "${HIDDEN_FORMS[@]}"; do
  assert_allow "$H" "$(bash_cmd "$c")" "hidden form, bundle present → ALLOW: $c"
done
# The classification probe strips quotes; the --draft scan must NOT run on a
# probe, or a `-d` mentioned inside a PR title would read as the flag and
# disable the gate. Re-asserted here because these are the two changes that
# could defeat each other.
park_branch_bundle
assert_deny "$H" "$(bash_cmd 'gh pr create --title "add -d flag support" --body x')" \
  "quote-stripping the probe does NOT expose a quoted -d as the draft flag" "no evidence bundle"
restore_branch_bundle

section "evidence-gate: adjacent traffic that merely mentions the command"
assert_allow "$H" "$(bash_cmd 'echo gh pr create')" \
  "echoing the command → ALLOW"
assert_allow "$H" "$(bash_cmd 'sudo systemctl restart nginx')" \
  "sudo something else entirely → ALLOW"
assert_allow "$H" "$(bash_cmd 'npx playwright test')" \
  "npx something else entirely → ALLOW"
assert_allow "$H" "$(bash_cmd '/bin/bash -lc "npm run build"')" \
  "an absolute-path shell running something else → ALLOW"
assert_allow "$H" "$(raw '{tool_name:"Bash", tool_input:"ls"}')" \
  "tool_input is a string, not an object → ALLOW (a decision, not a set -e abort)"

section "evidence-gate: --draft follows pflag's truthy vocabulary, case and all"
# `strconv.ParseBool` accepts 1/t/T/TRUE/true/True. Denying --draft=True would
# reproduce the exact false-deny the = form was added to fix.
park_branch_bundle
for f in '--draft=True' '--draft=TRUE' '--draft=T' '-d=t'; do
  assert_allow "$H" "$(bash_cmd "gh pr create $f --fill")" \
    "pflag truthy '$f' → ALLOW"
done
assert_deny "$H" "$(bash_cmd 'gh pr create --draft=False --fill')" \
  "--draft=False is still not a draft → DENY" "no evidence bundle"
# An unquoted `#` mid-word is literal to the shell, so stripping it context-free
# ate the --draft that followed and denied a genuine draft PR.
assert_allow "$H" "$(bash_cmd 'gh pr create --title issue#5 --draft')" \
  "a # inside a word does not eat the --draft after it → ALLOW"
assert_deny "$H" "$(bash_cmd 'gh pr create --fill # --draft')" \
  "a # that STARTS a word is still a comment → DENY" "no evidence bundle"
restore_branch_bundle

section "evidence-gate: every peel arm consumes, so the hook always returns"
# The first fix for the section above stripped "up to the first space", which is
# a no-op on a segment that IS the assignment — `A=1` spun forever. A hook that
# never returns renders no decision at all, so the gate is off AND the tool call
# is stuck behind it. These bound the run rather than asserting a verdict: a
# reintroduction fails the suite instead of hanging it.
#
# Two independent defences make the hang unreachable — every peel arm consumes,
# and the loop is capped — so NEITHER is observable on its own; a mutation has
# to remove both before these assertions have anything to report. That is the
# point of a belt-and-braces pair, and it is stated here so a future reader does
# not delete one of them for looking dead. Note also that only `assert_terminates`
# is bounded: if both defences go, these report the hang and a later unbounded
# assertion then stalls the runner.
assert_terminates "$H" "$(bash_cmd 'A=1')" \
  "a bare assignment segment terminates"
assert_terminates "$H" "$(bash_cmd 'FOO=bar&&gh pr create --fill')" \
  "an assignment glued to && terminates"
assert_terminates "$H" "$(bash_cmd 'GH_TOKEN=x;gh pr ready 3')" \
  "an assignment glued to ; terminates"
assert_terminates "$H" "$(bash_cmd 'A=1 B=2 C=3 D=4 E=5')" \
  "a run of assignments terminates"
assert_terminates "$H" "$(bash_cmd '=')" \
  "a lone = terminates"
# Termination is necessary, not sufficient — the verdict still has to be right.
park_branch_bundle
assert_deny "$H" "$(bash_cmd 'A=1&&gh pr create --title x --body y')" \
  "assignment glued to && is still gated" "no evidence bundle"
restore_branch_bundle
assert_allow "$H" "$(bash_cmd 'A=1')" \
  "a bare assignment is not a PR publish → ALLOW"
# Only an identifier-shaped name is an assignment. `a-b=c` is a COMMAND name to
# a real shell (assignment names cannot contain `-`), so gh never runs and the
# gate must not reach past it.
park_branch_bundle
assert_allow "$H" "$(bash_cmd 'a-b=c gh pr create --fill')" \
  "a non-identifier name is not an assignment → ALLOW (gh never runs)"
restore_branch_bundle

section "evidence-gate: --draft is recognised in its = form, and only when true"
# The bundle is parked for the WHOLE section on purpose. With it present these
# would allow via the bundle rather than via the draft exemption, and deleting
# the `=` alternation from the flag scan would leave them green — the fix would
# have no causal cover at all. Parked, the only thing that can produce an ALLOW
# here is the exemption itself, and the `--fill` control proves it.
park_branch_bundle
assert_deny "$H" "$(bash_cmd 'gh pr create --fill')" \
  "control: same section, no draft flag → DENY" "no evidence bundle"
assert_allow "$H" "$(bash_cmd 'gh pr create --draft=true --fill')" \
  "--draft=true → ALLOW (pflag accepts the = form for booleans)"
assert_allow "$H" "$(bash_cmd 'gh pr create --draft=1 --fill')" \
  "--draft=1 → ALLOW"
assert_allow "$H" "$(bash_cmd 'gh pr create -d=true --fill')" \
  "-d=true → ALLOW (shorthand takes the = form too)"
assert_deny "$H" "$(bash_cmd 'gh pr create --draft=false --fill')" \
  "--draft=false is NOT a draft → DENY" "no evidence bundle"
assert_deny "$H" "$(bash_cmd 'gh pr create --draft=0 --fill')" \
  "--draft=0 is NOT a draft → DENY"
restore_branch_bundle

section "evidence-gate: the comment surface reads more than one body field"
# `addCommentToJiraIssue` is named in this hook's own matcher, and reading
# `.body` alone left BOTH of its branches dead on it — the same "names a tool it
# cannot actually gate" defect review caught on the transition surface, missed
# one surface over.
assert_warn "$H" "$(raw '{tool_name:"mcp__atlassian__addCommentToJiraIssue", tool_input:{issueIdOrKey:"ABC-404", commentBody:"QA Test Report: AC-1 and AC-2 pass"}}')" \
  "Jira commentBody verdict, no bundle → WARN" "no evidence bundle"
assert_allow "$H" "$(raw '{tool_name:"mcp__atlassian__addCommentToJiraIssue", tool_input:{issueIdOrKey:"ABC-404", commentBody:"rebased onto main, retriggering CI"}}')" \
  "Jira commentBody ordinary → ALLOW"
assert_warn "$H" "$(raw '{tool_name:"mcp__linear__save_comment", tool_input:{id:"ABC-404", comment:"QA Test Report: AC-1 and AC-2 pass"}}')" \
  ".comment carries the verdict → WARN" "no evidence bundle"
assert_warn "$H" "$(raw '{tool_name:"mcp__github__create_comment", tool_input:{id:"ABC-404", text:"Verdict: PASSED"}}')" \
  ".text carries the verdict → WARN" "no evidence bundle"
# The body must be judged on its TEXT, not on its field names. An ADF document
# stringifies to JSON containing the word "content" and every key the tracker
# put there — so a structured body whose visible text IS a verdict must still
# not be classified from the wrapper. The verdict vocabulary is inside the text
# nodes here on purpose: stringifying the object makes this WARN.
assert_allow "$H" "$(raw '{tool_name:"mcp__atlassian__addCommentToJiraIssue", tool_input:{issueIdOrKey:"ABC-404", commentBody:{type:"doc", version:1, content:[{type:"paragraph", content:[{type:"text", text:"QA Test Report: AC-1 and AC-2 pass, verdict PASSED"}]}]}}}')" \
  "Jira ADF document body → ALLOW (a non-string body is not stringified)"
assert_allow "$H" "$(raw '{tool_name:"mcp__atlassian__addCommentToJiraIssue", tool_input:{issueIdOrKey:"ABC-1", commentBody:"QA Test Report: AC-1 pass"}}')" \
  "Jira commentBody verdict WITH a bundle → ALLOW"
# The secret branch was dead on this tool too, not just the WARN branch.
printf '%s' '{"log":{"entries":[{"request":{"headers":[{"name":"authorization","value":"Bearer LIVEjiraSurfaceValue"}]}}]}}' > "$HARB"
assert_deny "$H" "$(raw '{tool_name:"mcp__atlassian__addCommentToJiraIssue", tool_input:{issueIdOrKey:"ABC-1", commentBody:"QA Test Report: AC-1 pass"}}')" \
  "live credential + Jira commentBody verdict → DENY (not WARN)" "live credential"
rm -f "$HARB"

section "evidence-gate: one header can hold many credentials"
# A cookie / set-cookie value is a `;`-separated list of pairs. Judging the whole
# string against the placeholder vocabulary let ONE redacted pair vouch for every
# live pair beside it — the same laundering the structural walk exists to prevent,
# one level further in. Partial redaction is precisely the state this branch is for.
printf '%s' '{"log":{"entries":[{"request":{"headers":[{"name":"cookie","value":"consent=REDACTED; auth_token=LIVEcookieValue"}]}}]}}' > "$HARB"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "a redacted pair does NOT launder a live pair in the same header → DENY" "live credential"
printf '%s' '{"log":{"entries":[{"request":{"headers":[{"name":"set-cookie","value":"_ga=GA1.2.9; sid=REDACTED; session_token=eyJhbGciLIVE"}]}}]}}' > "$HARB"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "set-cookie with one live pair among redacted ones → DENY"
printf '%s' '{"log":{"entries":[{"request":{"headers":[{"name":"cookie","value":"consent=REDACTED; auth_token=[REDACTED]"}]}}]}}' > "$HARB"
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "every credential-bearing pair in the header redacted → ALLOW"
# The pair scan is scoped by the SAME name vocabulary as the field scan, and that
# scoping is what keeps it from becoming "any pair with a value". Drop the key
# test and this denies: `consent` has nothing to redact, so a deny here has no
# remedy but disabling the hook.
printf '%s' '{"log":{"entries":[{"request":{"headers":[{"name":"cookie","value":"consent=yes; auth_token=[REDACTED]"}]}}]}}' > "$HARB"
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "a live NON-credential pair beside a redacted credential → ALLOW (pair keys are vocabulary-scoped)"
printf '%s' '{"log":{"entries":[{"request":{"headers":[{"name":"set-cookie","value":"_ga=GA1.2.9; locale=en-GB; sid=[REDACTED]"}]}}]}}' > "$HARB"
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "analytics and locale pairs are not credentials → ALLOW"
# NEAR-MISS shapes, not far-side ones. The cases above prove an unrelated
# vocabulary (`consent`, `_ga`, `locale`) is allowed; these two pin the WORD
# BOUNDARIES around the vocabulary, which is where a name matcher actually goes
# wrong. PAIR_RE wraps its keyword in `([A-Za-z0-9_.-]*[-_])?` and
# `([-_][A-Za-z0-9_.-]*)?` to mirror NAME_RE's `(^|[-_])keyword([-_]|$)`, so the
# pair vocabulary and the field vocabulary cannot drift apart. Nothing asserted
# that mirroring: relaxing either affix to optional-anything left the gate
# denying these two live-but-innocent pairs, and both mutants survived the suite.
# Both are false-positive direction, which is the expensive kind — a DENY here
# has no remedy, because there is nothing to redact.
printf '%s' '{"log":{"entries":[{"request":{"headers":[{"name":"cookie","value":"mytoken=abc123def; auth=[REDACTED]"}]}}]}}' > "$HARB"
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "a keyword behind a non-separator PREFIX is a different word (mytoken) → ALLOW"
printf '%s' '{"log":{"entries":[{"request":{"headers":[{"name":"cookie","value":"tokenizer=xyz12345; auth=[REDACTED]"}]}}]}}' > "$HARB"
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "a keyword before a non-separator SUFFIX is a different word (tokenizer) → ALLOW"
# A raw `cookie` header string is opaque: the gate cannot see which pair is the
# session credential, so an entirely unredacted one is a finding on its own via
# the whole-value test. This is deliberately ASYMMETRIC with the structured
# `cookies:[{name,value}]` form above, where each cookie names itself and
# `sessionCartId` is judged — and allowed — on its own name. Same identifier,
# two shapes, two answers, on purpose: opacity is what forces the conservative
# call, and the remedy (redact the header) costs seconds.
printf '%s' '{"log":{"entries":[{"request":{"headers":[{"name":"cookie","value":"_ga=GA1.2.9; sessionCartId=cart-7; consent=yes"}]}}]}}' > "$HARB"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "a wholly unredacted cookie header is a finding (opaque string, whole-value test)"
# A pair-level finding that names only the header is undiagnosable: the operator
# who has already redacted `authorization` inside the cookie opens it, sees the
# placeholder, and concludes the gate is broken — while the remedy text points
# at the field they just fixed. A finding nobody can act on is how a gate gets
# turned off, so the pair has to be named.
printf '%s' '{"log":{"entries":[{"request":{"headers":[{"name":"cookie","value":"authorization=REDACTED; app_token=LIVEvalue123"}]}}]}}' > "$HARB"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "the finding names the offending PAIR, not just the header" 'pair `app_token`'
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "the finding still names the header too" 'field `cookie`'
rm -f "$HARB"

section "evidence-gate: a HAR too large to scan in budget is a finding, not a pass"
# The cap is derived from the hook's registered 10s PreToolUse budget and the
# measured scan cost. Set it above that and it is unreachable: the harness kills
# the hook, the hook emits nothing, and nothing is an ALLOW — so the very
# largest HARs, which are by construction the ones that still carry response
# bodies, would be exactly the ones that sail through. Sparse files: `wc -c`
# stats rather than reads, so this costs nothing.
dd if=/dev/zero of="$HARB" bs=1 count=0 seek=$((33 * 1024 * 1024)) 2>/dev/null
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "a HAR above the scan budget → DENY" "too large to verify"
dd if=/dev/zero of="$HARB" bs=1 count=0 seek=$((1024 * 1024)) 2>/dev/null
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "a HAR below the cap with no credential names → ALLOW"
rm -f "$HARB"

section "evidence-gate: a console log in a per-environment subdirectory is scanned"
# The subdirectory globs on the console scan were decorative — every console
# case landed at the bundle root, so deleting them changed nothing.
mkdir -p "$BUN/preview"
CSUB="$BUN/preview/console.log"
printf 'x-deployment-protection-bypass: aB3xQ9zzSubdirValue\n' > "$CSUB"
assert_deny "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "live credential in preview/console.log → DENY" "preview/console.log"
printf 'x-deployment-protection-bypass: [REDACTED]\n' > "$CSUB"
assert_allow "$H" "$(tracker mcp__linear__save_issue state Done)" \
  "redacted preview/console.log → ALLOW"
rm -rf "$BUN/preview"

section "evidence-gate: the escape hatch is honoured"
CIVITAS_DISABLE_EVIDENCE_GATE=1 assert_allow "$H" "$(tracker mcp__linear__save_issue state Done ABC-404)" \
  "disabled by env → ALLOW"

# Do not leak this file's workspace into later case files.
unset WORKSPACE_ROOT ACHILLES_PROTOCOL
