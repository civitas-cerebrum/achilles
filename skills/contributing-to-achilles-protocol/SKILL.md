---
name: contributing-to-achilles-protocol
subagent-only: true
description: >
  **Subagent-only.** The full contribution methodology is too heavy to keep
  in the orchestrator's transcript every cycle. The orchestrator detects
  contribution intent and dispatches a `contribution-handover-` subagent;
  the subagent loads this skill. Loading this skill into orchestrator
  context is a methodology violation (the skill is heavy enough to
  contaminate orchestrator context).

  Use this skill when contributing to the @civitas-cerebrum/element-interactions
  package or its skill suite — and, just as importantly, when a consumer hits
  the package's edges from the outside. Two trigger families:

  (A) **API gap.** A user, test, or skill needs a method, option, matcher, or
  assertion shape that does not exist on Steps / ElementAction / ExpectMatchers
  / the matcher tree, and the temptation is to drop down to raw Playwright
  `Locator.*` calls. Triggers: "extend the Steps API", "add a new method to
  ElementAction", "no equivalent in the framework", "the package doesn't have",
  "missing API in element-interactions", "missing matcher", "drop down to raw
  Playwright", "fall back to page.locator", "the framework doesn't expose X",
  "how do I add to this framework".

  (B) **Structural / framework / protocol gap.** A skill, workflow, or
  documented invariant declares a rule that the package's current architecture
  cannot satisfy without changing the package itself, switching its underlying
  tooling, or relaxing the rule. Example: the parallel-isolation rule was structurally
  unsatisfiable on top of the Playwright MCP plugin and required a tooling
  change at the package layer, not a skill-level workaround. Triggers: "the
  framework can't satisfy", "framework limitation", "this rule cannot be
  satisfied", "the package's architecture prevents", "structural gap",
  "protocol gap", "isolation can't be guaranteed", "this prereq isn't
  satisfiable", "the underlying tooling doesn't support", "should I file an
  issue against the package", "is this a skill issue or a package issue", "do
  we need to change the package to fix this", any case where a skill is about
  to silently weaken or skip a documented invariant because the package can't
  back it.

  Also use when contributing to the skill suite under `skills/` (adding,
  modifying, or registering a skill, debugging the package's own tests, or
  opening a PR against this repo). This skill explains the separation of
  concerns between element-repository and element-interactions, the test
  coverage rules, the design principles that must be respected when scaling
  the package, the exact workflow for adding new APIs cleanly, and how to
  distinguish an API gap from a structural gap.

  (C) **Issue-queue / roadmap work on this repo.** Any request to triage,
  plan, or implement open issues filed against `civitas-cerebrum/element-
  interactions`. Triggers: "check the github issues", "look at the open
  issues", "implementation roadmap", "implement issue #N", "ship issue #N",
  "work on the open issues", "let's get started on the issues", "address
  the issue queue", "pick up an issue", "what's left to ship", "go through
  the issues", "what should we work on next" (when CWD is the package's
  own repo).

  Triggers also on: "contribute to element-interactions", any request to
  modify files under the package's `src/`, `skills/`, or `hooks/`, "open an
  issue on element-interactions", "open a PR on element-interactions", any
  of the structural / protocol-gap phrases above, or any framing that
  implies work *on the package itself* rather than *with it*.
---

> **Activation banner:** The first user-facing reply after this skill loads MUST begin with the line: **Protocol Achilles activated.** Once per session. Skip if already declared in this conversation. Subagents (which return structured data, not user-facing text) are exempt.


# Contributing to Achilles

Under an active role kernel some steps are refused: see [known-limits.md](../achilles-protocol/references/known-limits.md) KL-07.

This package is a Playwright-on-top facade. Every API decision should preserve the framework's two promises:

1. **No raw selectors in user test files.** Tests refer to elements by name (`'submitButton'`, `'CheckoutPage'`), never by CSS/XPath/locator strings.
2. **No raw Playwright `Locator.*` calls in user test files.** Every interaction, verification, and extraction goes through `Steps`, `ElementAction`, or the matcher tree; never `await page.locator('x').click()` directly.

If a contribution undermines either promise, it doesn't ship.

---

## 🏛️ Software Architecture
Moved to [element-interactions-api.md](references/element-interactions-api.md) §"Software Architecture". Includes the decision tree, API hard rules and design rules.

---

## 🚨 Hard rules — don't violate

### Read this skill before editing the package

