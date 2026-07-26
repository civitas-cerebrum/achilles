# harness-atelier — context-flow observability

**Status:** authoritative spec for the harness-atelier telemetry + visualizer pair.
**Scope:** what is recorded, the event schema, the leak channels, the metrics the report computes, and how to run the visualizer.

harness-atelier is a **general-purpose harness observability utility** — built alongside the agentic-OS role-privilege harness but not tied to it. It visualizes how much context each agent and subagent uses, how context transfers between them, which skills consume the context, how the session unfolds over time, and — when an isolation contract is violated — where exactly the leak happened, down to the telemetry line.

Use it with achilles (where the privilege hooks *enforce* the isolation contract and atelier *measures* it — see [`agentic-os-roles.md`](agentic-os-roles.md)), with any other Claude Code experiment (drop a `.atelier` marker file at the repo root to opt in — the collector needs nothing else), or with any other coding agent that emits the JSONL event schema below (point the CLI at its log with `--telemetry <file>`). The event schema is the integration contract; nothing in the collector's output or the visualizer's aggregation assumes achilles.

---

## Architecture

| Piece | What it does |
|---|---|
| [`../../../hooks/atelier-telemetry-collector.sh`](../../../hooks/atelier-telemetry-collector.sh) | Pure observer hook (`PreToolUse:Agent`, `PostToolUse:Agent`, `PostToolUse:Bash`, `PostToolUse:Read\|Write\|Edit\|Grep\|Glob\|Skill\|WebFetch\|WebSearch`; never blocks, best-effort writes). Appends one JSON line per context transfer to `<project>/.achilles/atelier-telemetry.jsonl`. Opt-in per project: achilles project, `.atelier` marker file, or `ATELIER_TELEMETRY=on`; off switch: `ATELIER_TELEMETRY=off`. |
| [`../../../scripts/atelier/harness-atelier.mjs`](../../../scripts/atelier/harness-atelier.mjs) | Zero-dependency Node CLI (`npm run atelier`, or `node scripts/atelier/harness-atelier.mjs [--project <dir>] [--out <file>] [--telemetry <jsonl>] [--json]`). Aggregates the telemetry (plus `schema-guard-log.jsonl` and the agentic-OS process table when present) into a self-contained HTML report at `<project>/.achilles/harness-atelier.html`; `--json` emits the aggregate for CI; `--telemetry` points at any agent's log, making the CLI harness-agnostic. |

## What gets recorded

