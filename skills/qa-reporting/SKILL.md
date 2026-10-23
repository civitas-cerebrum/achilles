---
name: qa-reporting
description: >
  Stakeholder-facing output from an existing suite, loaded by a `doc-writer`
  dispatch. Two outputs sharing one render-and-inspect pipeline: the work
  summary deck ("generate a report", "QA report", "export a deck", "show what
  we've done", onboard Phase 8) and the test catalogue ("produce a test
  catalogue", "scenario report", "catalogue the suite", "export the scenario
  inventory"). The deck tells the narrative; the catalogue lists the
  inventory. On demand only; never during authoring, coverage, repair or
  diagnosis. The catalogue needs a sentinel-bearing journey map and at least
  one spec.
---

# QA reporting

Both outputs are a self-contained HTML file plus a PDF, written to the project root, rendered with the project's `@playwright/test` Chromium, and inspected page by page before they are reported done. No fabricated numbers, no velocity or effort language, no author block, no client-specific vocabulary baked into the skill.

## Data collection (both outputs)

Read what exists; note what does not. Sources: `tests/**/*.spec.ts` (test and describe counts, titles, tags, ids), `page-repository.json` (pages, elements, platforms), `tests/e2e/docs/app-context.md`, `tests/e2e/docs/journey-map.md` (sentinel on line 1 required for the catalogue; optional for the deck), `tests/e2e/docs/adversarial-findings.md`, `tests/e2e/docs/flake-quarantine.md`, `.achilles/self-repair/*/report.json`, `bug-discovery-report.md`, `git log`, `playwright-report/` / `test-results/` (latest JSON), `package.json` (framework packages and versions).

**Staleness gate.** Compare the report JSON's `stats.startTime` and test count with `git log -1 --format=%cI -- tests/` and the counted `test()` blocks. On mismatch, annotate every results-derived figure with "results as of `<date>`; suite has changed since" or return `NEEDS_CONTEXT` offering a fresh run. Stale pass rates are never presented as current.

Framework detection: `@civitas-cerebrum/singularity` present → cross-platform wording; `element-interactions` alone → Playwright wording; both → lead with Singularity.

## Output 1: work summary deck

`qa-summary-deck.html` + `.pdf`. Template and CSS: [`assets/template.html`](assets/template.html); consumers override the custom properties for brand. Five to ten slides, each earning its place with project data:

1. Title (project, framework, date). 2. Project overview (app, packages with versions). 3. Coverage summary (test count, pages covered, elements, platforms). 4. Pages and scenarios. 5. Closing (package badges, repository links). Optional when the data exists: architecture (Singularity only), before/after (conventional Playwright alongside Steps API tests), timeline, bug-discovery results, coverage gaps, repair outcomes.

Every slide: `<section class="slide">` with the brand mark, `NN / NN` slide number, `h2`, subtitle, content. `@page { size: landscape; margin: 0; }`, `page-break-after: always`.

### Print-safety rules

1. **Opaque colours only**: no `box-shadow`, no `opacity` < 1, no rgba/hsla, gradients fade to the background colour. Chromium turns transparency into PDF groups that macOS Preview renders as grey boxes, and poppler renders cannot show it, so this rule is enforced at authoring time.
2. Only font weights the family ships; emphasise with colour, not synthesised bold.
3. Grid children holding code get `min-width: 0` and `overflow: hidden`; wrap code to the column (≈60 chars at half width).
4. A landscape page is a hard ~850 px height budget; after any addition re-render and check collisions with the header band and the bottom edge; reclaim space from headings before body text.
5. Never hand-simplify a vector mark; inline the true asset once in `<g id="logo">` and reuse with `<use href="#logo"/>`.
6. Badges on their own line below headings.
7. Re-export and inspect after every edit round, not once at the end.

## Output 2: test catalogue

`test-catalogue.html` + `.pdf` (A4 landscape, `1123 × 794` px, dark print-tuned palette with `print-color-adjust: exact`). Args: `brand: <name>` (a row in the palette table), `output: <path>`. Reference implementation: [`scripts/build-catalogue.js`](scripts/build-catalogue.js); extraction rules: [`references/spec-parsing.md`](references/spec-parsing.md).

1. **Extract** every statement-position `test(`, `test.skip(`, `test.fail(` with its describe chain, marker, `@tags`, test id (`TCXX-NNNNNN` at the head of the title) and skip reason from the preceding comment.
2. **Cross-reference** with the journey map: priority, category, entry, purpose per `### j-…` heading. `-regression.spec.ts` → adversarial regression (attach the boundary code when the ledger lists it); `sj-` describes → structural; `@flaky` or a quarantine entry → `Quarantined`; `@known-defect` → `Failing-expected` with the referenced ticket. Unmatched tests go to an **Unmapped** bucket, shown, never dropped; more than ten means the map is stale, which the return says.
3. **Categorise** on two derived axes: primary section from each journey's `Entry:` host + first path segment (or an explicit `Section:` field; fall back to file-name prefix), page area from `Pages touched:` clusters (target 10–14 areas; fold singletons). Never group by priority; priority is a chip. Chips: priority (P0 crit red … P3 grey), type (mobile > edge > error > structural > regression > happy path), test id, status (Active / Skipped with reason / Failing-expected / Quarantined).
4. **Pages**: cover (app, date, totals), contents with page numbers, one section header plus table pages per primary section (`Journey · Scenario · Type · Status`), the adversarial-regression section, the skipped-with-reason section (present even when empty: "No scenarios deferred"). Header with wordmark, section label and `NN / TOTAL` on every page.

Palette tokens (default): `--bg #0A0E14`, `--ink #E6EAF2`, `--ink-mute #8892A6`, `--brand #00A3FF`, `--accent #FF7A1A`, `--crit #FF5757`, `--high #FF8A3D`, `--med #FFC93D`, `--low #9CA3AF`, `--ok #34D399`. Brand overrides are added as rows, never inferred from a hostname.

## Render and inspect (both outputs)

1. **Render**: `node <path-to-this-skill>/scripts/export-pdf.js <html> [pdf]` ([`scripts/export-pdf.js`](scripts/export-pdf.js) uses the project's `@playwright/test`; the resolved PDF path is printed). The script renders every `<section class="slide">` on its own page and verifies the page count equals the slide count; a mismatch is a corrupt render and throws. Chromium's single-pass PDF truncates long documents, so the per-slide path is the only path.
2. **Inspect every page** by rendering the PDF to images (`pdftoppm -png -r 60 <pdf> <dir>/page` when available, else the per-slide PNG the script can emit) and opening each one. Per-page checks: real numbers (no `NaN`, `undefined`, `0 of 0`), dark background filling the page, contents matching the sections produced, table headers present and rows unclipped, chips coloured per palette, `NN / TOTAL` monotonic with a constant total, the skipped section explicit when empty.
3. **Fix and re-render in full** on any failure; a fix shifts pagination, so partial re-inspection does not count. Failure patterns: a blank page is a slide missing its index; a white page is a missing `print-color-adjust`; overflow is an unsplit table; `NaN` is an extraction miss; a blank skip reason is a missing comment (add it or surface the gap).
4. Return `visual-inspection: PASS (<N> pages reviewed)` or `WARN — <issue>` when an unfixable issue ships with the document (a stale map producing Unmapped rows); never ship a known-broken page silently.

Commit `docs(report): qa summary deck` or `docs(report): test catalogue`.

## Return

`DONE` with the HTML and PDF paths, headline figures (deck: tests, pages, elements, platforms, bugs; catalogue: scenarios, journeys covered, section breakdown, skipped count), the staleness annotation if applied, the derived taxonomy (catalogue), and the visual-inspection line.
