# Repair-Worker Pipeline — understand before fixing

The stage contract every self-repair worker follows for every failing test
in its file. The pipeline exists because unstructured debugging converges
by luck: an agent that jumps from error line to fix attempt anchors on its
first hypothesis, heals symptoms, and misclassifies app bugs as test rot
(or worse, the reverse). The stages force the causal chain to be
established — and recorded — before any file is edited.

Stage names are a contract: the worker's `[self-repair:worker] stage=…`
announcements and the `stage-log[]` entries in its return use exactly
these names, in order. A stage may be revisited (experiment → back to
context-probe when a probe invalidates an assumption), but the
**understand gate** is one-way: no `fix` before `understand` is logged.

| # | Stage | Question it answers |
|---|---|---|
| 1 | `reproduce` | Does the failure happen under controlled observation, and what artifacts prove it? |
| 2 | `evidence-analysis` | At which exact step does the journey break, and what did the UI actually show? |
| 3 | `context-probe` | Are the selectors at the failure point valid against the live DOM, and what is the surrounding UI state? |
| 4 | `experiment` | What single factor, when varied, changes the behaviour — what is the causal mechanism? |
| 5 | `understand` | Can I state expected vs actual behaviour and the causal chain — and is it written down? |
| 6 | `fix` | (Test-side causes only) What is the minimal heal that addresses the established cause? |
| 7 | `verify` | Does the heal hold under 5 consecutive full-file runs? |
| 8 | `done` | Which exit condition was met? |

---

## Stage 1 — `reproduce`

Re-run the failing test under controlled observation: `--trace on`, video,
and the failure artifacts captured. In focus-mode baselines the failure
reruns already produced traces — start from those; reproduce fresh only
when they are missing or stale. Copy artifacts to the bug-evidence home
IMMEDIATELY (Playwright reuses `test-results/` dirs; reruns overwrite).

**Intermittent failures:** interleave reproductions over wall-clock time
before trusting any deterministic-looking pattern — a 3/3-red snapshot
inside one window can be a time-varying app incident. If reproduction
stops reproducing, that is itself evidence; record the pass/fail sequence.

**Output:** artifact paths + a one-line reproduction statement.
**Gate to 2:** at least one failure observed under trace, or the
non-reproduction pattern documented.

## Stage 2 — `evidence-analysis`

Read what was captured before touching anything live: failure screenshot
(what page/state was actually showing?), trace timeline (which action
succeeded last, which waits were pending, which network requests hung or
aborted?), error context (what did the assertion actually compare?).

Pin the **failure point**: the earliest step whose outcome diverged from
the journey's expectation — not the assertion that finally threw. An
"element not visible" error at the end of a flow usually indicts the
earliest broken step, not the element named in the error.

**Output:** the pinned failure point + what the UI actually showed there.
**Gate to 3:** failure point identified on evidence, not inferred from
the error message alone.

## Stage 3 — `context-probe`

Interrogate the live app around the failure point, read-only:

- **Selector validity:** does every selector the test uses at and before
  the failure point still match the live DOM (page repository entry ↔
  actual element)? A selector that matches green sibling tests is
  presumptively valid — check where it is used passing.
- **Surrounding UI state:** what is actually on the page at the failure
  point — overlays, dialogs, consent banners, loading states, pending
  network activity? What is interactive, what is disabled?
- **Journey context:** does the app's current flow still match the
  journey the test encodes (steps added/removed/reordered)?

**Output:** selector verdict + a snapshot description of the surrounding
UI state.
**Gate to 4:** selectors confirmed valid or identified as drifted; the
page state at the failure point is described from observation.

## Stage 4 — `experiment`

Hypothesis-driven interaction with the relevant components — vary **one
factor per probe** and observe how the behaviour changes:

- Run the journey outside the harness (plain Playwright, same UA/headers)
  — does the flow work without the test fixture's environment?
- Re-add harness factors one at a time (route interception, extra
  headers, viewport, storage state) — which one flips the behaviour?
- Interact with the failing component directly (click it in isolation,
  from a different entry path, after an explicit settle) — what changes?
- For timing suspicions: add/remove waits, throttle, slow-mo — does the
  failure rate move?

Budget: if ~5 probes have not produced a causal mechanism, stop
experimenting — record what was ruled out and exit `unresolved`/
`operator-pending` rather than guess. Ruling causes OUT is progress;
every probe's result (including nulls) goes in the stage log.

**Output:** the varied factors and their observed effects.
**Gate to 5:** one factor demonstrably changes the behaviour, or the
probe budget is exhausted with the exclusion list recorded.

## Stage 5 — `understand` (the one-way gate)