Every event carries `ts`, `event`, `actor` (`orchestrator` or the subagent's `agent_id`), and `role` (resolved through the same ladder the privilege guard uses — shared `lib/agent-process-table.sh`).

- **`dispatch`** (`PreToolUse:Agent`) — context flowing **down**: `tool_use_id`, `dispatch_role` (from the description prefix), `brief_bytes` (prompt + description size), truncated `description`. A dispatch issued from inside a subagent context records that agent as the actor — nested fan-out is visible, not just denied.
- **`return`** (`PostToolUse:Agent`) — context flowing **up**: `return_bytes` (the payload landing in the orchestrator window) and, when the return violates "structured summary only", a `leak` object.
- **`command`** (`PostToolUse:Bash`) — per-context activity: `bytes_out` (stdout ingested by the executing context), `command_head`, and for orchestrator-context payload dumps a `leak` object.
- **`skill`** (`PostToolUse:Skill`) — a Skill invocation: `skill` name and `bytes_out` (the instruction content it injected). Skill events open a **segment** for their actor: every later byte-bearing event by the same actor attributes to that skill until the next skill event — this is how "context consumed by which skill / stage" is computed, with no harness-specific knowledge.
- **`tool`** (`PostToolUse` on the generic matchers) — context ingestion by any other tool (Read/Grep/Glob/WebFetch/…): `tool`, `bytes_in`, `bytes_out`.

This five-event schema is the **integration contract**: any coding agent (Claude Code or otherwise) that writes these JSON lines can be visualized by the CLI via `--telemetry` — the collector hook is just the Claude Code adapter.

**Units.** Every `*_bytes` field is a **character count** (string length; ≈ bytes for ASCII payloads). The field names keep the `_bytes` suffix for schema stability, but the report displays **estimated tokens** (`chars ÷ 4`) everywhere — tokens are the unit that actually bounds an agent's window — with raw char counts on hover and alongside. The `--json` aggregate declares this in `sizing` (`{unit: "chars", chars_per_token_estimate: 4}`) and carries `schema_version` so CI consumers can pin the shape. Malformed telemetry lines are never silently dropped: the aggregate reports `telemetry_skipped_lines` / `schema_log_skipped_lines`, the report shows an undercount warning, and the CLI's stdout line says how many were skipped.

## Leak channels

| Channel | Meaning |
|---|---|
| `bash-ingest` | A payload dump (dump command × payload artifact — same detector vocabulary as the privilege guard) **actually executed** in the orchestrator context (guard off, or a pre-guard build). The event's evidence is the command itself. |
| `oversized-return` | A subagent return exceeded the return budget (`ATELIER_RETURN_BUDGET`, default 8000 bytes) — bulk content flowing up instead of a structured summary. |
| `pasted-source-return` | A return carried a fenced code block over 1200 chars — pasted test source / transcript inside the return channel. |

Each leak in the report's **leak panel** cites its channel, actor, role, evidence, the exact `atelier-telemetry.jsonl:<line>` it was recorded at — the "where exactly" pointer for harness development — and a per-channel **remediation**: the concrete contract fix for that channel (dispatch a reader-role subagent instead of dumping; tighten the return schema/brief; reference paths instead of pasting source).

## What the report shows

- **Summary tiles** — session span, dispatches, total brief ↓ and return ↑ (estimated tokens), median return/brief ratio, orchestrator total ingest, leak count.
- **Context budget & waste** — the headline the whole harness exists to protect: the orchestrator-window load (briefs authored ↓ + returns ingested ↑ + its own Bash stdout, tool ingest, and skill injections, with a per-source breakdown), how much of it was **leak waste** (the full size of each leaking transfer) and the resulting waste share, plus **worst-offender** tables (largest returns, largest per-context ingest) — the first places to fix. In `--json`: `orchestrator_window_bytes`/`_tokens_est`, `leaked_bytes`/`_tokens_est`, `leak_waste_share`, `worst_offenders`.
- **Context-transfer map** — SVG flow: orchestrator on the left, one node per agent on the right; down-edges sized by brief size, up-edges by return size; leaking returns render red. Shows the 40 largest agents by context volume; when telemetry has more, the cap and the full count are stated under the map (the Agents table always lists everything).
- **Agents table** — per dispatch: role, brief ↓, return ↑, compression ratio, leak flag.
- **Execution contexts table** — per actor: command count, Bash ingest, tool calls, tool ingest, skill injections, and total ingest — the complete per-context ingest picture, not just Bash.
- **Context by skill** — per skill: invocations, injected bytes (the skill's own instruction content), attributed bytes (everything its segment then consumed — briefs, returns, command stdout, tool ingestion), dispatches initiated.
- **Context impact by role (pipeline stage)** — per dispatch role: dispatches, brief ↓ / return ↑ totals, compression ratio, leak count. For a pipeline harness the roles are the stages (composer/reviewer/probe map to passes), so this is the per-stage context-impact view.
- **Tool mix** — bytes ingested per tool (Read vs Grep vs WebFetch …), the "what is actually filling the window" breakdown.
- **Session** — start → end timestamps and duration, in the header and tiles.
- **Return-schema validity** — per-role valid/invalid counts joined from `.achilles/schema-guard-log.jsonl` when present (achilles enrichment; absent for other harnesses, and the report degrades gracefully).

## Reading the metrics

A healthy harness shows: **small up-edges relative to the work done** (returns are summaries — the median return/brief ratio stays low), **near-zero orchestrator Bash ingest** while a pipeline is live, an **empty leak panel**, and **high per-role schema validity**. A fat red up-edge or a `bash-ingest` entry is the exact dispatch/command to fix — tighten that role's brief template, return schema, or privilege set and re-run.

## Effectiveness workflow

1. Run the harness normally (collector records passively).
2. `npm run atelier` → open `.achilles/harness-atelier.html`.
3. For each leak-panel entry, open the cited telemetry line, identify the dispatch or command, and fix the contract at the source (brief template, return schema, role privileges).
4. Re-run and compare tiles — leak count and ingest volume are the regression signal; `--json` output makes them CI-assertable.
