---
name: ticket-driven-testing
description: Use when a ticket from an issue tracker (Linear, Jira) is the unit of QA work — a QA ticket paired to a dev ticket, a PR awaiting QA sign-off, a "test this feature" request naming an issue key, or any ask to verify acceptance criteria against a branch that is not yet merged. Also use when asked to automate the tests for a ticket, produce evidence for a ticket, or QA a feature branch.
---

# Ticket-Driven Testing

## Overview

A ticket is not a test plan. It is a claim about behaviour, a branch that allegedly implements it, and a set of acceptance criteria someone will sign off against. This skill turns that into: verified evidence, durable regression tests, and sentinel tests for every defect found.

**Core principle: build understanding by interacting, then assert what you understood.**

Read the diff early — it tells you **where to look** and **what is risky**. It does not tell you
what to assert. Those are different jobs, and conflating them is how you end up with a suite that
asserts a class token instead of a highlight, `inert` instead of visibility, and an element's
computed `position` instead of whether the user can see two bars.

The order that works:

```
diff  →  where to look, what is risky
live  →  what actually happens, in what sequence, at what moment
        ↳ THIS is what you assert
```

A test written from the diff binds to the implementation of one branch. A test written from
observed behaviour survives the implementation changing — and that matters, because the branch you
are testing may never ship in the form you read.

**REQUIRED SUB-SKILL:** the evidence run itself is `companion-mode`. This skill wraps it with the ticket, branch, and diff context that companion-mode's Phase 1 assumes you already have.

### The sequence

Whenever you list what you are going to do, list these. All nine, in this order. Mark any you are skipping and say why — an omitted step is a decision, and it belongs in the report.

```
1  Read the ticket AND its parent          → ACs verbatim, branch, PR
2  Check PR review state                   → unresolved CHANGES_REQUESTED is itself a finding
3  Worktree the branch                     → never switch a shared checkout
4  Read the whole diff                     → where to look; NOT what to assert
5  Reach the environment                   → preview auth, bypass tokens
6  Build understanding by interacting      → 6a exists → 6b drive+observe → 6c derive cases
                                            → 6d evaluate what is undesirable
7  Write durable tests + a sentinel per defect
8  RUN THE NEGATIVE CONTROL                → the suite MUST fail where the fix is absent
8b DISPATCH THE ADVERSARIAL REVIEW         → 5 subagents attack the tests; you do not self-assess
9  Report — then DISPATCH probe-verdict at the report itself
                                            → §8b attacks the tests; this attacks the claims
```

Step 8 is the one that gets dropped — an early draft of this skill omitted it 5/5 while an agent with no skill at all named it first. 8b delegates the check as well, so it does not rest on memory alone. A suite nobody has seen fail is not regression cover, and "12/12 green on the branch" is not evidence that it would have caught anything.

## Prerequisites

State these before starting; each has blocked a real run.

| Need | Why | If absent |
|---|---|---|
| A reachable app (deployed or locally runnable) | phases 5–8 all drive a browser | the method stops at the diff review, which is still worth doing |
| A Playwright project with a config + installed browsers | every run shells out to `playwright test` | no automation; evidence only |
| `git` with worktree support | phase 3 | work in a clone instead, never the shared checkout |
| A tracker, OR the ACs pasted by hand | phase 1 | paste them; phases 2–9 are unchanged |
| `jq` on PATH | the harness gate is a shell hook and exits FATAL without it | install it, or disable the gate explicitly |
| A subagent-capable runtime | §8b dispatches four reviewers | run the probes yourself, serially, and say so in the report |
| **A second environment WITHOUT the fix** | §8 negative control | see §8's fallbacks — do not silently skip it |
| An `E2E_MUTATION_CSS` / `E2E_MUTATION_INIT` hook in your page fixture | §8b mutation probe (grammar in §8b) | source-level mutation instead, if the app runs locally |

**Code samples in this skill use the `@civitas-cerebrum/element-interactions` `steps` API**
(`steps.verifyCount('el', 'Page', …)`), which needs that package's fixture and a page-repository.
On stock Playwright the equivalent is `expect(page.locator(...))` — the method is identical, only
the call shape differs.

**Cost.** One 3-AC ticket run literally costs roughly **6+ full suite runs** (branch baseline,
negative control, one per mutation, plus the no-op control) and **5+ agent dispatches**. At an
8-minute suite that is ~1.5–3h wall clock. Budget it, or scope §8b to the ACs that matter.

## The Contract

Produce all five. A run that stops after evidence is half a deliverable.

1. **A ticket brief** — acceptance criteria, the dev branch, the PR and its review state.
2. **A diff review** — findings ranked by severity, each one a sentinel candidate.
3. **An evidence bundle** — via `companion-mode`, verdict grounded in the ACs.
4. **Durable tests** — regression cover in the suite, plus one sentinel per confirmed defect.
5. **A negative-control result** — proof the tests fail where the fix is absent (§8). Without it you have tests that pass, not tests that discriminate.

