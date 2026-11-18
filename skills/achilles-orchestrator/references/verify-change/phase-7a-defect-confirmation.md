# 7a. Defect confirmation: an independent reproducer per suspected defect

The diff review (step 4) and the live walk (step 6) produce **suspected** defects. Phase 7 turns a
*confirmed* defect into a `test.fail()` sentinel, and §9 reports it to the developer. This phase is
the step between those two: what turns a suspicion into a confirmation, and who decides.

**The agent that suspected a defect does not confirm it.** The inspector who saw it and the author
who would write its sentinel both have a stake in it being real. Each suspected defect goes to a
fresh `achilles-reproducer`, the expert whose only job is to decide whether it is a bug (it loads
[`../../../defect-confirmation/SKILL.md`](../../../defect-confirmation/SKILL.md)).

This exists because it was skipped and it cost something real. In the run this method comes from,
8 suspected defects went into the suite as `@known-defect` sentinels on the strength of the
inspector's own observation and the run's own knowledge base. When each was handed to an
independent reproducer:

- 5 were bugs;
- 1 was real in the source but never observed live;
- 1 was a spec ambiguity that needed a product decision;
- 1 was intended behaviour, coded and unit-tested on purpose.

Three of eight would have reached a developer as defects. One of the five that were bugs was also
described wrongly in the run's own notes; only reproducing it from scratch corrected the
description.

## When it runs

After step 6 has returned its observations and before phase 7 writes any sentinel. It also runs for
any defect the run "already knows": a defect is known when a tracker issue or an earlier
`defect-audit.md` entry records it, not when the run's own notes or knowledge base mention it. A
defect the run cannot point to either of those for is suspected, and is confirmed here like any other.

## Triage before dispatch

A reproducer decides whether behaviour is a defect; it is not needed to find out that nobody has said what the behaviour should be. Before dispatch, hold each suspicion against the criteria verbatim and the product's stated promises:

- **A criterion or a stated promise says what should happen, or the user loses data, money, access or work**: a suspected defect. It gets a reproducer.
- **Neither**: an observation about copy, layout taste or a behaviour no criterion covers. It goes to the product owner as a question in the report, worded with the evidence, and is listed in the audit as `not triaged as a defect`. It gets no sentinel, no defect id and no verdict; the orchestrator states an absence of a criterion, it does not rule on the behaviour.

When in doubt it is a suspected defect. Triage removes questions from the reproducers' queue; it never removes a defect.

## The brief: one reproducer per suspected defect

Dispatch one fresh reproducer per suspected defect (agent `achilles-reproducer`, skill
`defect-confirmation`), all in one message when the environment allows parallel sessions; a defect whose reproduction
changes account-wide state is dispatched alone, after the others have returned. Suspicions of low
severity on the same screen and in the same state (two at most: a reproduction fills about half of what a reproducer holds) may share one reproducer, which
returns one verdict and one `defect-repro` block per defect id; a defect that loses data, money,
access or work always has a reproducer of its own.

Each brief carries:

1. **The claim, worded exactly**: what was observed, under which conditions, and why it looks
   wrong. Before dispatch, check the wording against the evidence it came from (the screenshot,
   the network response, the source line) and quote that evidence in the brief. A brief that
   describes the wrong trigger sends the reproducer to test a case that always works, and its
   "not a bug" verdict is then about a different claim. This happened once: the claim said the
   defect appeared when the user typed a name; it appeared only when the user left the
   suggested name untouched.
2. **The acceptance criteria verbatim**, and the ticket text they come from.
3. **The environment**: URL, the account and role to use (by `.env` key name, never the value),
   the flags and add-ons that must be on, any fixture file to upload.
4. **Read access to the application source**, frontend and backend where both exist, and where
   that source lives (a checkout, a branch, a container image and its build date).
5. **What the reproducer must not read**: the suite, the run's knowledge base, the scenario files,
   earlier reports and other reproducers' reports. Independence is the point of the dispatch.
6. **The budget and cleanup rules**: the project's spend caps (for example, at most one call to a
   metered or rate-limited service per reproducer), which shared settings it may not change,
   and that everything it creates is deleted before it hands back. A reproduction that needs
   more budget than the brief grants returns `blocked` and says how much.
7. **The suspect script** the walk left for this suspicion (`tests/e2e/inspect/<ticket>/suspect-<n>.spec.ts`, phase 6 §6f) and the command that runs it. It shows how to trigger the claim; it does not decide it. A suspicion without a script is reproduced by hand.
8. **The defect id** `<TICKET>-D<n>`, which the sentinel, the audit and any filed ticket cite.
9. **The return schema** `schemas/subagent-returns/defect-repro.schema.json`.

