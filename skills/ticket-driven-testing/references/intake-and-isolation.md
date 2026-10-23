# Phases 1–5: intake, isolation, environment

## 1. Ticket intake

Read the QA ticket **and its parent**. QA tickets carry the test scope; parent dev tickets carry the acceptance criteria, the design links, and the implementation notes. Neither alone is enough.

Extract four things: the **ACs verbatim**, the **branch**, the **PR**, and the **current status**.

**Tracker-agnostic.** This skill needs six capabilities from whatever tracker is in play. Discover what is actually connected (an MCP server, a CLI, a REST token) and map onto it. Never hard-code one vendor's tool names into the workflow.

| Capability | Linear | Jira | Fallback |
|---|---|---|---|
| Read a ticket | `get_issue` | `getJiraIssue` | REST / `curl` |
| Read its parent | `parentId` on the issue | `fields.parent` | same |
| Find the branch | `gitBranchName` field | branch in the dev-status panel, or the issue key as a branch prefix | `git branch -r \| grep -i <KEY>` |
| Find the PR | attachments / links | remote links, or the dev-status panel | `gh pr list --search "<KEY>"` |
| Post the report | `save_comment` | `addCommentToJiraIssue` | REST |
| Attach evidence | `prepare_attachment_upload` → PUT → `create_attachment_from_upload` | `attachFile` | REST multipart |
| Move status | `save_issue` with a state | `transitionJiraIssue` | REST |

Two portability rules that bite in practice: **status names are per-project**, so enumerate the available states rather than assuming a "Done" exists; and **the ticket key is the only reliable join** between tracker, branch and PR; expect the branch to carry the *dev* ticket's key while you work the *QA* ticket's, and confirm rather than infer.

If no tracker is reachable at all, the workflow still runs; the user pastes the ACs and the branch, and phases 2 onward are unchanged. Losing the tracker costs you intake and reporting, not the method.

## 2. PR state — a first-class QA signal

Check reviews and their timestamps against commit timestamps.

An **unresolved `CHANGES_REQUESTED`** on a ticket sitting in QA Testing is a finding in itself. A later commit may look like the fix, but "plausibly addressed" is not "re-approved"; report the gap rather than assuming it closed. Conversely, an automated reviewer's comment may already be fixed by a later commit; verify against the current code before repeating it as a defect.

## 3. Isolate the branch in a worktree

```bash
git worktree add ../<repo>-<ticket> origin/<feature-branch>
```

**Never switch the shared checkout.** Another session, another agent, or a running dev server may depend on the current branch. A worktree costs nothing and cannot disturb them.

Two consequences that bite later, both worth handling now:

- **The verification receipt (§8b) belongs in the SESSION checkout, not the worktree.** The harness
  gate resolves its workspace from the session's git toplevel, so a receipt written inside the
  worktree is invisible to it; you get denied while holding the receipt.
- **A fresh worktree re-stamps every file's mtime**, so any pre-existing receipt is instantly
  "older than the newest spec" and treated as stale. Create the worktree first, then run §8/§8b.

## 4. Review the diff

Read every changed file. For each AC, decide what would actually prove it:

- **Structural guarantees beat visual ones.** "Only one sticky bar" is proven by an element computing `position: static` at that breakpoint; it *cannot* pin. A screenshot only shows it *did not* pin this time.
- **Find the load-bearing attributes.** `data-*` hooks, `inert`, `aria-*`, state-marker classes. These are the stable selectors, and they usually already exist; check before proposing a source change.
- **Note what the diff deletes.** Removed feature flags, removed route mappings, removed components each imply a regression surface.

Record findings now, with severity. They become sentinels in phase 7.

## 5. Reach the environment

Feature branches deploy to preview URLs that are usually **protection-gated**. Symptom: `curl` returns HTTP 200 with a provider login page, not your app.

- Put the bypass token in a gitignored env file. Verify the gitignore pattern actually covers it.
- **Do not set the suite's base-URL variable in a shared env file**: it silently retargets every other suite. Pass it per command.
- For a CLI browser session, providers usually accept the token as a query parameter that sets a bypass cookie for the session.
