# Static mode — first-class adversarial probing

`mode: static` is a **first-class probing mode**, not a degraded fallback for when live probing fails. Static mode is the default where `@playwright/cli` is unavailable (CI runners without a browser, restricted sandboxes, read-only review checkouts). Static findings stand on their own merit; they are simply a different class of evidence than live findings, and they are labelled as such.

## What the subagent reads

In static mode the subagent does not navigate the app. It reads, in order:

1. Spec files in the test directory: to understand what is currently asserted and what boundaries existing tests already guard.
2. `page-repository.json`: the authoritative selector inventory and element-attribute context (input types, max-length attributes, role hints).
3. `tests/e2e/docs/app-context.md`: documented pages, flows, and known quirks.
4. Sibling-journey ledger sections in `tests/e2e/docs/adversarial-findings.md` (or equivalent): adversarial findings logged against related journeys often transfer to the journey under analysis.

## How bugs are inferred

Static mode infers likely bugs from pattern matches against the code and repository snapshot. Every inferred finding is recorded with `inferred: true` in its structured body. Examples of inference patterns:

1. **Missing `maxlength` on a free-text input** → likely HTTP 500 on long input (server-side length unguarded). Infer a boundary bug for payloads above the typical DB column cap (255, 4000, etc.).
2. **Missing `type="email"` / no client validation on an email field** → likely XSS or malformed-input vector; downstream rendering probably reflects user-supplied content unescaped.
3. **No `autocomplete="off"` on a password-reset or MFA entry field** → likely credential-leak surface via browser autofill in shared-device contexts.
4. **No CSRF token reference in a form handler that issues a mutating POST** → likely CSRF vulnerability, especially if the session cookie lacks `SameSite=Lax|Strict`.
5. **Numeric input without `min` / `max` / `step` attributes** → likely negative-number or floating-point edge-case bug (e.g., quantity=-1 bypassing validation, price=0.0001 rounding to 0).

These five are illustrative; the subagent applies the same inference pattern to any similar structural gap it observes. Each finding body states the evidence (which file, which element, which missing attribute), the inferred failure mode, and carries the `inferred: true` flag.

## What static mode must never claim

- **No verified-bug claims.** Static mode never asserts that a bug was reproduced. Findings are inferences from structural evidence. If the caller later re-runs in `mode: live`, the inference can be confirmed or refuted, but until then, the finding is documented as inferred only.
- **No reproduction test.** Phase 6 writes reproduction tests; static mode does not. A static finding can be handed to a later live pass for reproduction, but the static subagent itself stops at evidence + inference.

## Why this is first-class, not a fallback

Several environments are static-only by construction: CI runners without a browser, regulated sandboxes that block outbound network, code-review contexts, and offline audits. Running bug-discovery in those contexts is a legitimate use case, not a degraded one. Framing static mode as a first-class probing mode removes the "apology" framing that produces weaker findings and standardises the structured-return shape so the orchestrator can merge static and live findings on the same footing (with the `inferred: true` flag retaining the epistemic distinction).

## Orchestrator-side: no silent deprioritisation

Static mode constrains how orchestrators (`coverage-expansion`, `onboarding`, Phase-7 deck generation) handle the findings:

- **Ranking.** Static findings rank by **severity**, not by evidence class. A `severity: high` inferred finding outranks a `severity: low` live-verified finding in any ordered list.
- **Inclusion in reports and decks.** Static findings appear in the onboarding-report and the summary deck on the same footing as live findings. The `inferred: true` flag is shown explicitly so readers can judge epistemic weight, but the finding is not buried or collapsed.
- **Follow-up suggestion.** When static findings landed in an earlier run and `@playwright/cli` later becomes available, the orchestrator SHOULD suggest re-running the affected journeys in `mode: live` to confirm or refute each `inferred: true` finding. "Suggest" means a one-line progress note to the caller, not an autonomous re-run.

**Rationalizations to reject:**

| Excuse | Reality |
|--------|---------|
| "Inferred findings are weaker so I'll bucket them separately in the deck" | Bucketing by evidence class rather than severity buries high-impact static findings. The flag carries the epistemic weight; ranking stays severity-first. |
| "Static-mode findings are probably false positives, so I'll drop the low-severity ones" | Every finding's severity is the subagent's judgement; filtering on evidence class on top of severity is double-discounting. |
| "Live mode ran fine so I can ignore any earlier static findings" | A live pass that failed to reproduce an inferred finding does not refute it; it demotes evidence, but the finding stays in the report unless the live pass reached the specific pattern. The orchestrator marks the inference as `live-unconfirmed`, not deleted. |
| "`@playwright/cli` is available so there's no reason to run static mode" | Correct for that one run. Static mode serves environments where live is unavailable; it is not redundancy. Do not run static mode in parallel with live unless the caller specifically requested a code-audit pass. |
