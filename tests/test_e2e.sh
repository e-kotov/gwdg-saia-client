#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# SAIA CLI End-to-End Test Suite
# Tests all requirements and acceptance criteria from MULTI_DOMAIN_SUPPORT_PROPOSAL.md
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SAIA_BIN="$WORKSPACE_DIR/saia.sh"
TEST_TMP_DIR="$SCRIPT_DIR/tmp_test_env"

cd "$WORKSPACE_DIR"

PASSED_COUNT=0
FAILED_COUNT=0

# Colors for test output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

cleanup() {
  rm -rf "$TEST_TMP_DIR"
  rm -f "$WORKSPACE_DIR/generated_image.png" "$WORKSPACE_DIR/edited_image.png"
}
trap cleanup EXIT

rm -rf "$TEST_TMP_DIR"
mkdir -p "$TEST_TMP_DIR/bin"

CURL_LOG="$TEST_TMP_DIR/curl_invocations.log"
MOCK_CURL="$TEST_TMP_DIR/bin/curl"

cat << 'EOF' > "$MOCK_CURL"
#!/usr/bin/env bash
# Record every invocation into log file on a single line
LOG_FILE="${TEST_CURL_LOG:-/tmp/curl_invocations.log}"
echo "$*" | tr '\n' ' ' >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# Find target URL in arguments
TARGET_URL=""
for arg in "$@"; do
  if [[ "$arg" =~ ^https?:// ]]; then
    TARGET_URL="$arg"
    break
  fi
done

# Route mock response based on URL and options
if [[ "$TARGET_URL" == */models ]]; then
  echo '{"data": [{"id": "meta-llama-3.1-8b-instruct"}, {"id": "deepseek-r1-distill-llama-70b"}, {"id": "qwen2.5-coder-32b-instruct"}]}'
  exit 0
fi

if [[ "$TARGET_URL" == */chat/completions ]]; then
  # Check if limits probe (-i flag passed and max_tokens / "." prompt)
  if [[ "$*" == *"-i"* ]] && [[ "$*" == *"max_tokens"* ]]; then
    if [[ "$TARGET_URL" == *"/no-headers"* ]]; then
      # Response with no ratelimit headers
      printf "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"choices\":[{\"message\":{\"content\":\".\"}}]}"
      exit 0
    fi
    printf "HTTP/1.1 200 OK\r\n"
    printf "Content-Type: application/json\r\n"
    printf "x-ratelimit-limit-minute: 30\r\n"
    printf "x-ratelimit-remaining-minute: 29\r\n"
    printf "x-ratelimit-limit-hour: 200\r\n"
    printf "x-ratelimit-remaining-hour: 199\r\n"
    printf "x-ratelimit-limit-day: 1000\r\n"
    printf "x-ratelimit-remaining-day: 999\r\n"
    printf "x-ratelimit-limit-month: 3000\r\n"
    printf "x-ratelimit-remaining-month: 2999\r\n"
    printf "x-ratelimit-reset-minute: 45\r\n"
    printf "\r\n"
    printf "{\"choices\":[{\"message\":{\"content\":\".\"}}]}"
    exit 0
  fi

  if [[ "$*" == *"error_trigger"* ]]; then
    echo '{"error": {"message": "Invalid prompt parameter"}}'
    exit 0
  fi

  if [[ "$*" == *"empty_response"* ]]; then
    exit 0
  fi

  if [[ "$*" == *"arcana"* ]]; then
    echo '{"choices": [{"message": {"role": "assistant", "content": "Arcana response content"}}]}'
    exit 0
  fi

  echo '{"choices": [{"message": {"role": "assistant", "content": "Chat response from mock server"}}]}'
  exit 0
fi

if [[ "$TARGET_URL" == */completions ]]; then
  echo '{"choices": [{"text": "Text completion response"}]}'
  exit 0
fi

if [[ "$TARGET_URL" == */embeddings ]]; then
  echo '{"data": [{"embedding": [0.123, 0.456, 0.789]}]}'
  exit 0
fi

if [[ "$TARGET_URL" == */documents/convert ]]; then
  echo '{"markdown": "# Converted Document Title\n\nDocument body content"}'
  exit 0
fi

if [[ "$TARGET_URL" == */audio/* ]]; then
  echo "Transcription: Hello audio world"
  exit 0
fi

if [[ "$TARGET_URL" == */images/generations ]]; then
  # Returns base64 encoded "PNG_DATA_MOCK"
  b64_dummy=$(printf "PNG_DATA_MOCK" | base64)
  echo "{\"data\": [{\"b64_json\": \"$b64_dummy\"}]}"
  exit 0
fi

if [[ "$TARGET_URL" == */images/edits* ]]; then
  # Writes output file if -o passed
  output_file=""
  prev=""
  for a in "$@"; do
    if [ "$prev" = "-o" ]; then
      output_file="$a"
      break
    fi
    prev="$a"
  done
  if [ -n "$output_file" ]; then
    echo "EDITED_PNG_MOCK" > "$output_file"
  fi
  exit 0
fi

echo "{\"error\": \"Unhandled mock route: $TARGET_URL\"}"
exit 1
EOF
chmod +x "$MOCK_CURL"

# Prepend mock bin to PATH and set test log
export PATH="$TEST_TMP_DIR/bin:$PATH"
export TEST_CURL_LOG="$CURL_LOG"
export SAIA_API_KEY="test_api_key"

assert_equals() {
  local expected="$1"
  local actual="$2"
  local desc="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "  [${GREEN}PASS${NC}] $desc"
    PASSED_COUNT=$((PASSED_COUNT + 1))
  else
    echo -e "  [${RED}FAIL${NC}] $desc"
    echo "    Expected: '$expected'"
    echo "    Actual:   '$actual'"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  local desc="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  [${GREEN}PASS${NC}] $desc"
    PASSED_COUNT=$((PASSED_COUNT + 1))
  else
    echo -e "  [${RED}FAIL${NC}] $desc"
    echo "    Expected to contain: '$needle'"
    echo "    Full content: '$haystack'"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
}

assert_not_contains() {
  local needle="$1"
  local haystack="$2"
  local desc="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo -e "  [${GREEN}PASS${NC}] $desc"
    PASSED_COUNT=$((PASSED_COUNT + 1))
  else
    echo -e "  [${RED}FAIL${NC}] $desc"
    echo "    Did not expect to contain: '$needle'"
    echo "    Full content: '$haystack'"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
}

assert_exit_code() {
  local expected_code="$1"
  local actual_code="$2"
  local desc="$3"
  if [ "$expected_code" -eq "$actual_code" ]; then
    echo -e "  [${GREEN}PASS${NC}] $desc (exit code $actual_code)"
    PASSED_COUNT=$((PASSED_COUNT + 1))
  else
    echo -e "  [${RED}FAIL${NC}] $desc"
    echo "    Expected exit code: $expected_code"
    echo "    Actual exit code:   $actual_code"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
}

# ==============================================================================
# GROUP 1: CLI Flags, Help, and Error Handling (Acceptance Criteria 7)
# ==============================================================================
echo -e "${BLUE}=== Group 1: CLI Flags, Help, and Option Validation ===${NC}"

# Test 1.1: Help message content
OUT=$("$SAIA_BIN" --help)
assert_contains "Usage:" "$OUT" "saia --help displays usage"
assert_contains "-e, --endpoint <name-or-url>" "$OUT" "saia --help documents -e, --endpoint"
assert_contains "academiccloud [default]" "$OUT" "saia --help identifies academiccloud default"
assert_contains "gwdg" "$OUT" "saia --help identifies gwdg built-in"
assert_contains "SAIA_ENDPOINT" "$OUT" "saia --help documents SAIA_ENDPOINT"

# Test 1.2: Default execution with no args shows help
OUT=$("$SAIA_BIN")
assert_contains "Usage:" "$OUT" "saia with no args displays help"

# Test 1.3: -h and help commands
OUT_H=$("$SAIA_BIN" -h)
assert_contains "Usage:" "$OUT_H" "saia -h displays help"
OUT_HELP=$("$SAIA_BIN" help)
assert_contains "Usage:" "$OUT_HELP" "saia help displays help"

# Test 1.4: Missing -e argument fails with code 1 before network request
rm -f "$CURL_LOG"
set +e
ERR=$("$SAIA_BIN" -e 2>&1)
CODE=$?
set -e
assert_exit_code 1 $CODE "saia -e without value exits 1"
assert_contains "Option '-e' requires a value" "$ERR" "saia -e error message"
assert_equals "false" "$([ -f "$CURL_LOG" ] && echo true || echo false)" "No network call was made on missing -e"

# Test 1.5: Missing --endpoint argument fails with code 1
rm -f "$CURL_LOG"
set +e
ERR=$("$SAIA_BIN" --endpoint 2>&1)
CODE=$?
set -e
assert_exit_code 1 $CODE "saia --endpoint without value exits 1"
assert_contains "Option '--endpoint' requires a value" "$ERR" "saia --endpoint error message"
assert_equals "false" "$([ -f "$CURL_LOG" ] && echo true || echo false)" "No network call on missing --endpoint"

# Test 1.6: Empty -e value fails with code 1
rm -f "$CURL_LOG"
set +e
ERR=$("$SAIA_BIN" -e "" models 2>&1)
CODE=$?
set -e
assert_exit_code 1 $CODE "saia -e '' exits 1"
assert_contains "Option '-e' requires a value" "$ERR" "saia -e '' error message"

# Test 1.7: Empty --endpoint= value fails with code 1
rm -f "$CURL_LOG"
set +e
ERR=$("$SAIA_BIN" --endpoint= models 2>&1)
CODE=$?
set -e
assert_exit_code 1 $CODE "saia --endpoint= exits 1"
assert_contains "Option '--endpoint' requires a value" "$ERR" "saia --endpoint= error message"

# Test 1.8: Unknown endpoint name fails before network call (Acceptance Criterion 7)
rm -f "$CURL_LOG"
set +e
ERR=$("$SAIA_BIN" -e my_custom_server models 2>&1)
CODE=$?
set -e
assert_exit_code 1 $CODE "saia -e unknown_name exits 1"
assert_contains "Unknown endpoint 'my_custom_server'" "$ERR" "Unknown endpoint reported"
assert_contains "Accepted endpoints are 'academiccloud', 'gwdg'" "$ERR" "Explains accepted endpoint names and URL form"
assert_equals "false" "$([ -f "$CURL_LOG" ] && echo true || echo false)" "No network call on invalid endpoint name"

# Test 1.9: Malformed URL (ftp / no host) fails before network call
rm -f "$CURL_LOG"
set +e
ERR=$("$SAIA_BIN" -e ftp://gateway.example.com/v1 models 2>&1)
CODE=$?
set -e
assert_exit_code 1 $CODE "saia -e ftp://... exits 1"
assert_contains "Unknown endpoint 'ftp://gateway.example.com/v1'" "$ERR" "Non-HTTP/HTTPS URL rejected"

# Test 1.10: Unknown CLI option
set +e
ERR=$("$SAIA_BIN" --bogus-flag models 2>&1)
CODE=$?
set -e
assert_exit_code 1 $CODE "saia --bogus-flag exits 1"
assert_contains "Unknown option: --bogus-flag" "$ERR" "Unknown option reported"

# Test 1.11: -- ends global option parsing
rm -f "$CURL_LOG"
OUT=$(
  (
    cd "$TEST_TMP_DIR"
    unset SAIA_ENDPOINT BASE_URL
    "$SAIA_BIN" -- models
  )
)
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "/models" "$LAST_CURL" "-- ends global option parsing"

# ==============================================================================
# GROUP 2: Endpoint Resolution & Precedence (Acceptance Criteria 1, 2, 3, 4, 5, 6)
# ==============================================================================
echo -e "${BLUE}=== Group 2: Endpoint Precedence and Resolution ===${NC}"

# Test 2.1: Default endpoint is Academic Cloud (Acceptance Criterion 1)
rm -f "$CURL_LOG"
unset SAIA_ENDPOINT || true
unset BASE_URL || true
OUT=$("$SAIA_BIN" models)
assert_contains "meta-llama-3.1-8b-instruct" "$OUT" "saia models executes successfully"
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "https://chat-ai.academiccloud.de/v1/models" "$LAST_CURL" "Default endpoint resolves to https://chat-ai.academiccloud.de/v1 (Criteria 1)"

# Test 2.2: -e gwdg selects GWDG endpoint (Acceptance Criterion 2)
rm -f "$CURL_LOG"
OUT=$("$SAIA_BIN" -e gwdg models)
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "https://saia.gwdg.de/v1/models" "$LAST_CURL" "saia -e gwdg sends to https://saia.gwdg.de/v1/models (Criteria 2)"

# Test 2.3: SAIA_ENDPOINT=gwdg env var selects GWDG (Acceptance Criterion 3)
rm -f "$CURL_LOG"
OUT=$(SAIA_ENDPOINT=gwdg "$SAIA_BIN" models)
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "https://saia.gwdg.de/v1/models" "$LAST_CURL" "SAIA_ENDPOINT=gwdg selects GWDG when no CLI option given (Criteria 3)"

# Test 2.4: CLI option overrides SAIA_ENDPOINT (Acceptance Criterion 4)
rm -f "$CURL_LOG"
OUT=$(SAIA_ENDPOINT=gwdg "$SAIA_BIN" -e academiccloud models)
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "https://chat-ai.academiccloud.de/v1/models" "$LAST_CURL" "saia -e academiccloud overrides SAIA_ENDPOINT=gwdg (Criteria 4)"

# Test 2.5: Project .env does not override inherited SAIA_ENDPOINT (Acceptance Criterion 5)
ENV_TEST_DIR="$TEST_TMP_DIR/dotenv_test"
mkdir -p "$ENV_TEST_DIR"
echo "SAIA_ENDPOINT=academiccloud" > "$ENV_TEST_DIR/.env"
echo "SAIA_API_KEY=test_api_key" >> "$ENV_TEST_DIR/.env"
rm -f "$CURL_LOG"
(
  cd "$ENV_TEST_DIR"
  OUT=$(SAIA_ENDPOINT=gwdg "$SAIA_BIN" models)
  LAST_CURL=$(tail -n 1 "$CURL_LOG")
  assert_contains "https://saia.gwdg.de/v1/models" "$LAST_CURL" "Inherited SAIA_ENDPOINT=gwdg overrides .env SAIA_ENDPOINT=academiccloud (Criteria 5)"
)

# Test 2.6: Project .env is used when no inherited env var is set
rm -f "$CURL_LOG"
echo "SAIA_ENDPOINT=gwdg" > "$ENV_TEST_DIR/.env"
(
  cd "$ENV_TEST_DIR"
  unset SAIA_ENDPOINT || true
  OUT=$("$SAIA_BIN" models)
  LAST_CURL=$(tail -n 1 "$CURL_LOG")
  assert_contains "https://saia.gwdg.de/v1/models" "$LAST_CURL" ".env SAIA_ENDPOINT=gwdg is used when env var unset"
)

# Test 2.7: .env accepts common spacing, quoted values, and an export prefix
rm -f "$CURL_LOG"
echo '  export SAIA_ENDPOINT = "gwdg"  ' > "$ENV_TEST_DIR/.env"
(
  cd "$ENV_TEST_DIR"
  unset SAIA_ENDPOINT || true
  OUT=$("$SAIA_BIN" models)
  LAST_CURL=$(tail -n 1 "$CURL_LOG")
  assert_contains "https://saia.gwdg.de/v1/models" "$LAST_CURL" ".env endpoint value is normalized before resolution"
)

# Test 2.8: Legacy BASE_URL fallback when SAIA_ENDPOINT is unset
rm -f "$CURL_LOG"
echo "BASE_URL=https://legacy-proxy.example.edu/v1" > "$ENV_TEST_DIR/.env"
(
  cd "$ENV_TEST_DIR"
  unset SAIA_ENDPOINT || true
  unset BASE_URL || true
  OUT=$("$SAIA_BIN" models)
  LAST_CURL=$(tail -n 1 "$CURL_LOG")
  assert_contains "https://legacy-proxy.example.edu/v1/models" "$LAST_CURL" "Legacy BASE_URL in .env fallback works"
)

# Test 2.9: Custom URL with trailing-slash normalization (Acceptance Criterion 6)
rm -f "$CURL_LOG"
OUT=$("$SAIA_BIN" -e "https://gateway.example.edu/v1/" models)
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "https://gateway.example.edu/v1/models" "$LAST_CURL" "Custom URL trailing slash normalized (Criteria 6)"

# Test 2.10: Custom URL with multiple trailing slashes normalized
rm -f "$CURL_LOG"
OUT=$("$SAIA_BIN" -e "https://gateway.example.edu/v1///" models)
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "https://gateway.example.edu/v1/models" "$LAST_CURL" "Custom URL multiple trailing slashes normalized"

# Test 2.11: Alternative flag syntax --endpoint=<val> and -e=<val>
rm -f "$CURL_LOG"
OUT=$("$SAIA_BIN" "--endpoint=https://gateway.example.edu/v1" models)
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "https://gateway.example.edu/v1/models" "$LAST_CURL" "--endpoint=val flag syntax works"

rm -f "$CURL_LOG"
OUT=$("$SAIA_BIN" "-e=gwdg" models)
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "https://saia.gwdg.de/v1/models" "$LAST_CURL" "-e=val flag syntax works"

# Test 2.12: Option before command only (options after command treated as args)
rm -f "$CURL_LOG"
CHAT_AFTER=$("$SAIA_BIN" chat "--endpoint" "gwdg")
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "https://chat-ai.academiccloud.de/v1/chat/completions" "$LAST_CURL" "Option after command treated as command args; default endpoint used"
assert_contains "Chat response from mock server" "$CHAT_AFTER" "Chat command executed"

# ==============================================================================
# GROUP 3: URL Derivation for All Commands (Acceptance Criterion 8)
# ==============================================================================
echo -e "${BLUE}=== Group 3: Command Endpoints & Audio URL Derivation ===${NC}"

CUSTOM_EP="https://my-gateway.org/api/v1"

# Test 3.1: models command uses BASE_URL
rm -f "$CURL_LOG"
OUT=$("$SAIA_BIN" -e "$CUSTOM_EP" models)
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "$CUSTOM_EP/models" "$LAST_CURL" "models uses derived BASE_URL"

# Test 3.2: chat command uses BASE_URL
rm -f "$CURL_LOG"
OUT=$("$SAIA_BIN" -e "$CUSTOM_EP" chat "User prompt")
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "$CUSTOM_EP/chat/completions" "$LAST_CURL" "chat uses derived BASE_URL"

# Test 3.3: complete command uses BASE_URL
rm -f "$CURL_LOG"
OUT=$("$SAIA_BIN" -e "$CUSTOM_EP" complete "Text prompt")
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "$CUSTOM_EP/completions" "$LAST_CURL" "complete uses derived BASE_URL"

# Test 3.4: embed command uses BASE_URL
rm -f "$CURL_LOG"
OUT=$("$SAIA_BIN" -e "$CUSTOM_EP" embed "Embedding text")
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "$CUSTOM_EP/embeddings" "$LAST_CURL" "embed uses derived BASE_URL"

# Test 3.5: convert command uses BASE_URL
DUMMY_DOC="$TEST_TMP_DIR/doc.pdf"
echo "Dummy PDF" > "$DUMMY_DOC"
rm -f "$CURL_LOG"
OUT=$("$SAIA_BIN" -e "$CUSTOM_EP" convert "$DUMMY_DOC")
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "$CUSTOM_EP/documents/convert" "$LAST_CURL" "convert uses derived BASE_URL"

# Test 3.6: audio transcriptions uses BASE_URL (Acceptance Criterion 8 - Fixes hardcoded saia.gwdg.de)
DUMMY_AUDIO="$TEST_TMP_DIR/audio.mp3"
echo "Dummy MP3" > "$DUMMY_AUDIO"
rm -f "$CURL_LOG"
OUT=$("$SAIA_BIN" -e "$CUSTOM_EP" audio transcriptions "$DUMMY_AUDIO")
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "$CUSTOM_EP/audio/transcriptions" "$LAST_CURL" "audio transcriptions uses derived BASE_URL (Criteria 8)"
assert_not_contains "saia.gwdg.de" "$LAST_CURL" "audio command does NOT use hardcoded saia.gwdg.de"

# Test 3.7: audio translations uses BASE_URL
rm -f "$CURL_LOG"
OUT=$("$SAIA_BIN" -e "$CUSTOM_EP" audio translations "$DUMMY_AUDIO")
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "$CUSTOM_EP/audio/translations" "$LAST_CURL" "audio translations uses derived BASE_URL"

# Test 3.8: image generation uses BASE_URL
rm -f "$CURL_LOG" "$WORKSPACE_DIR/generated_image.png"
OUT=$("$SAIA_BIN" -e "$CUSTOM_EP" image "Space landscape")
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "$CUSTOM_EP/images/generations" "$LAST_CURL" "image uses derived BASE_URL"
assert_equals "true" "$([ -f "$WORKSPACE_DIR/generated_image.png" ] && echo true || echo false)" "generated_image.png saved"
rm -f "$WORKSPACE_DIR/generated_image.png"

# Test 3.9: edit_image uses BASE_URL
DUMMY_IMG="$TEST_TMP_DIR/img.png"
echo "Dummy PNG" > "$DUMMY_IMG"
rm -f "$CURL_LOG" "$WORKSPACE_DIR/edited_image.png"
OUT=$("$SAIA_BIN" -e "$CUSTOM_EP" edit_image "Make it glow" "$DUMMY_IMG")
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "$CUSTOM_EP/images/edits/" "$LAST_CURL" "edit_image uses derived BASE_URL"
assert_equals "true" "$([ -f "$WORKSPACE_DIR/edited_image.png" ] && echo true || echo false)" "edited_image.png saved"
rm -f "$WORKSPACE_DIR/edited_image.png"

# Test 3.10: arcana uses BASE_URL
rm -f "$CURL_LOG"
OUT=$("$SAIA_BIN" -e "$CUSTOM_EP" arcana "arc-123" "Query text")
LAST_CURL=$(tail -n 1 "$CURL_LOG")
assert_contains "$CUSTOM_EP/chat/completions" "$LAST_CURL" "arcana uses derived BASE_URL"

# ==============================================================================
# GROUP 4: Limits Diagnostics & Stderr/Stdout Isolation (Acceptance Criterion 9)
# ==============================================================================
echo -e "${BLUE}=== Group 4: Limits Command & Observable Behavior ===${NC}"

# Test 4.1: limits on GWDG via CLI option outputs diagnostic to stderr (Criteria 9)
LIMITS_STDERR="$TEST_TMP_DIR/limits_gwdg_stderr.log"
LIMITS_STDOUT=$(SAIA_API_KEY=test "$SAIA_BIN" -e gwdg limits 2> "$LIMITS_STDERR")
STDERR_CONTENT=$(cat "$LIMITS_STDERR")

assert_contains "Endpoint: gwdg (https://saia.gwdg.de/v1; selected by CLI option)" "$STDERR_CONTENT" "limits stderr contains full endpoint diagnostic (Criteria 9)"
assert_contains "SAIA Account Rate Limits & Quota:" "$LIMITS_STDOUT" "limits stdout contains formatted quota table"
assert_contains "Minute:  29 / 30" "$LIMITS_STDOUT" "limits stdout renders Minute quota"
assert_contains "Hour:    199 / 200" "$LIMITS_STDOUT" "limits stdout renders Hour quota"
assert_contains "Day:     999 / 1000" "$LIMITS_STDOUT" "limits stdout renders Day quota"
assert_contains "Month:   2999 / 3000" "$LIMITS_STDOUT" "limits stdout renders Month quota"
assert_contains "resets in 45s" "$LIMITS_STDOUT" "limits stdout renders reset time"

# Test 4.2: limits with default endpoint shows default diagnostic
LIMITS_DEF_STDERR="$TEST_TMP_DIR/limits_def_stderr.log"
LIMITS_DEF_STDOUT=$(SAIA_API_KEY=test "$SAIA_BIN" limits 2> "$LIMITS_DEF_STDERR")
STDERR_DEF_CONTENT=$(cat "$LIMITS_DEF_STDERR")
assert_contains "Endpoint: academiccloud (https://chat-ai.academiccloud.de/v1; default)" "$STDERR_DEF_CONTENT" "limits default endpoint diagnostic shown on stderr"

# Test 4.3: limits on endpoint with missing ratelimit headers handles gracefully (Criteria 9)
LIMITS_NO_HDR_STDERR="$TEST_TMP_DIR/limits_no_hdr_stderr.log"
LIMITS_NO_HDR_STDOUT=$(SAIA_API_KEY=test "$SAIA_BIN" -e "https://gateway.example.com/no-headers" limits 2> "$LIMITS_NO_HDR_STDERR")
assert_contains "Rate limit headers are not available for this endpoint (custom: https://gateway.example.com/no-headers)" "$LIMITS_NO_HDR_STDOUT" "limits handles missing headers without failing (Criteria 9)"
assert_contains "This does not mean no limits exist on the server" "$LIMITS_NO_HDR_STDOUT" "limits clarifies missing headers do not mean unlimited quota"

# Test 4.4: Stderr diagnostic isolation for stdout pipelines (Acceptance Criterion 10)
# Normal stdout commands like chat or models should NOT print endpoint banners
rm -f "$TEST_TMP_DIR/stdout_pipe.log"
MODELS_OUT=$("$SAIA_BIN" -e gwdg models)
assert_not_contains "Endpoint: " "$MODELS_OUT" "models stdout has NO diagnostic banners"
assert_contains "deepseek-r1-distill-llama-70b" "$MODELS_OUT" "models stdout has pure payload"

CHAT_PIPE_OUT=$("$SAIA_BIN" -e gwdg chat "Summarize this")
assert_not_contains "Endpoint: " "$CHAT_PIPE_OUT" "chat stdout has NO diagnostic banners"
assert_equals "Chat response from mock server" "$CHAT_PIPE_OUT" "chat stdout has clean LLM response"

# ==============================================================================
# GROUP 5: Error Handling & Diagnostics (Acceptance Criteria 7, 10)
# ==============================================================================
echo -e "${BLUE}=== Group 5: API Error Responses & Input Validations ===${NC}"

# Test 5.1: API Error includes resolved BASE_URL in message
set +e
ERR_OUT=$("$SAIA_BIN" -e "$CUSTOM_EP" chat "error_trigger" 2>&1)
ERR_CODE=$?
set -e
assert_exit_code 1 $ERR_CODE "API error response exits code 1"
assert_contains "API Error ($CUSTOM_EP):" "$ERR_OUT" "API error includes resolved BASE_URL"
assert_contains "Invalid prompt parameter" "$ERR_OUT" "API error includes server error message"

# Test 5.2: Empty API response error includes BASE_URL
set +e
ERR_EMPTY=$("$SAIA_BIN" -e "$CUSTOM_EP" chat "empty_response" 2>&1)
ERR_EMPTY_CODE=$?
set -e
assert_exit_code 1 $ERR_EMPTY_CODE "Empty API response exits code 1"
assert_contains "Empty response from API ($CUSTOM_EP)" "$ERR_EMPTY" "Empty response includes BASE_URL"

# Test 5.3: Missing required command arguments fail with exit code 1
set +e
ERR_CHAT=$("$SAIA_BIN" chat 2>&1)
assert_exit_code 1 $? "chat without prompt fails"
assert_contains "Missing prompt" "$ERR_CHAT" "chat missing prompt error message"

ERR_DOC=$("$SAIA_BIN" convert 2>&1)
assert_exit_code 1 $? "convert without file fails"
assert_contains "Missing file path" "$ERR_DOC" "convert missing file error message"

ERR_AUDIO_TASK=$("$SAIA_BIN" audio invalid_task dummy.mp3 2>&1)
assert_exit_code 1 $? "audio with invalid task fails"
assert_contains "Task must be 'transcriptions' or 'translations'" "$ERR_AUDIO_TASK" "audio invalid task error message"

ERR_ARCANA=$("$SAIA_BIN" arcana 2>&1)
assert_exit_code 1 $? "arcana without ID fails"
assert_contains "Missing arcana ID" "$ERR_ARCANA" "arcana missing ID error message"
set -e

# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE}                         TEST SUMMARY                                 ${NC}"
echo -e "${BLUE}======================================================================${NC}"
echo -e "Total Passed: ${GREEN}$PASSED_COUNT${NC}"
echo -e "Total Failed: ${RED}$FAILED_COUNT${NC}"

if [ "$FAILED_COUNT" -gt 0 ]; then
  echo -e "${RED}Test suite FAILED!${NC}"
  exit 1
else
  echo -e "${GREEN}All tests passed successfully!${NC}"
  exit 0
fi
