---
name: failure-diagnosis
description: >
  **Subagent-only.** Do not load in the orchestrator's transcript — the
  diagnostic methodology + niche-edge-cases catalogue is heavy enough that
  inlining it contaminates orchestrator context. The orchestrator detects
  a failure and dispatches a subagent; the subagent loads this skill.
  Loading this skill into orchestrator context is a methodology violation
  (the skill is heavy enough to contaminate orchestrator context). The
  previous harness-side guard was retired in 0.3.6; respect the convention
  by dispatching a subagent.

  Diagnose failing Playwright tests through structured evidence-based triage.
  Two entrypoints — a LOCAL failure (artifacts already on disk) and a
  PIPELINE failure (artifacts still inside the CI run, and the first move is
  to pull them down, not to re-run locally).
  Activates inside subagent context (composer-/probe-/process-validator-/
  cleanup-/repair-worker- prefixes) when a test fails during any mode
  (authoring, maintenance, test-composer, bug-discovery, self-repair), or when
  the dispatching brief says "test is failing", "debug this", "why is this
  failing", "fix this test", or when another companion skill encounters a test
  failure.
  Pipeline triggers (Entrypoint C): "the nightly failed", "nightly regression
  failed", "the regression failed", "CI is red", "the build is red", "the
  pipeline failed", "the workflow failed", "the GitHub Actions run failed",
  "the prod regression is failing", "analyse the failures" / "analyze the
  failures", "why did the run fail", "what failed in CI", "look at run <id>",
  "download the trace", "get the trace from CI", "check the trace", "open the
  trace", "investigate the failure", "triage the CI failures".
  Guides the agent through trace inspection, screenshot analysis, DOM
  inspection, browser-console review, root cause hypothesis, then fixes test
  issues autonomously or reports app bugs with evidence.

  Auto-invoked via Skill tool from achilles-protocol Rule 7 (after
  the orchestrator dispatches the subagent), test-composer's stabilization
  loop, bug-discovery's adversarial probes, test-repair's per-cluster
  diagnosis, and any subagent that runs tests and observes a failure —
  those callers explicitly route to this skill rather than relying on
  always-load.
subagent-only: true
---

> **Activation banner:** The first user-facing reply after this skill loads MUST begin with the line: **Protocol Achilles activated.** Once per session — skip if already declared in this conversation. Subagents (which return structured data, not user-facing text) are exempt.


# Failure Diagnosis

A structured diagnostic protocol for failing Playwright tests. Every failure gets the full pipeline — no "retry and hope."

## When This Activates

- A test run produces failures (from any mode)
- User says "test is failing", "debug this", "why is this failing", "fix this test"
- Another companion skill encounters a failure during its workflow
  (exception: `companion-mode` treats Phase-4 failures as a first-class
  bundle outcome — failure-diagnosis is only its Phase-6 handoff, on
  explicit user assent)
- **A pipeline run went red** — "the nightly failed", "the regression failed",
  "CI is red", "the build is red", "the pipeline failed", "the workflow
  failed", "the GitHub Actions run failed", "the prod regression is failing",
  "analyse the failures", "why did the run fail", "what failed in CI", "look at
  run \<id\>", "download the trace", "get the trace from CI", "check the trace",
  "open the trace", "investigate the failure", "triage the CI failures"

## Entrypoints

Two ways in. They differ **only** in how Stage 0's source-of-truth and Stage 1's evidence are obtained — everything from Stage 2 onward is identical.

| Entrypoint | You are here when | First move |
|---|---|---|
| **L — local failure** | The failing run happened on this machine. `test-results/` and `playwright-report/` exist in the workspace and are fresh. | Stage 0, then Stage 1 against the on-disk artifacts. |
| **C — pipeline failure** | The failure happened in CI. The workspace has no artifacts for it (or has stale ones from a different run). The user named a run, a workflow, a nightly, "CI", or a red pipeline. | Stage 0 **including its commit-pinning step**, then **Stage 0b — pull the evidence down from the run**, then Stage 1 against the downloaded artifacts. |

**Entrypoint C does not start by re-running the suite locally.** A local re-run is a *different execution* on a different machine, browser build, dependency tree, network path, viewport, and data state — it answers "does it fail for me too?", not "why did *that* run fail?". The run's own trace / video / screenshot / console are the primary evidence and they already exist. Re-running locally is a Stage 3 reproduction step (and Stage 5 verification step), never the opening move. If the artifacts have expired or were never uploaded, say so explicitly in the report before falling back to a local reproduction.

---

## Diagnostic Pipeline

### Stage 0 — Context Pre-Read (mandatory)

Before collecting evidence on the failing test, read what the project already documents. Skipping this stage is how confidently-wrong "app bug" classifications get published — you compare the screenshot against your recollection of the page instead of against what the project already specifies.

**Methodology rule.** Failure-diagnosis edits and bug-report writes that skip the documented context pre-read produce confidently-wrong "app bug" classifications. The previous harness backstop that blocked these writes was retired in the 0.3.6 cleanup; the pre-read remains mandatory.

**Locate the files — do not assume the paths.** The paths below are the *scaffold defaults*, not a guarantee. Real consumers put their suite at `apps/e2e/`, `packages/e2e/`, `e2e/`, or a workspace package of their own naming, and some of these documents do not exist at all. Resolve each one before reading it, and record what you found (or that it is absent):

```bash
# The suite's docs directory, wherever it lives
find . -name app-context.md -not -path '*/node_modules/*' 2>/dev/null
find . -name 'journey-map.md' -o -name 'test-scenarios.md' -not -path '*/node_modules/*' 2>/dev/null

# The element repository, whatever it is called and wherever it sits
find . -name 'page-repository*.json' -not -path '*/node_modules/*' 2>/dev/null
# ...or read it out of the fixture that constructs the repository
grep -rn "page-repository" --include='*.ts' . | grep -v node_modules | head
```

