#!/bin/zsh

set -o pipefail

SCRIPT_DIR="${0:A:h}"
PROBE_SCRIPT="$SCRIPT_DIR/probe_anyrouter.zsh"
LOG_DIR="$SCRIPT_DIR/logs"
LABEL="${ANYROUTER_LAUNCHD_LABEL:-com.yang.anyrouter-api-probe}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
INTERVAL="${ANYROUTER_PROBE_INTERVAL_SECONDS:-900}"
LAUNCHD_PATH="${ANYROUTER_LAUNCHD_PATH:-/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"
INHERIT_PROXY="${ANYROUTER_LAUNCHD_INHERIT_PROXY:-1}"

usage() {
  print -r -- "Usage: ./install_launchd.zsh [install|uninstall|status]"
  print -r -- ""
  print -r -- "Environment:"
  print -r -- "  ANYROUTER_PROBE_INTERVAL_SECONDS=900"
  print -r -- "  ANYROUTER_LAUNCHD_LABEL=$LABEL"
  print -r -- "  ANYROUTER_LAUNCHD_INHERIT_PROXY=1"
  print -r -- "  ANYROUTER_LAUNCHD_PATH=$LAUNCHD_PATH"
}

xml_escape() {
  sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g" <<< "$1"
}

install_agent() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    print -u2 -r -- "launchd install is only supported on macOS."
    exit 2
  fi

  if [[ ! -x "$PROBE_SCRIPT" ]]; then
    print -u2 -r -- "Probe script is not executable: $PROBE_SCRIPT"
    print -u2 -r -- "Run: chmod +x $PROBE_SCRIPT"
    exit 2
  fi

  mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"

  local escaped_label escaped_probe escaped_workdir escaped_stdout escaped_stderr
  escaped_label="$(xml_escape "$LABEL")"
  escaped_probe="$(xml_escape "$PROBE_SCRIPT")"
  escaped_workdir="$(xml_escape "$SCRIPT_DIR")"
  escaped_stdout="$(xml_escape "$LOG_DIR/launchd.out.log")"
  escaped_stderr="$(xml_escape "$LOG_DIR/launchd.err.log")"
  escaped_path="$(xml_escape "$LAUNCHD_PATH")"

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
    print -r -- "    <string>$escaped_probe</string>"
    print -r -- '    <string>--notify</string>'
    print -r -- '    <string>--quiet</string>'
    print -r -- '  </array>'
    print -r -- '  <key>WorkingDirectory</key>'
    print -r -- "  <string>$escaped_workdir</string>"
    print -r -- '  <key>EnvironmentVariables</key>'
    print -r -- '  <dict>'
    print -r -- '    <key>PATH</key>'
    print -r -- "    <string>$escaped_path</string>"
    if [[ "$INHERIT_PROXY" == "1" ]]; then
      local proxy_name proxy_value escaped_proxy_name escaped_proxy_value
      for proxy_name in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy; do
        if (( ${+parameters[$proxy_name]} )); then
          proxy_value="${(P)proxy_name}"
        else
          proxy_value=""
        fi

        if [[ -n "$proxy_value" ]]; then
          escaped_proxy_name="$(xml_escape "$proxy_name")"
          escaped_proxy_value="$(xml_escape "$proxy_value")"
          print -r -- "    <key>$escaped_proxy_name</key>"
          print -r -- "    <string>$escaped_proxy_value</string>"
        fi
      done
    fi
    print -r -- '  </dict>'
    print -r -- '  <key>StartInterval</key>'
    print -r -- "  <integer>$INTERVAL</integer>"
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

  launchctl bootout "gui/$UID" "$PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$UID" "$PLIST"
  launchctl kickstart -k "gui/$UID/$LABEL" >/dev/null 2>&1 || true

  print -r -- "Installed $LABEL"
  print -r -- "Plist: $PLIST"
  print -r -- "Interval: ${INTERVAL}s"
}

uninstall_agent() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    print -u2 -r -- "launchd uninstall is only supported on macOS."
    exit 2
  fi

  launchctl bootout "gui/$UID" "$PLIST" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  print -r -- "Uninstalled $LABEL"
}

status_agent() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    print -u2 -r -- "launchd status is only supported on macOS."
    exit 2
  fi

  launchctl print "gui/$UID/$LABEL"
}

command="${1:-install}"
case "$command" in
  install)
    install_agent
    ;;
  uninstall)
    uninstall_agent
    ;;
  status)
    status_agent
    ;;
  --help|-h|help)
    usage
    ;;
  *)
    print -u2 -r -- "Unknown command: $command"
    usage >&2
    exit 2
    ;;
esac
