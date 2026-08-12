#!/bin/bash
# Tests for playwright-artifact-archiver.sh — PostToolUse:Bash + Stop/SubagentStop
# hook that copies each Playwright run's evidence into
# <project>/.achilles/runs/<runId>/ before the next run wipes outputDir.
#
# Behaviour under test:
#   - archives on a normal run; discovers outputDir / html outputFolder /
#     PLAYWRIGHT_JSON_OUTPUT_NAME / --output rather than assuming defaults
#   - a SECOND run cannot destroy the first run's archived evidence
#     (the regression the hook exists to prevent)
#   - retention prunes oldest-first and says so; size ceiling drops only
#     traces/videos and says so
#   - never deletes anything the consumer owns
#   - never fails the run: no deny under any input, exit 0 even when the
#     archive write itself is impossible
#   - idempotent: an unchanged candidate set is a no-op, so the Stop
#     backstop does not duplicate what PostToolUse already archived
H="$HOOK_DIR/playwright-artifact-archiver.sh"

# --- scaffolding -----------------------------------------------------------
# pa_project <dir> [outputDir] [reportDir] — a project with a playwright
# config and one failing test's worth of artifacts. Deliberately NON-default
# directory names so a hook that hardcodes `test-results/` fails these tests.
pa_project() {
  local d="$1" out="${2:-pw-artifacts}" rep="${3:-pw-html}"
  mkdir -p "$d/$out/spec-failing-test" "$d/$rep/data"
  cat > "$d/playwright.config.ts" <<EOF
import { defineConfig } from '@playwright/test';
export default defineConfig({
  outputDir: './$out',
  reporter: [['html', { outputFolder: './$rep' }]],
});
EOF
  printf 'run-marker-%s\n' "$(date +%s%N)" > "$d/$out/spec-failing-test/trace.zip"
  printf '# Error context\n\n- page snapshot\n' > "$d/$out/spec-failing-test/error-context.md"
  printf 'PNGDATA' > "$d/$out/spec-failing-test/test-failed-1.png"
  printf 'WEBMDATA' > "$d/$out/spec-failing-test/video.webm"
  printf '{"stats":{"expected":0,"unexpected":1}}' > "$d/$rep/results.json"
}

# pa_rerun <dir> <marker> [outputDir] — what Playwright does at the START of a
# run: wipe outputDir, then write fresh artifacts into the SAME per-test path.
# <marker> must differ per rerun; BSD date has no %N, so the caller supplies it.
pa_rerun() {
  local d="$1" marker="$2" out="${3:-pw-artifacts}"
  rm -rf "$d/$out"
  mkdir -p "$d/$out/spec-failing-test"
  printf 'run-marker-%s\n' "$marker" > "$d/$out/spec-failing-test/trace.zip"
  printf '# Error context\n\n- %s\n' "$marker" > "$d/$out/spec-failing-test/error-context.md"
}

pa_payload() { # pa_payload <dir> [command]
  payload hook_event_name=PostToolUse tool_name=Bash cwd="$1" \
          command="${2:-npx playwright test}"
}

pa_fire() { # pa_fire <dir> [command] — run the hook, capture stdout in PA_OUT
  PA_OUT=$(printf '%s' "$(pa_payload "$1" "${2:-npx playwright test}")" | bash "$H" 2>/dev/null)
}

pa_runs() { find "$1/.achilles/runs" -maxdepth 1 -mindepth 1 -type d ! -name latest 2>/dev/null | wc -l | tr -d ' '; }
pa_newest() { find "$1/.achilles/runs" -maxdepth 1 -mindepth 1 -type d ! -name latest 2>/dev/null | sort | tail -1; }
pa_oldest() { find "$1/.achilles/runs" -maxdepth 1 -mindepth 1 -type d ! -name latest 2>/dev/null | sort | head -1; }

PA_TMPS=()
pa_mktemp() { local t; t=$(mktemp -d /tmp/pw-archiver-XXXXXX); PA_TMPS+=("$t"); printf '%s' "$t"; }