1. **`app-context.md`** (scaffold default `tests/e2e/docs/app-context.md`) — page structures, intended modal lifecycles, `data-qa` selectors, known UI quirks (configuration-dependent option subsets, redirect-vs-popup auth patterns, vendor-aliased payment / shipping methods, async-loaded modal placeholders, documented degradation banners, etc.). Read the section for the page the test was on at the moment of failure. This is where the failing element's intended behaviour is documented. **This is the single highest-value step in the pipeline** — repeatedly, the failure shape under diagnosis is already written down here from a previous session, which turns an open-ended investigation into a confirm-or-refute. Never skip it, never skim it, and never substitute your recollection of the page for it.
2. **`test-scenarios.md`** (scaffold default `tests/e2e/docs/test-scenarios.md`) — the regression / scenario matrix, when the project keeps one. Confirms whether the failing scenario is even supposed to run on this configuration in the first place. Many projects have no such file; its absence is a note in the evidence package, not a blocker.
3. **`journey-map.md`** (when present) — the user journey map produced by the `journey-mapping` skill. Tells you whether the app's flow has changed since the test was written.
4. **The element repository** (scaffold default `tests/data/page-repository.json`; commonly `<e2e-root>/elements/page-repository.json` in real consumers) — the locator entries for the page in question. A stale or missing entry is one of the most common true root causes. **The entries are nested under a top-level `pages` key** — reading the root object and finding only `{ "pages": … }` does not mean the entries are missing. Address them as `.pages["<PageName>"]`:

   ```bash
   jq -r '.pages | keys[]'                    <repo-path>   # page names
   jq -r '.pages["CheckoutPage"] | keys[]'    <repo-path>   # element names on one page
   ```

Capture, in plain text, the documented expectations relevant to the failing step. The rest of the diagnostic pipeline is then comparing **observed** state against **documented** state — not against your recollection of what the page should do.

If any of these files are missing for the project, **note that** in the evidence package and consider whether the right escalation is to re-run `journey-mapping` on the relevant page rather than diagnose blind.

#### Stage 0a — Pin to the run's commit and dependency tree (Entrypoint C — mandatory)

**Before reading a single line of source, establish which code actually ran.** Your working tree is not the run under diagnosis. It is on a different branch, at a different commit, with a different `node_modules` — and the framework or app source you read from it may be the *fixed* implementation of the very defect that produced the failure. Reading local source against a CI failure is how a diagnoser spends a session hunting a phantom app bug for a defect that was already fixed upstream.

1. **Resolve the run's commit.**

   ```bash
   gh run view <run-id> --json headSha,headBranch,workflowName,displayTitle
   ```

2. **Read source at that commit, not from the working tree.** Either `git show`, or a pinned worktree when you need to browse:

   ```bash
   git fetch origin <headSha> 2>/dev/null || git fetch origin
   git show <headSha>:<path/to/file.spec.ts>
   git show <headSha>:playwright.config.ts
   git show <headSha>:<e2e-root>/elements/page-repository.json

   # Browsing many files is easier from a detached worktree
   git worktree add /tmp/fd-<run-id> <headSha>
   ```

3. **Diff the dependency versions the run resolved against your local ones.** This is the check that most often flips a diagnosis:

   ```bash
   # What CI resolved — read it straight out of the failing stack trace's paths,
   # which embed the version: .../@civitas-cerebrum+element-interactions@0.3.8/...
   grep -oE '@civitas-cerebrum\+[a-z-]+@[0-9]+\.[0-9]+\.[0-9]+' <log-or-trace-error>

   # What the run's lockfile pinned
   git show <headSha>:package-lock.json | jq -r '.packages | to_entries[]
     | select(.key | test("@civitas-cerebrum")) | "\(.key) \(.value.version)"'

   # What YOU have locally
   npm ls @civitas-cerebrum/element-interactions @civitas-cerebrum/element-repository 2>/dev/null
   ```

   Write the comparison down explicitly — `CI: element-interactions@0.3.8 / local: 0.3.9` is a finding on its own. **When the versions differ, the local framework source is inadmissible as evidence about the run.** Read the CI-resolved version's source instead (`npm view <pkg>@<version>`, or unpack that exact version into a scratch directory), and check the package's changelog / releases between the two versions before proposing any heal. A defect fixed between the run's version and yours is classified under Stage 3's **framework / dependency defect** branch and healed with strategy **(i)**, not worked around in the test.

4. **Record the pinning in the evidence package** — run id, `headSha`, branch, and the resolved framework versions. Every source citation from here on is a citation *at that commit*.

### Stage 0b — Pipeline evidence retrieval (Entrypoint C — mandatory)

The failing run's artifacts are the evidence. Pull them down before forming any hypothesis. All commands below are `gh` CLI and read-only.

**1. Find the failing run and job.**

```bash
# Which workflows exist (name → numeric id)
gh workflow list

# Recent runs for one workflow — accepts the workflow file name OR its numeric id
gh run list --workflow=playwright-prod-regression.yml --limit 10 \
  --json databaseId,conclusion,status,displayTitle,headBranch,headSha,createdAt

# The run's jobs, their conclusions, and per-step outcomes
gh run view <run-id> --json conclusion,workflowName,headBranch,headSha,jobs
```

Identify the job whose `conclusion` is `failure` and the step inside it that failed (usually the `Run tests` step). The failing job's `databaseId` is what the log commands take. `headSha` is what Stage 0a pins to.

**2. Read the failing step's log — for the failure *list*, not the diagnosis.**

```bash
gh run view <run-id> --job <job-id> --log-failed
```

