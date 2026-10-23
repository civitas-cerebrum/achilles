#!/usr/bin/env node
// Fails the publish (prepack) when the human-authored doc surfaces drift from
// the machine-authoritative sources they describe. One module per check in
// scripts/lint/, run in order; the process exits non-zero if any check fails.
//
//   1 registry          skill-registry table  ↔  skills/*/ directories
//   2 links             relative .md links under skills/ resolve
//   3 hook-manifest     hook-manifest.json entries valid  ↔  harness-hooks.md links
//   4 role-map          §4.4 validated description prefixes  ↔  schema-role-map.sh
//   5 hook-refs         deny/warn hooks cite resolvable References; cited paths exist
//   6 docs-counts       hand-written counts in docs/*.html  ↔  the filesystem
//   7 ledger-inventory  QA role ledger  ↔  QA mandate roles
//   8 opt-in-surfaces   env switches read in code  ↔  opt-in-surfaces.md
//   9 activation        skills/*/  ↔  ACHILLES_SKILL_ALT
//  10 agents            agents/*.md  ↔  QA mandate roles
//  11 anchors           every cited §"Heading" exists in the cited file
//  12 role-dispatch-sites  role names in skill/README prose  ↔  QA mandate roles
//  13 factory-manifest  hook-manifest.json .factory  ↔  hooks/factory/*.sh  ↔  harness-hooks.md
//  14 prose             em-dash density per file; banned stock phrases
//
// Where a surface has not yet converged the lint reports the specific drift
// rather than weakening the check.

import { makeReport } from './lint/util.mjs';
import * as registry from './lint/registry.mjs';
import * as links from './lint/links.mjs';
import * as hookManifest from './lint/hook-manifest.mjs';
import * as roleMap from './lint/role-map.mjs';
import * as hookRefs from './lint/hook-refs.mjs';
import * as docsCounts from './lint/docs-counts.mjs';
import * as ledgerInventory from './lint/ledger-inventory.mjs';
import * as optInSurfaces from './lint/opt-in-surfaces.mjs';
import * as activation from './lint/activation.mjs';
import * as agents from './lint/agents.mjs';
import * as anchors from './lint/anchors.mjs';
import * as roleDispatchSites from './lint/role-dispatch-sites.mjs';
import * as factoryManifest from './lint/factory-manifest.mjs';
import * as prose from './lint/prose.mjs';

const { report, state } = makeReport();
for (const check of [registry, links, hookManifest, roleMap, hookRefs, docsCounts,
  ledgerInventory, optInSurfaces, activation, agents, anchors, roleDispatchSites,
  factoryManifest, prose]) check.run(report);

if (state.failed) {
  console.error('\nlint-doc-drift: drift detected (see [FAIL] lines above).');
  process.exit(1);
}
console.log('\nlint-doc-drift: all checks passed.');
