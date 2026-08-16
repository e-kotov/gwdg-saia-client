#!/usr/bin/env bash

set -euo pipefail

# Configuration
DEFAULT_ENDPOINT="academiccloud"
DEFAULT_CHAT_MODEL="meta-llama-3.1-8b-instruct"
DEFAULT_IMAGE_MODEL="flux"

# Colors for UX
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Built-in endpoints
BUILTIN_ACADEMICCLOUD_URL="https://chat-ai.academiccloud.de/v1"
BUILTIN_GWDG_URL="https://saia.gwdg.de/v1"

# Capture inherited environment variables before loading .env
INHERITED_SAIA_ENDPOINT="${SAIA_ENDPOINT:-}"
INHERITED_BASE_URL="${BASE_URL:-}"
DOTENV_SAIA_ENDPOINT=""
DOTENV_BASE_URL=""

trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# Load .env if it exists in the current directory without overwriting inherited environment variables
if [ -f .env ]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//$'\r'/}"
    line="$(trim_whitespace "$line")"
    if [[ -n "$line" && ! "$line" =~ ^# && "$line" == *=* ]]; then
      key="${line%%=*}"
      val="${line#*=}"
      key="$(trim_whitespace "$key")"
      val="$(trim_whitespace "$val")"
      if [[ "$key" == export[[:space:]]* ]]; then
        key="$(trim_whitespace "${key#export}")"
      fi
      if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo -e "${RED}Error:${NC} Invalid variable name in .env: '$key'" >&2
        exit 1
      fi
      if [[ "$val" =~ ^\"(.*)\"$ ]]; then
        val="${BASH_REMATCH[1]}"
      elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
        val="${BASH_REMATCH[1]}"
      fi
      if [ "$key" = "SAIA_ENDPOINT" ] && [ -z "$INHERITED_SAIA_ENDPOINT" ] && [ -z "$DOTENV_SAIA_ENDPOINT" ]; then
        DOTENV_SAIA_ENDPOINT="$val"
      fi
      if [ "$key" = "BASE_URL" ] && [ -z "$INHERITED_BASE_URL" ] && [ -z "$DOTENV_BASE_URL" ]; then
        DOTENV_BASE_URL="$val"
      fi
      if [ -z "${!key+x}" ]; then
        export "$key=$val"
      fi
    fi
  done < .env
fi

# Endpoint Resolution State
BASE_URL=""
ENDPOINT_ID=""
ENDPOINT_LABEL=""
ENDPOINT_SOURCE=""

resolve_endpoint() {
  local raw_target=""

  if [ -n "$CLI_ENDPOINT" ]; then
    raw_target="$CLI_ENDPOINT"
    ENDPOINT_SOURCE="cli"
  elif [ -n "$INHERITED_SAIA_ENDPOINT" ]; then
    raw_target="$INHERITED_SAIA_ENDPOINT"
    ENDPOINT_SOURCE="environment"
  elif [ -n "$DOTENV_SAIA_ENDPOINT" ]; then
    raw_target="$DOTENV_SAIA_ENDPOINT"
    ENDPOINT_SOURCE="dotenv"
  elif [ -n "$INHERITED_BASE_URL" ]; then
    raw_target="$INHERITED_BASE_URL"
    ENDPOINT_SOURCE="legacy"
  elif [ -n "$DOTENV_BASE_URL" ]; then
    raw_target="$DOTENV_BASE_URL"
    ENDPOINT_SOURCE="legacy"
  else
    raw_target="$DEFAULT_ENDPOINT"
    ENDPOINT_SOURCE="default"
  fi

  raw_target="$(trim_whitespace "$raw_target")"

  case "$raw_target" in
    academiccloud)
      ENDPOINT_ID="academiccloud"
      BASE_URL="$BUILTIN_ACADEMICCLOUD_URL"
      ;;
    gwdg)
      ENDPOINT_ID="gwdg"
      BASE_URL="$BUILTIN_GWDG_URL"
      ;;
    http://*|https://*)
      if [[ ! "$raw_target" =~ ^https?://[^[:space:]/]+(/[^[:space:]]*)?$ ]]; then
        echo -e "${RED}Error:${NC} Invalid endpoint URL: '$raw_target'" >&2
        echo "Accepted endpoints are 'academiccloud', 'gwdg', or an absolute HTTP(S) URL (e.g. 'https://...')." >&2
        exit 1
      fi
      ENDPOINT_ID="custom"
      local normalized="$raw_target"
      while [[ "$normalized" == */ ]]; do
        normalized="${normalized%/}"
      done
      BASE_URL="$normalized"
      ;;
    *)
      echo -e "${RED}Error:${NC} Unknown endpoint '$raw_target'." >&2
      echo "Accepted endpoints are 'academiccloud', 'gwdg', or an absolute HTTP(S) URL (e.g. 'https://...')." >&2
      exit 1
      ;;
  esac

  local source_desc=""
  case "$ENDPOINT_SOURCE" in
    cli) source_desc="selected by CLI option" ;;
    environment) source_desc="selected by SAIA_ENDPOINT environment variable" ;;
    dotenv) source_desc="selected by .env file" ;;
    legacy) source_desc="selected by legacy BASE_URL" ;;
    default) source_desc="default" ;;
  esac

  ENDPOINT_LABEL="${ENDPOINT_ID} (${BASE_URL}; ${source_desc})"
}

