# Stage 0a and 0b: pipeline evidence for Entrypoint C

## Stage 0a — Pin to the run's commit and dependency tree (Entrypoint C — mandatory)

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

## Stage 0b — Pipeline evidence retrieval (Entrypoint C — mandatory)

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
