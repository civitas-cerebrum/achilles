# Handover — Senior-QA Harness & Methodology Upgrades

**Branch:** `claude/senior-qa-agent-harness-j7xdtc` (off `main` @ `9b54534`)
**Date:** 2026-06-12
**Status:** shipped & validated — all 365 hook tests pass, `schemas:lint` clean
**Scope of this doc:** what changed and why, the constraints you must not break, and the prioritized backlog for both `achilles` and `element-interactions`.

> This file is branch-level handover material. Drop or relocate it before merging to `main` if you don't want it in the package.

---

## 1. Goal of this work

Make the autonomous QA agent behave like a *more senior* QA engineer. A full audit of the methodology (all skills, hooks, schemas) showed the foundation is stronger than expected — flake detection, severity rubrics, stability protocols, and reviewer gates already exist. The genuine gaps were **lifecycle gaps** (states things enter but never leave) and **missing measurement axes**. Four were fixed in this branch; the rest are in the backlog (§4).

## 2. What shipped (commit `abe0c25`)

### 2.1 Oracle audit — new check §3b in the Stage 4a optimization protocol

**File:** `skills/element-interactions/references/test-optimization.md`

The 6-check protocol hardened test *inputs* (per-run uniqueness, seed rotation) but never audited the *assertion* side. §3b flags expected values hardcoded from volatile classes — timestamps, server-generated IDs, seed-dependent counts, locale/currency formatting, app-computed aggregates, order-dependent list reads — and rewrites them to round-trip / delta / shape oracles.

Key rules encoded in the section:
- Every expected value must trace to: the test's own inputs, a value captured earlier in the test, a documented invariant, or a shape assertion. Bare volatile literals fail.
- **Hardening ≠ weakening.** `exactly: 14` becomes `capture-before + 1`, never `greaterThan: 0`. If the robust form loses discriminating power → flag for review instead.
- Exact-copy tests (error wording, i18n, legal text) are flag-only: `// stage4a:oracle-deliberate`.

**Ripple updates (keep in sync if you touch §3b):**
- `skills/test-composer/SKILL.md` (lines ~51, ~216) — now says "7-check protocol"
- `skills/element-interactions/SKILL.md` (Stage 4a bullet + two dot-graph node labels) — "7-check protocol"
- `skills/element-interactions/references/stages-protocol.md` — section-count line

⚠️ **Numbering constraint:** §7 (whole-suite gate) and §8 (output format) are cross-referenced from `coverage-expansion/references/depth-mode-pipeline.md`, `test-composer/SKILL.md`, and `stages-protocol.md`. That's why the new check is **§3b**, not §4-with-renumbering. Don't renumber.

### 2.2 Defect-likelihood risk factors — second axis in journey mapping

**Files:** `skills/journey-mapping/references/phases.md` (Phase 3), `skills/journey-mapping/SKILL.md` (journey block template + kernel rules), `skills/coverage-expansion/references/depth-mode-pipeline.md`, `skills/bug-discovery/SKILL.md`

P0–P3 captures business **impact** but says nothing about **how likely a flow is to break** — a payment integration and a legal page got equal adversarial attention. Now:

- Journey blocks carry `**Risk factors:**` from a canonical 8-factor vocabulary: `state-mutation`, `payment`, `pii`, `auth-boundary`, `concurrent-use`, `third-party`, `async-heavy`, `complex-validation`. Tags require Phase 1/2 *observed evidence* (network shapes, mutation-endpoint table) — no speculative tagging.
- **Derived tier:** 2+ factors → `risk: elevated`, else `baseline`.
- Consumers: coverage-expansion excludes elevated journeys from `[group]`/`[P3-batch]` dispatches and orders them first *within* their tier; bug-discovery probes elevated journeys first and weights probe categories per factor (mapping table in its §"Risk-weighted probe ordering").

⚠️ **Invariants you must not break:**
1. **Risk never changes the P-tier.** It modulates adversarial attention and grouping eligibility only. Conflating the axes lets peripheral journeys absorb P0 budget.
2. **Backward compatibility:** maps without the field are valid; every consumer defaults to `risk: baseline` and behaves exactly as before. This keeps old journey maps, the test-catalogue parser, and the hooks untouched (no schema or hook changes were needed — verified by the full hook suite).

### 2.3 Flake-quarantine ledger with an exit path

**Files:** `skills/failure-diagnosis/SKILL.md` (heal (f) + new §"Quarantine ledger"), `skills/test-repair/SKILL.md` (Stage 1, new Stage 5.5, Stage 6 summary, YAGNI scope, success criteria)

Previously heal (f) tagged a test `@flaky` and… that was the end. test-repair even had a YAGNI rule forbidding persistent flake state, so quarantine was a one-way door. Now:

- Heal (f) appends a structured entry to `tests/e2e/docs/flake-quarantine.md` (committed, **not** gitignored — quarantine state must survive sessions). Entry template lives in failure-diagnosis §"Quarantine ledger".
- test-repair Stage 1 baselines **include** `@flaky` tests.
- New **Stage 5.5 quarantine review**: 3/3 baseline pass → candidate; confirm with 5× suite-order; release = remove `@flaky` + entry `status: unquarantined` (entry block stays — audit trail). Still-failing entries get a dated observation appended. Entries surviving **3+ sessions** escalate to the operator (root-cause investigation / heal (g) rewrite / retire).
- Ownership split: failure-diagnosis *writes* entries, only test-repair *releases* them.

The old YAGNI bullet was deliberately amended: the ledger is the **only** cross-session state; no run-history DB, no latency trending.