### The sign-off gate

**You may not report a QA verdict until you have run the negative control (§8) and can state its result.**

An early DRAFT of this skill omitted this step every time it was tested, while an agent with no skill at all reached for it unprompted. The current text fires it (3/3), but it remains the step most worth gating.

So, before writing any verdict, answer these three in the report:

- Did the suite run against an environment **without** the fix?
- Which tests **failed** there, and which **passed**?
- For each one that passed — is it close-regression cover of pre-existing behaviour (fine), or does it fail to discriminate the feature (worthless as AC cover)?

"The tests are green on the branch" answers none of these. If you cannot run the control, say so explicitly in the verdict — an unverified suite reported as unverified is honest; reported as regression cover it is not.

## Phases

### 1. Ticket intake

Read the QA ticket **and its parent**. QA tickets carry the test scope; parent dev tickets carry the acceptance criteria, the design links, and the implementation notes. Neither alone is enough.

Extract four things: the **ACs verbatim**, the **branch**, the **PR**, and the **current status**.

**Tracker-agnostic.** This skill needs six capabilities from whatever tracker is in play. Discover what is actually connected — an MCP server, a CLI, a REST token — and map onto it. Never hard-code one vendor's tool names into the workflow.

| Capability | Linear | Jira | Fallback |
|---|---|---|---|
| Read a ticket | `get_issue` | `getJiraIssue` | REST / `curl` |
| Read its parent | `parentId` on the issue | `fields.parent` | same |
| Find the branch | `gitBranchName` field | branch in the dev-status panel, or the issue key as a branch prefix | `git branch -r \| grep -i <KEY>` |
| Find the PR | attachments / links | remote links, or the dev-status panel | `gh pr list --search "<KEY>"` |
| Post the report | `save_comment` | `addCommentToJiraIssue` | REST |
| Attach evidence | `prepare_attachment_upload` → PUT → `create_attachment_from_upload` | `attachFile` | REST multipart |
| Move status | `save_issue` with a state | `transitionJiraIssue` | REST |

Two portability rules that bite in practice: **status names are per-project**, so enumerate the available states rather than assuming a "Done" exists; and **the ticket key is the only reliable join** between tracker, branch and PR — expect the branch to carry the *dev* ticket's key while you work the *QA* ticket's, and confirm rather than infer.

If no tracker is reachable at all, the workflow still runs — the user pastes the ACs and the branch, and phases 2 onward are unchanged. Losing the tracker costs you intake and reporting, not the method.

### 2. PR state — a first-class QA signal

Check reviews and their timestamps against commit timestamps.

An **unresolved `CHANGES_REQUESTED`** on a ticket sitting in QA Testing is a finding in itself. A later commit may look like the fix, but "plausibly addressed" is not "re-approved" — report the gap rather than assuming it closed. Conversely, an automated reviewer's comment may already be fixed by a later commit; verify against the current code before repeating it as a defect.

### 3. Isolate the branch in a worktree

```bash
git worktree add ../<repo>-<ticket> origin/<feature-branch>
```

**Never switch the shared checkout.** Another session, another agent, or a running dev server may depend on the current branch. A worktree costs nothing and cannot disturb them.

Two consequences that bite later, both worth handling now:

- **The verification receipt (§8b) belongs in the SESSION checkout, not the worktree.** The harness
  gate resolves its workspace from the session's git toplevel, so a receipt written inside the
  worktree is invisible to it — you get denied while holding the receipt.
- **A fresh worktree re-stamps every file's mtime**, so any pre-existing receipt is instantly
  "older than the newest spec" and treated as stale. Create the worktree first, then run §8/§8b.

### 4. Review the diff

Read every changed file. For each AC, decide what would actually prove it:

- **Structural guarantees beat visual ones.** "Only one sticky bar" is proven by an element computing `position: static` at that breakpoint — it *cannot* pin. A screenshot only shows it *did not* pin this time.
- **Find the load-bearing attributes.** `data-*` hooks, `inert`, `aria-*`, state-marker classes. These are the stable selectors, and they usually already exist — check before proposing a source change.
- **Note what the diff deletes.** Removed feature flags, removed route mappings, removed components each imply a regression surface.

Record findings now, with severity. They become sentinels in phase 7.

### 5. Reach the environment

Feature branches deploy to preview URLs that are usually **protection-gated**. Symptom: `curl` returns HTTP 200 with a provider login page, not your app.

- Put the bypass token in a gitignored env file. Verify the gitignore pattern actually covers it.
- **Do not set the suite's base-URL variable in a shared env file** — it silently retargets every other suite. Pass it per command.
- For a CLI browser session, providers usually accept the token as a query parameter that sets a bypass cookie for the session.

### 6. Build understanding by interacting — simplest first

**Do not write the acceptance-criteria tests yet.** Work up to them. Each rung earns the next, and
a rung that surprises you is worth more than the rung that passed.

**6a — Does it exist?** The smallest possible test: the thing renders, and you can click it.
Nothing about the ACs. If this is awkward to write, the selectors are wrong and everything built on
them will be too — find that out now, not after twelve tests.

