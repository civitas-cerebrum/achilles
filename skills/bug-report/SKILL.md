---
name: bug-report
description: Use when a defect, issue, or unexpected behavior is found during testing and needs to be reported in a defect tracking system (Jira). Use when asked to write, create, or file a bug ticket, defect report, or issue report. Loaded by a `doc-writer` dispatch; fields only the user knows come back as `NEEDS_CONTEXT`.
---

# Bug Report

A structured bug report gives developers everything they need to reproduce and fix a defect without follow-up questions. The quality of the report decides how quickly the issue gets resolved.

## Engine

### Step 1: extract before listing a field as missing

Read everything the brief and its evidence already carry before naming any field as open:

| What the brief gives | What to extract |
|---|---|
| Screenshot / GIF | Visible failure state, element involved, error message shown |
| Screen recording | Exact step where failure occurs, UI state before and after |
| Console / crash log | Uncaught exceptions, 4xx/5xx responses, error text verbatim |
| Test output / assertion | Failing assertion message word-for-word → becomes Actual result |
| Written description, finding block, reproduction spec | Flow being tested, what was expected, what happened, the traceability fields |

### Step 2: pre-fill the template

| Template field | How to populate |
|---|---|
| Summary | Location + short failure phrase, factual and searchable |
| Description | Synthesise observations; include error messages verbatim |
| Environment | Exact URL or environment name |
| Device/Browser | Model + OS version + browser name + browser version |
| Steps to Reproduce | Number from app launch or page load; reconstruct from evidence |
| Expected result | Correct intended behaviour only, never mixed with actual |
| Actual result | Quote error messages verbatim; reference specific file names |
| Attachments | List every evidence file by name |
| Severity | Suggest from the rules below |
| Priority | Pre-fill from the bug-discovery `f(severity, journey tier)` matrix suggestion when handed over; otherwise leave open |
| Build/Commit | The build identifier or commit SHA the bug was observed against |
| Finding ID | The canonical bug-discovery FINDING-ID (`<journey-slug>-<nn>` / `<journey-slug>-<pass>-<nn>`), or `n/a` if the report did not originate from bug-discovery |
| Reproduction test | Spec path › test name that reproduces it, or `none` |
| Journey | `j-<slug>` plus its priority tier, or `n/a` |

**Severity suggestion rules:**
- Uncaught exception, data loss, security issue, core feature fully blocked → suggest **Critical**
- Important feature broken, no workaround → suggest **High**
- Feature works incorrectly but workaround exists → suggest **Medium**
- Visual/cosmetic issue, no functional impact → suggest **Low**

### Step 3: return the pre-filled ticket for confirmation

Return `NEEDS_CONTEXT` with the complete filled ticket and one numbered list: every field still missing, the suggested Severity and Priority, and "confirm or correct any field". All open items go in that one list; never one field per round. The final ticket is produced on the re-dispatch that carries the answers; corrections are incorporated silently. A brief that pre-authorised filing (every field supplied, severity and priority confirmed) skips this step.

### Hard rules

- **Never paste plaintext secrets into a ticket.** Test-account passwords, API keys, tokens, or any credential value never go into a ticket body, attachment, or comment. Reference the credential store or the `.env` key name instead (e.g. `STAGING_QA_USER` / `STAGING_QA_PASSWORD` from `.env`), the `secrets-sweep` convention: credentials live in `.env` or the secret store, and only their key names travel.
- **Never fabricate evidence.** Only list attachments that exist.
- **Quote error messages verbatim.** Never paraphrase what the system said.
- **Console errors belong in the ticket body**, in Description or Actual result, not only in Attachments.
- **Severity and Priority are suggestions until confirmed** through the `NEEDS_CONTEXT` round; never assigned silently.
- **Never skip the confirmation round** unless the brief carries the confirmed values.
- Write in **third person** ("the user", "they"); assume the reader has zero prior knowledge of the project; fill every available field; attach evidence at the **end** of the ticket.

## Template

