#!/bin/bash
# Tests for the @known-defect no-rerun contract in bin/self-repair.mjs.
#
# Not a hook — the rule is enforced in the repair driver itself, and this is
# the repo's only test runner, so the contract is pinned here rather than left
# to a markdown claim. Exercises the pure classification path
# (collectResults → classify → redFiles) against Playwright-shaped JSON
# reports, plus the report rendering.
#
# Canonical rule: skills/achilles-protocol/references/test-identity.md §2.
DRIVER="$(cd "$HOOK_DIR/.." && pwd)/bin/self-repair.mjs"

TMP_KD=$(mktemp -d /tmp/self-repair-known-defect-XXXXXX)
trap 'rm -rf "$TMP_KD"' EXIT

# A Playwright JSON report: one green case, one untagged deterministic
# failure, one failing case whose DESCRIBE carries @known-defect, and one
# failing case tagged through the reporter's `tags` array.
cat > "$TMP_KD/report.json" <<'EOF'
{
  "suites": [
    {
      "title": "login.spec.ts",
      "file": "tests/e2e/login/login.spec.ts",
      "specs": [
        { "title": "LGN-01 · valid credentials reach the dashboard",
          "tests": [{ "results": [{ "status": "passed" }] }] },
        { "title": "LGN-04 · a wrong password is rejected",
          "tests": [{ "results": [{ "status": "failed", "error": { "message": "expected 401" } }] }] }
      ],
      "suites": [
        {
          "title": "Login — brute-force protection @known-defect",
          "specs": [
            { "title": "LGN-08 · repeated failed logins are throttled",
              "tests": [{ "results": [{ "status": "failed", "error": { "message": "no throttling observed" } }] }] }
          ]
        }
      ]
    },
    {
      "title": "signup.spec.ts",
      "file": "tests/e2e/signup/signup-duplicate-email.spec.ts",
      "specs": [
        { "title": "SGN-10 · a duplicate email surfaces a conflict",
          "tags": ["@known-defect"],
          "tests": [{ "results": [{ "status": "failed", "error": { "message": "no conflict message" } }] }] }
      ]
    }
  ]
}
EOF

# Same shape, but the known-defect case now PASSES — the defect got fixed.
python3 - "$TMP_KD/report.json" "$TMP_KD/report-fixed.json" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
r["suites"][1]["specs"][0]["tests"][0]["results"][0] = {"status": "passed"}
json.dump(r, open(sys.argv[2], "w"))
EOF

# probe <report-path>[,<report-path>…] <expression over the classified map>
# Each comma-separated report is one baseline run.
probe() {
  node --input-type=module -e "
    const m = await import('file://$DRIVER');
    const runs = '$1'.split(',').map((p) => m.collectResults(p));
    const byTest = m.classify(runs);
    const red = m.redFiles(byTest);
    const pat = (t) => [...byTest.values()].find((x) => x.title.startsWith(t))?.pattern;
    const redTitles = [...red.values()].flat().map((t) => t.title).sort();
    process.stdout.write(String($2));
  " 2>/dev/null
}

# ---------------------------------------------------------------------------
section "self-repair: @known-defect reds are classified, not queued for repair"
assert_eq "$(probe "$TMP_KD/report.json" "pat('LGN-08')")" "known-defect" \
  "failure under a @known-defect describe → pattern known-defect"
assert_eq "$(probe "$TMP_KD/report.json" "pat('SGN-10')")" "known-defect" \
  "failure tagged via the reporter tags array → pattern known-defect"
assert_eq "$(probe "$TMP_KD/report.json" "pat('LGN-04')")" "deterministic-fail" \
  "untagged failure → still deterministic-fail"
assert_eq "$(probe "$TMP_KD/report.json" "pat('LGN-01')")" "green" \
  "passing test → still green"

section "self-repair: the red set excludes them (no reruns, no workers)"
assert_eq "$(probe "$TMP_KD/report.json" "redTitles.join('|')")" \
  "LGN-04 · a wrong password is rejected" \
  "only the untagged failure enters the red set"
assert_eq "$(probe "$TMP_KD/report.json" "red.size")" "1" \
  "one red file — the @known-defect file is not scheduled"

section "self-repair: a passing @known-defect is an anomaly, never silently green"
# test-identity.md §2: the tag predicts red, so ANY pass classifies
# known-defect-passed — a non-terminal pattern that enters the repair scope
# (fixed → drop the tag after the stability bar; nondeterministic → @flaky).
assert_eq "$(probe "$TMP_KD/report-fixed.json" "pat('SGN-10')")" "known-defect-passed" \
  "tagged test passing every run → known-defect-passed, not green"
assert_eq "$(probe "$TMP_KD/report.json,$TMP_KD/report-fixed.json" "pat('SGN-10')")" "known-defect-passed" \
  "tagged test with a mixed fail/pass matrix → known-defect-passed, not known-defect"
assert_eq "$(probe "$TMP_KD/report-fixed.json" "pat('LGN-08')")" "known-defect" \
  "tagged test red in every run → still terminal known-defect"
