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
   (quote-aware: a separator inside quotes is not a separator) and EVERY
   segment must match at least one allow regex (union of the role's `bash.groups` expansion +
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
   their scope; a `..` segment in the search *pattern* (which is applied
   under the path) is denied so it cannot climb out of the scoped root.
   Absent `read` section → unrestricted paths.
5. **Write scope** — same mechanics for `Write`/`Edit`/`NotebookEdit`
   over `write.allow`/`write.deny`. Absent `write` section → NO writes
   (write is opt-in, read is opt-out; the asymmetry is deliberate).
5b. **Write-then-execute containment** — code authored into an
   executable file type (`.js/.ts/.py/.sh/…`) may not reach for host
   capabilities — filesystem (`fs`/`os`/`shutil`), process spawning
   (`child_process`/`subprocess`), raw network (`net`/`http`/`socket`),
   or `eval`/dynamic import — unless the role declares them in
   `write.codeCapabilities`. See below for why this axis exists.
6. **Dispatch gate** (`Agent` tool) — if the caller's role carries a
   `dispatch` list, the dispatch description must start with
   `<role>:` or `<role>-<slug>:` for a role in that list, and the prompt
   must carry the binding tag (below). A `dispatch` list also implies
   un-prefixed dispatches are denied — untagged children would be
   unbindable. Absent `dispatch` with `Agent` allowed → unrestricted.
7. **Skill gate** — optional `skills.allow` patterns against the Skill
   tool's `skill` input.
8. **MCP argument scoping** — for tools named in
   `settings.mcpPathArguments`, the declared `tool_input` fields are
   read as paths and held to the role's read/write scopes (see Known
   limits for what stays name-gated).

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
   `<<harness-os-role: NAME[#NONCE]>>` (the dispatch gate denies prompts
   without a tag). Two sub-steps, strongest first:
   - **4a — nonce match.** When the tag carries a unique `#NONCE`, the
     dispatch gate registers `nonce → role` at dispatch time, and the
     child binds by the nonce in its own transcript. This is exact: it
     survives a transcript that also quotes another role's tag, and it
     is what makes **mixed parallel dispatch unambiguous**. Always add a
     nonce when dispatching several different roles at once.
   - **4b — nonce-free fallback.** Otherwise, if the transcript's
     user-authored tags name exactly ONE distinct role, that is the
     identity. Multiple distinct roles → parent-wide transcript; fall
     through.
   Only user-authored transcript lines are scanned, so an agent echoing
   a foreign tag in its own output cannot poison its binding.
5. **Registry claim** — the dispatch registry
   (`.claude/harness-os.state/dispatch-registry.json`, written at
   PreToolUse:Agent, entries `{tool_use_id: {role, ts, claimed_by}}`,
   30-min TTL) is filtered to fresh, unclaimed entries. If all of them
   name ONE role → claim the oldest and bind. Mixed roles in flight →
   ambiguous; fall through.
6. **Unresolvable** → `settings.unboundAgentPolicy`:
   `deny` (block with re-dispatch guidance), `readonly` (default —
   allow only `Read`/`Glob`/`Grep`/`TaskGet`/`TaskList`), or `allow`.

Residual limitation: a child that has **no transcript of its own** and
arrives while several *different* roles are in flight cannot be
disambiguated by any rung (there is nothing left to key on), so the
`unboundAgentPolicy` governs — protectively, `readonly` by default.
Nonces close the common case: with a nonce in every dispatch tag, any
child whose transcript is visible binds exactly, so mixed parallel
dispatch is no longer a caveat. Same-role fan-out is always safe.

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

## Leak-proofing the Bash channel

Bash is the widest laundering channel a role has — one allowed binary
can read, write, or execute anything if the gate only pattern-matches
the command name. The kernel closes this with six sub-checks per
command, run over every segment (the command is split on `&&`, `||`,
`;`, `|`, `&`, and newlines — quote-aware, and after fd-plumbing like
`2>&1` is masked so a lone `&` can be split without shredding a
redirect):

