# Stage 4a and 4b: heal strategy selection and live DOM re-learning

# Stage 4a — Heal strategy selection

Once you've classified the failure as a test issue and checked edge cases, pick a healing strategy. Every heal has a precondition, an autonomy level, and a clear scope: applying the wrong one is how bugs get masked.

| Heal | Autonomy | Precondition | What it does |
|---|---|---|---|
| **a. Selector re-learn** | **Auto** | Page-repo lookup failed; live DOM has a close match by text/role/landmark; screenshot shows correct UI otherwise | Update `page-repository.json` with the re-learned selector; immediate confirmation run |
| **b. Timing hardening** | **Auto** | Intermittent timeout on a known-good element; screenshot shows correct UI (no error state); no flow drift detected | Add `waitForState` / `waitForNetworkIdle` before the interaction; bump a bounded timeout |
| **c. Flow-step drift** | **Propose** | App shows an extra/missing/reordered step between expected actions; screenshot confirms correct page state at each step the app does reach | Present the detected flow diff to the operator; apply on approval |
| **d. Assertion re-baseline** | **Propose** | Hardcoded literal no longer matches; UI state around the assertion is otherwise correct | Present old vs new value to the operator; apply on approval |
| **e. State isolation** | **Auto** | Test passes when run alone, fails when run after specific predecessors (verified empirically) | Add fresh context / storage reset / cleanup hook; re-run in suite order |
| **f. Flake quarantine** | **Report** | Flake persisted after two heal attempts of different strategies; root cause unclear | Tag test `@flaky`, append an entry to the quarantine ledger (see §Quarantine ledger below), add to repair summary with diagnostic notes; do NOT silently skip |
| **g. Whole-test rewrite** | **Operator-aligned** | Flow changed so fundamentally that the scenario no longer maps to the app as-is; no incremental heal applies | Present to operator; on approval, invoke `test-composer` with journey context. Never regenerate without alignment. The rewrite exits through `test-composer` Step 6c's composition judge (`../achilles-protocol/references/test-composition-standards.md` §4). |
| **h0. Known defect: no heal, no rerun** | **Report** | The test (or its describe) carries `@known-defect` and the failure signature matches the filed defect | Terminal on sight: do not reproduce, do not experiment, do not heal, do not rerun. Record it as a known defect in the summary and move on. A *different* error behind the tag is a second, unfiled problem; diagnose that one normally. A `@known-defect` test that passes is an anomaly, never a silent green: prove the fix with the stability bar (3/3 targeted + 5/5 suite-order green) and drop the tag, or, if any of those runs is red, the pass is nondeterministic: retag `@flaky` with a quarantine-ledger entry. Contract: [`test-identity.md`](../../achilles-protocol/references/test-identity.md) §2 |
| **h. Documented-quirk match: no heal** | **Report** | The observed failure shape exactly matches a documented quirk in `app-context.md` (configuration-dependent option subsets, redirect-vs-popup auth patterns, vendor-aliased options, etc.) **OR** matches a documented app-degradation signal (a degradation-banner copy string from `app-context.md`'s documented-banners list, the documented hanging spinner-sentinel custom element, 5xx in network capture) | Report observed-vs-documented diff; do NOT modify the test. The skip / failure is correct; the regression is in the app or in the documentation. Cross-link the relevant `app-context.md` section in the report. |
| **i. Dependency / framework upgrade** | **Propose** | Stage 3 classified the failure as a **framework / dependency defect**: the failing frames run through a dependency, Stage 0a shows the run resolved an older version than one where the behaviour differs, and the spec + app are both correct | Report the version delta (run's version → target version), cite the changelog / release entry or the passing re-run on the newer version, and propose the bump: a lockfile change, not a spec change. Do NOT edit the test, the waits, or the element repository. Verification is a re-run on the bumped version, and for Entrypoint C the next pipeline run. If the defect is not yet fixed upstream, this becomes a package-level report (see `contributing-to-achilles-protocol`); still not a test edit. |

**Selection rules** (apply in order, stop at first match):

0. If the test carries `@known-defect` and the failure signature matches the filed defect → (h0) known defect → report; do NOT heal, do NOT rerun. This is the first check on purpose: it is the cheapest, and every step below spends evidence-gathering on a conclusion already written down.
1. If the observed failure shape exactly matches a documented quirk or app-degradation signal recorded in Stage 0's `app-context.md` read → (h) documented-quirk match → report; do NOT heal.
2. If the failing frames run through a dependency and Stage 0a shows a version delta that accounts for the behaviour → (i) dependency / framework upgrade → propose the bump; do NOT heal the test. **Check this before (3)–(7)**: a framework defect presents as a selector, timing, or state failure, so every one of those rules will happily "match" it and produce a durable workaround for a fixed bug.
3. If screenshot shows wrong UI (500, error page, broken layout, missing-that-should-be-present component) → **app bug**, go to Stage 6. Do not heal.
4. If page-repo lookup failed → (a) selector re-learn → proceed to Stage 4b
5. If timeout on a known-good element with correct surrounding state → (b) timing hardening
6. If pattern hypothesis (from `test-repair` if present) or empirical check says "state leak" → (e) state isolation
7. If live DOM shows step order does not match test sequence → (c) flow drift → propose
8. If assertion failure on a specific literal with otherwise-correct surrounding state → (d) re-baseline → propose
9. If two heal strategies have been attempted and the test still flakes → (f) quarantine
10. If the test scenario no longer maps to the app flow → (g) rewrite → operator-align

The precondition columns exist so that no heal runs unqualified: any heal applied without meeting its precondition is a guess, and guesses mask bugs.

# Quarantine ledger (heal (f) only)

Heal (f) appends an entry to the quarantine ledger at
`tests/e2e/docs/flake-quarantine.md`. The ledger is **committed, not
gitignored**: quarantine is cross-session state that the next
`test-repair` session must see.

Ledger header (first lines of the file):

```markdown
# Flake quarantine ledger
<!-- Written by failure-diagnosis heal (f); released by test-repair Stage 5.5.
     Out-of-band shell edits are denied by hooks/protected-artifact-bash-guard.sh. -->
```

Entry template (one per quarantined test):

```markdown
### `tests/<file>.spec.ts::<test-name>`
- **Quarantined:** YYYY-MM-DD
- **Failure-shape:** flaky-consistent | flaky-chaotic
- **Heal attempts:** <strategy 1>, <strategy 2> — both destabilized
- **Error signature:** <one-line dominant error when failing>
- **Diagnostic notes:** <what the evidence showed; why root cause is unclear>
- **Observations:** <dated appends from later sessions — e.g. "YYYY-MM-DD: still flaking 1/3 in Stage-1 baseline">
- **Status:** quarantined | unquarantined (YYYY-MM-DD — <evidence: 3/3 baseline + 5/5 suite-order green>)
```

Ownership is write-only and split: **failure-diagnosis writes**
entries (heal (f)); **test-repair releases** them (its Stage 5.5
quarantine review flips `Status:` to `unquarantined` with dated
evidence, or appends a still-flaking observation). No other skill
edits the ledger, and entries are never deleted: a released entry
keeps its history.

# Stage 4b — Live DOM re-learning (for heal strategy (a) only)

When the heal strategy is (a) selector re-learn, do NOT guess a replacement selector. Use `playwright-cli` to open the page at the navigation state where the lookup fails (`npx playwright-cli -s=fd-<short-slug> open --browser=chromium <URL>` followed by whatever `goto` / `click` chain reproduces the failure state), then locate candidates by stable signals.

**When the environment is not reachable from this session** (Entrypoint C against a production or gated pipeline), re-learn from the run's captured DOM instead of skipping the stage: `error-context.md`'s aria page snapshot names every role + accessible name that existed at the moment of failure, and the trace's `frame-snapshot` entries carry the DOM tree. That is enough for signals 1–3 below. It is **not** enough to confirm the new selector resolves, so a repository change learned this way is **Propose**, not Auto: state that it was learned from artifacts, and let the next pipeline run confirm it.

1. **Exact text match**: does the previous selector have known text content? Search the live DOM for an element with the same text.
2. **Role + accessible name fuzzy match**: e.g. previous target was a button labeled "Submit"; find a `role="button"` whose name contains "Submit" (or close variants like "Place Order", "Confirm").
3. **Nearby landmark stability**: previous target was "the button inside the section with heading 'Shipping'"; find the current equivalent via the stable landmark.
4. **Attribute overlap**: shared `data-testid` family, shared class prefix, shared `id` pattern.

**Confidence thresholds:**

- **High confidence** (text match + role match + landmark match all agree) → update `page-repository.json` atomically, run the test immediately to confirm.
- **Multiple competing candidates** → escalate to the operator with the candidate list; do not guess between them.
- **No candidate found** → the element likely disappeared. Re-classify as either (c) flow drift (something replaced it) or app bug (component missing that should be present) using the screenshot evidence as the tiebreaker.

# Root cause: fragile selector

If triage attributes the failure to a fragile selector (text drift, position-dependent CSS, role/name collision), check workspace shape before selecting a heal strategy:

**Frontend source in workspace**: `package.json` lists the UI framework as a dependency **and** a `src/`-style tree of `.tsx`/`.jsx`/`.vue`/`.svelte`/`.html` files is present:

→ Dispatch `selector-development` (`mode: "jit"`, `scope` = the element-key whose locator failed). After it returns, replace the test's locator with the new test-attribute selector and re-run. Then continue from Stage 5 (stability validation) as normal.

**Frontend source NOT in workspace:**

→ Report the fragile selector to the user as an actionable test-debt item. Do NOT attempt to harden the locator with compound selectors, nth-child chains, or XPath depth, that adds brittleness without adding stability. The report should name the element-key, the fragile signal (text drift / CSS position / role collision), and that `selector-development` cannot help because the source files are not available in this workspace.
