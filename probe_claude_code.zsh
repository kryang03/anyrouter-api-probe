#!/bin/zsh

set -o pipefail

SCRIPT_DIR="${0:A:h}"
API_KEY_FILE="${ANYROUTER_API_KEY_FILE:-$SCRIPT_DIR/API_KEY}"
LOG_DIR="${ANYROUTER_LOG_DIR:-$SCRIPT_DIR/logs}"
LOG_FILE="${ANYROUTER_CLAUDE_LOG_FILE:-$LOG_DIR/claude-code.tsv}"
STATE_FILE="${ANYROUTER_CLAUDE_STATE_FILE:-$LOG_DIR/claude-code.state}"
LOOP_STATE_FILE="${ANYROUTER_CLAUDE_LOOP_STATE_FILE:-$LOG_DIR/claude-code.loop.state}"
LABEL="${ANYROUTER_CLAUDE_LABEL:-com.yang.anyrouter-probe.claude-code}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

MODEL="${ANYROUTER_CLAUDE_MODEL:-opus[1m]}"
API_MODEL="${ANYROUTER_CLAUDE_API_MODEL:-claude-opus-4-8}"
MAX_TOKENS="${ANYROUTER_CLAUDE_MAX_TOKENS:-1}"
PROMPT="${ANYROUTER_CLAUDE_PROMPT:-hi}"
ANTHROPIC_BETA="${ANYROUTER_CLAUDE_BETA:-context-1m-2025-08-07}"
CONNECT_TIMEOUT="${ANYROUTER_CONNECT_TIMEOUT:-10}"
MAX_TIME="${ANYROUTER_MAX_TIME:-120}"
AUTH_HEADER_STYLE="${ANYROUTER_CLAUDE_AUTH_HEADER:-authorization}"
INTERVAL_RAW="${ANYROUTER_CLAUDE_INTERVAL:-15m}"
NOTIFY_MODE="${ANYROUTER_NOTIFY_MODE:-always}"
LAUNCHD_PATH="${ANYROUTER_LAUNCHD_PATH:-$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"
INHERIT_PROXY="${ANYROUTER_LAUNCHD_INHERIT_PROXY:-1}"
NOTIFY_METHOD="${ANYROUTER_NOTIFY_METHOD:-dialog}"
NOTIFY_APP_BUNDLE="${ANYROUTER_NOTIFY_APP_BUNDLE:-com.microsoft.VSCode}"
NOTIFY_SOUND="${ANYROUTER_NOTIFY_SOUND:-Glass}"
NOTIFY_ALERT_SECONDS="${ANYROUTER_NOTIFY_ALERT_SECONDS:-8}"
NOTIFY_DIALOG_SECONDS="${ANYROUTER_NOTIFY_DIALOG_SECONDS:-0}"
NOTIFY_GROUP="${ANYROUTER_NOTIFY_GROUP:-anyrouter-api-probe}"
NOTIFY_IGNORE_DND="${ANYROUTER_NOTIFY_IGNORE_DND:-1}"
PROBE_MODE="${ANYROUTER_CLAUDE_MODE:-cli}"
CLAUDE_BIN="${ANYROUTER_CLAUDE_BIN:-}"
CLAUDE_SETTINGS="${ANYROUTER_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
EFFORT_LEVEL="${ANYROUTER_CLAUDE_EFFORT:-xhigh}"
ALL_ACCOUNTS="${ANYROUTER_CLAUDE_ALL_ACCOUNTS:-0}"
STOP_ON_AVAILABLE="${ANYROUTER_CLAUDE_STOP_ON_AVAILABLE:-${ANYROUTER_STOP_ON_AVAILABLE:-0}}"

COMMAND="once"
NOTIFY=1
QUIET=0
STOP_ON_AVAILABLE_SET=0
if (( ${+ANYROUTER_CLAUDE_STOP_ON_AVAILABLE} || ${+ANYROUTER_STOP_ON_AVAILABLE} )); then
  STOP_ON_AVAILABLE_SET=1
fi

