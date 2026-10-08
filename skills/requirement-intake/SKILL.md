---
name: requirement-intake
description: >
  The only door for a new scenario: a structured, linted block in a scenario
  document, from which the spec is derived and whose Status records the
  verified outcome. Triggers on: "new scenario", "add a scenario", "propose a
  scenario", "requirement", "acceptance criteria", "scenario block", "write a
  spec for", "derive the spec", "test case for", "scenario lint", "update the
  scenario status", "mark it green", "omitted-by-ruling", and on any
  [specs.shape] message from the intake gate or the lint. Use before writing
  any new test(...) in a project that has opted into the factory rule file
  (achilles-factory-rules.json with rule specs.shape). Do NOT use to compose
  a whole journey's variant set (test-composer) or to verify a change
  (ticket-driven-testing).
---

> **Activation banner:** The first user-facing reply after this skill loads MUST begin with the line: **Protocol Achilles activated.** Once per session — skip if already declared in this conversation. Subagents (which return structured data, not user-facing text) are exempt.

# Requirement intake — the block is the only door

> **Skill names: see `../achilles-protocol/references/skill-registry.md`.** Copy skill names from the registry verbatim.

A scenario exists in the suite only as a linted block in a scenario document. Specs are derived from blocks, never
invented; every test title carries its block's ID; the block's Status records what verification proved. The block is
the requirement a developer, a QA engineer and an agent can all read, propose by pull request, and check by machine.

Project values live in the factory rule file — `achilles-factory-rules.json` at the project root, or the file
`$FACTORY_RULES` names — rule `specs.shape` (schema: `hooks/data/factory-rules.schema.json`). The lint reads
`titleIdPattern` (required), `scenarioDocs`, and the optional `blockEnums` object `{ type, oracle, spendPolicy, status }`
(string arrays). Each array it finds replaces the lint's built-in default; a missing one falls back to it:

| `blockEnums` key | Checks | Built-in default |
|---|---|---|
| `type` | every tag in **Type** | `specs.shape.tags`, else any `@tag` |
| `oracle` | leading token of **Oracle** | `UI-only`, `api`, `db` |
| `spendPolicy` | leading token of **Spend policy** | `none`, `disposable`, `released`, `one-confirming-run` |
| `status` | leading token of **Status** | `proposed`, `implemented`, `green`, `red-by-design`, `blocked`, `omitted-by-ruling` |

Tokens are hyphenated; people may write them as prose. Before matching, the lint normalises both sides — lower case,
counts such as `3×` or `n×` removed, spaces turned into hyphens — so `green 3× (<date>)`, `red by design (<reason>)`
and `one confirming run` match `green`, `red-by-design` and `one-confirming-run`. The minimal omitted form keys on
the normalised `omitted-by-ruling`; a project with its own `status` list keeps that token to keep the form.

Gate semantics: `../achilles-protocol/references/factory-gates.md#specs.shape`.

## The one-door rule

1. **No block, no spec.** The intake gate (`hooks/factory/intake-gate.sh`) refuses a new spec file whose `test(`
   titles do not start with an ID that has a block in `scenarioDocs` and — when `lint` is set — passes it. It judges
   NEW files only (intake is not a retrofit), so the same drift in a file that already exists is caught by the
   **project's own** verify step, which should run this lint over every spec. Achilles ships no verify-step guard of
   its own — see `../achilles-protocol/references/factory-gates.md#opting-in-the-rule-file`, "Who detects a missing or
   weakened rule file". Without that step, an edit to an existing spec can drift from its block unnoticed.
2. **The block is the requirement.** The spec implements the block's Steps and asserts its Expected through its
   Oracle. When live behaviour contradicts the block, the block gets a `Corrected (<date>)` bullet in the same
   change; the spec never silently diverges from it.
3. **Nobody routes around the door.** A scenario that "only needs a quick test" gets a block first. A block may be
   short; it may not be skipped.

## The block

Template and field contract: [`references/scenario-block.md`](references/scenario-block.md). Nine fields:

| Field | Holds |
|---|---|
| Contexts | the dimension the project shards runs by (region, tenant, browser, account); free text, one or more names |
| Type | the test's tags |
| Purpose | one sentence, the behaviour under test |
| Preconditions / test data | requirements to resolve at runtime, never literals copied from today's content |
| Steps | numbered, user language, no selectors, no fixed waits |
| Expected | observable outcomes; amounts as rules |
| Oracle | the layer that confirms the outcome |
| Spend policy | what one run costs (`none`, `disposable`, `released`, `one-confirming-run`) |
| Status | `proposed` → `implemented` → `green` / `red-by-design` / `blocked` / `omitted-by-ruling` |

IDs follow `titleIdPattern` and are unique **per context** (the same ID may name the same scenario in `north` and
`south`). Env variable NAMES only — never values.

## The lint contract

`npx achilles-scenario-lint [files…] [--id <ID>] [--quiet] [--json]` (`bin/scenario-lint.mjs`).

- Files default to `specs.shape.scenarioDocs`; file arguments are relative to the project root; the rule file is `$FACTORY_RULES` (absolute, or relative to the
  project root) or `achilles-factory-rules.json` at the root. The root is `$CLAUDE_PROJECT_DIR`, else the cwd.
- **Exit 0** — every selected block passes. **Exit 1** — a block is rejected or `--id` matched no block.
  **Exit 2** — usage or configuration: unknown flag, missing rule file, no document, document not found.
- Every error is three lines: `[specs.shape] <file>:<line> <ID>: <what>` / `→ Do: …` / `→ Why/how: <doc#anchor>`.
- `--json` prints `{ ok, blocks: [{ id, title, line, file, fields, errors }], skipped }` for tools; with `--id`,
  `blocks` holds only the match while `skipped` still lists every non-block `####` heading of the given files.
- The intake gate calls it as `<lint…> --id <ID> <doc…>`; set `specs.shape.lint` to
  `["npx", "achilles-scenario-lint", "--quiet"]` (or a project wrapper).

## How people propose a scenario

1. Add the block to a scenario document with `Status: proposed`; the lint must be green.
2. Name the contexts and the oracle you expect; leave Steps free of selectors — the implementer finds the elements.
3. Open a pull request. The change loop picks the block up: brief → implement → review → verify.

## Deriving the spec (agent)

1. Read the block, [`../achilles-protocol/references/spec-shape.md`](../achilles-protocol/references/spec-shape.md)
   and the API reference.
2. Put the test in the spec file of its family (one family per file); check the project's config collects it.
3. Title it `'<ID> — <title>'` with tags from the block's Type; one `test()` per block.
4. Preconditions become a `Requirements` value resolved by the data engine (`test-data-conventions`), never a named
   merchant or item unless the scenario is about it.
5. Steps become inline calls in reading order; chores shared by two or more scenarios become fixture verbs.
6. The Oracle becomes a visible call at the end of the test; an order-placing test attaches its evidence.
7. New elements go through live inspection and selector evidence before the spec uses them.

## Status updates after verification

1. From the verify note (see `ticket-driven-testing` §8e): `green 3× (<date>)`, `green 1× (<date>, confirming run)`,
   `red-by-design (<reason>)`, `blocked (<reason, missing variable or owner action>)` — the count after `green` is
   free text for the reader; the lint matches the token.
2. Add `Corrected (<date>)` when live behaviour contradicted the block; keep the old claim visible.
3. Anything red or blocked also gets a known-issues row.
4. `omitted-by-ruling (<date>, <reason>)` keeps the heading and needs only Contexts, Purpose and Status. Reverse it by
   filling the remaining fields and setting `proposed`.

## Rationalizations to reject

| Excuse | Reality |
|---|---|
| "The ticket already says what to test" | A ticket is prose; the block is checked. Copy the acceptance criteria into Steps and Expected. |
| "I'll write the block after the spec works" | Then the block describes the spec, not the requirement. The gate refuses the spec first on purpose. |
| "The selector is the clearest way to say the step" | Selectors belong in the repository. Steps say what the user does and sees. |
| "Status is bookkeeping" | Status is the only place a reader learns what was proved, when, and what is known broken. |

## Checklist

- [ ] Block exists, all nine fields filled, lint green, ID unique for each context
- [ ] Spec flat per `spec-shape.md`, title `'<ID> — <title>'`, known tags, oracle call visible
- [ ] Status updated from the verify note; `Corrected` bullets for any live contradiction
