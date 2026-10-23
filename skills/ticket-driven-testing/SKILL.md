---
name: ticket-driven-testing
description: Use when a code change is the unit of QA work — a ticket paired to a PR, a branch awaiting sign-off, OR a developer who has just finished building something and asks for it to be tested, verified, checked, covered, or QA'd. Triggers include "test this", "verify my changes work", "can you check this", "write tests for what I just built", "is this covered", "QA this before I open a PR", as well as any ask naming a tracker issue key. Covers UI verification, test automation, and adversarial review of the testing itself.
---

# Ticket-Driven Testing

## Overview

A ticket is not a test plan. It is a claim about behaviour, a branch that allegedly implements it, and a set of acceptance criteria someone will sign off against. This skill turns that into: verified evidence, durable regression tests, and sentinel tests for every defect found.

**Core principle: build understanding by interacting, then assert what you understood.**

Read the diff early: it tells you **where to look** and **what is risky**. It does not tell you
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
observed behaviour survives the implementation changing; and that matters, because the branch you
are testing may never ship in the form you read.

**REQUIRED SUB-SKILL:** the evidence run itself is `companion-mode`. This skill wraps it with the ticket, branch, and diff context that companion-mode's Phase 1 assumes you already have.

### The sequence

Whenever you list what you are going to do, list these. All ten, in this order. Mark any you are skipping and say why; an omitted step is a decision, and it belongs in the report.

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
8e VERIFY NOTE                             → stable = N green in the reporter history + a can-fail proof per family
9  Report — then DISPATCH probe-verdict at the report itself
                                            → §8b attacks the tests; this attacks the claims