### 2.4 Finding triage lifecycle in bug-discovery

**File:** `skills/bug-discovery/SKILL.md` (Phase 2 steps, Phase 7 report template + new §"Triage lifecycle")

Reports were append-only snapshots. Now every finding carries `**Triage:**` — `new → acknowledged → fix-in-progress → fix-verified`, plus `deferred` / `wontfix`.

⚠️ **Invariants:**
- `deferred`/`wontfix` are **operator-only** (verbatim instruction recorded). Self-assigned acceptance = silent scope compression, which this methodology fights everywhere.
- `fix-verified` requires the Phase-6 reproduction test (asserting *correct* behaviour) to pass. Mere failure-to-reproduce → `live-unconfirmed` note, status unchanged (same epistemics as static-mode findings).
- Severity never changes during triage; the two fields answer different questions.
- Re-runs reconcile prior reports (Phase 3 re-runs reproduction tests) and carry all entries forward — findings advance, they never disappear.

## 3. Validation & dev environment

```bash
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 CIVITAS_SKIP_HOOK_INSTALL=1 CIVITAS_SKIP_JQ_INSTALL=1 npm install
npm run schemas:lint    # all schema fixtures green
npm run test:hooks      # 365/365 green
```

Gotchas:
- Use the three env opt-outs above in sandboxes — plain `npm install` registers hooks into `~/.claude/settings.json` and fetches chromium.
- Newer npm rewrites `peer` flags in `package-lock.json`; revert lockfile churn unless you actually changed deps (I did).
- Some hooks grep skill-file content — always run the full hook suite after editing any `SKILL.md`, even for "doc-only" changes.

## 4. Backlog — achilles (prioritized, not started)

1. **`cleanupViaApiBackdoor`** — contracted in `skills/test-composer/SKILL.md` (tenant-cleanup for add-* journeys) but unimplemented; specs that need it throw at runtime. Highest-value single item.
2. **CI integration** — `.github/workflows/` is empty. Candidate shape: hook tests + schemas:lint on PR; document a consumer-side workflow example (Pass 1 on PR, full pipeline nightly).
3. **Accessibility coverage** — no a11y variant anywhere (test-composer portfolio, bug-discovery probe catalogue). Blocked on element-interactions a11y matchers (§5 item 2) for the assertion surface; an axe-core probe phase in bug-discovery is possible sooner.
4. **Performance baselines** — companion-mode captures HAR but nothing analyzes it; no WebVitals capture or per-journey latency thresholds.
5. **Exploratory-testing charters** — time-boxed, focus-area session mode distinct from the deterministic matrix; natural fit as a bug-discovery `mode:`.
6. **Brownfield audit** — coverage-expansion assumes greenfield; no pre-pass that inventories *existing* tests against the journey map (duplicates / outdated / candidates for merge).
7. **Test-data seeding strategy** — gated-areas records *what* credentials are needed but not *how* to provision them.

## 5. Backlog — element-interactions (separate repo, access blocked from this session)

**Access status:** this session is scoped to `civitas-cerebrum/achilles` only — both the git proxy and GitHub MCP deny `civitas-cerebrum/element-interactions`, and no `add_repo` tooling is exposed. Analysis below comes from the published npm tarball `@civitas-cerebrum/element-interactions@0.3.6`. Start a session with that repo as a source to implement.

**Audit verdict:** clean package, zero drift between shipped `.d.ts` surface and the documented API reference in `skills/element-interactions/references/api-reference.md` (no doc fixes needed). Gaps are missing capabilities, not defects:

| # | Item | Notes |
|---|---|---|
| 1 | **Soft assertions** | All matchers throw on first failure. Sketch: `steps.expect(el, page).soft().text.toBe(x).visible.toBeTrue().finish()` — collect, then throw aggregate. |
| 2 | **Accessibility matchers** | No aria/role/contrast surface at all. Prereq for achilles a11y coverage (§4 item 3). e.g. `.accessibility.hasAriaLabel()`, role+name assertions. |
| 3 | **Network stubbing helpers** | Only `waitForResponse` exists. Add `stubRoute(pattern, response)` / `blockRoute(pattern)` wrapping `page.route()` — unlocks deterministic error-state tests. |
| 4 | **Clock mocking** | Surface Playwright `page.clock` as `freezeTime(iso)` / `advanceTime(ms)`. Pairs directly with the new §3b oracle check for timestamp assertions. |
| 5 | **Ship source maps** | `dist/` has no `.map` files; consumers can't debug through the package. `sourceMap: true` + include in `files`. |
| 6 | **Discriminated-union options** | `StepOptions` allows `strategy: 'index'` + `text` simultaneously with no compile error; same for `selectDropdown` (`type: VALUE` + `index`). Tighten without runtime change. |
| 7 | **Download tracking, fuzzy text match, modifier clicks, richer `withDescendant` filters** | Lower priority; see audit notes. |

All additions are non-breaking. When implemented, mirror them into `skills/element-interactions/references/api-reference.md` here — the zero-drift property between package and docs is worth protecting (consider a CI check for it).

## 6. Where to look first

| Question | File |
|---|---|
| How the 8-phase pipeline fits together | `skills/onboarding/SKILL.md` |
| What the hooks enforce | `hooks/*.sh` + `hooks/tests/cases/` (test names map 1:1 to hooks) |
| Subagent return contracts | `schemas/subagent-returns/*.schema.json` + fixtures |
| The four changes in this branch | `git show abe0c25` |