usage() {
  print -r -- "Usage: ./probe_claude_code.zsh [once|start|stop|status|health|tail|test-notification] [options]"
  print -r -- ""
  print -r -- "Options:"
  print -r -- "  -i, --interval VALUE     launchd interval, for example 15m, 900s, 1h, or 900."
  print -r -- "  --notify                 Show macOS notification when at least one account is available."
  print -r -- "  --no-notify              Disable notification for this run."
  print -r -- "  --notify-mode MODE       always or on-change. Default: always."
  print -r -- "  --notify-method METHOD   auto, terminal-notifier, vscode, osascript, dialog, alert, sound, bell, or all. Default: dialog."
  print -r -- "  --quiet                  Suppress terminal output; logs are still written."
  print -r -- "  --mode MODE              cli or api. Default: cli."
  print -r -- "  --auth-header STYLE      authorization, x-api-key, or both. Default: authorization."
  print -r -- "  --model MODEL            Claude Code model. Default: $MODEL"
  print -r -- "  --api-model MODEL        Direct API model for --mode api. Default: $API_MODEL"
  print -r -- "  --prompt TEXT            Probe prompt. Default: $PROMPT"
  print -r -- "  --beta VALUE             anthropic-beta header. Default: $ANTHROPIC_BETA"
  print -r -- "  --settings PATH          Claude settings path. Default: $CLAUDE_SETTINGS"
  print -r -- "  --effort LEVEL           Claude effort level. Default: $EFFORT_LEVEL"
  print -r -- "  --claude-bin PATH        Claude CLI path. Default: auto-detect."
  print -r -- "  --all-accounts           Probe every account even after one succeeds."
  print -r -- "  --stop-on-available      Stop the launchd probe after an available result. Default for start."
  print -r -- "  --always                 Keep launchd polling after available results."
  print -r -- "  --api-key-file PATH      API_KEY file path. Default: $API_KEY_FILE"
}

if [[ $# -gt 0 && "$1" != -* ]]; then
  COMMAND="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--interval)
      shift
      INTERVAL_RAW="${1:-}"
      ;;
    --notify)
      NOTIFY=1
      ;;
    --no-notify)
      NOTIFY=0
      ;;
    --notify-mode)
      shift
      NOTIFY_MODE="${1:-}"
      ;;
    --notify-method)
      shift
      NOTIFY_METHOD="${1:-}"
      ;;
    --quiet)
      QUIET=1
      ;;
    --mode)
      shift
      PROBE_MODE="${1:-}"
      ;;
    --auth-header)
      shift
      AUTH_HEADER_STYLE="${1:-}"
      ;;
    --model)
      shift
      MODEL="${1:-}"
      ;;
    --api-model)
      shift
      API_MODEL="${1:-}"
      ;;
    --prompt)
      shift
      PROMPT="${1:-}"
      ;;
    --beta)
      shift
      ANTHROPIC_BETA="${1:-}"
      ;;
    --settings)
      shift
      CLAUDE_SETTINGS="${1:-}"
      ;;
    --effort)
      shift
      EFFORT_LEVEL="${1:-}"
      ;;
    --claude-bin)
      shift
      CLAUDE_BIN="${1:-}"
      ;;
    --all-accounts)
      ALL_ACCOUNTS=1
      ;;
    --stop-on-available)
      STOP_ON_AVAILABLE=1
      STOP_ON_AVAILABLE_SET=1
      ;;
    --always)
      STOP_ON_AVAILABLE=0
      STOP_ON_AVAILABLE_SET=1
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

parse_interval() {
  local raw="$1"
  local value unit

  if [[ "$raw" == <-> ]]; then
    print -r -- "$raw"
    return 0
  fi

  if [[ "$raw" =~ '^([0-9]+)(s|m|h)$' ]]; then
    value="${match[1]}"
    unit="${match[2]}"
    case "$unit" in
      s) print -r -- "$value" ;;
      m) print -r -- "$(( value * 60 ))" ;;
      h) print -r -- "$(( value * 3600 ))" ;;
    esac
    return 0
  fi

  print -u2 -r -- "Invalid interval: $raw"
  print -u2 -r -- "Use examples like 15m, 900s, 1h, or 900."
  return 2
}

xml_escape() {
  sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g" <<< "$1"
}

plist_arg_after() {
  local option="$1"
  [[ -f "$PLIST" ]] || return 0

  plutil -extract ProgramArguments xml1 -o - "$PLIST" 2>/dev/null | awk -v opt="$option" '
    found && /<string>/ {
      gsub(/^.*<string>/, "", $0)
      gsub(/<\/string>.*$/, "", $0)
      print
      exit
    }
    $0 ~ "<string>" opt "</string>" { found = 1 }
  '
}

format_epoch() {
  date -r "$1" '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S %z'
}

self_stop_agent() {
  [[ "$(uname -s)" == "Darwin" ]] || return 0
  launchctl bootout "gui/$UID" "$PLIST" >/dev/null 2>&1 || true
  rm -f "$PLIST"
}

