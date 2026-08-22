# Harness OS — storage & swap format

> Canonical home: [civitas-cerebrum/harness-os](https://github.com/civitas-cerebrum/harness-os).

A designed harness OS is more valuable when it can be **stored, shared,
version-pinned, and swapped** as one unit — not retyped per project. This
is what the bundle format is for. It is a packaging layer *on top of* the
live manifest; the kernel is untouched.

## Two artifacts, one clean split

| Artifact | Path | Who reads it | Lifetime |
|---|---|---|---|
| **Live manifest** | `<repo>/.claude/harness-os.json` | the kernel hook, every tool call | the running project |
| **Bundle** (`.hos.json`) | a file, or the library | the CLI, humans, other projects | the portable definition |

The kernel *only ever* reads the plain live manifest — so the storage
layer adds zero attack surface to enforcement. The bundle is what you
move around; importing one simply writes its manifest to
`.claude/harness-os.json` and records where it came from.

Runtime state (`.claude/harness-os.state/` — role bindings, the dispatch
registry, the decision log) is **never** part of a bundle. A bundle is a
*definition*, not a running instance; a fresh install starts with empty
state.

## The bundle (`.hos.json`)

Schema: [`schemas/harness-os-bundle.schema.json`](../../../schemas/harness-os-bundle.schema.json).

```jsonc
{
  "kind": "harness-os-bundle",
  "bundleVersion": 1,                       // envelope format version
  "metadata": {
    "name": "registration-form-qa",         // stable identity, project-independent
    "revision": "1.2.0",                     // bump on every meaningful change
    "title": "Registration-form QA",
    "description": "...",
    "author": "...",
    "createdAt": "2026-08-22T10:00:00Z",     // stamped at export
    "basedOn": "qa-pipeline",                // lineage (optional)
    "tags": ["qa", "playwright"]
  },
  "manifest": { /* the exact harness-os.json, embedded verbatim */ },
  "fingerprint": "sha256:…",                 // integrity + identity
  "notes": "changelog / design rationale"    // optional
}
```

- **`name@revision`** is the identity. Together they form the library
  key (`registration-form-qa@1.2.0.hos.json`) and make swaps and
  rollbacks unambiguous. `bundleVersion` (the envelope format) is
  distinct from `manifest.harnessOsVersion` (the contract the kernel
  enforces).
- **`fingerprint`** is `sha256:` + the hex SHA-256 of the manifest
  canonicalised as JSON with all object keys sorted recursively and no
  insignificant whitespace. It is deterministic across machines, so it
  doubles as (a) an integrity check — a bundle whose fingerprint no
  longer matches its embedded manifest is refused on import, and (b) a
  drift signal — `status` compares it against the live manifest.
- **`manifest`** is embedded verbatim, so a bundle is fully
  self-contained: one file carries the whole OS.

A **directory-form** bundle (`<name>@<rev>/`) may additionally ship
companion `assets` — per-role brief templates the orchestrator pastes
into dispatch prompts, a README — declared in the envelope's optional
`assets` map. The kernel never reads them; they travel with the OS for
the humans and orchestrators who operate it.

## The library (swap store)

`~/.harness-os/library/` (override with `$HARNESS_OS_HOME`) holds bundles
by `<name>@<revision>.hos.json`. It is the shared shelf you `use` OSes
from — machine-wide, not per project. Keeping several revisions of the
same name side by side is exactly what enables rollback.

## The lock (per-project provenance)

Importing an OS writes `<repo>/.claude/harness-os.lock.json`:

```jsonc
{
  "active": {
    "name": "registration-form-qa",
    "revision": "1.2.0",
    "fingerprint": "sha256:…",
    "source": "/home/me/.harness-os/library/registration-form-qa@1.2.0.hos.json",
    "installedAt": "2026-08-22T10:05:00Z"
  }
}
```

It records which stored OS the live manifest came from. That is what lets
`status` say "you are running `registration-form-qa@1.2.0`, and the live
manifest still matches it" — or warn that it has drifted.

## CLI workflow

```bash
# capture the OS you designed into the library
harness-os export --to-library --revision 1.0.0 --notes "first cut"

# see what's on the shelf (★ marks the one active here)
harness-os list

# swap this project to a stored OS (resets runtime state for the new roles)
harness-os use registration-form-qa@1.0.0
harness-os use feature-dev --keep-state     # keep bindings if roles overlap

# share one OS as a single file
harness-os export --out ./registration-form-qa.hos.json
#   → teammate: harness-os import ./registration-form-qa.hos.json --activate

# is the live manifest still the OS I installed?
harness-os status
```

## Swap semantics (why it's clean)

- **`use <name[@rev]>`** verifies the bundle's fingerprint, writes its
  manifest to `.claude/harness-os.json`, updates the lock, and (by
  default) clears `.claude/harness-os.state/` — a different OS has
  different roles, so cached bindings from the old one are stale.
  `--keep-state` preserves them when the role sets overlap.
- **No `@rev`** → the highest revision in the library wins, so
  `harness-os use qa-pipeline` tracks latest while
  `harness-os use qa-pipeline@1.0.0` pins.
- **Drift** is a first-class concept: edit the live manifest in place and
  `status` flags it against the lock's fingerprint, prompting you to
  either re-export (capture the change as a new revision) or re-apply the
  stored OS (discard the edit). Storage never silently diverges from what
  is running.
- **Tamper refusal**: a bundle whose recorded `fingerprint` no longer
  matches its embedded manifest is rejected on import/use — a hand-edited
  bundle cannot silently widen a role.

## Design intent

Ease of storage = one self-contained, schema-validated, fingerprinted
file per OS. Swappability = a machine-wide library keyed by
`name@revision`, a per-project lock that always knows which OS is live,
and a `use` that swaps atomically and resets the state that would
otherwise leak between role sets. The enforcement kernel stays a plain
manifest reader throughout, so none of this widens what a running OS can
do.
