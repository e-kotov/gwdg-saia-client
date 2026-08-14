#!/usr/bin/env bash

set -euo pipefail

# Configuration
BASE_URL="https://chat-ai.academiccloud.de/v1"
DEFAULT_CHAT_MODEL="meta-llama-3.1-8b-instruct"
DEFAULT_IMAGE_MODEL="flux"

# Colors for UX
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load .env if it exists in the current directory
if [ -f .env ]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ ! "$line" =~ ^# ]] && [[ "$line" == *=* ]]; then
      export "$line"
    fi
  done < .env
fi

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
    echo "Please set it in your environment or add it to a .env file as SAIA_API_KEY=your_key_here"
    exit 1
  fi
}

# Error Handling Helper
handle_api_response() {
  local response="$1"
  if [ -z "$response" ]; then
    echo -e "${RED}Error:${NC} Empty response from API." >&2
    exit 1
  fi
  if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    echo -e "${RED}API Error:${NC}"
    echo "$response" | jq -r '.error.message // .error'
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
  echo -e "${BLUE}SAIA CLI - Simple API Utility${NC}"
  echo ""
  echo "Usage: $0 <command> [arguments]"
  echo ""
  echo -e "${BLUE}Authentication:${NC}"
  echo "  Provide your API key in one of three ways:"
  echo "  1. Export it:        export SAIA_API_KEY='your_key'"
  echo "  2. .env file:        echo \"SAIA_API_KEY=your_key\" > .env"
  echo "  3. macOS Keychain:   automatically reads 'saia_api_key' if present"
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
  echo "  $0 chat \"Hello there\""
  echo "  $0 chat \"You are a poet\" \"Write a poem about Bash\""
  echo "  $0 limits"
  echo "  cat file.txt | $0 chat \"Summarize this\" -"
  echo ""
  echo "Limit note:"
  echo "  $0 limits sends a minimal 1-token request payload so Kong returns"
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
  (( days > 0 )) && parts+=("${days}d")
  (( hours > 0 )) && parts+=("${hours}h")
  (( minutes > 0 )) && parts+=("${minutes}m")
  (( seconds > 0 || ${#parts[@]} == 0 )) && parts+=("${seconds}s")

  local IFS=' '
  echo "${parts[*]}"
}

format_reset_time() {
  local reset_seconds="$1"
  [[ "$reset_seconds" =~ ^[0-9]+$ ]] || return 1

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

  local raw_resp header_block
  raw_resp=$(curl -s -i --max-time 5 "$BASE_URL/chat/completions" \
    -H "Authorization: Bearer $SAIA_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg model "$model" '{model: $model, messages: [{"role":"user","content":"."}], max_tokens: 1}')" || true)

  header_block=$(echo "$raw_resp" | sed -n '1,/^\r*$/p' | tr -d '\r')

  get_header_val() {
    local key="$1"
    echo "$header_block" | grep -i "^${key}:" | head -n1 | cut -d':' -f2- | xargs
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

  if [ -n "$lim_min" ]; then
    # SAIA supplies one generic `ratelimit-reset` header, not a separate reset
    # time for every window.  Show it only beside the quota window that is
    # actually exhausted.  Labelling it as a minute reset when the daily quota
    # is exhausted is misleading.
    local reset_window="" reset_suffix="" reset_note=""
    local min_reset_suffix="" hr_reset_suffix="" day_reset_suffix="" mo_reset_suffix=""
    local exhausted_windows=()
    [[ "$rem_min" == "0" ]] && exhausted_windows+=("Minute")
    [[ "$rem_hr" == "0" ]] && exhausted_windows+=("Hour")
    [[ "$rem_day" == "0" ]] && exhausted_windows+=("Day")
    [[ "$rem_mo" == "0" ]] && exhausted_windows+=("Month")

    if [ -n "$reset_sec" ]; then
      local reset_description
      reset_description=$(format_reset_time "$reset_sec" || true)
      if [ "${#exhausted_windows[@]}" -eq 1 ]; then
        reset_window="${exhausted_windows[0]}"
        [ -n "$reset_description" ] && reset_suffix="  (resets in ${reset_description})"
      elif [ "${#exhausted_windows[@]}" -gt 1 ]; then
        [ -n "$reset_description" ] && reset_note="next applicable reset in ${reset_description}"
      fi
    fi

    case "$reset_window" in
      Minute) min_reset_suffix="$reset_suffix" ;;
      Hour) hr_reset_suffix="$reset_suffix" ;;
      Day) day_reset_suffix="$reset_suffix" ;;
      Month) mo_reset_suffix="$reset_suffix" ;;
    esac

    echo ""
    echo -e "${BLUE}SAIA Account Rate Limits & Quota:${NC}"
    printf "  %-8s %s / %-5s remaining%s\n" "Minute:" "${rem_min:-?}" "${lim_min:-?}" "$min_reset_suffix"
    printf "  %-8s %s / %-5s remaining%s\n" "Hour:" "${rem_hr:-?}" "${lim_hr:-?}" "$hr_reset_suffix"
    printf "  %-8s %s / %-5s remaining%s\n" "Day:" "${rem_day:-?}" "${lim_day:-?}" "$day_reset_suffix"
    printf "  %-8s %s / %-5s remaining%s\n" "Month:" "${rem_mo:-?}" "${lim_mo:-?}" "$mo_reset_suffix"
    if [ -n "$reset_note" ]; then
      echo "  Reset:   ${reset_note}"
    fi
    echo ""
    echo -e "${RED}Note:${NC} Running this quota check consumed 1 request attempt from your API limit."
  else
    echo -e "${RED}Warning:${NC} Could not parse standard rate limit headers. Raw response headers:"
    echo "$header_block" | grep -iE "x-ratelimit|ratelimit" || echo "$header_block"
  fi
}