# Dependency Check
check_deps() {
  for dep in curl jq base64; do
    if ! command -v "$dep" &> /dev/null; then
      echo -e "${RED}Error:${NC} $dep is not installed. Please install it to use this script." >&2
      exit 1
    fi
  done
}

# API Key Check
check_api_key() {
  if [ -z "${SAIA_API_KEY:-}" ]; then
    # Try fetching from macOS Keychain if on macOS
    if [[ "$OSTYPE" == "darwin"* ]] && command -v security &> /dev/null; then
      SAIA_API_KEY=$(security find-generic-password -w -s saia_api_key 2>/dev/null || true)
      export SAIA_API_KEY
    fi
  fi

  if [ -z "${SAIA_API_KEY:-}" ]; then
    echo -e "${RED}Error:${NC} SAIA_API_KEY is not set." >&2
    echo "Please set it in your environment or add it to a .env file as SAIA_API_KEY=your_key_here" >&2
    exit 1
  fi
}

# Error Handling Helper
handle_api_response() {
  local response="$1"
  if [ -z "$response" ]; then
    echo -e "${RED}Error:${NC} Empty response from API (${BASE_URL})." >&2
    exit 1
  fi
  if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    echo -e "${RED}API Error (${BASE_URL}):${NC}" >&2
    echo "$response" | jq -r '.error.message // .error' >&2
    exit 1
  fi
}

# Cross-platform base64 decode
decode_base64() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    base64 -D
  else
    base64 -d
  fi
}

