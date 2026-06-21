#!/bin/zsh

set -o pipefail

SCRIPT_DIR="${0:A:h}"
API_KEY_FILE="${ANYROUTER_API_KEY_FILE:-$SCRIPT_DIR/API_KEY}"
LOG_DIR="${ANYROUTER_LOG_DIR:-$SCRIPT_DIR/logs}"
LOG_FILE="${ANYROUTER_CODEX_LOG_FILE:-$LOG_DIR/codex.tsv}"
STATE_FILE="${ANYROUTER_CODEX_STATE_FILE:-$LOG_DIR/codex.state}"
LOOP_STATE_FILE="${ANYROUTER_CODEX_LOOP_STATE_FILE:-$LOG_DIR/codex.loop.state}"
LABEL="${ANYROUTER_CODEX_LABEL:-com.yang.anyrouter-probe.codex}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

CONNECT_TIMEOUT="${ANYROUTER_CONNECT_TIMEOUT:-10}"
MAX_TIME="${ANYROUTER_MAX_TIME:-120}"
INTERVAL_RAW="${ANYROUTER_CODEX_INTERVAL:-15m}"
NOTIFY_MODE="${ANYROUTER_NOTIFY_MODE:-always}"
LAUNCHD_PATH="${ANYROUTER_LAUNCHD_PATH:-/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"
INHERIT_PROXY="${ANYROUTER_LAUNCHD_INHERIT_PROXY:-1}"
NOTIFY_METHOD="${ANYROUTER_NOTIFY_METHOD:-dialog}"
NOTIFY_APP_BUNDLE="${ANYROUTER_NOTIFY_APP_BUNDLE:-com.microsoft.VSCode}"
NOTIFY_SOUND="${ANYROUTER_NOTIFY_SOUND:-Glass}"
NOTIFY_ALERT_SECONDS="${ANYROUTER_NOTIFY_ALERT_SECONDS:-8}"
NOTIFY_DIALOG_SECONDS="${ANYROUTER_NOTIFY_DIALOG_SECONDS:-0}"
NOTIFY_GROUP="${ANYROUTER_NOTIFY_GROUP:-anyrouter-api-probe}"
NOTIFY_IGNORE_DND="${ANYROUTER_NOTIFY_IGNORE_DND:-1}"
CODEX_BIN="${ANYROUTER_CODEX_BIN:-}"
REASONING_EFFORT="${ANYROUTER_CODEX_REASONING_EFFORT:-low}"
ALL_ACCOUNTS="${ANYROUTER_CODEX_ALL_ACCOUNTS:-0}"
PROMPT="${ANYROUTER_CODEX_PROMPT:-hi}"
STOP_ON_AVAILABLE="${ANYROUTER_CODEX_STOP_ON_AVAILABLE:-${ANYROUTER_STOP_ON_AVAILABLE:-0}}"

COMMAND="once"
NOTIFY=1
QUIET=0
MODEL="${ANYROUTER_CODEX_MODEL:-gpt-5.5}"
BASE_URL="${ANYROUTER_CODEX_BASE_URL:-}"
STOP_ON_AVAILABLE_SET=0
if (( ${+ANYROUTER_CODEX_STOP_ON_AVAILABLE} || ${+ANYROUTER_STOP_ON_AVAILABLE} )); then
  STOP_ON_AVAILABLE_SET=1
fi

