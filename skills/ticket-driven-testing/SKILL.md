---
name: ticket-driven-testing
description: Use when a code change is the unit of QA work — a ticket paired to a PR, a branch awaiting sign-off, OR a developer who has just finished building something and asks for it to be tested, verified, checked, covered, or QA'd. Triggers include "test this", "verify my changes work", "can you check this", "write tests for what I just built", "is this covered", "QA this before I open a PR", as well as any ask naming a tracker issue key. Covers UI verification, test automation, and adversarial review of the testing itself.
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

Whenever you list what you are going to do, list these. All ten, in this order. Mark any you are skipping and say why — an omitted step is a decision, and it belongs in the report.

```
0  RE-ENTER FOR THIS TICKET                 → loaded ≠ performed. One ticket, one run of 0–9
1  Read the ticket AND its parent          → ACs verbatim, branch, PR
2  Check PR review state                   → unresolved CHANGES_REQUESTED is itself a finding
3  Worktree the branch                     → never switch a shared checkout
4  Read the whole diff                     → where to look; NOT what to assert
5  Reach the environment                   → preview auth, bypass tokens
6  Build understanding by interacting      → 6a exists → 6b drive+observe → 6c derive cases
                                            → 6d evaluate what is undesirable
7  Write durable tests + a sentinel per defect
8  RUN THE NEGATIVE CONTROL                → the suite MUST fail where the fix is absent
8b DISPATCH THE ADVERSARIAL REVIEW         → 6 subagents attack the tests; you do not self-assess
8c SCORE the testing itself (probe-rigour, 0-3 x6, blocking floor)
8d COMMIT OR DISCARD                       → CX/revenue impact proposes; a human confirms; discard is the default
9  Report — then DISPATCH probe-verdict at the report itself
                                            → §8b attacks the tests; this attacks the claims
```

Step 8 is the one that gets dropped — an early draft of this skill omitted it 5/5 while an agent with no skill at all named it first. 8b delegates the check as well, so it does not rest on memory alone. A suite nobody has seen fail is not regression cover, and "12/12 green on the branch" is not evidence that it would have caught anything.

### 0. One ticket, one run — the skill being loaded is not the sequence being performed

**Every ticket gets its own run of steps 1–9. A skill already loaded in this session does NOT
mean the sequence has been performed for the ticket in front of you now.**

Activation here is intent-triggered, so the only thing that re-fires it on the second ticket is
your own judgement — and the second ticket is exactly where that judgement fails. The skill IS in
your transcript. The method IS still there to read. "I'm already in ticket-testing mode" is a
locally reasonable inference and a globally wrong one, because *mode* is a property of the
session and *the sequence* is a property of the ticket. Those two came apart the moment the
operator handed you a second ticket.

What that costs, from the run that produced this rule: a session ran the method properly for one
ticket, then picked up a second and ran an ad-hoc verification instead. It posted a verdict to
the tracker with measured numbers and **zero artifacts** — no screenshots, no recording, no
trace, no bundle. Nothing objected; the user did. When the same work was redone under
`companion-mode`, the proper run immediately surfaced two things the ad-hoc pass had missed:
artifact paths that collided so a second environment's run silently overwrote the first's
video/trace/HAR, and a live deployment protection-bypass token sitting unredacted in the captured
HARs. Neither was a subtle finding. Both were invisible without the bundle contract.

Re-enter when **any** of these is true, without waiting to be asked:

- a different ticket key, issue, or branch than the one you last ran the sequence for;
- the same ticket after the branch moved (new commits, a force-push, a rebase);
- a ticket you are picking up mid-flight from someone else's work — including one already sitting
  in a QA column with an open PR, which is the shape that most reads as "just confirm it".

Announce the re-entry in one line ("re-entering ticket-driven-testing for <key>") and restate the
sequence for that ticket. Restating it is cheap; the cost of the wrong inference is a verdict
with nothing behind it.

**Harness-enforced by [`hooks/evidence-bundle-gate.sh`](../../hooks/evidence-bundle-gate.sh) — and
read what it does NOT do.** The gate cannot see whether you re-ran the sequence; it can only see,
per ticket, whether the Contract's item-3 evidence bundle exists. That check is bound to the
ticket key rather than to the session, so a second ticket cannot ride on the first ticket's
bundle. It **DENIES** a terminal transition or a published PR with no bundle for that ticket.
On a verdict-shaped **comment** it only **WARNs** — which means the failure described above, where
the artifact-free verdict was posted as a comment, would have been flagged and not blocked. The
grading is deliberate (a bundle-less verdict has one honest form, per §"Prerequisites"), but it is
a trade. Do not read the gate as a reason to stop watching for this yourself.

## Two entry points, one method

Steps 6–9 are identical either way. Only the front half differs, because only the front half
depends on where the acceptance criteria and the environment come from. "Identical either way"
means identical between the two *entry points* — not shared across *tickets*. Step 0 still
applies: each ticket runs its own 1–9 whichever column it arrived in.

