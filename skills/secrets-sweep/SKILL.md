---
name: secrets-sweep
description: >
  Extract hardcoded credentials, API keys, PII-shape literals and app URLs
  out of a test suite into `.env`, loaded by an `author` dispatch. The final
  guardrail before a suite is published or treated as portable across
  environments; onboard Phase 7. Returns conform to the composer schema.
---

# Secrets sweep

Earlier phases enforce runtime self-credentialing; this sweep is the drift guard for the literal that landed anyway. Application source is out of scope: a credential found under `src/` or `app/` is reported, never edited.

## What counts

| Class | Examples | Replacement |
|---|---|---|
| Credentials | usernames, passwords, JWT subjects, OAuth client secrets | `process.env.TEST_USER_EMAIL`, … |
| API keys, tokens, cookies | `sk-…`, bearer prefixes, raw 3-segment JWTs | `process.env.STRIPE_API_KEY`, … |
| PII-shape test data | emails or full names that look like real people | `process.env.TEST_USER_EMAIL`; `test@example.com` / `Test User` are acceptable defaults |
| App URLs and ports | `http(s)://…`, `:PORT` | `process.env.APP_URL`, `process.env.APP_PORT` |

## Scope

Two briefs, two scopes, in order:

| Brief | May edit | Does |
|---|---|---|
| scaffold scope | `.env`, `.env.example`, `.gitignore`, root `playwright*.config.ts` | writes the env files and the `dotenv` load; moves config literals (`localhost:3000` included) |
| `tests/**` scope | specs, fixtures, `tests/contracts/**`, `tests/data/**` | rewrites literals to `process.env.<NAME>` using exactly the names in the brief |

Off limits for both: `src/**`, `app/**`, renames, new spec files, `tests/e2e/evidence/**` (bundles are redacted at capture time by `evidence-capture`, never swept here). JSON under `tests/**` (including `page-repository.json`) cannot hold `process.env`: scan it and report literals as `name + file:line`; the orchestrator decides.

## Playbook

a. **List candidates** over `tests/**` and the root configs with these patterns (`-E`):

| Pattern | Catches |
|---|---|
| `password\|secret\|token\|api[_-]?key\|bearer\|sk-[A-Za-z0-9]` | credential and key names |
| `@[a-z0-9._-]+\.(com\|io\|net\|org)` | email addresses |
| `https?://\|:[0-9]{4,5}` | URLs and ports |
| `eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*` | raw JWT |
| `AKIA[0-9A-Z]{16}` | AWS access key id |
| `ghp_[A-Za-z0-9]{36}\|github_pat_[A-Za-z0-9_]{22,}` | GitHub tokens |
| `xox[baprs]-` | Slack tokens |
| `(type\|fill)\(['"].*[Pp]ass.*['"],` | credential-shaped argument to type/fill |

Read each hit and classify. False positives (documentation strings, deliberately public endpoints, the `expect.stringMatching(...)` regex literals in `tests/contracts/schemas.ts`) are skips, listed in the return so the audit shows they were seen.

b. **Pick stable names**: UPPER_SNAKE_CASE, one name per value across files (`APP_URL`, `TEST_USER_EMAIL`, `TEST_USER_PASSWORD`, `STRIPE_API_KEY`, `OAUTH_CLIENT_SECRET`).

c. **Replace in source** with `process.env.<NAME>`; where TypeScript needs a string, a small `env(name)` helper that throws on a missing variable beats `!` assertions.

d. **`.env`** (scaffold brief): real values, gitignored, never committed.

e. **`.env.example`** (scaffold brief): one comment line per variable, clearly non-secret placeholders.

f. **`.gitignore`** (scaffold brief) covers `.env`, `.env.local`, `.env.*.local`.

g. **Re-scan** `tests/**`: every hit is now a `process.env.<NAME>` reference or a noted skip.

h. **Verify** (orchestrator, after both briefs return): `npx playwright test --list`, then the full suite. A failure here usually means `dotenv` is not loaded before the specs.

i. **Second opinion** (optional, orchestrator): `gitleaks` or `detect-secrets` over `tests/` when already on PATH; never installed for this.

j. **Commit** (orchestrator): `chore: extract secrets to .env`.

## Return

Composer schema (`schemas/subagent-returns/composer.schema.json`), envelope first. `covered-exhaustively` when literals were rewritten and the re-scan is clean; `new-tests-landed` when a regression fixture was authored; `skipped` with the verification line when the suite was already clean; `blocked` with `blocked-reason` naming every un-extracted finding (unrecognisable project structure, or a literal in application source). `summary` names the variables used and the file count. Values are never echoed.

## Common mistakes

Editing application source; forgetting `.env.local`; leaving `localhost:3000` in the config (it belongs to the scaffold brief); replacing `test@example.com` with another placeholder; touching clean specs.