**6b — Drive it and watch.** Step through the flow in small increments with a screenshot *and* a
state dump at every step. Small enough to catch transitions: the interesting behaviour is between
the states, not at them. Record what you did not expect, even when it looks harmless.

> Worked example: stepping a page 0 → 400 → 560 → 700 → 1200px located a window where an element
> reported itself "stuck" while still `position: static` **and still half-visible and clickable**.
> No assertion had bounded that window, and no amount of diff-reading would have found it — the
> code looks correct at every line.

**6c — Derive the test cases from what you observed.** Now write them, and write them against what
a user would notice. Ask of each assertion: *if this passed but the feature were visibly broken,
would I still be green?* If yes, you asserted the mechanism instead of the outcome.

| Asserting the mechanism | Asserting the outcome |
|---|---|
| element has class `.is-active` | the active item is visually distinguished |
| `inert` attribute is absent | the control is visible **and** focusable |
| computed `position: static` | only one bar is pinned at the top |

Mechanism assertions are not wrong — they are often the only *stable* form, and the strongest
assertions in a suite are frequently structural. But a mechanism assertion is a **proxy**, and a
proxy needs the outcome asserted alongside it at least once, or nobody ever checks the proxy still
tracks the thing.

**6d — Only now, evaluate.** With a working model of the component, judge what is *undesirable*:
jitter, duplicated controls, focus traps, content that clips at a real breakpoint, states the
design never anticipated. This step is why 6a–6c come first — you cannot recognise "that looks
wrong" in a component you have only read about.

Then run `companion-mode` for the evidence bundle.

**Why this order.** Tests written straight from a diff bind to *that* implementation. Measured
cost: on one run, roughly nine desktop tests bound to a structural detail (`lg:static`) that exists
only on the feature branch — had it shipped differently, they would have needed rewriting rather
than catching the change. Tests derived from observed behaviour survive the implementation moving
underneath them.

> **Phases 1–9 are one sequence.** A run that stops at 7 has produced tests nobody has shown to discriminate the fix. 8 is not optional follow-up.

### 7. Durable tests and sentinels

Regression tests go in the project's suite, not the bundle. One test per AC, plus edge cases and close-regression cover for what the diff touched nearby.

For each confirmed defect, write a **sentinel**: assert the *correct* behaviour and mark it `test.fail()`. It fails today, keeps the suite green, and flips to a loud "expected to fail but passed" the moment someone fixes the bug — which is the signal to delete it.

```ts
test('TC_...[SENTINEL <TICKET>-D1]: <correct behaviour>', async ({ steps }) => {
  test.fail(true, 'Known defect: <what is wrong>. Delete this sentinel once fixed.')
  await steps.verifyCount('stateMarker', 'SomePage', { exactly: 0 })
})
```

**Pick a durable observable.** A sentinel is worthless if the app erases its own evidence — see the session-storage trap below.

**Feature gates must ask the ENVIRONMENT, never the page.** A gate that probes the feature's own
selector and skips when it is missing cannot distinguish "not deployed yet" from "regressed" —
they look identical. Measured: with the feature's root element hidden, a page-probing gate turned a
total AC regression into `2 skipped` instead of `2 failed`. The gate that keeps the nightly green
also blinds the suite to the thing it exists to catch.

Have the environment declare expectation instead, and default to fail-closed:

```ts
const FEATURE_EXPECTED = (process.env.E2E_FEATURE_<TICKET> ?? 'expected') !== 'absent'
// expected + present → run
// expected + absent  → FAIL   ← the regression
// absent   + absent  → skip   ← deliberate, annotated
// absent   + present → FAIL   ← shipped where it should not have
```

The environment without the feature opts out explicitly; removing that opt-out is what arms the
tests at release, and is a one-line change rather than an edit to every spec.

**Every absence assertion needs a positive control in the same test.** `count === 0`,
`toBeHidden` (which passes on ZERO matches) and "element not present" all pass on a 404, an
unhydrated page, a challenge page, and an environment where the feature never existed. Assert the
page is alive first — then absence means something.

If the suite runs against an environment where the feature is not deployed yet, gate it — with
**this** implementation, not one of your own. Copy it verbatim; §8's negative control depends on
the `GATE_OFF` escape being present.

