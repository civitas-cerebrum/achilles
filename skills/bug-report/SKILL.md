---
name: bug-report
description: Use when a defect, issue, or unexpected behavior is found during testing and needs to be reported in a defect tracking system (Jira). Use when asked to write, create, or file a bug ticket, defect report, or issue report.
---

# Bug Report

## Overview

A structured bug report gives developers everything they need to reproduce and fix a defect without follow-up questions. Quality of the report directly impacts how quickly the issue gets resolved.

## Engine — How to Build a Strong Bug Report

### Step 1: Extract before asking

Before prompting the user for any field, read everything already provided:

| What the user gives | What to extract |
|---|---|
| Screenshot / GIF | Visible failure state, element involved, error message shown |
| Screen recording | Exact step where failure occurs, UI state before and after |
| Console / crash log | Uncaught exceptions, 4xx/5xx responses, error text verbatim |
| Test output / assertion | Failing assertion message word-for-word → becomes Actual result |
| Written description | Flow being tested, what was expected, what happened |

Extract everything available first. Only ask for what is genuinely missing.

---

### Step 2: Gather missing fields in one message

Ask for all missing items in a single message — never one field at a time.

| Field | Required |
|---|---|
| What broke and where | ✅ |
| Environment URL | ✅ |
| Device + browser + OS version | ✅ |
| Steps to reproduce | ✅ |
| Expected vs actual result | ✅ |
| Evidence files (screenshots, video, logs) | ✅ |
| Credential reference (never the secret itself) | Optional — only if login is required to reproduce |
| Severity / Priority | ✅ — offer the Severity vs Priority table to help |

---

### Step 3: Pre-fill the template

| Template field | How to populate |
|---|---|
| Summary | Location + short failure phrase — factual, searchable |
| Description | Synthesise observations; include error messages verbatim |
| Environment | Exact URL or environment name |
| Device/Browser | Model + OS version + browser name + browser version |
| Steps to Reproduce | Number from app launch or page load; reconstruct from evidence |
| Expected result | Correct intended behaviour only — never mixed with actual |
| Actual result | Quote error messages verbatim; reference specific file names |
| Attachments | List every evidence file by name |
| Severity | Suggest using the rules below; user confirms |
| Priority | Pre-fill from the bug-discovery `f(severity, journey tier)` matrix suggestion when handed over; otherwise ask. User always confirms. |
| Build/Commit | The build identifier or commit SHA the bug was observed against |
| Finding ID | The canonical bug-discovery FINDING-ID (`<journey-slug>-<nn>` / `<journey-slug>-<pass>-<nn>`), or `n/a` if the report did not originate from bug-discovery |
| Reproduction test | Spec path › test name that reproduces it, or `none` |
| Journey | `j-<slug>` plus its priority tier, or `n/a` |

**Severity suggestion rules:**
- Uncaught exception, data loss, security issue, core feature fully blocked → suggest **Critical**
- Important feature broken, no workaround → suggest **High**
- Feature works incorrectly but workaround exists → suggest **Medium**
- Visual/cosmetic issue, no functional impact → suggest **Low**

Always present as a suggestion. The user confirms.

---

### Step 4: Show the pre-filled ticket and wait for confirmation

Print the complete filled ticket and ask:
> "Does this look accurate? Confirm or correct any field before I finalise."

Do not output the final ticket until the user explicitly confirms. Incorporate corrections silently, then print the final version.

---

### Engine hard rules

- **Never paste plaintext secrets into a ticket.** Test-account passwords, API keys, tokens, or any credential value never go into a ticket body, attachment, or comment. Reference the credential store or the `.env` key name instead (e.g. `STAGING_QA_USER` / `STAGING_QA_PASSWORD` from `.env`). This mirrors the `secrets-sweep` convention — credentials live in `.env`/the secret store, and only their key names travel. A ticket that needs a login points the developer at the named credential, never the value.
- **Never fabricate evidence.** Only list attachments that actually exist.
- **Quote error messages verbatim.** Never paraphrase what the system said.
- **Console errors belong in the ticket body.** Relevant errors go into Description or Actual result — not only in Attachments.
- **Severity and Priority always require user confirmation.** Never assign them silently.
- **Never skip the confirmation step.** Pre-filling does not mean the ticket is correct. The engineer signs off first.

---

## Key Rules

- Write in **third person** — use "the user", "they", "them". Never "I" or "me".
- Assume the reader has **zero prior knowledge** of the project.
- Include **more detail than seems necessary**.
- Fill in **every available field**.
- Attach evidence (screenshot, video, console log) at the **end** of the ticket.

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

## Field-by-Field Guide

### Summary
Format: `Location - Description`
- **Location**: Where the issue appears (e.g., "Login Page", "Burger Menu", "Checkout Flow")
- **Description**: Clear, searchable phrase in as few words as possible

```
✅ Login - Login button unresponsive on mobile Safari browser
✅ PDP - Add to Bag button missing on iOS 17 Chrome
❌ bug with button
❌ something is broken on the page
```

### Description
Describe the defect in third person. Explain what the user observes and under what conditions it occurs.

```
✅ When the user attempts to login using the Safari browser, the login button is unresponsive.
✅ When adding the Hero Component in AEM and accessing Preview Mode, the component is not displayed.
❌ I clicked the button and nothing happened.
```

### Steps to Reproduce
Start from zero — assume the user is opening the app for the first time.

```
1. Open Safari on iPhone 13 Pro.
2. Navigate to [URL].
3. Enter valid credentials in the login form.
4. Tap the "Login" button.
5. Observe that nothing happens.
```

### Expected Result
Describe the **correct intended behavior** only. Do not mix with actual result. Use objective, testable language.

