# Framework gaps

What an author does when the Steps API, or the framework behind it, cannot do what a test needs. Two shapes, two paths.

## API gap: a method, option or matcher is missing

```ts
// Not this: it drops out of the framework
const locator = page.locator('button.submit');
await locator.evaluate(el => getComputedStyle(el).getPropertyValue('--brand-color'));
```

1. **Check it is missing.** Read [api-reference.md](api-reference.md) end to end for the surface: the matcher tree, the predicate form, `.css(prop)`, extraction methods. Most needs are covered.
2. **Check the version.** `npm view @civitas-cerebrum/element-interactions version` against the pinned one; a capability that landed upstream is a dependency bump, not a gap.
3. **Ship now with the escape hatch.** `interactions.interact.*`, `interactions.verify.*`, `interactions.extract.*` accept a `Locator` or an `Element`; use them for the one-off call and leave a one-line comment naming the gap. Never a raw `locator.*()` call in a spec.
4. **Report it.** Return `DONE_WITH_CONCERNS` naming the missing method, the use case and the escape-hatch call site, so the orchestrator can surface an upstream issue against `civitas-cerebrum/element-interactions` (generic element capabilities belong in element-repository's `Element` first; assertion shapes belong on the matcher tree).

## Structural gap: a rule the framework cannot back

Signs: a skill prerequisite the package cannot make true; a workaround that would weaken or skip a documented invariant; two parallel experts corrupting each other's state through the chosen tool; a protocol that assumes a host capability the runtime lacks.

1. **Write the unsatisfied invariant down**: the rule (file and section), the mechanism that fails to back it, the smallest credible fix (a new primitive, a tool swap, a protocol change).
2. **Do not relax the invariant locally.** The rest of the suite is built on it; a local patch hides the structural problem.
3. **Decide block versus documented workaround.** Block when the invariant is safety-critical (data corruption, cross-tenant leakage, false-pass tests): return `BLOCKED`. A workaround is acceptable when it is local and reversible, waiting costs more than working around, and the gap is reported: return `DONE_WITH_CONCERNS` with the workaround named.
4. The fix lands in the package; the consuming skill deletes its workaround once the primitive ships.