# ---------------------------------------------------------------------------
section "playwright-artifact-archiver: archives a normal run"
PA_A=$(pa_mktemp); pa_project "$PA_A"
pa_fire "$PA_A"
PA_RUN1=$(pa_newest "$PA_A")

assert_eq "$(pa_runs "$PA_A")" "1" "one run directory created"
assert_eq "$([ -f "$PA_RUN1/artifacts/pw-artifacts/spec-failing-test/trace.zip" ] && echo yes)" "yes" "trace.zip archived"
assert_eq "$([ -f "$PA_RUN1/artifacts/pw-artifacts/spec-failing-test/error-context.md" ] && echo yes)" "yes" "error-context.md archived"
assert_eq "$([ -f "$PA_RUN1/artifacts/pw-artifacts/spec-failing-test/video.webm" ] && echo yes)" "yes" "video archived"
assert_eq "$([ -f "$PA_RUN1/artifacts/pw-artifacts/spec-failing-test/test-failed-1.png" ] && echo yes)" "yes" "screenshot archived"
assert_eq "$([ -f "$PA_RUN1/artifacts/pw-html/results.json" ] && echo yes)" "yes" "report JSON archived"
assert_eq "$("$JQ" -r '.schema' "$PA_RUN1/manifest.json")" "playwright-run-archive/v1" "manifest schema stamped"
assert_eq "$("$JQ" -r '.mode' "$PA_RUN1/manifest.json")" "full" "full mode under the default ceiling"
assert_eq "$("$JQ" -r '.counts.errorContexts' "$PA_RUN1/manifest.json")" "1" "manifest counts error-context files"
assert_eq "$("$JQ" -r '[.sources[] | select(.kind=="outputDir")] | .[0].path' "$PA_RUN1/manifest.json")" "pw-artifacts" "outputDir discovered from config, not assumed"
assert_eq "$("$JQ" -r '[.sources[] | select(.kind=="outputDir")] | .[0].resolvedFrom' "$PA_RUN1/manifest.json")" "config:playwright.config.ts:outputDir" "manifest records where the path came from"
assert_eq "$("$JQ" -r '[.sources[] | select(.kind=="htmlReport")] | .[0].path' "$PA_RUN1/manifest.json")" "pw-html" "html outputFolder discovered from config"
assert_eq "$(readlink "$PA_A/.achilles/runs/latest")" "$(basename "$PA_RUN1")" "latest symlink points at the new run"
assert_eq "$PA_OUT" "" "silent on a clean archive (nothing discarded)"

# ---------------------------------------------------------------------------
section "playwright-artifact-archiver: a second run cannot destroy the first run's evidence"
# This is the regression the hook exists for. Without it, run 2's wipe of
# outputDir leaves run 1's trace/error-context unrecoverable.
PA_R1_TRACE=$(cat "$PA_RUN1/artifacts/pw-artifacts/spec-failing-test/trace.zip")
pa_rerun "$PA_A" SECOND-RUN
assert_eq "$(grep -cF "$PA_R1_TRACE" "$PA_A/pw-artifacts/spec-failing-test/trace.zip")" "0" "live outputDir: run 2 overwrote run 1's trace (the hazard is real)"
pa_fire "$PA_A"
assert_eq "$(cat "$PA_RUN1/artifacts/pw-artifacts/spec-failing-test/trace.zip")" "$PA_R1_TRACE" "run 1's archived trace is byte-identical after run 2"
assert_eq "$(grep -c 'SECOND-RUN' "$PA_RUN1/artifacts/pw-artifacts/spec-failing-test/error-context.md")" "0" "run 1's archived error-context was not overwritten by run 2"
assert_eq "$(pa_runs "$PA_A")" "2" "run 2 archived alongside run 1, not over it"
assert_eq "$(grep -c 'SECOND-RUN' "$(pa_newest "$PA_A")/artifacts/pw-artifacts/spec-failing-test/error-context.md")" "1" "run 2's own evidence is in the newer archive"

