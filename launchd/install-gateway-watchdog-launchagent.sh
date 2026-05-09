#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_FILE="$SCRIPT_DIR/ai.hermes.gateway-watchdog.plist.template"
TARGET_DIR="$HOME/Library/LaunchAgents"
TARGET_FILE="$TARGET_DIR/ai.hermes.gateway-watchdog.plist"
SERVICE_LABEL="gui/$(id -u)/ai.hermes.gateway-watchdog"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
WATCHDOG_HOME="${WATCHDOG_HOME:-$HERMES_HOME/watchdog}"
WATCHDOG_ENV_FILE="${WATCHDOG_ENV_FILE:-$WATCHDOG_HOME/config/watchdog.env}"
WATCHDOG_LOG_DIR="${WATCHDOG_LOG_DIR:-$WATCHDOG_HOME/logs}"
WATCHDOG_LOG_FILE="$WATCHDOG_LOG_DIR/gateway-watchdog.log"
WATCHDOG_RUNTIME_DIR="${WATCHDOG_RUNTIME_DIR:-$WATCHDOG_HOME/runtime/current}"
WATCHDOG_SCRIPT_PATH="$WATCHDOG_RUNTIME_DIR/gateway-watchdog.sh"
WATCHDOG_WORKING_DIR="$WATCHDOG_RUNTIME_DIR"

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[&]/\\&/g'
}

sync_runtime_tree() {
  mkdir -p "$WATCHDOG_RUNTIME_DIR" "$WATCHDOG_RUNTIME_DIR/notifiers"
  cp "$REPO_ROOT/gateway-watchdog.sh" "$WATCHDOG_RUNTIME_DIR/gateway-watchdog.sh"
  cp "$REPO_ROOT/watchdog-core.sh" "$WATCHDOG_RUNTIME_DIR/watchdog-core.sh"
  cp "$REPO_ROOT/config.sh" "$WATCHDOG_RUNTIME_DIR/config.sh"
  cp "$REPO_ROOT/state.sh" "$WATCHDOG_RUNTIME_DIR/state.sh"
  cp "$REPO_ROOT/probe.sh" "$WATCHDOG_RUNTIME_DIR/probe.sh"
  cp "$REPO_ROOT/repair.sh" "$WATCHDOG_RUNTIME_DIR/repair.sh"
  cp "$REPO_ROOT/notifiers/"*.sh "$WATCHDOG_RUNTIME_DIR/notifiers/"
  chmod +x "$WATCHDOG_RUNTIME_DIR/gateway-watchdog.sh"
}

if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "Template not found: $TEMPLATE_FILE" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR" "$WATCHDOG_LOG_DIR" "$(dirname "$WATCHDOG_ENV_FILE")"
sync_runtime_tree
sed \
  -e "s|__WATCHDOG_SCRIPT_PATH__|$(escape_sed_replacement "$WATCHDOG_SCRIPT_PATH")|g" \
  -e "s|__WATCHDOG_WORKING_DIR__|$(escape_sed_replacement "$WATCHDOG_WORKING_DIR")|g" \
  -e "s|__WATCHDOG_ENV_FILE__|$(escape_sed_replacement "$WATCHDOG_ENV_FILE")|g" \
  -e "s|__WATCHDOG_LOG_FILE__|$(escape_sed_replacement "$WATCHDOG_LOG_FILE")|g" \
  -e "s|__HOME__|$(escape_sed_replacement "$HOME")|g" \
  -e "s|__HERMES_HOME__|$(escape_sed_replacement "$HERMES_HOME")|g" \
  -e "s|__WATCHDOG_HOME__|$(escape_sed_replacement "$WATCHDOG_HOME")|g" \
  "$TEMPLATE_FILE" > "$TARGET_FILE"

launchctl bootout "$SERVICE_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$TARGET_FILE"
launchctl kickstart -k "$SERVICE_LABEL"

echo "Installed: $TARGET_FILE"
echo "Service: $SERVICE_LABEL"
echo "WATCHDOG_ENV_FILE: $WATCHDOG_ENV_FILE"
echo "WATCHDOG_LOG_FILE: $WATCHDOG_LOG_FILE"
echo "WATCHDOG_RUNTIME_DIR: $WATCHDOG_RUNTIME_DIR"
