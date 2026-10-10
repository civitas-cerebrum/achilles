# Phase 5: Classification & Prioritization

Merge all findings from Phases 2, 3, and 4 into a single prioritized list.

## Classifications

| Classification | Meaning | Action |
|---|---|---|
| **New bug** | Not documented, not tested, clearly wrong | Phase 6 (reproduce) |
| **Regression candidate** | Contradicts existing test in different context | Phase 6 (reproduce with context note) |
| **Undocumented quirk** | Weird but possibly intentional | Flag in report, ask user |
| **Known but untested** | In app-context but no test guards it | Phase 6 (write guard test) |

## Severity

Severity uses the **single canonical five-value enum**: `critical | high | medium | low | info`, defined once in [`../achilles-protocol/references/subagent-return-schema.md`](../../achilles-protocol/references/subagent-return-schema.md) §1. This skill does not restate the enum; the table below is **report-facing decision guidance** that maps observed findings onto those canonical values. The report-facing label **"No impact (DOM-only)"** is this skill's presentation name for canonical `info`.

| Canonical severity | Report-facing guidance | Decision criteria | Examples |
|---|---|---|---|
| `critical` (**Critical**) | Security vulnerabilities, privacy violations, leaked sensitive data, broken authentication, credential/key exposure, legal-or-compliance risk, or complete failure of a primary user journey. | Ask: "Could this cause a data breach, privilege escalation, auth bypass, legal liability, or prevent all users from achieving the app's core purpose?" If yes → critical. | XSS/injection, exposed API keys or credentials in client-side code, auth bypass, IDOR/cross-user data access, SSL errors, GDPR/CCPA violations, broken payment flow, complete app crash on load |
| `high` (**High**) | A state the app must prevent, or material user impact: the user cannot complete an intended action without a non-obvious workaround; a core feature is broken. | Ask: "Is a user stuck? Can they not complete what they came to do?" If yes → high. Simple workaround + non-core feature → medium. | Form submission silently fails, primary navigation leads to error/blank page, core feature throws unhandled exception, search returns no results when results exist, login/signup broken |
| `medium` (**Medium**) | Degraded UX or data-correctness issue. The user notices something is wrong but can continue. | Ask: "Does the user notice something is wrong, but can still use the app?" If yes → medium. If the broken content is critical to the app's purpose (e.g. pricing on e-commerce), escalate to high. | Dead outbound links, expired listings, 404 on linked pages, stale references, broken images on content pages, incorrect contact details |
| `low` (**Low**) | Minor inconsistency, cosmetic defect, UX nit. Still accessible, just slightly inconvenient; a typical user would not notice. | Ask: "Would a normal user even notice this? Does it prevent them from doing anything?" If no to both → low. | `href="#"` instead of `tel:`, external links missing `target="_blank"`, minor nav/footer naming inconsistencies, slightly truncated tooltip |
| `info` (**No impact (DOM-only)**) | Found only by inspecting HTML/DOM; invisible to users. Hidden elements, zero-height containers, unused template content, metadata issues. Code hygiene, not bugs. | Ask: "Is there captured evidence appropriate to the finding's oracle?" (See the evidence rule.) If a user-experience finding has no screenshot → info. | Lorem ipsum in `display:none` sections, broken anchors in hidden navs, unused zero-dimension FAQ sections, missing H1 in hidden blocks, generic `<title>` tags |

## Evidence rule (replaces the absolute screenshot cap)

This operationalises the unified evidence rule in `subagent-return-schema.md` §1; it is the authority other skills inherit.

**Every finding above `info` MUST cite captured evidence appropriate to its oracle**: a screenshot for visual/UX findings; a saved response body, header dump, console capture, DOM/source excerpt, or static-inference rationale (`inferred: true`) for API/security/privacy findings. Findings with no captured evidence cap at `info`.

- **User-experience findings** (visual/functional/UX) **MUST be screenshot-verified.** If you cannot see the issue in a screenshot: element hidden, zero-sized, off-screen, `display:none`, collapsed container: it caps at `info` (the "No impact (DOM-only)" label). A hidden broken link is unused HTML, not a broken link.
- **Security-class findings MUST be artifact-verified**, and are **severity-rated on impact regardless of screenshot visibility.** A security/privacy finding (anything meeting the `critical`-row criteria in §1: auth bypass, IDOR/cross-user access, credential/key exposure, injection, data exfiltration, privilege escalation, compliance risk) is rated on its impact even when nothing visible appears in a screenshot, *provided* it is backed by an artifact: a DOM/source excerpt, a saved response body, a header dump, or a static-inference rationale (`inferred: true`). The artifact is the evidence the screenshot would otherwise be: the carve-out is *which* evidence, not *whether* evidence.

**Verification process: for every finding:**
1. Navigate to the page where the finding occurs.
2. Capture the evidence appropriate to the oracle: a screenshot for a UX finding; a response body / header dump / DOM excerpt / console capture (or a static-inference rationale) for a security/API/privacy finding.
3. **UX finding, visible in the screenshot** → assign severity on user impact via the table above. **Not visible** → `info`.
4. **Security-class finding, artifact captured** → rate on impact per §1's critical-row criteria, even if invisible on screen. **No artifact captured** → caps at `info`.
5. **When in doubt** for a UX finding, scroll to the element and take a full-page screenshot: CSS transforms, overflow, z-index, and scroll-reveal can hide an in-DOM element. Do not rely on DOM inspection alone to judge *user* visibility.

## Priority derivation

**Priority** is distinct from severity: severity = "how bad is the defect", priority = "how soon to fix", and it is a fixed function of `f(severity, journey tier)`. Record a `Priority:` next to `Severity:` in the Phase 7 block and pass it to `bug-report` as the pre-filled suggestion (the user confirms).

| Severity \ Journey tier | P0 | P1 | P2 | P3 |
|---|---|---|---|---|
| `critical` | Highest | Highest | High | High |
| `high` | Highest | High | High | Medium |
| `medium` | High | Medium | Medium | Low |
| `low` | Low | Low | Low | Low |
| `info` | Low | Low | Low | Low |

When no journey map is available (standalone runs without tiers), default the journey tier to **P2**.

**Vocabulary mapping** (one surface, three labels):

| Canonical severity (§1) | bug-discovery report label | bug-report Jira label |
|---|---|---|
| `critical` | Critical | Critical |
| `high` | High | High |
| `medium` | Medium | Medium |
| `low` | Low | Low |
| `info` | No impact (DOM-only) | _(not ticketed)_ |

## Also in this phase

Update `app-context.md` with any newly discovered pages, state variations, or quirks found during probing.
