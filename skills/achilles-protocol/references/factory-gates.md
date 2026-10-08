# Factory gates

Field-level content gates for a project's own test code. Seven PreToolUse hooks under `hooks/factory/`, one shared
library (`hooks/lib/factory-common.sh`), one project rule file. They answer one question per tool call: *is what this
call writes or runs acceptable for this project?* — never *who* is calling (that is the kernel's job, see
[Ordering with the kernel](#ordering-with-the-kernel)).

The examples below use the neutral example shop: regions `north` / `south`, merchant `demo-bistro`, a spend-incurring
spec `tests/e2e/south/checkout-order.spec.ts`.

## Opting in: the rule file

A project opts in by committing `achilles-factory-rules.json` at the project root (override: `FACTORY_RULES=<path>`,
absolute or relative to the project root). It lives at the root, not under `.achilles/`, because onboarding gitignores
`.achilles/`: a rule file there would be missing in every other clone and the gates silently off. No rule file → every
factory gate allows silently. A rule id absent from the file → its gate allows silently. Start from
[`hooks/data/factory-rules.example.json`](../../../hooks/data/factory-rules.example.json); validate against
[`hooks/data/factory-rules.schema.json`](../../../hooks/data/factory-rules.schema.json).

**Registration.** Installing the package registers the gates ([harness-hooks.md](harness-hooks.md#factory-gates-opt-in)),
so committing the rule file is the whole of a project's opt-in. That holds only for an install that ran:
`CIVITAS_SKIP_HOOK_INSTALL=1`, or a vendored copy that predates the manifest, leaves the gates on disk and
unregistered, which looks exactly like a project where everything passes. `hooks/tests/install-simulation.sh` asserts
the registration from a simulated consumer install; `node scripts/lint-doc-drift.mjs` fails when a gate under
`hooks/factory/` is missing from the manifest or from harness-hooks.md.

```json
{
  "$schema": "https://raw.githubusercontent.com/civitas-cerebrum/achilles/main/hooks/data/factory-rules.schema.json",
  "version": 1,
  "contexts": {
    "north": { "baseUrl": "${SHOP_BASE_URL_NORTH}", "storageState": "tests/data/.auth/shopper-a.json" }
  },
  "rules": {
    "<rule-id>": { "description": "…", "doc": "skills/achilles-protocol/references/factory-gates.md#<rule-id>", "action": "…", "<field>": "…" }
  }
}
```

Every rule carries `doc` (quoted on the third line of each deny) and `action` (quoted on the second line). Paths are
project-relative; globs are bash globs where a trailing `/**` also matches the directory itself. Each rule object is
closed (`additionalProperties: false`), so a misspelled field fails the schema instead of being ignored. The optional
top-level `contexts` map (name → `{ baseUrl, storageState, description? }`) is for skills and tools that need a base URL
and an authenticated storage state per region or account; the gates do not read it.

**Floors.** The schema pins a floor for the lists where weakening is the risk: `selectors.no-inline.forbidden` and
`secrets.none.patterns` must contain the shipped entries (`allOf` / `contains`). A project adds entries, never removes
them — a rule file that drops a floor entry fails the schema.

**Who detects a missing or weakened rule file.** The gates cannot: a deleted file or a deleted rule is, by design, a
silent opt-out. Achilles ships no verify-step guard. The detector is the **project's own verify step**, which should
(1) fail when `achilles-factory-rules.json` is missing, (2) validate it against the schema (floors, closed rule
objects), and (3) mirror whichever content checks the project wants enforced in CI. Without that step, weakening the
file is silent.

| Gate (`hooks/factory/`) | Event | Rule id | Project values |
|---|---|---|---|
| `selector-write-gate.sh` | `Write\|Edit\|MultiEdit` | [`selectors.no-inline`](#selectors.no-inline) | scopes; forbidden/allowed (floor shipped) |
| `repository-evidence-gate.sh` | `Write\|Edit\|MultiEdit` | [`selectors.evidence`](#selectors.evidence) | repository path, evidence dir, provisional key |
| `intake-gate.sh` | `Write\|Edit\|MultiEdit` | [`specs.shape`](#specs.shape) | scope, id pattern, scenario docs, optional lint, frozen dirs |
| `spend-gate.sh` | `Bash` | [`spend.opt-in`](#spend.opt-in) | spend list; opt-in env + flag; wrapper, spend projects/scripts |
| `secrets-gate.sh` | `Write\|Edit\|MultiEdit` | [`secrets.none`](#secrets.none) | scopes; patterns (floor shipped); allowlist |
| `commit-gate.sh` | `Bash` | [`process.evidence`](#process.evidence) | stamp, current-change marker, trail dir, required files, hash command |
| `state-gate.sh` | `Bash` | [`process.state`](#process.state) | protected state dir |

## The rules

<a id="selectors.no-inline"></a>
### selectors.no-inline

A source file (`.ts .mts .cts .js .mjs .cjs`) under `scope` must not contain a `forbidden` literal (`getByRole(`,
`.locator(`, `[data-`, `page.goto(`, …) once comments are masked and every `allowed` literal (`extractAttribute:`,
`page.context()`, …) is cut out. Elements are named through the page repository — `steps.click('payButton',
'PaymentPage')` — never located inline.

Fields: `scope[]`, `forbidden[]` (floor), `allowed[]`.

<a id="selectors.evidence"></a>
### selectors.evidence

A write to `repository` is compared entry by entry with the on-disk file (Edit and MultiEdit replacements are applied to
it first). Every entry whose selector is new or changed must either carry `"<provisionalKey>": true` or have
`<evidenceDir>/<Page>.<element>.md` whose first `- selector: <JSON>` line deep-equals the new selector (key order
irrelevant) and which has a `- source:` line. A note that still describes the old selector is stale. Adding the
provisional flag alone, removing an entry or reordering is never judged.

Fields: `repository` (required), `evidenceDir` (default: see `hooks/data/factory-rules.schema.json`), `provisionalKey` (default
`provisional`); `action` may carry `<Page>` and `<element>`, which the gate fills in. Page and element names are read
separately, so a page name containing a dot (`Checkout.v2`) works; the note is `<evidenceDir>/Checkout.v2.<element>.md`.

<a id="specs.shape"></a>
### specs.shape

Two checks on a write that **creates** a file (existing files are never judged — intake is not a retrofit):

1. **Frozen directories** — a new file under a `frozenDirs` entry is denied; editing an existing file there is allowed.
2. **Intake** — a new `*.spec.*` / `*.test.*` under `scope` and outside `exclude` is read title by title (`test(…)`,
   `test.skip|fixme|only|fail|slow(…)`; commented-out lines ignored). Each title must match `titleIdPattern`
   (e.g. `CHK-01 — Card: place an order`), the id must head a block in a `scenarioDocs` file (a Markdown heading
   `#### CHK-01 — …`), and when `lint` is set, `<lint…> --id <ID> <doc…>` must exit 0; its `[specs.shape] …` lines
   (else its first line) are quoted in the deny.

Fields: `scope[]`, `exclude[]`, `frozenDirs[]`, `titleIdPattern`, `scenarioDocs[]`, `lint` (argv, optional), `tags[]`
and `blockEnums` (read by the scenario lint, not by the gate:
[scenario-block.md](../../requirement-intake/references/scenario-block.md)).

**`titleIdPattern` is the project's one test-id shape.** It is read by a second, already-registered gate as well:
`hooks/test-id-compliance-gate.sh` (every title an edit ADDS carries a stable id, and no id repeats in one file) takes
its pattern from this field whenever the project has a `specs.shape` rule, so the two gates cannot disagree about what
an id looks like. Precedence: `CIVITAS_TEST_ID_PATTERN` (an explicit operator override) → `titleIdPattern` → the house
`TCXX-NNNNNN` default for a project with no rule file. Each gate still checks its own thing — the test-id gate that an
id is *there* and unique, the intake gate that the id names a written, linted scenario — but against one shape.

To make the two differ, set `CIVITAS_TEST_ID_PATTERN` deliberately.

<a id="spend.opt-in"></a>
### spend.opt-in

`list` is a JSON file `{ "specs": ["tests/e2e/south/checkout-order.spec.ts", …] }` of specs that cost something on every
run (real orders, paid calls, shared quota). Per shell segment, unless **that** segment opts in — `<optInEnv>=1` as a
leading assignment of `playwright test` / `npm run <spendScript>`, or `<optInFlag>` on the `wrapper` command — the gate
denies when:

- a file argument (`:line[:col]` stripped, `..` and the project root resolved) is part of a listed path or contains one
  (Playwright file filters are path regexes, so `checkout-order` selects `checkout-order.spec.ts`);
- `playwright test` (including `--list`) has no file argument and no `--project`, or a `--project` in `spendProjects`;
- `npm run <spendScript>` runs a spend project unfiltered.

One level of `bash|sh|zsh|dash|ksh -c '…'` and `eval '…'` is classified as a command of its own (outer assignments inherited).
A spec or project argument that is a shell expansion (`"$SPEC"`) cannot be judged and is denied with a request for a
literal path. An opt-in exported in an earlier segment (`export SPEND_OPT_IN=1; …`) does not count.

Fields: `list`, `optInEnv`, `optInFlag` (required); `wrapper`, `spendProjects[]`, `spendScripts[]` (optional).

<a id="secrets.none"></a>
### secrets.none

A file under `scope` must not receive content matching a `patterns` entry (POSIX ERE; `\d` is rewritten to `[0-9]`).
`allowlist`: an entry ending in `/` exempts a path prefix; any other entry exempts the file with exactly that path and
allows a match that contains it (case-insensitive). The deny quotes only the first three characters of a match.

Fields: `scope[]`, `patterns[]` (floor: email, E.164 phone, JWT), `allowlist[]`. A rule without `scope` or `patterns`
allows with a warning.

<a id="process.evidence"></a>
### process.evidence

A `git commit` whose directory (after `cd` segments and `-C` options) is inside the project is denied when `stamp` is
missing, has no `treeHash`, or its `treeHash` differs from what `hashCommand` prints now; and, when `currentChange`
exists, when it does not name a `<yyyy-mm-dd>-<slug>` folder or that folder under `trailDir` lacks a `required` file. No
marker means a maintenance commit: only the stamp is checked. Commits in other repositories are not gated.

Fields: `stamp`, `trailDir`, `hashCommand` (argv; required), `currentChange`, `required[]`.

The receipt is `{ "treeHash": "<hex>", "at": "<iso>" }`. `treeHash` is the sha1 over the sorted `(relative path, sha1 of
contents)` lines of every file under the hashed roots, excluding `stateDir`, local run output and authentication
state; a symlink is hashed by its target text. A touch keeps the hash; any added, removed or changed file invalidates
it. `hashCommand` prints the same function without running the checks. Only the project's verify step writes the
stamp, and only when every check passed; `state-gate` blocks hand-written forgeries.

<a id="process.state"></a>
### process.state

A Bash command naming `stateDir` is denied when it writes into it: a redirect onto a path in it; `tee`, `rm`, `touch`,
`truncate`, `unlink`, `shred`, `ln`, `mv`, `dd of=`, `sed -i`, `perl -i` naming a path in it; `cp`, `install`, `rsync`
whose target (last operand, or the `-t` directory) is in it; any of those after a `cd` into it. Quoted text is an
argument: `echo "> .achilles/x"` passes. Reading and copying out are allowed.

The gate fails closed when it cannot judge the target: a line too long to split, an unknown wrapper option, `xargs`
feeding a writer, or a `$VAR`, `$( )` or path glob as the operand of a writer other than `cp`, `install` and `rsync`.

Fields: `stateDir` (missing → allow with a warning on every Bash call, so the gap is visible).

## Message contract

Every deny reason is exactly three lines:

```text
[spend.opt-in] Command runs the spend-incurring spec checkout-order.spec.ts (listed in tests/spend-list.json) without SPEND_OPT_IN=1.
→ Do: Prefix the command with SPEND_OPT_IN=1 for an owner-approved run (one per scenario), or use node scripts/run-suite.mjs, which excludes the listed specs unless --include-spend is passed.
→ Why/how: skills/achilles-protocol/references/factory-gates.md#spend.opt-in
```

- Line 1 `[<rule-id>] <what happened>` names the file or command fragment and the exact offending literal, so the agent
  can fix it without re-reading the rule.
- Line 2 `→ Do:` is the sanctioned alternative (the rule's `action`, or a gate-specific action), never "don't".
- Line 3 `→ Why/how:` is the rule's `doc` anchor.

Outcomes other than deny:

| Situation | Outcome |
|---|---|
| No rule file, or the rule id is absent | silent allow (not opted in) |
| jq or node missing; rule file not a JSON object; payload not a JSON object; a required field missing; a helper cannot run | allow with one `[factory] …` line on stderr |
| Input the gate can see but cannot judge (a shell expansion as a spec argument) | deny, asking for a literal |

The allow-with-warning branch never bricks a session: an environment without jq still lets the agent work. The
detector for that branch is the project's verify step (see [Who detects a missing or weakened rule
file](#opting-in-the-rule-file)).

## Ordering with the kernel

The role kernel (`hooks/data/achilles-qa.kernel-mandate.json`) decides **authority**: which role may write which path, run
which command, dispatch which role. The factory gates decide **content**: whether what an allowed role writes or runs
is acceptable for this project. A factory gate never inspects who is calling; the kernel never inspects what is written.

Both run on PreToolUse; matching hooks run independently and a single deny wins, so there is no ordering to configure
and no gate relies on another having run. A call passes only when both agree. Both fail closed on their own
undecidable inputs (the kernel on an unknown role, a gate on an unjudgeable argument) and neither writes a file.

## Verify-step conventions the gates rely on

- **Stamp.** The verify step runs every check (typecheck, unit and guard, hook fixtures, lints) and writes the receipt of
  [process.evidence](#process.evidence) only when all pass.
- **`--forbid-only`.** The verify step runs its unit/guard project with `--forbid-only`: a stray `test.only` in a
  guard spec would otherwise run one test, skip the rest of the guard, and still stamp.

Limits of the gates: [known-limits.md](known-limits.md) KL-17 to KL-19. Adding a rule and running the cases:
[hook-authoring.md](../../contributing-to-achilles-protocol/references/hook-authoring.md#factory-gates-adding-a-rule--running-the-cases).