| | **A — ticket-driven** | **B — dev-triggered** |
|---|---|---|
| Trigger | a tracker issue, a PR awaiting sign-off | *"I've finished this, can you test it"* |
| 1 | ticket + parent → ACs verbatim | **the change set → ACs derived and CONFIRMED (§1b)** |
| 2 | PR review state is a QA signal | skip if no PR exists; say so |
| 3 | worktree the branch | **§3b — uncommitted work is not in a worktree** |
| 5 | deployed preview, bypass tokens | the dev's local server |
| 8 | negative control: find an env without the fix | **the merge-base. The strongest form, and nearly free** |

Entry B is not a lighter version. It is the same bar reached by different means — and on two
dimensions it reaches a **higher** one, because a local checkout gives you things a deployed
preview cannot.

### 1b. Derive the ACs — then get them confirmed

Entry A reads acceptance criteria. Entry B has none: the dev has a diff and an intention, and the
intention is in their head.

Do NOT proceed on ACs you invented. A suite built from assumed criteria is green against *your*
model of the feature, and its greenness says nothing about theirs — you will have automated your
own misunderstanding and reported it as cover.

1. Read the whole diff, then write **3–6 candidate ACs** as observable, user-visible statements.
   "Clicking Apply closes the drawer and the result count updates" — not "the `useFilters` hook
   dispatches correctly".
2. Put them to the dev **in one message**, numbered, and ask what is missing or wrong. One round
   trip, not an interview.
