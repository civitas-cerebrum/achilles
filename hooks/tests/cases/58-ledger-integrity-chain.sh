#!/bin/bash
# Tests for ledger-integrity-chain.sh — tamper-evident hash chain for the
# onboarding status ledger. PreToolUse (verify) + PostToolUse (record) on
# Write|Edit. Sidecar: tests/e2e/docs/.ledger-integrity.json.
H="$HOOK_DIR/ledger-integrity-chain.sh"

# shellcheck disable=SC1091
. "$HOOK_DIR/lib/hash.sh"

TMP_CHAIN=$(mktemp -d /tmp/ledger-integrity-chain-XXXXXX)
mkdir -p "$TMP_CHAIN/tests/e2e/docs"
trap 'rm -rf "$TMP_CHAIN"' EXIT

CHAIN_LEDGER="$TMP_CHAIN/tests/e2e/docs/onboarding-status.json"
CHAIN_SIDECAR="$TMP_CHAIN/tests/e2e/docs/.ledger-integrity.json"
FIXTURE="$HOOK_DIR/../schemas/onboarding-status.fixtures/valid-fresh-run.json"

reset_chain_fixture() {
  cp "$FIXTURE" "$CHAIN_LEDGER"
  rm -f "$CHAIN_SIDECAR"
}

# ---------------------------------------------------------------------------
section "ledger-integrity-chain: tool / path filtering"
reset_chain_fixture
assert_allow "$H" "$(payload tool_name=Bash command='ls' hook_event_name=PreToolUse)" \
  "Bash → silent allow (not a Write/Edit)"
assert_allow "$H" "$(payload tool_name=Write file_path="$TMP_CHAIN/somewhere/else.json" content='x' hook_event_name=PreToolUse)" \
  "Write to unrelated path → silent allow"

# ---------------------------------------------------------------------------
section "ledger-integrity-chain: record on PostToolUse"
reset_chain_fixture
assert_allow "$H" "$(payload tool_name=Write file_path="$CHAIN_LEDGER" content='x' hook_event_name=PostToolUse cwd="$TMP_CHAIN")" \
  "PostToolUse Write → silent (record path emits nothing)"

# Sidecar must now exist and its latest record must equal the on-disk hash.
TESTS_RUN=$((TESTS_RUN + 1))
recorded=$("$JQ" -r '.records[-1].sha256 // empty' "$CHAIN_SIDECAR" 2>/dev/null)
actual=$(file_sha256 "$CHAIN_LEDGER")
if [ -f "$CHAIN_SIDECAR" ] && [ -n "$recorded" ] && [ "$recorded" = "$actual" ]; then
  TESTS_PASSED=$((TESTS_PASSED + 1))
  echo "${CLR_PASS}  ✓${CLR_RST} PostToolUse record → sidecar created with matching sha256"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAIL_DETAILS+=("PostToolUse record: sidecar missing or hash mismatch. recorded='${recorded}' actual='${actual}'")
  echo "${CLR_FAIL}  ✗${CLR_RST} PostToolUse record → sidecar created with matching sha256"
fi

# ---------------------------------------------------------------------------
section "ledger-integrity-chain: verify pass on PreToolUse (chain intact)"
# Sidecar from the record above still matches the on-disk ledger.
assert_allow "$H" "$(payload tool_name=Write file_path="$CHAIN_LEDGER" content='x' hook_event_name=PreToolUse cwd="$TMP_CHAIN")" \
  "PreToolUse with matching chain → ALLOW"

# ---------------------------------------------------------------------------
section "ledger-integrity-chain: out-of-band mutation DENIED on PreToolUse"
# Simulate an out-of-band write: append a byte directly (no hooks fired).
printf ' ' >> "$CHAIN_LEDGER"
assert_deny "$H" "$(payload tool_name=Write file_path="$CHAIN_LEDGER" content='x' hook_event_name=PreToolUse cwd="$TMP_CHAIN")" \
  "PreToolUse after out-of-band append → DENY" "out of band"
assert_deny "$H" "$(payload tool_name=Edit file_path="$CHAIN_LEDGER" old_string='a' new_string='b' hook_event_name=PreToolUse cwd="$TMP_CHAIN")" \
  "Edit PreToolUse after out-of-band append → DENY" "out of band"

# ---------------------------------------------------------------------------
section "ledger-integrity-chain: rm-trick (ledger deleted, sidecar survives)"
rm -f "$CHAIN_LEDGER"
assert_deny "$H" "$(payload tool_name=Write file_path="$CHAIN_LEDGER" content='x' hook_event_name=PreToolUse cwd="$TMP_CHAIN")" \
  "PreToolUse with deleted ledger + surviving sidecar → DENY" "deleted"

# ---------------------------------------------------------------------------
section "ledger-integrity-chain: bootstrap (ledger present, no sidecar)"
reset_chain_fixture
assert_allow "$H" "$(payload tool_name=Write file_path="$CHAIN_LEDGER" content='x' hook_event_name=PreToolUse cwd="$TMP_CHAIN")" \
  "PreToolUse with no sidecar → ALLOW (bootstrap)"

# ---------------------------------------------------------------------------
section "ledger-integrity-chain: write-failure tolerance (records[-2] matches)"
# Simulate a sanctioned write whose Post record landed but the write itself
# was then rolled back / superseded: latest record is stale, but the
# second-to-last record matches the on-disk content.
reset_chain_fixture
good_hash=$(file_sha256 "$CHAIN_LEDGER")
printf '%s' "{\"records\":[{\"sha256\":\"$good_hash\",\"ts\":1},{\"sha256\":\"deadbeef-not-matching\",\"ts\":2}]}" > "$CHAIN_SIDECAR"
assert_allow "$H" "$(payload tool_name=Write file_path="$CHAIN_LEDGER" content='x' hook_event_name=PreToolUse cwd="$TMP_CHAIN")" \
  "PreToolUse where records[-2] matches → ALLOW (write-failure tolerance)"

# ---------------------------------------------------------------------------
section "ledger-integrity-chain: sidecar itself is not writable via Write/Edit"
reset_chain_fixture
assert_deny "$H" "$(payload tool_name=Write file_path="$CHAIN_SIDECAR" content='{}' hook_event_name=PreToolUse cwd="$TMP_CHAIN")" \
  "direct Write to the sidecar → DENY" "hook-authored"

rm -rf "$TMP_CHAIN"
