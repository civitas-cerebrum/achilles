# Controller protocol

How an orchestrator that runs a change through several agents (implementer, reviewer, verifier, inspector) keeps the
context discipline of [SKILL.md](../SKILL.md) rule 12. Roles, dispatch prefixes and the review and verify loops:
[roles-and-dispatch.md](roles-and-dispatch.md) §"Change loop".

- **Briefs and reports are files.** Each task gets a brief file (scope, files, exact values, rule ids, spend budget,
  the account it may use) and each agent writes a report file. A dispatch has five parts: where the task fits, the
  brief path ("read this first"), interfaces from earlier tasks the brief cannot know, the controller's rulings, the
  report path with a short reply contract. Never paste accumulated history into a dispatch.
- **Reports, not transcripts.** The controller reads the report. When a claim is disputed it greps the agent's
  transcript for the specific evidence lines (a run summary, an order id line), records the finding, and moves on.
- **Model per dispatch:** `coverage-expansion` §"Hybrid model selection".
- **Concurrency.** Read-only agents (reviewers, verifiers, inspectors) may run in parallel with one implementer on
  disjoint files. At most **one implementer edits shared fixtures** at a time. **One agent per shared account** (two
  agents on `user-a` collide on its basket and its duplicate-order throttle). **No fixture edits while a
  verifier's runs compile them.** Temporary inspection files are deleted before hand-back.
- **Hand-back statuses.** `DONE` → review. `DONE_WITH_CONCERNS` → rule on each concern, then review.
  `NEEDS_CONTEXT` → answer with rulings and resume the same agent. `BLOCKED` → owner action, split the task, or
  re-dispatch at a higher tier — never retry blindly, and never perform an action the agent's permission check denied.
- **Bounded waiting.** Never poll an agent that has not handed back. Between hand-backs do only local work (ledger,
  review package, next brief). A course correction is a message to the running agent, not a new dispatch.
- **Rulings, not stalls.** Every ambiguity the controller resolves is one ledger line —
  `Ruling: <what> — <why> — cost if wrong: <cost>` — and the work continues. Owner instructions are quoted with their
  date. A question only the owner can answer is ledgered as an owner action while independent tasks proceed.