State the understanding explicitly, in the report AND in the project's
knowledge base:

1. **Expected behaviour** — what the journey should do at the failure
   point (per the journey map / test intent).
2. **Actual behaviour** — what the app demonstrably does, per stages 1–4.
3. **Causal chain** — the mechanism connecting them, with the stage-4
   probe results as proof.

**Knowledge write-back:** append a dated finding to the project's app
knowledge document (`tests/e2e/docs/app-context.md`, built by onboarding
Phase 2 — create it with a minimal header if the project predates it).
Behavioural discoveries outlive the repair session: interception changes
settle timing, this page double-redirects on locale strip, signout can
land on /500 during incidents. Re-read the file immediately before
appending (parallel workers share it); never rewrite others' entries.

**Classification happens here**, not earlier: test-side cause → proceed
to `fix`; app-side cause → high-confidence bug exit (below); mechanism
not established → `unresolved`/`operator-pending` exit. Confidence in an
app-bug claim must be HIGH: mechanism demonstrated, test-side causes
excluded by experiment, evidence bundle complete (including the
slow-motion recording per the bug-evidence standard).

**Output:** expected/actual/causal-chain in the report;
knowledge-base entry appended.
**Gate to 6:** understanding written. `fix` without a logged
`understand` stage is a contract violation.

## Stage 6 — `fix` (test-side causes only)

The minimal heal that addresses the established cause — selector
re-learning, settle/wait hardening, state isolation — per the bug-vs-heal
discipline (`test-repair` §"Bug-vs-Heal Discipline"). Semantic changes
(assertion re-baselining, flow-step drift) are proposed as
`operator-pending`, not applied. The heal must reference the stage-5
understanding; a fix that doesn't follow from the causal chain is
anchoring, not healing.

## Stage 7 — `verify`

5 consecutive passing full-file runs (the suite's own timeouts — proof
happens under real conditions). A heal that does not stabilise is
reverted, and the pipeline re-enters at the stage the instability
implicates (usually 4).

## Stage 8 — `done` — exit conditions

Exactly one of:

- **`healed`** — verified 5× green; understanding + fix + stability in
  the report.
- **`app-bug` (high confidence)** — expected behaviour, actual behaviour,
  and causal mechanism stated; test-side causes excluded by experiment;
  evidence bundle complete per the bug-evidence standard; test NOT
  modified.
- **`operator-pending`** — semantic change proposed with the
  understanding attached, awaiting human judgment.
- **`quarantined`** — irreducible flake per failure-diagnosis heal (f),
  ledger entry written.
- **`known-defect`** — the test (or its describe) carries
  `@known-defect`: an intentional red guarding a filed defect. Terminal on
  sight — no reproduce, no experiment, no fix. Normally caught at
  classification so no worker is dispatched at all; a worker that meets one
  returns it immediately with the tag as the note. Contract:
  [`test-identity.md`](../../achilles-protocol/references/test-identity.md) §2.
- **`unresolved`** — probe budget exhausted; exclusion list and partial
  understanding recorded. Never silent.

---

## Relationship to `failure-diagnosis`

This pipeline is the **ordering and gating contract**; `failure-diagnosis`
remains the technique library used inside the stages — its evidence-reading
discipline powers stages 1–2, its edge-case catalogue informs stages 3–4,
its heal strategies implement stage 6, its 5× stability rule is stage 7.
Workers load it via the Skill tool as before; nothing in its contract
changes for its other callers.

## Worked example (calibration case)

Two workers, same journey (logout), same 3/3-red baselines, different
truths — resolved correctly because both followed this order:

- **Desktop:** reproduce (trace) → evidence (screenshot: still on
  /account/orders, logged in; signout POST never sent) → context-probe
  (logout selector valid — click lands) → experiment (no-interception
  repro works; a NEVER-matching `page.route()` breaks it; settle-gate
  fixes it) → understand (interception disables HTTP cache → settle
  timing shifts → click races in-flight requests; knowledge written) →
  fix (optional networkidle gate) → verify (5/5) → **healed**.
- **Mobile:** reproduce → evidence (app actively navigates to /500 —
  a server-rendered error page) → context-probe (selectors valid) →
  experiment (out-of-harness repro passes 3/3 incl. harness headers —
  incident-shaped, server-side) → understand (expected: signout 200 →
  /login; actual: intermittent /500 during bad windows) →
  **app-bug, high confidence**, test untouched, recording watcher armed.

The pipeline's value is visible in the near-miss: the mobile failure
initially *looked* like an app bug on desktop too, and the desktop one
initially looked like selector drift. Stage order prevented both wrong
turns.