# ---------------------------------------------------------------------------
section "playwright-artifact-archiver: idempotent — unchanged artifacts are a no-op"
PA_BEFORE=$(pa_runs "$PA_A")
pa_fire "$PA_A"
assert_eq "$(pa_runs "$PA_A")" "$PA_BEFORE" "re-firing with no new run archives nothing"
PA_OUT=$(printf '%s' "$(payload hook_event_name=Stop cwd="$PA_A")" | bash "$H" 2>/dev/null)
assert_eq "$(pa_runs "$PA_A")" "$PA_BEFORE" "Stop backstop does not duplicate an already-archived run"
assert_eq "$PA_OUT" "" "Stop backstop silent when there is nothing new"

# ---------------------------------------------------------------------------
section "playwright-artifact-archiver: Stop backstop catches an interrupted run"
# A killed run never fires PostToolUse, but its partial evidence is still
# evidence. Only the Stop/SubagentStop backstop can recover it.
PA_INT=$(pa_mktemp); pa_project "$PA_INT"
assert_eq "$(pa_runs "$PA_INT")" "0" "nothing archived before the backstop fires"
printf '%s' "$(payload hook_event_name=Stop cwd="$PA_INT")" | bash "$H" >/dev/null 2>&1
assert_eq "$(pa_runs "$PA_INT")" "1" "Stop archives an interrupted run with no PostToolUse"
assert_eq "$("$JQ" -r '.trigger' "$(pa_newest "$PA_INT")/manifest.json")" "Stop" "manifest records the interrupted-run trigger"
PA_SUB=$(pa_mktemp); pa_project "$PA_SUB"
printf '%s' "$(payload hook_event_name=SubagentStop cwd="$PA_SUB")" | bash "$H" >/dev/null 2>&1
assert_eq "$(pa_runs "$PA_SUB")" "1" "SubagentStop archives a subagent's interrupted run"

# ---------------------------------------------------------------------------
section "playwright-artifact-archiver: retention prunes oldest-first and says so"
PA_RET=$(pa_mktemp); pa_project "$PA_RET"
# Markers of DIFFERING LENGTH: the idempotency fingerprint is (count, bytes,
# digest of size+mtime+path), so a rerun must actually differ in size or mtime
# — as a real rerun does — to count as a new run.
for m in r1 rerun-22 rerun-longer-333; do
  pa_rerun "$PA_RET" "$m"
  ACHILLES_ARTIFACT_RETAIN=2 pa_fire "$PA_RET"
  PA_RET_OUT="$PA_OUT"
done
assert_eq "$(pa_runs "$PA_RET")" "2" "retention window honoured (ACHILLES_ARTIFACT_RETAIN=2)"
assert_eq "$(printf '%s' "$PA_RET_OUT" | "$JQ" -r '.systemMessage' 2>/dev/null | grep -c 'Pruned')" "1" "pruning is announced, never silent"
assert_eq "$(printf '%s' "$PA_RET_OUT" | "$JQ" -r '.systemMessage' 2>/dev/null | grep -c 'ACHILLES_ARTIFACT_RETAIN')" "1" "the warning names the knob to raise"
assert_eq "$("$JQ" -r '.retention.pruned | length' "$(pa_newest "$PA_RET")/manifest.json")" "1" "manifest records which run was pruned"
assert_eq "$([ -d "$PA_RET/pw-artifacts" ] && echo yes)" "yes" "pruning never touches the consumer's outputDir"

