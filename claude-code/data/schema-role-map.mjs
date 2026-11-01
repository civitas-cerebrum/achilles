// Agent role (the Agent tool's type, achilles-<role>) to the return schemas in
// schemas/subagent-returns/<schema>.schema.json it may hand back; the first is the default, the
// rest are picked when the brief names one. Read by the return-review hook.
export const SCHEMA_ROLES = {
  author: ['composer', 'repair-worker', 'probe', 'phase4-prioritise-author'],
  inspector: ['section-agent', 'probe'],
  reviewer: ['reviewer-inloop', 'workflow-reviewer', 'perf-reviewer'],
  'doc-writer': [],
}
