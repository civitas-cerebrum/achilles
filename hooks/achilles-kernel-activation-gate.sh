#!/bin/bash
# achilles-kernel-activation-gate.sh — binds the kernel-mandate role gate
#                                      to the achilles protocol lifecycle.
#
# Hook    : PreToolUse:.*  (registered in place of the raw kernel gate)
# Mode    : PASS-THROUGH — this file decides NOTHING about a tool call.
#           It decides only WHETHER THE KERNEL IS CONSULTED, then relays
#           the kernel's verdict byte-for-byte.
# State   : none (reads the activation marker via lib/achilles-activation.sh)
# Env     : ACHILLES_PROTOCOL=0|1 (activation suppression / forcing —
#           the same seam every other achilles gate honours)
#
# Why
# ---
# The kernel is a general-purpose role OS: point it at a manifest and it
# governs every tool call in the project, forever. That is the right
# behaviour for a project that deliberately adopted a mandate, and the
# wrong behaviour for a project that merely installed a test framework.
# Shipping the kernel registered unconditionally would mean `npm i
# @civitas-cerebrum/achilles` silently placed every future session in
# that project under a mandate nobody asked for.
#
# So authority follows a deliberate act. The achilles protocol activates
# when a person invokes an achilles skill, types /<skill>, or dispatches
# a role-prefixed subagent — and only from that moment does the mandate
# bind. When the pipeline reaches a terminal status, or the session ends,
# the mandate lifts with it. A session that never runs QA never feels it.
#
# This also answers the cost objection honestly: an unregistered kernel
# is free, and a dormant one costs a single marker stat rather than a
# manifest parse and a scope resolution on every tool call.
#
# What this file must never do
# ----------------------------
# 1. **Decide.** It has no policy. If the protocol is active, the kernel's
#    answer is the answer. If a future maintainer is tempted to add "…but
#    allow X" here, that belongs in the mandate, where it is declared,
#    validated and logged.
# 2. **Swallow a non-zero exit.** The kernel signals an internal error by
#    exiting non-zero with no stdout, and a wrapper that normalises that
#    to 0 converts "the gate broke" into "the gate permitted" — the exact
#    failure the kernel's own exit trap exists to prevent. The status is
#    relayed unchanged.
#
# Failure → action
# ----------------
# Kernel script missing → exit 0 (nothing to consult; achilles' own gates
# still apply). Kernel present → its verdict and its exit status, verbatim.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HOOK_DIR/lib/achilles-activation.sh"

INPUT=$(cat)

# Dormant: the achilles protocol is not in play in this session. The
# mandate exists on disk but binds nothing. Silent allow.
achilles_session_active "$INPUT" || exit 0

KERNEL="$HOOK_DIR/kernel-mandate-role-gate.sh"
[ -f "$KERNEL" ] || exit 0

# Relay: the kernel's stdout IS this hook's stdout, and its exit status
# IS this hook's exit status. No interpretation, no normalisation.
printf '%s' "$INPUT" | bash "$KERNEL"
exit $?