```
✅ The user is successfully logged in and redirected to the homepage.
✅ A success toast 'Profile updated' is displayed.
❌ It should work correctly.
❌ The button should look nice and respond fast.
```

### Actual Result
Describe **exactly** what happened. Stick to facts.

```
✅ The "Login" button is unresponsive. No action occurs after tapping.
✅ Error message 'Invalid token' appears after entering a valid OTP.
✅ No confirmation message is displayed after submitting the form.
❌ It's weird and broken.
❌ I think the button didn't work.
```

### Severity vs Priority

| | Severity | Priority |
|---|---|---|
| **Definition** | How badly the bug breaks the system | How urgently it needs to be fixed |
| **Question** | "How bad is this?" | "How soon?" |

| Severity Level | When to use |
|---|---|
| **Critical** | System crash, data loss, security issue, core feature completely blocked |
| **High** | Important feature broken, no workaround available |
| **Medium** | Feature works incorrectly but workaround exists |
| **Low** | Minor UI/cosmetic issue, no functional impact |

> A bug can have **High severity** but **Low priority** (rare crash in unused area), or **Low severity** but **High priority** (typo on homepage during marketing campaign).

When the report is handed over from `bug-discovery`, **Priority arrives pre-filled** from that skill's `f(severity, journey tier)` matrix suggestion — present it as the suggestion and let the user confirm, exactly as with Severity.

### Test Account
Reference the credential, never the value. Point at the credential store or the `.env` key name (e.g. `STAGING_QA_USER` / `STAGING_QA_PASSWORD`). A developer reproducing the bug looks the secret up from the named source — it never appears in the ticket. (See the Engine hard rule on plaintext secrets.)

```
✅ Test account: STAGING_QA_USER / STAGING_QA_PASSWORD (.env)
✅ Test account: vault://qa/staging/login (credential store)
❌ Email: test@example.com  Password: 123!Password
```

### Traceability
Four fields that link the ticket back to its origin so it can be deduplicated, regression-checked, and closed against the right build. Use `n/a` / `none` honestly — a missing field is better than a guessed one.

- **Finding ID**: the canonical bug-discovery FINDING-ID (`<journey-slug>-<nn>` standalone, `<journey-slug>-<pass>-<nn>` from coverage-expansion). `n/a` if the report did not come from bug-discovery. Never invent a `BUG-NNN`.
- **Journey**: `j-<slug>` plus its priority tier (`P0`–`P3`), or `n/a`.
- **Build/Commit**: the build identifier or commit SHA the bug was observed against — without it, regression-vs-new is unanswerable.
- **Reproduction test**: `spec-path › test name`, or `none`.

### Attachments
Always include evidence. Place attachments **at the end** of the ticket.

| Type | When to use |
|---|---|
| Screenshot | UI issues, error messages — annotate with red box/arrow |
| Screen recording | Interaction flows, reproducible steps |
| GIF | Short focused clip — mid-point between video and image |
| Console/crash log | Any functional or technical issue |

## Quick Reference

| Field | Required | Notes |
|---|---|---|
| Summary | ✅ | Location - short description |
| Description | ✅ | Third person, full context |
| Environment | ✅ | URL or env name |
| Device/Browser | ✅ | Include versions |
| Steps to Reproduce | ✅ | Start from zero |
| Expected Result | ✅ | Intended correct behavior only |
| Actual Result | ✅ | Facts only, no opinions |
| Attachments | ✅ | At end of ticket |
| Severity | ✅ | Critical/High/Medium/Low |
| Priority | ✅ | Highest/High/Medium/Low — pre-filled from the bug-discovery matrix when handed over |
| Test account | Optional | Credential-store reference or `.env` key name only — never the secret value |
| Finding ID | Optional | Canonical bug-discovery FINDING-ID, or `n/a` |
| Journey | Optional | `j-<slug>` + tier, or `n/a` |
| Build/Commit | ✅ | Build id or commit SHA observed against |
| Reproduction test | Optional | Spec path › test name, or `none` |

## Example

```
Summary: Login - Login button unresponsive on mobile Safari browser

Description:
When the user attempts to login when using the Safari browser, the button is unresponsive.

Environment: https://staging.example.com

Device/Browser: iPhone 13 Pro (iOS 18.1) Safari

Test account: STAGING_QA_USER / STAGING_QA_PASSWORD (.env)

Steps to Reproduce:
1. Open Safari on iPhone 13 Pro.
2. Navigate to the login page.
3. Enter valid credentials in the email and password fields.
4. Tap the "Login" button.
5. Observe that nothing happens.

Expected result:
The user is successfully logged in and redirected to the homepage.

Actual result:
The "Login" button is unresponsive. No action occurs after tapping.

Attachments:
- screenshot_login_unresponsive.png (annotated with red arrow on button)
- screen_recording_login_issue.mp4

Severity: High
Priority: High

Traceability:
Finding ID: j-login-03
Journey: j-login (P0)
Build/Commit: a1b9f3c
Reproduction test: tests/e2e/j-login-regression.spec.ts › login button unresponsive on mobile Safari
```

## Common Mistakes

| Mistake | Fix |
|---|---|
| First person ("I clicked…") | Third person ("The user taps…") |
| Vague actual result ("it's broken") | Specific behavior ("button does not respond, no error shown") |
| Missing device/OS version | Always include model, OS version, browser version |
| Steps skip preconditions | Start from app launch or page load |
| Attachment placed mid-ticket | Move all attachments to the end |
| Expected result mixed with actual | Keep them strictly separate |
| Subjective language ("looks weird") | Objective facts only |
| Plaintext password/key in the ticket | Reference the credential store or `.env` key name; never the secret value |
| Missing build/commit or finding ID | Always record traceability — without it, regression-vs-new and dedup are impossible |