show_help() {
  local script_name
  script_name="$(basename "$0")"

  echo -e "${BLUE}SAIA CLI - Simple API Utility${NC}"
  echo ""
  echo "Usage: $script_name [-e|--endpoint <name-or-url>] <command> [arguments]"
  echo ""
  echo -e "${BLUE}Options:${NC}"
  echo "  -e, --endpoint <name-or-url>  Select a built-in endpoint or API base URL"
  echo "                                (built-in: academiccloud [default], gwdg;"
  echo "                                 or custom: https://...)"
  echo ""
  echo -e "${BLUE}Authentication:${NC}"
  echo "  Provide your API key in one of three ways:"
  echo "  1. Export it:        export SAIA_API_KEY='your_key'"
  echo "  2. .env file:        echo \"SAIA_API_KEY=your_key\" > .env"
  echo "  3. macOS Keychain:   automatically reads 'saia_api_key' if present"
  echo ""
  echo -e "${BLUE}Configuration:${NC}"
  echo "  Set a persistent endpoint via SAIA_ENDPOINT in your environment or .env:"
  echo "    export SAIA_ENDPOINT=gwdg"
  echo "    export SAIA_ENDPOINT=https://custom-gateway.example.edu/v1"
  echo ""
  echo -e "${BLUE}Service & Utility Commands:${NC}"
  echo "  models            List all available AI models"
  echo "  limits [model]    Show current API rate limits and remaining account quota"
  echo "                    (optional [model] argument, defaults to $DEFAULT_CHAT_MODEL)"
  echo "  convert <file>    Convert a document (PDF/etc) to Markdown (Docling)"
  echo "  embed <text>      Get embeddings for the provided text"
  echo "  audio <task> <f>  Audio task (transcriptions|translations) for file <f>"
  echo ""
  echo -e "${BLUE}Inference & AI Commands:${NC}"
  echo "  chat [sys] <user> Chat completion (use '-' for stdin user prompt)"
  echo "  complete <prompt> Text generation (use '-' for stdin prompt)"
  echo "  image <prompt>    Generate an image (saves to generated_image.png)"
  echo "  edit_image <p> <f> Edit image <f> with prompt <p> (saves to edited_image.png)"
  echo "  arcana <id> <q>   Query an Arcana (RAG) with ID and user query <q>"
  echo ""
  echo "  help              Show this help message"
  echo ""
  echo "Examples:"
  echo "  $script_name chat \"Hello there\""
  echo "  $script_name -e gwdg models"
  echo "  $script_name -e https://gateway.example.edu/v1 chat \"Summarize this\""
  echo "  $script_name chat \"You are a poet\" \"Write a poem about Bash\""
  echo "  $script_name limits"
  echo "  cat file.txt | $script_name chat \"Summarize this\" -"
  echo ""
  echo "Limit note:"
  echo "  $script_name limits sends a minimal 1-token request payload so Kong returns"
  echo "  your true inference account quota (consumes 1 request attempt)."
  echo ""
}

# --- Service Commands ---

