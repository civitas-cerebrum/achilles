---
name: secrets-sweep
description: >
  Phase-7 methodology for extracting hardcoded credentials, API keys,
  PII-shape literals, and app URLs out of a test suite into `.env`. Use
  this skill as the final guardrail before publishing a test suite or
  treating it as portable across environments. Returns conform to the
  ComposerReturn schema.
---

> **Activation banner:** The first user-facing reply after this skill loads MUST begin with the line: **Protocol Achilles activated.** Once per session — skip if already declared in this conversation. Subagents (which return structured data, not user-facing text) are exempt.


# Secrets sweep — Phase 7

The purpose of this skill is to ensure the test suite is free of hardcoded
sensitive literals before it leaves the developer's workstation. Earlier
phases enforce *runtime self-credentialing* (Phase 2's fixture mints test
users at runtime) — this phase is the **drift guard**. Even with good
discipline upstream, a literal sometimes lands in a spec. The sweep finds
and removes it.

This skill does **not** sanitise the application under test. Application
source code is out of scope. Phase 7 is two dispatches, in order:

0. The orchestrator scans `tests/**` and the root configs itself
   (steps a-b) and builds `NAME=value` pairs.
1. `scaffolder-phase7:` brief carries the pairs. It writes `.env`,
   `.env.example`, the `.gitignore` entry and the `dotenv` load in
   `playwright*.config.ts`, and rewrites config literals (steps d-f,
   and any `localhost:3000` in a config) to `process.env.<NAME>`.
2. `secrets-sweep-phase7:` brief carries `NAME (one-word role label)`
   pairs, e.g. `TEST_USER_EMAIL (login email)`: "use exactly these
   names as `process.env.<NAME>`". It edits only
   `tests/**` (steps c, g). It cannot read `.env` or run anything.
3. The orchestrator runs steps h-j.

---

## What counts as a "secret"

Four literal classes. Each has a different remediation pattern.

| Class | Examples | Replacement |
|---|---|---|
| **Credentials** | usernames, passwords, JWT subjects, OAuth client secrets | `process.env.TEST_USER_EMAIL`, etc. |
| **API keys / tokens / cookies** | strings shaped like `sk-…`, bearer prefixes, raw 3-segment JWTs | `process.env.STRIPE_API_KEY`, etc. |
| **PII-shape test data** | email addresses or full names that look like real people | `process.env.TEST_USER_EMAIL` (default to `test@example.com` and `Test User`) |
| **App URLs / ports** | `http(s)://…` literals, `:PORT` literals | `process.env.APP_URL`, `process.env.APP_PORT` |

The convention `test@example.com` / `Test User` is acceptable as a default
placeholder. Anything resembling a real human's email or name should be
parameterised.

---

## Scope rules — what to touch

Strict allow-list. Everything else is off-limits.

| Role | Touchable | Off-limits |
|---|---|---|
| `secrets-sweep-phase7` | `tests/**` (specs, fixtures, `tests/contracts/**` incl. `schemas.ts`, `tests/data/**`). JSON under `tests/**` (incl. `page-repository.json`) cannot hold `process.env.*`: scan it and REPORT literals as name + `file:line`, do not rewrite; env-dependent JSON values are the orchestrator's decision | `src/**`, `app/**`, renames, new spec files, `tests/e2e/evidence/**` (see below), every file outside `tests/**` |
| `scaffolder-phase7` only | `.env`, `.env.example`, `.gitignore`, root `playwright*.config.ts` (incl. `playwright.contracts.config.ts`) | everything else |

If you find a credential hard-coded in application source, **flag it in
the summary** rather than editing the application code. The application
team owns that remediation.

**Evidence bundles are not swept.** `tests/e2e/evidence/` bundles
(screenshots, HARs, traces) are covered by `companion-mode`'s Phase-5
redaction step at bundle-write time, not by this sweep. Do not grep or
edit them here.

---

## Playbook

Work the playbook in order. Each step has a verification.

### a. List candidates

No shell anywhere in this phase: scans use the Grep tool with these
regexes (`-E`).

| Pattern | Catches |
|---|---|
| `password\|secret\|token\|api[_-]?key\|bearer\|sk-[A-Za-z0-9]` | credential and key names |
| `@[a-z0-9._-]+\.(com\|io\|net\|org)` | email addresses |
| `https?://\|:[0-9]{4,5}` | URLs and ports |
| `eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*` | raw 3-segment JWT |
| `AKIA[0-9A-Z]{16}` | AWS access key id |
| `ghp_[A-Za-z0-9]{36}\|github_pat_[A-Za-z0-9_]{22,}` | GitHub tokens |
| `xox[baprs]-` | Slack tokens |
| `(type\|fill)\(['"].*[Pp]ass.*['"],` | credential-shaped argument to type/fill |

| Scanner | Paths |
|---|---|
| Orchestrator (step 0, exit re-scan) | `tests/**` and root `playwright*.config.ts` |
| `secrets-sweep-phase7` (steps a, g) | `tests/**` |

Read each hit and decide which class it belongs to. False positives
(documentation strings, deliberately-public test endpoints) are fine to
skip — note them in the summary so reviewers see the audit covered them.
A standing example: the `expect.stringMatching(...)` regex literals in
`tests/contracts/schemas.ts` (email shapes, ISO-date shapes) are
deliberate non-secrets — note them as skips, don't extract them.

### b. Pick stable env-var names

UPPER_SNAKE_CASE. Reuse the same name across files when the value is the
same. Conventional names:

