# Style-interaction verification — mock the page, test the styling

When a fix is purely CSS/styling that responds to user interactions (focus rings, hover states,
active highlights) and **real page data is unavailable** (no orders, no transactions, empty
accounts), you cannot drive the feature end-to-end. But you can still verify the fix in the real
CSS environment (Tailwind layers, design tokens, specificity chains, global rules) by injecting
mock DOM and triggering the interaction programmatically.

This is a **fallback**, not a substitute. The report must state that real data was unavailable and
why. An injected element proves the CSS classes produce the right computed styles in the project's
stylesheet; it does not prove the component renders those classes, that the layout doesn't clip the
indicator, or that no ancestor `overflow: hidden` truncates it. Those require the real component
with real data, and the gap belongs in the report.

## When to use it

- The fix changes CSS classes on a component (focus-visible, hover, active, disabled states)
- The component needs data you cannot create (orders need payment, transactions need fulfilment)
- You need to prove the styling works in the real CSS environment, not in isolation
- The ticket's ACs are about computed visual properties (outline width, contrast, ring visibility)

## The pattern

All six steps run inside a single Playwright test via the project's CLI (`pnpm exec playwright
test`), so `playwright.config.ts` headers, device presets, and bypass tokens all apply.

**1. Navigate to the real page.** The full CSS environment must be loaded: Tailwind's generated
stylesheet, design tokens, global rules (e.g. `.is-tabbing a:focus-visible`). Use the page where
the component would normally appear, logged in if required.

**2. Set required state classes.** Some styling depends on ancestor state classes that headless
browsers don't trigger automatically. Inject them via `page.evaluate()`:

```ts
// The site adds .is-tabbing on first Tab keypress; headless may not fire it
await page.evaluate(() => document.documentElement.classList.add('is-tabbing'))
```

State the injected classes in the report; they are assumptions, not observations.

**3. Inject mock DOM** via `page.evaluate()` using the **exact CSS classes from the PR diff**.
Insert into `<main>` so the element inherits the page's full cascade. Give the mock a unique `id`
for reliable targeting:

```ts
await page.evaluate((cssClasses) => {
  const main = document.querySelector('main')
  if (!main) throw new Error('No <main> element found')
  const mock = document.createElement('div')
  mock.id = 'mock-component'
  mock.innerHTML = `<a href="#" class="${cssClasses}" id="mock-target">
    <span class="inline-block text-body-md-bold">Mock content</span>
  </a>`
  main.insertBefore(mock, main.firstChild)
}, 'focus-visible:ring-2 focus-visible:ring-brand-blue-500 …')
```

**4. Trigger the interaction.** Use the interaction that the fix targets:

| Interaction | How to trigger |
|---|---|
| Keyboard focus | `page.keyboard.press('Tab')` in a loop until `document.activeElement.id === target` |
| Hover | `page.hover('#mock-target')` |
| Active/pressed | `page.locator('#mock-target').dispatchEvent('pointerdown')` |
| Disabled state | set `disabled` attribute or `aria-disabled` on the mock |

**5. Assert computed styles.** Read the styles that the AC requires and assert on them directly:

```ts
const styles = await page.evaluate(() => {
  const el = document.activeElement
  if (!el) return null
  const cs = window.getComputedStyle(el)
  return {
    outline: cs.outline,
    outlineStyle: cs.outlineStyle,
    outlineWidth: cs.outlineWidth,
    outlineColor: cs.outlineColor,
    outlineOffset: cs.outlineOffset,
    boxShadow: cs.boxShadow,
  }
})

// Assert the AC: "visible focus indicator ≥ 2px"
const hasRing = styles.outlineStyle !== 'none' && styles.outlineWidth !== '0px'
const hasShadow = styles.boxShadow !== 'none'
expect(hasRing || hasShadow).toBe(true)
```

**6. Capture evidence screenshots.** Two shots: viewport for context, closeup for detail:

```ts
// Full viewport — shows the page, the mock element, and the focus state
await page.screenshot({ path: 'test-results/evidence-viewport.png' })

// Closeup — clip around the focused element with padding
const rect = await page.evaluate(() => document.activeElement?.getBoundingClientRect())
if (rect) {
  const pad = 40
  await page.screenshot({
    path: 'test-results/evidence-closeup.png',
    clip: { x: Math.max(0, rect.x - pad), y: Math.max(0, rect.y - pad),
            width: rect.width + pad * 2, height: rect.height + pad * 2 },
  })
}
```

## What to report

Follow the brief comment format from §9's "Posting to the tracker": what was tested (mention mock
injection and which classes), evidence screenshots inline, and the verdict. Caveats (no real data,
single browser, injected state classes) go as one-liners under the verdict, not as separate
sections.

## Negative control caveat

The standard negative control (§8), running the same test against an environment without the fix,
may not work for style-interaction tests. CSS specificity and Tailwind's layer ordering mean
that injecting old classes into a page does not replicate the cascade the old component experienced.
When the negative control is not feasible via injection, state this explicitly and cite the
ticket's own audit evidence (screenshots, screen recordings) as the pre-fix baseline.