```

Step 8 is the one that gets dropped, so 8b delegates the check instead of resting on memory. A suite nobody has seen fail is not regression cover, and "12/12 green on the branch" is not evidence that it would have caught anything.

### 0. One ticket, one run — the skill being loaded is not the sequence being performed

**Every ticket gets its own run of steps 1–9. A skill already loaded in this session does NOT
mean the sequence has been performed for the ticket in front of you now.**

Activation here is intent-triggered, so the only thing that re-fires it on the second ticket is
your own judgement: and the second ticket is exactly where that judgement fails. The skill IS in
your transcript. The method IS still there to read. "I'm already in ticket-testing mode" is a
locally reasonable inference and a globally wrong one, because *mode* is a property of the
session and *the sequence* is a property of the ticket. Those two came apart the moment the
operator handed you a second ticket.

An ad-hoc second-ticket verification posts a verdict with **zero artifacts**: no screenshots, recording, trace or bundle. The bundle contract is what surfaces artifact paths that collide across environments (a second run silently overwriting the first's video/trace/HAR) and live protection-bypass tokens left unredacted in captured HARs.

Re-enter when **any** of these is true, without waiting to be asked:

- a different ticket key, issue, or branch than the one you last ran the sequence for;
- the same ticket after the branch moved (new commits, a force-push, a rebase);
- a ticket you are picking up mid-flight from someone else's work; including one already sitting
  in a QA column with an open PR, which is the shape that most reads as "just confirm it".

Announce the re-entry in one line ("re-entering ticket-driven-testing for <key>") and restate the
sequence for that ticket. Restating it is cheap; the cost of the wrong inference is a verdict
with nothing behind it.

**Harness-enforced by [`hooks/evidence-bundle-gate.sh`](../../hooks/evidence-bundle-gate.sh): and
read what it does NOT do.** The gate cannot see whether you re-ran the sequence; it can only see,
per ticket, whether the Contract's item-3 evidence bundle exists. That check is bound to the
ticket key rather than to the session, so a second ticket cannot ride on the first ticket's
bundle. It **DENIES** a terminal transition or a published PR with no bundle for that ticket.
On a verdict-shaped **comment** it only **WARNs**; which means the failure described above, where
the artifact-free verdict was posted as a comment, would have been flagged and not blocked. The
grading is deliberate (a bundle-less verdict has one permitted form, per §"Prerequisites"), but it is
a trade. Do not read the gate as a reason to stop watching for this yourself.

## Two entry points, one method

Steps 6–9 are identical either way. Only the front half differs, because only the front half
depends on where the acceptance criteria and the environment come from. "Identical either way"
means identical between the two *entry points*; not shared across *tickets*. Step 0 still
applies: each ticket runs its own 1–9 whichever column it arrived in.

| | **A: ticket-driven** | **B: dev-triggered** |
|---|---|---|
| Trigger | a tracker issue, a PR awaiting sign-off | *"I've finished this, can you test it"* |
| 1 | ticket + parent → ACs verbatim | **the change set → ACs derived and CONFIRMED (§1b)** |
| 2 | PR review state is a QA signal | skip if no PR exists; say so |
| 3 | worktree the branch | **§3b: uncommitted work is not in a worktree** |
| 5 | deployed preview, bypass tokens | the dev's local server |
| 8 | negative control: find an env without the fix | **the merge-base. The strongest form, and nearly free** |

Entry B is not a lighter version. It is the same bar reached by different means; and on two
dimensions it reaches a **higher** one, because a local checkout gives you things a deployed
preview cannot.

Dev-triggered runs (entry B) add §1b (derive and confirm the ACs), §3b (uncommitted work defeats a worktree), §8·B (the merge-base is the negative control) and source-level mutation: [entry-b-dev-triggered.md](references/entry-b-dev-triggered.md).

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
| **A second environment WITHOUT the fix** | §8 negative control | see §8's fallbacks: do not silently skip it |
| An `E2E_MUTATION_CSS` / `E2E_MUTATION_INIT` hook in your page fixture | §8b mutation probe (grammar in §8b) | source-level mutation instead, if the app runs locally |

**Code samples in this skill use the `@civitas-cerebrum/element-interactions` `steps` API**
(`steps.verifyCount('el', 'Page', …)`), which needs that package's fixture and a page-repository.
On stock Playwright the equivalent is `expect(page.locator(...))`; the method is identical, only
the call shape differs.

**Cost.** One 3-AC ticket run literally costs roughly **6+ full suite runs** (branch baseline,
negative control, one per mutation, plus the no-op control) and **5+ agent dispatches**. At an
8-minute suite that is ~1.5–3h wall clock. Budget it, or scope §8b to the ACs that matter.

## The Contract

Produce all five, **for each ticket**. A run that stops after evidence is half a deliverable, and
a second ticket that reuses the first ticket's deliverables has produced none of its own.

1. **A ticket brief**: acceptance criteria, the dev branch, the PR and its review state.
2. **A diff review**: findings ranked by severity, each one a sentinel candidate.
3. **An evidence bundle**: via `companion-mode`, verdict grounded in the ACs. Named for this
   ticket, containing this ticket's artifacts, redacted per `companion-mode` §"Redaction". Numbers
   in a report are not evidence: evidence is what someone else can re-open and disagree with.
4. **Verified tests**: one per AC plus one sentinel per confirmed defect, written and proven
   against the negative control. Whether they are **committed** to the suite or **discarded**
   into the evidence bundle is decided in §8d; and discard is the default.
5. **A negative-control result**: proof the tests fail where the fix is absent (§8). Without it you have tests that pass, not tests that discriminate.

### The sign-off gate

**You may not report a QA verdict until you have run the negative control (§8) and can state its result.**

**You may not report a QA verdict for a ticket that has no evidence bundle of its own.** This is
item 3 above, restated at the boundary where it gets skipped. If the run captured
nothing (an unreachable app, a diff review only) say *that* in the verdict and scope the claim
to what you actually did. Label an unevidenced report unevidenced; labelling it verified misreports the run.

For entry B the sign-off boundary is **opening the PR**, not a tracker transition; that is the
moment the work is presented to others as done. Everything the contract requires applies there
unchanged.

So, before writing any verdict, answer these three in the report:

- Did the suite run against an environment **without** the fix?
- Which tests **failed** there, and which **passed**?
- For each one that passed; is it close-regression cover of pre-existing behaviour (fine), or does it fail to discriminate the feature (worthless as AC cover)?

"The tests are green on the branch" answers none of these. If you cannot run the control, say so explicitly in the verdict; report an unverified suite as unverified, never as regression cover.

## Phases

One file per phase. Read the file for the phase you are in; do not load them all.

| Phase | Read |
|---|---|
| 1 Ticket intake, 2 PR state, 3 Worktree, 4 Diff review, 5 Environment | [intake-and-isolation.md](references/intake-and-isolation.md) |
| 6 Build understanding by interacting (6a–6e) | [phase-6-understanding.md](references/phase-6-understanding.md) |
| 7 Durable tests and sentinels | [phase-7-durable-tests.md](references/phase-7-durable-tests.md) |
| 8 Negative control | [phase-8-negative-control.md](references/phase-8-negative-control.md) |
| 8b Adversarial test review (six probes, `probe-visual`) | [phase-8b-adversarial-review.md](references/phase-8b-adversarial-review.md) |
| 8c Score the testing, 8d Commit or discard, 8e Verify note | [phase-8c-8e-scoring-and-commit.md](references/phase-8c-8e-scoring-and-commit.md) |
| 9 Live observation, compliance sweep, report, tracker post, QA comment template | [reporting.md](references/reporting.md) |
| Entry B (dev-triggered): 1b, 3b, 8·B, source-level mutation | [entry-b-dev-triggered.md](references/entry-b-dev-triggered.md) |
| Style-interaction verification (mock-DOM styling tests) | [style-interaction-verification.md](references/style-interaction-verification.md) |
| "Show me" runs, instrument controls, traps, framework gaps | [traps-and-instruments.md](references/traps-and-instruments.md) |

### 8. Prove the tests discriminate the fix — the negative control

Run the new suite against an environment without the fix. It MUST fail there; read the result per test. Details and fallbacks: [phase-8-negative-control.md](references/phase-8-negative-control.md).

#### 8b. Dispatch the adversarial test review

Six subagents attack the tests; you do not self-assess. Mission briefs, mutation grammar and return handling: [phase-8b-adversarial-review.md](references/phase-8b-adversarial-review.md).

> **Phases 1–9 are one sequence.** A run that stops at 7 has produced tests nobody has shown to discriminate the fix. 8 is not optional follow-up.