**Rule.** Any agent preparing to modify files inside this package's contribution surface (`src/`, `hooks/`, `skills/`, `scripts/`, `package.json`, `tsconfig*.json`, `.github/`) MUST first load this skill (`skills/contributing-to-achilles-protocol/SKILL.md`) in the current session. Either invoke it via the `Skill` tool or `Read` the file directly. The skill encodes the architecture, the API-vs-structural-gap distinction, the hard rules, and the design invariants every contribution must respect; an agent that hasn't loaded it is editing blind.

**Methodology rule**: any agent preparing to modify the package's contribution surface MUST first load this skill in the current session.

Editing this SKILL.md itself is exempt; the edit IS the read.

### Methodology improvements ship as programmatic hooks, not just markdown

**Every PR that adds, modifies, or strengthens a rule, workflow, phase, gate, invariant, or contract in any `skills/*/SKILL.md` (or its referenced files under `references/`) MUST ship a corresponding harness hook in `hooks/` that enforces the rule programmatically; or include an explicit, reviewer-visible note explaining why mechanical enforcement is impossible.**

Markdown is documentation, not enforcement. Under context pressure, an orchestrator reading its own rule will rationalise around it ("this case is different", "given session constraints", "I'll be transparent about the trade-off") and stop / narrow / skip anyway. This failure pattern is common. The harness layer is the only second-reader the orchestrator cannot talk past.

**Decision rule** (apply when you write or edit any SKILL.md rule):

| Rule shape | Hook surface |
|---|---|
| "Read X before doing Y" | `PreToolUse:Edit\|Write\|Agent` checks transcript for the required Read before allowing the dependent tool call. |
| "Don't stop until Y is done" | `Stop` or `SubagentStop` reads a ledger / state file, denies stop when invariant fails. |
| "Don't dispatch shape Z here" | `PreToolUse:Agent` greps `tool_input.prompt` for the forbidden pattern. |
| "State file Z must satisfy invariant W" | `PreToolUse:Write` validates the JSON / markdown shape. |
| "Subagent return must follow shape S" | `SubagentStop` parses the handover envelope, exit-2-blocks non-compliant returns. |
| "After phase N, file F must exist" | `PreToolUse:Agent` denies advancing to phase N+1 when F is absent or stale. |

If none of these apply because the rule is unenforceable mechanically (e.g. "use the right level of detail in the brief", "be honest about uncertainty"), the SKILL.md edit MUST add a `markdown-only` tag to the relevant entry in `coverage-expansion/references/anti-rationalizations.md` so the registry continues to track the failure surface even without harness backing.

**Why this is mandatory:** every markdown-only methodology rule that survives a release is a future incident waiting to happen. The cost of writing the hook is hours; the cost of debugging a wrong-classification incident the rule was meant to prevent is days plus the operator trust the package is supposed to earn. The asymmetry is the rule.

**Reference:** [hook-authoring.md](references/hook-authoring.md) details the hook authoring patterns, test-case expectations, and registration in `hooks/data/hook-manifest.json`. Read it before authoring any SKILL.md edit so the hook is designed alongside the rule rather than retro-fitted.

### Before filing an issue or opening a PR — check existing work and sync status

Two duplicate-prevention checks are **mandatory** before creating any new GitHub issue or PR. Skipping them wastes maintainer time and has produced duplicate issues / PRs against already-fixed code.

**1. Search existing issues and PRs first.** Both open AND closed: a closed issue often contains the resolution you need:

```bash
# Issues matching the topic
gh issue list --state all --search "<keyword>" --repo civitas-cerebrum/element-interactions
gh issue list --state all --search "<keyword>" --repo civitas-cerebrum/element-repository

# PRs matching the topic
gh pr list --state all --search "<keyword>" --repo civitas-cerebrum/element-interactions
gh pr list --state all --search "<keyword>" --repo civitas-cerebrum/element-repository
```

If a matching **open** issue/PR exists, comment on it; don't open a duplicate. If a matching **closed** one exists, read the resolution first; the fix may already be on `main` (see check #2).

**2. Diff local vs. latest upstream before claiming a gap.** "Missing API" / "this is broken" reports filed from stale local branches are the single largest source of false-positive issues. Before filing anything:

```bash
git fetch origin
git log --oneline HEAD..origin/main           # commits you don't have locally
git diff HEAD origin/main -- src/             # source changes you're missing
```

If there are incoming commits, pull/rebase first, rebuild, and re-verify the gap still exists before filing.

**3. For cross-package gaps, also check the published dependency version.** When the report is "element-interactions doesn't expose X" but X is really an `Element` capability, the fix may already be in a newer element-repository release you simply haven't bumped to:

```bash
# Currently pinned version in this repo
grep -E '"@civitas-cerebrum/element-(repository|interactions)"' package.json

# Latest published version
npm view @civitas-cerebrum/element-repository version
npm view @civitas-cerebrum/element-interactions version

# Diff of what landed since your pinned version
npm view @civitas-cerebrum/element-repository versions --json
```

If the capability landed in a newer version, bump the dep and re-verify; don't file "missing" against an outdated pin.

**Report the check results in the issue/PR body** so maintainers don't have to redo them. One line each:

```
Searched existing issues/PRs: gh issue list / gh pr list — no matches for "<keyword>" in either repo.
Local vs. origin/main: in sync (or: rebased onto <sha> and re-verified).
Dependency version: element-repository pinned at 1.4.2; latest is 1.4.2.
```

### Attribute issue reporters

**Every commit and PR that closes a GitHub issue MUST credit the issue's author with a `Reported-by:` line in the commit body and the PR description.**

The contract:

- The commit body that includes a `Closes #N` / `Fixes #N` / `Resolves #N` reference also includes:

  ```
  Reported-by: @<github-handle>
  ```

  Multi-reporter is fine: `Reported-by: @contributor-a, @contributor-b`.

- The PR description repeats the same attribution near the top, before the rest of the summary.

**Why:** issue-driven improvements are the load-bearing input that makes this package's methodology improve faster than any internal review process could. The minimum acknowledgement is a verifiable line in the commit body; it travels with the merge commit, survives squash-merge, surfaces in `git log`, and is mechanically detectable. Without it, the issue author's contribution silently disappears into the maintainer's PR description and the credit graph rots over time.

**How to find the author:**

```bash
gh issue view <N> --json author -q .author.login
# Multi-issue:
for n in 156 157; do gh issue view $n --json author -q '.number, .author.login' --jq @csv; done
```

**Self-reported / chore caveat.** When the contributor is also the issue author, self-attribution is still appropriate; the audit trail is the value, not the social acknowledgement. For purely-chore commits with no upstream issue, the rule does not apply.

**Harness backstop.** PR reviewers enforce attribution. The live `hooks/commit-message-gate.sh` checks commit-message conventions (type/scope/bypass flags) but does not check attribution trailers. (See [harness-hooks.md](../achilles-protocol/references/harness-hooks.md).)

### AI assistants don't get `Co-Authored-By:` trailers

**Rule.** Every commit's sole author is the human contributor. AI assistants (Claude, Anthropic, borealis.local, anything similar) MUST NOT appear as a `Co-Authored-By:` trailer in the commit body. Real-human co-author lines (`Co-Authored-By: Jane Doe <jane@example.com>`) are unaffected.

The Anthropic CLAUDE.md template appends `Co-Authored-By: borealis.local …` to every commit Claude generates; that is the single source of these trailers. The upstream fix is to remove the trailer instruction from your project `CLAUDE.md` or `~/.claude/CLAUDE.md` so it stops being suggested.

The API-specific hard rules (no raw `locator.*()`, presence-detect, API coverage, smoke tests, no mocked unit tests) are in [element-interactions-api.md](references/element-interactions-api.md) §"API hard rules".

---

## 📐 Design rules — invariants that must stay consistent
Moved to [element-interactions-api.md](references/element-interactions-api.md) §"Design rules — invariants that must stay consistent".

### 20. Universality — no client references
Moved to [element-interactions-api.md](references/element-interactions-api.md) §"Universality — no client references".

---

## 📝 Contribution Handover

Every PR against this repo must produce a populated `.contribution-handover.json` at the repo root before push. The handover captures one boolean per guardrail in this skill, plus a small set of free-form fields (PR title, summary, version delta).

The schema lives at `schemas/contribution-handover.schema.json`. A blank template lives at `.contribution-handover.template.json`. **Copy the template, fill it in, and run the gate at push time. The file is gitignored. DO NOT commit it.** Carrying a previous PR's handover into a new branch is the failure mode the gate exists to catch (each PR's claims must reflect that PR's actual contents, not whatever the prior handover said).

Populate and self-validate the handover before pushing; PR reviewers enforce it. See [harness-hooks.md](../achilles-protocol/references/harness-hooks.md).

