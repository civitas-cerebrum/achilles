---
name: mandate-designer
description: >
  Onboarding flow for the kernel mandate — the role-based operating layer
  that turns "orchestrator dispatches, inspector inspects, only the
  judge updates the ledger" from prose into hook-enforced permissions.
  Use this skill to design an agent harness with the user (roles,
  command groups, read/write scopes, dispatch rights), generate the
  .claude/kernel-mandate.json manifest, and validate it. Works for ANY
  agentic workflow — QA pipelines, feature development, doc
  generation, research swarms.
---

# Mandate designer — design the boundaries your agents run inside

> Canonical home: [civitas-cerebrum/kernel-mandate](https://github.com/civitas-cerebrum/kernel-mandate).
> The copy inside the achilles QA package is vendored from here verbatim.

You are helping the user design an **agent harness operating system**: a
set of named roles, each with hook-enforced permission grants. The
output is a single manifest file the kernel hook
([`hooks/kernel-mandate-role-gate.sh`](../../hooks/kernel-mandate-role-gate.sh))
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
[examples/feature-dev.kernel-mandate.json](examples/feature-dev.kernel-mandate.json)
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

   And say the harder half out loud, because a redirect is not the only
   way a command writes: **ask what each granted verb can DO, not how it
   is spelled.** A command group is a regex over argv. `npm install`
   runs the lifecycle scripts of whatever it installs; `playwright
   codegen` drives a browser and writes traces, HARs and generated
   scripts wherever it is pointed; `make` runs whatever a Makefile says.
   The kernel refuses install and build-recipe verbs unless the role
   opts in, and holds every output flag and `file://` operand to the
   role's scopes — but a group named `form-probe` or `build` reads as
   narrow while granting a general-purpose tool, and that is the shape
   two review rounds broke this project's own shipped templates on.
3. **Read scope** — the files this role's task genuinely needs. Globs
   are repo-root-relative; `**` crosses directories. Remind them:
   pathless `Glob`/`Grep` counts as a root-wide search and will be
   denied for scoped roles — searches happen inside the scope.
4. **Write scope** — usually a subtree (implementer) or a single file
   (judge + ledger). The ledger ACL pattern: put the ledger in several
   roles' `read.allow` and exactly one role's `write.allow`.
   **If the role writes executable files** (specs, scripts), say so out
   loud: code it authors is code something will run, so the kernel denies
   filesystem / process / network / eval surfaces inside that code unless
   you declare them (`write.codeCapabilities`). A framework-driven test
   needs none — if the user insists a spec needs `fs`, that is a design
   smell worth questioning before granting it.
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

1. Write the manifest to `<repo-root>/.claude/kernel-mandate.json`. Start
   from [examples/qa-pipeline.kernel-mandate.json](examples/qa-pipeline.kernel-mandate.json)
   or [examples/feature-dev.kernel-mandate.json](examples/feature-dev.kernel-mandate.json)
   when the workflow matches; otherwise from the axes elicited above.
2. Validate it against
   [`schemas/kernel-mandate.schema.json`](../../schemas/kernel-mandate.schema.json).
   Where the standalone package is installed, `npx kernel-mandate validate`
   does this AND the cross-checks the schema cannot express (every
   `settings.mainSessionRole`, `dispatch` entry, and `bash.groups`
   entry must name an existing role / command group); otherwise run any
   JSON Schema 2020-12 validator and check the cross-references by
   hand.
3. Dry-run the boundaries with the user — and do it against the real
   kernel, not from reasoning about the manifest:

   ```bash
   kernel-mandate explain --role reviewer --tool Read  --path docs/acceptance/x.md   # expect ALLOW
   kernel-mandate explain --role reviewer --tool Write --path docs/ledger.json       # expect DENY
   kernel-mandate explain --role inspector --tool Bash --command 'npx playwright test'
   ```

   For each role, run two calls its mandate covers and two adjacent ones
   it must refuse, and confirm the verdicts match intent. This is the
   design review, and it catches a too-narrow command group *before* the
   first live run. The deny messages quote the role `description`
   verbatim, so make those precise sentences.

### Phase 3b — Store it so it can be reused and swapped

A designed mandate is worth keeping. Once the manifest validates, capture it
as a portable **bundle** so it can be version-pinned, shared, and swapped
in and out of projects — see
[references/storage-format.md](references/storage-format.md) for the full
model. In short:

```bash
kernel-mandate export --to-library --revision 1.0.0   # store in ~/.kernel-mandate/library
kernel-mandate list                                    # what's on the shelf
kernel-mandate use <name>@<rev>                         # swap this project's active mandate
kernel-mandate status                                   # active mandate + drift check
```

The bundle (`.km.json`) embeds the manifest verbatim plus an identity
(`name@revision`) and a content fingerprint; the kernel still only reads
the plain `.claude/kernel-mandate.json`, so storage adds no enforcement
surface. Teach the user that swapping mandates resets runtime state by design
(a new role set invalidates old bindings), and that `status` flags a live
manifest that has drifted from the stored bundle.

### Phase 4 — Teach the dispatch discipline

The manifest only binds subagents that are dispatched correctly. The
orchestrator (human-written CLAUDE.md, a skill, or the main session
itself) must dispatch every subagent as:

```
description: "<role>-<slug>: <what this task is>"
prompt:      first line is the literal tag  <<kernel-mandate-role: <role>#<nonce>>>
             then the role's mandate, then ONLY the context its scope covers
```

The `#<nonce>` (4+ chars of `[a-z0-9]`, unique per dispatch) is what
makes the binding exact: the kernel registers `nonce → role` at dispatch
and the child binds by the nonce in its own transcript, so **dispatching
several different roles in parallel stays unambiguous**. The plain
`<<kernel-mandate-role: reviewer>>` form still works for a single dispatch;
teach the nonce as the default habit anyway — it costs six characters
and removes the only remaining identity caveat.

Do not hand-write "the role's mandate" — generate it, so it cannot
disagree with what the kernel actually enforces:

```bash
kernel-mandate brief --role composer              # read it yourself
kernel-mandate brief --role composer --dispatch   # paste-ready, already tagged
```

`brief` renders the role's tools, read/write scopes, command patterns,
dispatch and skill grants, and the constructs it must not attempt,
straight from the manifest. Teach the orchestrator to open every dispatch
with it. This is not documentation politeness: the benchmark measured
working roles spending 15–17 tool calls discovering their own boundaries
by hitting denies, and every one of those was context spent on the
harness instead of on the task. A brief that is generated cannot drift
from the boundary the way a prompt written once and copied forever does.

The kernel denies untagged dispatches from roles holding a `dispatch`
list, so the discipline is self-enforcing after day one. Also brief the
user on:

- **Bootstrap / redesign** — enforcement activates the moment the
  manifest exists. Governed roles can never edit the manifest or the
  state dir (root of trust); redesigns happen in a session launched
  with `KERNEL_MANDATE=0` in the operator's shell, or by hand-editing the
  file outside a session.
- **Calibration is a workflow, not a chore.** Every deny lands in
  `.claude/kernel-mandate.state/decision-log.jsonl`, and
  `kernel-mandate doctor` reads it back as ranked, role-specific advice
  ("2× composer bash-segment-not-allowed → widen this command group").
  After the first real run, go through it with the user: repeated denies
  on legitimate work mean a grant is too narrow; zero denies ever may
  mean a scope is too wide to be doing anything.
- **When a deny is legitimate, widen narrowly.** For an indirection
  construct, `bash.permit: ["<construct>"]` unlocks exactly that one and
  nothing else — the deny message names the construct id, and `doctor`
  proposes the edit. Reserve `bash.unrestricted` for a role you have
  decided to trust wholesale; never reach for it to silence a single
  deny. Preview any widening with `kernel-mandate explain` before editing.
- **A role that authors code AND runs it needs the runtime profile.**
  The kernel gates tool calls; it cannot gate what a granted tool call
  executes. Where you cannot split authoring from running into two
  roles, make the command group require the wrapper:

  ```jsonc
  "commandGroups": {
    "test-execution": ["^kernel-mandate run --role composer -- npx playwright test\\b"]
  }
  ```

  `kernel-mandate run` execs the command under Node's permission model built
  from that role's path scopes, so authored code is refused by the
  *runtime* even when the static screen has no pattern for its spelling.
  Walk `kernel-mandate run --role <r> --dry-run -- <cmd>` with the user
  before adopting it: it prints the profile, names every
  sensitive-looking file a recursive directory grant would expose, and
  flags any runner path that contains the project. The layout rule it
  implies is worth agreeing out loud — **keep secrets out of any
  directory a role's scope covers**, because an allow-list permission
  model has no deny-list to fix it with.

## If you are an AGENT, not a person running a design session

Two situations, and they call for opposite behaviour.

### You joined a project that is already governed

Orient before you act. Three commands, in order:

```bash
kernel-mandate status                 # is enforcement actually ON? which mandate is live?
kernel-mandate brief --role <yours>   # your scopes, command patterns, and what you must not attempt
kernel-mandate explain --role <yours> --tool Bash --command '<the thing you were about to run>'
```

`status` is the one people skip and the one that matters: a hook can be
*registered* while the package is absent, in which case `.claude/settings.json`
says the project is governed and nothing is being enforced. It says so
out loud rather than letting you believe otherwise.

Then read your denies as information, not obstacles. Each one names the
missing grant and the narrowest widening that would fix it. If a deny is
wrong, say so to the operator with the exact command and the exact
message — do not route around it, and never reach for `bash.unrestricted`
to silence one. **You cannot edit the mandate that governs you**, by
design; a redesign happens in a session the operator launches with
`KERNEL_MANDATE=0`.

### You have finished work in a project that is NOT governed, and a mandate would help

You are the wrong party to install one. The roles encode somebody's
intent about separation of duties, and a mandate an agent writes for
itself is a mandate it could have written to suit itself. So **draft,
and hand it over**:

1. Write the candidate manifest anywhere EXCEPT `.claude/kernel-mandate.json`
   — `/tmp/mandate-draft.json` is fine. Base it on what the work actually
   did: the files each step read, the commands it ran, who checked whose
   output.
2. Review it mechanically and show the operator the output:

   ```bash
   kernel-mandate propose /tmp/mandate-draft.json
   ```

   `propose` validates the draft, renders what each role could actually
   do, diffs it against any live mandate, and reports the two structural
   risks no schema can express: a role that both **authors and runs**
   code, and a role that **writes what another role reads**. It writes
   nothing — deliberately. It refuses to be pointed at the live manifest.
3. Dry-run the boundaries you are least sure of with `explain`, and put
   those verdicts in front of the operator too.
4. **Stop.** Applying it is `init`, `import --activate`, or a copy — all
   things a person does knowingly.

The two risks `propose` reports are not lint. Every escape in rounds
45–50 of the review log was a role that authored code and ran it, and
round 51's was a graded role writing into its grader's read scope. If
your draft has either, say which and why you think it is acceptable —
that sentence is the design decision, and it belongs to the operator.

## Worked examples

- [examples/registration-form-qa.kernel-mandate.json](examples/registration-form-qa.kernel-mandate.json)
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
- [examples/qa-pipeline.kernel-mandate.json](examples/qa-pipeline.kernel-mandate.json)
  — the canonical QA shape: the orchestrator is only responsible for
  dispatching the appropriate agents to the tasks of the workflow; the
  inspector can only run inspection commands and read files relevant to
  its task; the reviewer can only read the acceptance criteria and the
  deliverable; the orchestrator can read the ledger, but only the judge
  can update it.
- [examples/feature-dev.kernel-mandate.json](examples/feature-dev.kernel-mandate.json)
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
