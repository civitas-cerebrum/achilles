# Autonomous mode

When invoked with `autonomousMode: true` (e.g. by `onboarding` if it ever needs evidence captures, or by a user-facing scheduler), all Phase-1 inputs MUST arrive in args:

```
companion-mode mode=live \
  task="Verify a returning user can log in and see their dashboard." \
  appUrl="https://staging.example.com/login" \
  passCriterion="Dashboard heading reads 'Welcome back, <user>' within 5s of submit." \
  slug="login-returning-user" \
  credentials=<ref-to-secret> \
  build=<app-build-id>            # optional — lands on summary.md's "App build:" line
```

Gate suspension matches the `achilles-protocol` autonomous-mode contract: page-repository proposals are written directly, no Phase-1 prompts are issued, the Phase-6 automation offer is suppressed (the caller's args resolve graduation explicitly via `graduate=` below). The bundle is still produced and its path is returned to the caller as the result.

The caller is responsible for handling the verdict; companion mode does not auto-escalate to `failure-diagnosis` even in autonomous mode, and does not silently graduate to durable automation. Graduation in autonomous mode is opt-in via an explicit arg from the caller:

| Caller arg | Behaviour |
|---|---|
| `graduate=none` (default) | Phase 6 prints the report and ends. No handoff to Stage 3 or `onboarding`. |
| `graduate=stage3` | After Phase 5, hand off to `achilles-protocol` with `autonomousMode: true, entry: "stage3", bundlePath: "<absolute>"` per the orchestrator's autonomous-mode cheat-sheet. Caller is responsible for ensuring the project is at Level None or C, OR for having already remediated A/B in its own pre-step. |
| `graduate=onboarding` | After Phase 5, hand off to `onboarding` in autonomous mode with the bundle's task as `happyPathDescription`. Companion mode does NOT decide between `stage3` and `onboarding` for the caller: the caller picks. |

Inferring `graduate=` from project state is a contract violation; the explicit arg is required.
