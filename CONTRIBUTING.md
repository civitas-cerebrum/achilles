# Contributing to Achilles

Achilles is a harness-neutral QA methodology (`skills/`) plus a Claude Code adapter (`claude-code/`). Methodology text never names a harness tool; adapter code never restates methodology. Keep that split in every change.

## Before you file or open anything

1. **Search existing issues and PRs, open and closed**, in this repo and in the two framework repos:
   ```bash
   gh issue list --state all --search "<keyword>" --repo civitas-cerebrum/achilles
   gh issue list --state all --search "<keyword>" --repo civitas-cerebrum/element-interactions
   gh pr list   --state all --search "<keyword>" --repo civitas-cerebrum/achilles
   ```
   Comment on an open match instead of duplicating; read a closed match's resolution first.
2. **Diff local against upstream** before claiming a gap: `git fetch origin && git log --oneline HEAD..origin/main`. Rebase and re-verify if commits are incoming.
3. **Check the published framework version** when the report is "the Steps API lacks X": `npm view @civitas-cerebrum/element-interactions version` against the pin in `package.json`. Framework API changes belong in that repository, not here; this repo's [`skills/achilles-orchestrator/references/api-reference.md`](skills/achilles-orchestrator/references/api-reference.md) follows a published release.

Report the three checks in one line each in the issue or PR body.

## Commit and PR conventions

- Conventional subjects: `feat(skills): …`, `fix(adapter): …`, `docs(harness): …`, `chore: …`. One logical change per commit.
- A commit or PR that closes an issue credits the reporter: `Reported-by: @<github-handle>` in the commit body and near the top of the PR description.
- **No AI attribution trailers.** Commits and PR bodies carry no `Co-Authored-By: Claude …`, no "Generated with …" line and no `claude.ai/code` URL. The adapter's Bash judge refuses such commits for agents; the same policy applies to humans on this repo.
- No version bump inside a feature PR; versions move at release time.
- Never commit `.achilles/`, `.env`, evidence bundles or client vocabulary. `client-term-guard` (a local denylist at `.achilles/client-terms.local.txt`) is your personal backstop; the shipped text stays universal.

## Changing the methodology (`skills/**`)

- **One canonical home per rule.** Shared composing rules live where [`test-composition-standards.md`](skills/achilles-orchestrator/references/test-composition-standards.md) §2 says they live; other files cite, never re-paste. Adding a clause to a shared rule inside another skill is a fork.
- **Harness-neutral text.** No Claude Code tool names (`Skill`, `Task`, `Read`, `TaskCreate`, `MultiEdit`), no hook names, no `.claude/` paths, no `subagent_type`, no dispatch-prefix grammar. The orchestrator dispatches experts with the ordinary Agent tool as `achilles-inspector`, `achilles-author`, `achilles-reviewer`, `achilles-doc-writer`, prompt = brief path + report path; experts load skills by directory name and dispatch nobody. Harness specifics go in [`docs/harness/<adapter>.md`](docs/harness/).
- **No user dialogue inside a skill.** Every skill runs as a subagent; a question becomes a `NEEDS_CONTEXT` return with a numbered question list. See [`skills/achilles-orchestrator/SKILL.md`](skills/achilles-orchestrator/SKILL.md) §6.
- **Lint before you push:** `node scripts/lint-doc-drift.mjs` checks skill links, `§"Heading"` anchors, the skill set against the orchestrator's routing table, agent role names in prose, docs counts, and prose density (em dashes ≤ 8 per 100 lines; a short banned-phrase list). `npm test` runs the adapter and CLI suites.
- **A new skill** gets a directory under `skills/<name>/` with a `SKILL.md` whose frontmatter `description` states triggering conditions, a row in the orchestrator's routing table when the orchestrator routes to it, and citations from the skills that dispatch it. Renaming a skill updates every citation in the same commit.
- **A new reference** lives under the one skill that owns the concept; other skills link to it with a relative path.
- **Niche diagnosis traps** go in [`skills/failure-diagnosis/references/niche-edge-cases.md`](skills/failure-diagnosis/references/niche-edge-cases.md) when all three hold: the shape misclassifies in practice, the disambiguating probe is non-obvious, and the shape is reproducible across consumers. Five fields per entry (Symptom / Why LLMs struggle / Disambiguating probe / Classification / Cross-link); one paragraph each.

## Changing the adapter (`claude-code/**`)

- One hook module; shared parsed-command model; advise by default, deny only for irreversible or dangerous actions (the deny list is in [`docs/harness/claude-code.md`](docs/harness/claude-code.md)).
- Every pattern deny ships with at least two adjacent-traffic allow cases in `claude-code/tests/`. Fixture cases are data (`{ input, expect: allow | deny | advise, messageContains }`).
- A deny or advice message leads with the action to take, then what was wrong, then a `References:` block of one to three repo-relative `skills/.../<file>.md` paths naming the rule it enforces. Cited paths must exist.
- Agent definitions under `agents/achilles-<role>.md` are hand-authored: tools and path scopes are the role boundary. Changing a role's scope changes that file, the adapter's data file that mirrors it, and the lint that reads both, in one commit.

## PR checklist

- [ ] Duplicate search, upstream diff and framework version reported in the body
- [ ] `node scripts/lint-doc-drift.mjs` green; `npm test` green
- [ ] No harness vocabulary added under `skills/`; no methodology restated under `claude-code/`
- [ ] Every new or changed rule cites its canonical home; no re-pasted shared rules
- [ ] New deny has ≥2 allow cases; message ends with `References:`
- [ ] `Reported-by:` present when an issue is closed; no AI attribution trailers; no version bump
- [ ] `CHANGELOG.md` entry under Unreleased