```ts
// ONE gate. Env-declared, fail-closed, with all four outcomes in code.
// Ticket keys contain hyphens, which are illegal in env identifiers — normalise to underscores:
//   ABC-450 -> E2E_FEATURE_ABC_450
const FEATURE_ENV = 'E2E_FEATURE_ABC_450'          // <- your normalised ticket key
const GATE_OFF = process.env.E2E_FEATURE_GATE === 'off'   // §8 negative control uses this
// Legal values: 'expected' (default) | 'absent'. Anything else is a config error, not a silent pass.
const raw = process.env[FEATURE_ENV] ?? 'expected'
if (!['expected', 'absent'].includes(raw)) throw new Error(`${FEATURE_ENV} must be 'expected' or 'absent', got '${raw}'`)
const FEATURE_EXPECTED = raw === 'expected'

test.beforeEach(async ({ steps }, testInfo) => {
  // POSITIVE CONTROL FIRST. Absence assertions below are meaningless on a dead page.
  await steps.verifyState('pageRoot', 'SomePage', 'visible')

  const present = await steps.isVisible('featureRoot', 'SomePage', { timeout: 5000 })
  testInfo.annotations.push({ type: 'feature-gate', description: `expected=${FEATURE_EXPECTED} present=${present}` })

  if (GATE_OFF) return                                   // §8: run regardless, expect failures
  if (FEATURE_EXPECTED && !present) {
    throw new Error('feature expected on this environment but absent — this IS the regression')
  }
  if (!FEATURE_EXPECTED && present) {
    throw new Error('feature not expected here but rendered anyway')
  }
  if (!FEATURE_EXPECTED) test.skip(true, `not deployed here (${FEATURE_ENV}=absent)`)
})
```

| `FEATURE_EXPECTED` | feature present | outcome |
|---|---|---|
| true | yes | run |
| true | **no** | **FAIL** — the regression |
| false | no | skip, annotated |
| false | **yes** | **FAIL** — shipped where it should not have |

The environment lacking the feature sets `E2E_FEATURE_<KEY>=absent` explicitly. **Removing that one
line is what arms the tests at release** — no spec edits.

Why not probe the page and skip? Because that cannot tell "not deployed" from "regressed". Measured:
with the feature's root element hidden, a page-probing gate turned a total AC regression into
`2 skipped` rather than `2 failed`.

### 8. Prove the tests discriminate the fix — the negative control

A green suite on the feature branch proves the assertions pass *where the feature exists*. It does not prove they would fail where it doesn't. Those are different claims, and only the second one makes the suite regression cover.

**Run the suite against an environment without the fix and require it to FAIL.**

Production before the PR ships is the usual target, but it is not the only one and it is not always
safe. In order of preference:

1. **A preview of the merge-base commit** — same infrastructure, no fix. Cleanest.
2. **A local build of `main`** — needs the app runnable locally.
3. **Production** — only when the suite is READ-ONLY. A suite that creates orders, users or
   records will create them in production. Check before pointing it there; this is the one step in
   this skill that can cause real-world damage.
4. **Feature-flag the fix off**, if it is flagged.

If none is available, say so in the verdict: *"suite is green but unverified — not regression
cover"*. That is honest. Silently skipping the control and reporting regression cover is not.

A gated suite will skip there, which proves only that the gate works. So give the gate an explicit off switch and use it:

```ts
const FEATURE_GATE_DISABLED = process.env.E2E_FEATURE_GATE === 'off'
test.skip(!present && !FEATURE_GATE_DISABLED, 'Not deployed on this environment yet.')
```

Read the result per test, not in aggregate. Three outcomes, three meanings:

| Outcome without the fix | Meaning |
|---|---|
| **Fails** | The test discriminates the feature. This is what you want from AC cover. |
| **Passes** | Either it is close-regression cover of *pre-existing* behaviour (correct — filter drawers and sort controls should pass on both), or it asserts nothing the feature changed and is worthless as AC cover. Decide which; do not assume the charitable reading. |
| **Skips** | You forgot the off switch. The run told you nothing. |

**`test.fail()` sentinels cannot pass this control**, and it is worth knowing why before it confuses you: on an environment without the feature they fail because the element is *missing*, not because the defect is *present* — and `test.fail()` reports that as passed. A sentinel is indistinguishable between "bug reproduced" and "feature absent". The feature gate is what keeps that harmless; nothing else does.

#### 8b. Dispatch the adversarial test review

Do not self-assess your own tests. **Dispatch subagents whose mission is to attack them.** The rationale is separation of duties, not a measured effect: a reviewer that did not write the tests has no stake in their looking good. NOT claimed: that delegation outperforms instruction. Delegation was never run as its own arm, so there is no evidence either way.

Dispatch these **five in parallel**, scoped to the diff and the ACs. Anything outside those two is out of scope — an unbounded critic returns "you didn't test Safari 14 on 3G" forever.

| Mission | Question it must answer | Required output |
|---|---|---|
| `probe-mutation` | For each AC, what concrete one-line change to the app would break it — and does any test catch it? **Make the change, run the suite, revert.** | Per mutation: the diff hunk, and `caught` / `survived` |
| `probe-coverage` | Which AC clauses and which hunks of the diff have **no** assertion pointing at them? | Gap list keyed to AC text and `file:line` |
| `probe-assertions` | Does each assertion prove a structural guarantee, or did it observe one passing render? | Per assertion: `structural` / `incidental`, with the reason |
| `probe-value` | Is each test **worth keeping** — does it protect behaviour a user would notice losing, at a maintenance cost the risk justifies? | Per test: `keep` / `merge` / `delete`, with the reason |
| `probe-outcome` | For each AC: is the **user-visible outcome** asserted anywhere, or only a mechanism standing in for it? Would the suite stay green with the feature visibly broken? | Per AC: `outcome-asserted` / `proxy-only`, naming the proxy |