1. **Indirection denies** — `$(…)`/`` `…` ``/`$VAR`, process
   substitution, `eval`, `xargs`, a shell or interpreter one-liner
   (`sh -c`, `python -c`) as the command, `find -exec`/`-delete`, `cd`
   (which would un-anchor every relative path the gate checks), and
   `{a,b}` brace expansion (which hides the expanded filename). Each
   lets a segment that *matches* an allow pattern do something the
   pattern never saw, so all are denied for governed roles. Leading
   command-runner wrappers (`env`, `sudo`, `nohup`, `timeout N`,
   `nice`, `time`, `exec`, …) are stripped first, so
   `env sh -c …`/`timeout 5 python -c …`/`sudo bash` can't hide a shell
   behind a wrapper whose own name matches an allow pattern. The
   `bash.permit` unlocks named constructs one at a time for a role that
   legitimately needs them (`["var-expansion"]` for a role that uses
   `"$HOME"`), leaving every other construct and every other axis in
   force — this is the intended answer to a legitimate deny, and it
   exists so nobody reaches for a blanket waiver out of frustration. A
   permitted expansion still cannot smuggle a path: an expansion inside
   a path-shaped token is denied as *unverifiable*, since the kernel
   cannot resolve it to check the read scope. `bash.unrestricted: true`
   remains the nuclear option for a deliberately-trusted role (explicit
   denies, redirect scope, and read scope still apply); the schema
   documents the cost.
2. **Allow-set** — every segment must match one of the role's command
   groups.
3. **Deny patterns** — explicit `bash.deny` regexes, checked with a
   dedicated message.
4. **Write targets** — anything that names a destination is held to the
   same `write.allow` scope as the Write tool (and denied outright for a
   role with no write grants): a `>`/`>>`/`tee` target that survives the
   fd-mask, the destination operand of an ordinary file verb
   (`cp`, `mv`, `dd of=`, `install`, `sed -i`, `truncate`, `ln`,
   `rsync`), and output *flags* (`--output`, `-fprintf`, `-fls`, and
   `-o` for the commands that spell output that way). Enumerating write
   verbs kept losing to the next tool — three review rounds found
   `cp`/`mv`/`sed -i`, then `sort -o`, then `find -fprintf` — so the flag
   form is matched generically rather than per verb. Every write target,
   whatever produced it, also faces the self-protection axis: a role with
   *any* write grant still cannot aim one at the manifest, the state
   directory, or the kernel itself.
5. **Read tokens** — every token that resolves (glob-aware) to an
   existing file/dir must be inside `read.allow ∪ write.allow`, so
   `cat ../secrets/x` through an allowed `cat` is denied exactly as a
   `Read` of that path would be. The manifest itself is always readable.
6. **Version-control history** — history is a second copy of the working
   tree, and every scope in this kernel is written against the working
   tree. `git show HEAD:.env` names no existing path, so axis 5 never
   sees it; a reviewer used exactly that to read a secret past a
   read-only role's scope. Content-bearing git subcommands are now held
   to the read scope directly: a `<rev>:<path>` operand and any pathspec
   after `--` are scope-checked, and a form with no path constraint at
   all (`git log -p`, `git diff HEAD`, `git grep x`, `git archive HEAD`)
   is denied as the construct `vcs-history`, permittable per role like
   any other. Metadata forms — `git status`, `git log` without a patch
   flag, `--stat`, `--name-only` — print no file bodies and are
   untouched, and `-C`/`--git-dir`/`--work-tree` pointing at another
   repository is refused for the same reason `cd` is.

Paths on every axis are lexically normalised (`realpath -m`, with a
pure-bash `..`-collapsing fallback) *before* scope matching, so
`src/../.env` cannot ride an `src/**` grant.

### Quoting is not decoration

The kernel used to strip every quote character before scanning, which
conflates the two things the shell keeps strictly apart: a quoted word is
a *literal*, an unquoted one is a *pattern the shell expands*. That made
`find tests -name "*.json"` look like a read of every JSON file in the
project, including ones outside the role's scope — a false deny on about
as ordinary a command as exists, and the kind that gets a gate switched
off. Segments are now tokenised quote-aware: an unquoted word is
glob-expanded and scope-checked, a fully quoted one is checked only
against itself. The same distinction drives the construct checks —
brace expansion and globbing are suppressed by either quote style,
`$…` and `` `…` `` only by single quotes — so `echo '{"a":1,"b":2}'` is
JSON and `cat {.env,x}` is still an escape attempt.

