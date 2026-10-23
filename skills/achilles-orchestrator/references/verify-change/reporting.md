# Phase 9: compliance sweep, report review, report

Live observation (drive the flow by hand, screenshot and state dump per step, the control element) is §6b in [phase-6-understanding](phase-6-understanding.md); it is done before the tests are written, not after.

## 9a. Compliance sweep: before any verdict leaves the run

**Exit gate.** Every spec this workflow writes or edits gets the Stage 4b compliance sweep before the return, announced with the **API Compliance Review** block ([`stages-protocol.md`](../stages-protocol.md) §"Stage 4b is every mode's exit gate").

A QA verdict rests on the tests that produced it. Sweeping them is part of producing the verdict, not a follow-up task.

## 9b. Report review: `probe-verdict`

**Dispatch one more reviewer at the report itself, before it reaches a human.** §8b attacks the
tests; nothing there attacks the verdict. The verdict is the artifact a person acts on, and it is
the last place an unearned claim can hide.

The `probe-verdict` brief (review skill, Mode 4) carries the draft report, the specs, the negative-control output and the mutation report; the instruction to quote each claim, name the evidence that would support it and state what exists; the hunt list (a criterion called verified where only a proxy was asserted; a suite called regression cover with no negative control; sample sizes not disclosed; "always / never / cannot" on one run; a test cited as covering something it does not assert); the return schema `schemas/subagent-returns/probe.schema.json`; and the rule that silence is a failed dispatch: findings, or every claim checked, listed.

This exists because it was skipped and it cost something real: a shipped verdict declared two
acceptance criteria verified when the suite asserted a *mechanism* for one (`inert`, not
visibility) and a *tautology* for the other (a URL segment a server-side rewrite never produces).
Both passed every test. Only an audit of the claims against the evidence found them.

If the report has already been posted when a finding lands, **correct it in place and say what
changed**. A quietly edited verdict is worse than the original error.

## 9c. Reporting

Report defects the diff review found even when every AC passes: they are the value a human reviewer could not get from a green suite. Separate them clearly from AC verdicts: **"all three ACs pass, and here are four defects"** is a coherent and common outcome.

Never silently upgrade a defect into an AC failure, or silently drop one because the ACs passed.

### Posting to the tracker

The ticket comment is what the developer, the PM, and the next QA engineer will read. Keep it
**brief**: four sections, nothing else:

1. **What was tested**: one or two sentences per AC: what was verified, on which viewports/browsers.
2. **Evidence**: screenshots uploaded and embedded **inline** in the comment body (not as
   separate attachments the reader has to click through). Use the tracker's image markdown
   (`![alt](url)`) so the images render directly in the comment.
3. **Negative control**: one or two sentences stating whether the tests were run against an
   environment without the fix and what happened. This shows
   that the tests discriminate the change. If the control was not run, say so.
4. **Verdict**: the QA outcome and what should happen next. Pass, fail, or pass-with-caveats,
   followed by a clear recommendation: ready to merge, needs fixes, or blocked. Caveats
   (untested browsers, environment limitations) go as one-liners under the verdict.

That is the entire comment. No tables of computed CSS values, no code review notes, no
methodology explanations beyond the negative control result. The evidence screenshots carry
the detail: that is what they are for.

**Example shape:**

```
## QA: PEDX-XXXXX

**PR:** [#1234](https://github.com/org/repo/pull/1234) | **Date:** 2026-08-20

### AC1: Error appears without size selection

Verified on Desktop (Sheet) and Mobile (Drawer). Clicking the button without selecting a size
shows the inline error alert.

![AC1 Desktop: error alert inline](https://uploads.linear.app/…)
![AC1 Mobile: error alert inline](https://uploads.linear.app/…)

### Negative control

Same checks run against production. The styling assertion fails there (button is grey, not blue),
confirming the tests discriminate the fix.

### Verdict

✅ **All ACs pass.** No defects found. Ready to merge.
```

**Upload then embed.** Use the tracker's upload API (`prepare_attachment_upload` → PUT →
`create_attachment_from_upload` on Linear), then reference the returned `assetUrl` in the comment
body as a markdown image. A comment without inline evidence is incomplete.

### One contract, every surface — PR descriptions included

The format above is not tracker-specific. It is the report contract, and it binds **every surface
this run writes for a human reader**: the ticket comment AND the description of any pull request
the run opens (durable tests committed via §8d, or a sign-off summary posted on the dev's PR):

- **What was tested**: the scenarios and behaviours covered. Never HOW: no methodology
  narration, no step-by-step process, no framework mechanics.
- **Findings**: defects or confirmations, one line each, separated from AC verdicts per
  §9c above.
- **Evidence**: screenshots / recordings linked or attached.
- **Verdict**: pass / fail / blocked, with a one-line justification.

**Brevity is a hard requirement, not a style preference.** If a section can be a bullet, it is a
bullet. Anything about *how* the testing was performed is omitted, the reader is deciding
whether to merge, not auditing your process. The one process fact that stays is the
negative-control result, for the reason given above: it is evidence that the tests discriminate
the change, not methodology. Everything else about the rig (tool mechanics, injected state,
framework versions) lives in the evidence bundle, where the next QA engineer can find it without
the reviewer having to scroll past it.
