#!/bin/zsh

set -o pipefail

SCRIPT_DIR="${0:A:h}"
API_KEY_FILE="${ANYROUTER_API_KEY_FILE:-$SCRIPT_DIR/API_KEY}"
LOG_DIR="${ANYROUTER_LOG_DIR:-$SCRIPT_DIR/logs}"
LOG_FILE="${ANYROUTER_LOG_FILE:-$LOG_DIR/probe.tsv}"
STATE_FILE="${ANYROUTER_STATE_FILE:-$LOG_DIR/state}"

MODEL="${ANYROUTER_PROBE_MODEL:-claude-3-haiku-20240307}"
MAX_TOKENS="${ANYROUTER_PROBE_MAX_TOKENS:-1}"
CONNECT_TIMEOUT="${ANYROUTER_CONNECT_TIMEOUT:-10}"
MAX_TIME="${ANYROUTER_MAX_TIME:-30}"
AUTH_HEADER_STYLE="${ANYROUTER_AUTH_HEADER:-auto}"
NOTIFY_MODE="${ANYROUTER_NOTIFY_MODE:-always}"

NOTIFY=0
QUIET=0
TEST_NOTIFICATION=0

usage() {
  print -r -- "Usage: ./probe_anyrouter.zsh [--notify] [--quiet] [--test-notification]"
  print -r -- ""
  print -r -- "Options:"
  print -r -- "  --notify                 Show a macOS notification when at least one account is available."
  print -r -- "  --quiet                  Suppress terminal output; logs are still written."
  print -r -- "  --test-notification      Send a local test notification and exit."
  print -r -- "  --auth-header STYLE      auto, authorization, x-api-key, or both."
  print -r -- "  --model MODEL            Probe model name. Default: $MODEL"
  print -r -- "  --api-key-file PATH      File containing export ANTHROPIC_AUTH_TOKEN=... lines."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notify)
      NOTIFY=1
      ;;
    --no-notify)
      NOTIFY=0
      ;;
    --quiet)
      QUIET=1
      ;;
    --test-notification)
      TEST_NOTIFICATION=1
      NOTIFY=1
      ;;
    --auth-header)
      shift
      AUTH_HEADER_STYLE="${1:-}"
      ;;
    --model)
      shift
      MODEL="${1:-}"
      ;;
    --api-key-file)
      shift
      API_KEY_FILE="${1:-}"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      print -u2 -r -- "Unknown option: $1"
      usage >&2
      exit 2
      ;;
  esac
  shift
done

notify() {
  local title="$1"
  local message="$2"

  [[ "$NOTIFY" == "1" ]] || return 0
  [[ "$(uname -s)" == "Darwin" ]] || return 0
  [[ -x /usr/bin/osascript ]] || return 0

  /usr/bin/osascript \
    -e 'on run argv' \
    -e 'display notification (item 2 of argv) with title (item 1 of argv) sound name "Glass"' \
    -e 'end run' \
    "$title" "$message" >/dev/null 2>&1 || true
}

if [[ "$TEST_NOTIFICATION" == "1" ]]; then
  notify "Claude 状态监测" "通知链路测试：AnyRouter 探针已就绪"
  [[ "$QUIET" == "1" ]] || print -r -- "Sent test notification."
  exit 0
fi

if [[ ! -f "$API_KEY_FILE" ]]; then
  print -u2 -r -- "API key file not found: $API_KEY_FILE"
  exit 2
fi

extract_exports() {
  local name="$1"

  awk -v name="$name" '
    BEGIN { pattern = "^[[:space:]]*export[[:space:]]+" name "=" }
    $0 ~ pattern {
      sub(pattern, "", $0)
      sub(/[[:space:]]+#.*$/, "", $0)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      if ((substr($0, 1, 1) == "\"" && substr($0, length($0), 1) == "\"") ||
          (substr($0, 1, 1) == sprintf("%c", 39) && substr($0, length($0), 1) == sprintf("%c", 39))) {
        $0 = substr($0, 2, length($0) - 2)
      }
      if (length($0) > 0) print $0
    }
  ' "$API_KEY_FILE"
}