```
Summary: [Location] - [Concise description of the issue]

Description:
[Detailed description in third person. Describe what the user observes and under what conditions.]

Environment: [Test environment name/URL]

Device/Browser: [Device model (OS version) + Browser name and version]

Test account: [credential-store reference or .env key name, e.g. STAGING_QA_USER / STAGING_QA_PASSWORD (.env) — never paste secret values into tickets]

Steps to Reproduce:
1. [Start from the very beginning — launching app or loading URL]
2. ...
3. ...
4. Observe [what happens]

Expected result:
[Clear, specific description of the correct intended behavior.]

Actual result:
[Exactly what happens — visible errors, missing elements, unresponsive actions.]

Attachments:
[Screenshots, screen recordings, GIFs, console/crash logs]

Severity: [Critical / High / Medium / Low]
Priority: [Highest / High / Medium / Low]

Traceability:
Finding ID: [canonical bug-discovery FINDING-ID, e.g. j-login-03 / j-login-4-03 — or n/a]
Journey: [j-<slug> + tier, e.g. j-login (P0) — or n/a]
Build/Commit: [build identifier or commit SHA observed against]
Reproduction test: [spec path › test name — or none]
```

## Field-by-field guide

### Summary
Format: `Location - Description`: where the issue appears ("Login Page", "Burger Menu", "Checkout Flow") plus a clear, searchable phrase in as few words as possible.

```
✅ Login - Login button unresponsive on mobile Safari browser
✅ PDP - Add to Bag button missing on iOS 17 Chrome
❌ bug with button
```

### Description
Third person; what the user observes and under what conditions.

```
✅ When the user attempts to login using the Safari browser, the login button is unresponsive.
❌ I clicked the button and nothing happened.
```

### Steps to Reproduce
Start from zero, as if opening the app for the first time: open the browser on the device, navigate to the URL, each action, then "Observe that …".

### Expected result
The **correct intended behaviour** only, in objective, testable language ("The user is logged in and redirected to the homepage"), never "it should work correctly".

### Actual result
**Exactly** what happened, facts only ("The 'Login' button is unresponsive. No action occurs after tapping."), never "it's weird and broken".

### Severity versus Priority

| | Severity | Priority |
|---|---|---|
| **Definition** | How badly the bug breaks the system | How urgently it needs to be fixed |
| **Question** | "How bad is this?" | "How soon?" |

| Severity level | When to use |
|---|---|
| **Critical** | System crash, data loss, security issue, core feature completely blocked |
| **High** | Important feature broken, no workaround available |
| **Medium** | Feature works incorrectly but workaround exists |
| **Low** | Minor UI/cosmetic issue, no functional impact |

A bug can have **High severity** but **Low priority** (rare crash in an unused area), or **Low severity** but **High priority** (typo on the homepage during a marketing campaign). A report handed over from `bug-discovery` arrives with Priority pre-filled from that skill's `f(severity, journey tier)` matrix; present it as the suggestion, exactly as with Severity.

### Test account
Reference the credential, never the value: the credential store or the `.env` key name (`STAGING_QA_USER / STAGING_QA_PASSWORD (.env)`, `vault://qa/staging/login`). A developer reproducing the bug looks the secret up from the named source.

### Traceability
Four fields that link the ticket back to its origin so it can be deduplicated, regression-checked, and closed against the right build. Use `n/a` / `none` when a field is missing: a missing field is better than a guessed one.

- **Finding ID**: the canonical bug-discovery FINDING-ID (`<journey-slug>-<nn>` standalone, `<journey-slug>-<pass>-<nn>` from coverage expansion). `n/a` if the report did not come from bug-discovery. Never invent a `BUG-NNN`.
- **Journey**: `j-<slug>` plus its priority tier (`P0`–`P3`), or `n/a`.
- **Build/Commit**: the build identifier or commit SHA the bug was observed against; without it, regression-versus-new is unanswerable.
- **Reproduction test**: `spec-path › test name`, or `none`.

### Attachments
Always include evidence, at the **end** of the ticket: a screenshot for UI issues and error messages (annotated with a red box or arrow), a screen recording or GIF for interaction flows, a console or crash log for any functional or technical issue.