# ---------------------------------------------------------------------------
section "playwright-artifact-archiver: pruning only ever removes its own run dirs"
PA_KEEP=$(pa_mktemp); pa_project "$PA_KEEP"
mkdir -p "$PA_KEEP/.achilles/runs/my-notes"
printf 'operator notes\n' > "$PA_KEEP/.achilles/runs/my-notes/README.md"
printf 'top-level file\n' > "$PA_KEEP/.achilles/runs/keepme.txt"
for m in r1 rerun-22 rerun-longer-333; do pa_rerun "$PA_KEEP" "$m"; ACHILLES_ARTIFACT_RETAIN=1 pa_fire "$PA_KEEP"; done
assert_eq "$([ -f "$PA_KEEP/.achilles/runs/my-notes/README.md" ] && echo yes)" "yes" "a non-runId directory under runs/ is never pruned"
assert_eq "$([ -f "$PA_KEEP/.achilles/runs/keepme.txt" ] && echo yes)" "yes" "a stray file under runs/ is never pruned"

# ---------------------------------------------------------------------------
section "playwright-artifact-archiver: size ceiling drops blobs only, and says so"
PA_CAP=$(pa_mktemp); pa_project "$PA_CAP"
ACHILLES_ARTIFACT_MAX_MB=0 pa_fire "$PA_CAP"
PA_CAP_RUN=$(pa_newest "$PA_CAP")
assert_eq "$("$JQ" -r '.mode' "$PA_CAP_RUN/manifest.json")" "reduced" "over the ceiling → reduced mode"
assert_eq "$([ -f "$PA_CAP_RUN/artifacts/pw-artifacts/spec-failing-test/error-context.md" ] && echo yes)" "yes" "reduced mode still keeps error-context.md"
assert_eq "$([ -f "$PA_CAP_RUN/artifacts/pw-artifacts/spec-failing-test/test-failed-1.png" ] && echo yes)" "yes" "reduced mode still keeps screenshots"
assert_eq "$([ -f "$PA_CAP_RUN/artifacts/pw-html/results.json" ] && echo yes)" "yes" "reduced mode still keeps the report JSON"
assert_eq "$([ -f "$PA_CAP_RUN/artifacts/pw-artifacts/spec-failing-test/trace.zip" ] && echo yes)" "" "reduced mode skips the trace blob"
assert_eq "$([ -f "$PA_CAP_RUN/artifacts/pw-artifacts/spec-failing-test/video.webm" ] && echo yes)" "" "reduced mode skips the video blob"
assert_eq "$("$JQ" -r '[.skipped[].path] | map(select(endswith("trace.zip"))) | length' "$PA_CAP_RUN/manifest.json")" "1" "manifest names the skipped trace"
assert_eq "$(printf '%s' "$PA_OUT" | "$JQ" -r '.systemMessage' 2>/dev/null | grep -c 'Skipped')" "1" "size-ceiling skips are announced, never silent"
assert_eq "$([ -f "$PA_CAP/pw-artifacts/spec-failing-test/trace.zip" ] && echo yes)" "yes" "the skipped trace is still in the consumer's outputDir (copy, not move)"

# ---------------------------------------------------------------------------
section "playwright-artifact-archiver: copies, never moves — consumer files survive"
PA_SAFE=$(pa_mktemp); pa_project "$PA_SAFE"
# Hash names AND contents so a silently-emptied or renamed file is caught.
pa_tree_hash() { find "$1" "$2" -type f -exec shasum {} + 2>/dev/null | sort | shasum | awk '{print $1}'; }
PA_SAFE_BEFORE=$(pa_tree_hash "$PA_SAFE/pw-artifacts" "$PA_SAFE/pw-html")
pa_fire "$PA_SAFE"
PA_SAFE_AFTER=$(pa_tree_hash "$PA_SAFE/pw-artifacts" "$PA_SAFE/pw-html")
assert_eq "$PA_SAFE_AFTER" "$PA_SAFE_BEFORE" "no consumer file removed or renamed by archiving"
assert_eq "$([ -f "$PA_SAFE/playwright.config.ts" ] && echo yes)" "yes" "consumer config untouched"

