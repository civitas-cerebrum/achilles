# Selector evidence

Every entry in `page-repository.json` is backed by a committed evidence note **or** carries `"provisional": true` —
never both, never neither. The note turns rule 4 ("inspect the live site") from a sentence in a transcript into a
reviewable artefact, and it is what lets rule 2's standing authorisation work: a live-verified entry with a note
needs no approval round (see [Standing authorisation](#standing-authorisation)).

Examples below use a small web shop; the entries are `CheckoutPage.payButton` (on `/checkout`), `CataloguePage.itemCard` (a repeated card for `veggie-wrap` and its
siblings on `/catalogue`, `"list": true`) and `HomePage.searchBox` (signed-out landing page `/`). Contexts are the
regions `north` (session of `shopper-a`) and `south` (session of `shopper-b`).

## The sequence

The **only** sanctioned sequence for a new or changed entry — all four steps in the same change:

1. **Inspect live** — `playwright-cli` session (rule 11) or a temporary inspection spec. Record per element: URL path,
   context, how the state was reached, tag, role, accessible name, test attribute, the count of matches for the
   candidate selector, the frame title if framed.
2. **Insert provisional** — add the entry with `"provisional": true`. The tool reads only committed entries (it takes
   no selector argument), and the repository-evidence gate accepts a flagged entry without a note.
3. **Evidence** — run the tool for the entry; it writes `<Page>.<element>.md` and `.png` into the evidence directory.
4. **Drop the flag** — a flag-only edit. The gate now sees the note and checks it against the selector.

A flag that exists only between steps 2 and 4 is **not** a "never seen live" claim and needs no known-issues row.

Selector preference when inserting: the project's test attribute (`data-testid` or its convention) first; role +
accessible name second; text last. Framed content is a frame page keyed by a unique iframe title, never a frame
index. Repeated elements carry `"list": true`. A candidate that matches two things is omitted, not indexed.

## The tool

`bin/selector-evidence.mjs` (bin `achilles-selector-evidence`):

```
npx achilles-selector-evidence --page <Page> --element <element> \
  (--base-url <url> [--storage-state <path>] | --context <name>) \
  [--url <path>] [--out <dir>] [--repository <file>] [--mask <css>]… [--anonymous] [--help]
```

- Reads the **committed** entry and resolves it with `@civitas-cerebrum/element-repository` `get()` — exactly the
  framework's resolution, frames included. Both packages are resolved from the project, not from Achilles.
- **Count semantics**: exactly 1 match; at least 1 for an entry marked `"list": true` (the first match is outlined and
  the note says `(list entry)`). Count 0 → the message names the URL path, and for a framed page the iframe titles
  present. Count ≥ 2 on a non-list entry → the message lists up to 8 candidates by their first `data-*` attribute.
- On success: outlines the element in red with a `<Page>.<element>` label, screenshots the viewport (clipped around the
  element when the PNG would exceed 300 KB) and writes the note. The note is rendered and validated **before** any
  file is written, so a refused run never replaces a committed note or PNG.
- **Masking**: `--mask <css>` (repeatable) masks personal data in the screenshot. Default: none — the project knows
  where its personal data renders; Achilles does not. The mask is the tool's only raw locator.
- `--anonymous` opens the page signed out (for example `HomePage.searchBox`, which a signed-in session may redirect away
  from). Otherwise a storage state is required; the tool never logs in — the project's auth setup produces the file.
- Never clicks, types or submits. An element that only renders after an interaction (a dialog behind a button) cannot
  be evidenced by the tool; see [Provisional entries](#provisional-entries).
- Every refusal uses the three-line [message contract](factory-gates.md#message-contract).
- Exit codes (as `achilles-mutate`): **0** note written · **1** evidence refused (count, resolution failure, PNG over
  cap, invalid note) · **2** usage or configuration error (flags, unknown entry, missing storage state, dependency not
  resolvable).

## Config and contexts

The tool has no built-in URL, account or mask. It takes them from flags, or from the **optional** `contexts` map in the
project's factory rules file (`$FACTORY_RULES`, else `achilles-factory-rules.json`):

```json
{
  "contexts": {
    "north": { "baseUrl": "https://shop.example.test", "storageState": "tests/data/.auth/shopper-a.json" },
    "south": { "baseUrl": "https://shop.example.test", "storageState": "tests/data/.auth/shopper-b.json" }
  },
  "rules": {
    "selectors.evidence": { "repository": "tests/e2e/page-repository.json", "provisionalKey": "provisional" }
  }
}
```

- `--context north` picks an entry; `--base-url` / `--storage-state` override its fields. Without a rules file, pass
  the flags.
- `rules["selectors.evidence"].evidenceDir` is the one directory both the tool (default `--out`) and the
  repository-evidence gate read. Default when unset: see `hooks/data/factory-rules.schema.json`; the tool and the gate
  both read it there.
- `rules["selectors.evidence"].repository` is the default for `--repository`.
- Relative paths (`--repository`, `--out`, `--storage-state`) resolve against the project root (`$CLAUDE_PROJECT_DIR`,
  else the cwd), like the rules file.
- **Schema fields the tool reads** (`hooks/data/factory-rules.schema.json`, all optional):
  - `contexts` — optional top-level map `{ "<name>": { "baseUrl": string, "storageState": string } }`;
  - `rules["selectors.evidence"].evidenceDir` — the evidence directory (default `--out`);
  - `rules["selectors.evidence"].provisionalKey` — the entry flag name (`provisional`), read by the gate; the tool
    itself does not change entries.

  A project that shards by another dimension (locale, tenant, device) names its contexts after it.

## The note

`<Page>.<element>.md`, one per entry:

```
# CheckoutPage.payButton
- selector: {"css":"[data-testid='pay-button']"}
- context: north · url: /checkout · date: 2026-01-01T10:00:00Z · tool: selector-evidence 1.0
- resolved count: 1 · tag: button · role: — · name: "Pay ¤12.50" · data-attribute: data-testid=pay-button
- aria snippet: `- button "Pay ¤12.50"`
- screenshot: CheckoutPage.payButton.png
- source: live
```

| Field | Meaning |
|---|---|
| `selector` | the entry's selector JSON at the time of the run |
| `context` | the `--context` name, or `flags`; `(anonymous)` when signed out |
| `url` | the resolved URL path (id-like segments replaced by `<id>`; query dropped) |
| `date`, `tool` | ISO timestamp; tool name and version |
| `resolved count` | the count; `(list entry)` for `"list": true` |
| `tag`, `role`, `name` | of the first match; name = `aria-label` or trimmed text (≤ 80 chars) |
| `data-attribute` | up to three `data-*` attributes of the first match |
| `aria snippet` | first line of its aria snapshot |
| `screenshot` | the PNG beside the note (live notes only) |
| `source` | `live`, or a backfill source (below) |

**Contract used by the repository-evidence gate:** for a new or changed entry that is not provisional,
the note must exist, its `- selector:` JSON must **deep-equal** the entry's selector (after JSON parse; key order
irrelevant), and it must carry a `- source:` line. A changed selector with the old note is refused as stale; a
hand-written note without a source is refused. The tool refuses to write a note without `source`, or one whose text
carries an `@` on any line **except** `- selector:` (emails are redacted first). The selector line is exempt because
it is the project's own committed value, already in `page-repository.json`, and the gate requires the note to carry it
back verbatim, so a selector containing `@` can be neither redacted nor omitted. A refusal is reported as a refusal: it
names the offending line and says the element resolved, rather than sending you to re-check the `--url`.

## Backfill

A project adopting the convention has entries that predate it. A backfill writes a note only on what the record says:

1. **The inspection record itself says the entry was seen live** (a proposal comment, an inspection file whose own
   header says it is a live inspection, a row saying "seen live") → `source: legacy-inspection <path>`, the record
   quoted verbatim in `legacy record`, `live-observed: yes (<why>)`, and `resolved count: — (backfill note: …)`.
2. **The record is unconfirmed or absent, but a green run exercises the entry non-optionally** (optional probes and
   `hidden` waits do not count) → `source: live-run (exercised by <file:line>)`, `live-observed: yes (by run)`.
3. **Otherwise no note**: the entry becomes `"provisional": true` and gets a known-issues row.

"Seen live" is written only when the record says so, never inferred from a plausible-looking entry. A backfill
never touches a `source: live` note and is idempotent. Running the tool later replaces a backfill note with a live one.

## Provisional entries

An entry may **stay** provisional only when the code needs it and its state never occurred live, or the tool cannot
reach it without an interaction. Every such entry is **listed in the project's known-issues file** (for example
`tests/e2e/docs/known-issues.md`): the entry, its selector, where it is referenced, and what fails if it is wrong.
Note XOR flag; flag ⇒ known-issues row. When the state is met live: run the tool, drop the flag, delete the row — in
the same change.

## Standing authorisation

Rule 2 requires the user's "yes" before `page-repository.json` is edited. A user may grant a **standing
authorisation** in the form: *live-verified entries with an evidence note need no approval round; source-only entries
do.* Under it:

- an entry inspected live (step 1) and evidenced by the tool (step 3) is inserted without a separate approval round;
- an entry inferred from frontend source, docs or another suite — anything not seen live — is shown to the user as
  JSON and waits for "yes", exactly as rule 2 says.

The authorisation is recorded where the project records its decisions; without it, rule 2 applies unchanged.
