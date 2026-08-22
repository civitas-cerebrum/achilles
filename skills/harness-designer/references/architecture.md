# Harness OS — Architecture

> Canonical home: [civitas-cerebrum/harness-os](https://github.com/civitas-cerebrum/harness-os).
> The copy inside the achilles QA package is vendored from here verbatim —
> edit upstream, never the vendored copy.

The harness OS is a role-based operating layer for multi-agent harnesses.
A project declares its agent roles once, in a machine-readable manifest,
and a single generic hook enforces every role's boundaries at tool-call
time. The design goal is twofold:

1. **Separation of duties** — an inspector can only inspect, a reviewer
   can only read the acceptance criteria and the deliverable, only the
   judge can update the ledger. No role can grade its own work or reach
   outside its mandate.
2. **Context-load hygiene** — a role that *cannot* read outside its scope
   never pollutes its context window with irrelevant files. The
   permission boundary doubles as a context budget: the reviewer's
   read-scope IS its context diet.

Because enforcement lives in hooks (not in prompts), the guarantees hold
for any harness built on top — QA fleets, feature-development pipelines,
doc generators, research swarms — without per-harness hook code. The
manifest is the harness; the hook is the kernel.

## The three pieces

| Piece | File | Job |
|---|---|---|
| Manifest schema | [`schemas/harness-os.schema.json`](../../../schemas/harness-os.schema.json) | Validates a project's role manifest |
| Kernel hook | [`hooks/harness-os-role-gate.sh`](../../../hooks/harness-os-role-gate.sh) | PreToolUse `.*` — resolves the caller's role, enforces its grants |
| Onboarding skill | [`skills/harness-designer/SKILL.md`](../SKILL.md) | Interviews the user, writes + validates the manifest |

The standalone package adds a CLI (`npx harness-os init` to register the
hook project-locally or globally, `npx harness-os validate` to check a
manifest including the cross-references JSON Schema cannot express).

## The manifest

Lives at `<repo-root>/.claude/harness-os.json` in the *consumer* project
(override with `HARNESS_OS_MANIFEST` for tests). **Presence of the
manifest is the activation signal**: no manifest → the kernel hook
silent-allows everything, so an installed hook never polices projects
that did not opt in. `HARNESS_OS=0` in the operator's shell environment
(set before launching the session — agents cannot alter hook env from
inside) disables enforcement for bootstrap/redesign sessions.

```jsonc
{
  "harnessOsVersion": 1,
  "name": "qa-pipeline",
  "settings": {
    "mainSessionRole": "orchestrator",   // omit → main session ungoverned
    "unboundAgentPolicy": "readonly"     // deny | readonly | allow
  },
  "commandGroups": {
    "inspection": ["^git (status|log|diff|show)\\b", "^(ls|find|wc|file|stat)\\b"],
    "test-execution": ["^(npx|yarn|pnpm exec) playwright\\b", "^npm (test|run test)\\b"]
  },
  "roles": {
    "orchestrator": {
      "description": "Dispatches workflow tasks to the right role. Never does the work itself.",
      "tools":   { "allow": ["Agent", "Read", "Glob", "Grep", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet"] },
      "read":    { "allow": ["docs/ledger.json", "workflows/**"] },
      "dispatch": ["inspector", "implementer", "reviewer", "judge"]
    },
    "inspector": {
      "description": "Runs inspection commands and reads files relevant to its task.",
      "tools": { "allow": ["Bash", "Read", "Glob", "Grep"] },
      "bash":  { "groups": ["inspection"] },
      "read":  { "allow": ["src/**", "tests/**", "docs/**"] }
    },
    "implementer": {
      "description": "Writes the deliverable.",
      "tools": { "allow": ["Bash", "Read", "Glob", "Grep", "Write", "Edit"] },
      "bash":  { "groups": ["inspection", "test-execution"] },
      "read":  { "allow": ["src/**", "tests/**", "docs/acceptance/**"] },
      "write": { "allow": ["src/**", "tests/**"] }
    },
    "reviewer": {
      "description": "Reads acceptance criteria and the deliverable. Nothing else.",
      "tools": { "allow": ["Read", "Glob", "Grep"] },
      "read":  { "allow": ["docs/acceptance/**", "src/**", "tests/**"] }
    },
    "judge": {
      "description": "The only role that may update the ledger.",
      "tools": { "allow": ["Read", "Write", "Edit"] },
      "read":  { "allow": ["docs/**"] },
      "write": { "allow": ["docs/ledger.json"] }
    }
  }
}
```

The canonical governance patterns fall straight out of the axes:

- *"Orchestrator only dispatches"* → `tools.allow` has `Agent` but no
  `Write`/`Bash`; `dispatch` lists who it may spawn.
- *"Inspector can only run inspection commands and read files relevant
  to its task"* → `bash.groups: ["inspection"]` + `read.allow` scopes.
- *"Reviewer can only read acceptance criteria and the deliverable"* →
  read-only tools + two read scopes.
- *"Orchestrator can read the ledger but only the judge can update it"*
  → the ledger appears in orchestrator's `read.allow` and ONLY in
  judge's `write.allow`. A ledger is not a special-cased concept — it is
  the write-ACL pattern applied to one file.

Worked manifests: [examples/qa-pipeline.harness-os.json](../examples/qa-pipeline.harness-os.json)
(the QA shape above) and
[examples/feature-dev.harness-os.json](../examples/feature-dev.harness-os.json)
(architect / implementer / tester / scribe — the same kernel governing an
ordinary feature-development pipeline, no QA methodology anywhere).

## Permission axes

Evaluated in this order inside the kernel; first deny wins.

1. **Built-in self-protection** — a governed context may never Write/Edit
   the manifest or the kernel's state dir, and may not run write-shaped
   Bash against them. Unconditional; keeps the root of trust out of any
   role's reach. (Ungoverned contexts — no manifest role bound — are the
   operator's design surface and stay free.)
2. **Tool gate** — `tools.deny` then `tools.allow` (shell-glob patterns
   against the tool name, e.g. `mcp__github__*`). Absent `tools` →
   all tools pass to the finer axes.
3. **Bash command gate** — the command is split on `&&`, `||`, `;`, `|`
   (quote-blind, protective direction) and EVERY segment must match at
   least one allow regex (union of the role's `bash.groups` expansion +
   `bash.allow`) and no deny regex. A role with no `write` grants also
   gets a built-in deny on file-redirect shapes (`>`/`>>` after
   stripping `2>/dev/null`-style fd noise) — Bash must not launder
   writes for a read-only role. Absent `bash` section with Bash allowed
   → any command.
4. **Read scope** — `Read`/`Glob`/`Grep`/`NotebookRead` paths are
   repo-root-relativised and matched against `read.allow`/`read.deny`
   globs (`**` crosses directories, `*` stays within one). A `Glob`/
   `Grep` call with no `path` counts as the repo root and needs a
   root-covering grant — scoped roles are expected to search inside
   their scope. Absent `read` section → unrestricted paths.
5. **Write scope** — same mechanics for `Write`/`Edit`/`NotebookEdit`
   over `write.allow`/`write.deny`. Absent `write` section → NO writes
   (write is opt-in, read is opt-out; the asymmetry is deliberate).
6. **Dispatch gate** (`Agent` tool) — if the caller's role carries a
   `dispatch` list, the dispatch description must start with
   `<role>:` or `<role>-<slug>:` for a role in that list, and the prompt
   must carry the binding tag (below). A `dispatch` list also implies
   un-prefixed dispatches are denied — untagged children would be
   unbindable. Absent `dispatch` with `Agent` allowed → unrestricted.
7. **Skill gate** — optional `skills.allow` patterns against the Skill
   tool's `skill` input.

Deny payloads use the standard Claude Code
`hookSpecificOutput.permissionDecision: "deny"` JSON with a reason that
names the role, the violated grant, and the sanctioned alternative —
the deny message is part of the OS's teaching surface.

## Role resolution (the kernel's hardest problem)

A hook invocation must answer *"which role is calling?"* from the hook
input alone. The Claude Code build gives us:

- top-level (orchestrator/main-session) tool calls carry **no
  `agent_id`**; dispatched-subagent calls carry a non-empty `agent_id`
  (+ `agent_type`);
- the dispatching `Agent` call's `tool_use_id` is visible at
  PreToolUse:Agent time, but current builds do NOT echo it as
  `parent_tool_use_id` on the child's calls;
- `transcript_path` may point at the child's own transcript, which
  contains its dispatch prompt.

So the kernel binds identity with a resolution ladder, strongest signal
first, and records the outcome in
`<repo-root>/.claude/harness-os.state/agents/<agent_id>` so the ladder
runs once per agent:

1. **No `agent_id`** → `settings.mainSessionRole` (unset → ungoverned;
   silent allow).
2. **Cached binding** for this `agent_id` → that role.
3. **`parent_tool_use_id`** present and found in the dispatch registry →
   exact match; bind.
4. **Transcript tag** — dispatch prompts must embed
   `<<harness-os-role: NAME>>` (the dispatch gate denies prompts without
   it). If the transcript at `transcript_path` contains exactly ONE
   distinct tag, it is the child's own transcript → bind to that role.
   Multiple distinct tags → it is a parent-wide transcript; fall
   through.
5. **Registry claim** — the dispatch registry
   (`.claude/harness-os.state/dispatch-registry.json`, written at
   PreToolUse:Agent, entries `{tool_use_id: {role, ts, claimed_by}}`,
   30-min TTL) is filtered to fresh, unclaimed entries. If all of them
   name ONE role → claim the oldest and bind. Mixed roles in flight →
   ambiguous; fall through.
6. **Unresolvable** → `settings.unboundAgentPolicy`:
   `deny` (block with re-dispatch guidance), `readonly` (default —
   allow only `Read`/`Glob`/`Grep`/`TaskGet`/`TaskList`), or `allow`.

Accepted-limitation note: when different roles are dispatched in
parallel AND the build supplies neither `parent_tool_use_id` nor
per-child transcripts, step 5 cannot disambiguate and the fallback
policy governs. Orchestrators that need hard guarantees under mixed
parallel dispatch should serialise role-heterogeneous waves; same-role
fan-out is always safe.

## Relationship to the achilles QA harness

[civitas-cerebrum/achilles](https://github.com/civitas-cerebrum/achilles)
is the flagship consumer: its autonomous QA methodology vendors this
package (kernel, schema, and this skill, synced verbatim from here) so
QA pipelines can be described as manifests. The dependency points one
way only — the kernel never sources achilles' session-activation lib
([`achilles-activation.sh`](https://github.com/civitas-cerebrum/achilles/blob/main/hooks/lib/achilles-activation.sh)):
achilles activation scopes the *QA methodology* gates to methodology
sessions, whereas the harness OS scopes itself by manifest presence in
the project. The two compose — an achilles pipeline can itself be
described by a manifest — but neither depends on the other, and
`harness-designer` is intentionally absent from achilles' activation
list so designing a harness never switches on the QA methodology's
commit grammar and ledger gates in an unrelated project.

## State, logging, protection

- State dir: `<repo-root>/.claude/harness-os.state/` —
  `dispatch-registry.json`, `agents/<agent_id>` bindings, and
  `decision-log.jsonl` (one line per deny, for calibrating
  over-broad grants before tightening the manifest).
- Both the manifest and the state dir are covered by the built-in
  self-protection axis; the deny message routes changes to an
  operator-run design session (`HARNESS_OS=0`) or a hand edit.
- All state writes are atomic (`tmp` + `mv`) and TTL-pruned.

## False-positive direction

Everywhere the kernel guesses, it guesses toward deny-with-guidance:
quote-blind Bash segmentation, root-as-path for pathless searches,
write-opt-in defaults, unbound → readonly. A wrongly-denied call costs
one re-dispatch with a corrected grant; a wrongly-allowed call breaks
the separation-of-duties story the manifest was written to buy. Every
deny names the fix.
