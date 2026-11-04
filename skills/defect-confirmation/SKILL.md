---
name: defect-confirmation
description: Independent reproduction of one suspected defect, loaded by an `achilles-reproducer` dispatch. Decides from the claim, the acceptance criteria, the live application and the source whether the defect is a bug, real only in the source, a spec ambiguity or intended, and returns that verdict as the standard defect evidence the adapter records. Triggers: verify-change step 7a, "is this really a bug", "reproduce this defect", "confirm before filing", any defect that is about to become a sentinel or a ticket.
---

# Defect confirmation

You are handed one suspected defect and asked one question: **is it a bug?** Someone else saw
it; you did not. Agreeing with the claim is not the job. Deciding is.

The orchestrator's side of this step (when it runs, what the brief carries, the audit it feeds) is
[`../achilles-orchestrator/references/verify-change/phase-7a-defect-confirmation.md`](../achilles-orchestrator/references/verify-change/phase-7a-defect-confirmation.md).

## Independence

Read the brief, the acceptance criteria and the ticket text it quotes, the application source and
the live application. **Do not read** the suite (`tests/**` specs), the run's knowledge base or
scenario files, earlier reports, or other reproducers' reports, even when they are in reach. They
carry the conclusion you are here to test.

If the brief does not give you enough to reach the application or the source, return `blocked`
with what is missing. Do not fill the gap from the suite.

## How to reproduce

1. **Restate the claim** in your report in one sentence: the trigger, the observation, why it
   looks wrong. If the evidence the brief quotes does not support the claim as worded, say so and
   test what the evidence shows.
2. **Find the oracle**: the acceptance criterion, the on-screen promise (copy, a hint, a success
   message) or the documented behaviour the claim says is broken. No oracle, no bug: the result is
   `spec-ambiguity` or `not-a-bug`.
3. **Read the source** along the path: where the behaviour is decided, in every layer you can
   reach. Note `file:line`. Look for tests, comments or rules that make the behaviour deliberate.
4. **Reproduce live**, in your own browser session (`npx playwright-cli -s=<slug> …`, the slug
   your brief gives you), from a state a reader can reach: log in, open, upload. Capture what you
   see: screenshots, the network request and response, the downloaded file.
5. **Repeat** when the behaviour depends on anything non-deterministic (an AI result, timing,
   ordering). Record attempts and observations; say what varied.
6. **Stay inside the budget** the brief sets for metered or rate-limited services. A
   reproduction that needs more returns `blocked` and says how much.
7. **Clean up**: delete everything you created in the application. Never change a shared setting
   the brief does not grant.

## The verdict

Exactly one:

| Verdict | When |
|---|---|
| `bug` | Seen live at least once, against the oracle. |
| `real-in-source` | The code path is wrong, and you could not trigger it live. |
| `spec-ambiguity` | Two readings of the criteria, or two layers of the code, disagree, and either could be intended. Name the decision a product owner has to make. |
| `not-a-bug` | Intended: coded, documented or tested on purpose. Cite where. |

Never call something a `bug` from the source alone, and never upgrade `real-in-source` because
the code reading is convincing.

## The standard defect evidence (your return)

Write your report to the path in your brief. It ends with one fenced `json` block that validates
against [`schemas/subagent-returns/defect-repro.schema.json`](../../schemas/subagent-returns/defect-repro.schema.json).
That block is the standard defect evidence: the harness records it as the confirmation of this
defect, and sign-off and defect filing read it. Without it the defect counts as unconfirmed.

The block carries:

- `handover` (`role: reproducer`, `status: verdict-reached` or `blocked`, `next-action`);
- `ticket` (the ticket key under test) and `defect-id` (`<TICKET>-D<n>`, from the brief);
- `verdict`;
- `reproduction` (`attempts`, `observed`, and `varied` when it varied);
- `root-cause`: one entry per layer, `file:line` or why that source was unavailable;
- `severity`: `level` and the `reason` (what the user loses, whether there is a workaround);
- `steps`: one action per step for a reader with no context. Every button and menu by its
  visible label, every file by its path, accounts by `.env` key name. No `→` chains, no "as
  above", no shorthand;
- `expected` and `actual` (required for `bug`), `question` (required for `spec-ambiguity`);
- `evidence`: the paths of what you captured (required for `bug`);
- `cleanup`: `created` and `deleted`;
- `budget-spent`.

Never put a credential value in the report or the evidence; redact it and say so.
