# Phase 9: observation, compliance sweep, report

## 9. Live observation — watch it, don't just assert it

Assertions confirm what you thought to ask. Watching the page reveals what you didn't. Before trusting a green suite, drive the flow once by hand: screenshot **and** probe state after **every** action, not just at the end.

Step in increments small enough to catch transitions, and capture both a screenshot and a state dump at each step:

```
y=0     header=40,143   pcp=631,712   pos=static  inert=1  stuckMarker=0
y=400   header=0,103    pcp=231,312   pos=static  inert=1  stuckMarker=0
y=560   header=0,103    pcp=71,152    pos=static  inert=1  stuckMarker=1   ← defect window opens
y=1200  header=0,103    pcp=-569,-488 pos=static  inert=0  stuckMarker=1   ← merge completes
```

That trace located a defect window no assertion had bounded: between y≈560 and y≈700 the row reports itself stuck while still `static` **and still half-visible under the header**, so a user can click a pill that is about to report the wrong telemetry. A pass/fail test would never have surfaced the *width* of that window.

**Live comparison.** Where the change is visual, drive the same URL and the same scroll positions on the environment *with* the fix and the one *without*, and diff the screenshots. Differences you cannot explain are findings.

**Assert a control element, always.** A live probe that reports "the feature's selectors are absent" is ambiguous: the feature may be missing, or *the page may never have loaded*. Bot protection, an auth wall or a CDN challenge all render a page where every product selector is absent, and it looks exactly like a shipped-but-disabled feature.

Include one element in every probe that must exist on **any** build of the page (a header, a footer, `<main>`). If the control is missing too, you are not looking at the app and every conclusion from that probe is void. Note also that a suite reaching production via an allowlisted header (`x-e2e-test`) proves nothing about whether an *ad-hoc* browser can: the CLI session gets challenged where the suite sails through.

## 8c. Compliance sweep — before any verdict leaves the session

**Exit gate: the compliance sweep is not optional.** This mode writes test code, so it runs the Stage-4b compliance sweep over every spec it touched before it returns, and announces it with the documented **API Compliance Review** block. That sweep is where API misuse, tautological assertions, missing test IDs and untagged intentional reds get caught. Harness-enforced at stop time by `hooks/compliance-sweep-exit-gate.sh`; the rule and the per-mode table live in [`stages-protocol.md`](../../achilles-protocol/references/stages-protocol.md) §"Stage 4b is every mode's exit gate".

A QA verdict rests on the tests that produced it. Sweeping them is part of producing the verdict, not a follow-up task.

## 9. Report — and have the report reviewed before it ships

**Dispatch one more probe at the REPORT itself, before it reaches a human.** §8b attacks the
tests; nothing there attacks the verdict. The verdict is the artifact a person acts on, and it is
the last place an unearned claim can hide.

```
Agent(description: "probe-verdict-<ticket>", prompt: "
  ADVERSARIAL REVIEW — audit this QA verdict against its evidence. Find overstatement.
  Return shape: schemas/subagent-returns/probe.schema.json (handover{role,status,next-action},
  findings-emitted, finding-ids, summary).
  <the draft report> <the specs> <the negative-control output> <the mutation report>
  For EACH claim: quote it, name the evidence that would support it, and state what exists.
  Hunt for: an AC called 'verified' where only a proxy was asserted; a suite called regression
  cover with no negative control; sample sizes not disclosed; 'always/never/cannot' on one run;
  a test cited as covering something it does not assert.
  MANDATORY: silence is a failed dispatch. Return findings, or list every claim you checked.
")
```

This exists because it was skipped and it cost something real: a shipped verdict declared two
acceptance criteria verified when the suite asserted a *mechanism* for one (`inert`, not
visibility) and a *tautology* for the other (a URL segment a server-side rewrite never produces).
Both passed every test. Only an audit of the claims against the evidence found them.

If the report has already been posted when a finding lands, **correct it in place and say what
changed**. A quietly edited verdict is worse than the original error.

## Reporting

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
  §"Reporting" above.
- **Evidence**: screenshots / recordings linked or attached.
- **Verdict**: pass / fail / blocked, with a one-line justification.

**Brevity is a hard requirement, not a style preference.** If a section can be a bullet, it is a
bullet. Anything about *how* the testing was performed is omitted, the reader is deciding
whether to merge, not auditing your process. The one process fact that stays is the
negative-control result, for the reason given above: it is evidence that the tests discriminate
the change, not methodology. Everything else about the rig (tool mechanics, injected state,
framework versions) lives in the evidence bundle, where the next QA engineer can find it without
the reviewer having to scroll past it.
