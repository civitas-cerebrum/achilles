# Changelog

## 0.2.0 — unreleased

### Upgrading from 0.1.8

- **One-time overwrite.** 0.1.8 kept no install record. The first 0.2.0 install replaces every hook, hook library, hook data file and skill file in `.claude/` (for `-g`, in `~/.claude`) whose content differs from the package, including ones you edited. Postinstall prints how many files it replaced. From then on, a file you edit is never overwritten or pruned; postinstall warns once and leaves it.
- **Restart Claude Code** after the install to pick up the new hooks.
- **User-level copies.** A local install no longer copies skills and agents to `~/.claude`. It removes the copies an earlier recorded local install left there, unless you edited them, and names any unrecorded user-level skill with an Achilles name: 0.1.8 kept no record, and a user-level skill wins over the project's copy of the same name.
- **Staged mandate.** If `.claude/kernel-mandate.json` differs from what Achilles staged, it is left as it is and the new QA mandate is written beside it as `kernel-mandate.achilles-new.json`, with one notice. An unedited copy is refreshed.

### Added

- Role kernel: while an Achilles skill is active, every tool call is checked against the QA mandate (23 roles), staged into `.claude/kernel-mandate.json`. Only the kernel runtime ships; the mandate-designer skill and the kernel's schemas do not. See `skills/achilles-protocol/references/roles-and-dispatch.md`.
- Five change-loop roles: `live-inspector`, `implementer`, `task-reviewer`, `verifier`, `doc-author`, each with its own write scope and one hand-off path. A `doc-author` proposes changes to `CLAUDE.md` and skills as `docs/proposals/<topic>.md`.
- Seven opt-in factory gates under `hooks/factory/`, active only when `achilles-factory-rules.json` exists in the project. They are registered for every project and allow silently without the file. See `skills/achilles-protocol/references/factory-gates.md`.
- `achilles-import-boundary-gate` (static import screen on `tests/` and root config) and `achilles-multiedit-gate` (MultiEdit is refused while the protocol is active).
- Routing skill `~/.claude/skills/achilles`, the one file a local install writes user-level: a test request in a project with Achilles goes to `achilles-protocol`; in a project without it, the skill says how to install Achilles and does not run the protocol.
- One generated agent definition per QA role, installed to `.claude/agents/`; a file of yours with the same name is left alone and warned about.
- CLIs: `achilles-scenario-lint`, `achilles-selector-evidence`, `achilles-uninstall`.
- `achilles-uninstall [--global | --project [dir]] [--dry-run]` removes what postinstall recorded: its settings.json registrations, hooks, skills and agents (only files still unchanged since install), and an unedited staged mandate. Your own settings.json entries stay.
- Install record `achilles-install.json` in each `.claude/` directory Achilles installs into: the files written (with hashes) and the registrations added.
- Skill `requirement-intake`; references for the controller protocol, verification record, known limits and opt-in surfaces.

### Changed

- Postinstall copies by content instead of file time, so an npm tarball's fixed timestamps no longer leave an upgraded hook stale. A second run changes nothing.
- Files a newer version no longer ships are pruned, with their registrations, unless you edited them.
- Install scope follows `-g`. `npm i -g` installs hooks (registered by absolute path), skills, agents and the record in `~/.claude`, and stages the mandate as `~/.claude/achilles-qa.kernel-mandate.json` for projects without their own; nothing lands under npm's `lib/`. A local install writes all of it to the project's `.claude/` and only the routing skill user-level.
- A session that never activated the protocol leaves no file behind. The transcript scan takes an Achilles `SKILL.md` as a signal only as a tool call's `file_path`, not wherever the path is mentioned; the negative cache is written only once an activation has created the state dir; and a bundled jq that cannot run (macOS kills an unsigned binary) no longer reads as a missing `session_id`, which activated every session and let the Stop hooks write `.achilles/run-summary.json` into any project.
- A project install registers its hooks as `"$CLAUDE_PROJECT_DIR"/.claude/hooks/<file>`, so a moved or cloned project keeps working; an absolute registration from an earlier install is switched over.
- Bash guards (`protected-artifact-bash-guard`, `playwright-cli-isolation-guard`, `state-gate`) split a command line with one shared parser and judge the primary ways an agent writes: redirects, `tee`, `cp`/`mv`/`rm`, `sed -i`, and `git checkout`/`restore`/`reset --hard`/`clean`/`rm` on protected paths. A line they cannot split, or an unknown wrapper option, is denied. Obfuscated forms are out of scope. See KL-15 and KL-20.
- The bundled jq is checked against a pinned sha256 before it is made executable; a mismatch deletes it unrun.
- While the protocol is active, a PreToolUse call is denied when `jq` or a hook library is missing, with the remedy on stderr.
- Approval-class ledger writes must come from an approver `agent_type` when the host supplies one.
- Phase 7 is dispatched as `secrets-sweep-phase7:` with `subagent_type: secrets-sweep`.
- The package declares `"engines": { "node": ">=20" }` and its tarball no longer includes schema fixtures.

### Known limits

See `skills/achilles-protocol/references/known-limits.md`.