Segmentation is quote-aware for the same reason. It was quote-blind on
the argument that over-splitting can only cause a deny, never an allow —
true, and also unusable: `echo "await steps.click('x');" >> spec.ts`
split mid-string, and the fragment `" >> spec.ts` matched no command
pattern, so writing most lines of JavaScript through Bash was refused
with a message about command patterns. A separator inside quotes is not a
separator, so it no longer splits; placeholders carry it through and are
restored after, leaving each segment byte-identical to what the shell
will run.

Redirection is read from a quote-masked view of the **un-stripped**
segment. Both halves earned their place. Un-stripped, because the
assignment and wrapper strips consume a `NAME=value` run and
`env X=1<.env cat` hides an entire redirection inside one — a reviewer
used exactly that to read a secret, write outside every scope, and
overwrite the kernel itself from a role with no write grants at all.
Quote-masked, because `grep '=>' spec.ts` is not a redirection, and a
gate that denies the arrow operator is a gate nobody keeps switched on.

A backslash escapes the next character everywhere except inside single
quotes, and the scanner honours that before anything else. `\"` is a
literal quote and does not open a string; missing that hid `cat .env`
after a `;` the scanner believed was inside quotes. An unterminated
quote is refused outright: everything after it reads as inert string, so
the scanner's idea of what is syntax has diverged from any shell's — and
a shell refuses such a command anyway.

Quoting never decides which word is the *command*, though: `"cat" .env`
still runs cat, so the command-name and allow-set checks read the
segment verbatim.

Operands that a command's own grammar defines as patterns rather than
paths are exempt from the read scan by position — grep's pattern (or its
`-e` operand, but never its `-f` operand, which is a real file read),
`sed`/`awk`'s program text, and the operand of `find -name`/`-path`/
`-regex`. `grep package.json src/` does not read `package.json`, and a
deny saying it does is one an operator cannot act on.

## Why write-then-execute containment exists

This axis was not designed in the abstract — it closes an escape found by
running the benchmark ([`hooks/tests/cases/03-benchmark-registration.sh`](../../../hooks/tests/cases/03-benchmark-registration.sh)
against the live app). The composer role holds `write: tests/e2e/**` and
a command group containing `npx playwright test`. Both grants are
obviously correct in isolation. Together they are a complete bypass:

```ts
// tests/e2e/anything.spec.ts — inside the composer's write scope
import * as fs from 'fs';
test('x', async () => { fs.readFileSync('.env', 'utf8'); });  // then: npx playwright test
```

The kernel gates **tool calls**, not the code a granted tool call
executes. The spec is written with an allowed tool to an allowed path,
and run with an allowed command — every axis passes, and the role reads a
file its read scope forbids. This was reproduced end to end: the secret
was exfiltrated.

The general principle: **a role that can author code holds, in effect,
whatever permissions that code will have when something runs it** — its
own test command, CI, or another role. Path scopes only bind if the code
inside the path stays inside them. So the kernel checks authored content
for the capability surfaces that escape the role's envelope, and a
legitimate need is declared explicitly:

```jsonc
"write": { "allow": ["tests/**"], "codeCapabilities": ["fs"] }
```

Calibration is deliberate and tested: the benchmark's real 74-line
framework-driven spec passes untouched, as does a spec reading
`process.env` config or mentioning `fs` in a comment — a containment that
blocked ordinary test authoring would be switched off within a day.

**What this axis is and is not.** It is a static, pattern-based check,
and an independent adversarial reviewer broke its first version with
`await import("node:fs")` — a synonym, not a contortion. The matcher now
normalises quoting, `node:` prefixes and string concatenation before
matching, and covers dynamic `import()`, `require` with any quote form,
`process.getBuiltinModule`, python's comma/`from`-import forms, bare
`open(`, `fetch(`, and `file://` URLs; every one of those is a regression
test in `hooks/tests/cases/08-reviewer-round1.sh`. Later rounds added
octal escapes, `String.fromCharCode` module names, computed-member method
access (`m["read"+"File"+"Sync"](…)`), `process.binding`, and the
backslash-escaped quoting that arrives when code is authored through
Bash. But a static check on a Turing-complete language cannot be
complete, and no amount of pattern work will make it so.

