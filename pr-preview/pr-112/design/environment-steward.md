# Design: the environment steward

Status: proposed, not implemented. Written for a developer new to Achilles who will implement it.
Prerequisite reading: `CONTRIBUTING.md` (methodology vs adapter split, deny posture),
`docs/harness/claude-code.md` (the eight hooks), `claude-code/hooks/dispatch.ts` and
`claude-code/hooks/signoff.ts` (the two hooks this design extends the most).

## 1. The problem

Achilles experts share things no single expert owns: test accounts on a shared environment,
account-wide switches, metered services, and the checkout itself. Today each expert sees only its own
brief, and the rules about shared state are prose the orchestrator copies into briefs by hand. Nothing
counts, nothing enforces, and nothing reports what was used.

What that cost in one real ticket run (three stories of an AI document builder, tested on a shared
pre-production environment, 2026-11-02/03):

| What happened | Why it happened | What would have prevented it |
|---|---|---|
| A test switched a paid add-on off and on for the whole account. Every feature behind it then answered 403 for about an hour, blocking the other experts, a human explorer and the next suite run. | The toggle was one test among many; nothing marked it as account-wide with a one-hour recovery. | Knowing that switch is account-wide and slow to recover, and refusing it unless the run holds the account exclusively. |
| An AI service capped at 100 calls per account per month was used by the suite, by 8 independent reproducers and by a human, all on one account. | The cap lived in brief prose ("at most ONE upload that runs a detection"). Nobody summed usage. | A budget per run, sliced per expert, reported in the hand-back. |
| About 165 temporary uploads were left on the account. | Cleanup was each test's own business; nobody listed leftovers. | A registry of what each run created, and a leftovers line in the hand-back. |
| Account flags were nearly flipped while another session's tests ran on the account. | Concurrency was a memory note ("serialise"), not a lock. | A lease on the account that other sessions can see. |
| Another session switched the shared Achilles checkout to a different branch while this session was writing files into it. Two new files landed in the other session's tree. | Two sessions, one working tree, no lock. | The same lease mechanism applied to a checkout. |
| Every brief repeated the same environment block: URL, CA bundle, which `.env` keys hold the logins, which account must never be used. One wrong copy would have pointed an expert at the wrong account. | The facts had no single home. | One committed profile, routed into each brief by the adapter. |

## 2. Goals and non-goals

Goals:

1. **One home for environment facts**: a committed, secret-free profile per project.
2. **Context routing**: every expert brief gets the slice of the profile and of the run's live state that
   its task needs, injected by the adapter, not copied by the orchestrator.
3. **Guarding**: account-wide switches and exclusive resources need a lease, and metered use is counted
   against a budget.
4. **Accounting**: the hand-back states spend, toggles, leases and leftovers.

Non-goals:

- **Not a new expert agent.** The steward is deterministic bookkeeping. An LLM agent would be one more
  context to keep in sync, and it could be talked out of a rule. The judgement parts (is this toggle
  needed, can I clean this up) stay with the orchestrator and the experts; the steward supplies facts
  and enforces limits.
- **Not a secret store.** The profile names `.env` keys, never values.
- **Not test data generation.** That stays with `test-data-conventions` and the project's data service.

## 3. Concepts

### 3.1 The environment profile (committed)

`achilles-environments.json` at the project root, validated by `schemas/environments.schema.json`.
It is the single source of facts. Example, with the shape a fresh implementer should aim for:

```json
{
  "environments": {
    "preprod": {
      "url": "https://app.preprod.example.com",
      "caBundleEnv": "NODE_EXTRA_CA_CERTS",
      "accounts": {
        "ticket-qa": {
          "id": "1001",
          "logins": { "owner": ["E2E_OWNER_EMAIL", "E2E_OWNER_PASSWORD"], "manager": ["E2E_MANAGER_EMAIL", "E2E_MANAGER_PASSWORD"] },
          "sharing": "shared",
          "cleanupPrefix": "achilles-"
        },
        "base": { "id": "1002", "sharing": "do-not-use", "reason": "owned by another team; no billing rights" }
      },
      "metered": {
        "ai-detection": { "cap": 100, "per": "account-month", "matches": ["POST /api/ai/detect"], "countWith": "npm run budget:ai-detection --silent" }
      },
      "accountWide": {
        "premium-addon": { "recovery": "up to 60 min of 403s after re-enabling", "matches": ["PUT /api/subscription", "tests tagged @account-toggle"], "needs": "exclusive" },
        "feature-flags": { "recovery": "about 15 s to reach the edge", "matches": ["PUT /v1/accounts/*/flags"], "needs": "exclusive" }
      }
    }
  }
}
```

Reasoning:

- **One file, committed.** Facts that every expert needs must not live in one expert's memory or in
  brief prose. The file is reviewed like code, so a wrong account id is caught in review, not mid-run.
- **`matches` describes the traffic, not the code.** An implementer cannot know every way a test reaches
  a metered endpoint. Matching on method + path (and on spec tags for whole tests) works for browser
  traffic, API tests and data-service calls alike.
