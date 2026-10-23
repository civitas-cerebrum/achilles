# 8. Prove the tests discriminate the fix — the negative control

A green suite on the feature branch proves the assertions pass *where the feature exists*. It does not prove they would fail where it doesn't. Those are different claims, and only the second one makes the suite regression cover.

**Run the suite against an environment without the fix and require it to FAIL.**

Production before the PR ships is the usual target, but it is not the only one and it is not always
safe. In order of preference:

1. **A preview of the merge-base commit**: same infrastructure, no fix. Cleanest.
2. **A local build of `main`**: needs the app runnable locally.
3. **Production**: only when the suite is READ-ONLY. A suite that creates orders, users or
   records will create them in production. Check before pointing it there; this is the one step in
   this skill that can cause real-world damage.
4. **Feature-flag the fix off**, if it is flagged.

If none is available, say so in the verdict: *"suite is green but unverified; not regression
cover"*. Silently skipping the control and reporting regression cover is not.

A gated suite will skip there, which proves only that the gate works. So give the gate an explicit off switch and use it:

```ts
const FEATURE_GATE_DISABLED = process.env.E2E_FEATURE_GATE === 'off'
test.skip(!present && !FEATURE_GATE_DISABLED, 'Not deployed on this environment yet.')
```

Read the result per test, not in aggregate. Three outcomes, three meanings:

| Outcome without the fix | Meaning |
|---|---|
| **Fails** | The test discriminates the feature. This is what you want from AC cover. |
| **Passes** | Either it is close-regression cover of *pre-existing* behaviour (correct: filter drawers and sort controls should pass on both), or it asserts nothing the feature changed and is worthless as AC cover. Decide which; do not assume the charitable reading. |
| **Skips** | You forgot the off switch. The run told you nothing. |

**`test.fail()` sentinels cannot pass this control**, and it is worth knowing why before it confuses you: on an environment without the feature they fail because the element is *missing*, not because the defect is *present*, and `test.fail()` reports that as passed. A sentinel is indistinguishable between "bug reproduced" and "feature absent". The feature gate is what keeps that harmless; nothing else does.
