#!/usr/bin/env node
// Fails the publish (prepack) when the human-authored doc surfaces drift from
// the sources they describe. One module per check in scripts/lint/, run in
// order; the process exits non-zero if any check fails.
//
//   1 registry            skills/*/ ↔ the orchestrator's routing (frontmatter name = dir name)
//   2 links               relative links under skills/, docs/, CONTRIBUTING.md resolve
//   5 hook-refs           adapter sources cite resolvable skills/ and schemas/ paths (when claude-code/ exists)
//   6 docs-counts         hand-written counts in docs/*.html ↔ the tree
//   8 opt-in-surfaces     env switches read by the adapter and CLIs ↔ docs/harness/claude-code.md
//  10 agents              agents/*.md ↔ the five roles; tools ↔ the Agents table in docs/harness/claude-code.md
//  11 anchors             every cited §"Heading" exists in the cited file
//  12 role-dispatch-sites role names in prose ↔ the five agents; no dispatch-prefix grammar
//  14 prose               em-dash density per file; banned stock phrases
//
// Checks 3, 4, 7, 9 and 13 (hook manifest, role map, mandate ledger, activation
// list, factory manifest) left with the bash hook runtime and the role kernel
// in 0.3.0. Where a surface has not yet converged the lint reports the
// specific drift rather than weakening the check.

import { makeReport } from './lint/util.mjs';
import * as registry from './lint/registry.mjs';
import * as links from './lint/links.mjs';
import * as hookRefs from './lint/hook-refs.mjs';
import * as docsCounts from './lint/docs-counts.mjs';
import * as optInSurfaces from './lint/opt-in-surfaces.mjs';
import * as agents from './lint/agents.mjs';
import * as anchors from './lint/anchors.mjs';
import * as roleDispatchSites from './lint/role-dispatch-sites.mjs';
import * as prose from './lint/prose.mjs';

const { report, state } = makeReport();
for (const check of [registry, links, hookRefs, docsCounts, optInSurfaces, agents, anchors, roleDispatchSites, prose]) check.run(report);

if (state.failed) {
  console.error('\nlint-doc-drift: drift detected (see [FAIL] lines above).');
  process.exit(1);
}
console.log('\nlint-doc-drift: all checks passed.');
