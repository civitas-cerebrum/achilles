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
2. **One step per action, captioned.** Each caption is shown on its own for `pace.captionMs`, then its
   action runs at `pace.actionMs` per interaction, with the caption still on screen. The player numbers
   captions that do not start with "Step".
3. **An off-camera login.** `auth.steps` run in a separate browser context that is never recorded, or
   `auth.storageState` names a state file. No credential, email or token is ever on screen.
4. **An evidence page.** Proof that is not on the screen, shown in the same recording: a downloaded
   `.docx` read as paragraphs (`match` keeps the relevant ones), an API response or request (`capture`
   plus a `pick` path), or plain text. `highlight` marks the decisive text, and the page scrolls to it.
   `bad: true` marks the panel that shows the failure.
5. **A closing caption**: "Expected: … / Actual: …", held for `pace.closingMs`.

## The quality bar

These are what made the first reproduction videos readable. Keep them.

- **Captions are the reproduction steps**, worded as a reader would do them: "Step 6: choose Always
  'Indefinite period'", not "click locator 3". They match the steps in the written report one to one.
- **One action per step.** The player refuses a step with two.
- **Default pace, not faster.** 1280×800, 600 ms per action, 2.2 s per caption, 9 s of evidence, 6 s of
  closing. A video a developer has to pause to read is too fast.
- **The evidence names the defect.** Highlight the exact text that is wrong, and show what was sent
  next to what was saved, so the viewer sees cause and effect without a second file.
- **Expected and actual close the video**, in the words of the acceptance criterion or the on-screen
  promise.
- **Real footage only.** Never re-render, splice or edit a recording after the fact. If the evidence
  page was wrong, fix the storyboard and record again. The manifest is the record of what was run.
- **Wait on conditions.** Use `waitFor` (text, element, URL or a capture), never a fixed pause, for
  anything the application does; `pause` is for letting the viewer read.

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

The run exits 1 when a step failed: the video still ends, on a caption naming the failure. Treat a
failed step as a failed reproduction, not as evidence of the defect. Before citing a video:

- confirm `status: "ok"`, the expectations you rely on, and `decoded: true`;
- watch it once end to end.

Attach the `.mp4` to the ticket. It plays inline in trackers and chat.
