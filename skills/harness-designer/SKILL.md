---
name: harness-designer
description: >
  Onboarding flow for the harness OS — the role-based operating layer
  that turns "orchestrator dispatches, inspector inspects, only the
  judge updates the ledger" from prose into hook-enforced permissions.
  Use this skill to design an agent harness with the user (roles,
  command groups, read/write scopes, dispatch rights), generate the
  .claude/harness-os.json manifest, and validate it. Works for ANY
  agentic workflow — QA pipelines, feature development, doc
  generation, research swarms.
---

# Harness designer — design the OS your agents run on

> Canonical home: [civitas-cerebrum/harness-os](https://github.com/civitas-cerebrum/harness-os).
> The copy inside the achilles QA package is vendored from here verbatim.

You are helping the user design an **agent harness operating system**: a
set of named roles, each with hook-enforced permission grants. The
output is a single manifest file the kernel hook
([`hooks/harness-os-role-gate.sh`](../../hooks/harness-os-role-gate.sh))
enforces on every tool call. Read
[references/architecture.md](references/architecture.md) before your
first design conversation — it defines the permission axes, the role
resolution ladder, and the enforcement guarantees you are allowed to
promise. Do not promise anything the architecture doc does not back.

Two rules frame every conversation:

1. **Least mandate.** Every role gets the smallest grant set that lets
   it do its job. When the user is unsure, start narrow — the kernel's
   deny messages name the missing grant, so widening later is cheap and
   informed; narrowing later means auditing what already leaked.
2. **Scope = context diet.** A role's read scope is not only a security
   boundary; it is the role's context budget. Sell it that way: "the
   reviewer that can't read the whole repo also can't waste its context
   window on it."

## The onboarding flow

### Phase 1 — Understand the workflow

Ask the user to walk through their workflow as steps, not roles ("first
something inspects the failure, then something proposes a fix, then
something reviews it against the criteria, then a verdict is
recorded"). From the steps, propose the role list — typical shapes:

| Archetype | Mandate | Typical grants |
|---|---|---|
| orchestrator | dispatch the appropriate agents to the tasks of a workflow; never does the work itself | `Agent` + task tools; read the ledger/workflow files; `dispatch` list |
| inspector | run inspection commands, read files relevant to its task | `Bash` (inspection group) + read scope |
| implementer | produce the deliverable | read + write scopes on the source tree; build/test command groups |
| reviewer | read the acceptance criteria and the deliverable — nothing else | read-only tools, two read scopes |
| judge | the only role that updates the ledger | `Write` scoped to the ledger file |

The archetypes are QA-flavoured because that is where the pattern was
born, but they generalise: an architect is an inspector with design-doc
write scope, a scribe is an implementer scoped to `docs/**`, a release
gatekeeper is a judge whose ledger is the changelog. See
[examples/feature-dev.harness-os.json](examples/feature-dev.harness-os.json)
for a complete non-QA harness.

Confirm the list with the user before going deeper. Fewer, sharper
roles beat many fuzzy ones.

### Phase 2 — Elicit the grants, one axis at a time

For each role, in this order (it mirrors the kernel's evaluation):

1. **Tools** — which tools does the mandate require? Offer the shortest
   list that works; remember `write` is opt-in (no `write` section = no
   writes) while `read` is opt-out.
2. **Command groups** — collect the Bash commands the role legitimately
   runs and generalise them into named `commandGroups` (POSIX ERE,
   anchored with `^`). Groups are shared across roles — name them by
   capability (`inspection`, `test-execution`, `build`), not by role.
   Warn the user that compound commands are checked per segment and
   that read-only roles get a built-in deny on file redirects.
3. **Read scope** — the files this role's task genuinely needs. Globs
   are repo-root-relative; `**` crosses directories. Remind them:
   pathless `Glob`/`Grep` counts as a root-wide search and will be
   denied for scoped roles — searches happen inside the scope.
4. **Write scope** — usually a subtree (implementer) or a single file
   (judge + ledger). The ledger ACL pattern: put the ledger in several
   roles' `read.allow` and exactly one role's `write.allow`.
5. **Dispatch** — who may this role spawn? Only orchestrator-shaped
   roles normally hold a `dispatch` list. Presence of the list also
   switches on the tagging discipline (below).
6. **MCP path arguments** — if any role uses an MCP tool that reads or
   writes files, add it to `settings.mcpPathArguments` (tool-name glob →
   which `tool_input` fields carry paths, split into `read`/`write`).
   Those paths then obey the same scopes as the core tools. Map each
   tool by the access it performs: a `*__read*` glob under `read`, a
   `*__write*` glob under `write` — a single glob listing a field as
   both would check a read call against the write scope. Unmapped MCP
   tools stay gated by name only, so say so out loud when you leave one
   unmapped.

### Phase 3 — Generate and validate the manifest

1. Write the manifest to `<repo-root>/.claude/harness-os.json`. Start
   from [examples/qa-pipeline.harness-os.json](examples/qa-pipeline.harness-os.json)
   or [examples/feature-dev.harness-os.json](examples/feature-dev.harness-os.json)
   when the workflow matches; otherwise from the axes elicited above.
2. Validate it against
   [`schemas/harness-os.schema.json`](../../schemas/harness-os.schema.json).
   Where the standalone package is installed, `npx harness-os validate`
   does this AND the cross-checks the schema cannot express (every
   `settings.mainSessionRole`, `dispatch` entry, and `bash.groups`
   entry must name an existing role / command group); otherwise run any
   JSON Schema 2020-12 validator and check the cross-references by
   hand.
3. Dry-run the boundaries with the user — and do it against the real
   kernel, not from reasoning about the manifest:

   ```bash
   harness-os explain --role reviewer --tool Read  --path docs/acceptance/x.md   # expect ALLOW
   harness-os explain --role reviewer --tool Write --path docs/ledger.json       # expect DENY
   harness-os explain --role inspector --tool Bash --command 'npx playwright test'
   ```

   For each role, run two calls its mandate covers and two adjacent ones
   it must refuse, and confirm the verdicts match intent. This is the
   design review, and it catches a too-narrow command group *before* the
   first live run. The deny messages quote the role `description`
   verbatim, so make those precise sentences.

### Phase 3b — Store it so it can be reused and swapped

A designed OS is worth keeping. Once the manifest validates, capture it
as a portable **bundle** so it can be version-pinned, shared, and swapped
in and out of projects — see
[references/storage-format.md](references/storage-format.md) for the full
model. In short:

```bash
harness-os export --to-library --revision 1.0.0   # store in ~/.harness-os/library
harness-os list                                    # what's on the shelf
harness-os use <name>@<rev>                         # swap this project's active OS
harness-os status                                   # active OS + drift check
```

The bundle (`.hos.json`) embeds the manifest verbatim plus an identity
(`name@revision`) and a content fingerprint; the kernel still only reads
the plain `.claude/harness-os.json`, so storage adds no enforcement
surface. Teach the user that swapping OSes resets runtime state by design
(a new role set invalidates old bindings), and that `status` flags a live
manifest that has drifted from the stored bundle.

### Phase 4 — Teach the dispatch discipline

The manifest only binds subagents that are dispatched correctly. The
orchestrator (human-written CLAUDE.md, a skill, or the main session
itself) must dispatch every subagent as:

```
description: "<role>-<slug>: <what this task is>"
prompt:      first line is the literal tag  <<harness-os-role: <role>#<nonce>>>
             then the role's mandate, then ONLY the context its scope covers
```

The `#<nonce>` (4+ chars of `[a-z0-9]`, unique per dispatch) is what
makes the binding exact: the kernel registers `nonce → role` at dispatch
and the child binds by the nonce in its own transcript, so **dispatching
several different roles in parallel stays unambiguous**. The plain
`<<harness-os-role: reviewer>>` form still works for a single dispatch;
teach the nonce as the default habit anyway — it costs six characters
and removes the only remaining identity caveat.

The kernel denies untagged dispatches from roles holding a `dispatch`
list, so the discipline is self-enforcing after day one. Also brief the
user on:

- **Bootstrap / redesign** — enforcement activates the moment the
  manifest exists. Governed roles can never edit the manifest or the
  state dir (root of trust); redesigns happen in a session launched
  with `HARNESS_OS=0` in the operator's shell, or by hand-editing the
  file outside a session.
- **Calibration is a workflow, not a chore.** Every deny lands in
  `.claude/harness-os.state/decision-log.jsonl`, and
  `harness-os doctor` reads it back as ranked, role-specific advice
  ("2× composer bash-segment-not-allowed → widen this command group").
  After the first real run, go through it with the user: repeated denies
  on legitimate work mean a grant is too narrow; zero denies ever may
  mean a scope is too wide to be doing anything.
- **When a deny is legitimate, widen narrowly.** For an indirection
  construct, `bash.permit: ["<construct>"]` unlocks exactly that one and
  nothing else — the deny message names the construct id, and `doctor`
  proposes the edit. Reserve `bash.unrestricted` for a role you have
  decided to trust wholesale; never reach for it to silence a single
  deny. Preview any widening with `harness-os explain` before editing.

## Worked examples

- [examples/registration-form-qa.harness-os.json](examples/registration-form-qa.harness-os.json)
  — **the benchmark.** A complete QA harness for automating the
  registration/submission form of the Achilles Vue test app
  (`FormsPage`: `#name #email #gender #mobile` date `#hobbies
  #currentAddress #city #submit`). The orchestrator dispatches; the
  inspector probes the live form with `playwright codegen` and reads the
  page repository; the composer writes and runs `tests/e2e/registration.spec.ts`;
  the reviewer reads only the acceptance criteria and that spec; the
  judge alone records the verdict in `docs/e2e-ledger.json`. Every step
  of that workflow — and every boundary violation a drifting agent would
  attempt — is exercised against the real kernel in
  [`hooks/tests/cases/03-benchmark-registration.sh`](../../hooks/tests/cases/03-benchmark-registration.sh).
  Use it as the template when onboarding any test-automation harness.
- [examples/qa-pipeline.harness-os.json](examples/qa-pipeline.harness-os.json)
  — the canonical QA shape: the orchestrator is only responsible for
  dispatching the appropriate agents to the tasks of the workflow; the
  inspector can only run inspection commands and read files relevant to
  its task; the reviewer can only read the acceptance criteria and the
  deliverable; the orchestrator can read the ledger, but only the judge
  can update it.
- [examples/feature-dev.harness-os.json](examples/feature-dev.harness-os.json)
  — the same kernel governing an ordinary feature-development pipeline:
  an architect that designs but cannot implement, an implementer that
  cannot touch the design docs it builds against, a tester that owns
  `tests/**` but not `src/**`, and a scribe scoped to `docs/**`.

## What this skill is not

- It is not tied to any methodology. The achilles QA package vendors it
  and deliberately excludes it from its protocol-activation list —
  designing a harness must not switch on someone's QA commit grammar.
- It does not replace Claude Code's own permission system; the kernel
  is a *narrowing* layer on top of it.
- It is not a sandbox: the kernel is a hook, so it governs tool calls
  in sessions where the hooks are installed. Its guarantees are
  separation-of-duties and context hygiene, not adversarial isolation.