**On `probe-value` specifically.** The other three ask whether a test *works*; this one asks whether it should *exist*. A test can catch its mutation and still be a liability. The four verdicts it hunts for:

- **Redundant** — another test already fails for the same cause. The second one adds run time and a second thing to update, not a second signal.
- **Testing the framework** — asserting that the router routes or the component library renders. That is someone else's test suite.
- **Cost exceeds risk** — a slow, fragile, environment-sensitive test guarding something trivial or cosmetic. Every future failure of it will be triaged, and most will be noise.
- **Unfalsifiable in practice** — technically green, but it would pass in nearly every world, including broken ones. `probe-mutation` catches the strong form; this catches the weak form the mutation happened not to touch.

Bias it toward **`merge` over `delete`**, and require evidence for either — name the test that already covers it, or the specific reason the risk does not warrant the cost. Deleting cover is the one recommendation here that can lose information permanently, so an unevidenced `delete` is a rejected finding. Coverage counts are not the goal: twelve tests where six would do is worse than six, because the six carry the same signal and half the maintenance.

**The dispatch will be DENIED unless you cite the return schema.** `probe-` is a schema-mapped role: `subagent-schema-preread-gate.sh` blocks any `probe-*` dispatch whose brief does not name `schemas/subagent-returns/probe.schema.json`. This was found the only way it could be — by following this section and being blocked three times in a row. Use this shape:

```
Agent(description: "probe-mutation-<slug>", prompt: "
  ADVERSARIAL REVIEW — <mission>. Your job is to find defects, not to approve.
  Return shape: schemas/subagent-returns/probe.schema.json. Return `handover`
  ({role, status, next-action} — all three required), `findings-emitted`,
  `finding-ids` (REQUIRED whenever status is "findings-emitted"), and
  `summary`. Omitting finding-ids is the easy mistake: it is conditionally
  required exactly when the probe succeeds in finding something.
  <files to read> <the ACs> <the specific question>
  MANDATORY: silence is a failed dispatch. Return findings, or state exactly
  what you examined and why you found nothing. A vague approval is a failure.
")
```

**Non-negotiables for these dispatches:**

- **They must execute, not just read.** The most dangerous defect found in the run this skill came from was a sentinel that *passed while the bug was live* — the destination page consumed the session-storage flag it asserted on before the assertion ran. No amount of reading would have caught that; running it did.
- **Prove each mutation APPLIED.** An un-applied mutation is indistinguishable from an uncaught
  one, and reads as a coverage hole that does not exist. This cost a false finding: a mutation was
  reported as surviving when its injection had silently never run (a bare string passed where the
  API wanted `{ content }`). Give every mutation a selector that must match once it is live, and
  assert that before believing any "survived" result — the same control logic as `noop`, applied
  per mutation instead of per run.
- **Do not target zero survivors.** A survivor with a written, defensible reason is a decision; a
  survivor without one is a hole. Demanding zero pushes you into asserting design tokens and other
  over-fitted details, producing tests that fail on legitimate change. When a mutation survives for
  a good reason, narrow the test's CLAIM rather than widening its assertion — and rename the test
  so it no longer promises what it does not check.
- **Mutation needs a target you can break.** Source-level mutation needs a locally runnable app. Where the suite runs against a *deployed* environment you cannot rebuild, mutate at the **browser** level instead: inject CSS/JS that re-creates the broken state the AC forbids, then check the suite goes red. Weaker in one way (it binds to behaviour, not to the source change) and stronger in another (it tests the deployed artifact). Either way, **include a no-op mutation as the harness's own control** — if the suite goes red with nothing injected, the harness is breaking the page and every other result in the run is void.
- **Browser-level mutation needs a hook in the project's fixture**, because a Playwright config cannot add one. Two variables, exact names and grammar:

  | Variable | Contains | Applied |
  |---|---|---|
  | `E2E_MUTATION_CSS` | a CSS string | `page.addStyleTag({ content })` on every `load` |
  | `E2E_MUTATION_INIT` | a JS string | `page.addInitScript({ content })` — note the object form; a bare string silently does nothing |

  ```ts
  // in your `page` fixture — inert unless the driver sets these, so it costs nothing when unused
  if (process.env.E2E_MUTATION_INIT) await page.addInitScript({ content: process.env.E2E_MUTATION_INIT })
  if (process.env.E2E_MUTATION_CSS) {
    const css = process.env.E2E_MUTATION_CSS
    page.on('load', () => { page.addStyleTag({ content: css }).catch(() => {}) })
  }
  ```

  The `noop` control is simply both variables empty. The applied-check is a CSS selector that must
  match once the mutation is live (e.g. `[data-x] [inert]`) — assert it before believing any
  "survived" result. Add this hook as a **prerequisite**, not a mid-probe discovery: without it,
  §8b's first mission is not runnable at all on a deployed-only project.
