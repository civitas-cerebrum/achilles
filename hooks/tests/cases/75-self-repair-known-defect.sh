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

# probe <report-path> <expression over the classified map>
probe() {
  node --input-type=module -e "
    const m = await import('file://$DRIVER');
    const rows = m.collectResults('$1');
    const byTest = m.classify([rows]);
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

section "self-repair: a @known-defect test that goes green is green"
assert_eq "$(probe "$TMP_KD/report-fixed.json" "pat('SGN-10')")" "green" \
  "defect fixed → the tagged test classifies green, not known-defect"

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
