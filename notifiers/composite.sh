#!/usr/bin/env bash

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

source "$SCRIPT_DIR/notifiers/discord.sh"
source "$SCRIPT_DIR/notifiers/feishu.sh"

notify_send() {
  local text="$1"
  local overall_success=1

  if notify_discord "$text"; then overall_success=0; fi
  if notify_feishu "$text"; then overall_success=0; fi

  return "$overall_success"
}