usage() {
  print -r -- "Usage: ./probe_codex.zsh [once|start|stop|status|health|tail|test-notification] [options]"
  print -r -- ""
  print -r -- "Options:"
  print -r -- "  -i, --interval VALUE     launchd interval, for example 15m, 900s, 1h, or 900."
  print -r -- "  --notify                 Show macOS notification when at least one account is available."
  print -r -- "  --no-notify              Disable notification for this run."
  print -r -- "  --notify-mode MODE       always or on-change. Default: always."
  print -r -- "  --notify-method METHOD   auto, terminal-notifier, vscode, osascript, dialog, alert, sound, bell, or all. Default: dialog."
  print -r -- "  --quiet                  Suppress terminal output; logs are still written."
  print -r -- "  --model MODEL            Probe model. Default: gpt-5.5."
  print -r -- "  --prompt TEXT            Probe prompt. Default: $PROMPT"
  print -r -- "  --base-url URL           OpenAI-compatible base URL. Default: base_url in API_KEY."
  print -r -- "  --codex-bin PATH         Codex CLI path. Default: auto-detect."
  print -r -- "  --reasoning-effort VALUE low, medium, high, or xhigh. Default: low."
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
    --model)
      shift
      MODEL="${1:-}"
      ;;
    --prompt)
      shift
      PROMPT="${1:-}"
      ;;
    --base-url)
      shift
      BASE_URL="${1:-}"
      ;;
    --codex-bin)
      shift
      CODEX_BIN="${1:-}"
      ;;
    --reasoning-effort)
      shift
      REASONING_EFFORT="${1:-}"
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

toml_value_from_file() {
  local key="$1"
  local file="$2"

  [[ -f "$file" ]] || return 0

  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", $0)
      sub(/[[:space:]]+#.*$/, "", $0)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      if ((substr($0, 1, 1) == "\"" && substr($0, length($0), 1) == "\"") ||
          (substr($0, 1, 1) == sprintf("%c", 39) && substr($0, length($0), 1) == sprintf("%c", 39))) {
        $0 = substr($0, 2, length($0) - 2)
      }
      print $0
      exit
    }
  ' "$file"
}

codex_config_value() {
  local key="$1"
  local value=""

  value="$(toml_value_from_file "$key" "$HOME/.codex/config.toml")"
  if [[ -z "$value" ]]; then
    value="$(toml_value_from_file "$key" "$API_KEY_FILE")"
  fi

  print -r -- "$value"
}

openai_keys() {
  awk '
    /^[[:space:]]*export[[:space:]]+OPENAI_API_KEY=/ {
      sub(/^[[:space:]]*export[[:space:]]+OPENAI_API_KEY=/, "", $0)
      sub(/[[:space:]]+#.*$/, "", $0)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      gsub(/^"|"$/, "", $0)
      if (length($0) > 0) print $0
    }
    /"OPENAI_API_KEY"[[:space:]]*:/ {
      line = $0
      sub(/^.*"OPENAI_API_KEY"[[:space:]]*:[[:space:]]*"/, "", line)
      sub(/".*$/, "", line)
      if (length(line) > 0) print line
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
    400) print -r -- "bad_request" ;;
    401|403) print -r -- "auth_failed" ;;
    408) print -r -- "timeout" ;;
    429) print -r -- "rate_limited_or_pool_busy" ;;
    500|502|503|504) print -r -- "upstream_unavailable" ;;
    *) print -r -- "http_$http_code" ;;
  esac
}

resolve_codex_bin() {
  if [[ -n "$CODEX_BIN" ]]; then
    print -r -- "$CODEX_BIN"
    return 0
  fi

  local found=""
  found="$(command -v codex 2>/dev/null || true)"
  if [[ -z "$found" ]]; then
    found="$(find "$HOME/.vscode/extensions" -path '*/bin/*/codex' -type f -perm -111 2>/dev/null | sort | tail -n 1)"
  fi

  if [[ -z "$found" ]]; then
    print -u2 -r -- "Cannot find Codex CLI. Pass --codex-bin /path/to/codex."
    return 2
  fi

  print -r -- "$found"
}

write_temp_codex_home() {
  local tmp_home="$1"
  local key="$2"

  mkdir -p "$tmp_home"
  chmod 700 "$tmp_home"

  {
    print -r -- "model = \"$MODEL\""
    print -r -- 'model_provider = "anyrouter"'
    print -r -- 'preferred_auth_method = "apikey"'
    print -r -- "model_reasoning_effort = \"$REASONING_EFFORT\""
    print -r -- ""
    print -r -- "[model_providers.anyrouter]"
    print -r -- 'name = "Any Router"'
    print -r -- "base_url = \"$BASE_URL\""
    print -r -- 'wire_api = "responses"'
  } > "$tmp_home/config.toml"

  {
    print -r -- "{"
    print -r -- "  \"OPENAI_API_KEY\":\"$key\""
    print -r -- "}"
  } > "$tmp_home/auth.json"
  chmod 600 "$tmp_home/config.toml" "$tmp_home/auth.json"
}