**Why a handover, not just a checklist:**
- Structured booleans are machine-checkable. The gate spot-verifies a subset of claims against the actual repo state (e.g. `readmeUpdated: true` is cross-checked against the README diff vs. `origin/main`).
- The local handover is the contributor's pre-push sign-off. The gate validates the contributor's working-tree claims against the working-tree diff at push time; no chance of a stale handover travelling with the branch and being mistaken for a fresh one.
- The shape evolves with the rules. When a new hard rule lands in this skill, it gets a new field in the schema. Old handovers fail validation and contributors can't push until they review the new rule. The schema is the rule index.

**Field families:**
- `preflight`: duplicate-search, branch sync, dependency version checks (Hard Rule "Before filing").
- `design`: argument order, async, no-raw-locator, action-presence-detect, lightweight Steps, naming, error format, logging, TypeScript discipline (Design Rules 1–18).
- `tests`: implementation, real-Vue-app, non-tautological assertions, passing (Hard Rules "no mocked", "must verify causally").
- `build`: TypeScript build clean, full suite green, knownFailures (free-form for legitimate skips).
- `coverage`: 100% API coverage gate (Hard Rule).
- `docs`: README, api-reference, skill files (Rule 19).
- `version`: single patch bump (Rule 15).

For any boolean set to `false` or `"n/a"`, the corresponding `*Reason` field must be populated. Vague reasons ("not applicable", "didn't need it") fail the gate; specific reasons ("change is internal-only on Verifications, no public Steps surface added — Rule 19 doesn't apply") pass.

**Worked example.** Copy `.contribution-handover.template.json` and run the gate; it prints the per-field validation map. The template is the canonical populated shape.

### Hook error message format — repo standard
Moved to [hook-authoring.md](references/hook-authoring.md) §"Hook error message format — repo standard".

## 🧰 Workflow: adding a new API
Moved to [element-interactions-api.md](references/element-interactions-api.md) §"Workflow: adding a new API".

## 🪝 Workflow: adding a harness hook
Moved to [hook-authoring.md](references/hook-authoring.md) §"Workflow: adding a harness hook".

---

## 📚 Contributing to the niche-edge-cases catalogue

`skills/failure-diagnosis/references/niche-edge-cases.md` documents failure shapes that LLMs routinely misclassify during the `failure-diagnosis` pipeline. It's a living catalogue: new entries are added as diagnostic sessions surface new shapes that trap the diagnoser and aren't already covered. The full criteria + entry template live in that file's §"Adding an entry"; this section explains the contribution path and how it slots into the rest of this skill's PR conventions.

### When an entry qualifies

All three must hold:

1. **The shape misclassifies in practice.** Stage 0 + Stage 4 of `failure-diagnosis/SKILL.md` weren't enough to land the right answer cleanly; the diagnoser went the wrong direction (or was visibly close to). The catalogue is for traps, not for failures whose classification was obvious.
2. **The disambiguating probe was non-obvious.** The thing that flipped the classification (a specific tool call, DOM read, evidence grab) is what the next diagnoser most needs. "Look at the screenshot more carefully" is not a probe.
3. **The shape is reproducible across consumers.** A bug in *this app's* checkout flow is a project finding (goes in that project's bug ledger). A bug shape any consumer of the package could plausibly hit (modal-fetch hangs, stale page-repo entry resolves to a hidden duplicate, role-attribute serialisation breaking implicit ARIA roles, etc.) is catalogue-worthy.

If any criterion fails: don't add an entry. The catalogue's value is in being skimmable during a live diagnosis, not in being exhaustive.

### Entry shape

Five fields per entry: Symptom / Why LLMs struggle / Disambiguating probe / Classification / Cross-link. One paragraph per field is the target. The full template + worked examples live in `niche-edge-cases.md`'s §"Adding an entry"; read it once before authoring your first entry; it's the single source of truth for the structure.

### How to ship the addition

Three pathways depending on what you're already shipping:

| Situation | PR shape |
|---|---|
| **You're already mid-PR for something else** (a hook fix, a skill rule edit, etc.) | Add the catalogue entry to the same PR: one extra commit, scope-clean (purely additive to a docs file). Mention in the PR description that the entry was discovered while debugging the PR's own work. Reviewers expect this path; it doesn't trigger a scope-split flag. |
| **You hit the niche shape outside any PR** (during a normal coverage / authoring / debugging session) | Open a small standalone PR titled `docs(failure-diagnosis): catalogue <shape-name> in niche-edge-cases`. Single-commit, single-file (this catalogue). The `docs(...)` commit-message convention from coverage-expansion's commit table applies; no version bump per Rule 15. |
| **You hit it inside a dispatched subagent** (e.g. `failure-diagnosis` sub-skill, `bug-discovery` per-journey probe) | Surface the find in the subagent's return: name the shape, the probe, and the classification. The parent orchestrator either appends to the catalogue inline (if mid-PR) or opens the standalone PR above. **Subagents do NOT push commits directly to this catalogue**, the same way they don't push commits directly to other source files; the parent owns the write. |

