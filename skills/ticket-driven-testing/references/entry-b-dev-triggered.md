# Entry B: dev-triggered runs

## 1b. Derive the ACs — then get them confirmed

Entry A reads acceptance criteria. Entry B has none: the dev has a diff and an intention, and the
intention is in their head.

Do NOT proceed on ACs you invented. A suite built from assumed criteria is green against *your*
model of the feature, and its greenness says nothing about theirs; you will have automated your
own misunderstanding and reported it as cover.

1. Read the whole diff, then write **3–6 candidate ACs** as observable, user-visible statements.
   "Clicking Apply closes the drawer and the result count updates": not "the `useFilters` hook
   dispatches correctly".
2. Put them to the dev **in one message**, numbered, and ask what is missing or wrong. One round
   trip, not an interview.
3. Ask the two questions the diff cannot answer: **what should NOT change** (the regression
   surface), and **what would worry you most if it broke** (the risk ranking that decides where
   §8b's budget goes).
4. Record the confirmed list verbatim. From here it is Entry A: those are the ACs, and §9's report
   is written against them.

If the dev is unavailable, proceed on the derived list, **label every AC `derived, unconfirmed`
in the report**, and never state a criterion as verified without saying whose criterion it was.

## 3b. Uncommitted work defeats a worktree — check first

`git worktree add` checks out a **commit**. Uncommitted changes stay in the original working tree,
so a worktree built to isolate the dev's work can silently contain everything except their work.
The tests then pass against the pre-change code and prove nothing. This is the entry-B version of
the negative-control failure, and it looks identical to success.

```bash
git status --porcelain          # empty? worktree is safe — use it
git stash list                  # work parked here is not in a worktree either
```

Three cases, and you must say which one you are in:

| State | Do |
|---|---|
| clean | worktree normally (§3) |
| uncommitted changes | **test in place.** Say so, and do not switch branches; the dev is still working here |
| dev offers to commit/stash | worktree the commit, and confirm the diff you review matches what they meant to ship |

## 8·B. The merge-base IS the negative control

Entry A hunts for an environment without the fix and often settles for a documented fallback.
Entry B has the ideal one locally, so there is no excuse for skipping it:

```bash
git merge-base HEAD origin/main            # the without-fix commit
git worktree add ../nofix <that-commit>    # build and run the NEW suite against OLD code
```

The suite MUST fail there, and you must read it **per test**. A test that passes in both places
tests something that was already true, not the change.

This is the strongest form of §8 and it is nearly free here. **A dev-triggered run that skips the
negative control has no excuse and should not report cover.**

## Source-level mutation is available here

`achilles-mutate` injects at the browser because deployed previews cannot be rebuilt. Locally you
can edit the source, rebuild, and run; which binds the mutation to the actual change rather than
to a behaviour that resembles it. Prefer it when the app runs locally. The rules are unchanged: a
`noop` control, owner-based classification, and proof each mutation applied (**revert every
mutation before moving on**: a mutation left in the tree is a defect you introduced).
