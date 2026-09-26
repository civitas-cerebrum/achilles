#!/bin/bash
# Blocks a subagent's stop unless the payload says a stop hook already blocked once.
in=$(cat)
case "$in" in *'"stop_hook_active":true'*) exit 0 ;; esac
echo '{"decision":"block","reason":"subagent: finish the review first"}'