run_codex_cli_account() {
  local key="$1"
  local codex_bin="$2"
  local tmp_home out_file err_file last_file rc output last_message summary

  tmp_home="$(mktemp -d "${TMPDIR:-/tmp}/anyrouter_codex_home.XXXXXX")" || return 1
  out_file="$(mktemp "${TMPDIR:-/tmp}/anyrouter_codex_out.XXXXXX")" || {
    rm -rf "$tmp_home"
    return 1
  }
  err_file="$(mktemp "${TMPDIR:-/tmp}/anyrouter_codex_err.XXXXXX")" || {
    rm -rf "$tmp_home" "$out_file"
    return 1
  }
  last_file="$(mktemp "${TMPDIR:-/tmp}/anyrouter_codex_last.XXXXXX")" || {
    rm -rf "$tmp_home" "$out_file" "$err_file"
    return 1
  }

  write_temp_codex_home "$tmp_home" "$key"

  rc=0
  CODEX_HOME="$tmp_home" "$codex_bin" exec \
    --skip-git-repo-check \
    --ephemeral \
    --sandbox read-only \
    --ignore-rules \
    --output-last-message "$last_file" \
    --color never \
    "$PROMPT" >"$out_file" 2>"$err_file" || rc=$?

  output="$(summarize_file "$out_file") $(summarize_file "$err_file")"
  last_message="$(summarize_file "$last_file")"
  rm -rf "$tmp_home" "$out_file" "$err_file" "$last_file"

  if [[ "$rc" == "0" && -n "$last_message" ]]; then
    print -r -- "available|$last_message"
    return 0
  fi

  if [[ "$output" == *"429"* || "$output" == *"rate_limit"* || "$output" == *"rate limit"* ]]; then
    summary="$(print -r -- "$output" | cut -c 1-240)"
    print -r -- "rate_limited_or_pool_busy|$summary"
    return 0
  fi

  if [[ "$output" == *"401"* || "$output" == *"403"* || "$output" == *"Unauthorized"* || "$output" == *"authentication"* ]]; then
    summary="$(print -r -- "$output" | cut -c 1-240)"
    print -r -- "auth_failed|$summary"
    return 0
  fi

  summary="$(print -r -- "$output" | cut -c 1-240)"
  print -r -- "codex_cli_error|exit=$rc $summary"
}