- **Silence is not a pass.** A reviewer that reports nothing is indistinguishable from a lazy one. Require the shape: findings, **or** an explicit *"I attempted these N mutations and the suite caught all N"* with the list. An empty return is a failed dispatch, not a clean bill of health.
- **A surviving mutation is a finding, not a suggestion.** It means a stated AC has no test that can fail for it. Fix the test before reporting the verdict.

Write the outcome to `.achilles/adversarial-verification/<ticket-key>.json`:

```json
{
  "ticket": "<KEY>", "ranAt": "<ISO-8601>",
  "negativeControl": { "environment": "<url>", "failed": 5, "passed": 1, "skipped": 0 },
  "mutations": [{ "ac": "AC-2", "hunk": "…", "caught": true }],
  "coverageGaps": [], "incidentalAssertions": [], "lowValueTests": []
}
```

That receipt is what the harness gate looks for. **The gate DENIES a tracker transition to a
completed state without it**, so an adopter who has not read this section meets it as an
unexplained denial — kill-switch `CIVITAS_DISABLE_ADVERSARIAL_GATE=1` if you need out.

**Gitignore `.achilles/`.** The receipt is a local run artifact: git does not preserve mtimes, so a
committed receipt would arrive on CI with a rewritten timestamp and defeat the staleness check
outright. It is evidence for the run that produced it, not a shared artifact. Writing it by hand without running the probes defeats the check entirely — and the failure it catches is *your own*.

### 9. Live observation — watch it, don't just assert it

Assertions confirm what you thought to ask. Watching the page reveals what you didn't. Before trusting a green suite, drive the flow once by hand — screenshot **and** probe state after **every** action, not just at the end.

Step in increments small enough to catch transitions, and capture both a screenshot and a state dump at each step:

```
y=0     header=40,143   pcp=631,712   pos=static  inert=1  stuckMarker=0
y=400   header=0,103    pcp=231,312   pos=static  inert=1  stuckMarker=0
y=560   header=0,103    pcp=71,152    pos=static  inert=1  stuckMarker=1   ← defect window opens
y=1200  header=0,103    pcp=-569,-488 pos=static  inert=0  stuckMarker=1   ← merge completes
```

That trace located a defect window no assertion had bounded: between y≈560 and y≈700 the row reports itself stuck while still `static` **and still half-visible under the header** — so a user can click a pill that is about to report the wrong telemetry. A pass/fail test would never have surfaced the *width* of that window.

**Live comparison.** Where the change is visual, drive the same URL and the same scroll positions on the environment *with* the fix and the one *without*, and diff the screenshots. Differences you cannot explain are findings.

**Assert a control element, always.** A live probe that reports "the feature's selectors are absent" is ambiguous: the feature may be missing, or *the page may never have loaded*. Bot protection, an auth wall or a CDN challenge all render a page where every product selector is absent — and it looks exactly like a shipped-but-disabled feature.

Include one element in every probe that must exist on **any** build of the page (a header, a footer, `<main>`). If the control is missing too, you are not looking at the app and every conclusion from that probe is void. Note also that a suite reaching production via an allowlisted header (`x-e2e-test`) proves nothing about whether an *ad-hoc* browser can — the CLI session gets challenged where the suite sails through.

## "Show me" — demonstration runs

**When the user says "show me", "let me see it", "watch it run", "demo this", or anything of that shape, they are not asking for a pass/fail summary. They are asking to watch.** Deliver a run that is:

- **headed** — a real browser window,
- **born slow** — `launchOptions.slowMo` ≥ **1500ms** per action, so the native real-time recording is watchable as-is. Prefer the project's existing hook (`E2E_SLOWMO=<ms>`) where it has one. Same standard `self-repair` applies to bug recordings; 500ms proved too fast to track individual actions.
- **recorded** — video always on, and **serial** (`workers: 1`), because parallel workers open several windows at once and produce interleaved footage nobody can follow,
- **retry-free** — a retry overwrites the recording of the attempt they watched.

**Use the shipped runner — do not hand-write this per project:**

```bash
npx achilles-show <path|--grep …>        # every arg forwards to `playwright test`
```

`achilles-show` derives a run from the project's existing `playwright.config.*`, applying exactly the overrides above, and writes mp4s to `show-recordings/<timestamp>/`. Nothing in the project's own config changes, and there is no second config to maintain or drift.

Never flag-patch the CI config to achieve this by hand. `slowMo` multiplies every action's wall time, so CI-tuned timeouts fire spuriously; demo settings leaking into CI are actively harmful.

**Never slow footage down afterwards.** The slow-down happens at the source — pacing the actions treats the cause, time-stretching the video treats the symptom. If actions still blur, raise `slowMo` and re-record.

**Container format is a separate concern from pacing.** Transcoding webm → mp4 changes container and codec, not timing, so it does not conflict with the born-slow rule. `achilles-show` handles this: it resolves `ffmpeg-static` → `ffmpeg` on `PATH` → keeps the webm and says so explicitly. Never silently ship a format the user did not ask for.