3. Ask the two questions the diff cannot answer: **what should NOT change** (the regression
   surface), and **what would worry you most if it broke** (the risk ranking that decides where
   §8b's budget goes).
4. Record the confirmed list verbatim. From here it is Entry A: those are the ACs, and §9's report
   is written against them.

If the dev is unavailable, proceed on the derived list, **label every AC `derived, unconfirmed`
in the report**, and never state a criterion as verified without saying whose criterion it was.

### 3b. Uncommitted work defeats a worktree — check first

`git worktree add` checks out a **commit**. Uncommitted changes stay in the original working tree,
so a worktree built to isolate the dev's work can silently contain everything except their work.
The tests then pass against the pre-change code and prove nothing. This is the entry-B version of
the negative-control failure, and it looks identical to success.

```bash
git status --porcelain          # empty? worktree is safe — use it
git stash list                  # work parked here is not in a worktree either
```

Three cases, and you must say which one you are in:

| State | Do |
|---|---|
| clean | worktree normally (§3) |
| uncommitted changes | **test in place.** Say so, and do not switch branches — the dev is still working here |
| dev offers to commit/stash | worktree the commit, and confirm the diff you review matches what they meant to ship |

### 8·B. The merge-base IS the negative control

Entry A hunts for an environment without the fix and often settles for a documented fallback.
Entry B has the ideal one locally, so there is no excuse for skipping it:

```bash
git merge-base HEAD origin/main            # the without-fix commit
git worktree add ../nofix <that-commit>    # build and run the NEW suite against OLD code
```

The suite MUST fail there, and you must read it **per test**. Any test that passes in both places
is not testing the change — it is testing something that was already true.

This is the strongest form of §8 and it is nearly free here. **A dev-triggered run that skips the
negative control has no excuse and should not report cover.**

### Source-level mutation is available here

`achilles-mutate` injects at the browser because deployed previews cannot be rebuilt. Locally you
can edit the source, rebuild, and run — which binds the mutation to the actual change rather than
to a behaviour that resembles it. Prefer it when the app runs locally. The rules are unchanged: a
`noop` control, owner-based classification, and proof each mutation applied (**revert every
mutation before moving on** — a mutation left in the tree is a defect you introduced).

## Prerequisites

State these before starting; each has blocked a real run.

| Need | Why | If absent |
|---|---|---|
| A reachable app (deployed or locally runnable) | phases 5–8 all drive a browser | the method stops at the diff review, which is still worth doing |
| A Playwright project with a config + installed browsers | every run shells out to `playwright test` | no automation; evidence only |
| `git` with worktree support | phase 3 | work in a clone instead, never the shared checkout |
| A tracker, OR the ACs pasted by hand | phase 1 | paste them; phases 2–9 are unchanged |
| `jq` on PATH | the harness gate is a shell hook and exits FATAL without it | install it, or disable the gate explicitly |
| A subagent-capable runtime | §8b dispatches six reviewers | run the probes yourself, serially, and say so in the report |
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

Produce all five, **for each ticket**. A run that stops after evidence is half a deliverable, and
a second ticket that reuses the first ticket's deliverables has produced none of its own.

1. **A ticket brief** — acceptance criteria, the dev branch, the PR and its review state.
2. **A diff review** — findings ranked by severity, each one a sentinel candidate.
3. **An evidence bundle** — via `companion-mode`, verdict grounded in the ACs. Named for this
   ticket, containing this ticket's artifacts, redacted per `companion-mode` §"Redaction". Numbers
   in a report are not evidence: evidence is what someone else can re-open and disagree with.
4. **Verified tests** — one per AC plus one sentinel per confirmed defect, written and proven
   against the negative control. Whether they are **committed** to the suite or **discarded**
   into the evidence bundle is decided in §8d — and discard is the default.
5. **A negative-control result** — proof the tests fail where the fix is absent (§8). Without it you have tests that pass, not tests that discriminate.

### The sign-off gate

**You may not report a QA verdict until you have run the negative control (§8) and can state its result.**

**You may not report a QA verdict for a ticket that has no evidence bundle of its own.** This is
item 3 above, restated at the boundary where it gets skipped. If the run genuinely captured
nothing — an unreachable app, a diff review only — say *that* in the verdict and scope the claim
to what you actually did. An unevidenced report labelled unevidenced is honest; the same report
labelled verified is not.

For entry B the sign-off boundary is **opening the PR**, not a tracker transition — that is the
moment the work is presented to others as done. Everything the contract requires applies there
unchanged.

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

**6e — Inspect every screenshot for design quality.** Evidence screenshots are not just functional
proof — they are a visual inspection surface. After capturing them, review each one as a designer
would. A screenshot that proves "the error alert appeared" can simultaneously reveal that the
alert's container has broken padding.

Check for:

- **Padding and spacing symmetry** — are horizontal/vertical insets consistent between the left
  and right edges? Between the top and bottom? Compare the element's spacing to its siblings and
  to the container edges.
- **Alignment** — do elements that should be aligned (buttons, labels, icons) actually line up?
  Is text baseline-aligned where it should be?
- **Clipping and overflow** — is any content cut off by a parent's `overflow: hidden`? Are
  rounded corners rendering correctly at the edges?
- **Visual hierarchy** — does the layout still read correctly? Is the primary action visually
  dominant? Are secondary elements appropriately subdued?
- **State transitions** — compare the "before" and "after" screenshots. Does the layout degrade
  when the component changes state (expanding, showing an error, loading)?
- **Responsive integrity** — at the tested viewport, does the layout look intentional or does it
  look like it squeezed to fit?

This step catches defects that no functional assertion will find — the test that asserts
"the error alert is visible" passes identically whether the alert has correct padding or is
flush against the edge. Report design findings separately from AC results: they are not AC
failures, but they are findings that belong in the QA comment.

> **Provenance — PEDX-10264:** All 3 functional ACs passed (error appears, clears, layout at
> 375px). But the mobile screenshot showed the expanded MiniProductCard had lost its left padding
> — content flush to the drawer edge while the right side retained a margin. No assertion caught
> it. A human reviewing the screenshot would have seen it immediately. This step exists because
> that run shipped "all pass" without noting a visible design inconsistency.

**Why this order.** Tests written straight from a diff bind to *that* implementation. Measured
cost: on one run, roughly nine desktop tests bound to a structural detail (`lg:static`) that exists
only on the feature branch — had it shipped differently, they would have needed rewriting rather
than catching the change. Tests derived from observed behaviour survive the implementation moving
underneath them.

> **Phases 1–9 are one sequence.** A run that stops at 7 has produced tests nobody has shown to discriminate the fix. 8 is not optional follow-up.

### 7. Durable tests and sentinels

Regression tests go in the project's suite, not the bundle. One test per AC, plus edge cases and close-regression cover for what the diff touched nearby.

**Written is not committed.** Whether these tests land in the suite or stay in the evidence
bundle is §8d's decision, made after they have proven themselves in §8–8c — and the default is
that they stay. Write them to committable standard either way; a test that would embarrass the
suite proves nothing as evidence either.

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

Dispatch these **six in parallel**, scoped to the diff and the ACs. Anything outside those two is out of scope — an unbounded critic returns "you didn't test Safari 14 on 3G" forever.

| Mission | Question it must answer | Required output |
|---|---|---|
| `probe-mutation` | For each AC, what concrete one-line change to the app would break it — and does any test catch it? **Make the change, run the suite, revert.** | Per mutation: the diff hunk, and `caught` / `survived` |
| `probe-coverage` | Which AC clauses and which hunks of the diff have **no** assertion pointing at them? | Gap list keyed to AC text and `file:line` |
| `probe-assertions` | Does each assertion prove a structural guarantee, or did it observe one passing render? | Per assertion: `structural` / `incidental`, with the reason |
| `probe-value` | Is each test **worth keeping** — does it protect behaviour a user would notice losing, at a maintenance cost the risk justifies? | Per test: `keep` / `merge` / `delete`, with the reason |
| `probe-outcome` | For each AC: is the **user-visible outcome** asserted anywhere, or only a mechanism standing in for it? Would the suite stay green with the feature visibly broken? | Per AC: `outcome-asserted` / `proxy-only`, naming the proxy |
| `probe-visual` | Review every evidence screenshot for design quality: padding symmetry, alignment, clipping, visual hierarchy, state-transition degradation, responsive integrity (§6e checklist). | Per screenshot: `design-defect` / `cosmetic` / `acceptable`, naming what is wrong |

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

#### probe-visual — screenshot design review

Unlike the other probes, `probe-visual` does not read test code — it reads the evidence
screenshots. Its input is the screenshots directory of the evidence bundle, and its job is to
review every image as a designer would.

The brief must include:
- The path to the screenshots directory
- The §6e checklist items (padding/spacing symmetry, alignment, clipping/overflow, visual
  hierarchy, state transitions, responsive integrity)
- Instruction to compare "before" and "after" screenshots for layout degradation on state changes
- The standard return schema citation

```
Agent(description: "probe-visual-<ticket>", prompt: "
  ADVERSARIAL REVIEW — visual design inspection. Your job is to find design
  defects in evidence screenshots, not to approve them.
  Return shape: schemas/subagent-returns/probe.schema.json. Return `handover`
  ({role, status, next-action} — all three required), `findings-emitted`,
  `finding-ids` (REQUIRED whenever status is 'findings-emitted'), and `summary`.

  Read every screenshot in <screenshots-dir>.
  For EACH screenshot, check the §6e checklist:
  1. Padding and spacing symmetry — are insets consistent left/right, top/bottom?
  2. Alignment — do sibling elements (buttons, labels, icons) line up?
  3. Clipping and overflow — is content cut off? Rounded corners correct?
  4. Visual hierarchy — is the primary action visually dominant?
  5. State transitions — compare before/after shots. Does layout degrade on expand, error, load?
  6. Responsive integrity — does the layout look intentional at this viewport?

  For each finding: name the screenshot, describe what is wrong, and classify as
  'design-defect' (broken layout/padding), 'cosmetic' (minor visual inconsistency),
  or 'acceptable' (intentional design choice).

  MANDATORY: silence is a failed dispatch. If every screenshot passes inspection,
  list each one you reviewed and what you checked. A vague 'looks fine' is a failure.
")
```

This probe populates `uiReviewed: true` in the adversarial verification receipt. The
`adversarial-verification-gate.sh` already enforces this field — sign-off is denied without it.
A test suite with passing functional assertions but unreviewed screenshots cannot ship.

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
**Use the shipped runner — do not hand-roll this per project:**

```bash
npx achilles-mutate                     # reads .achilles/mutations.mjs
npx achilles-mutate --only pills-hidden # one mutation, while iterating
```

It owns the parts that drew blood here: owner-based classification, the `noop` control, the
per-mutation applied-check, and the VOID verdict. This was a prose recipe first, and every
subtlety in the prose was re-derived wrongly at least once — that is the evidence for shipping it
as code. The runner refuses to start without a `noop` mutation, because without one there is no
way to tell "the suite catches mutations" from "the harness breaks the page".

- **Browser-level mutation needs a hook in the project's fixture**, because a Playwright config cannot add one — this part the runner genuinely cannot do for you. Two variables, exact names and grammar:

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

  The `noop` control is simply both variables empty. The applied-check is an expression evaluated
  **in the page** once the mutation is live — a selector alone is too weak, because most mutations
  change a computed style rather than adding a node (`getComputedStyle(el).display === 'none'`,
  not `[data-x][hidden]`).

  **Give the un-applied case its own verdict.** Do not fold it into SURVIVED: an un-applied
  mutation is a **VOID** measurement that says nothing about coverage, and calling it a survivor
  manufactures a coverage hole that does not exist. Three outcomes, not two:

  | Suite red? | Applied? | Verdict |
  |---|---|---|
  | yes | — (self-evident) | CAUGHT |
  | no | true | SURVIVED — a real finding |
  | no | false | **VOID** — fix the injection and re-run before reading anything |

  Only SURVIVED needs the check, and only then is it worth the browser launch.

  **The applied-check is itself an instrument, so it needs its own control** — this is the rule
  that keeps getting missed, including by the code written to enforce the rule above it. Two
  cheap calibrations before believing any result: run it with **no injection** (must report
  `false`) and with the mutation injected (must report `true`). A checker that always returns
  true is a rubber stamp; one that always returns false invents holes. `achilles-mutate
  --calibrate` runs both points for every mutation and exits non-zero on any that cannot produce
  both answers.

  **Run the calibration as its own command, not opportunistically.** The applied-check only fires
  when a mutation SURVIVES, so a check that is broken for a mutation the suite reliably catches is
  never exercised — no number of full runs will surface it. Measured: a width-scoped mutation
  (`@media (max-width:1400px)`) had its check performed at the run's 1440 viewport, where the rule
  does not apply. It reported false for a mutation that works. Because that mutation had been
  caught in every run since it was written, the fault was invisible and would have surfaced only
  on the one future run where it mattered — as a VOID verdict on a perfectly good mutation. If
  your mutation is scoped to a width, a media query, or a state, **check it where it applies**. Give it the same
  page-level control as any other probe — if the page never rendered, the result is void rather
  than false.

  **And keep "could not check" separate from "checked, did not apply".** Collapsing them puts an
  infrastructure failure into a coverage verdict, which is the same error VOID exists to prevent,
  one level up. Measured: a resolution bug made every applied-check return "unknown", the runner
  read unknown as VOID, and a documented intentional survivor was reported as a broken injection.
  Four outcomes, and the last one is a bug report about the harness rather than a fact about the
  suite:

  | | meaning |
  |---|---|
  | CAUGHT | the OWNING test failed |
  | SURVIVED | applied, and nothing failed — a finding |
  | VOID | checked: it never took effect. Fix the injection |
  | UNCHECKED | the check could not run. Says nothing either way; print the reason, not a verdict | Add this hook as a **prerequisite**, not a mid-probe discovery: without it,
  §8b's first mission is not runnable at all on a deployed-only project.
- **Silence is not a pass.** A reviewer that reports nothing is indistinguishable from a lazy one. Require the shape: findings, **or** an explicit *"I attempted these N mutations and the suite caught all N"* with the list. An empty return is a failed dispatch, not a clean bill of health.
- **A surviving mutation is a finding, not a suggestion.** It means a stated AC has no test that can fail for it. Fix the test before reporting the verdict.

Write the outcome to `.achilles/adversarial-verification/<ticket-key>.json`:

```json
{
  "ticket": "<KEY>", "ranAt": "<ISO-8601>",
  "negativeControl": { "environment": "<url>", "failed": 5, "passed": 1, "skipped": 0 },
  "mutations": [{ "ac": "AC-2", "hunk": "…", "caught": true }],
  "coverageGaps": [], "incidentalAssertions": [], "lowValueTests": [],
  "review": { "uiReviewed": true }
}
```

That receipt is what the harness gate looks for. **The gate DENIES a tracker transition to a
completed state without it**, so an adopter who has not read this section meets it as an
unexplained denial — kill-switch `CIVITAS_DISABLE_ADVERSARIAL_GATE=1` if you need out.

The gate also checks `review.uiReviewed: true` (populated by `probe-visual` — see §8b).
Without it, sign-off is denied even when all functional probes pass.

**Gitignore `.achilles/`.** The receipt is a local run artifact: git does not preserve mtimes, so a
committed receipt would arrive on CI with a rewritten timestamp and defeat the staleness check
outright. It is evidence for the run that produced it, not a shared artifact. Writing it by hand without running the probes defeats the check entirely — and the failure it catches is *your own*.

#### 8c. Score the testing itself — `probe-rigour`

The six probes above audit the **artifacts**: the tests, the assertions, the coverage. None of
them audits **the testing**. A run can produce well-formed tests that catch their mutations and
still be bad QA — because the agent never drove the feature, ran one browser and claimed three,
or bounded nothing it reported.

So dispatch a sixth reviewer whose subject is the *work*, and make it return **a score with a
threshold**, not a findings list. A findings list has no failure state: zero findings reads as
"nothing to fix" and six reads as "we fixed six", and neither says whether the testing was good
enough to sign off on. A rubric with a blocking floor does.

**Score each dimension 0–3. Every score MUST cite the artifact it is read from — a score with no
citation is void and scores 0.** The reviewer is scoring what it can *see*, not what it is told.

| # | Dimension | 0 — blocks sign-off | 3 |
|---|---|---|---|
| R1 | **Understanding** — were cases derived from driving the feature? | tests written from the diff alone; no live interaction recorded | a live trace exists, and named cases trace to things observed in it |
| R2 | **Discrimination** — does the suite fail where the fix is absent? | never run against a build without the fix | negative control run and read *per test*, plus mutation by owner |
| R3 | **Outcome fidelity** — is the user-visible outcome asserted? | every AC rests on a proxy/mechanism | outcome asserted directly; each surviving proxy justified in writing |
| R4 | **Environment honesty** — do the claims match what was run? | claims cover browsers/viewports/builds never executed | every claim scoped to the matrix actually run, with the matrix stated |
| R5 | **Defect quality** — are findings reproducible and bounded? | severities asserted; no repro; no boundary | each defect has a repro, a measured boundary, and a severity with a reason |
| R6 | **Self-scepticism** — was the harness itself controlled? | results believed without a control | no-op control, applied-checks, and at least one earlier conclusion retracted on evidence |

**Thresholds — the part that makes it a gate rather than a decoration:**

- **Any dimension at 0 blocks sign-off**, whatever the total. A high total must never mask a
  fatal hole; that is precisely how a suite with excellent assertions and no negative control gets
  shipped as regression cover.
- **≤ 12 / 18 → rework before reporting.** Not advice — the report does not ship.
- **13–15 → ship with the weak dimensions named in the report.** The reader is owed them.
- **16–18** should be *rare*. A reviewer handing out 18 is a reviewer to distrust: ask it which
  dimension it examined *least* carefully, and re-run that one.

```
Agent(description: "probe-rigour-<ticket>", prompt: "
  ADVERSARIAL REVIEW — score the QA WORK, not the code under test. You are not
  checking whether the tests pass; you are judging whether the testing was done
  properly enough to sign off on.
  Return shape: schemas/subagent-returns/probe.schema.json (handover{role,status,
  next-action}, findings-emitted, finding-ids, summary).
  Score R1..R6 from the rubric, 0-3 each. For EVERY score, quote the artifact you
  read it from — file, line, log, or run output. A score you cannot cite is 0.
  Then state the total, the blocking dimensions, and the ONE change that would
  raise the lowest score.
  <the specs> <the live-observation trace> <the negative-control output>
  <the mutation report> <the defect list> <the draft report>
  Report the score you measured, not the score that would be encouraging. If you
  scored everything 3, name the dimension you examined least and re-examine it.
")
```

**Why a score and not more findings.** Findings are unranked and unbounded; six cosmetic ones read
louder than one missing negative control. A rubric forces the reviewer to say *which axis is
weak*, and the blocking floor makes one axis sufficient to stop the work. It also gives the human
a number to disagree with — which is the point. A verdict nobody can argue with is a verdict
nobody has checked.

**Do not average away a zero, and do not let the author set the score.** `probe-rigour` runs on the
same separation-of-duties basis as §8b: the agent that did the testing has a stake in it looking
thorough.

#### 8d. Commit or discard — the CX/revenue impact gate

The tests exist, they discriminate the fix (§8), and they survived the review (§8b–8c). None of
that decides whether they belong in the suite. **Written is not committed.** A durable test is a
permanent liability the whole team pays for — it runs on every PR, flakes on every infrastructure
hiccup, and bills its maintenance to people who never read this ticket. Whether the scenario
earns that is a separate judgement, and it comes *after* verification, because only a verified
test is worth proposing at all.

Analyse the tested scenario's **customer-experience and revenue impact**, then route:

| Impact analysis says | Outcome |
|---|---|
| No significant CX or revenue impact | **DISCARD** — the default. The tests stay in the evidence bundle; nothing is committed. |
| Significant CX and/or revenue impact | **PROPOSE** — state the impact rationale explicitly; a human confirms before anything is committed. |

**Discard is the default.** The ticket's value is already banked: the change was verified, the
evidence is on the ticket, the negative control ran. Committing the tests is a second decision
with a different cost curve, and it needs a positive case — not the absence of an objection.

**What counts as significant.** Conversion-critical paths, checkout-adjacent flows, auth and
account access, data-loss risk — scenarios where a regression costs money or locks users out. The
rationale must be stated, not implied: which user path, what a regression there costs, and why
existing cover would not catch it. "It might break someday" is true of every line in the
application and therefore justifies nothing.

**High impact proposes; a human commits.** Even when the analysis clears the bar, the agent's
output is a *proposal with the impact rationale attached* — the human (dev or QA) confirms before
the tests land. This is the human "confirm coverage" gate of AI-enhanced shift-left: the agent is
well placed to analyse what a scenario touches, and badly placed to own a permanent addition to
someone else's CI bill. No confirmation, no commit; a proposal that expires unanswered is a
discard.

**Discarded is not undocumented.** A discarded suite still produces the full evidence package on
the ticket — the companion-mode bundle, screenshots, recordings, the negative-control result, and
the specs themselves as attachments. Discard changes where the tests live, not what the run
proved.

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

## Style-interaction verification — mock the page, test the styling

When a fix is purely CSS/styling that responds to user interactions (focus rings, hover states,
active highlights) and **real page data is unavailable** (no orders, no transactions, empty
accounts), you cannot drive the feature end-to-end. But you can still verify the fix in the real
CSS environment — Tailwind layers, design tokens, specificity chains, global rules — by injecting
mock DOM and triggering the interaction programmatically.

This is a **fallback**, not a substitute. The report must state that real data was unavailable and
why. An injected element proves the CSS classes produce the right computed styles in the project's
stylesheet; it does not prove the component renders those classes, that the layout doesn't clip the
indicator, or that no ancestor `overflow: hidden` truncates it. Those require the real component
with real data, and the gap belongs in the report.

### When to use it

- The fix changes CSS classes on a component (focus-visible, hover, active, disabled states)
- The component needs data you cannot create (orders need payment, transactions need fulfilment)
- You need to prove the styling works in the real CSS environment, not in isolation
- The ticket's ACs are about computed visual properties (outline width, contrast, ring visibility)

### The pattern

All six steps run inside a single Playwright test via the project's CLI (`pnpm exec playwright
test`), so `playwright.config.ts` headers, device presets, and bypass tokens all apply.

**1. Navigate to the real page.** The full CSS environment must be loaded — Tailwind's generated
stylesheet, design tokens, global rules (e.g. `.is-tabbing a:focus-visible`). Use the page where
the component would normally appear, logged in if required.

**2. Set required state classes.** Some styling depends on ancestor state classes that headless
browsers don't trigger automatically. Inject them via `page.evaluate()`:

```ts
// The site adds .is-tabbing on first Tab keypress; headless may not fire it
await page.evaluate(() => document.documentElement.classList.add('is-tabbing'))
```

State the injected classes in the report — they are assumptions, not observations.

**3. Inject mock DOM** via `page.evaluate()` using the **exact CSS classes from the PR diff**.
Insert into `<main>` so the element inherits the page's full cascade. Give the mock a unique `id`
for reliable targeting:

```ts
await page.evaluate((cssClasses) => {
  const main = document.querySelector('main')
  if (!main) throw new Error('No <main> element found')
  const mock = document.createElement('div')
  mock.id = 'mock-component'
  mock.innerHTML = `<a href="#" class="${cssClasses}" id="mock-target">
    <span class="inline-block text-body-md-bold">Mock content</span>
  </a>`
  main.insertBefore(mock, main.firstChild)
}, 'focus-visible:ring-2 focus-visible:ring-brand-blue-500 …')
```

**4. Trigger the interaction.** Use the interaction that the fix targets:

| Interaction | How to trigger |
|---|---|
| Keyboard focus | `page.keyboard.press('Tab')` in a loop until `document.activeElement.id === target` |
| Hover | `page.hover('#mock-target')` |
| Active/pressed | `page.locator('#mock-target').dispatchEvent('pointerdown')` |
| Disabled state | set `disabled` attribute or `aria-disabled` on the mock |

**5. Assert computed styles.** Read the styles that the AC requires and assert on them directly:

```ts
const styles = await page.evaluate(() => {
  const el = document.activeElement
  if (!el) return null
  const cs = window.getComputedStyle(el)
  return {
    outline: cs.outline,
    outlineStyle: cs.outlineStyle,
    outlineWidth: cs.outlineWidth,
    outlineColor: cs.outlineColor,
    outlineOffset: cs.outlineOffset,
    boxShadow: cs.boxShadow,
  }
})

// Assert the AC: "visible focus indicator ≥ 2px"
const hasRing = styles.outlineStyle !== 'none' && styles.outlineWidth !== '0px'
const hasShadow = styles.boxShadow !== 'none'
expect(hasRing || hasShadow).toBe(true)
```

**6. Capture evidence screenshots.** Two shots — viewport for context, closeup for detail:

```ts
// Full viewport — shows the page, the mock element, and the focus state
await page.screenshot({ path: 'test-results/evidence-viewport.png' })

// Closeup — clip around the focused element with padding
const rect = await page.evaluate(() => document.activeElement?.getBoundingClientRect())
if (rect) {
  const pad = 40
  await page.screenshot({
    path: 'test-results/evidence-closeup.png',
    clip: { x: Math.max(0, rect.x - pad), y: Math.max(0, rect.y - pad),
            width: rect.width + pad * 2, height: rect.height + pad * 2 },
  })
}
```

### What to report

Follow the brief comment format from §9's "Posting to the tracker": what was tested (mention mock
injection and which classes), evidence screenshots inline, and the verdict. Caveats (no real data,
single browser, injected state classes) go as one-liners under the verdict — not as separate
sections.

### Negative control caveat

The standard negative control (§8) — running the same test against an environment without the fix
— may not work for style-interaction tests. CSS specificity and Tailwind's layer ordering mean
that injecting old classes into a page does not replicate the cascade the old component experienced.
When the negative control is not feasible via injection, state this explicitly and cite the
ticket's own audit evidence (screenshots, screen recordings) as the pre-fix baseline.

### Provenance: PEDX-10727

This pattern was developed during QA verification of PEDX-10727 (focus indicator on ordered item
names, WCAG 2.4.11). The automation accounts had no order history, and test environments lacked
payment capabilities. A mock order link was injected with the fix's CSS classes
(`focus-visible:ring-2 focus-visible:ring-brand-blue-500 focus-visible:ring-offset-2
focus-visible:outline-none`), Tab-focused, and the computed outline (`rgb(51, 113, 165) solid 2px`
with `2px` offset) was asserted and screenshotted as evidence. The approach verified the fix
produced a WCAG-compliant focus ring in the real Tailwind CSS environment, despite having no real
order data to render the actual component.

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

## Control every instrument before you read it

Six separate controls appear above — the negative control, positive controls before absence
assertions, a page-level control element, the `noop` mutation, the per-mutation applied-check, and
a control on the applied-check itself. Every one was added *after* a specific failure. Stated
separately they read as six rules to remember; they are one rule, and stating it as one is what
stops the seventh instrument from producing the next phantom finding.

**Any instrument whose output you will read as evidence must first be shown capable of producing
a different output.**

The failure mode is always the same shape, and it is silent by construction: an instrument that
does not run produces no signal, and *no signal is indistinguishable from no defect*. It fails in
the direction that looks like success — a clean report — so nothing prompts you to check.

Measured, in this project alone:

| Instrument | How it failed | What it produced |
|---|---|---|
| mutation injection | `addInitScript(str)` where the API wants `{content: str}` | a coverage hole that did not exist |
| the applied-check built to catch that | resolved its dependency from the wrong directory | a documented survivor reported as a broken injection |
| the hook test runner | counts assert calls; a mistyped helper increments nothing | `all 28 tests passed` while 14 lines errored |

The third is the one worth dwelling on: it is the instrument that validates the other gates, it
failed the same way, and it was found only because a test count did not move. Note also the second
— the instrument written to enforce this exact rule broke this exact rule. Knowing the principle
is not sufficient; the calibration has to be run.

**The calibration: two points, always.** Show the instrument reports positive on a case you know
is positive, and negative on a case you know is negative. One point proves nothing — a checker
hard-wired to `true` passes any single positive test.

```
applied-check   → no injection must report FALSE; a known-caught mutation must report TRUE
mutation runner → the `noop` control must be green; a known-caught mutation must go red
a test suite    → must fail where the fix is absent (§8); must pass where it is present
a live probe    → a control element present on ANY build must be found (§9)
a grep/count    → run it once where you KNOW the answer is non-zero
a test runner   → make one case fail on purpose and confirm the tally moves
```

**Three questions before believing any "nothing found":**

1. Did the instrument actually run? Not "was it invoked" — did it reach the thing it measures?
2. Has it produced a *different* answer, on a case where the answer is known?
3. If the subject were broken, what exactly would be different in this output? If you cannot
   name it, you have not measured anything.

**Corollary: "could not measure" is never "measured nothing".** Keep the two apart in your data
structures, not only in your prose — the collapse happens silently at the point where a `null`
meets a boolean. §8b's UNCHECKED verdict exists because that collapse turned a tooling failure
into a coverage claim.

## Traps

Each of these cost a failed run or a wrong conclusion in practice.

| Trap | What happens | Fix |
|---|---|---|
| **Suite's default viewport** | ACs are signed off at one size; the project's device preset is another. Behaviour genuinely differs. | Pin the viewport explicitly in `beforeEach`. Cover the other size as its own test. |
| **Late-hydrating components** | Client-rendered regions (search/results grids) are absent when your first assertion runs; your feature gate checked an SSR'd element and passed. | `waitForState` on the client-rendered container before asserting against it. |
| **Self-consuming observables** | A sentinel watches a session-storage flag; the destination page's effect reads and deletes it before you assert. Test passes, bug is live. | Assert a state that persists — a DOM state marker at the source, not a message in flight. |
| **Assumed default states** | You click a toggle expecting it to open; it was already open, so you closed it. | Read the initial state, assert the round-trip, don't assume a starting position. |
| **Unredacted HAR** | Your bypass token appears in the request headers of every entry — hundreds of copies inside a bundle you are about to commit. | Redact by header name and strip response bodies. This also shrinks the HAR by ~20×. `companion-mode` §"Redaction" makes the pass mandatory for **any** captured HAR or console log, bundle or not — an ad-hoc capture is precisely where the pass has no owner. |
| **One ticket, two environments, one set of paths** | You verify the same ticket against two environments (preview and production, two viewports, two locales) from one output directory. `video.webm` / `trace.zip` / `network.har` are fixed names, so the second run silently overwrites the first. The report cites both; one exists, and nothing says which. | One bundle per environment, or one named subdirectory per environment inside the bundle. Count the artifacts against the number of runs you are about to claim, before writing the verdict. |
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

### Posting to the tracker

The ticket comment is what the developer, the PM, and the next QA engineer will read. Keep it
**brief** — four sections, nothing else:

1. **What was tested** — one or two sentences per AC: what was verified, on which viewports/browsers.
2. **Evidence** — screenshots uploaded and embedded **inline** in the comment body (not as
   separate attachments the reader has to click through). Use the tracker's image markdown
   (`![alt](url)`) so the images render directly in the comment.
3. **Negative control** — one or two sentences stating whether the tests were run against an
   environment without the fix and what happened. This is not methodology — it is evidence that
   the tests discriminate the change. If the control was not run, say so.
4. **Verdict** — the QA outcome and what should happen next. Pass, fail, or pass-with-caveats,
   followed by a clear recommendation: ready to merge, needs fixes, or blocked. Caveats
   (untested browsers, environment limitations) go as one-liners under the verdict.

That is the entire comment. No tables of computed CSS values, no code review notes, no
methodology explanations beyond the negative control result. The evidence screenshots carry
the detail — that is what they are for.

**Example shape:**

```
## QA — PEDX-XXXXX

**PR:** [#1234](https://github.com/org/repo/pull/1234) | **Date:** 2026-08-20

### AC1 — Error appears without size selection

Verified on Desktop (Sheet) and Mobile (Drawer). Clicking the button without selecting a size
shows the inline error alert.

![AC1 Desktop — error alert inline](https://uploads.linear.app/…)
![AC1 Mobile — error alert inline](https://uploads.linear.app/…)

### Negative control

Same checks run against production. The styling assertion fails there — button is grey, not blue —
confirming the tests discriminate the fix.

### Verdict

✅ **All ACs pass.** No defects found. Ready to merge.
```

**Upload then embed.** Use the tracker's upload API (`prepare_attachment_upload` → PUT →
`create_attachment_from_upload` on Linear), then reference the returned `assetUrl` in the comment
body as a markdown image. A comment without inline evidence is incomplete.

### One contract, every surface — PR descriptions included

The format above is not tracker-specific. It is the report contract, and it binds **every surface
this run writes for a human reader** — the ticket comment AND the description of any pull request
the run opens (durable tests committed via §8d, or a sign-off summary posted on the dev's PR):

- **What was tested** — the scenarios and behaviours covered. Never HOW: no methodology
  narration, no step-by-step process, no framework mechanics.
- **Findings** — defects or confirmations, one line each, separated from AC verdicts per
  §"Reporting" above.
- **Evidence** — screenshots / recordings linked or attached.
- **Verdict** — pass / fail / blocked, with a one-line justification.

**Brevity is a hard requirement, not a style preference.** If a section can be a bullet, it is a
bullet. Anything about *how* the testing was performed is omitted — the reader is deciding
whether to merge, not auditing your process. The one process fact that stays is the
negative-control result, for the reason given above: it is evidence that the tests discriminate
the change, not methodology. Everything else about the rig — tool mechanics, injected state,
framework versions — lives in the evidence bundle, where the next QA engineer can find it without
the reviewer having to scroll past it.

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
