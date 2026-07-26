# harness-atelier — context-flow observability

**Status:** authoritative spec for the harness-atelier telemetry + visualizer pair.
**Scope:** what is recorded, the event schema, the leak channels, the metrics the report computes, and how to run the visualizer.

harness-atelier is the observability companion to the agentic-OS role-privilege harness ([`agentic-os-roles.md`](agentic-os-roles.md)): the privilege hooks *enforce* the context-isolation contract; atelier *measures* it. It visualizes how much context each agent and subagent uses, how context transfers between them, and — when the contract is violated — where exactly the leak happened, down to the telemetry line.

---

## Architecture

| Piece | What it does |
|---|---|
| [`../../../hooks/atelier-telemetry-collector.sh`](../../../hooks/atelier-telemetry-collector.sh) | Pure observer hook (`PreToolUse:Agent`, `PostToolUse:Agent`, `PostToolUse:Bash`; never blocks, best-effort writes). Appends one JSON line per context transfer to `<project>/.achilles/atelier-telemetry.jsonl`. Off switch: `ATELIER_TELEMETRY=off`. |
| [`../../../scripts/atelier/harness-atelier.mjs`](../../../scripts/atelier/harness-atelier.mjs) | Zero-dependency Node CLI (`npm run atelier`, or `node scripts/atelier/harness-atelier.mjs [--project <dir>] [--out <file>] [--json]`). Aggregates the telemetry (plus `schema-guard-log.jsonl` and the agentic-OS process table) into a self-contained HTML report at `<project>/.achilles/harness-atelier.html`; `--json` emits the aggregate for CI. |

## What gets recorded

Every event carries `ts`, `event`, `actor` (`orchestrator` or the subagent's `agent_id`), and `role` (resolved through the same ladder the privilege guard uses — shared `lib/agent-process-table.sh`).

- **`dispatch`** (`PreToolUse:Agent`) — context flowing **down**: `tool_use_id`, `dispatch_role` (from the description prefix), `brief_bytes` (prompt + description size), truncated `description`. A dispatch issued from inside a subagent context records that agent as the actor — nested fan-out is visible, not just denied.
- **`return`** (`PostToolUse:Agent`) — context flowing **up**: `return_bytes` (the payload landing in the orchestrator window) and, when the return violates "structured summary only", a `leak` object.
- **`command`** (`PostToolUse:Bash`) — per-context activity: `bytes_out` (stdout ingested by the executing context), `command_head`, and for orchestrator-context payload dumps a `leak` object.

## Leak channels

| Channel | Meaning |
|---|---|
| `bash-ingest` | A payload dump (dump command × payload artifact — same detector vocabulary as the privilege guard) **actually executed** in the orchestrator context (guard off, or a pre-guard build). The event's evidence is the command itself. |
| `oversized-return` | A subagent return exceeded the return budget (`ATELIER_RETURN_BUDGET`, default 8000 bytes) — bulk content flowing up instead of a structured summary. |
| `pasted-source-return` | A return carried a fenced code block over 1200 chars — pasted test source / transcript inside the return channel. |

Each leak in the report's **leak panel** cites its channel, actor, role, evidence, and the exact `atelier-telemetry.jsonl:<line>` it was recorded at — the "where exactly" pointer for harness development.

## What the report shows

- **Summary tiles** — dispatches, total brief bytes ↓, total return bytes ↑, median return/brief ratio, orchestrator Bash ingest volume, leak count.
- **Context-transfer map** — SVG flow: orchestrator on the left, one node per agent on the right; down-edges sized by brief bytes, up-edges by return bytes; leaking returns render red.
- **Agents table** — per dispatch: role, brief ↓, return ↑, compression ratio, leak flag.
- **Execution contexts table** — per actor: command count and stdout bytes ingested.
- **Return-schema validity** — per-role valid/invalid counts joined from `.achilles/schema-guard-log.jsonl` (the schema guard's calibration log).

## Reading the metrics

A healthy harness shows: **small up-edges relative to the work done** (returns are summaries — the median return/brief ratio stays low), **near-zero orchestrator Bash ingest** while a pipeline is live, an **empty leak panel**, and **high per-role schema validity**. A fat red up-edge or a `bash-ingest` entry is the exact dispatch/command to fix — tighten that role's brief template, return schema, or privilege set and re-run.

## Effectiveness workflow

1. Run the harness normally (collector records passively).
2. `npm run atelier` → open `.achilles/harness-atelier.html`.
3. For each leak-panel entry, open the cited telemetry line, identify the dispatch or command, and fix the contract at the source (brief template, return schema, role privileges).
4. Re-run and compare tiles — leak count and ingest volume are the regression signal; `--json` output makes them CI-assertable.