Gitignore `show-recordings/` — demonstration footage is not a repo artifact.

**If a project needs behaviour `achilles-show` does not provide**, that is a gap in the runner, not a licence to hand-roll a per-project config. Fix it in the package — see `contributing-to-element-interactions`.

## Traps

Each of these cost a failed run or a wrong conclusion in practice.

| Trap | What happens | Fix |
|---|---|---|
| **Suite's default viewport** | ACs are signed off at one size; the project's device preset is another. Behaviour genuinely differs. | Pin the viewport explicitly in `beforeEach`. Cover the other size as its own test. |
| **Late-hydrating components** | Client-rendered regions (search/results grids) are absent when your first assertion runs; your feature gate checked an SSR'd element and passed. | `waitForState` on the client-rendered container before asserting against it. |
| **Self-consuming observables** | A sentinel watches a session-storage flag; the destination page's effect reads and deletes it before you assert. Test passes, bug is live. | Assert a state that persists — a DOM state marker at the source, not a message in flight. |
| **Assumed default states** | You click a toggle expecting it to open; it was already open, so you closed it. | Read the initial state, assert the round-trip, don't assume a starting position. |
| **Unredacted HAR** | Your bypass token appears in the request headers of every entry — hundreds of copies inside a bundle you are about to commit. | Redact by header name and strip response bodies. This also shrinks the HAR by ~20×. |
| **Bundle size** | Trace + video + HAR + an HTML report that duplicates all three easily exceeds 200MB. | Promote trace/video to the bundle root, drop the duplicate report, slim the HAR. Decide deliberately whether the directory is committed or gitignored. |
| **Blocked postinstall scripts** | pnpm blocks dependency build scripts by default and only prints a warning. A package whose binary is fetched in `postinstall` resolves to a path that does not exist, failing at call time, not install time. | Read the "Ignored build scripts" warning. Add the package to `pnpm.onlyBuiltDependencies`, or run its installer directly. |
| **Bare `spec.ts` is not collected** | Playwright's default `testMatch` (`**/*.@(spec\|test).ts`) requires a prefix before `.spec` — a file literally named `spec.ts` matches nothing and the run reports "No tests found". | Set `testMatch: 'spec.ts'` in the bundle-local config, or prefix the filename. |
| **HTML report nested in `outputDir`** | The HTML reporter wipes its folder before writing and refuses to start when it sits inside the test output folder. | Point `outputFolder` outside `outputDir`. |
| **Bot protection reads as "feature absent"** | An ad-hoc browser hitting production gets a CDN challenge page. Every feature selector is absent, so the probe looks like a clean "not deployed yet" — while you are actually looking at a block page. | Probe a control element that exists on any build (header/footer/`<main>`). Control missing ⇒ conclusion void. See §9. |
| **Green on the branch mistaken for regression cover** | The suite passes where the feature exists, and nobody checks it fails where it doesn't. Assertions that key off something unrelated to the change pass in both places. | Run the negative control (§8) and read it per test. |
| **Diagnosing against the wrong control** | A check fails on your PR and passes on someone else's, so you conclude your change caused it — when the real variable was the *author*, the base commit, or the branch age. You then "fix" something that was never broken. | Pick a control that differs from yours in **one** dimension. Comparing to another PR by the same author, or to your own branch before the change, is a control; comparing to a different person's PR is not. |
| **Test tooling reaching outside the test directory** | Adding a dependency, a lockfile entry, or a package-manager setting for a test convenience changes how *every* app in the workspace installs or builds. Local runs never see it; CI does. | Keep test tooling inside the test package. If a change edits the root manifest or the lockfile, that is the moment to ask whether the feature justifies workspace-wide reach — usually a runtime fetch or an optional dependency does the same job with no blast radius. |

Those last two are the same failure in different clothes: **applying less rigour to your own changes than to the code under test.** A QA agent that runs a negative control on the application and then pushes an unverified packaging change has simply moved the untested surface, not removed it.

## Framework gaps

When an assertion has no API surface, do **not** silently drop to raw driver calls. Assert the strongest expressible proxy, capture the rest as screenshots, and record the gap.

Known gap: **document-level geometry.** "No horizontal clipping" is `documentElement.scrollWidth > clientWidth`, and step-based frameworks generally have no element-free assertion for it. Proxy: assert every control stays present and reachable at each width, and let the per-width screenshots carry the visual proof.

**REQUIRED SUB-SKILL:** to close a gap rather than work around it, use `contributing-to-element-interactions`.

## 9. Report — and have the report reviewed before it ships

**Dispatch one more probe at the REPORT itself, before it reaches a human.** §8b attacks the
tests; nothing there attacks the verdict. The verdict is the artifact a person acts on, and it is
the last place an unearned claim can hide.