typeset -a api_keys filtered_keys base_values
api_keys=("${(@f)$(extract_exports ANTHROPIC_AUTH_TOKEN)}")
if [[ ${#api_keys[@]} -eq 0 ]]; then
  api_keys=("${(@f)$(extract_exports ANTHROPIC_API_KEY)}")
fi

for key in "${api_keys[@]}"; do
  [[ -n "$key" ]] && filtered_keys+=("$key")
done
api_keys=("${filtered_keys[@]}")

if [[ ${#api_keys[@]} -eq 0 ]]; then
  print -u2 -r -- "No ANTHROPIC_AUTH_TOKEN or ANTHROPIC_API_KEY exports found in $API_KEY_FILE"
  exit 2
fi

base_values=("${(@f)$(extract_exports ANTHROPIC_BASE_URL)}")
BASE_URL="${ANTHROPIC_BASE_URL:-}"
if [[ -z "$BASE_URL" && ${#base_values[@]} -gt 0 ]]; then
  BASE_URL="${base_values[-1]}"
fi
BASE_URL="${BASE_URL%/}"

if [[ -z "$BASE_URL" ]]; then
  print -u2 -r -- "No ANTHROPIC_BASE_URL found. Set it in $API_KEY_FILE or the environment."
  exit 2
fi

API_URL="${ANYROUTER_API_URL:-$BASE_URL/v1/messages}"

case "$AUTH_HEADER_STYLE" in
  auto|authorization|x-api-key|both)
    ;;
  *)
    print -u2 -r -- "Invalid auth header style: $AUTH_HEADER_STYLE"
    print -u2 -r -- "Use: auto, authorization, x-api-key, or both"
    exit 2
    ;;
esac

mkdir -p "$LOG_DIR"
if [[ ! -f "$LOG_FILE" ]]; then
  print -r -- "timestamp	account	header	http_code	category	duration_seconds	model	message" > "$LOG_FILE"
fi

build_payload() {
  printf '{"model":"%s","max_tokens":%s,"messages":[{"role":"user","content":"ping"}]}' "$MODEL" "$MAX_TOKENS"
}

summarize_file() {
  local file="$1"

  if [[ ! -s "$file" ]]; then
    print -r -- ""
    return 0
  fi

  tr '\r\n\t' '   ' < "$file" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | cut -c 1-240
}

classify_status() {
  local curl_rc="$1"
  local http_code="$2"

  if [[ "$curl_rc" != "0" || -z "$http_code" || "$http_code" == "000" ]]; then
    print -r -- "network_error"
    return 0
  fi

  case "$http_code" in
    200|201)
      print -r -- "available"
      ;;
    401|403)
      print -r -- "auth_failed"
      ;;
    408)
      print -r -- "timeout"
      ;;
    429)
      print -r -- "rate_limited_or_pool_busy"
      ;;
    500|502|503|504)
      print -r -- "upstream_unavailable"
      ;;
    *)
      print -r -- "http_$http_code"
      ;;
  esac
}

perform_request() {
  local key="$1"
  local header_style="$2"
  local body_file="$3"
  local err_file="$4"
  local payload meta curl_rc http_code duration
  local -a headers

  headers=(
    -H "anthropic-version: 2023-06-01"
    -H "content-type: application/json"
  )

  case "$header_style" in
    authorization)
      headers+=(-H "Authorization: Bearer $key")
      ;;
    x-api-key)
      headers+=(-H "x-api-key: $key")
      ;;
    both)
      headers+=(-H "Authorization: Bearer $key")
      headers+=(-H "x-api-key: $key")
      ;;
  esac

  payload="$(build_payload)"
  curl_rc=0
  meta=$(curl -sS \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$MAX_TIME" \
    -o "$body_file" \
    -w "%{http_code} %{time_total}" \
    "${headers[@]}" \
    "$API_URL" \
    -d "$payload" 2>"$err_file") || curl_rc=$?

  http_code="${meta%% *}"
  duration="${meta##* }"
  if [[ -z "$http_code" || "$http_code" == "$meta" ]]; then
    http_code="000"
    duration="0"
  fi

  print -r -- "$curl_rc|$http_code|$duration"
}

RESULT_HEADER=""
RESULT_HTTP_CODE=""
RESULT_CATEGORY=""
RESULT_DURATION=""
RESULT_MESSAGE=""