# ---------------------------------------------------------------------------
section "playwright-artifact-archiver: path discovery beats hardcoded defaults"
PA_JSON=$(pa_mktemp); pa_project "$PA_JSON"
mkdir -p "$PA_JSON/reports"
printf '{"stats":{}}' > "$PA_JSON/reports/custom.json"
pa_fire "$PA_JSON" "PLAYWRIGHT_JSON_OUTPUT_NAME=reports/custom.json npx playwright test"
PA_JSON_RUN=$(pa_newest "$PA_JSON")
assert_eq "$([ -f "$PA_JSON_RUN/artifacts/reports/custom.json" ] && echo yes)" "yes" "PLAYWRIGHT_JSON_OUTPUT_NAME from the command line is honoured"
assert_eq "$("$JQ" -r '[.sources[] | select(.kind=="jsonReport")] | .[0].resolvedFrom' "$PA_JSON_RUN/manifest.json")" "cli:PLAYWRIGHT_JSON_OUTPUT_NAME" "manifest records the json path source"

PA_CLI=$(pa_mktemp); pa_project "$PA_CLI"
mkdir -p "$PA_CLI/cli-out/spec-x"
printf 'cli-trace' > "$PA_CLI/cli-out/spec-x/trace.zip"
pa_fire "$PA_CLI" "npx playwright test --output=cli-out"
assert_eq "$([ -f "$(pa_newest "$PA_CLI")/artifacts/cli-out/spec-x/trace.zip" ] && echo yes)" "yes" "--output= on the command line overrides the config"

PA_DEF=$(pa_mktemp)
mkdir -p "$PA_DEF/test-results/spec-y"
printf 'default-trace' > "$PA_DEF/test-results/spec-y/trace.zip"
pa_fire "$PA_DEF"
assert_eq "$([ -f "$(pa_newest "$PA_DEF")/artifacts/test-results/spec-y/trace.zip" ] && echo yes)" "yes" "no config → degrades to the Playwright default outputDir"
assert_eq "$("$JQ" -r '[.sources[] | select(.kind=="outputDir")] | .[0].resolvedFrom' "$(pa_newest "$PA_DEF")/manifest.json")" "default" "manifest is honest that the path was a fallback"

# ---------------------------------------------------------------------------
section "playwright-artifact-archiver: archiving failure never fails the run"
PA_BROKE=$(pa_mktemp); pa_project "$PA_BROKE"
# .achilles occupied by a regular file — every mkdir under it fails.
printf 'not a directory\n' > "$PA_BROKE/.achilles"
assert_allow "$H" "$(pa_payload "$PA_BROKE")" "unwritable archive root → silent allow, exit 0"
assert_eq "$([ -f "$PA_BROKE/pw-artifacts/spec-failing-test/trace.zip" ] && echo yes)" "yes" "a broken archiver leaves the consumer's artifacts alone"

# A PARTIAL copy failure is the dangerous one: the archive root is writable, so
# a manifest gets written, but one file never lands. It must not pass for a
# complete archive, and it must not stamp the fingerprint — otherwise the run is
# permanently marked archived and the next run wipes the originals.
PA_PART=$(pa_mktemp); pa_project "$PA_PART"
chmod 000 "$PA_PART/pw-artifacts/spec-failing-test/trace.zip"
pa_fire "$PA_PART"
PA_PART_RUN=$(pa_newest "$PA_PART")
assert_eq "$("$JQ" -r '.incomplete' "$PA_PART_RUN/manifest.json")" "true" "a short copy is marked incomplete in the manifest"
assert_eq "$([ "$("$JQ" -r '.counts.archivedFiles' "$PA_PART_RUN/manifest.json")" -lt "$("$JQ" -r '.counts.expectedFiles' "$PA_PART_RUN/manifest.json")" ] && echo yes)" "yes" "manifest reconciles archived against expected file counts"
assert_eq "$(printf '%s' "$PA_OUT" | "$JQ" -r '.systemMessage' 2>/dev/null | grep -c 'INCOMPLETE')" "1" "a short copy is announced, never silent"
assert_eq "$([ -f "$PA_PART/.achilles/runs/.last-archive.json" ] && echo yes)" "" "an incomplete archive does not stamp the fingerprint"
assert_eq "$([ -f "$PA_PART_RUN/artifacts/pw-artifacts/spec-failing-test/error-context.md" ] && echo yes)" "yes" "the files that COULD be copied are still archived"
chmod 644 "$PA_PART/pw-artifacts/spec-failing-test/trace.zip"
pa_fire "$PA_PART"
assert_eq "$(pa_runs "$PA_PART")" "2" "the unstamped fingerprint makes the next invocation retry"
assert_eq "$("$JQ" -r '.incomplete' "$(pa_newest "$PA_PART")/manifest.json")" "false" "the retry archives completely"