This tells you *which* tests failed and the shape of the error line. It does **not** tell you why — that is what the trace, DOM and console are for (Stage 1's evidence floor). Do not stop here.

**3. List the artifacts before downloading — sizes matter.**

```bash
gh api repos/<owner>/<repo>/actions/runs/<run-id>/artifacts \
  --jq '.artifacts[] | "\(.name)  \(.size_in_bytes)  expired=\(.expired)"'
```

`expired=true` means GitHub has garbage-collected the artifact (default retention is 90 days, often shortened per-repo). An expired artifact is a hard evidence gap — record it and say so in the report rather than silently substituting a local re-run.

**4. Download.**

```bash
# Everything (one directory per artifact name)
gh run download <run-id> --dir <dest>

# One artifact by exact name (extracted directly into <dest>, no wrapper dir)
gh run download <run-id> --name <artifact-name> --dir <dest>

# By glob — useful when only the mobile / desktop shard failed
gh run download <run-id> --pattern '*mobile*' --dir <dest>
```

Add `--repo <owner>/<repo>` when the run is not in the current working directory's repo. Download to a scratch directory, never over the workspace's own `test-results/` — mixing run artifacts with local ones is how a stale screenshot ends up in an app-bug report.

**5. Map the layout — and mind the attempt/retry split.** A Playwright artifact unpacks to:

```
<dest>/[<artifact-name>/]
├── playwright-report/                       # the HTML report — npx playwright show-report <dir>
│   ├── index.html
│   ├── data/                                # attachments referenced by the report
│   └── trace/
└── test-results/
    ├── <shard>-results.json                 # JSON reporter output, if configured
    ├── <sanitized-title>-<project>/         # ATTEMPT 0 — the failure
    │   ├── test-failed-1.png                # failure screenshot
    │   ├── video.webm
    │   └── error-context.md                 # Playwright's aria "Page snapshot" at failure
    └── <sanitized-title>-<project>-retry1/  # ATTEMPT 1 — a SIBLING directory
        ├── trace.zip
        ├── video.webm
        └── error-context.md
```

**The attempt directories are siblings with different contents, and the trace is frequently on the wrong one.** Under `trace: 'on-first-retry'`, attempt 0 — the attempt that actually failed — has the screenshot, the video and `error-context.md` but **no trace**, while `-retry1/` carries the only `trace.zip`. On a flaky test the retry *passed*, so that trace shows a clean, fast, uneventful run. A diagnoser who opens the only `trace.zip` they can find, sees a 2.1s successful click, and writes "cannot reproduce" has read the wrong attempt. Flaky-on-CI is the most common CI-only shape, so this is the default trap, not an edge case:

```bash
ls -d <dest>/test-results/*/                                    # every attempt directory
ls -la <dest>/test-results/<sanitized-title>-<project>/         # attempt 0 — the failure
ls -la <dest>/test-results/<sanitized-title>-<project>-retry1/  # attempt 1 — often the only trace
```

Always state **which attempt** each artifact you cite came from, and whether that attempt passed or failed.

The failing specs come straight out of the JSON reporter file when present:

```bash
jq -r '.. | objects | select(has("ok") and has("tests")) | select(.ok == false)
       | "\(.file):\(.line) — \(.title)"' <dest>/test-results/<shard>-results.json

jq -r '.. | objects | select(has("ok") and has("tests")) | select(.ok == false)
       | .tests[].results[] | select(.status == "failed" or .status == "timedOut")
       | .error.message' <dest>/test-results/<shard>-results.json
```

**The JSON reporter carries two fields the HTML report buries, and both are decisive more often than the error message:**

```bash
# stderr — the framework's own tester:* step log for that result. Shows the exact
# sequence of interact/verify calls, and how many times a retry loop actually ran.
jq -r '.. | objects | select(has("status") and has("stderr"))
       | .stderr[]? | .text? // empty' <dest>/test-results/<shard>-results.json

# annotations — an EMPTY array is evidence too. The framework pushes annotations for
# paths it took (e.g. an `interception-fallback` annotation); absence proves the
# fallback path did NOT run, which no screenshot can tell you.
jq -r '.. | objects | select(has("status") and has("annotations"))
       | "\(.status): \(.annotations)"' <dest>/test-results/<shard>-results.json
```

**6. Establish whether a trace exists before you go looking for one.** Read the project's `playwright.config.ts` **at the run's commit** (Stage 0a) — `use.trace` decides this, and the answer differs per project and per branch:

| `use.trace` | `retries` on CI | Is there a `trace.zip`? |
|---|---|---|
| `retain-on-failure` | any | **Yes** — in every failed test's directory, first attempt included. |
| `on-first-retry` | `>= 1` | **Only in the `-retry1` directory** — i.e. on the attempt that may well have passed. The failing first attempt has screenshot + video + `error-context.md` and no trace. |
| `on-first-retry` | `0` | **No.** No retry ran, so nothing was recorded. This is the usual reason a local failure has no trace. |
| `off` / unset | any | **No.** |

Check it directly rather than assuming, including on the branch the run was built from:

```bash
git show <headSha>:playwright.config.ts | grep -nE "trace:|retries:|video:|screenshot:"
grep -nE "trace:|retries:|video:|screenshot:" playwright.config.ts   # your working tree, for the diff
```

**When no trace exists for the failing attempt**, do not treat that as permission to diagnose from the log. Work the rest of the evidence floor — `test-failed-1.png`, `error-context.md` (which carries the full aria page snapshot at the moment of failure), `video.webm`, and the JSON reporter's `stderr` / `annotations` — and state in the report that the trace was unavailable and why. Then, separately from the diagnosis, flag the config: `trace: 'on-first-retry'` is a known evidence gap and `retain-on-failure` is this suite's documented default (see `achilles-protocol/SKILL.md` Rule 8). Fixing it is a follow-up item, not a substitute for this session's evidence.

**7. Open the trace.** Interactive, when a human is watching:

```bash
npx playwright show-trace <dest>/test-results/<test-slug>-retry1/trace.zip
```

Headless — a `trace.zip` is a plain zip of JSONL streams and resources, so it reads programmatically without a browser:

```bash
unzip -o -q trace.zip -d ./trace-x

# The test-runner stream: every action, in order, with its error
jq -r 'select(.type == "before") | "\(.class).\(.method) — \(.title)"' ./trace-x/test.trace
jq -r 'select(.type == "after" and has("error")) | .error.message'    ./trace-x/test.trace

# The browser-context stream: console, network, DOM snapshots, screencast frames
jq -r '.type' ./trace-x/0-trace.trace | sort | uniq -c
jq -r 'select(.type == "console") | "[\(.messageType)] \(.text)"'      ./trace-x/0-trace.trace
jq -r 'select(.type == "frame-snapshot") | .snapshot.frameUrl'          ./trace-x/0-trace.trace | tail -1
```

Useful shapes inside the archive:

- `test.trace` — the runner stream. `before` entries carry `class`, `method`, `title`; the matching `after` entry carries `error.message` with Playwright's full call log (including the resolved element's outerHTML). This is where "which action failed, against what element" is answered without ambiguity.
- `0-trace.trace` — the browser stream: `console`, `frame-snapshot`, `screencast-frame`, `input`, `log`.
- `0-trace.network` — every request/response of the run.
- `resources/page@*.jpeg` — the screencast frames. Read the last few with the Read tool to see the UI at the moment of failure without launching the viewer.
- `resources/*.txt` / hashed files — captured page resources (scripts, stylesheets, HTML) as served during the run.

`frame-snapshot.snapshot.html` is Playwright's delta-encoded DOM format (nested arrays, not raw HTML). For a readable DOM at failure, prefer `error-context.md`'s aria page snapshot; use the trace viewer when you need the live DOM tree.

**8. Watch the video when the trace is missing or the failure is motion-dependent.** `video.webm` sits beside the screenshot in each attempt directory and is often the only timeline available for the failing attempt — it answers "did the drawer ever open", "how long did the spinner stay up", "did the element move under the cursor". Extract frames with `ffmpeg` when present:

```bash
ffmpeg -i video.webm -vf fps=1 frame-%03d.png    # ~1fps sampling is enough for a timeline
```

**When `ffmpeg` is absent** (common on a locked-down machine), do not skip the video. Fall back to a browser: write a tiny `file://` HTML wrapper that loads the `.webm` in a `<video>` element, drive it with Playwright's bundled chromium, seek in ~1s steps, and screenshot each step. It is slower than `ffmpeg` and entirely sufficient for a timeline.