run_probe() {
  if [[ ! -f "$API_KEY_FILE" ]]; then
    print -u2 -r -- "API key file not found: $API_KEY_FILE"
    return 2
  fi

  [[ -n "$MODEL" ]] || MODEL="gpt-5.5"
  [[ -n "$BASE_URL" ]] || BASE_URL="$(codex_config_value base_url)"
  [[ -n "$BASE_URL" ]] || BASE_URL="https://anyrouter.top/v1"

  BASE_URL="${BASE_URL%/}"
  local codex_bin
  codex_bin="$(resolve_codex_bin)" || return $?

  typeset -a api_keys available_accounts rate_limited_accounts failed_accounts
  api_keys=("${(@f)$(openai_keys)}")
  if [[ ${#api_keys[@]} -eq 0 ]]; then
    print -u2 -r -- "No OPENAI_API_KEY entries found in $API_KEY_FILE"
    return 2
  fi

  mkdir -p "$LOG_DIR"
  if [[ ! -f "$LOG_FILE" ]]; then
    print -r -- "timestamp	account	probe	http_code	category	duration_seconds	model	base_url	message" > "$LOG_FILE"
  fi

  local timestamp account key started ended duration result category message
  timestamp="$(date '+%Y-%m-%d %H:%M:%S %z')"

  for i in {1..${#api_keys[@]}}; do
    key="${api_keys[$i]}"
    account="account-$i"
    started="$(date +%s)"
    result="$(run_codex_cli_account "$key" "$codex_bin")"
    ended="$(date +%s)"
    duration="$(( ended - started ))"
    category="${result%%|*}"
    message="${result#*|}"

    print -r -- "$timestamp	$account	codex-cli	cli	$category	$duration	$MODEL	$BASE_URL	${message//$'\t'/ }" >> "$LOG_FILE"

    case "$category" in
      available) available_accounts+=("$account") ;;
      rate_limited_or_pool_busy|upstream_unavailable) rate_limited_accounts+=("$account") ;;
      *) failed_accounts+=("$account:$category") ;;
    esac

    [[ "$QUIET" == "1" ]] || print -r -- "$account	codex-cli	$category	${duration}s	$message"

    if [[ "$category" == "available" && "$ALL_ACCOUNTS" != "1" ]]; then
      break
    fi
  done

  local available_join="${(j:, :)available_accounts}"
  local rate_limited_join="${(j:, :)rate_limited_accounts}"
  local failed_join="${(j:, :)failed_accounts}"
  local previous_state=""
  [[ -f "$STATE_FILE" ]] && previous_state="$(<"$STATE_FILE")"

  if [[ ${#available_accounts[@]} -gt 0 ]]; then
    print -r -- "available	$timestamp	$available_join" > "$STATE_FILE"
    if [[ "$NOTIFY_MODE" != "on-change" || "$previous_state" != available* ]]; then
      notify "Codex Probe" "AnyRouter Codex/GPT 可用：$available_join"
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
  escaped_script="$(xml_escape "$SCRIPT_DIR/probe_codex.zsh")"
  escaped_workdir="$(xml_escape "$SCRIPT_DIR")"
  escaped_stdout="$(xml_escape "$LOG_DIR/codex.launchd.out.log")"
  escaped_stderr="$(xml_escape "$LOG_DIR/codex.launchd.err.log")"
  escaped_path="$(xml_escape "$LAUNCHD_PATH")"
  escaped_api_key_file="$(xml_escape "$API_KEY_FILE")"
  escaped_log_dir="$(xml_escape "$LOG_DIR")"
  escaped_log_file="$(xml_escape "$LOG_FILE")"
  escaped_state_file="$(xml_escape "$STATE_FILE")"
  escaped_loop_state_file="$(xml_escape "$LOOP_STATE_FILE")"
  local plist_model plist_base_url plist_codex_bin
  plist_model="${MODEL:-$(codex_config_value model)}"
  plist_base_url="${BASE_URL:-$(codex_config_value base_url)}"
  plist_codex_bin="${CODEX_BIN:-$(resolve_codex_bin)}"

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
    print -r -- '    <string>--model</string>'
    print -r -- "    <string>$(xml_escape "$plist_model")</string>"
    print -r -- '    <string>--prompt</string>'
    print -r -- "    <string>$(xml_escape "$PROMPT")</string>"
    print -r -- '    <string>--base-url</string>'
    print -r -- "    <string>$(xml_escape "$plist_base_url")</string>"
    print -r -- '    <string>--codex-bin</string>'
    print -r -- "    <string>$(xml_escape "$plist_codex_bin")</string>"
    print -r -- '    <string>--reasoning-effort</string>'
    print -r -- "    <string>$(xml_escape "$REASONING_EFFORT")</string>"
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
    print -r -- '    <key>ANYROUTER_CODEX_LOG_FILE</key>'
    print -r -- "    <string>$escaped_log_file</string>"
    print -r -- '    <key>ANYROUTER_CODEX_STATE_FILE</key>'
    print -r -- "    <string>$escaped_state_file</string>"
    print -r -- '    <key>ANYROUTER_CODEX_LOOP_STATE_FILE</key>'
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

  print -r -- "Started Codex probe: $LABEL"
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
  print -r -- "Stopped Codex probe: $LABEL"
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

  print -r -- "Codex probe: loaded=$loaded state=$state"
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
    notify "Codex Probe" "通知链路测试：Codex 探针已就绪"
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
