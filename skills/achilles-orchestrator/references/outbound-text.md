# Outbound text: no AI signatures

Everything a run sends outside itself is written as the QA work, not as an agent's output. That
covers commits, pull request titles and descriptions, issue and PR comments and reviews, tracker
tickets and comments, wiki pages, chat messages, and the reports and evidence summaries a person
will read or forward.

This is the canonical home of the rule; other files cite it.

## What is forbidden

**AI signatures**, in any of those surfaces:

- AI co-author trailers: `Co-Authored-By: Claude …`, any `Co-Authored-By` naming an AI or `noreply@anthropic.com`;
- session links and trailers: `Claude-Session: …`, any `claude.ai/code` URL;
- "generated with" footers: `Generated with Claude Code`, `🤖 Generated with …`.

A human co-author trailer is fine. So is prose that mentions a product name for a reason the work
needs, such as a changelog entry about a tool.

**Agent framing** in tickets, comments and reports:

- the text presenting itself as an agent's output: "a separate QA agent confirmed", "as an AI";
- a brief pasted as a template: "You are an independent QA reproducer…";
- the harness's internals as the reader's business: experts, the orchestrator, run ids, briefs,
  `.achilles/` paths, "the knowledge base", "the mocks".

Write what was done and what was found: "an independent second QA pass reproduced it", "reproduction
checklist", "the e2e test TCCL-270918 covers it". The reader is deciding what to fix, not auditing
who typed it.

## Why

A signature turns a QA finding into a statement about tooling. Readers outside the team discount it,
forward it with the signature attached, and argue about the tool instead of the defect. A tracker
comment, once posted, is also copied into notifications and emails that cannot be edited later.

Harness defaults may add an attribution line on their own. This rule overrides them for every
Achilles run.

## How it is enforced

Where the harness can see the write, a signature is refused before it leaves, and agent framing in an
outbound message gets a note ([`docs/harness/claude-code.md`](../../../docs/harness/claude-code.md):
the Bash judge for commits, `gh pr` and `gh issue`; the outbound check for tracker, page and chat
writes and for report documents). The rule binds where no hook reaches too: an expert drafting text
for the main session to post writes it without a signature or framing.