**9. Record the provenance.** Every artifact path you cite from here on is a *downloaded CI path*, not a workspace path. Note the run id, `headSha`, job name, branch, browser/project, and **which attempt directory** each artifact came from — a diagnosis attached to the wrong run, or to the passing retry, is worse than no diagnosis.

### Stage 1 — Collect Evidence

Do NOT guess from the error message alone. Collect visual and structural evidence first.

#### Evidence floor — non-negotiable, both entrypoints, both conclusions

Before you write down a root cause, propose a heal, edit a spec, touch the element repository, or file an app-bug report, you must have inspected **all three** of the following and written down what each one showed:

| # | Evidence | Local (Entrypoint L) | Pipeline (Entrypoint C) |
|---|---|---|---|
| **1** | **The trace** | `test-results/<sanitized-title>-<project>[-retryN]/trace.zip` — `npx playwright show-trace <path>`, or unzip + `jq` per Stage 0b step 7 | Same, from the downloaded artifact — and name the attempt it came from (Stage 0b step 5) |
| **2** | **The UI / DOM at failure** | `test-results/<sanitized-title>-<project>/test-failed-1.png` + `error-context.md`'s aria page snapshot; the trace's last `frame-snapshot` / screencast frames | Same, from the downloaded artifact, **attempt 0** — the attempt that failed |
| **3** | **The browser console** | `jq 'select(.type=="console")' 0-trace.trace` from the trace; or a fresh `playwright-cli` console read on reproduction | Same — the console lines are inside the downloaded trace |

Each one gets an explicit written observation, even when it is negative — "console: 7 messages, all third-party script-blocking notices, nothing from app code" is a finding. "I didn't look" is not.

**The floor binds both conclusions, not just app bugs.** Stage 6's rule that an app-bug report must cite an artifact only binds *after* you have already concluded "app bug". The cheaper and far more common conclusion is "test issue" — and that is precisely the one that most needs a floor, because a wrong test-issue call produces a spec edit that hides the real defect and makes the suite lie. Classifying a failure as a test issue, a flake, or a framework defect without the floor is the same violation as classifying it as an app bug without it.

**If a piece of the floor is genuinely unavailable** (no trace on the failing attempt because of `on-first-retry`; artifact expired; console empty because the trace predates the failure), name the specific gap and the specific reason in the evidence package, and proceed on the remaining evidence — including the JSON reporter's `stderr` and `annotations` and the video. A named gap is auditable; a silent one turns the whole classification into a guess.

**Anti-rationalizations — the log-text-only diagnosis.** The dominant real-world failure of this skill is an agent reading the CI log or the terminal error, recognising a familiar-looking error string, and shipping a root cause without ever opening the trace. Every one of these framings is the same move:

- "the error message is obvious — it's a timeout on the apply button"
- "it's clearly a timeout, the trace won't add anything"
- "I can tell from the stack trace exactly which locator failed"
- "the call log already shows the resolved element, so I've effectively seen the DOM"
- "the failure name says `strict mode violation` — that's self-explanatory"
- "opening the trace is expensive / the trace viewer needs a browser / it's a 30MB zip"
- "downloading the artifact is slow, I'll just re-run it locally"
- "I'll form the hypothesis first and check the trace only if it doesn't hold"
- "three tests failed the same way, so one log line covers all three"
- "the error is identical to a failure I diagnosed earlier in this session"
- "the trace I found shows a clean pass, so it isn't reproducible" (you read the retry, not the failure — Stage 0b step 5)
- "I read the framework source, so I know what it does" (from *your* `node_modules`, not the version CI resolved — Stage 0a)

**Reality:** the error message tells you *where execution stopped*. It does not tell you *what the page was doing*, and those are different questions — which is the entire reason the trace exists. `Timeout ... waiting for element to be visible, enabled and stable` is emitted identically by an overlay intercepting pointer events, a sticky cookie banner, an element animating forever, a mid-flight client-side navigation, a 500 behind a skeleton, a framework-side retry defect, and a genuinely absent element. The call log's resolved-element `outerHTML` proves the element *matched*; it says nothing about what was painted on top of it. Recognising the error *shape* from a previous diagnosis is exactly the condition under which a different root cause gets the previous session's answer stapled to it. Cost is not a reason: `unzip` + `jq` reads a trace headlessly in seconds, and the screencast frames are readable images.

A root cause proposed without the evidence floor is a guess, and Stage 4a's preconditions cannot be honestly evaluated against a guess — every heal that follows inherits the guess.

#### Steps

