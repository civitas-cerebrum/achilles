// The pipeline-state files an achilles agent edits only through Write/Edit (so the ledger hook
// runs), never through a shell redirect, tee, sed -i or rm. The Bash judge advises on a shell
// write to one of these; the names are matched as whole words under the ledger docs dirs.
export const LEDGER_DOCS_DIRS = ['tests/e2e/docs', 'tests/perf/docs']
export const PROTECTED_FILES = [
  'onboarding-status.json',
  'perf-onboarding-status.json',
  'journey-map.md',
  '.phase4-cycle-state.json',
  'coverage-expansion-state.json',
  'adversarial-findings.md',
  'flake-quarantine.md',
]
