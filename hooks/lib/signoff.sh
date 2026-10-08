# signoff.sh — which tracker surface a tool call is, shared by the two sign-off gates
# (adversarial-verification-gate.sh, evidence-bundle-gate.sh). Vendors differ; match shapes.

# Sets IS_TRANSITION / IS_COMMENT / IS_PR from a tool name; returns 1 for any other tool.
signoff_classify_tool() {
  IS_TRANSITION=0 IS_COMMENT=0 IS_PR=0
  case "$1" in
    *save_issue*|*transitionJiraIssue*|*update_issue*|*editJiraIssue*) IS_TRANSITION=1 ;;
    *save_comment*|*addCommentToJiraIssue*|*create_comment*)           IS_COMMENT=1 ;;
    # A developer-triggered run has no ticket; opening the PR is its sign-off boundary, so the
    # same check belongs there. Without it the entry-B path was ungated.
    Bash)                                                              IS_PR=1 ;;
    *) return 1 ;;
  esac
}