probe_one() {
  local key="$1"
  local body_file err_file result curl_rc http_code duration category message error_message
  local -a styles

  RESULT_HEADER=""
  RESULT_HTTP_CODE=""
  RESULT_CATEGORY=""
  RESULT_DURATION=""
  RESULT_MESSAGE=""

  if [[ "$AUTH_HEADER_STYLE" == "auto" ]]; then
    styles=(authorization x-api-key)
  else
    styles=("$AUTH_HEADER_STYLE")
  fi

  for style in "${styles[@]}"; do
    body_file="$(mktemp "${TMPDIR:-/tmp}/anyrouter_probe_body.XXXXXX")" || return 1
    err_file="$(mktemp "${TMPDIR:-/tmp}/anyrouter_probe_err.XXXXXX")" || {
      rm -f "$body_file"
      return 1
    }

    result="$(perform_request "$key" "$style" "$body_file" "$err_file")"
    curl_rc="${result%%|*}"
    result="${result#*|}"
    http_code="${result%%|*}"
    duration="${result##*|}"
    category="$(classify_status "$curl_rc" "$http_code")"
    message="$(summarize_file "$body_file")"
    error_message="$(summarize_file "$err_file")"
    rm -f "$body_file" "$err_file"

    if [[ "$category" == "network_error" && -n "$error_message" ]]; then
      message="$error_message"
    fi

    RESULT_HEADER="$style"
    RESULT_HTTP_CODE="$http_code"
    RESULT_CATEGORY="$category"
    RESULT_DURATION="$duration"
    RESULT_MESSAGE="$message"

    if [[ "$AUTH_HEADER_STYLE" == "auto" && "$style" == "authorization" ]]; then
      if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
        continue
      fi
      if [[ "$http_code" == "400" && "$message" == *api*key* ]]; then
        continue
      fi
    fi

    break
  done
}

join_by() {
  local sep="$1"
  shift

  if [[ $# -eq 0 ]]; then
    print -r -- ""
    return 0
  fi

  local out="$1"
  shift
  for item in "$@"; do
    out="$out$sep$item"
  done
  print -r -- "$out"
}

timestamp="$(date '+%Y-%m-%d %H:%M:%S %z')"
typeset -a available_accounts rate_limited_accounts failed_accounts

for i in {1..${#api_keys[@]}}; do
  account="account-$i"
  probe_one "${api_keys[$i]}"

  safe_message="${RESULT_MESSAGE//$'\t'/ }"
  print -r -- "$timestamp	$account	$RESULT_HEADER	$RESULT_HTTP_CODE	$RESULT_CATEGORY	$RESULT_DURATION	$MODEL	$safe_message" >> "$LOG_FILE"

  case "$RESULT_CATEGORY" in
    available)
      available_accounts+=("$account")
      ;;
    rate_limited_or_pool_busy|upstream_unavailable)
      rate_limited_accounts+=("$account")
      ;;
    *)
      failed_accounts+=("$account:$RESULT_CATEGORY")
      ;;
  esac

  if [[ "$QUIET" != "1" ]]; then
    print -r -- "$account	$RESULT_HEADER	$RESULT_HTTP_CODE	$RESULT_CATEGORY	${RESULT_DURATION}s	$RESULT_MESSAGE"
  fi
done

available_join="$(join_by ", " "${available_accounts[@]}")"
rate_limited_join="$(join_by ", " "${rate_limited_accounts[@]}")"
failed_join="$(join_by ", " "${failed_accounts[@]}")"

previous_state=""
if [[ -f "$STATE_FILE" ]]; then
  previous_state="$(<"$STATE_FILE")"
fi

if [[ ${#available_accounts[@]} -gt 0 ]]; then
  print -r -- "available	$timestamp	$available_join" > "$STATE_FILE"

  should_notify=0
  if [[ "$NOTIFY_MODE" == "on_change" ]]; then
    [[ "$previous_state" != available* ]] && should_notify=1
  else
    should_notify=1
  fi

  if [[ "$should_notify" == "1" ]]; then
    notify "Claude 状态监测" "AnyRouter 号池可用：$available_join"
  fi

  [[ "$QUIET" == "1" ]] || print -r -- "Summary: available via $available_join"
else
  print -r -- "unavailable	$timestamp	rate_limited=$rate_limited_join	failed=$failed_join" > "$STATE_FILE"
  [[ "$QUIET" == "1" ]] || print -r -- "Summary: unavailable. rate_limited=[$rate_limited_join] failed=[$failed_join]"
fi

exit 0