1. **Read the error message and stack trace.** Note the test file, line number, step name, and error type — and the framework version embedded in the stack trace's `node_modules` paths (Stage 0a step 3). This scopes the search; it does not answer it.
2. **Open the trace** (floor #1), from the attempt that failed. Walk the action sequence to the failing call, then look at what the page was doing in the seconds before it — network activity, navigations, overlays appearing, content swapping.
3. **Read the failure screenshot and the DOM at failure** (floor #2). The per-attempt evidence lives in `test-results/<sanitized-title>-<project>[-retryN]/` — the screenshot on disk is `test-failed-1.png`, and the aria page snapshot is in `error-context.md` beside it. Open both directly with the Read tool. (The HTML report at `playwright-report/` is a viewer over the same attachments — `npx playwright show-report <report-dir>` is convenient for a human, but the per-attempt directory is where the files you cite actually live.)
4. **Describe what the screenshot and DOM show.** State explicitly: page state, visible elements, error messages, unexpected UI, loading indicators, overlays. Write this down — it informs every subsequent decision.
5. **Read the browser console** (floor #3). Note app-code errors, failed requests, CSP/blocked-resource notices, and framework warnings. Distinguish third-party noise from app-origin errors; only the latter is evidence about the app.
6. **Read the JSON reporter's `stderr` and `annotations` for the failing result** (Stage 0b step 5). The `tester:*` step log in `stderr` is the framework's own account of what it did — including how many times a retry loop ran; an empty `annotations` array proves a fallback path did not fire.
7. **Watch the video** when the trace is absent or the failure is motion-dependent (scroll, animation, transient overlay) — `video.webm` sits beside the screenshot in the same attempt directory.
8. **If the evidence is still insufficient:** use `@playwright/cli` (see [`../achilles-protocol/references/playwright-cli-protocol.md`](../achilles-protocol/references/playwright-cli-protocol.md)) to navigate to the failing page URL and take a fresh snapshot — `npx playwright-cli -s=fd-<short-slug> open --browser=chromium <URL>` then `npx playwright-cli -s=fd-<short-slug> snapshot`. Inspect the DOM for the element the test was trying to interact with. For Entrypoint C, note that this is a *different environment* from the run under diagnosis; differences between the two are themselves evidence, not corrections.

### Stage 2 — Group Failures

Before diagnosing individually, look at the big picture:

1. **Scan all failures** in the test run output.
2. **Group by likely root cause:**
   - Same missing page/element in the repository → single repo issue
   - Same page failing to load → navigation or app issue
   - Same timeout pattern → timing or environment issue
   - Same API misuse pattern → test code issue
3. **Prioritize:** Fix the root cause that unblocks the most tests first. A single missing page-repository entry might cause 10 failures — fix it once, not 10 times.

### Stage 3 — Classify

Determine whether each failure group is a **test issue**, **app bug**, a **framework / dependency defect**, or **ambiguous**. You must meet the burden of proof before classifying.

**Precondition:** Stage 1's evidence floor (trace, UI/DOM at failure, browser console) is complete for the group's representative failure, or its gaps are named with reasons. Classifying without it is not permitted — the classification criteria below are all statements about observed page state, and log text is not observed page state. This precondition applies to *every* branch below, including the test-issue branch.

#### Test Issue — fix autonomously

**All** of the following must be true:
- Screenshot shows the page loaded correctly **and the expected UI matches what `app-context.md` describes for this page** (Stage 0 read this), and the expected element is visible in the DOM at the documented selector
- Error is traceable to test code: wrong selector, wrong param order, missing wait, stale repo entry, API misuse, incorrect assertion
- DOM inspection confirms the element exists but the test targeted it incorrectly

Common test issues:
- Wrong `(elementName, pageName)` argument order
- Missing or stale `page-repository.json` entry
- Missing `waitForState` or `waitForNetworkIdle` before interaction
- Hardcoded assertion value that doesn't match dynamic content
- Test isolation problem — stale cookies/localStorage from prior test
- Navigation race — test interacts before page finishes loading

#### App Bug — hard stop, report to user

**At least one** of the following must be true:
- Screenshot shows unexpected UI state (blank page, error message, broken layout, wrong content displayed)
- DOM inspection confirms the element genuinely doesn't exist or the app produces incorrect output
- The test logic is correct per the scenario — the app simply doesn't do what it should

Additionally: the bug must be **reproducible** (not a one-off network blip). There are two admissible evidence tiers, and the second exists because triaging a production pipeline from artifacts alone cannot satisfy the first:

| Tier | How reproduction is established | When it applies |
|---|---|---|
| **R1 — live reproduction** (preferred) | Navigate to the page manually via `playwright-cli` (`-s=fd-<short-slug> open ...`, then `goto`/`snapshot`/`click`) and observe the defect. | The environment is reachable from this session and safe to drive. |
| **R2 — artifact-only** | Reproduction is established from the run's own artifacts, and the report says so explicitly. Requires **all** of: (a) the failing behaviour is visible in the trace or the failure screenshot / aria snapshot — not merely inferred from the error text; (b) it is **not** a one-off — the same shape appears in ≥2 independent observations (two tests in the run, two attempts, two runs, or one run plus a documented prior occurrence in `app-context.md`); (c) the counter-hypotheses are excluded from the evidence itself — no app-origin console error explaining it away, no 5xx/network failure in the trace's network stream, no third-party blocked-resource notice. | The failure happened in CI and the environment is not reachable from here (prod pipeline, ephemeral preview, gated network, destructive flow). |

**R2 is a full-strength classification, not a hedge** — a production pipeline triage that has the trace, the DOM at failure, the console, and two independent observations has more evidence than most live reproductions do. What it is not is a licence to skip the evidence floor: R2 raises the bar on the artifacts precisely because there is no live probe behind them. State the tier in the report (`Reproducible: R2 — artifact-only; <the two observations>`), and name why R1 was unavailable.

**When you identify an app bug: STOP.** Do NOT modify the test to accommodate the bug. Report it (see Stage 6).

#### Framework / dependency defect — do not touch the test, upgrade instead

**All** of the following must be true:

- The failing behaviour originates inside a dependency, not inside the app or the spec — the stack trace's frames run through the framework's own code (`node_modules/.../@civitas-cerebrum/element-interactions/...`, or another dependency), and the trace / `stderr` step log shows the framework taking the wrong path (a retry loop that ran once when it should have retried, a fallback that never fired, a wait that resolved early)
- Stage 0a's version comparison shows the run resolved a version **older than** one in which the behaviour differs — the package's changelog / release notes / commit history between the run's version and a later one describes the same defect, **or** the same test passes against the later version with no spec change
- The spec's logic is correct per the scenario and the app's behaviour is correct per `app-context.md`

Typical shape: the failing stack trace's path embeds `@civitas-cerebrum+element-interactions@0.3.8`, the local tree is on `0.3.9`, and the difference between them is exactly the defect. This is the classification that a version-blind diagnoser most often mislabels — as an app bug (because the app "didn't respond"), or as a test issue (because a `waitForState` "would fix it"). Both produce a durable workaround for a defect that a version bump removes.

**Heal:** strategy **(i) dependency / framework upgrade** (Stage 4a). Do NOT add a wait, a retry, a `force`, or a selector change to route around a defect that is already fixed upstream — a workaround for a fixed bug outlives the bug and hides the next one.

#### Ambiguous — escalate to user

- Evidence supports both interpretations
- The app changed intentionally but tests weren't updated (is this a test issue or a spec change?)
- Present all evidence and ask the user to classify before acting

### Stage 4 — Edge Case Checklist

Before finalizing your classification, run through this checklist:

| Edge Case | What to Check | Likely Classification |
|---|---|---|
| **Element obscured/overlapped** | Screenshot shows overlays, modals, z-index issues blocking the target element | App bug if the overlay shouldn't be there; test issue if the test forgot to dismiss a dialog or close a modal |
| **Timing-dependent content** | Screenshot shows loading state, spinner, or skeleton instead of the expected content | Test issue — add explicit `waitForState`, `waitForNetworkIdle`, or `waitForResponse` before the interaction |
| **Data-dependent failure** | Assertion expects a specific count or text value that doesn't match what's displayed | Check whether the assertion is hardcoded to fragile values; may be either a test issue (use dynamic assertion) or app bug (data is wrong) |
| **Environment differences** | Failure only in CI, passes locally; or vice versa | Note the environment context; check viewport size, network conditions, base URL differences. Often a test issue — add resilience |
| **CI-only, "passes for me"** | Entrypoint C: the test passes on a local re-run. Compare the CI trace against the local run — base URL, viewport env, browser project, locale, blocked third-party scripts in the CI console, worker count, **and the dependency versions the run resolved vs. yours (Stage 0a)**. The CI trace is authoritative for what CI did. | Do NOT close as "not reproducible". Either name the environmental difference the CI trace shows, classify as a framework/dependency defect if the versions differ, or classify as flaky and follow (f) — a green local run is not evidence the CI failure was spurious |
| **The only trace shows a clean pass** | The `trace.zip` you opened came from `-retry1/`, and under `trace: 'on-first-retry'` that is the attempt that succeeded. Check the sibling attempt-0 directory (Stage 0b step 5). | Not a classification — an evidence error. Re-read attempt 0's screenshot / `error-context.md` / video and the JSON reporter's `stderr` before classifying anything |
| **Failure originates inside the framework** | Stack-trace frames run through `node_modules/.../@civitas-cerebrum/element-interactions/...`; the run's resolved version is older than your local one (Stage 0a) | **Framework / dependency defect** — heal `(i)` upgrade. Not a test issue, not an app bug |
| **Partial page load** | Page loaded but a specific section didn't render (lazy-loaded component, conditional feature flag) | Inspect DOM for presence of the container; app bug if the component is missing from the DOM, test issue if it needs a wait |
| **Stale browser state** | Cookies, localStorage, or cached data from a previous test contaminating the current one | Test isolation issue — test issue. Ensure tests don't depend on shared state |
| **Navigation race** | URL shows an intermediate state; page is mid-redirect when the test tries to interact | Test issue — add `verifyUrlContains` or `waitForState` after navigation |
| **Third-party dependency** | CDN asset failed, external widget didn't load, embedded iframe timed out | Neither test nor app bug — report as infrastructure/external dependency issue |
| **Modal opens but content hangs** | Frame mounts but content stays on a spinner sentinel — see [`references/niche-edge-cases.md`](references/niche-edge-cases.md) entry (1) for the disambiguating probe and full prose | **App bug** — apply Stage 4a heal `(h)` (documented-quirk, no heal) |

### Niche edge cases

Failure shapes that LLMs routinely misclassify are catalogued in [`references/niche-edge-cases.md`](references/niche-edge-cases.md). Read the relevant entry before classifying when the failure shape doesn't fit Stage 4's table cleanly.

**The catalogue is meant to grow.** When you resolve a failure whose shape isn't already documented there, **append a new entry as part of the same diagnostic session** — before closing out / handing back to the caller. The entry costs a few minutes; future sessions (yours, other contributors', other consumers of the package) get to skip the wrong-direction work this entry catalogues.

When to append (criteria — must hold ALL):

1. **You actually misclassified at first** (or were close to). The catalogue is for shapes that *trap* the diagnoser — not for failures whose classification was obvious from the screenshot. If Stage 0 + Stage 4 got you to the right answer cleanly, no entry needed.
2. **The disambiguating probe was non-obvious.** The thing you ended up doing — the specific tool call, DOM read, or evidence grab that flipped the classification — is what the next diagnoser most needs. If your probe was just "look at the screenshot more carefully", that's not catalogue-worthy.
3. **The shape is reproducible across consumers**, not project-specific. A bug in *this app's checkout flow* is a project finding, not a niche-edges entry. A bug shape that any consumer of the package could plausibly hit (modal-fetch hangs, role-attribute serialisation, page-repo entry resolves but matches a hidden duplicate, etc.) is.

When all three hold, follow the entry shape documented in `references/niche-edge-cases.md` §"Adding an entry" (Symptom / Why LLMs struggle / Disambiguating probe / Classification / Cross-link). Keep entries tight — one paragraph per field, not a war story.

Contribution path for promoted entries: see `skills/contributing-to-achilles-protocol/SKILL.md` §"Contributing to the niche-edge-cases catalogue" — covers the criteria above, the entry template, and how to ship the change as part of either a normal PR or a standalone docs PR.

### Stage 4a — Heal strategy selection

Once you've classified the failure as a test issue and checked edge cases, pick a healing strategy. Every heal has a precondition, an autonomy level, and a clear scope — applying the wrong one is how bugs get masked.

| Heal | Autonomy | Precondition | What it does |
|---|---|---|---|
| **a. Selector re-learn** | **Auto** | Page-repo lookup failed; live DOM has a close match by text/role/landmark; screenshot shows correct UI otherwise | Update `page-repository.json` with the re-learned selector; immediate confirmation run |
| **b. Timing hardening** | **Auto** | Intermittent timeout on a known-good element; screenshot shows correct UI (no error state); no flow drift detected | Add `waitForState` / `waitForNetworkIdle` before the interaction; bump a bounded timeout |
| **c. Flow-step drift** | **Propose** | App shows an extra/missing/reordered step between expected actions; screenshot confirms correct page state at each step the app does reach | Present the detected flow diff to the operator; apply on approval |
| **d. Assertion re-baseline** | **Propose** | Hardcoded literal no longer matches; UI state around the assertion is otherwise correct | Present old vs new value to the operator; apply on approval |
| **e. State isolation** | **Auto** | Test passes when run alone, fails when run after specific predecessors (verified empirically) | Add fresh context / storage reset / cleanup hook; re-run in suite order |
| **f. Flake quarantine** | **Report** | Flake persisted after two heal attempts of different strategies; root cause unclear | Tag test `@flaky`, append an entry to the quarantine ledger (see §Quarantine ledger below), add to repair summary with diagnostic notes; do NOT silently skip |
| **g. Whole-test rewrite** | **Operator-aligned** | Flow changed so fundamentally that the scenario no longer maps to the app as-is; no incremental heal applies | Present to operator; on approval, invoke `test-composer` with journey context. Never regenerate without alignment. The rewrite exits through `test-composer` Step 6c's composition judge (`../achilles-protocol/references/test-composition-standards.md` §4). |
| **h. Documented-quirk match — no heal** | **Report** | The observed failure shape exactly matches a documented quirk in `app-context.md` (configuration-dependent option subsets, redirect-vs-popup auth patterns, vendor-aliased options, etc.) **OR** matches a documented app-degradation signal (a degradation-banner copy string from `app-context.md`'s documented-banners list, the documented hanging spinner-sentinel custom element, 5xx in network capture) | Report observed-vs-documented diff; do NOT modify the test. The skip / failure is correct; the regression is in the app or in the documentation. Cross-link the relevant `app-context.md` section in the report. |
| **i. Dependency / framework upgrade** | **Propose** | Stage 3 classified the failure as a **framework / dependency defect**: the failing frames run through a dependency, Stage 0a shows the run resolved an older version than one where the behaviour differs, and the spec + app are both correct | Report the version delta (run's version → target version), cite the changelog / release entry or the passing re-run on the newer version, and propose the bump — a lockfile change, not a spec change. Do NOT edit the test, the waits, or the element repository. Verification is a re-run on the bumped version, and for Entrypoint C the next pipeline run. If the defect is not yet fixed upstream, this becomes a package-level report (see `contributing-to-achilles-protocol`) — still not a test edit. |

**Selection rules** (apply in order, stop at first match):

1. If the observed failure shape exactly matches a documented quirk or app-degradation signal recorded in Stage 0's `app-context.md` read → (h) documented-quirk match → report; do NOT heal.
2. If the failing frames run through a dependency and Stage 0a shows a version delta that accounts for the behaviour → (i) dependency / framework upgrade → propose the bump; do NOT heal the test. **Check this before (3)–(7)** — a framework defect presents as a selector, timing, or state failure, so every one of those rules will happily "match" it and produce a durable workaround for a fixed bug.
3. If screenshot shows wrong UI (500, error page, broken layout, missing-that-should-be-present component) → **app bug**, go to Stage 6. Do not heal.
4. If page-repo lookup failed → (a) selector re-learn → proceed to Stage 4b
5. If timeout on a known-good element with correct surrounding state → (b) timing hardening
6. If pattern hypothesis (from `test-repair` if present) or empirical check says "state leak" → (e) state isolation
7. If live DOM shows step order does not match test sequence → (c) flow drift → propose
8. If assertion failure on a specific literal with otherwise-correct surrounding state → (d) re-baseline → propose
9. If two heal strategies have been attempted and the test still flakes → (f) quarantine
10. If the test scenario no longer maps to the app flow → (g) rewrite → operator-align

The precondition columns exist to keep you honest: any heal applied without meeting its precondition is a guess, and guesses mask bugs.

### Quarantine ledger (heal (f) only)

Heal (f) appends an entry to the quarantine ledger at
`tests/e2e/docs/flake-quarantine.md`. The ledger is **committed, not
gitignored** — quarantine is cross-session state that the next
`test-repair` session must see.

Ledger header (first lines of the file):

```markdown
# Flake quarantine ledger
<!-- Written by failure-diagnosis heal (f); released by test-repair Stage 5.5.
     Out-of-band shell edits are denied by hooks/protected-artifact-bash-guard.sh. -->
```

Entry template (one per quarantined test):

```markdown
### `tests/<file>.spec.ts::<test-name>`
- **Quarantined:** YYYY-MM-DD
- **Failure-shape:** flaky-consistent | flaky-chaotic
- **Heal attempts:** <strategy 1>, <strategy 2> — both destabilized
- **Error signature:** <one-line dominant error when failing>
- **Diagnostic notes:** <what the evidence showed; why root cause is unclear>
- **Observations:** <dated appends from later sessions — e.g. "YYYY-MM-DD: still flaking 1/3 in Stage-1 baseline">
- **Status:** quarantined | unquarantined (YYYY-MM-DD — <evidence: 3/3 baseline + 5/5 suite-order green>)
```

Ownership is write-only and split: **failure-diagnosis writes**
entries (heal (f)); **test-repair releases** them (its Stage 5.5
quarantine review flips `Status:` to `unquarantined` with dated
evidence, or appends a still-flaking observation). No other skill
edits the ledger, and entries are never deleted — a released entry
keeps its history.

### Stage 4b — Live DOM re-learning (for heal strategy (a) only)

When the heal strategy is (a) selector re-learn, do NOT guess a replacement selector. Use `playwright-cli` to open the page at the navigation state where the lookup fails (`npx playwright-cli -s=fd-<short-slug> open --browser=chromium <URL>` followed by whatever `goto` / `click` chain reproduces the failure state), then locate candidates by stable signals.

**When the environment is not reachable from this session** (Entrypoint C against a production or gated pipeline), re-learn from the run's captured DOM instead of skipping the stage: `error-context.md`'s aria page snapshot names every role + accessible name that existed at the moment of failure, and the trace's `frame-snapshot` entries carry the DOM tree. That is enough for signals 1–3 below. It is **not** enough to confirm the new selector resolves — so a repository change learned this way is **Propose**, not Auto: state that it was learned from artifacts, and let the next pipeline run confirm it.

1. **Exact text match** — does the previous selector have known text content? Search the live DOM for an element with the same text.
2. **Role + accessible name fuzzy match** — e.g. previous target was a button labeled "Submit"; find a `role="button"` whose name contains "Submit" (or close variants like "Place Order", "Confirm").
3. **Nearby landmark stability** — previous target was "the button inside the section with heading 'Shipping'"; find the current equivalent via the stable landmark.
4. **Attribute overlap** — shared `data-testid` family, shared class prefix, shared `id` pattern.

**Confidence thresholds:**

- **High confidence** (text match + role match + landmark match all agree) → update `page-repository.json` atomically, run the test immediately to confirm.
- **Multiple competing candidates** → escalate to the operator with the candidate list; do not guess between them.
- **No candidate found** → the element likely genuinely disappeared. Re-classify as either (c) flow drift (something replaced it) or app bug (component missing that should be present) using the screenshot evidence as the tiebreaker.

### Root cause: fragile selector

If triage attributes the failure to a fragile selector (text drift, position-dependent CSS, role/name collision), check workspace shape before selecting a heal strategy:

**Frontend source in workspace** — `package.json` lists the UI framework as a dependency **and** a `src/`-style tree of `.tsx`/`.jsx`/`.vue`/`.svelte`/`.html` files is present:

→ Dispatch `selector-development` (`mode: "jit"`, `scope` = the element-key whose locator failed). After it returns, replace the test's locator with the new test-attribute selector and re-run. Then continue from Stage 5 (stability validation) as normal.

**Frontend source NOT in workspace:**

→ Report the fragile selector to the user as an actionable test-debt item. Do NOT attempt to harden the locator with compound selectors, nth-child chains, or XPath depth — that adds brittleness without adding stability. The report should name the element-key, the fragile signal (text drift / CSS position / role collision), and that `selector-development` cannot help because the source files are not available in this workspace.

---

### Stage 5 — Fix and stability (test issues only)

1. **Apply the fix** per the heal strategy selected in Stage 4a. Use the Steps API correctly — refer to [`../achilles-protocol/references/api-reference.md`](../achilles-protocol/references/api-reference.md) for all method signatures.
2. **If the fix requires new selectors:** Stage 4b has produced the proposal. For Auto strategies the update applies directly; for Propose strategies confirm with the operator first.
3. **Run the test until the stability bar is met** — 3 consecutive green for a fix to a new or edited test; 5 consecutive for a heal of a previously-flaky test (suite order for flaky heals, per `test-repair`). A single pass is not sufficient — flaky tests are worse than failing tests.
   ```bash
   # Run the specific test file repeatedly (5 shown — the flaky-heal bar; 3 suffices for a non-flaky fix)
   for i in {1..5}; do npx playwright test <test-file> --reporter=line; done
   ```
4. **Only commit after all stability runs pass.**
5. **If any stability run fails:** revert the heal, then re-enter the diagnostic pipeline from Stage 1. The heal was incomplete. If a second strategy also destabilizes, escalate to (f) flake quarantine rather than trying a third heal — two failed strategies is a signal that single-failure mode is insufficient for this test.
6. **Entrypoint C — local green is provisional.** When the failure came from a pipeline, local stability runs are necessary but not sufficient: the failure was observed in an environment you did not reproduce. Match the CI conditions as closely as the config allows (same Playwright project / device, same base URL, same viewport env var, same grep filter as the failing job's command line — read it out of `gh run view <run-id> --job <job-id> --log-failed`), and state in the return that final confirmation is the next pipeline run. Do not report the failure as resolved on local evidence alone.
7. **Heal (i) verification is a dependency bump, not a spec run.** Confirm on the bumped version with the spec unchanged; a green run that also carries spec edits proves nothing about the version delta.

### Stage 6 — Report (app bugs only)

Present the bug report to the user with this structure:

> **Application Bug Report**
>
> **Test:** `tests/example.spec.ts` — TC_001: Login flow
> **Step:** "Verify dashboard loads after login"
>
> **Expected:** Dashboard page loads with welcome message and user stats
> **Actual:** Page shows "500 Internal Server Error"
>
> **Screenshot:** <on-disk path, incl. which attempt directory> — <one-line description>
> **Trace:** <trace.zip path, incl. which attempt> — <the failing action and what the page was doing around it>
> **DOM evidence:** <error-context.md or snapshot path>
> **Console:** <app-origin errors, or "none — only third-party blocked-resource notices">
> **Severity:** <per bug-report rubric>
> **Environment:** <base URL + browser/project + viewport>
> **Source run:** <local | run <run-id>, job "<job name>", workflow "<name>", branch <ref>, commit <headSha>, framework <pkg>@<version>>
> **Journey:** j-<slug> (when journey-map.md present)
> **Reproducible:** R1 — confirmed by navigating manually via `playwright-cli` | R2 — artifact-only: <the ≥2 independent observations>; R1 unavailable because <reason>
>
> This is an application bug. The test has NOT been modified.

**Hard rule:** every app-bug report MUST cite at least one on-disk artifact path (screenshot, `trace.zip`, `error-context.md`, snapshot, or capture file). Prose supplements the artifact, never replaces it.

**Hard rule (Entrypoint C):** every pipeline-sourced report MUST carry the `Source run:` provenance line — including the commit the run was built from and the framework version it resolved — and MUST cite downloaded-artifact paths, not workspace paths. A report that cites `test-results/...` from the workspace while diagnosing a CI failure is citing a different execution.

Do NOT modify the test to work around the bug. Do NOT skip the test. Do NOT add try/catch blocks to swallow the error. Report and stop.

---

## Stability Validation Protocol

A fix is confirmed only when it meets the two-number stability bar — **3 consecutive green runs for any new or edited test; 5 consecutive green runs for a heal of a previously-flaky test** (in suite order, per `test-repair`). This section is the canonical home of the bar (resolution record: `../achilles-protocol/references/test-composition-standards.md` §3.3). It catches:
- Race conditions that pass 80% of the time
- Timing-sensitive tests that work on fast machines but fail under load
- State leakage between tests that only manifests on repeated runs

If any run in the stability check fails, the fix is incomplete. Do not commit — re-diagnose.

---

## Integration

### Skills that call this one

| Calling Skill | Activation Point | What Happens Next |
|---|---|---|
| `maintenance` | First step when a test failure is reported | After heal + stability → return for compliance review + commit |
| `authoring` | When a newly written test fails in Stage 3 | After heal + stability → return for compliance review + commit |
| `test-composer` | When a test run produces failures | After heal + stability → return for next scenario |
| `bug-discovery` | When adversarial tests fail | After heal + stability OR bug report → return to caller |
| `test-repair` | Per cluster in its Stage 4 (batch repair pipeline) | Diagnose the cluster's representative, apply heal once for the whole cluster, return outcome (Healed / App bug / Operator-pending / Quarantined) |
| `self-repair` | Per red spec file, inside each `repair-worker-*` worker | Same contract as `test-repair`, one worker per file |
| `achilles-protocol` | A pipeline run went red and the user asks why (Entrypoint C) | Dispatch an `fd-ci-<run-id>:` subagent; it runs Stage 0 → Stage 0a → Stage 0b → the full pipeline and returns the diagnosis with run provenance |

After a successful heal + stability confirmation, control returns to the calling skill.

### Escalating up to test-repair

Sometimes single-failure mode isn't the right shape. Hand off to `test-repair` when the failure is not really a single event:

| Condition | Why escalate |
|---|---|
| The current run has ≥5 failures or ≥30% of executed tests failed | Per-failure diagnosis doesn't scale; batch clustering finds the shared root cause faster |
| You have been invoked 3+ times in this session on distinct tests | The pattern across failures is likely worth detecting before healing more in isolation |
| A heal you applied caused previously-passing tests to start failing | Cross-test interaction is invisible from here; `test-repair`'s post-heal verification stage is designed for it |
| Two different heal strategies on the same test have both destabilized | Before trying a third, bump up to batch mode — the test's behavior may be coupled to sibling tests |
| The pipeline run has ≥5 failing tests or ≥2 red spec files (Entrypoint C) | Same volume rule, read off the run's JSON reporter output. **Complete Stage 0a + Stage 0b first** and hand `test-repair` / `self-repair` the *downloaded artifact directory* and the run's `headSha`, not just the run id — otherwise clustering starts from log lines instead of evidence |

**Announce the escalation once** to the operator and start batch mode:

> Detected <reason> — handing off to the `test-repair` batch pipeline so we can cluster root causes before continuing to heal individually. Reply "stay single-failure" to override.

The operator can override back to single-failure mode if they have a reason to keep the narrower scope.

---

## API Reference

Refer to [`../achilles-protocol/references/api-reference.md`](../achilles-protocol/references/api-reference.md) for all method signatures, argument orders, and types. All Steps methods use `(elementName, pageName)` order.