```
Agent(description: "probe-verdict-<ticket>", prompt: "
  ADVERSARIAL REVIEW — audit this QA verdict against its evidence. Find overstatement.
  Return shape: schemas/subagent-returns/probe.schema.json (handover{role,status,next-action},
  findings-emitted, finding-ids, summary).
  <the draft report> <the specs> <the negative-control output> <the mutation report>
  For EACH claim: quote it, name the evidence that would support it, and state what exists.
  Hunt for: an AC called 'verified' where only a proxy was asserted; a suite called regression
  cover with no negative control; sample sizes not disclosed; 'always/never/cannot' on one run;
  a test cited as covering something it does not assert.
  MANDATORY: silence is a failed dispatch. Return findings, or list every claim you checked.
")
```

This exists because it was skipped and it cost something real: a shipped verdict declared two
acceptance criteria verified when the suite asserted a *mechanism* for one (`inert`, not
visibility) and a *tautology* for the other (a URL segment a server-side rewrite never produces).
Both passed every test. Only an audit of the claims against the evidence found them.

If the report has already been posted when a finding lands, **correct it in place and say what
changed**. A quietly edited verdict is worse than the original error.

## Reporting

Report defects the diff review found even when every AC passes — they are the value a human reviewer could not get from a green suite. Separate them clearly from AC verdicts: **"all three ACs pass, and here are four defects"** is a coherent and common outcome.

Never silently upgrade a defect into an AC failure, or silently drop one because the ACs passed.

## Baseline testing

Three pressure scenarios, run against subagents with and without this skill. The results are worth stating plainly, because two of them argue *against* parts of the skill.

All "with the skill" runs below are against the current text, after the harness bug described further down was fixed. Sample sizes are given because they are small.

| Scenario | Without the skill | With the skill |
|---|---|---|
| **Green suite, 2h to sprint end, "are we done?"** (n=3) | Refused to sign off. Named "verify the tests can fail" as its **first, non-negotiable** action. Deferred reading the diff to step 5, after testing. | Refused to sign off, **3/3**. Negative control as **step 1**, §8b probes step 2, results read per test, receipt written. |
| **Start QA; shared checkout is dirty, teammate's server running** (n=1) | Already correct: `git worktree add`, no checkout, no stash, isolated port. | Same, plus PR-state check, diff-before-app ordering, the control-element probe, and passing the base URL per command rather than into a shared env file. |
| **All 3 ACs pass; diff contains a telemetry defect** (n=1) | Reported the defect, flagged the A/B implications, filed a linked ticket. Set the ticket **Done**. | Same, plus a `test.fail()` sentinel — and **declared "negative control: NOT RUN" as an outstanding gate**, refusing to close a ticket whose suite has not been shown to discriminate the fix. |

**What this establishes.** The competent baseline is high. Worktree isolation and reporting an out-of-scope defect are things a good agent already does — those sections codify existing practice rather than correcting a failure, and should be read as reference, not as discipline.

What the skill measurably adds: **the negative control** (absent from the draft, present 3/3 now), **diff-before-testing ordering**, **PR review-state as a QA signal** (never mentioned in any baseline), **`test.fail()` sentinels**, and **not self-closing a ticket**.

The third scenario is the strongest result: the agent did not merely remember the control, it **surfaced its absence as a blocker** and declined to close on that basis. That is the behaviour the harness gate enforces, reached from instruction alone.

### How step 8 was made to fire — and the harness bug that hid it

The **draft** version of this skill omitted the negative control every time: five runs of scenario 1, five identical answers, each an otherwise excellent plan that never checked whether the tests could fail. An agent with no skill at all named that check first, unprompted — so the draft was actively *worse* than nothing on this dimension.

Five revisions were made and each appeared to change nothing. **They changed nothing because none of them reached the agent.** Skills load from the installed path; the edits were being made to the repository copy. Same filename, different file. Every "failed intervention" re-ran the identical unmodified draft.

Once the installed copy was actually synced, the revised skill put the negative control at **step 1** and the §8b probes at step 2, unprompted, in the same scenario that had failed five times.

Two things worth keeping from that:

- **The revisions work.** Which one did the work is unknown — the sequence block, the sign-off gate, the corrected contract count and §8b all landed together. If you need to attribute it, re-test them individually.
- **A test harness needs its own negative control.** One run against a deliberately corrupted skill would have shown the output never varied, and would have caught this immediately. The methodology demands exactly that check of the application under test (§8) and it applies with equal force to the rig you are testing *with*. Verifying that your test setup can register a change is not optional; it is the first thing to establish.

  The retraction supplied that control after the fact: draft omitted the step 5/5, corrected text includes it 3/3. Output varied with input, so the rig is now known-live. Establish that *before* interpreting a result, not after — five runs were spent on the other order.

The harness gate (`adversarial-verification-gate.sh`) is therefore **defence in depth, not the sole mechanism** — the instructions do work. It still earns its place: instructions are advisory and a gate is not, and the gate's own tests are independent of whether a skill loaded correctly.

Everything above in the table is one round of testing, not proof: three scenarios, one sample each, one model.