The screen is a shared function both authoring routes run. It was wired
only to Write/Edit until round 4, which meant
`echo 'require("fs")…' > tests/e2e/x.spec.ts` put the identical code on
disk inside the role's own write scope with nothing looking at it, and
the role's granted test command then ran it. An axis that guards one
door and not the other guards nothing; the bash route screens the whole
command, because `echo <code> | tee spec.ts` carries the code in the
segment *before* the one naming the file.

So do not read this axis as "the write-then-execute escape is closed".
Read it as: **authoring an escape now costs deliberate obfuscation
instead of a standard-library import**. The sound fix is structural —
*separate the role that authors code from the role that runs it*, so no
single mandate spans both. `harness-os validate` warns when one role
holds both, and the designer skill teaches the split. Where the split is
impractical, this axis is defence in depth, not a boundary you should
stake a security claim on.

## False-positive direction

Everywhere the kernel guesses, it guesses toward deny-with-guidance:
root-as-path for pathless searches, write-opt-in defaults, unbound →
readonly, an unrecognised construct in a command → deny, an unterminated
quote → deny. A wrongly-denied call costs one re-dispatch with a
corrected grant; a wrongly-allowed call breaks the separation-of-duties
story the manifest was written to buy. Every deny names the fix.

That direction is a tiebreaker, not a licence. Guessing toward deny is
free only where the guess is rare; where it fires on ordinary correct
work it stops being conservative and becomes the reason the gate gets
switched off, and a gate that is off enforces nothing. Four adversarial
rounds produced escapes and false positives in roughly equal number, and
the false positives were the more dangerous half: `find tests -name
"*.json"` read as a scope violation, `grep '=>' spec.ts` read as a write,
`grep package.json src/` read as a read of a file it only searches *for*.
Each was fixed by teaching the kernel the relevant grammar — quoting,
escaping, which operands a command treats as patterns — rather than by
widening a scope. When a deny cannot be explained to the person who
wrote the manifest, it is a bug on this axis, not a boundary.

## Known limits (honest boundaries)

The kernel is a separation-of-duties and context-hygiene layer, not an
adversarial sandbox. It governs tool calls in sessions where the hook
is installed; it does not contain a determined operator who can edit
files in their own terminal. Specifically:

- **MCP tools are path-scoped only where the manifest says how.**
  `settings.mcpPathArguments` maps a tool-name glob to the `tool_input`
  fields that carry paths (dot-paths; array values checked
  element-wise), and those paths are then held to the role's read/write
  scopes exactly like a core tool's. A tool with **no mapping entry
  stays gated by name alone** — so map the file-touching tools your
  roles actually use, and grant unmapped file-mutating tools only to
  roles whose mandate covers the effect.
- **Pre-existing symlinks that escape a scope** are resolved by
  `realpath` (so a symlink already pointing outside the scope is caught
  at match time), but a role with write access inside its scope can
  still create new links with granted tools; treat write scope as
  "may create arbitrary files here", not "may only affect bytes here".
- **`bash.unrestricted`** is a deliberate hole for a trusted role, and
  should now be rare: `bash.permit` unlocks *one named construct* at a
  time, which is almost always the right answer to an unexpected deny.
  Neither is a substitute for diagnosing the deny first —
  `harness-os explain` previews a verdict, `harness-os doctor` turns the
  decision log into the specific grant that is too narrow.
- **A child with no transcript of its own, arriving amid several
  different in-flight roles**, cannot be disambiguated by any rung and
  falls back to `unboundAgentPolicy` (protectively `readonly`). Adding a
  `#NONCE` to every dispatch tag closes this for any child whose
  transcript is visible; same-role fan-out is always safe.

Within that model — a cooperating-but-fallible agent that may drift,
over-reach, or try the obvious shortcut — the six axes above are
designed to have no silent bypass. The adversarial test suite
(`hooks/tests/cases/02-adversarial.sh`) encodes one escape attempt per
closed channel.
