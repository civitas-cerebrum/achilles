# Phases 8c–8e: scoring, commit or discard, verify note

## 8c. Score the testing itself — `probe-rigour`

The six probes above audit the **artifacts**: the tests, the assertions, the coverage. None of
them audits **the testing**. A run can produce well-formed tests that catch their mutations and
still be bad QA, because the agent never drove the feature, ran one browser and claimed three,
or bounded nothing it reported.

So dispatch a sixth reviewer whose subject is the *work*, and make it return **a score with a
threshold**, not a findings list. A findings list has no failure state: zero findings reads as
"nothing to fix" and six reads as "we fixed six", and neither says whether the testing was good
enough to sign off on. A rubric with a blocking floor does.

**Score each dimension 0–3. Every score MUST cite the artifact it is read from; a score with no
citation is void and scores 0.** The reviewer is scoring what it can *see*, not what it is told.

| # | Dimension | 0: blocks sign-off | 3 |
|---|---|---|---|
| R1 | **Understanding**: were cases derived from driving the feature? | tests written from the diff alone; no live interaction recorded | a live trace exists, and named cases trace to things observed in it |
| R2 | **Discrimination**: does the suite fail where the fix is absent? | never run against a build without the fix | negative control run and read *per test*, plus mutation by owner |
| R3 | **Outcome fidelity**: is the user-visible outcome asserted? | every AC rests on a proxy/mechanism | outcome asserted directly; each surviving proxy justified in writing |
| R4 | **Environment honesty**: do the claims match what was run? | claims cover browsers/viewports/builds never executed | every claim scoped to the matrix actually run, with the matrix stated |
| R5 | **Defect quality**: are findings reproducible and bounded? | severities asserted; no repro; no boundary | each defect has a repro, a measured boundary, and a severity with a reason |
| R6 | **Self-scepticism**: was the harness itself controlled? | results believed without a control | no-op control, applied-checks, and at least one earlier conclusion retracted on evidence |

**Thresholds: the part that makes it a gate rather than a decoration:**

- **Any dimension at 0 blocks sign-off**, whatever the total. A high total must never mask a
  fatal hole; that is precisely how a suite with excellent assertions and no negative control gets
  shipped as regression cover.
- **≤ 12 / 18 → rework before reporting.** Not advice: the report does not ship.
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
a number to disagree with, which is the point. A verdict nobody can argue with is a verdict
nobody has checked.

**Do not average away a zero, and do not let the author set the score.** `probe-rigour` runs on the
same separation-of-duties basis as §8b: the agent that did the testing has a stake in it looking
thorough.

## 8d. Commit or discard — the CX/revenue impact gate

The tests exist, they discriminate the fix (§8), and they survived the review (§8b–8c). None of
that decides whether they belong in the suite. **Written is not committed.** A durable test is a
permanent liability the whole team pays for: it runs on every PR, flakes on every infrastructure
hiccup, and bills its maintenance to people who never read this ticket. Whether the scenario
earns that is a separate judgement, and it comes *after* verification, because only a verified
test is worth proposing at all.

Analyse the tested scenario's **customer-experience and revenue impact**, then route:

| Impact analysis says | Outcome |
|---|---|
| No significant CX or revenue impact | **DISCARD**: the default. The tests stay in the evidence bundle; nothing is committed. |
| Significant CX and/or revenue impact | **PROPOSE**: state the impact rationale explicitly; a human confirms before anything is committed. |

**Discard is the default.** The ticket's value is already banked: the change was verified, the
evidence is on the ticket, the negative control ran. Committing the tests is a second decision
with a different cost curve, and it needs a positive case: not the absence of an objection.

**What counts as significant.** Conversion-critical paths, checkout-adjacent flows, auth and
account access, data-loss risk: scenarios where a regression costs money or locks users out. The
rationale must be stated, not implied: which user path, what a regression there costs, and why
existing cover would not catch it. "It might break someday" is true of every line in the
application and therefore justifies nothing.

**High impact proposes; a human commits.** Even when the analysis clears the bar, the agent's
output is a *proposal with the impact rationale attached*; the human (dev or QA) confirms before
the tests land. This is the human "confirm coverage" gate of AI-enhanced shift-left: the agent is
well placed to analyse what a scenario touches, and badly placed to own a permanent addition to
someone else's CI bill. No confirmation, no commit; a proposal that expires unanswered is a
discard.

**Discarded is not undocumented.** A discarded suite still produces the full evidence package on
the ticket: the companion-mode bundle, screenshots, recordings, the negative-control result, and
the specs themselves as attachments. Discard changes where the tests live, not what the run
proved.

## 8e. "Stable" is a record, not a feeling — and the verify note says so

Stable means N green runs per test id plus one can-fail proof per family; the independent verifier records both in
`docs/evidence/<change>/verify.md`. Definition, template and verdicts:
[`achilles-protocol/references/verification-record.md`](../../achilles-protocol/references/verification-record.md).
