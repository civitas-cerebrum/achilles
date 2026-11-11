# Evidence videos: the storyboard and `achilles-video`

A reproduction video shows a developer with no context what was done, what happened and what should
have happened, at a pace they can follow. One storyboard file describes it, and one command plays it:

```
npx achilles-video <storyboard.json>            # record: <name>.webm, <name>.mp4, <name>.json
npx achilles-video <storyboard.json> --check    # validate only
npx achilles-video <storyboard.json> --headed   # watch it while it records
```

The format is [`schemas/evidence-video.schema.json`](../../../schemas/evidence-video.schema.json); an
example is [`schemas/evidence-video.fixtures/valid-reproduction.json`](../../../schemas/evidence-video.fixtures/valid-reproduction.json).

## When to use it

- **Every defect that shows in the UI** gets one, by default: the reproducer records its reproduction
  ([`../../defect-confirmation/SKILL.md`](../../defect-confirmation/SKILL.md)).
- A "show me" run whose reader wants to watch the flow rather than read screenshots.

A defect that never reaches the screen (an API, backend or data defect) needs no video; its evidence
is the request and response.

## What a video is made of

1. **An opening card**: the title, so a forwarded file still says what it is.
2. **One step per action, captioned.** Each caption is shown on its own for its reading time (400 ms
   plus `pace.wordMs` per word, at least `pace.captionMs`), then its action runs at `pace.actionMs` per
   interaction, with the caption still on screen. A caption repeated from the step before is not held
   again, but every action is followed by `pace.settleMs` on the screen it led to, so no screen a caption
   names flashes by. The player numbers
   captions that do not start with "Step".
3. **An off-camera login.** `auth.steps` run in a separate browser context that is never recorded, or
   `auth.storageState` names a state file. No credential, email or token is ever on screen.
4. **An evidence page.** Proof that is not on the screen, shown in the same recording: a downloaded
   `.docx` read as paragraphs (`match` keeps the relevant ones), an API response or request (`capture`
   plus a `pick` path), or plain text. `highlight` marks the decisive text, and the page scrolls to it.
   `bad: true` marks the panel that shows the failure; `format` turns captured values into a sentence
   (`"{response.data.applied} of {response.data.requested} changes applied"`).
5. **A closing card**: Expected and Actual on a screen of their own, held for its reading time (400 ms plus `pace.wordMs` per word of both), never less than `pace.closingMs`, so it never covers the evidence and is never cut short.

## The quality bar

These are what made the first reproduction videos readable. Keep them.

- **One caption per ticket step, numbered from 1.** Captions are the reproduction steps of the filed
  ticket, one to one, with the same numbers and words, so the ticket and the video read side by side. The
  video always starts at Step 1. When the ticket's step 1 is the login, its caption ("Step 1: log in to
  the test environment as the account owner") is shown on the first screen after the off-camera login.
- **Longer captions, not more of them.** What the reader should notice on that step goes in the same
  caption, after the action: "Step 6: scroll to Delivery date; it shows Not set, yet the order summary
  already lists a date." A step that needs several actions repeats its caption
  exactly, so it is held once. Up to about 30 words; no notes about the recording, no stage directions in
  brackets, no long placeholder lists (the evidence page carries the detail).
- **One action per step.** The player refuses a step with two.
- **At least HD, at the default pace.** Full HD (1920×1080) by default and never below 1280×720, except a
  phone-size reproduction; 400 ms per action, each caption held for its reading time, 5 s of evidence, 4 s
  of closing. Text must be readable at full screen. Actions move quickly; captions stay long enough to
  read once, never so long that the reader waits.
- **The evidence names the defect.** Highlight the exact value that is wrong (the field name, the empty
  blank, the error message), not a JSON key; keep `match` tight enough that only the relevant
  paragraphs show, and show what was sent
  next to what was saved, so the viewer sees cause and effect without a second file.
- **Expected and actual close the video**, in the words of the acceptance criterion or the on-screen
  promise.
- **Real footage only.** Never re-render, splice or edit a recording after the fact. If the evidence
  page was wrong, fix the storyboard and record again. The manifest is the record of what was run.
- **Wait on conditions.** Use `waitFor` (text, element, URL or a capture), never a fixed pause, for
  anything the application does; `pause` is for letting the viewer read.

## Routes: a stand-in for a service

`routes` names a module (a path relative to the storyboard, `.mjs` or `.js`) that sets up the recorded
context before the first page opens, for example Playwright routes that answer a metered or slow
service with a local stand-in. Its default export is called with `{ context, storyboard, env }` and may
return:

- `notice`: what the routes change, in one sentence. It is shown on the title card and kept in the
  manifest (`routes.notice`). A recording made with a stand-in must say so here: a viewer must never
  take the stand-in's answers for the product's.
- `finish()`: run after the last step. Use it for the stand-in's own guard (nothing it should have
  answered reached the network). A throw marks the recording failed (`routes.finish` holds the reason).

## Values and secrets

- `${env:NAME}` takes a value from the environment. It is masked as `[REDACTED]` in the manifest and
  in captured bodies, and a caption may not use it.
- `${run}` is a short id unique to the run; use it in the names of things the video creates, so
  cleanup can find them.
- Request and response headers are never kept.

## Targets

Prefer page-repository entries (`{ "page": "TemplatesPage", "element": "addTemplateButton" }`, with
`pageRepository` pointing at the file). Otherwise use a role and accessible name, a label, a
placeholder, a test id, or text; `css` is the last resort. `nth` picks among several matches, and
`optional: true` lets a dialog that may not appear be skipped without failing the run.

## Checking the result

The manifest `<name>.json` holds:

- every step with its start time in the video, and any error or skip;
- every `expect` with whether it held;
- the captures, with headers stripped and secrets masked;
- the downloads;
- a decode check of each video file.

The run exits 1 when a step failed: the video still ends, on a caption naming the failure. The closing
card states the storyboard's `actual` only when the run showed it; after a stopped step or an
expectation that did not hold it says "Not shown in this recording" and why (`manifest.closing.shown`).
An existing recording of the same name is never replaced without `--force`. Treat a
failed step as a failed reproduction, not as evidence of the defect. Before citing a video:

- confirm `status: "ok"`, the expectations you rely on, and `decoded: true`;
- watch it once end to end.

Attach the `.mp4` to the ticket. It plays inline in trackers and chat.