list_models() {
  echo -e "${BLUE}Fetching available models...${NC}" >&2
  local response
  response=$(curl -s -X POST "$BASE_URL/models" \
    -H "Authorization: Bearer $SAIA_API_KEY" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json")
  
  handle_api_response "$response"
  echo "$response" | jq -r '.data[].id' | sort
}

format_duration() {
  local total_seconds="$1"
  local days hours minutes seconds

  days=$((total_seconds / 86400))
  hours=$(((total_seconds % 86400) / 3600))
  minutes=$(((total_seconds % 3600) / 60))
  seconds=$((total_seconds % 60))

  local parts=()
  if [ "$days" -gt 0 ]; then parts+=("${days}d"); fi
  if [ "$hours" -gt 0 ]; then parts+=("${hours}h"); fi
  if [ "$minutes" -gt 0 ]; then parts+=("${minutes}m"); fi
  if [ "$seconds" -gt 0 ] || [ "${#parts[@]}" -eq 0 ]; then parts+=("${seconds}s"); fi

  local IFS=' '
  echo "${parts[*]}"
}

format_reset_time() {
  local reset_seconds="$1"
  if [[ ! "$reset_seconds" =~ ^[0-9]+$ ]]; then
    return 0
  fi

  local target_epoch=$(( $(date +%s) + reset_seconds ))
  local timestamp
  if [[ "$OSTYPE" == "darwin"* ]]; then
    timestamp=$(date -r "$target_epoch" '+%Y-%m-%d %H:%M:%S %Z')
  else
    timestamp=$(date -d "@$target_epoch" '+%Y-%m-%d %H:%M:%S %Z')
  fi

  printf '%s (at %s)' "$(format_duration "$reset_seconds")" "$timestamp"
}

show_limits() {
  local model="${1:-$DEFAULT_CHAT_MODEL}"
  echo -e "${BLUE}Fetching SAIA account rate limits...${NC}" >&2
  echo -e "Endpoint: ${ENDPOINT_LABEL}" >&2

  local raw_resp header_block
  raw_resp=$(curl -s -i --max-time 5 "$BASE_URL/chat/completions" \
    -H "Authorization: Bearer $SAIA_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg model "$model" '{model: $model, messages: [{"role":"user","content":"."}], max_tokens: 1}')" || true)

  header_block=$(echo "$raw_resp" | sed -n '1,/^\r*$/p' | tr -d '\r')

  get_header_val() {
    local key="$1"
    echo "$header_block" | { grep -i "^${key}:" || true; } | head -n1 | cut -d':' -f2- | xargs
  }

  local rem_min lim_min rem_hr lim_hr rem_day lim_day rem_mo lim_mo reset_sec
  lim_min=$(get_header_val "x-ratelimit-limit-minute")
  rem_min=$(get_header_val "x-ratelimit-remaining-minute")

  lim_hr=$(get_header_val "x-ratelimit-limit-hour")
  rem_hr=$(get_header_val "x-ratelimit-remaining-hour")

  lim_day=$(get_header_val "x-ratelimit-limit-day")
  rem_day=$(get_header_val "x-ratelimit-remaining-day")

  lim_mo=$(get_header_val "x-ratelimit-limit-month")
  rem_mo=$(get_header_val "x-ratelimit-remaining-month")

  reset_sec=$(get_header_val "ratelimit-reset")
  if [ -z "$reset_sec" ]; then
    reset_sec=$(get_header_val "x-ratelimit-reset")
  fi

  local reset_min_hdr reset_hr_hdr reset_day_hdr reset_mo_hdr
  reset_min_hdr=$(get_header_val "x-ratelimit-reset-minute")
  reset_hr_hdr=$(get_header_val "x-ratelimit-reset-hour")
  reset_day_hdr=$(get_header_val "x-ratelimit-reset-day")
  reset_mo_hdr=$(get_header_val "x-ratelimit-reset-month")

  if [ -n "$lim_min" ] || [ -n "$lim_hr" ] || [ -n "$lim_day" ] || [ -n "$lim_mo" ]; then
    local reset_window="" reset_suffix="" reset_note=""
    local min_reset_suffix="" hr_reset_suffix="" day_reset_suffix="" mo_reset_suffix=""
    local exhausted_windows=()
    if [[ "$rem_min" == "0" ]]; then exhausted_windows+=("Minute"); fi
    if [[ "$rem_hr" == "0" ]]; then exhausted_windows+=("Hour"); fi
    if [[ "$rem_day" == "0" ]]; then exhausted_windows+=("Day"); fi
    if [[ "$rem_mo" == "0" ]]; then exhausted_windows+=("Month"); fi

    # Check for per-window reset headers first
    if [ -n "$reset_min_hdr" ]; then
      local desc
      desc=$(format_reset_time "$reset_min_hdr" || true)
      if [ -n "$desc" ]; then min_reset_suffix="  (resets in ${desc})"; fi
    fi
    if [ -n "$reset_hr_hdr" ]; then
      local desc
      desc=$(format_reset_time "$reset_hr_hdr" || true)
      if [ -n "$desc" ]; then hr_reset_suffix="  (resets in ${desc})"; fi
    fi
    if [ -n "$reset_day_hdr" ]; then
      local desc
      desc=$(format_reset_time "$reset_day_hdr" || true)
      if [ -n "$desc" ]; then day_reset_suffix="  (resets in ${desc})"; fi
    fi
    if [ -n "$reset_mo_hdr" ]; then
      local desc
      desc=$(format_reset_time "$reset_mo_hdr" || true)
      if [ -n "$desc" ]; then mo_reset_suffix="  (resets in ${desc})"; fi
    fi

    # Fall back to single generic reset header if per-window headers were not provided
    if [ -n "$reset_sec" ] && [ -z "$min_reset_suffix" ] && [ -z "$hr_reset_suffix" ] && [ -z "$day_reset_suffix" ] && [ -z "$mo_reset_suffix" ]; then
      local reset_description
      reset_description=$(format_reset_time "$reset_sec" || true)
      if [ "${#exhausted_windows[@]}" -eq 1 ]; then
        reset_window="${exhausted_windows[0]}"
        if [ -n "$reset_description" ]; then reset_suffix="  (resets in ${reset_description})"; fi
      elif [ "${#exhausted_windows[@]}" -gt 1 ]; then
        if [ -n "$reset_description" ]; then reset_note="next applicable reset in ${reset_description}"; fi
      else
        # When no window is exhausted, Kong's generic ratelimit-reset corresponds to the active minute window
        reset_window="Minute"
        if [ -n "$reset_description" ]; then reset_suffix="  (resets in ${reset_description})"; fi
      fi

      case "$reset_window" in
        Minute) min_reset_suffix="$reset_suffix" ;;
        Hour) hr_reset_suffix="$reset_suffix" ;;
        Day) day_reset_suffix="$reset_suffix" ;;
        Month) mo_reset_suffix="$reset_suffix" ;;
      esac
    fi

    echo ""
    echo -e "${BLUE}SAIA Account Rate Limits & Quota:${NC}"
    printf "  %-8s %s / %-5s remaining%s\n" "Minute:" "${rem_min:-N/A}" "${lim_min:-N/A}" "$min_reset_suffix"
    printf "  %-8s %s / %-5s remaining%s\n" "Hour:" "${rem_hr:-N/A}" "${lim_hr:-N/A}" "$hr_reset_suffix"
    printf "  %-8s %s / %-5s remaining%s\n" "Day:" "${rem_day:-N/A}" "${lim_day:-N/A}" "$day_reset_suffix"
    printf "  %-8s %s / %-5s remaining%s\n" "Month:" "${rem_mo:-N/A}" "${lim_mo:-N/A}" "$mo_reset_suffix"
    if [ -n "$reset_note" ]; then
      echo "  Reset:   ${reset_note}"
    fi
    echo ""
    echo -e "${RED}Note:${NC} Running this quota check consumed 1 request attempt from your API limit."
  else
    echo ""
    echo -e "${BLUE}SAIA Account Rate Limits & Quota:${NC}"
    echo "  Rate limit headers are not available for this endpoint (${ENDPOINT_ID}: ${BASE_URL})."
    echo "  This does not mean no limits exist on the server."
    local rl_headers
    rl_headers=$(echo "$header_block" | grep -iE "x-ratelimit|ratelimit" || true)
    if [ -n "$rl_headers" ]; then
      echo ""
      echo "  Available ratelimit headers:"
      echo "$rl_headers" | sed 's/^/    /'
    fi
    echo ""
    echo -e "${RED}Note:${NC} Running this quota check consumed 1 request attempt from your API limit."
  fi
}

