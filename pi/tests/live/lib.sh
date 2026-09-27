# pi/tests/live/lib.sh — temp-HOME harness. Sourced by each live check.
# Requires: pi on PATH, local model reachable (default local vLLM on :8000).
# Never touches ~/.pi or ~/.claude.
set -uo pipefail
LIVE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIVE_MODEL="${ACHILLES_PI_TEST_MODEL:-local/unsloth/Qwen3.8-27B-NVFP4}"
LIVE_BASE_URL="${ACHILLES_PI_TEST_BASE_URL:-http://localhost:8000/v1}"
LIVE_TIMEOUT="${ACHILLES_PI_TEST_TIMEOUT:-180}"

live_skip() { echo "SKIP: $1"; exit 0; }
command -v pi >/dev/null || live_skip "pi not on PATH"
curl -s --max-time 3 "$LIVE_BASE_URL/models" >/dev/null || live_skip "model endpoint $LIVE_BASE_URL unreachable"

LIVE_HOME=$(mktemp -d /tmp/achilles-live-XXXXXX)
trap '[ "${ACHILLES_PI_KEEP_LIVE:-0}" = 1 ] || rm -rf "$LIVE_HOME"' EXIT
export HOME="$LIVE_HOME"
export PI_CODING_AGENT_DIR="$LIVE_HOME/.pi/agent"
export ACHILLES_PI_LOG="$LIVE_HOME/achilles-pi.log"
export ACHILLES_SESSION_STATE_DIR="$LIVE_HOME/.claude/achilles/sessions"
mkdir -p "$PI_CODING_AGENT_DIR" "$LIVE_HOME/project"
LIVE_PROJECT="$LIVE_HOME/project"
cat > "$PI_CODING_AGENT_DIR/models.json" <<JSON
{"providers":{"local":{"baseUrl":"$LIVE_BASE_URL","api":"openai-completions","apiKey":"local",
 "compat":{"supportsDeveloperRole":false,"supportsReasoningEffort":false,"thinkingFormat":"chat-template",
 "chatTemplateKwargs":{"enable_thinking":{"\$var":"thinking.enabled"}}},
 "models":[{"id":"${LIVE_MODEL#local/}","contextWindow":184320,"maxTokens":8192,"input":["text"],"reasoning":true}]}}}
JSON
# Hooks + lib + data into the fake ~/.claude/hooks through the real installer (require()'d, so the
# in-repo guard is bypassed). jq resolves from PATH inside the fake HOME.
CIVITAS_SKIP_JQ_INSTALL=1 node -e "require('$LIVE_REPO/scripts/postinstall.js').installCivitasHooks('$LIVE_HOME/.claude')" >/dev/null
node -e "require('$LIVE_REPO/scripts/postinstall.js').installAgentSkills('$LIVE_HOME')" >/dev/null

# live_pi <cwd> <prompt> [extra pi args...] — runs one headless JSON-mode turn with the extension loaded.
# Stdout: the JSONL event stream. Exit code: pi's.
# stdin is closed: `pi -p` reads piped stdin as extra prompt text, so a check launched with an open
# stdin pipe (a CI runner, a background shell) otherwise sits idle until the timeout instead of
# answering. agent-tool.ts closes it for the same reason when it spawns a child.
live_pi() {
  local cwd="$1"; shift; local prompt="$1"; shift
  ( cd "$cwd" && timeout "$LIVE_TIMEOUT" pi --mode json -p --no-session -a \
      -e "$LIVE_REPO/pi/extensions/achilles/index.ts" \
      --model "$LIVE_MODEL" --thinking off "$@" "$prompt" </dev/null )
}
live_pass() { echo "PASS: $1"; }
live_fail() { echo "FAIL: $1"; echo "--- log ---"; cat "$ACHILLES_PI_LOG" 2>/dev/null | tail -20; exit 1; }
