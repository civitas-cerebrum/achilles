# 6. Build understanding by interacting — simplest first

**Do not write the acceptance-criteria tests yet.** Work up to them. Each rung earns the next, and
a rung that surprises you is worth more than the rung that passed.

**6a: Does it exist?** The smallest possible test: the thing renders, and you can click it.
Nothing about the ACs. If this is awkward to write, the selectors are wrong and everything built on
them will be too: find that out now, not after twelve tests.

**6b: Drive it and watch.** Step through the flow in small increments with a screenshot *and* a
state dump at every step. Small enough to catch transitions: the interesting behaviour is between
the states, not at them. Record what you did not expect, even when it looks harmless.

> Worked example: stepping a page 0 → 400 → 560 → 700 → 1200px located a window where an element
> reported itself "stuck" while still `position: static` **and still half-visible and clickable**.
> No assertion had bounded that window, and no amount of diff-reading would have found it; the
> code looks correct at every line.

**6c: Derive the test cases from what you observed.** Now write them, and write them against what
a user would notice. Ask of each assertion: *if this passed but the feature were visibly broken,
would I still be green?* If yes, you asserted the mechanism instead of the outcome.

| Asserting the mechanism | Asserting the outcome |
|---|---|
| element has class `.is-active` | the active item is visually distinguished |
| `inert` attribute is absent | the control is visible **and** focusable |
| computed `position: static` | only one bar is pinned at the top |

Mechanism assertions are not wrong; they are often the only *stable* form, and the strongest
assertions in a suite are frequently structural. But a mechanism assertion is a **proxy**, and a
proxy needs the outcome asserted alongside it at least once, or nobody ever checks the proxy still
tracks the thing.

**6d: Only now, evaluate.** With a working model of the component, judge what is *undesirable*:
jitter, duplicated controls, focus traps, content that clips at a real breakpoint, states the
design never anticipated. This step is why 6a–6c come first; you cannot recognise "that looks
wrong" in a component you have only read about.

Then run `companion-mode` for the evidence bundle.

**6e: Inspect every screenshot for design quality.** Evidence screenshots are not just functional
proof — they are a visual inspection surface. After capturing them, review each one as a designer
would. A screenshot that proves "the error alert appeared" can simultaneously reveal that the
alert's container has broken padding.

Check for:

- **Padding and spacing symmetry** — are horizontal/vertical insets consistent between the left
  and right edges? Between the top and bottom? Compare the element's spacing to its siblings and
  to the container edges.
- **Alignment** — do elements that should be aligned (buttons, labels, icons) actually line up?
  Is text baseline-aligned where it should be?
- **Clipping and overflow** — is any content cut off by a parent's `overflow: hidden`? Are
  rounded corners rendering correctly at the edges?
- **Visual hierarchy** — does the layout still read correctly? Is the primary action visually
  dominant? Are secondary elements appropriately subdued?
- **State transitions** — compare the "before" and "after" screenshots. Does the layout degrade
  when the component changes state (expanding, showing an error, loading)?
- **Responsive integrity** — at the tested viewport, does the layout look intentional or does it
  look like it squeezed to fit?

This step catches defects that no functional assertion will find — the test that asserts
"the error alert is visible" passes identically whether the alert has correct padding or is
flush against the edge. Report design findings separately from AC results: they are not AC
failures, but they are findings that belong in the QA comment.

**Why this order.** Tests written straight from a diff bind to *that* implementation. Tests derived from observed behaviour survive the implementation moving
underneath them.

> **Phases 1–9 are one sequence.** A run that stops at 7 has produced tests nobody has shown to discriminate the fix. 8 is not optional follow-up.