convert_doc() {
  local file="$1"
  [ -f "$file" ] || { echo -e "${RED}Error:${NC} File not found: $file" >&2; exit 1; }

  echo -e "${BLUE}Converting document: $file...${NC}" >&2
  local response
  response=$(curl -s -X POST "$BASE_URL/documents/convert" \
    -H "Authorization: Bearer $SAIA_API_KEY" \
    -H "Accept: application/json" \
    -F "document=@$file")

  handle_api_response "$response"
  echo "$response" | jq -r '.markdown'
}

get_embeddings() {
  local text="$1"
  local model="${2:-multilingual-e5-large-instruct}"

  echo -e "${BLUE}Fetching embeddings for text using $model...${NC}" >&2
  local response
  response=$(curl -s -X POST "$BASE_URL/embeddings" \
    -H "Authorization: Bearer $SAIA_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg input "$text" --arg model "$model" '{input: $input, model: $model}')")

  handle_api_response "$response"
  echo "$response" | jq -c '.data[0].embedding'
}

handle_audio() {
  local task="$1"
  local file="$2"
  local model="${3:-whisper-large-v2}"
  local format="${4:-text}"

  [ -f "$file" ] || { echo -e "${RED}Error:${NC} File not found: $file" >&2; exit 1; }

  echo -e "${BLUE}Performing audio $task for $file...${NC}" >&2
  local audio_url="$BASE_URL/audio/$task"
  
  curl -s -X POST "$audio_url" \
    -H "Authorization: Bearer $SAIA_API_KEY" \
    -H "Accept: */*" \
    -F "model=$model" \
    -F "file=@$file" \
    -F "response_format=$format"
}

# --- Inference Commands ---

chat_completion() {
  local sys_prompt="$1"
  local user_prompt="$2"
  [ "$user_prompt" = "-" ] && user_prompt=$(cat)
  local model="${3:-$DEFAULT_CHAT_MODEL}"

  echo -e "${BLUE}Chatting with $model...${NC}" >&2
  local response
  response=$(curl -s -X POST "$BASE_URL/chat/completions" \
    -H "Authorization: Bearer $SAIA_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg model "$model" --arg sys "$sys_prompt" --arg user "$user_prompt" \
      '{model: $model, messages: [{"role":"system","content":$sys}, {"role":"user","content":$user}], temperature: 0.5}')")

  handle_api_response "$response"
  echo "$response" | jq -r '.choices[0].message.content'
}

