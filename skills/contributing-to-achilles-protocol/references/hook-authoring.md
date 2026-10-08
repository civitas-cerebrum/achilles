# Hook authoring

How to add, change and register a harness hook. The rule that every methodology rule ships with a hook is in [SKILL.md](../SKILL.md) §"Methodology improvements ship as programmatic hooks, not just markdown".

## Hook error message format — repo standard

Every hook under `hooks/*.sh` that emits a `permissionDecision: "deny"` (or a `systemMessage` warn) must format the reason text using the layout below. The shape is identical across hooks so contributors recognize a hook block instantly and know where to look.

```
[BLOCKED] <one-line headline — what's wrong, in present tense>

──────────────────────────
Do this instead:
──────────────────────────
  Option A — <case>
    <concrete template / command / config diff>
  Option B — <other case>
    <concrete next step>

──────────────────────────
What was wrong:
──────────────────────────
File: <path or N/A>
<observed values — claim, actual, diff, etc.>
<one-paragraph why it matters — the rule, the prior incident, the cost of the failure>

──────────────────────────
If <common motivation> — read this:
──────────────────────────
<pointer to the upstream fix or the rule the contributor is bumping against>

References:
  <canonical docs — file paths or URLs>
```

`[WARN]` replaces `[BLOCKED]` for `systemMessage`-style soft warnings. Box-drawing characters are U+2500 — copy them from this file, not from any other hook (existing hooks predate this standard and use ad-hoc formatting; they'll be normalized in a separate cleanup PR).

**Why these sections exist:**
- *Headline* — the contributor sees the failure in one line in their terminal. Don't bury the rule in paragraph two.
- *Do this instead* — concrete, copy-pasteable. At least two options when there are two valid resolutions (fix the work vs. update the claim). One option when there's only one path (e.g. file-corruption → repair the file).
- *What was wrong* — observed state, including the file path, the claim, and the actual value. This is the audit-log section; without it, contributors can't tell which check fired.
- *If <motivation>* — the empathy line. Anticipates the most common reason a contributor hit this gate ("you ticked the box without updating the file") and routes them to the right fix path. Skip this section if there's no common motivation worth naming.
- *References* — the canonical docs for the rule. Always include the SKILL.md section that defines the rule, plus the schema / config file the contributor will edit. Two to four lines.

The `commit-message-gate.sh` hook is the canonical implementation — copy its message-extraction block (the `MSG=`/`SCAN=` section handling `-m`, `--message=`, `-F`/`--file`, with the raw-command fallback that never denies blind on extraction failure) and its rich-error-context deny messages when writing a new hook.

---

## 🪝 Workflow: adding a harness hook

Hooks live in `hooks/<name>.sh`, are installed into `~/.claude/hooks/` by `scripts/postinstall.js`, and are registered in `~/.claude/settings.json` from the `hooks` array of `hooks/data/hook-manifest.json`. They run at PreToolUse / PostToolUse / SubagentStop / Stop boundaries to enforce skill contracts mechanically — markdown rules can be rationalised away mid-run, hooks cannot.

This section is the **how**. The **when** is fixed by the Hard rule §"Methodology improvements ship as programmatic hooks": every SKILL.md rule edit comes paired with a hook unless the rule is genuinely unenforceable mechanically. Re-read that hard rule first if you're authoring a SKILL.md change — its decision table maps each rule shape to a concrete hook surface.

When to add a hook (vs declaring the rule `markdown-only`):

- The rule is **mechanically detectable** at a tool-use boundary (specific tool, file path, command pattern, response-shape signal). → Hook.
- Markdown enforcement has been observed to fail under context pressure. → Hook.
- The cost of a violation is high (corrupt state, lost work, contract violation propagating downstream). → Hook.
- The rule is too contextual to detect mechanically (e.g. "use the right level of detail in this brief", "be honest about uncertainty"). → Stays markdown-only **and** the rule gets tagged in `coverage-expansion/references/anti-rationalizations.md` so the un-backed surface stays visible.

The default is "ship a hook." Choosing `markdown-only` is an explicit reviewer-visible exception, not the absence of a decision.

### Hook authoring — three required patterns

#### 1. Documentation header — uniform across all hooks

Every hook starts with a structured comment block. Readers should be able to scan the header alone and answer: what event does it fire on, what does it block / warn on, where's the canonical rule it implements, what's the exact failure → action mapping.

```bash
#!/bin/bash
# <name>.sh — <one-line summary of what this hook does>
#
# Hook    : <event>:<matcher>  (e.g. PreToolUse:Agent, PostToolUse:Bash, SubagentStop)
# Mode    : <DENY | WARN | RECORD | combinations>  (DENY blocks the tool call,
#           WARN emits systemMessage, RECORD updates state without output)
# State   : <none | <repo-or-home>/.claude/<file>.json>
# Env     : <none | CIVITAS_X_Y=<int>  (default <N>, semantics)>
#
# Rule
# ----
# <Single paragraph: what this hook enforces. Names the contract surface
# concretely. No ambiguity about which tool calls are caught.>
#
# Why
# ---
# <Single paragraph: motivation. Why mechanical enforcement here? What
# failure mode does it catch that markdown couldn't?>
#
# Canonical reference
# -------------------
# skills/<skill>/SKILL.md §"<section>"  (and/or)
# skills/<skill>/references/<file>.md §"<section>"
#
# (Optional sections: Conventions / Allowed list / Migration / etc. —
#  use them when the rule has a non-trivial vocabulary the reader needs
#  alongside the comment block.)
#
# Failure → action
# ----------------
# - <violation>                                       → DENY|WARN|RECORD
# - <other violation>                                 → DENY|WARN|RECORD
# - <legitimate-looking case that's exempt>          → silent allow
# - Anything else                                     → silent allow
```

This pattern is followed by every hook in `hooks/`. Adding a new hook with a different shape regresses scannability — match the existing template. Examples to read first: `hooks/playwright-cli-isolation-guard.sh` (DENY with multi-case classification), `hooks/commit-message-gate.sh` (DENY with rich error context), `hooks/subagent-return-schema-guard.sh` (PostToolUse observer + state-file deregister).

#### 2. Helper functions — consistent shape

Hooks emit two output shapes: a deny JSON (PreToolUse-only, blocks the tool call) and a warn JSON (any event, emits a `systemMessage`). Both are wrapped in helpers defined inline at the top of the script:

```bash
emit_deny() {
  jq -n --arg r "$1" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": $r
    }
  }'
}

emit_warn() {
  jq -n --arg m "$1" '{
    "systemMessage": $m,
    "suppressOutput": false
  }'
}
```

Define only what the hook actually uses (a deny-only hook doesn't need `emit_warn`). Don't inline a fresh `jq -n` in each call site — use the unified helpers instead.

#### 3. Action-first error message template — guide the agent back on track

Hook deny / warn messages are read by an agent under context pressure. The agent's next action is what matters most — not the diagnosis, not the references. Lead with the action.

Template:

```
[BLOCKED|WARN] <one-line headline of what was caught>

──────────────────────────────────────────────────────────────────
Do this instead — <option list or concrete template>:
──────────────────────────────────────────────────────────────────

  Option A — <case>
    <concrete next step: code template, command, or option>
  Option B — <other case, if applicable>
    <concrete next step>

──────────────────────────────────────────────────────────────────
What was wrong:
──────────────────────────────────────────────────────────────────
File: <path>
<observed values that triggered the rule>

<one-paragraph diagnosis: what the violation was, what failure mode it
represents, name the framings/symptoms verbatim where applicable>

──────────────────────────────────────────────────────────────────
If <common motivation for the violation> — read this:
──────────────────────────────────────────────────────────────────
<pointer to the upstream fix that resolves the underlying concern, NOT
the symptom-level workaround>

References:
  <canonical-doc-path-1>
  <canonical-doc-path-2>
```

Why this shape:
- **Action first.** The agent reading the message under context pressure should see the next step in the first ~10 lines. References at the end are for follow-up, not primary action.
- **Show, don't describe.** A concrete `Agent({...})` template, command, or option-list beats prose. Substitute extracted values where possible (slug from file path, count from JSON, etc.) so the agent can copy-paste.
- **Named symptoms.** When the violation has a recognisable internal-monologue framing ("honest stopping point", "I'll be transparent", "given session constraints"), name it verbatim in the diagnosis. Future agents recognise their own self-talk.
- **Underlying concern + upstream fix.** When a violation is driven by a real concern (e.g., parallel dispatch felt unsafe due to shared-DB races), acknowledge the concern and point at the upstream fix (per-test-user pattern in test-optimization §1.A) — NOT the symptom-level workaround. Otherwise the agent re-violates as soon as the same concern recurs.
- **References last.** Two to four canonical doc paths. Don't bury them in prose; list them.

**The `References:` block is MANDATORY on every runtime deny / warn / Stop-block message — not just recommended by the template.** Every message a hook can emit at runtime (a PreToolUse `permissionDecision: deny`/`ask` reason, a `systemMessage` warn, a Stop `decision: block` reason, a strict-mode `exit 2` stderr block) MUST end with a `References:` block of 1–3 repo-relative paths naming the canonical rule(s) the hook enforces — `skills/.../<file>.md` (optionally with a §section); when the hook enforces a machine-readable schema, cite the schema file AND the skill section that mandates it. A blocked agent must learn not just what to do next but which methodology section governs the rule. The reference implementation is `hooks/composition-judge-gate.sh`'s block; the house pattern is a single `HOOK_REFS` constant defined near the top of the hook and appended by the `emit_deny` / `emit_warn` helpers (before `achilles_scope_notice`, when the hook uses it), so every emission carries the block without per-site duplication. Mechanically enforced by the hook-references check in `scripts/lint-doc-drift.mjs` (runs in `prepack`): a deny/warn-capable hook with no runtime `References:` block or a cited path that does not resolve in the repo fails the lint. Pure writer/archiver hooks that never emit a user-facing message need nothing.

Examples to read: `hooks/subagent-schema-preread-gate.sh` (PreToolUse gate citing a schema) and `hooks/commit-message-gate.sh` (DENY with rich error context; Option A / Option B layout). The earlier reference implementations of the in-flight composer registry pattern (a dispatch-guard registrar paired with a direct-compose-block consumer) were removed in the 0.3.6 cleanup; the pattern itself is documented here for future contributors.

### Hook checklist

When opening a PR that adds or modifies a hook:

- [ ] Documentation header follows the unified template (Hook / Mode / State / Env / Rule / Why / Canonical reference / Failure → action).
- [ ] `emit_deny` / `emit_warn` helpers used consistently — no inline `jq -n --arg` calls in the body.
- [ ] Error messages follow the action-first template (headline → Do this instead → What was wrong → upstream fix → References).
- [ ] **Every runtime deny / warn / Stop-block message ends with a `References:` block** of 1–3 repo-relative `skills/.../<file>.md` paths (plus the schema file, when the hook enforces one) naming the canonical rule — typically via a single `HOOK_REFS` constant appended in the emit helpers. `scripts/lint-doc-drift.mjs` fails the build otherwise, and also fails on cited paths that don't resolve.
- [ ] Test cases added to `hooks/tests/cases/<NN>-<topic>.sh` covering: happy-path allow, each rule's deny/warn path, exempt cases, edge cases (empty inputs, special characters, alternate runner forms, etc.).
- [ ] `bash hooks/tests/run.sh` reports green on the new case file plus all existing cases.
- [ ] If the hook records state, the state-file path and shape are documented in the canonical reference.
- [ ] `hooks/data/hook-manifest.json` `hooks` array updated with the new entry (file, event, matcher, timeout, optional async).
- [ ] If the hook gates a markdown rule, the kernel-resident invariants in the relevant SKILL.md mention the harness backstop, naming the live hook precisely (e.g. "Harness-enforced by `hooks/standard-mode-first-pass-guard.sh`"). Never cite a retired hook; if a hook is removed, rewrite its skill-side claims to the honest-retirement form ("the harness guard for this rule was retired in <version>; the rule still applies").
- [ ] If the rule has a category in the anti-rationalization registry, the registry entry's `Hooks that catch this:` list is updated.

### Approximating `is_subagent` — the in-flight-registry pattern

The Claude Code harness payload doesn't include an `is_subagent` field on hook input — `Write` calls from a dispatched subagent and `Write` calls from the orchestrator are indistinguishable at hook-fire time.

When a hook needs to distinguish "was this tool call made by a legitimately-dispatched subagent doing its expected work" from "was this the orchestrator absorbing work that should have been delegated", use the **in-flight-registry pattern**:

1. **PreToolUse:Agent (the dispatch-guard)** writes a registration entry to a state file (e.g. `tests/e2e/docs/.in-flight-composers.json`) when the dispatch matches a known role-prefix that produces specific tool calls (e.g. `composer-j-<slug>:` produces a `Write tests/e2e/j-<slug>.spec.ts`).
2. **PostToolUse / PreToolUse on the produced tool call** reads the registry and gates the call: if the slug is in-flight (within a TTL window), the writer is the legitimate subagent — ALLOW. If not in-flight, it's the orchestrator absorbing — DENY with a redirect to dispatch the right subagent.
3. **TTL / cleanup as a failsafe**: the registry uses a rolling 30-min TTL — entries that aren't deregistered explicitly (see point 4) expire on the next dispatch-guard run, so stale registrations don't accumulate when a subagent crashes or is abandoned mid-flight.
4. **Explicit deregistration on terminal handover (the primary cleanup path).** Each subagent return is prefaced with a `handover:` envelope (`role`, `cycle`, `status`, `next-action` — schema in [`../achilles-protocol/references/subagent-return-schema.md`](../../achilles-protocol/references/subagent-return-schema.md) §2.0). In this pattern, a PostToolUse:Agent consumer parses the envelope, cycle-matches against the registry entry, and **deregisters the slot immediately on terminal status** instead of waiting for TTL. Cycle-mismatch (envelope claims a different cycle than the registered dispatch) refuses to deregister and asks the orchestrator to redispatch under the correct cycle. This shorter leash matters because the orchestrator's redispatch under the same slug can race with stale handovers from a slow / auto-compacted prior cycle — the cycle-match contract pins the deregistration to one specific dispatch.

The reference implementation paired a dispatch-guard registrar (registering `composer-j-*` / `composer-sj-*` / `probe-j-*` / `probe-sj-*` dispatches with a `cycle` field) with a direct-compose-block consumer (gating `tests/e2e/{j,sj}-*.spec.ts` writes against the registry) and `hooks/subagent-return-schema-guard.sh` (parses the handover envelope, cycle-matches, deregisters terminal handovers). All three registry-coupled behaviours were removed in the 0.3.6 cleanup; `subagent-return-schema-guard.sh` survives, but today it only validates returns against the role schemas via the bundled validator — it no longer parses-and-deregisters registry entries. The pattern avoids false positives that would otherwise force a WARN — the gate runs as a hard DENY because the registry mechanically distinguishes legitimate from violation, and the leash is bounded by the explicit handover instead of the looser 30-min window. (Reference implementation removed in 0.3.6; pattern documented here for future contributors.)

When you ship a new harness pattern that needs the same distinction, register at the dispatch boundary, gate at the produced-tool-call boundary, deregister on the canonical handover envelope, and keep the TTL as a failsafe. Use a hidden state file under `tests/e2e/docs/.<topic>-<scope>.json` to keep the registry alongside other coverage-expansion state.

---

## Vendored kernel

`hooks/kernel-mandate-role-gate.sh` and `hooks/lib/kernel-mandate.sh` are copied verbatim from [civitas-cerebrum/kernel-mandate](https://github.com/civitas-cerebrum/kernel-mandate). Never edit them here.

1. Land the change upstream first.
2. Re-copy: `KERNEL_MANDATE_SRC=<upstream checkout> npm run sync:kernel-mandate`. Without `KERNEL_MANDATE_SRC` it exits 2.
3. Commit the copied files with the regenerated `scripts/kernel-mandate.lock.json`. CI runs `node scripts/sync-kernel-mandate.mjs --check` against the lock.

## Changing a QA role

Edit all three in one commit:

1. `hooks/data/achilles-qa.kernel-mandate.json` (the manifest).
2. `hooks/data/achilles-qa.kernel-mandate.md` (the ledger, hand-kept).
3. `agents/*.md`, regenerated with `node scripts/build-agents.mjs`.

Then run `node scripts/lint-doc-drift.mjs` (checks 7 ledger inventory, 10 agents, 12 role dispatch sites) and `bash hooks/tests/run.sh 85-qa-mandate-scopes`.

## Conventions (factory)

Rules for a PreToolUse hook an agent hits hundreds of times a day. The factory gates and their fixture cases follow all of them.

1. **Allow-with-warning when the harness cannot run.** A missing jq or node, an unreadable rule file, a payload that is
   not a JSON object, a required field that is absent: allow, print one `[<hook>] <what> — <what still catches it>` line
   on stderr, exit 0. A hook that denies because *it* is broken bricks the session for a fault the agent cannot fix. Pair
   every such branch with a detector that runs where the environment is guaranteed (the project's verify step, an
   integrity chain) and fails closed there.
2. **Fail closed on your own undecidable input.** When the hook can see the input but cannot judge it — a spec argument
   that is a shell expansion (`"$SPEC"`) on a command that may spend money — deny and ask for the decidable form (a
   literal path): "I could not tell" is not "allowed". A gate script never exits non-zero by accident (`set -uo
   pipefail`, every external call guarded): Claude Code treats a crashing hook as a non-blocking error, which is an
   allow nobody chose.
3. **Three-line messages.** Every deny reason is exactly `[<rule-id>] <what happened>` / `→ Do: <sanctioned
   alternative>` / `→ Why/how: <doc#anchor>`. Line 1 names the file or command fragment and the offending literal; line
   2 is an action, never just "don't"; line 3 is a stable anchor. Agents recover from a denial in one step when the
   message says what to do instead; they loop when it only says no. The fixture runner rejects any deny that is not
   exactly this shape.
4. **Quote-aware Bash with one level of nesting.** Split the command into segments at unquoted `&& || ; | &` and
   newlines, and each segment into tokens honouring `'…'`, `"…"` and `\` escapes. Classify one level of
   `bash|sh|zsh -c '…'` and `eval '…'` as a command of its own, inheriting the outer segment's leading assignments.
   Deeper nesting, aliases, functions and scripts are out of reach — say so in the header's known limits and name the
   detector that covers them. A naive `grep` over the whole command both misses `sh -c` payloads and denies on text
   inside a `--grep "…"` argument.
5. **Opt-ins are per segment.** An opt-in (`SPEND_OPT_IN=1` prefix, `--include-spend` flag) counts only for the segment
   it is written on. `export SPEND_OPT_IN=1; node scripts/run-suite.mjs --include-spend && npx playwright test …`
   opts in the wrapper, not the Playwright run after it. Otherwise one early opt-in silently authorises everything
   that follows.
6. **Normalise paths before any scope decision.** Resolve a relative `file_path` against the call's `cwd`, then
   resolve `.`, `..` and `//` lexically (`tests/e2e/north/../legacy/x.ts` is `tests/e2e/legacy/x.ts`), before matching
   scopes or testing existence. Strip `:line[:col]` from test-file arguments. Where symlinks matter, resolve the parent
   directory explicitly; otherwise document that the link path is judged.
7. **Gates never write files.** A deny/allow gate writes no receipts, caches, logs or "last seen" markers. A gate that
   writes state creates a second trust anchor that itself needs protecting, and makes the decision depend on call
   order; recorders (archivers, registries) are separate scripts. State a gate reads (a verify stamp, a change marker)
   is written by the project's own commands and protected by a Bash guard plus a content hash.
8. **Content-hash stamps, not timestamps.** A "verified" receipt carries the hash of the tree it verified (sorted
   `(path, content hash)` lines over the hashed roots). The commit-time check recomputes it. A touch keeps it; any added,
   removed or changed file invalidates it; a forged stamp passes only if it carries the current tree's hash.
9. **Run guard suites with `--forbid-only`.** A stray `test.only` in a guard spec runs one test, skips the rest and
   still reports green.
10. **Fixture cases are data.** One JSON file per case: `input` (the PreToolUse payload, `{{ROOT}}` for the project
    dir), `expect` (`allow` | `deny`), `messageContains[]` (asserted only on denies, together with the three-line
    shape), `stderrContains[]`, `warn` (`false` = must be a clean allow, `true` = must warn), plus `env`, and
    `cwd: "temp"` with `copy[]` / `write{}` for a throwaway project. The runner fails a case whose exit status is not 0
    or whose stdout is not JSON.
11. **Allow cases assert no warning.** Give every allow case `"warn": false` unless the warning is the point. An allow
    that is really a skipped gate (a required field misspelled, a helper missing) passes a bare `expect: "allow"`
    forever; `"warn": false` turns that silent skip into a red case. A missing rule file is a deliberate silent opt-out,
    so no case can catch it: that is the project's verify step's job (require the file, validate it against the schema).
