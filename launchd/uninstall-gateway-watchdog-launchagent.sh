#!/usr/bin/env bash
set -euo pipefail

TARGET_FILE="$HOME/Library/LaunchAgents/ai.hermes.gateway-watchdog.plist"
SERVICE_LABEL="gui/$(id -u)/ai.hermes.gateway-watchdog"

launchctl bootout "$SERVICE_LABEL" 2>/dev/null || true
rm -f "$TARGET_FILE"

echo "Removed: $TARGET_FILE"
echo "Service stopped: $SERVICE_LABEL"