- **`countWith` is optional and project-supplied.** The adapter cannot see browser traffic. When the
  application exposes its own usage counter (here: the AI service answers `run_limit_reached` at the cap,
  and the project can query usage), a command that prints the current count is the only trustworthy
  source. Without it, the steward falls back to the experts' declared spend (§4.3) and says so.
- **`sharing`**: `shared` (others may use it at the same time), `exclusive` (one run at a time) and
  `do-not-use` (never, with the reason). The J15 run had a do-not-use account guarded only by a memory
  note.

### 3.2 The run's environment ledger (adapter-maintained)

`.achilles/runs/<run>/environment.json`, written only by the adapter (hash-tracked like the sign-off
receipt, `claude-code/hooks/context.ts` `writeReceiptHash`):

```json
{
  "environment": "preprod", "account": "ticket-qa",
  "leases": [{ "resource": "account:1001", "mode": "shared", "since": "…", "expires": "…" }],
  "budget": { "ai-detection": { "granted": 10, "spent": 7, "source": "countWith", "byExpert": { "reproducer-f2": 1 } } },
  "toggles": [{ "what": "premium-addon", "by": "author-3", "at": "…", "restoredAt": "…" }],
  "created": [{ "kind": "template", "name": "achilles-f3-new-field", "by": "reproducer-f3", "deleted": true }]
}
```

### 3.3 Leases (machine-wide)

`~/.achilles/leases/<resource>.json`, one file per leased resource (`account:1001`, or
`checkout:<git common dir>`): holder session id, run id, mode, expiry, heartbeat. Machine-wide on
purpose: the collisions happened between sessions, not inside one run. A lease past its expiry with no
heartbeat is stale and may be taken over, with a note.

Reasoning: a lock inside `.achilles/` of one checkout cannot be seen by a session in another worktree
or another repository using the same account. The user's home directory is the narrowest place every
session on the machine shares. Cross-machine sharing (CI against the same account) is out of scope
for the first version; the profile's `sharing: exclusive` plus a tracker of CI schedules is the
workaround, listed in §8.

## 4. Behaviour

### 4.1 Context routing (the brief slice)

`dispatchAdvice` in `claude-code/hooks/dispatch.ts` already rewrites every expert's prompt with a
preamble. Extend that preamble with an **Environment** block, built from the profile and the run ledger:

- the environment URL, the CA variable to set, the account id and the `.env` key names of the logins
  the role needs (a reproducer gets the role named in its brief; a doc-writer gets none);
- the do-not-use accounts and why;
- the expert's budget slice per metered service (§4.3) and what remains for the run;
- the account-wide switches and their recovery, and whether this run holds the lease to touch them;
- the cleanup prefix, and the instruction to delete what it creates;
- other leases on the account right now ("a human explorer session holds a shared lease").

Reasoning: this replaces the hand-copied environment block of every brief. The orchestrator still
writes the task; the adapter writes the facts. The methodology side (what a brief must contain,
`controller-contract.md` §"Briefs and reports are files") gains one line: environment facts come from
the profile, and a brief does not restate them.

The run gets its environment and account once, at preflight: the orchestrator names them in
`resume.json` (`"environment": "preprod", "account": "ticket-qa"`), and the adapter takes the shared
lease then. With no profile, nothing changes from today: no block, no guard, one note at preflight.

### 4.2 Guarding account-wide switches

A call that matches an `accountWide` entry needs the run to hold an **exclusive** lease on the account,
and the run's brief, or the user's answer to a `NEEDS_CONTEXT`, must grant that switch by name.
Matching:

- Bash commands that run a spec tagged as in `matches` (reuse the Bash judge's spend-listed spec
  detection in `claude-code/hooks/bash-judge.ts`);
- Bash `curl`/`node` calls whose argument text contains a matched method + path (best effort; say so in
  the doc);
- MCP or tool calls to a test-data service whose path matches.

Without the lease and grant it is a **deny**, with the action to take: "this switches premium-addon for
the whole account (recovery: up to 60 min of 403s); hand back NEEDS_CONTEXT asking the user to grant it,
and take the exclusive lease first". This meets CONTRIBUTING's deny bar: the effect cannot be undone
within the run, and it lands on other people.