text_completion() {
  local prompt="$1"
  [ "$prompt" = "-" ] && prompt=$(cat)
  local model="${2:-$DEFAULT_CHAT_MODEL}"

  echo -e "${BLUE}Generating completion with $model...${NC}" >&2
  local response
  response=$(curl -s -X POST "$BASE_URL/completions" \
    -H "Authorization: Bearer $SAIA_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg model "$model" --arg prompt "$prompt" \
      '{model: $model, prompt: $prompt, max_tokens: 500, temperature: 0.5}')")

  handle_api_response "$response"
  echo "$response" | jq -r '.choices[0].text'
}

generate_image() {
  local prompt="$1"
  local model="${2:-$DEFAULT_IMAGE_MODEL}"
  local output_file="generated_image.png"

  echo -e "${BLUE}Generating image with $model...${NC}" >&2
  local response
  response=$(curl -s -X POST "$BASE_URL/images/generations" \
    -H "Authorization: Bearer $SAIA_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg prompt "$prompt" --arg model "$model" \
      '{prompt: $prompt, model: $model, response_format: "b64_json", size: "1024x1024", n: 1}')")

  handle_api_response "$response"
  echo -e "${GREEN}Saving to $output_file${NC}" >&2
  echo "$response" | jq -r '.data[0].b64_json' | decode_base64 > "$output_file"
}

edit_image() {
  local prompt="$1"
  local file="$2"
  local output_file="edited_image.png"

  [ -f "$file" ] || { echo -e "${RED}Error:${NC} Image file not found: $file" >&2; exit 1; }

  echo -e "${BLUE}Editing image $file...${NC}" >&2
  curl -s -X POST "$BASE_URL/images/edits/" \
    -H "Authorization: Bearer $SAIA_API_KEY" \
    -H "Content-Type: multipart/form-data" \
    -H "inference-service: image-edit-2511" \
    -F "prompt=$prompt" \
    -F "image=@$file" \
    -o "$output_file"

  echo -e "${GREEN}Saved to $output_file${NC}" >&2
}

chat_arcana() {
  local arcana_id="$1"
  local user_prompt="$2"
  [ "$user_prompt" = "-" ] && user_prompt=$(cat)
  local model="qwen3-30b-a3b-instruct-2507"

  echo -e "${BLUE}Querying Arcana $arcana_id...${NC}" >&2
  local response
  response=$(curl -s -X POST "$BASE_URL/chat/completions" \
    -H "Authorization: Bearer $SAIA_API_KEY" \
    -H "Content-Type: application/json" \
    -H "inference-service: saia-openai-gateway" \
    -d "$(jq -n --arg model "$model" --arg user "$user_prompt" --arg id "$arcana_id" \
      '{
        model: $model, 
        messages: [{"role":"system","content":"You are a helpful assistant."}, {"role":"user","content":$user}], 
        "enable-tools": true, 
        arcana: {id: $id}, 
        temperature: 0.0
      }')")

  handle_api_response "$response"
  echo "$response" | jq -r '.choices[0].message.content'
}

# --- Main & Dispatcher ---

check_deps