assert_eq "$(probe "$TMP_KD/report-fixed.json" "redTitles.includes('SGN-10 · a duplicate email surfaces a conflict')")" "true" \
  "the anomaly ENTERS the red set — it gets a stability-probe worker"
assert_eq "$(probe "$TMP_KD/report-fixed.json" "red.size")" "2" \
  "anomaly file scheduled alongside the untagged red file; the all-red @known-defect file still is not"
assert_eq "$(probe "$TMP_KD/report-fixed.json" "pat('LGN-01')")" "green" \
  "an untagged pass still classifies green"

section "self-repair: the report surfaces them separately"
RENDER=$(node --input-type=module -e "
  const m = await import('file://$DRIVER');
  process.stdout.write(m.renderMarkdown({
    'run-id': 'r1', mode: 'script', 'started-at': 'a', 'finished-at': 'b', rounds: 1,
    baseline: { runs: 3 }, 'verify-runs': 2,
    totals: { 'already-green': 1, 'known-defect': 1, healed: 0, 'app-bugs': 0, quarantined: 0, 'operator-pending': 0, unresolved: 0 },
    files: [{ file: 'a.spec.ts', status: 'explained', tests: [
      { title: 'LGN-08 · repeated failed logins are throttled', 'baseline-pattern': 'known-defect', outcome: 'known-defect' },
    ] }],
    observations: [], artifacts: {},
  }));
" 2>/dev/null)
assert_eq "$(echo "$RENDER" | grep -c 'Known defects (not repaired, not rerun)')" "1" \
  "report.md carries a known-defects section"
assert_eq "$(echo "$RENDER" | grep -c '| 1 | 1 | 0 | 0 | 0 | 0 | 0 |')" "1" \
  "the outcome table carries the known-defect column"

section "self-repair: the anomaly worker brief carries the stability probe and the tag-site guard"
# brief <tests-json> <expression over the composed brief string>
brief() {
  node --input-type=module -e "
    const m = await import('file://$DRIVER');
    const b = m.workerBrief('tests/e2e/signup/signup.spec.ts', $1,
      '/tmp/r.json', '/tmp/s.json', { baselineRuns: 3 });
    process.stdout.write(String($2));
  " 2>/dev/null
}
ANOMALY_ONLY="[{ title: 'SGN-10 · a duplicate email surfaces a conflict', pattern: 'known-defect-passed', outcomes: ['passed'], errors: [] }]"
MIXED="[{ title: 'SGN-10 · a duplicate email surfaces a conflict', pattern: 'known-defect-passed', outcomes: ['passed'], errors: [] }, { title: 'SGN-11 · weak password rejected', pattern: 'deterministic-fail', outcomes: ['failed'], errors: ['boom'] }]"

assert_eq "$(brief "$ANOMALY_ONLY" "b.includes('TAG-SITE GUARD')")" "true" \
  "anomaly brief carries the tag-site guard"
assert_eq "$(brief "$ANOMALY_ONLY" "b.includes('do NOT strip or replace it there — re-scope first')")" "true" \
  "shared describe/file tag sites must be re-scoped, never stripped, while siblings are still red"
assert_eq "$(brief "$ANOMALY_ONLY" "b.includes('each still-red sibling keeps') && b.includes('@known-defect')")" "true" \
  "re-scoping keeps @known-defect on the still-red siblings"
assert_eq "$(brief "$ANOMALY_ONLY" "b.includes('adapted from the one test-repair Stage 5.5 uses')")" "true" \
  "the probe bar is named as adapted from Stage 5.5, not the same bar"
assert_eq "$(brief "$ANOMALY_ONLY" "b.includes('Load the failure-diagnosis skill')")" "false" \
  "an anomaly-only file gets the probe brief, not the repair pipeline"
assert_eq "$(brief "$MIXED" "b.includes('Load the failure-diagnosis skill') && b.includes('TAG-SITE GUARD')")" "true" \
  "a mixed file gets both the repair pipeline and the anomaly probe"

section "self-repair: verify identity survives the tag edit (normalised-title fallback)"
# Dropping @known-defect (or retagging @flaky) renames a title-keyed test;
# normalizeTitle is what testOutcome/findVerified use to re-attach evidence.
assert_eq "$(node --input-type=module -e "
  const m = await import('file://$DRIVER');
  const pre = 'SGN-10 · a duplicate email surfaces a conflict @known-defect';
  const post = 'SGN-10 · a duplicate email surfaces a conflict';
  const retagged = 'SGN-10 · a duplicate email surfaces a conflict @flaky';
  process.stdout.write(String(
    m.normalizeTitle(pre) === m.normalizeTitle(post) &&
    m.normalizeTitle(retagged) === m.normalizeTitle(post) &&
    m.normalizeTitle('untouched title') === 'untouched title'));
" 2>/dev/null)" "true" \
  "baseline, tag-dropped and retagged titles normalise to the same identity"