convert_doc() {
  local file="$1"
  [ -f "$file" ] || { echo -e "${RED}Error:${NC} File not found: $file"; exit 1; }

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

  [ -f "$file" ] || { echo -e "${RED}Error:${NC} File not found: $file"; exit 1; }

  echo -e "${BLUE}Performing audio $task for $file...${NC}" >&2
  local audio_url="https://saia.gwdg.de/v1/audio/$task"
  
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

  [ -f "$file" ] || { echo -e "${RED}Error:${NC} Image file not found: $file"; exit 1; }

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

# --- Main ---

check_deps

case "${1:-help}" in
  models)
    check_api_key && list_models
    ;;
  limits)
    check_api_key && show_limits "${2:-}"
    ;;
  convert)
    check_api_key
    [ -z "${2:-}" ] && { echo -e "${RED}Error:${NC} Missing file path"; exit 1; }
    convert_doc "$2"
    ;;
  embed)
    check_api_key
    [ -z "${2:-}" ] && { echo -e "${RED}Error:${NC} Missing text"; exit 1; }
    get_embeddings "$2"
    ;;
  audio)
    check_api_key
    [[ "${2:-}" != "transcriptions" && "${2:-}" != "translations" ]] && { echo -e "${RED}Error:${NC} Task must be 'transcriptions' or 'translations'"; exit 1; }
    [ -z "${3:-}" ] && { echo -e "${RED}Error:${NC} Missing file path"; exit 1; }
    handle_audio "$2" "$3" "${4:-}" "${5:-}"
    ;;
  chat)
    check_api_key
    if [ -z "${2:-}" ]; then
      echo -e "${RED}Error:${NC} Missing prompt"; exit 1
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
    [ -z "${2:-}" ] && { echo -e "${RED}Error:${NC} Missing prompt (use '-' for stdin)"; exit 1; }
    text_completion "$2" "${3:-}"
    ;;
  image)
    check_api_key
    [ -z "${2:-}" ] && { echo -e "${RED}Error:${NC} Missing prompt"; exit 1; }
    generate_image "$2" "${3:-}"
    ;;
  edit_image)
    check_api_key
    [ -z "${2:-}" ] && { echo -e "${RED}Error:${NC} Missing prompt"; exit 1; }
    [ -z "${3:-}" ] && { echo -e "${RED}Error:${NC} Missing image file path"; exit 1; }
    edit_image "$2" "$3"
    ;;
  arcana)
    check_api_key
    [ -z "${2:-}" ] && { echo -e "${RED}Error:${NC} Missing arcana ID"; exit 1; }
    [ -z "${3:-}" ] && { echo -e "${RED}Error:${NC} Missing user prompt (use '-' for stdin)"; exit 1; }
    chat_arcana "$2" "$3"
    ;;
  help|--help|-h)
    show_help
    ;;
  *)
    echo -e "${RED}Error:${NC} Unknown command: $1" >&2
    show_help
    exit 1
    ;;
esac
