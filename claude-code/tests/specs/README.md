# Inert specs of 0.2.x hooks that were not ported

Nothing in this folder runs. Each `*.sh` is the behaviour spec of a bash hook that 0.2.x shipped,
kept verbatim (it still names `$HOOK_DIR`, `hooks/lib/…` and the runtime it drove, none of which
exists any more). Every other spec became a kit test under `claude-code/tests/*.test.ts` or a node
test of a scanner under `claude-code/tests/lib/` and was deleted; the factory JSON cases live on as
`claude-code/tests/factory-cases.mjs`. What remains, and why:

| Spec | Hook it described | Why it is still here |
|---|---|---|
| `59-run-summary-writer.sh` | Stop: wrote `.achilles/run-summary.json` (run-summary/v2) for an external benchmark | The adapter carries a run summary line in each hand-back instead; no consumer of the JSON file ships with the package. Port it if a benchmark needs the file again (`schemas/run-summary.schema.json` is kept). |
| `67-perf-summary-writer.sh` | Stop: wrote `.achilles/perf-summary.json` (perf-summary/v1) | Same as 59, for the performance pipeline (`schemas/perf-summary.schema.json` is kept). |
| `75-self-repair-known-defect.sh` | none: the `@known-defect` no-rerun contract of `bin/self-repair.mjs` | Tests a CLI, not a hook; it belongs with the CLI's tests under `tests/bin/`, outside the adapter. |
| `76-compliance-sweep-exit-gate.sh` | Stop: blocked until the assistant's prose announced the Stage-4b compliance sweep | Detected the sweep by matching assistant prose, a weak signal a port would inherit. A port would keep a per-expert "spec written since the last sweep" flag and note it at the expert's turn end. |
| `78-client-term-guard.sh` | Write/Edit into this package's own repository: client names from an operator-local list | Contributor tooling for this repository, not consumer behaviour; a pre-commit check here is the better home. |
| `83-deck-inspection-gate.sh` | after `export-pdf.js`: render the deck's pages and hold dispatches until they were read | The qa-reporting skill renders and inspects the pages itself; a post-export note per expert is the port if it is needed. |
