---
name: achilles
description: >
  Use whenever the user asks for testing work: "test the app", "test this", "write tests", "add tests",
  "e2e tests", "Playwright tests", "browser testing", "QA", "smoke test", "regression test", "test coverage",
  "the test failed", "CI is red", "find bugs", or names @civitas-cerebrum/element-interactions. Routes the
  request to the Achilles QA protocol when this project has Achilles installed, and otherwise tells the user
  how to install it.
---

# Achilles (router)

A local `npm i -D @civitas-cerebrum/achilles` installs Achilles into that project's `.claude/` and only this
routing skill user-level. It decides whether the protocol can run here.

1. From the project root, check whether `.claude/skills/achilles-protocol/SKILL.md` exists.
2. It exists: invoke the `achilles-protocol` skill now and follow it. This skill adds nothing further.
3. It does not: Achilles is not installed in this project, so its hooks are absent and nothing it requires
   would be enforced. Do not invoke `achilles-protocol` or any other Achilles skill. Tell the user:

   > Achilles is not installed in this project. Install it here with `npm i -D @civitas-cerebrum/achilles`,
   > or for every project with `npm i -g @civitas-cerebrum/achilles`, then restart Claude Code.

   Then handle the request without Achilles only if the user asks you to.