notify() {
  local title="$1"
  local message="$2"
  local method_rc sent=1
  local terminal_notifier=""
  local -a attempts

  [[ "$NOTIFY" == "1" ]] || return 0
  [[ "$(uname -s)" == "Darwin" ]] || return 0

  if [[ "$NOTIFY_METHOD" == "auto" || "$NOTIFY_METHOD" == "terminal-notifier" || "$NOTIFY_METHOD" == "notifier" || "$NOTIFY_METHOD" == "all" ]]; then
    terminal_notifier="${ANYROUTER_TERMINAL_NOTIFIER:-$(command -v terminal-notifier 2>/dev/null || true)}"
    if [[ -n "$terminal_notifier" && -x "$terminal_notifier" ]]; then
      local -a tn_args
      tn_args=(-title "$title" -message "$message" -group "$NOTIFY_GROUP")
      [[ -n "$NOTIFY_SOUND" ]] && tn_args+=(-sound "$NOTIFY_SOUND")
      [[ "$NOTIFY_IGNORE_DND" == "1" ]] && tn_args+=(-ignoreDnD)
      "$terminal_notifier" "${tn_args[@]}" >/dev/null 2>&1
      method_rc=$?
      attempts+=("terminal-notifier:$method_rc")
      [[ "$method_rc" == "0" ]] && sent=0
      if [[ "$NOTIFY_VERBOSE" == "1" && "$method_rc" == "0" ]]; then
        "$terminal_notifier" -list "$NOTIFY_GROUP" 2>/dev/null | sed -n '1,2p'
      fi
    else
      attempts+=("terminal-notifier:missing")
    fi
  fi

  if [[ "$NOTIFY_METHOD" == "auto" || "$NOTIFY_METHOD" == "vscode" || "$NOTIFY_METHOD" == "all" ]]; then
    if [[ -n "$NOTIFY_APP_BUNDLE" && -x /usr/bin/osascript ]]; then
      /usr/bin/osascript \
        -e 'on run argv' \
        -e 'tell application id (item 1 of argv) to display notification (item 3 of argv) with title (item 2 of argv) sound name (item 4 of argv)' \
        -e 'end run' \
        "$NOTIFY_APP_BUNDLE" "$title" "$message" "$NOTIFY_SOUND" >/dev/null 2>&1
      method_rc=$?
      attempts+=("app:$method_rc")
      [[ "$method_rc" == "0" ]] && sent=0
    fi
  fi

  if [[ "$NOTIFY_METHOD" == "auto" || "$NOTIFY_METHOD" == "osascript" || "$NOTIFY_METHOD" == "all" ]]; then
    if [[ -x /usr/bin/osascript ]]; then
      /usr/bin/osascript \
        -e 'on run argv' \
        -e 'display notification (item 2 of argv) with title (item 1 of argv) sound name (item 3 of argv)' \
        -e 'end run' \
        "$title" "$message" "$NOTIFY_SOUND" >/dev/null 2>&1
      method_rc=$?
      attempts+=("osascript:$method_rc")
      [[ "$method_rc" == "0" ]] && sent=0
    fi
  fi

  if [[ "$NOTIFY_METHOD" == "alert" || "$NOTIFY_METHOD" == "all" ]]; then
    if [[ -x /usr/bin/osascript ]]; then
      /usr/bin/osascript \
        -e 'on run argv' \
        -e 'display alert (item 1 of argv) message (item 2 of argv) giving up after ((item 3 of argv) as integer)' \
        -e 'end run' \
        "$title" "$message" "$NOTIFY_ALERT_SECONDS" >/dev/null 2>&1 &
      attempts+=("alert:background")
      sent=0
    fi
  fi

  if [[ "$NOTIFY_METHOD" == "dialog" || "$NOTIFY_METHOD" == "all" ]]; then
    if [[ -x /usr/bin/osascript ]]; then
      if [[ "$NOTIFY_DIALOG_SECONDS" == <-> && "$NOTIFY_DIALOG_SECONDS" -gt 0 ]]; then
        /usr/bin/osascript \
          -e 'on run argv' \
          -e 'display dialog (item 2 of argv) with title (item 1 of argv) buttons {"OK"} default button "OK" giving up after ((item 3 of argv) as integer)' \
          -e 'end run' \
          "$title" "$message" "$NOTIFY_DIALOG_SECONDS" >/dev/null 2>&1 &
      else
        /usr/bin/osascript \
          -e 'on run argv' \
          -e 'display dialog (item 2 of argv) with title (item 1 of argv) buttons {"OK"} default button "OK"' \
          -e 'end run' \
          "$title" "$message" >/dev/null 2>&1 &
      fi
      attempts+=("dialog:background")
      sent=0
    fi
  fi

  if [[ "$NOTIFY_METHOD" == "auto" || "$NOTIFY_METHOD" == "sound" || "$NOTIFY_METHOD" == "all" ]]; then
    if [[ -x /usr/bin/afplay && -f "/System/Library/Sounds/$NOTIFY_SOUND.aiff" ]]; then
      /usr/bin/afplay "/System/Library/Sounds/$NOTIFY_SOUND.aiff" >/dev/null 2>&1 &
      attempts+=("sound:background")
    fi
  fi

  if [[ "$NOTIFY_METHOD" == "auto" || "$NOTIFY_METHOD" == "bell" || "$NOTIFY_METHOD" == "all" ]]; then
    { printf '\a' > /dev/tty; } >/dev/null 2>&1 || printf '\a'
    attempts+=("bell:sent")
  fi

  if [[ "$NOTIFY_VERBOSE" == "1" ]]; then
    print -r -- "Notification attempts: ${(j:, :)attempts}"
  fi

  return "$sent"
}

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
    200|201) print -r -- "available" ;;
    401|403) print -r -- "auth_failed" ;;
    408) print -r -- "timeout" ;;
    429) print -r -- "rate_limited_or_pool_busy" ;;
    500|502|503|504) print -r -- "upstream_unavailable" ;;
    *) print -r -- "http_$http_code" ;;
  esac
}