CLI_ENDPOINT=""
REMAINING_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo -e "${RED}Error:${NC} Option '-e' requires a value." >&2
        echo "Accepted endpoints are 'academiccloud', 'gwdg', or an absolute HTTP(S) URL (e.g. 'https://...')." >&2
        exit 1
      fi
      CLI_ENDPOINT="$2"
      shift 2
      ;;
    -e=*)
      CLI_ENDPOINT="${1#-e=}"
      if [ -z "$CLI_ENDPOINT" ]; then
        echo -e "${RED}Error:${NC} Option '-e' requires a value." >&2
        echo "Accepted endpoints are 'academiccloud', 'gwdg', or an absolute HTTP(S) URL (e.g. 'https://...')." >&2
        exit 1
      fi
      shift 1
      ;;
    --endpoint)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo -e "${RED}Error:${NC} Option '--endpoint' requires a value." >&2
        echo "Accepted endpoints are 'academiccloud', 'gwdg', or an absolute HTTP(S) URL (e.g. 'https://...')." >&2
        exit 1
      fi
      CLI_ENDPOINT="$2"
      shift 2
      ;;
    --endpoint=*)
      CLI_ENDPOINT="${1#--endpoint=}"
      if [ -z "$CLI_ENDPOINT" ]; then
        echo -e "${RED}Error:${NC} Option '--endpoint' requires a value." >&2
        echo "Accepted endpoints are 'academiccloud', 'gwdg', or an absolute HTTP(S) URL (e.g. 'https://...')." >&2
        exit 1
      fi
      shift 1
      ;;
    --)
      shift 1
      while [[ $# -gt 0 ]]; do
        REMAINING_ARGS+=("$1")
        shift 1
      done
      break
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    -*)
      if [ "$1" = "-" ]; then
        REMAINING_ARGS+=("$1")
        shift 1
      else
        echo -e "${RED}Error:${NC} Unknown option: $1" >&2
        show_help >&2
        exit 1
      fi
      ;;
    *)
      REMAINING_ARGS+=("$1")
      shift 1
      ;;
  esac
done

if [ ${#REMAINING_ARGS[@]} -gt 0 ]; then
  set -- "${REMAINING_ARGS[@]}"
else
  set --
fi

resolve_endpoint

case "${1:-help}" in
  models)
    check_api_key && list_models
    ;;
  limits)
    check_api_key && show_limits "${2:-}"
    ;;
  convert)
    check_api_key
    [ -z "${2:-}" ] && { echo -e "${RED}Error:${NC} Missing file path" >&2; exit 1; }
    convert_doc "$2"
    ;;
  embed)
    check_api_key
    [ -z "${2:-}" ] && { echo -e "${RED}Error:${NC} Missing text" >&2; exit 1; }
    get_embeddings "$2" "${3:-}"
    ;;
  audio)
    check_api_key
    [[ "${2:-}" != "transcriptions" && "${2:-}" != "translations" ]] && { echo -e "${RED}Error:${NC} Task must be 'transcriptions' or 'translations'" >&2; exit 1; }
    [ -z "${3:-}" ] && { echo -e "${RED}Error:${NC} Missing file path" >&2; exit 1; }
    handle_audio "$2" "$3" "${4:-}" "${5:-}"
    ;;
  chat)
    check_api_key
    if [ -z "${2:-}" ]; then
      echo -e "${RED}Error:${NC} Missing prompt" >&2; exit 1
    fi
    if [ -z "${3:-}" ]; then
      # One arg: treated as user prompt with default system prompt
      chat_completion "You are a helpful assistant." "$2"
    else
      # Two or more args: system_prompt, user_prompt, [model]
      chat_completion "$2" "$3" "${4:-}"
    fi
    ;;
  complete)
    check_api_key
    [ -z "${2:-}" ] && { echo -e "${RED}Error:${NC} Missing prompt (use '-' for stdin)" >&2; exit 1; }
    text_completion "$2" "${3:-}"
    ;;
  image)
    check_api_key
    [ -z "${2:-}" ] && { echo -e "${RED}Error:${NC} Missing prompt" >&2; exit 1; }
    generate_image "$2" "${3:-}"
    ;;
  edit_image)
    check_api_key
    [ -z "${2:-}" ] && { echo -e "${RED}Error:${NC} Missing prompt" >&2; exit 1; }
    [ -z "${3:-}" ] && { echo -e "${RED}Error:${NC} Missing image file path" >&2; exit 1; }
    edit_image "$2" "$3"
    ;;
  arcana)
    check_api_key
    [ -z "${2:-}" ] && { echo -e "${RED}Error:${NC} Missing arcana ID" >&2; exit 1; }
    [ -z "${3:-}" ] && { echo -e "${RED}Error:${NC} Missing user prompt (use '-' for stdin)" >&2; exit 1; }
    chat_arcana "$2" "$3"
    ;;
  help)
    show_help
    ;;
  *)
    echo -e "${RED}Error:${NC} Unknown command: $1" >&2
    show_help >&2
    exit 1
    ;;
esac
