#!/bin/bash
# Fixture: the real playwright-artifact-archiver warning shape; ARCHIVE_RUN sets the run id.
cat >/dev/null
J='{"systemMessage": "[WARN] Playwright evidence archived to .achilles/runs/__RUN__ with omissions.\n\nPruned 1 older run(s) past ACHILLES_ARTIFACT_RETAIN=5: 20260926T105516Z. Raise ACHILLES_ARTIFACT_RETAIN to keep more.\n\nReferences:\n  skills/achilles-protocol/references/harness-hooks.md §PostToolUse\n  .achilles/runs/__RUN__/manifest.json"}'
printf '%s' "${J//__RUN__/${ARCHIVE_RUN:-20260926T110721Z}}"