resolve_claude_bin() {
  if [[ -n "$CLAUDE_BIN" ]]; then
    print -r -- "$CLAUDE_BIN"
    return 0
  fi

  local found=""
  found="$(command -v claude 2>/dev/null || true)"
  if [[ -z "$found" ]]; then
    found="$(find "$HOME/.local/bin" "$HOME/.npm-global/bin" "$HOME/.nvm" -name claude -type f -perm -111 2>/dev/null | sort | tail -n 1)"
  fi

  if [[ -z "$found" ]]; then
    print -u2 -r -- "Cannot find Claude CLI. Pass --claude-bin /path/to/claude."
    return 2
  fi

  print -r -- "$found"
}

run_claude_cli_account() {
  local key="$1"
  local base_url="$2"
  local claude_bin="$3"
  local out_file err_file rc output summary pid waited
  local -a args

  out_file="$(mktemp "${TMPDIR:-/tmp}/claude_probe_out.XXXXXX")" || return 1
  err_file="$(mktemp "${TMPDIR:-/tmp}/claude_probe_err.XXXXXX")" || {
    rm -f "$out_file"
    return 1
  }

  args=(
    --print
    --output-format text
    --no-session-persistence
    --settings "$CLAUDE_SETTINGS"
    --model "$MODEL"
    --effort "$EFFORT_LEVEL"
    --permission-mode dontAsk
  )
  if [[ -n "$ANTHROPIC_BETA" ]]; then
    args+=("--betas=$ANTHROPIC_BETA")
  fi
  args+=("$PROMPT")

  rc=0
  (
    export ANTHROPIC_AUTH_TOKEN="$key"
    export ANTHROPIC_API_KEY="$key"
    export ANTHROPIC_BASE_URL="$base_url"
    exec "$claude_bin" "${args[@]}"
  ) >"$out_file" 2>"$err_file" &
  pid=$!
  waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$(( waited + 1 ))
    if (( waited >= MAX_TIME )); then
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rc=124
      break
    fi
  done
  if [[ "$rc" != "124" ]]; then
    wait "$pid" || rc=$?
  fi

  output="$(summarize_file "$out_file") $(summarize_file "$err_file")"
  rm -f "$out_file" "$err_file"

  if [[ "$rc" == "124" ]]; then
    summary="$(print -r -- "$output" | cut -c 1-240)"
    print -r -- "timeout|exceeded ${MAX_TIME}s $summary"
    return 0
  fi

  if [[ "$rc" == "0" ]]; then
    summary="$(print -r -- "$output" | cut -c 1-240)"
    print -r -- "available|$summary"
    return 0
  fi

  if [[ "$output" == *"429"* || "$output" == *"rate_limit"* || "$output" == *"rate limit"* ]]; then
    summary="$(print -r -- "$output" | cut -c 1-240)"
    print -r -- "rate_limited_or_pool_busy|$summary"
    return 0
  fi

  if [[ "$output" == *"503"* || "$output" == *"Service Unavailable"* || "$output" == *"overloaded"* ]]; then
    summary="$(print -r -- "$output" | cut -c 1-240)"
    print -r -- "upstream_unavailable|$summary"
    return 0
  fi

  if [[ "$output" == *"401"* || "$output" == *"403"* || "$output" == *"Unauthorized"* || "$output" == *"authentication"* ]]; then
    summary="$(print -r -- "$output" | cut -c 1-240)"
    print -r -- "auth_failed|$summary"
    return 0
  fi

  summary="$(print -r -- "$output" | cut -c 1-240)"
  print -r -- "claude_cli_error|exit=$rc $summary"
}