| Concept | Suggested env var |
|---|---|
| Local app URL | `APP_URL` |
| Test user email | `TEST_USER_EMAIL` |
| Test user password | `TEST_USER_PASSWORD` |
| Stripe API key | `STRIPE_API_KEY` |
| OAuth client secret | `OAUTH_CLIENT_SECRET` |

### c. Replace literals in source

For each finding, replace the literal with `process.env.<NAME>`. If
TypeScript demands a non-null assertion (`process.env` is typed
`string | undefined`), use `process.env.<NAME>!` or a small helper:

```ts
function env(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing required env var: ${name}`);
  return v;
}
```

### d. Write `.env` (real values, gitignored)

Scaffolder, not the sweep.

```
# .env  — local values, NEVER commit
APP_URL=http://localhost:3000
TEST_USER_EMAIL=test@example.com
TEST_USER_PASSWORD=correct-horse-battery-staple
STRIPE_API_KEY=sk_test_…
```

### e. Write `.env.example` (placeholders, committed)

Scaffolder, not the sweep.

One comment line per variable describing what it's for. Use a clearly
non-secret placeholder.

```
# .env.example  — committed; copy to .env and fill in
# Where the dev server is reachable
APP_URL=http://localhost:3000

# Test-only login (created by the runtime self-credentialing fixture)
TEST_USER_EMAIL=your-test-user@example.com
TEST_USER_PASSWORD=<choose a strong placeholder>

# Stripe sandbox key — see https://stripe.com/docs/keys
STRIPE_API_KEY=sk_test_REPLACE_ME
```

### f. Ensure `.gitignore` covers `.env`

Scaffolder, not the sweep.

The file must contain at minimum:

```
.env
.env.local
.env.*.local
```

If only `.env` is present, add the two `.local` variants while you're
there — they're the standard Next.js / Vite / Astro overrides and
forgetting them is a common foot-gun.

### g. Re-scan

Re-run the step (a) patterns over `tests/**`. All hits should now be either
`process.env.<NAME>` references or deliberate skips you noted in step
(a).

### h. Verify

The `secrets-sweep` role has no shell; return after the re-scan. The
orchestrator runs, after the sweep returns:

```bash
npx playwright test --list           # specs still parse + enumerate
npx playwright test --reporter=line  # full suite still passes
```

A failing suite at this point usually means an env var didn't get loaded
— check that `dotenv` (or the test harness's equivalent) runs before
the specs.

### i. Second opinion (optional, orchestrator only)

If `gitleaks` or `detect-secrets` is on PATH, run it over `tests/` as a
second opinion and reconcile its hits against your skip notes from step
(a). Do not install either tool for this — the grep playbook remains the
no-dependency floor; the scanner only adds confidence when it happens to
be available.

### j. Stage and commit (orchestrator only, after the sweep returns)

```
chore: extract secrets to .env
```

If the workflow is driven by an external automated orchestrator, that
orchestrator may commit on your behalf — in that case just stage the
changes.

---

## Return shape

This skill's subagent returns conform to the `composer` schema (see
`schemas/subagent-returns/composer.schema.json`). `onboarding` dispatches
this skill (after `scaffolder-phase7:`) with the `secrets-sweep-phase7:` description prefix
(`subagent_type: secrets-sweep`; grammar: [roles-and-dispatch.md](../achilles-protocol/references/roles-and-dispatch.md) §"Dispatch grammar"), so returns are schema-validated against
`composer.schema.json` with zero hook change.

Every return MUST open with a `handover` envelope as its first key:

| Field | Rule |
|---|---|
| `role` | Kebab-case slug: `secrets-sweep`. |
| `cycle` | Integer ≥ 1. |
| `status` | Status words: [ledger-vocabulary.md](../achilles-protocol/references/ledger-vocabulary.md) §"Subagent returns". |
| `next-action` | One-line directive for the orchestrator. |

**Worked example — `covered-exhaustively`:**

```json
{
  "handover": {
    "role": "secrets-sweep",
    "cycle": 1,
    "status": "covered-exhaustively",
    "next-action": "orchestrator to record Phase-7 completion in the onboarding ledger"
  },
  "tests-added": 0,
  "summary": "Rewrote literals to APP_URL, TEST_USER_EMAIL, TEST_USER_PASSWORD, STRIPE_API_KEY; 7 files modified; re-scan clean (2 noted skips)."
}
```

Per status:

- `new-tests-landed` — when `tests-added > 0` because a regression
  fixture was authored as part of the sweep.
- `covered-exhaustively` — the typical happy path: literals were
  rewritten and the re-scan is clean, no new specs needed.
- `skipped` — when there is nothing to extract (suite was already
  clean). Provide a `skip-authorisation` line explaining how you
  verified.
- `blocked` — when the project structure is unrecognisable (no
  `tests/` directory, no `package.json`, etc.) or a literal lives
  in *application source* (which is out of scope for this skill);
  `blocked-reason` MUST name the un-extracted findings so the human
  can route them.

`summary` must include the env var names used and the count of
files modified.

---

## Common mistakes

- **Editing application source.** Out of scope. Flag and report only.
- **Forgetting `.env.local`.** Some frameworks read `.env.local` first;
  leaving it un-gitignored leaks secrets via local overrides.
- **Hardcoded `localhost:3000` left in `playwright.config.ts`.** Put it
  in the `scaffolder-phase7:` brief — extract to `APP_URL` so CI can
  point at staging. The sweep cannot write configs.
- **Removing `test@example.com`.** That's the *acceptable* default —
  don't replace a perfectly-fine placeholder with another placeholder.
- **Touching specs that don't have literals.** If a spec is clean,
  leave it alone.
