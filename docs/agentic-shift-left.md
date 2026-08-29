# Agentic Shift-Left: A Doctrine for Autonomous Quality Assurance

> Development is agentic. Quality assurance must be too.

When features ship at agent speed — scaffolded, iterated, and merged in a single session — manual testing becomes the bottleneck that nullifies every upstream acceleration. The traditional shift-left response (write tests earlier) is necessary but insufficient: it shifts the *work* left without shifting the *worker*. Agentic shift-left shifts both.

This document describes the methodology implemented by [`@civitas-cerebrum/achilles`](https://www.npmjs.com/package/@civitas-cerebrum/achilles) and [`@civitas-cerebrum/element-interactions`](https://www.npmjs.com/package/@civitas-cerebrum/element-interactions) — two open-source npm packages that together give an AI coding agent the architectural foundation, the QA methodology, and the harness enforcement to autonomously verify a web application.

---

## I. The Architectural Foundation

### Separation of Concerns

A test that hard-codes CSS selectors is a test that breaks when a class name changes. An agent that writes tests with hard-coded selectors produces a suite that rots faster than it grows.

The foundation is a **three-layer separation**:

| Layer | Owns | Changes when |
|---|---|---|
| **Test code** | Business intent — what the user does and what should happen | A requirement changes |
| **Steps API** | Interaction mechanics — how to click, type, wait, scroll, retry | The framework evolves |
| **Page repository** | Selectors — where each element lives in the DOM | The UI is redesigned |

When a frontend redesign changes every `data-testid` in the application, zero test files change. When the framework adds a new stability mechanism, zero test files change. Each layer is the single source of truth for its concern.

This separation is what makes agent-authored tests viable. The agent writes business-intent test code in plain English; the framework handles the stability engineering underneath.

### Tests Anyone Can Read

```
await steps.on('addToCartButton', 'ProductPage').click()
await steps.on('cartCount', 'CartDrawer').expectText('1')
```

The Steps API is the interface between human intent and automated verification. A product owner can read the test above and know what it checks. An agent can write it without knowing how click-interception retry works under the hood.

The framework manages:
- **Stability** — auto-wait visibility, `scrollIntoView`, click-interception detection with classified retry and `dispatchEvent` fallback
- **Logging** — zero log lines written in project test code; the `debug` library with `tester:*` namespaces produces aligned, timestamped output automatically
- **Selectors** — resolved at runtime from the page repository; tests never import or reference a CSS selector

### Open Source

Both packages are public on npm. The methodology ships inside `node_modules` — not in a wiki, not in a Confluence page, not in a prompt that drifts with every session. When you `npm install @civitas-cerebrum/achilles`, the agent picks up the skills, the hooks register themselves, and the harness is live. Version-pinned, auditable, reproducible.

---

## II. The Agentic Shift-Left Lifecycle

Four stages. A human starts it, agents do the heavy lifting, a human confirms the result, and agents guard it going forward.

### Stage 1 — Triage (Human)

**What matters enough to test?**

A human reads the ticket, the PR, or the feature brief and makes the CX/revenue call: does this change affect something a customer would notice? Is there revenue at risk if it breaks?

This is the one decision the methodology refuses to automate. An agent can assess technical risk (code complexity, blast radius, dependency count), but the question *"will a customer care?"* requires business context that lives outside the codebase.

The output of triage is a ticket with a clear scope and a priority: test this, verify that, cover these flows.

### Stage 2 — Automate (Autonomous)

**Sub-agents own the work.**

The methodology decomposes test automation into roles that can be independently dispatched, each with isolated context and a schema-validated return contract:

| Role | Responsibility |
|---|---|
| **Discover** | Crawl the application, map pages and user journeys, prioritise by business impact |
| **Inspect** | Drive a real browser, interact with the live DOM, understand what each element does before writing a locator |
| **Compose** | Write the test — happy path, error states, edge cases, mobile variants, data lifecycle. Every state-changing step verified by an API or database oracle, not a UI toast |
| **Review** | Fresh-context adversarial review of the composed test. Dual-stage: composer and reviewer never share context, so the reviewer catches what the composer's familiarity blinds it to |

Each journey runs through composer → reviewer cycles (up to seven) until the reviewer approves or surfaces a structural blocker. Independent journeys are dispatched in parallel.

### Stage 3 — Confirm (Human + Harness)

**The tests get tested.**

Two mechanisms, both harness-enforced — not advisory, not "best practice," but physically gated by hooks that block sign-off without evidence:

**Negative control.** Every test must be proven to fail where the fix is absent. If the test passes both with and without the change, it proves nothing. The harness blocks QA sign-off until negative control evidence exists.

**Adversarial review.** Before any ticket can be transitioned to a completed state, the methodology dispatches adversarial probes against the tests themselves: Do the assertions actually verify the acceptance criteria? Are there false-positive paths? Could a mutation survive? The harness gate (`adversarial-verification-gate`) blocks the transition until the review receipt exists and is newer than the most recently edited spec.

The human's role at this stage is larger than confirming a verdict. **Coverage is a human responsibility**: the QA engineer — together with product owners and developers — owns the answer to "is every critical component of the business tested against every significant point of failure that carries CX or revenue impact?" The agent verifies what is covered and proves its tests bite; the test engineer is accountable for what *must* be covered. Reading the adversarial findings, judging the result, and closing coverage gaps the machine cannot know matter — that is the human contribution the automation cannot replace.

### Stage 4 — Guard / Heal (Autonomous)

**Gated releases, layered verification.**

Once tests are committed, the methodology prescribes a layered, gate-first test architecture:

- **Regression suites** run in the go-live pipeline, during the build, against an environment that faithfully represents production **without** production connections to critical systems (production database, payment providers, live third-party integrations). A regression failure **stops the release** — regression is a gate, not an alarm. Failures additionally surface via alerting integrations (chat webhooks, email, SMS).
- **Smoke tests** target individual features, pages, and components, and run on **every pull request**. They sit on top of the quicker, more primitive unit tests, and are free to use data mocking or consume the API directly to reach the surface under test fast — speed is their contract.
- **E2E tests** verify complete user journeys, and every step happens in the browser: their intention is to replicate the user's experience as closely as possible, so no step of an e2e journey is shortcut through an API.
- **Self-repair** classifies failures when they occur: is this an app bug (file evidence, leave the test alone), test drift (heal the test autonomously), or an irreducible flake (quarantine it with evidence)? Every test ends the repair cycle green or explained — never silently skipped.

The guard stage is what makes the lifecycle a loop rather than a line. Tests don't just get written and forgotten; they're actively maintained by the same agents that wrote them.

---

## III. Commit or Discard

Tests are **discardable by default.**

The verification work — running the test, collecting evidence, proving the negative control — always happens. But committing the test to the permanent suite is a separate decision with a separate gate:

1. The agent proposes durable automation only when CX/revenue impact justifies permanent regression coverage.
2. A human confirms the proposal. Without explicit confirmation, the test stays in the evidence bundle (attached to the ticket) and is not committed to the repository.

This prevents suite bloat. Not every ticket deserves a permanent regression test. A login-flow change that affects every user? Commit. A tooltip copy fix? Verify it, attach the evidence, discard the test.

The commit-or-discard gate is the methodology's answer to the observation that most test suites grow without bound and eventually collapse under their own maintenance weight.

---

## IV. Enforcement, Not Instructions

The distinction between a methodology and a best-practices document is enforcement.

Every critical rule in this lifecycle is backed by a harness hook — a shell script that runs on every tool invocation and physically blocks the action when a precondition is not met:

| Gate | What it blocks | Precondition |
|---|---|---|
| **Evidence bundle** | Ticket transition to completed state; non-draft PR creation | Evidence bundle with summary, screenshots, and at least one verification artifact must exist for the ticket |
| **Adversarial verification** | Same surfaces as above | Adversarial review receipt must exist and be newer than the newest spec edit |
| **Negative control** | QA sign-off | Test must be demonstrated to fail without the fix |
| **Schema validation** | Subagent returns | Every sub-agent return must conform to its role's JSON Schema |
| **Dual-stage review** | Journey completion | Composer and reviewer must be separate dispatches with isolated context |
| **PDF inspection** | Agent dispatch after deck export | Every page of a generated PDF must be visually inspected before delivery |

The agent doesn't opt into the methodology; it has no path around it. The hooks are installed globally by `npm postinstall` and registered in the harness configuration. They cannot be disabled from inside a session — they can only be disabled by the operator before the session starts, via documented environment variables.

This is what makes the methodology trustworthy at scale: the enforcement is independent of the agent's context window, its instruction-following fidelity, or the length of the session. A hook that blocks sign-off without evidence blocks it on the ten-thousandth tool call the same way it blocks it on the first.

---

## V. What This Enables

When the foundation (separation of concerns), the lifecycle (triage → automate → confirm → guard), and the enforcement (harness hooks) work together:

- **A single sentence drives the entire QA process.** *"Verify the checkout flow with evidence."* The agent maps the flow, composes the tests, runs them, collects evidence, proves the negative control, and files the report — gated at every stage by the harness.

- **Test quality is not proportional to human attention.** The adversarial review and negative control gates mean a test that passes sign-off has been challenged by a reviewer with fresh context and proven to fail under the right conditions. A human confirms the verdict; a human doesn't produce it.

- **Suites stay healthy.** The guard/heal cycle means test failures are triaged and resolved autonomously. App bugs get evidence and a report. Test drift gets healed. Flakes get quarantined. The suite stays green and meaningful, not green and hollow.

- **The methodology travels with the package.** Install the npm package; the methodology is live. No onboarding document to read, no wiki to keep current, no "we should really update the testing guidelines" conversation that never happens.

---

## VI. The Honest Constraint

The lifecycle described above works within the boundaries of the environment it runs against. When that environment is production — when every test hits a live database, real payment processors, and actual customer-facing state — the methodology must exclude its most critical flows.

Checkout. Registration. Payment. Password reset. Account deletion. These are the flows with the highest CX/revenue impact, and they are the flows that cannot be safely automated against a production environment.

The shift-left lifecycle is incomplete until a test environment exists: a faithful representation of production without production connections to the critical systems — database, payment providers, live integrations. The guard stage can gate releases with what it can safely run; it cannot verify the flows that would damage production to test.

This is not a limitation of the methodology. It is a limitation of the environment. The methodology is ready. The sandbox is what's missing.

---

*Built on [`@civitas-cerebrum/achilles`](https://www.npmjs.com/package/@civitas-cerebrum/achilles) and [`@civitas-cerebrum/element-interactions`](https://www.npmjs.com/package/@civitas-cerebrum/element-interactions).*