PA_NOPROJ=$(pa_mktemp)
assert_allow "$H" "$(pa_payload "$PA_NOPROJ")" "project with no artifacts at all → silent allow"
assert_allow "$H" "$(payload hook_event_name=PostToolUse tool_name=Bash cwd=/nonexistent-path-xyz command='npx playwright test')" "nonexistent cwd → silent allow"
assert_allow "$H" "$(payload hook_event_name=Stop)" "empty payload → silent allow"

# ---------------------------------------------------------------------------
section "playwright-artifact-archiver: scoped — adjacent traffic is not archived"
# Allow-cases for the command heuristic: commands that mention playwright or
# look test-shaped but are not a Playwright run must not trigger an archive.
PA_ADJ=$(pa_mktemp); pa_project "$PA_ADJ"
assert_allow "$H" "$(pa_payload "$PA_ADJ" 'ls -la test-results/')" "listing test-results is not a run"
assert_allow "$H" "$(pa_payload "$PA_ADJ" 'npx playwright show-report')" "show-report is not a run"
assert_allow "$H" "$(pa_payload "$PA_ADJ" 'npx playwright show-trace test-results/x/trace.zip')" "show-trace is not a run"
assert_allow "$H" "$(pa_payload "$PA_ADJ" 'npx playwright-cli -s=composer-j-login-1-c1 open')" "playwright-cli is not a run"
assert_allow "$H" "$(pa_payload "$PA_ADJ" 'echo "npx playwright test"')" "a quoted mention is not a run"
assert_allow "$H" "$(pa_payload "$PA_ADJ" 'npm ci --ignore-scripts')" "npm ci is not a run"
assert_eq "$(pa_runs "$PA_ADJ")" "0" "no archive produced by any adjacent command"

# The npm-script form IS a run when package.json says so.
printf '{"scripts":{"test:e2e":"playwright test --reporter=list"}}' > "$PA_ADJ/package.json"
pa_fire "$PA_ADJ" "npm run test:e2e"
assert_eq "$(pa_runs "$PA_ADJ")" "1" "npm run <script> whose body is a playwright run archives"

# ---------------------------------------------------------------------------
section "playwright-artifact-archiver: opt-out and never-deny"
PA_OFF=$(pa_mktemp); pa_project "$PA_OFF"
ACHILLES_ARTIFACT_RETAIN=0 pa_fire "$PA_OFF"
assert_eq "$(pa_runs "$PA_OFF")" "0" "ACHILLES_ARTIFACT_RETAIN=0 disables archiving entirely"
assert_eq "$PA_OUT" "" "opt-out is silent"

# The hook is an observer: no input shape may produce a permissionDecision.
PA_DENY=$(pa_mktemp); pa_project "$PA_DENY"
for pa_cmd in 'npx playwright test' 'rm -rf /' 'git commit -m "x"' ''; do
  PA_D=$(printf '%s' "$(pa_payload "$PA_DENY" "$pa_cmd")" | bash "$H" 2>/dev/null \
         | "$JQ" -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null)
  assert_eq "${PA_D:-none}" "none" "never emits a permissionDecision (command: ${pa_cmd:-<empty>})"
done

rm -rf ${PA_TMPS[@]+"${PA_TMPS[@]}"}
