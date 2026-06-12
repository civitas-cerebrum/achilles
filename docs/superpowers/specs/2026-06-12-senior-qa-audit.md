# Senior-QA Audit — achilles + element-interactions (2026-06-12)

Four parallel audits of the QA-agent system, commissioned to ground the "more senior
QA agent" improvement roadmap. Surfaces: (1) skills methodology, (2) harness hooks
enforcement, (3) the element-interactions package, (4) evidence & communication
outputs. This document is the durable record; the phased designs reference it.

Roadmap derived from this audit:

- **Phase 1 — make the harness honest** (integrity fixes; spec: `2026-06-12-phase1-harness-integrity-design.md`)
- **Phase 2 — senior judgment layer** (risk model, oracle ladder, BVA, stopping criteria, a11y/perf)
- **Phase 3 — framework state-control & evidence upgrades** (mocking/clock/storage, `test.step()` artifacts, ledger schema extensions, trend reporting, flake ledger)

---

## Audit 1 — Skills methodology (judgment & risk-based thinking)

Overall: exceptionally strong on *process integrity* (anti-shortcut contracts,
determinism, evidence discipline, schema rigor) — arguably staff-level on preventing
an LLM from cutting corners. Weakest on the opposite dimension: *economic and risk
judgment*.

### Top 10 gaps

1. **Risk model is impact-only, execution risk-flat** — `journey-mapping/references/phases.md`
   Phase 3 asks only impact-side questions; likelihood, code churn, and defect history
   never enter prioritization. coverage-expansion's no-skip contract gives a P3 footer
   journey the same five-pass treatment as checkout, contradicting journey-mapping's
   own "higher-priority journeys get more adversarial attention." High / medium effort.
2. **"Knowing when to stop" is structurally forbidden but never equipped** — the only
   sanctioned scope decisions are all-or-nothing modes plus verbatim user quotes; no
   skill ever *generates* a risk-ranked plan the user could approve. The judgment is
   exiled to the user without analysis to decide with. High / large.
3. **Equivalence partitioning / BVA never named or taught** — "edge cases" is a payload
   grab-bag (test-composer Step 3, bug-discovery Phase 1a); no defense against five
   tests in the same equivalence class. Medium-high / small.
4. **Screenshot-visibility rule self-contradicts** — bug-discovery's "absolute" rule
   (non-visible → "No impact") vs its own Critical examples (exposed API keys, GDPR
   violations) and static mode's severity ordering. Security bugs get demoted. High / small.
5. **No oracle-strength hierarchy** — toast-visible satisfies the kernel rule for a
   checkout; DB/API oracle is opt-in (database-testing names the gap but test-composer
   never requires it); contract-testing's deliberate-failure check has no UI analogue.
   High / medium.
6. **No maintenance economics** — Pass 5 locks every confirmed boundary as a permanent
   regression test with no value gate (worked example: +14 from one pass); test-repair
   is deliberately stateless on flake history; suite runtime never budgeted. High / medium.
7. **"Performance baseline" promised for P0 journeys (Phase 3 table), defined nowhere.**
   Medium / small-medium.
8. **Accessibility entirely absent** — no WCAG/axe/keyboard/focus anywhere, despite
   ARIA snapshots powering every probe; coverage-expansion's "Adding a new pass type"
   even uses a11y as its hypothetical. Medium-high / medium.
9. **Coverage reasoned quantitatively with contradictory gates** — journey-mapping's
   75%/50% checkpoint tiers vs test-composer's "exhaustive" contract describe
   incompatible worlds; no residual-risk statement in coverage artifacts (bug-discovery's
   "Areas not probed (and why)" framing exists nowhere else). Medium / small-medium.
10. **Count-over-quality incentives** — onboarding's "≥7 unique findings → third
    adversarial pass" (a pass that doesn't exist in coverage-expansion) triggers on
    volume not severity; "5-15 tests per spec" reads as quota; `N findings` headlines
    commit messages and returns. Medium / small.

### Minor observations