run_probe() {
  if [[ ! -f "$API_KEY_FILE" ]]; then
    print -u2 -r -- "API key file not found: $API_KEY_FILE"
    return 2
  fi

  case "$PROBE_MODE" in
    cli|api) ;;
    *)
      print -u2 -r -- "Invalid mode: $PROBE_MODE"
      return 2
      ;;
  esac

  case "$AUTH_HEADER_STYLE" in
    authorization|x-api-key|both) ;;
    *)
      print -u2 -r -- "Invalid auth header style: $AUTH_HEADER_STYLE"
      return 2
      ;;
  esac

  typeset -a api_keys base_values available_accounts rate_limited_accounts failed_accounts
  api_keys=("${(@f)$(extract_exports ANTHROPIC_AUTH_TOKEN)}")
  if [[ ${#api_keys[@]} -eq 0 ]]; then
    api_keys=("${(@f)$(extract_exports ANTHROPIC_API_KEY)}")
  fi

  if [[ ${#api_keys[@]} -eq 0 ]]; then
    print -u2 -r -- "No ANTHROPIC_AUTH_TOKEN or ANTHROPIC_API_KEY exports found in $API_KEY_FILE"
    return 2
  fi

  base_values=("${(@f)$(extract_exports ANTHROPIC_BASE_URL)}")
  BASE_URL="${ANTHROPIC_BASE_URL:-}"
  if [[ -z "$BASE_URL" && ${#base_values[@]} -gt 0 ]]; then
    BASE_URL="${base_values[-1]}"
  fi
  BASE_URL="${BASE_URL%/}"

  if [[ -z "$BASE_URL" ]]; then
    print -u2 -r -- "No ANTHROPIC_BASE_URL found in $API_KEY_FILE"
    return 2
  fi

  local api_url="${ANYROUTER_CLAUDE_API_URL:-$BASE_URL/v1/messages}"
  local claude_bin=""
  if [[ "$PROBE_MODE" == "cli" ]]; then
    claude_bin="$(resolve_claude_bin)" || return $?
  fi

  local timestamp account body_file err_file meta curl_rc http_code duration category message error_message key result started ended
  local -a headers

  mkdir -p "$LOG_DIR"
  if [[ ! -f "$LOG_FILE" ]]; then
    print -r -- "timestamp	account	header	http_code	category	duration_seconds	model	message" > "$LOG_FILE"
  fi

  timestamp="$(date '+%Y-%m-%d %H:%M:%S %z')"

  for i in {1..${#api_keys[@]}}; do
    key="${api_keys[$i]}"
    account="account-$i"
    if [[ "$PROBE_MODE" == "cli" ]]; then
      started="$(date +%s)"
      result="$(run_claude_cli_account "$key" "$BASE_URL" "$claude_bin")"
      ended="$(date +%s)"
      duration="$(( ended - started ))"
      category="${result%%|*}"
      message="${result#*|}"

      print -r -- "$timestamp	$account	claude-cli	cli	$category	$duration	$MODEL	${message//$'\t'/ }" >> "$LOG_FILE"

      case "$category" in
        available) available_accounts+=("$account") ;;
        rate_limited_or_pool_busy|upstream_unavailable) rate_limited_accounts+=("$account") ;;
        *) failed_accounts+=("$account:$category") ;;
      esac

      [[ "$QUIET" == "1" ]] || print -r -- "$account	claude-cli	cli	$category	${duration}s	$message"
      if [[ "$category" == "available" && "$ALL_ACCOUNTS" != "1" ]]; then
        break
      fi
      continue
    fi

    body_file="$(mktemp "${TMPDIR:-/tmp}/claude_probe_body.XXXXXX")" || return 1
    err_file="$(mktemp "${TMPDIR:-/tmp}/claude_probe_err.XXXXXX")" || {
      rm -f "$body_file"
      return 1
    }

    headers=(-H "anthropic-version: 2023-06-01" -H "content-type: application/json")
    if [[ -n "$ANTHROPIC_BETA" ]]; then
      headers+=(-H "anthropic-beta: $ANTHROPIC_BETA")
    fi
    case "$AUTH_HEADER_STYLE" in
      authorization) headers+=(-H "Authorization: Bearer $key") ;;
      x-api-key) headers+=(-H "x-api-key: $key") ;;
      both)
        headers+=(-H "Authorization: Bearer $key")
        headers+=(-H "x-api-key: $key")
        ;;
    esac

    curl_rc=0
    meta=$(curl -sS \
      --connect-timeout "$CONNECT_TIMEOUT" \
      --max-time "$MAX_TIME" \
      -o "$body_file" \
      -w "%{http_code} %{time_total}" \
      "${headers[@]}" \
      "$api_url" \
      -d "{\"model\":\"$API_MODEL\",\"max_tokens\":$MAX_TOKENS,\"messages\":[{\"role\":\"user\",\"content\":\"$PROMPT\"}]}" 2>"$err_file") || curl_rc=$?

    http_code="${meta%% *}"
    duration="${meta##* }"
    if [[ -z "$http_code" || "$http_code" == "$meta" ]]; then
      http_code="000"
      duration="0"
    fi

    category="$(classify_status "$curl_rc" "$http_code")"
    message="$(summarize_file "$body_file")"
    error_message="$(summarize_file "$err_file")"
    rm -f "$body_file" "$err_file"

    if [[ "$category" == "network_error" && -n "$error_message" ]]; then
      message="$error_message"
    fi

    print -r -- "$timestamp	$account	$AUTH_HEADER_STYLE	$http_code	$category	$duration	$API_MODEL	${message//$'\t'/ }" >> "$LOG_FILE"

    case "$category" in
      available) available_accounts+=("$account") ;;
      rate_limited_or_pool_busy|upstream_unavailable) rate_limited_accounts+=("$account") ;;
      *) failed_accounts+=("$account:$category") ;;
    esac

    [[ "$QUIET" == "1" ]] || print -r -- "$account	$AUTH_HEADER_STYLE	$http_code	$category	${duration}s	$message"
  done

  local available_join="${(j:, :)available_accounts}"
  local rate_limited_join="${(j:, :)rate_limited_accounts}"
  local failed_join="${(j:, :)failed_accounts}"
  local previous_state=""
  [[ -f "$STATE_FILE" ]] && previous_state="$(<"$STATE_FILE")"

  if [[ ${#available_accounts[@]} -gt 0 ]]; then
    print -r -- "available	$timestamp	$available_join" > "$STATE_FILE"
    if [[ "$NOTIFY_MODE" != "on-change" || "$previous_state" != available* ]]; then
      notify "Claude Code Probe" "AnyRouter Claude 可用：$available_join"
    fi
    [[ "$QUIET" == "1" ]] || print -r -- "Summary: available via $available_join"
    if [[ "$STOP_ON_AVAILABLE" == "1" ]]; then
      self_stop_agent
      [[ "$QUIET" == "1" ]] || print -r -- "Stopped launchd probe after availability."
    fi
  else
    print -r -- "unavailable	$timestamp	rate_limited=$rate_limited_join	failed=$failed_join" > "$STATE_FILE"
    [[ "$QUIET" == "1" ]] || print -r -- "Summary: unavailable. rate_limited=[$rate_limited_join] failed=[$failed_join]"
  fi
}

write_plist() {
  local interval_seconds="$1"
  local escaped_label escaped_script escaped_workdir escaped_stdout escaped_stderr escaped_path escaped_api_key_file
  local escaped_log_dir escaped_log_file escaped_state_file escaped_loop_state_file

  mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"
  escaped_label="$(xml_escape "$LABEL")"
  escaped_script="$(xml_escape "$SCRIPT_DIR/probe_claude_code.zsh")"
  escaped_workdir="$(xml_escape "$SCRIPT_DIR")"
  escaped_stdout="$(xml_escape "$LOG_DIR/claude-code.launchd.out.log")"
  escaped_stderr="$(xml_escape "$LOG_DIR/claude-code.launchd.err.log")"
  escaped_path="$(xml_escape "$LAUNCHD_PATH")"
  escaped_api_key_file="$(xml_escape "$API_KEY_FILE")"
  escaped_log_dir="$(xml_escape "$LOG_DIR")"
  escaped_log_file="$(xml_escape "$LOG_FILE")"
  escaped_state_file="$(xml_escape "$STATE_FILE")"
  escaped_loop_state_file="$(xml_escape "$LOOP_STATE_FILE")"
  local plist_claude_bin
  plist_claude_bin="${CLAUDE_BIN:-$(resolve_claude_bin)}"

  {
    print -r -- '<?xml version="1.0" encoding="UTF-8"?>'
    print -r -- '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    print -r -- '<plist version="1.0">'
    print -r -- '<dict>'
    print -r -- '  <key>Label</key>'
    print -r -- "  <string>$escaped_label</string>"
    print -r -- '  <key>ProgramArguments</key>'
    print -r -- '  <array>'
    print -r -- '    <string>/bin/zsh</string>'
    print -r -- "    <string>$escaped_script</string>"
    print -r -- '    <string>loop</string>'
    print -r -- '    <string>--interval</string>'
    print -r -- "    <string>$interval_seconds</string>"
    print -r -- '    <string>--notify</string>'
    print -r -- '    <string>--quiet</string>'
    print -r -- '    <string>--notify-mode</string>'
    print -r -- "    <string>$(xml_escape "$NOTIFY_MODE")</string>"
    print -r -- '    <string>--notify-method</string>'
    print -r -- "    <string>$(xml_escape "$NOTIFY_METHOD")</string>"
    print -r -- '    <string>--mode</string>'
    print -r -- "    <string>$(xml_escape "$PROBE_MODE")</string>"
    print -r -- '    <string>--auth-header</string>'
    print -r -- "    <string>$(xml_escape "$AUTH_HEADER_STYLE")</string>"
    print -r -- '    <string>--model</string>'
    print -r -- "    <string>$(xml_escape "$MODEL")</string>"
    print -r -- '    <string>--api-model</string>'
    print -r -- "    <string>$(xml_escape "$API_MODEL")</string>"
    print -r -- '    <string>--prompt</string>'
    print -r -- "    <string>$(xml_escape "$PROMPT")</string>"
    print -r -- '    <string>--beta</string>'
    print -r -- "    <string>$(xml_escape "$ANTHROPIC_BETA")</string>"
    print -r -- '    <string>--settings</string>'
    print -r -- "    <string>$(xml_escape "$CLAUDE_SETTINGS")</string>"
    print -r -- '    <string>--effort</string>'
    print -r -- "    <string>$(xml_escape "$EFFORT_LEVEL")</string>"
    print -r -- '    <string>--claude-bin</string>'
    print -r -- "    <string>$(xml_escape "$plist_claude_bin")</string>"
    if [[ "$ALL_ACCOUNTS" == "1" ]]; then
      print -r -- '    <string>--all-accounts</string>'
    fi
    if [[ "$STOP_ON_AVAILABLE" == "1" ]]; then
      print -r -- '    <string>--stop-on-available</string>'
    fi
    print -r -- '    <string>--api-key-file</string>'
    print -r -- "    <string>$escaped_api_key_file</string>"
    print -r -- '  </array>'
    print -r -- '  <key>WorkingDirectory</key>'
    print -r -- "  <string>$escaped_workdir</string>"
    print -r -- '  <key>EnvironmentVariables</key>'
    print -r -- '  <dict>'
    print -r -- '    <key>PATH</key>'
    print -r -- "    <string>$escaped_path</string>"
    print -r -- '    <key>ANYROUTER_LOG_DIR</key>'
    print -r -- "    <string>$escaped_log_dir</string>"
    print -r -- '    <key>ANYROUTER_CLAUDE_LOG_FILE</key>'
    print -r -- "    <string>$escaped_log_file</string>"
    print -r -- '    <key>ANYROUTER_CLAUDE_STATE_FILE</key>'
    print -r -- "    <string>$escaped_state_file</string>"
    print -r -- '    <key>ANYROUTER_CLAUDE_LOOP_STATE_FILE</key>'
    print -r -- "    <string>$escaped_loop_state_file</string>"
    if [[ "$INHERIT_PROXY" == "1" ]]; then
      local proxy_name proxy_value
      for proxy_name in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy; do
        if (( ${+parameters[$proxy_name]} )); then
          proxy_value="${(P)proxy_name}"
        else
          proxy_value=""
        fi
        if [[ -n "$proxy_value" ]]; then
          print -r -- "    <key>$(xml_escape "$proxy_name")</key>"
          print -r -- "    <string>$(xml_escape "$proxy_value")</string>"
        fi
      done
    fi
    print -r -- '  </dict>'
    print -r -- '  <key>RunAtLoad</key>'
    print -r -- '  <true/>'
    print -r -- '  <key>StandardOutPath</key>'
    print -r -- "  <string>$escaped_stdout</string>"
    print -r -- '  <key>StandardErrorPath</key>'
    print -r -- "  <string>$escaped_stderr</string>"
    print -r -- '</dict>'
    print -r -- '</plist>'
  } > "$PLIST"

  chmod 644 "$PLIST"
}

loop_agent() {
  local interval_seconds started ended next_start sleep_seconds loop_status next_start_text
  interval_seconds="$(parse_interval "$INTERVAL_RAW")" || return $?
  mkdir -p "$LOG_DIR"

  while true; do
    started="$(date +%s)"
    print -r -- "running	$(date '+%Y-%m-%d %H:%M:%S %z')	interval=${interval_seconds}s" > "$LOOP_STATE_FILE"
    run_probe || true

    if [[ "$STOP_ON_AVAILABLE" == "1" && -f "$STATE_FILE" && "$(<"$STATE_FILE")" == available* ]]; then
      print -r -- "stopped_available	$(date '+%Y-%m-%d %H:%M:%S %z')	interval=${interval_seconds}s" > "$LOOP_STATE_FILE"
      return 0
    fi

    ended="$(date +%s)"
    next_start="$(( started + interval_seconds ))"
    sleep_seconds="$(( next_start - ended ))"
    if (( sleep_seconds > 0 )); then
      next_start_text="$(format_epoch "$next_start")"
      print -r -- "sleeping	$(date '+%Y-%m-%d %H:%M:%S %z')	next_start=$next_start_text	sleep=${sleep_seconds}s	interval=${interval_seconds}s" > "$LOOP_STATE_FILE"
      sleep "$sleep_seconds"
    else
      loop_status="$(( -sleep_seconds ))"
      print -r -- "behind	$(date '+%Y-%m-%d %H:%M:%S %z')	lag=${loop_status}s	interval=${interval_seconds}s" > "$LOOP_STATE_FILE"
    fi
  done
}

start_agent() {
  [[ "$(uname -s)" == "Darwin" ]] || { print -u2 -r -- "launchd is only supported on macOS."; return 2; }
  local interval_seconds
  interval_seconds="$(parse_interval "$INTERVAL_RAW")" || return $?
  if [[ "$STOP_ON_AVAILABLE_SET" != "1" ]]; then
    STOP_ON_AVAILABLE=1
  fi

  write_plist "$interval_seconds"
  launchctl bootout "gui/$UID" "$PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$UID" "$PLIST"
  launchctl kickstart "gui/$UID/$LABEL" >/dev/null 2>&1 || true

  print -r -- "Started Claude Code probe: $LABEL"
  if [[ "$STOP_ON_AVAILABLE" == "1" ]]; then
    print -r -- "Mode: stop-on-available"
  else
    print -r -- "Mode: always"
  fi
  print -r -- "Interval: ${interval_seconds}s"
  print -r -- "Schedule: start-to-start"
  print -r -- "Log: $LOG_FILE"
}

stop_agent() {
  [[ "$(uname -s)" == "Darwin" ]] || { print -u2 -r -- "launchd is only supported on macOS."; return 2; }
  launchctl bootout "gui/$UID" "$PLIST" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  print -r -- "Stopped Claude Code probe: $LABEL"
}

status_agent() {
  [[ "$(uname -s)" == "Darwin" ]] || { print -u2 -r -- "launchd is only supported on macOS."; return 2; }
  launchctl print "gui/$UID/$LABEL"
}

health_agent() {
  [[ "$(uname -s)" == "Darwin" ]] || { print -u2 -r -- "launchd is only supported on macOS."; return 2; }

  local loaded="no" state="not loaded" interval="unknown" interval_label="unknown" mode="unknown" last_exit="unknown" runs="unknown" last_result="no log yet"
  local current_pid="" current_elapsed="unknown" current_reason="unknown"
  local status_output plist_interval log_line loop_state="no loop state yet"

  status_output="$(launchctl print "gui/$UID/$LABEL" 2>/dev/null)" && loaded="yes"
  if [[ "$loaded" == "yes" ]]; then
    state="$(print -r -- "$status_output" | awk -F'= ' '/state =/ {print $2; exit}')"
    interval="$(print -r -- "$status_output" | awk '/run interval =/ {print $4; exit}')"
    last_exit="$(print -r -- "$status_output" | awk -F'= ' '/last exit code =/ {print $2; exit}')"
    runs="$(print -r -- "$status_output" | awk -F'= ' '/runs =/ {print $2; exit}')"
    current_pid="$(print -r -- "$status_output" | awk -F'= ' '/pid =/ {print $2; exit}')"
    current_reason="$(print -r -- "$status_output" | awk -F'= ' '/immediate reason =/ {print $2; exit}')"
    if [[ -n "$current_pid" ]]; then
      current_elapsed="$(ps -p "$current_pid" -o etime= 2>/dev/null | awk '{$1=$1; print}')"
      [[ -n "$current_elapsed" ]] || current_elapsed="unknown"
    fi
  elif [[ -f "$PLIST" ]]; then
    loaded="plist-only"
  fi
  if [[ -f "$PLIST" ]]; then
    plist_interval="$(plist_arg_after --interval)"
    if [[ -z "$plist_interval" ]]; then
      plist_interval="$(plutil -extract StartInterval raw -o - "$PLIST" 2>/dev/null || true)"
    fi
    [[ -n "$plist_interval" && ( -z "$interval" || "$interval" == "unknown" ) ]] && interval="$plist_interval"
    if plutil -extract ProgramArguments xml1 -o - "$PLIST" 2>/dev/null | grep -q -- '--stop-on-available'; then
      mode="stop-on-available"
    else
      mode="always"
    fi
  fi

  if [[ -f "$LOG_FILE" ]]; then
    log_line="$(tail -n 1 "$LOG_FILE")"
    if [[ -n "$log_line" && "$log_line" != timestamp$'\t'* ]]; then
      last_result="$(print -r -- "$log_line" | awk -F'\t' '{printf "%s %s %s %s %ss", $1, $2, $3, $5, $6}')"
    fi
  fi
  if [[ -f "$LOOP_STATE_FILE" ]]; then
    loop_state="$(tail -n 1 "$LOOP_STATE_FILE")"
  fi
  [[ -n "$interval" ]] || interval="unknown"
  if [[ "$interval" == <-> ]]; then
    interval_label="${interval}s"
  else
    interval_label="$interval"
  fi

  print -r -- "Claude Code probe: loaded=$loaded state=$state"
  print -r -- "Mode: $mode"
  print -r -- "Interval: $interval_label  launchd_runs=$runs  last_exit=$last_exit"
  if [[ "$state" == "running" && -n "$current_pid" ]]; then
    print -r -- "Launchd process: pid=$current_pid elapsed=$current_elapsed reason=$current_reason"
  fi
  print -r -- "Loop state: $loop_state"
  print -r -- "Last result: $last_result"
  print -r -- "Log: $LOG_FILE"
  if [[ "$state" == "not running" ]]; then
    print -r -- "Note: with the new loop scheduler, loaded=yes should usually stay running."
  fi
}

case "$COMMAND" in
  once)
    run_probe
    ;;
  loop)
    loop_agent
    ;;
  start)
    start_agent
    ;;
  stop)
    stop_agent
    ;;
  status)
    status_agent
    ;;
  health)
    health_agent
    ;;
  tail)
    tail -n "${1:-20}" "$LOG_FILE"
    ;;
  test-notification)
    NOTIFY=1
    NOTIFY_VERBOSE=1
    notify "Claude Code Probe" "通知链路测试：Claude Code 探针已就绪"
    [[ "$QUIET" == "1" ]] || print -r -- "Sent test notification request."
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    print -u2 -r -- "Unknown command: $COMMAND"
    usage >&2
    exit 2
    ;;
esac