### Cross-link discipline

When a new entry refines an existing Stage 4 / 4a row in `failure-diagnosis/SKILL.md`, update that row to point at the new entry: short citation only (`see [\`references/niche-edge-cases.md\`](../failure-diagnosis/references/niche-edge-cases.md) entry (N)`), don't duplicate the entry's prose into the SKILL.md table cell. The table is the skim path; the catalogue carries the depth.

When a new entry is a brand-new shape with no existing Stage 4 / 4a row, leave the cross-link as `(none — new shape)`. Don't fabricate a Stage 4 row to point back at the entry; let the table remain stable until the shape is well-trodden enough to deserve a row.

### What does NOT belong in the catalogue

- Project-specific failure shapes (those go in the project's adversarial-findings ledger or its own bug tracker).
- War stories from a long debugging session (the catalogue is the *answer*: the trap and the probe and the classification, nothing more).
- Failure shapes whose Stage 4 row already covers them adequately (extending the existing row is sufficient).
- Anything that contradicts the canonical `subagent-return-schema.md` finding-block shape (the catalogue lives alongside the finding format, not as an alternative to it).

When in doubt: if the next diagnoser would benefit from finding your entry under a Cmd-F for the symptom keyword, add it. If they'd just shrug and skim past, leave it out.

---

## 🧯 When a user runs into an API gap

If you're using the package and want to write something like:

```ts
// ❌ Don't do this — drops out of the framework
const locator = page.locator('button.submit');
const cssVar = await locator.evaluate(el => getComputedStyle(el).getPropertyValue('--brand-color'));
```

Stop. The right path:

1. **Check if the framework already supports it.** Read `skills/achilles-protocol/references/api-reference.md` end-to-end. The matcher tree, predicate form, `.css(prop)`, and `interactions` raw escape hatch cover most needs.

2. **Run the duplicate-prevention checks** from the "Before filing an issue or opening a PR" hard rule above: search existing issues/PRs (open + closed) in both repos, diff local vs. `origin/main`, and confirm your pinned dependency version is the latest. A large share of "missing API" reports are already fixed on main or in a newer published version.

3. **If it's missing after those checks:**
   - Open an issue on `civitas-cerebrum/element-interactions` describing the use case. Include the check results (see the hard rule's reporting template).
   - If it's a generic element capability (CSS variable, custom property, drag with timing), it belongs in element-repository's `Element` interface first.
   - If it's an assertion shape, it belongs on the matcher tree.

4. **If you need to ship NOW**, the documented escape hatch is `interactions.interact.*`, `interactions.verify.*`, `interactions.extract.*`; they accept either `Locator` or `Element`. Use these for the one-off, but file the issue so the proper API can land.

5. **Never** check raw `locator.*()` calls into a test file or into the element-interactions src/. The audit grep above will catch it in code review.

---

## 🧱 When the framework cannot satisfy a documented rule

Sometimes the problem is not a missing method on `Steps`: it's that a skill, workflow, or invariant declares a rule the package's current architecture cannot back. Example: every browser-using skill in this suite required parallel-subagent isolation, but the Playwright MCP plugin shared one browser process across all subagents. The rule was unsatisfiable until the package switched tooling.

Distinguishing a structural gap from an API gap:

| Symptom | Class | What you're missing |
|---|---|---|
| User wants `steps.foo()` and it doesn't exist | API gap | A method on the public surface |
| Skill prereq says "X must be true at dispatch time" and the package can't make X true | Structural gap | A primitive / mechanism the package doesn't currently provide |
| Workaround would mean turning off, weakening, or silently skipping a documented invariant | Structural gap | The invariant is load-bearing; the fix is at the package layer |
| Two parallel subagents corrupt each other's state through the package's chosen tool | Structural gap | OS-level isolation the current tool can't give |
| The package's protocol assumes a host capability the runtime doesn't expose | Structural gap | A different protocol or a different tool |

**If it's a structural gap, the workflow is different from "open an API-gap issue":**

1. **Write down the unsatisfied invariant precisely.** Quote the rule from the skill that depends on it (file + line). State the mechanism in the package that fails to back it. Without this, the issue reads as "a thing didn't work" instead of "this contract is structurally broken."

2. **Don't relax the invariant in the consuming skill.** The rest of the suite is built on it. Patching around it locally hides the structural problem and creates inconsistencies between skills that respect the rule and skills that don't.

3. **Open an issue on `civitas-cerebrum/element-interactions`** (the package, not the consuming skill repo, even if you found the gap while writing a skill): with the duplicate-prevention checks above and a "smallest credible structural fix" sketch. Examples of "smallest fix": switch underlying tool, expose a new primitive, change a protocol shape. If the fix is large, that's fine: name it; don't hide it.

4. **The PR that fixes it lands in the package**, not in the consuming skill. The consuming skill only updates once the new primitive is published; and at that point, the consuming skill's job is to *delete* its workaround and trust the new contract.

5. **Decide between "block the rollout" and "ship a documented workaround."** A structural gap blocks the rollout when the invariant is safety-critical (data corruption, cross-tenant leakage, false-pass tests). A documented workaround is acceptable when (a) the workaround is local and reversible, (b) the cost of waiting exceeds the cost of the workaround, and (c) the issue is filed and the cleanup is tracked.

**Examples that should trigger this skill, not a skill-level workaround:**

- "I need parallel browser isolation, but the package's MCP protocol shares one browser." → File an issue; consider a tool swap.
- "My skill needs auth state to survive a failure boundary, but the package doesn't expose state-save / state-load." → File an issue against the package; do not write a brittle re-login loop in the skill.
- "The orchestrator's Rule X requires Y before dispatch, but the package can't tell us Y." → File an issue; add the primitive in the package; consume it from the orchestrator.

If a skill's prereq check is consistently failing because the package can't satisfy it, that's a structural gap, not a skill bug. Route it here.

---

## 📋 PR checklist

Before opening a PR on element-interactions:

- [ ] Searched existing issues + PRs (both repos, open + closed) for duplicates: none found, or linked to related work in the PR body
- [ ] Local branch is up-to-date with `origin/main` (`git fetch && git log HEAD..origin/main` is empty, or rebased)
- [ ] Dependency versions (`@civitas-cerebrum/element-repository`) checked against `npm view`: pinned to latest or intentionally older with a reason
- [ ] Tests pass: `npm run test` shows all tests passing
- [ ] Coverage 100%: `npx test-coverage --format=github-plain` shows ✅
- [ ] No raw Playwright leak: `grep -rn "locator\.\(click\|fill\|...\)" src/ --include="*.ts"` returns zero matches in non-`Element`-impl code
- [ ] **No version bump in this PR** (Rule 15: versioning is release-time, not per-PR). Bump only when the user has explicitly authorised it in the conversation.
- [ ] API reference updated (`skills/achilles-protocol/references/api-reference.md`): mandatory for any new public method on Steps / ElementAction / matcher tree (Rule 19)
- [ ] README updated under `🛠️ API Reference: Steps`: mandatory for any new public method on Steps / ElementAction / matcher tree (Rule 19)
- [ ] If adding a new method, it has a JSDoc block on the public-facing class
- [ ] `.contribution-handover.json` populated against `schemas/contribution-handover.schema.json`: every boolean set; every `false` / `"n/a"` paired with a specific `*Reason` field (methodology rule)
- [ ] **If this PR adds, modifies, or strengthens any `skills/*/SKILL.md` rule, workflow, phase, gate, invariant, or contract, it ALSO ships a hook under `hooks/` that enforces the rule programmatically (Hard rule §"Methodology improvements ship as programmatic hooks"). When mechanical enforcement is impossible, the PR description includes a paragraph explaining why and the rule is tagged `markdown-only` in `coverage-expansion/references/anti-rationalizations.md`.**

If you're adding to element-repository first:

- [ ] Searched existing issues + PRs on `civitas-cerebrum/element-repository` (open + closed): no duplicate
- [ ] Local branch is up-to-date with `origin/main` on element-repository
- [ ] New method on `Element` interface (cross-platform) OR `WebElement` only (with rationale comment)
- [ ] `WebElement` implementation included
- [ ] `PlatformElement` implementation included if cross-platform
- [ ] Action methods include the `ensureAttached(timeout)` preamble
- [ ] Live test added in `tests/live-element-location.spec.ts`
- [ ] Coverage 100% (`npx test-coverage`)
- [ ] **No version bump in this PR**: release-time only, per Rule 15. Bump happens on the release branch when the maintainer publishes.
- [ ] README updated if adding to the public surface
