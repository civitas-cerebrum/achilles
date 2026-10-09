# Changelog

## 0.2.0 — unreleased

### Upgrading from 0.1.8

- **One-time overwrite.** 0.1.8 kept no install record. The first 0.2.0 install replaces every hook, hook library, hook data file and skill file in `.claude/` (and in `~/.claude/skills`) whose content differs from the package, including ones you edited. Postinstall prints how many files it replaced. From then on, a file you edit is never overwritten or pruned; postinstall warns once and leaves it.
- **Restart Claude Code** after the install to pick up the new hooks.
- **Staged mandate.** If `.claude/kernel-mandate.json` differs from what Achilles staged, it is left as it is and the new QA mandate is written beside it as `kernel-mandate.achilles-new.json`, with one notice. An unedited copy is refreshed.

### Added

- Role kernel: while an Achilles skill is active, every tool call is checked against the QA mandate (23 roles), staged into `.claude/kernel-mandate.json`. Only the kernel runtime ships; the mandate-designer skill and the kernel's schemas do not. See `skills/achilles-protocol/references/roles-and-dispatch.md`.
- Five change-loop roles: `live-inspector`, `implementer`, `task-reviewer`, `verifier`, `doc-author`, each with its own write scope and one hand-off path. A `doc-author` proposes changes to `CLAUDE.md` and skills as `docs/proposals/<topic>.md`.
- Seven opt-in factory gates under `hooks/factory/`, active only when `achilles-factory-rules.json` exists in the project. They are registered for every project and allow silently without the file. See `skills/achilles-protocol/references/factory-gates.md`.
- `achilles-import-boundary-gate` (static import screen on `tests/` and root config) and `achilles-multiedit-gate` (MultiEdit is refused while the protocol is active).
- One generated agent definition per QA role, installed to `.claude/agents/`; a file of yours with the same name is left alone and warned about.
- CLIs: `achilles-scenario-lint`, `achilles-selector-evidence`, `achilles-uninstall`.
- `achilles-uninstall [--global] [--project <dir>] [--dry-run]` removes what postinstall recorded: its settings.json registrations, hooks, skills and agents (only files still unchanged since install), and an unedited staged mandate. Your own settings.json entries stay.
- Install record `achilles-install.json` in each `.claude/` directory Achilles installs into: the files written (with hashes) and the registrations added.
- Skill `requirement-intake`; references for the controller protocol, verification record, known limits and opt-in surfaces.

### Changed

- Postinstall copies by content instead of file time, so an npm tarball's fixed timestamps no longer leave an upgraded hook stale. A second run changes nothing.
- Files a newer version no longer ships are pruned, with their registrations, unless you edited them.
- A global install (`npm i -g`) no longer stages the mandate or writes a `.claude/` under npm's `lib/`.
- A project install registers its hooks as `"$CLAUDE_PROJECT_DIR"/.claude/hooks/<file>`, so a moved or cloned project keeps working; an absolute registration from an earlier install is switched over.
- Bash guards (`protected-artifact-bash-guard`, `playwright-cli-isolation-guard`, `state-gate`) judge the words a command line runs and the paths it writes after normalisation, treat anything they cannot parse as unsafe, and deny unknown wrapper options. They judge `git` targets (including `git rm --cached` of a protected path) and `find -exec`. See KL-15.
- While the protocol is active, a PreToolUse call is denied when `jq` or a hook library is missing, with the remedy on stderr.
- Approval-class ledger writes must come from an approver `agent_type` when the host supplies one.
- Phase 7 is dispatched as `secrets-sweep-phase7:` with `subagent_type: secrets-sweep`.
- The package declares `"engines": { "node": ">=20" }` and its tarball no longer includes schema fixtures.

### Known limits

See `skills/achilles-protocol/references/known-limits.md`.
