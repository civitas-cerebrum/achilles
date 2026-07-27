# harness-atelier

**Context-flow observability for agentic harnesses.** harness-atelier shows you where an agent session's context actually went: how much each agent and subagent consumed, how context transferred between them (dispatch briefs down, returns up), which skills and tools filled the window, and — when an isolation contract was violated — **where exactly the leak happened**, down to the telemetry line, with the concrete fix next to it.

It was built alongside the [Achilles](https://github.com/civitas-cerebrum/achilles) agentic-OS role-privilege harness (where privilege hooks *enforce* the isolation contract and atelier *measures* it), but it is deliberately **harness-agnostic**: the integration surface is a five-event JSONL schema, not any particular agent framework. Anything that can append JSON lines to a file can be visualized here — Claude Code today, other coding agents tomorrow.

This directory is repo-shaped (own `package.json`, `LICENSE`, tests) so it can live inside Achilles or be severed into a standalone repository unchanged.

---

## How it works

```
┌────────────────────┐     appends      ┌───────────────────────────┐
│  emitter / adapter │ ───────────────► │ atelier-telemetry.jsonl   │
│  (e.g. Claude Code │  one JSON line   │ (5-event schema, below)   │
│   hooks in the     │  per context     └────────────┬──────────────┘
│   harness repo)    │  transfer                     │ reads
└────────────────────┘                               ▼
                                        ┌───────────────────────────┐
                                        │  harness-atelier.mjs      │
                                        │  (zero-dep node CLI)      │
                                        └────────────┬──────────────┘
                                          ┌──────────┴───────────┐
                                          ▼                      ▼
                                 harness-atelier.html      --json aggregate
                                 (self-contained report)   (CI assertions,
                                                            baselines)
```

Three pieces, two of which live with the harness being measured:

| Piece | Where it lives | What it does |
|---|---|---|
| **Visualizer** — `harness-atelier.mjs` | this directory | Zero-dependency node CLI. Aggregates a telemetry log into a self-contained HTML report and/or a JSON aggregate. Knows nothing about any specific harness. |
| **Collector** (adapter) | the harness repo (Achilles: `hooks/atelier-telemetry-collector.sh`) | A pure-observer Claude Code hook set (`PreToolUse:Agent`, `PostToolUse:Agent/Bash/Read\|Write\|Edit\|Grep\|Glob\|Skill\|WebFetch\|WebSearch`) that emits the event schema. Never blocks; best-effort writes. |
| **Auto-renderer** (adapter) | the harness repo (Achilles: `hooks/atelier-report-renderer.sh`) | A `Stop` hook that re-renders the report at session end whenever the telemetry is newer than the report, and picks up a pinned baseline automatically. |

Adapters live with their harness because *emitting* telemetry requires harness-specific knowledge (hook events, role resolution, payload shapes); *aggregating and rendering* it does not. Writing an adapter for another agent = writing the five event shapes below to a file. That's the whole contract.

---

## Quick start

**In an Achilles project** — telemetry collection is already on (the hooks install with the package). Open the report:

```sh
npm run atelier            # from the achilles repo, or:
node atelier/harness-atelier.mjs --project /path/to/project
open .achilles/harness-atelier.html
```

The `Stop` hook keeps the report fresh automatically at the end of every session — the manual render is only needed mid-session.

**In any other Claude Code project** — drop an opt-in marker at the repo root; the collector hooks (installed globally by Achilles) need nothing else:

```sh
touch .atelier
```

**With any other agent's log** — point the CLI at any file that follows the event schema:

```sh
node harness-atelier.mjs --telemetry /path/to/its/log.jsonl --out report.html
```

---

## The event schema (integration contract)

One JSON object per line. Every event carries `ts` (ISO-8601), `event`, `actor` (`"orchestrator"` or a subagent id), and `role` (free-form; `"unconfined"` when unknown). Five event types:

| `event` | Direction | Fields |
|---|---|---|
| `dispatch` | context **down** into a subagent | `tool_use_id`, `dispatch_role`, `brief_bytes` (prompt + description size), `description` (truncated) |
| `return` | context **up** into the dispatcher | `tool_use_id`, `dispatch_role`, `return_bytes`, optional `leak` |
| `command` | shell activity inside a context | `tool` (`"Bash"`), `bytes_out` (stdout ingested), `command_head`, optional `leak` |
| `skill` | instruction injection + segment marker | `skill` (name), `bytes_in`, `bytes_out` (injected instruction size) |
| `tool` | any other tool's ingestion | `tool` (name), `bytes_in`, `bytes_out` |

A `skill` event opens a **segment** for its actor: every later byte-bearing event by the same actor attributes to that skill until the actor's next `skill` event. That is how "context consumed by which skill/stage" is computed with no harness-specific knowledge.

A `leak` field is `{channel, evidence}` and can ride on `return` and `command` events (see channels below).

**Units.** Every `*_bytes` field is a **character count** (string length; ≈ bytes for ASCII). Field names keep the `_bytes` suffix for schema stability, but the report displays **estimated tokens** (`chars ÷ 4`) everywhere — tokens are the unit that actually bounds an agent's window — with raw chars on hover. The JSON aggregate declares this in `sizing` and carries `schema_version` so CI consumers can pin the shape.

Malformed lines are never silently dropped: they are counted (`telemetry_skipped_lines`), warned about in the report, and mentioned on the CLI's stdout line.

## Leak channels

| Channel | Meaning | Remediation shown in the report |
|---|---|---|
| `bash-ingest` | A payload dump actually executed in the orchestrator context | Dispatch a reader-role subagent to ingest the artifact and return a structured summary |
| `oversized-return` | A return exceeded the budget (`ATELIER_RETURN_BUDGET`, default 8000) — bulk content flowed up instead of a summary | Tighten the role's return schema / brief template |
| `pasted-source-return` | A return carried a fenced code block over 1200 chars | Brief the role to reference paths + line ranges, not paste content |

Every leak-panel entry cites channel, actor, role, evidence, the exact `telemetry.jsonl:<line>` it was recorded at, and its remediation.

## The report

- **Summary tiles** — session span, dispatches, brief ↓ / return ↑ (est. tokens), median return/brief ratio, orchestrator ingest, leak count.
- **Context budget & waste** — the headline: total orchestrator-window load with a per-source breakdown (briefs authored, returns ingested, bash stdout, tool ingest, skill injections), leaked size + waste share, and worst-offender tables (largest returns, largest per-context ingest).
- **vs baseline** — when `--baseline` is given: per-metric before/after/delta with regressed/improved verdicts.
- **Context-transfer map** — SVG flow, orchestrator ↔ agents, edge width ∝ size, leaking returns in red. Shows the 40 largest agents; the cap is stated when exceeded.
- **Agents / Execution contexts / Context by skill / Context impact by role / Tool mix** — the full tables behind the map.
- **Leak panel** — every leak with its line-exact pointer and remediation.
- **Return-schema validity** — joined from a `schema-guard-log.jsonl` when present (harness enrichment; degrades gracefully).

## CLI reference

```
node harness-atelier.mjs [--project <dir>] [--out <file>] [--telemetry <jsonl>] [--baseline <json>] [--json]
```

| Flag | Meaning |
|---|---|
| `--project <dir>` | Project root (default: cwd). Telemetry defaults to `<project>/.achilles/atelier-telemetry.jsonl`, report to `<project>/.achilles/harness-atelier.html`. |
| `--telemetry <file>` | Read any JSONL log following the event schema — the harness-agnostic entry point. |
| `--out <file>` | Report output path. |
| `--baseline <json>` | A prior `--json` aggregate to diff against (below). Unreadable baseline = exit 1, never a silent skip. |
| `--json` | Print the aggregate to stdout and skip HTML — the CI surface. |

## Baseline diffing

Pin a baseline after a known-good run, then diff every subsequent run against it:

```sh
node harness-atelier.mjs --project . --json > .achilles/atelier-baseline.json
# ... harness changes, another session ...
node harness-atelier.mjs --project . --json --baseline .achilles/atelier-baseline.json
```

Lower-is-better metrics (`leaks`, `leaked_bytes`, `leak_waste_share`, `orchestrator_bash_ingest_bytes`, `median_return_to_brief_ratio`) flag **regressed** when they grow and **improved** when they shrink. Volume metrics (`orchestrator_window_bytes`, brief/return totals, `dispatches`) are reported as context only — they move with the amount of work done. `baseline_comparison.regressions` lists regressed metric names; a CI job asserts it is empty. The Achilles `Stop` hook passes `--baseline` automatically whenever `.achilles/atelier-baseline.json` exists, so every session ends with the drift view already rendered.

## Writing an adapter for another agent

1. Find your agent's tool-call observation points (hooks, middleware, a log tailer — anything).
2. On each observation, append one event line to a JSONL file: `dispatch` when a subagent is spawned, `return` when it hands back, `command`/`tool` for ingestion, `skill` when a named instruction pack is loaded.
3. Point the CLI at the file with `--telemetry`.

Only `ts`/`event`/`actor` plus the per-event fields above are read; extra fields are ignored, so you can enrich events freely. Leak detection in your adapter is optional — the report degrades gracefully without `leak` objects (you lose the leak panel, keep everything else).

## Reading the metrics

A healthy harness shows: **small up-edges relative to work done** (returns are summaries — the median return/brief ratio stays low), **near-zero orchestrator bash ingest** while a pipeline is live, an **empty leak panel**, and a **waste share of 0%**. A fat red up-edge or a `bash-ingest` entry is the exact dispatch or command to fix — apply the entry's remediation at the source (brief template, return schema, role privileges) and re-run against your baseline.

## Development

```sh
npm test        # zero-dependency suite in test/run.mjs (needs node >= 18)
```

Inside Achilles, the same surface is additionally covered by the integration case `hooks/tests/cases/73-harness-atelier-cli.sh` (and `75-atelier-report-renderer.sh` for the Stop hook), which run in `npm run test:hooks`.

## Relationship to Achilles

This directory is designed to stand alone: everything harness-agnostic (visualizer, schema contract, docs, tests, license) is here; everything harness-specific (the Claude Code collector and Stop-renderer hooks, role resolution, install wiring) stays in the harness repo as its adapter. Severing = lifting this directory into its own repository; the Achilles hooks already resolve a `node_modules/harness-atelier` install path, so Achilles can then consume it as a dependency. The Achilles-side spec (`skills/element-interactions/references/harness-atelier.md`) documents the same contract from the harness's perspective.

## License

MIT
