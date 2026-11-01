# Controller contract

How the orchestrator runs a task through several experts while keeping the context discipline of [SKILL.md](../SKILL.md) §1. Everything an expert needs is in its brief file; everything the orchestrator needs back is in the return and its spill file.

## Briefs and reports are files

Each dispatch gets a brief at `.achilles/runs/<run-id>/briefs/<slug>.md` and a report path at `.achilles/runs/<run-id>/reports/<slug>.md`; long bodies spill to `tests/e2e/docs/.subagent-returns/<role>-<scope>.md` (sentinel on line 1) and the report names the spill. The dispatch is the ordinary Agent tool: type `achilles-inspector`, `achilles-author`, `achilles-reviewer` or `achilles-doc-writer`; prompt = "read `<brief path>` first; write your report to `<report path>` before your final message"; description = a short label for the status pane (`author j-login pass 1 cycle 1`), not a routing grammar. Independent experts go out in one message; the orchestrator waits for them in the foreground, in the same turn (never a background dispatch, which ends the orchestrator's turn early), and reads the report files when they return, never the transcripts. Experts dispatch nobody; a judge, a diagnosis or a cleanup is another dispatch of the orchestrator's.

A brief has five parts, in order:

1. **Where the task fits.** One paragraph: the workflow, the pass or phase, what came before, what consumes the result.
2. **Read this first.** The skill to load by directory name, the references to open, the journey block or spec path, the page-repository slice, the app-context slice. Point at files; paste only what the expert cannot locate itself (a journey block, a negative-case matrix, a must-fix list).
3. **Interfaces from earlier tasks.** Paths and ids the brief cannot be expected to know: the discovery draft, the prior cycle's spill, the sibling finding ids, the ledger section.
4. **Rulings.** Decisions already made that the expert must not relitigate, each quoted from the state file.
5. **Return contract.** The status words that apply, the spill path, the schema file for the role (`schemas/subagent-returns/<role>.schema.json` where one exists), the `playwright-cli` session slug, the account the expert may use, and what must appear in `summary`.

Never paste accumulated history. Never paste another expert's transcript.

## Browser automation block

Every browser-using brief carries the block from [playwright-cli-protocol.md](playwright-cli-protocol.md) §8 with the slug filled in. Slug families: `stage2-`, `phase1-`, `phase4-`, `composer-`, `reviewer-`, `probe-`, `fd-`, `companion-`, `cleanup-`, `repair-`; budget ≤25 characters.

## Concurrency

- Read-only experts (inspectors, reviewers) run in parallel with one author on disjoint files.
- At most one author edits shared fixtures at a time.
- One expert per shared account: two experts on `user-a` collide on its basket and its duplicate-order throttle.
- No fixture edits while a reviewer's runs compile them.
- One pool of in-flight slots is shared by authors and reviewers; queue order is FIFO. A journey's own author and reviewer never overlap; across journeys any interleaving is fine.
- Temporary inspection files (`tests/e2e/inspect/**`) are deleted before the expert returns.
- The orchestrator runs `npx playwright-cli close-all` at the end of a phase; never while experts are in flight.
- The orchestrator's context holds the brief paths, the report summaries and the state file; the expert's turn is the expert's.

## Worker statuses

An expert ends with the envelope `handover: { role, cycle, status, next-action }` as the first key of its return, then `summary`, `paths`, `findings`, `questions`, `concerns` as the role's schema allows. JSON is preferred over YAML (YAML's compact mapping corrupts values that contain `:`).

| Status | Orchestrator action |
|---|---|
| `DONE` or the workflow's result word | record; dispatch the review |
| `DONE_WITH_CONCERNS` | rule on each concern (one ledger line each); then review |
| `NEEDS_CONTEXT` | answer from the state file or your own ruling and resume the same expert; a question only the user can answer is carried upward in your own `NEEDS_CONTEXT` while independent work continues |
| `BLOCKED` | owner action, split the task, or re-dispatch with a stronger model; never retry blindly; never perform the action the expert's scope refused |

Shape check on receipt: [finding-and-ledger-schema.md](finding-and-ledger-schema.md) §4.1. A malformed return is re-dispatched once with the violation quoted; a second malformed return is `blocked-dispatch-failure` in the state file.

## Hand-back statuses (upward)

The first line of the orchestrator's final message is one of `DONE`, `DONE_WITH_CONCERNS`, `NEEDS_CONTEXT`, `BLOCKED`; contents per [SKILL.md](../SKILL.md) §6. The adapter adds its own relay framing around the message; the orchestrator writes none. The main session delivers it to the user and re-dispatches with answers; the orchestrator resumes from `.achilles/runs/<run-id>/resume.json` and the workflow's state file, never from the conversation.

## Rulings, not stalls

Every ambiguity the orchestrator resolves itself is one line in the run's state file:

```
Ruling: <what> — <why> — cost if wrong: <cost>
```

Owner instructions are quoted with their date. A question only the owner can answer is recorded as an owner action while independent tasks proceed; the run hands back `NEEDS_CONTEXT` when nothing independent remains.

## Review before advancing

Each unit of work (a scenario, a journey's pass, a discovery cycle, a pipeline phase) is reviewed by a fresh `achilles-reviewer` loading [`../../review/SKILL.md`](../../review/SKILL.md) before the run advances. The brief carries the unit's exit criteria verbatim, the deliverable paths, and the closing expert's return. Advance on `greenlight`/`approve`; on `improvements-needed`/`reject` fix surgically and re-review with a new reviewer; the third consecutive rejection escalates upward.