- contract-testing frontmatter names bug-discovery as a caller; its own integration table says "Unrelated."
- onboarding priority-tier vocabulary drift (P1-P3 vs journey-mapping's P0-P3); Phase 5 exit criteria omit P0/P1.
- P3 "smoke test" coverage vs the presence-only anti-pattern — exception never stated.
- test-composer mobile-variant rule conflict (Step 1 conditional vs reviewer unconditional on P0/P1).
- Legacy `singularity` skill still claims the same trigger space as `element-interactions`; failure-diagnosis/test-repair still titled "Singularity — …".
- `cleanupViaApiBackdoor` is contracted vaporware (throws at runtime by design).
- bug-report template ships plaintext credentials into tickets.
- Chromium-only by construction; no browser-matrix discussion.
- No clock/time control discussion (only visual-mask mitigation).
- No CI test-selection strategy (tags exist, no run-strategy guidance).
- Two-plus severity rubrics coexist with partial mappings.
- bug-discovery has no session charters or time-boxing; stopping point is category exhaustion.

---

## Audit 2 — Harness hooks enforcement

### Hook inventory (summary)

18 manifest hooks (see `scripts/postinstall.js` HOOK_MANIFEST): playwright-cli
isolation guard + cleanup, commit-message gate, subagent schema pre-read gate +
post-hoc return guard, standard-mode first-pass guard, onboarding ledger dispatch
gate + write gate, workflow approver registry + brief gate + attestation gate,
journey-mapping pre-read gate, journey-map sentinel gate, four selector-development
hooks, run-summary writer. Lib: no-skip-messaging, schema-role-map,
validate-against-schema.mjs, selector-diff-validator, visual-diff.

### Top 10 enforcement gaps (by damage potential)

1. **Every Write|Edit gate bypassable via Bash** (`cat > onboarding-status.json`,
   `rm` the ledger to reset to "brand-new run" silent-allow). Only Bash hooks are the
   playwright-cli guard and commit-message gate. CRITICAL / medium.
2. **onboarding-ledger-write-gate is a silent no-op in consumer installs** —
   postinstall never copies `schemas/` to `~/.claude/hooks/`; the gate's schema lookup
   fails and `exit 0`s, skipping actor-identity, phase-skip, mode-auth, and deliverable
   checks too. CRITICAL / low.
3. **Edit-path content synthesis broken** — `awk sub(o,n)` treats old_string as regex;
   any `[` aborts awk → empty PROPOSED_CONTENT → silent allow
   (onboarding-ledger-write-gate.sh:121-130). Zero test coverage on the Edit path. HIGH / low.
4. **Subagent-return validation broken/noisy when installed** — no node_modules or
   schemas at `~/.claude/hooks/lib/` → permanent false WARNs; WARN-only by design and
   PostToolUse can't deny. HIGH / medium.
5. **Reviewer identity is description-prefix-deep** — puppet reviewers satisfiable;
   brief-gate checks trivially gamed; attestation WARN-only; workflow-reviewer absent
   from schema-role-map despite its schema existing; no hook counts the 3-cycle reject cap. HIGH.
6. **Stale "Harness-enforced" claims** — coverage-expansion SKILL.md:46,564,569;
   test-composer SKILL.md:357; contributing SKILL.md:321,762 cite hooks retired in
   0.3.6. Orchestrator-direct spec writes are now ungated. HIGH / medium.
7. **"Unforgeable" deliverable signatures are forgeable state files** — no hook gates
   `.phase4-cycle-state.json`, `coverage-expansion-state.json`, `adversarial-findings.md`,
   `.workflow-approvers.json`. Phase 4 forgeable in three Writes. MEDIUM-HIGH / medium.
8. **Schema coverage diverges from README claims** — "picks up new roles automatically"
   is false (hard-coded case map); schemas with no wiring: section-agent,
   phase4-prioritise-author, workflow-reviewer, contribution-handover; roles with no
   schema: process-validator, phase1/2, stage2, cleanup, companion, fd, secrets-sweep,
   work-summary-deck; README's dispatch-mode rejection rules implemented nowhere. MEDIUM-HIGH / low.
9. **Ledger-gate phase targeting is opt-in for the attacker** — only `phaseN-*` and two
   other prefixes inferred; free-form descriptions skip ordering checks; fail-open on
   malformed/missing ledger. MEDIUM / medium.
10. **Subagent-only / parent-only invariants purely model-compliance since 0.3.6** —
    ~10 declared invariants ship neither hook nor honest impossibility note, violating
    the package's own contribution rule. MEDIUM / high.

### Hook-quality issues

- Bare `jq` (no bundled fallback) in: selector-development-activation-gate,
  -inertness-guard, -pipeline-stepper, run-summary-writer → fail-open under `set -e`.
- run-summary-writer reads artifacts nothing writes (`.achilles/onboarding-ledger.json`,
  `.bug-ledger/`, `.achilles/journey-map.json`); hardcodes `pw_exit=0`; counts only
  `.tests[0].results[0]`; only manifest hook with no test case.
- 3s timeout on the write-gate (node cold-start + Ajv compile); timeout kill fails open.
- commit-message-gate parses only the first `-m '...'`; `--message=`, `-F`, heredocs bypass.
- Reviewer-prefix definition drift between ledger-gate (`phase[1-8]|pass[1-5]|cycle[1-5]`)
  and registry/brief/attestation gates (any `workflow-reviewer-*`).
- workflow-reviewer-attestation-gate.sh:146-147 vestigial empty regex group + blanked comment.
- selector-development-pipeline-stepper: `xargs cat` breaks on spaces; `sha256sum`
  absent on stock macOS (commit check permanently denies); bash-3.2 `set -u` empty-array crash.
- Tests: 365 green, but no Edit-synthesis case, no run-summary case; bypass-artifacts
  README references deleted tests 24-30.
- harness-hooks.md index missing four hooks (approver-registry, brief-gate,
  attestation-gate, run-summary-writer).

### Minor

- Dead registry leash in subagent-return-schema-guard.sh:159-201 (registrar retired);
  isolation-guard deny text cites the retired dispatch-guard.
- onboarding-status.schema.json: `additionalProperties: true`, no `modeAuthorizer`
  property, yet write-gate deny text cites "§runMode" of it.
- Env-var escape hatches (`*_GATE=off`, `FAKE_STAGED_HASH`) and agent's ability to edit
  `~/.claude/settings.json`/hook files are an unaddressed meta-surface.
- contributing SKILL.md:822 references a `build_message` helper that doesn't exist.
- Retirement hygiene otherwise good (pruneRetiredHooks removes all 32 legacy hooks).

---

## Audit 3 — element-interactions package (v0.3.6)

API surface: 102 public Steps methods, 53 on ElementAction, 281 public methods total.
Disciplined architecture (Steps → ElementAction → matcher tree → Verifications).
Error-message quality is a genuine strength (available-texts listings, fix-pointing
unconfigured-client errors) — well-tuned for agent self-correction.

### Top 10 gaps (priority order = severity × effort)

1. **G6 — publish blocker:** `"@civitas-cerebrum/sql-client": "file:../sql-client"`. HIGH / small.
2. **G1 — waitForState and all internal waits swallow timeouts**
   (ElementUtilities.ts:31-54, CommonSteps.ts:1242-1247): `steps.waitForState(...)`
   can never fail a test; README's own example uses it as an assertion; strict-mode
   violations silently narrow to `.first()`. HIGH / small.
3. **G4 — failure artifacts:** single screenshot; steps never wrapped in `test.step()`
   so logging never reaches report/trace; no console/pageerror capture, DOM/ARIA
   snapshot on failure, or structured failure metadata via `testInfo.attach`. HIGH / medium.
4. **G2 — pointer-interception auto-retry masks real overlay bugs**
   (Interaction.ts:89-101): unconditional dispatchEvent fallback, debug-channel-only
   signal; `force`/`withoutScrolling` both map to dispatchEvent (≠ Playwright
   semantics). HIGH / medium.
5. **G3 — no test-state control plane:** no network mocking (only blockedOrigins
   abort), no clock facade, no storage/cookie setters (read-only), no storageState
   auth reuse, no test-data lifecycle helpers. HIGH / large.
6. **G5 — README teaches removed raw-Locator API** (§"Advanced: Raw Interactions API"
   vs v0.2.6 WebElement-only reality); negative.spec.ts passes raw Locators and passes
   for the wrong reason; tests excluded from tsc. MEDIUM / small.
7. **G7 — no per-call timeout on positional Steps API** (StepOptions lacks `timeout`);
   option-bag pollution: inapplicable options typecheck and silently no-op. MEDIUM / small.
8. **G8 — API/SQL provider-overload heuristics ambiguous and any-typed**
   (CommonSteps.ts:1697-1711, 1764-1769): `apiPost(path, 'stringBody')` impossible;
   no response-body/schema matchers despite contract-testing's mandates. MEDIUM / medium.
9. **G9 — no dialog, download, waitForURL, scroll, permissions/locale facades**;
   raw-`page` drop-down undocumented as sanctioned escape hatch. MEDIUM / medium.
10. **G10 — no soft assertions:** ExpectBuilder.flush short-circuits; verifyAllPresent
    loses sibling failures; `waitForNetworkIdle` rests on discouraged `'networkidle'`;
    no animation-settle/hydration helper. MEDIUM / medium.

### Self-testing & docs

- 31 specs (~7k lines) against dockerized Vue app + BookHive + Postgres — real E2E
  self-testing. `test-coverage-report.txt`'s "281/281 (100.0%)" is method-invocation
  coverage, not branch coverage — should be labeled "API coverage."
- Tests excluded from typechecking; `retries: 1` locally.
- Docs drift: raw-Locator section (worst), getText null-vs-'' contract, verifyCount
  missing variants, README matcher list omits html/outerHtml.
- Minor: `isPresent` checks visibility not presence; `click` leaks
  `Promise<boolean|void>`; `Steps.on()`/`expect()` construct fresh ElementInteractions
  per call; `Navigation.toUrl` reaches into private `_options.baseURL`; `dist/` and
  `.env` committed; BooleanMatcher missing checked/focused/editable.

---

## Audit 4 — Evidence & communication

Human-facing surfaces (bug-report ticket, companion-mode bundle) are near
senior-grade. The pipeline-internal defect record (adversarial-findings ledger) is far
below the bug-report skill's own standard. Cross-run memory is essentially absent.

### Top 10 gaps

1. **No build/commit identification anywhere** — ledger schema is exactly four
   sub-bullets and §4 rule 5 forbids extensions; run-summary has no timestamp/run
   ID/build. Regression-vs-new unanswerable. HIGH / M.
2. **Ledger findings lack repro steps and evidence paths — and the requirement is
   self-contradictory:** bug-discovery's reviewer demands `evidence:` lines "per the
   canonical schema" which defines no such line and bans extensions. HIGH / M.
3. **run-summary-writer reports against artifacts no skill produces**, hardcodes exit
   0, third severity vocabulary (`high/med/low`). HIGH / S-M.
4. **No trend reporting across runs** — single overwritten run-summary.json; deck
   timeline from git log, not result history. HIGH / M.
5. **Severity/priority conflated in all autonomous outputs** — discipline exists only
   in the Jira path; journey P0-P3 priority never propagated to findings. MEDIUM-HIGH / S.
6. **bug-discovery mandates `BUG-001` IDs its own line 35 bans** — two incompatible ID
   systems for the same defect. MEDIUM-HIGH / S.
7. **Dedup is pure LLM semantic judgment** — no normalized fingerprint
   (route + element + failure-category); cross-run dedup doesn't exist. MEDIUM / M.
8. **No persisted flake/pass-fail history** — heal (f) requires "flake persisted after
   two heal attempts" but nothing records attempts across sessions. MEDIUM / M.
9. **Jira template is a traceability island with plaintext credentials** — no
   FINDING-ID/journey/test-path/build fields; `Password: 123!Password` verbatim. MEDIUM / S.
10. **failure-diagnosis Stage 6 describes evidence instead of citing paths** —
    "[describe what the screenshot shows]" with the artifact on disk; no
    severity/env/journey link. MEDIUM / S.

### Minor

- bug-discovery cites `references/adversarial-findings-schema.md` relative to itself; lives in coverage-expansion.
- Three severity vocabularies; mapping discipline only partial.
- probe.schema.json returns counts only — no finding IDs, unreconcilable against ledger.
- bug-discovery screenshot path convention unanchored.
- companion-mode summary lacks browser/build fields.
- work-summary-deck reads whatever playwright-report is on disk, no staleness check.
- Strong points to preserve: companion-mode immutable bundle + capture-gaps honesty;
  journey-mapping Gated Areas; test-catalogue skipped-with-reason; failure-diagnosis
  Stage 0 "observed vs documented" — candidate for a required `oracle:` citation line.