## The verdicts

The reproducer decides for itself and returns exactly one verdict:

| Verdict | Meaning | What happens next |
|---|---|---|
| `bug` | Reproduced live, against the ACs or a stated product promise, also when the code diverges from them on purpose. | Sentinel in phase 7; filed per §9d. |
| `real-in-source` | The code path is wrong, but the reproducer could not trigger it live. | No sentinel. Reported as a code finding with its source lines; filed only if the user decides to. |
| `spec-ambiguity` | The written text supports two readings, both quoted in the verdict, or two written sources disagree. | No sentinel. A question for the product owner in the report. |
| `not-a-bug` | Intended, and no criterion or spec row says otherwise. | No sentinel. The run's notes are corrected. At most a copy or UX remark. |

Every verdict carries:

- **The reproduction count**: how many times the reproducer tried and how many times it saw the
  defect (`4/4`, `1/3`). A non-deterministic defect says so, with what varied between runs.
- **The root cause with `file:line`**, in each layer it reached (frontend, backend), or the
  statement that the source was not available for that layer.
- **A severity with its reason**: one value of the severity rubric ([`finding-and-ledger-schema.md`](../finding-and-ledger-schema.md) §"Severity rubric (the single authority)"), reached by its ordered questions, and what is lost, by whom, and whether there is a way round.
- **Reproduction steps written for someone with no context**: one action per numbered step,
  starting from a state the reader can reach (log in as, open, upload). No shorthand: no `→`
  chains, no "as above", no "upload the fixture → Continue". Every button and menu by its visible
  label, every file by its path.
- **The reproduction evidence**: the captures behind the verdict (the script's runs, traces and
  screenshots), and for a `bug` that shows in the UI, a recording of the reproduction (one chapter
  per step). Other verdicts get no recording. A `bug` without evidence is not recorded as confirmed.
- **What it created and deleted.**

A verdict without a reproduction count, or `bug` with no live reproduction, is an incomplete
return: message the same reproducer with what is missing, once. It has the reproduction in hand, and
finishing its own report costs no independence. Dispatch a fresh reproducer only when that answer
is still incomplete, or when the claim itself was worded wrong. A verdict is never re-run to change
its form.

## The standard defect evidence

The reproducer's report ends with one fenced `json` block in the `defect-repro` shape. A harness
that records returns keeps it as the defect's confirmation, written by the harness and not by any
expert, so the agent that wants the defect to be real cannot forge it. On Claude Code the record is
`.achilles/defect-confirmations/<ticket>/<defect-id>.json`
([`docs/harness/claude-code.md`](../../../../docs/harness/claude-code.md), hook 3). Two moments read it:

- **Filing a defect.** A bug or rework ticket an Achilles agent files must cite a `defect-id` whose
  recorded verdict is `bug`. Without one, the filing is refused, and the refusal says to dispatch
  the reproducer.
- **Sign-off.** Every `[SENTINEL <TICKET>-D<n>]` in the suite needs a recorded `bug` verdict for
  `<TICKET>-D<n>`, and a verdict comment that reports defects needs at least one recorded
  confirmation for the ticket. Without them the sign-off is refused the same way.

A user who decides to file a defect the reproducer did not call a `bug` files it from the main
session, which the harness never binds; the ticket records that decision.

## The audit: `docs/evidence/<ticket>/defect-audit.md`

A doc-writer consolidates the recorded confirmations (and the reproducers' reports they point to)
into one file per ticket:

1. A verdict table: id, ticket and AC, verdict, severity, one line.
2. One section per defect: the evidence, the root cause with `file:line`, and the reproduction
   steps as the reproducer wrote them.
3. The source versions read (commit or image build date), and the total budget spent.

The audit is what phase 7, §8c and §9 read. A sentinel cites its audit entry, R5 is scored from it,
and the report's defect list is drawn from it.

## What the orchestrator does with the verdicts

- Correct the run's own notes, knowledge base and scenario files wherever they called a
  non-`bug` verdict a defect, in the same pass.
- Carry `spec-ambiguity` verdicts upward as `NEEDS_CONTEXT` questions for the product owner; do
  not choose a reading.
- Never upgrade a verdict. A reproducer's `real-in-source` stays `real-in-source` until a live
  reproduction exists, however convincing the code reading is.