Every allowed toggle is recorded in the ledger, with a restore check. The project's profile may name a
`verify` command per switch (the J15 run's restore check was "a dummy call answers 422, not 403"). A
toggle not verified restored by the end of the run is named at the top of the hand-back.

### 4.3 Budgets for metered services

- At preflight the orchestrator asks for (or the profile defaults) a run budget per metered service.
  It lands in the ledger as `granted`.
- At dispatch the orchestrator names an expert's slice in the brief ("ai-detection: 1"). The adapter
  checks it against what remains and puts it in the Environment block. A slice the run cannot afford is
  a note, not a deny: the orchestrator can rebalance.
- Spend is counted three ways, best first: the project's `countWith` command run at each expert's turn
  end (adapter, `turn.complete` in `claude-code/hooks.ts`); spec runs tagged as metered (count of
  tests); the expert's declared `budget-spent` in its return (already in `defect-repro.schema.json`).
  The ledger records which source each number came from.
- Over budget: the next dispatch that would spend gets a note; a spec run over the remaining budget is
  denied the way the factory `spend.opt-in` rule denies today (`bash-judge.ts`). The deny names the
  remaining budget and says to ask the user.

Reasoning: the cap is per account per month and shared with humans, so a per-run grant is the only
number a run can own. Counting from the application itself (`countWith`) is the only source that sees
humans and other sessions; the fallbacks are labelled so nobody mistakes them for the real count.

### 4.4 Cleanup accounting

Experts already name what they create in their returns (`cleanup.created/deleted` in the reproducer
return; authors in their reports). The adapter collects those into the ledger. At hand-back it lists:

- anything created and not deleted;
- when the profile gives a `leftovers` command (for example, list templates and uploads whose name
  starts with the cleanup prefix), its output.

It does not delete anything itself. Deletion is an application action and belongs to an expert.

### 4.5 The hand-back

`handBack` in `claude-code/hooks.ts` already appends a run summary. Add an environment line: account and
lease, spend per service (granted / spent / source), toggles with their restore status, leftovers.
Unrestored toggles and leftovers go to the top of the hand-back, like the "Unconfirmed defects" line
of PR #100.

## 5. What changes where

| Area | Change |
|---|---|
| `schemas/environments.schema.json` (new) | The profile shape of §3.1; fixtures valid/invalid as for the other schemas (`schemas/subagent-returns/README.md` §"Adding a new role" shows the fixture convention). |
| `claude-code/hooks/environment.ts` (new) | Load and validate the profile, the ledger read/write with hashes, the lease files, the matchers. Registered from `claude-code/hooks.ts`. It extends hook 4 (dispatch) and hook 1 (Bash judge) rather than adding a ninth hook, so the eight-hook contract and the docs counts stay true; if it grows, make it hook 9 and update `docs/harness/claude-code.md` and the site counts (the `docs-counts` lint will tell you). |
| `claude-code/hooks/dispatch.ts` | The Environment block in the preamble (§4.1); budget-slice check. |
| `claude-code/hooks/bash-judge.ts` | Account-wide toggle and metered-spec matching (§4.2, §4.3). |
| `claude-code/hooks.ts` | Preflight lease; `countWith` at expert turn end; the hand-back line (§4.5). |
| `pi/guards.ts` | The same Bash-judge rules on pi (the judge is shared; check the guard wiring). |
| `skills/achilles-orchestrator/SKILL.md` §preflight | Name the environment and account; ask for budgets and toggle grants up front in one `NEEDS_CONTEXT`. |
| `skills/achilles-orchestrator/references/controller-contract.md` | Briefs name the expert's budget slice and any granted switch; they do not restate environment facts. |
| `skills/test-data-conventions/SKILL.md` | Cleanup prefix and the created/deleted return fields. |
| `docs/harness/claude-code.md` | Hook rows, the new deny, the switches table, the state the adapter writes. |
| `CHANGELOG.md` | Entry under the unreleased version. |

## 6. Delivery in three steps

Each step is shippable alone.

1. **Profile and routing (advisory only).** Schema, loader, the Environment block, the hand-back line
   with declared spend. No denies. This alone removes the hand-copied environment prose and the
   wrong-account risk.
2. **Ledger and accounting.** `countWith`, budgets and slices, toggles recorded and verified, the
   cleanup registry, leftovers in the hand-back.
3. **Leases and denies.** Machine-wide leases (accounts and checkouts), the account-wide toggle deny,
   the over-budget spec deny.

## 7. Tests

Follow `claude-code/tests/signoff.test.ts`: an in-memory project from `claude-code/tests/harness.ts`,
one test per behaviour, and **at least two allowed cases beside every deny** (CONTRIBUTING). Minimum
set:

- a brief to a reproducer gets the account, its login key names and its budget slice; a doc-writer's
  brief gets no logins;
- a do-not-use account named in a brief is a note;
- a spec tagged `@account-toggle` is denied without the exclusive lease and grant, and allowed with
  them; an untagged spec and a read-only call pass;
- a second session's exclusive lease on the account turns a shared-lease request into a note naming
  the holder; a stale lease is taken over with a note;
- spend past the grant: a note on the next spending dispatch, a deny on a metered spec run; a
  non-metered spec passes;
- the hand-back lists an unrestored toggle and a leftover at the top.

Prove each deny test can fail: break the check and watch the test go red (the PR #100 tests were
checked this way).

## 8. Open questions for the implementer and the maintainers

1. **Cross-machine leases.** CI and laptops share accounts. Is a lease service (or a row in the test
   data service, which already sees every run) worth it, or is `sharing: exclusive` plus a schedule
   enough?
2. **Who sets the run budget** when the user gave none: a profile default, or always a `NEEDS_CONTEXT`?
   The J15 run would have benefited from being asked once.
3. **Matching browser traffic.** Should the Playwright reporter (`reporter/`) record matched requests to
   the ledger, giving the steward real counts for spec runs without a `countWith` command?
4. **The test data service.** The J15 run's data service already knows accounts, flags and add-on state
   (and its own undo). It may be the better home for leases and toggles, with the adapter as its
   client. Decide before step 3.
