#!/usr/bin/env bash

derive_watchdog_seed_paths() {
  local seed_hermes_home seed_watchdog_home

  seed_hermes_home="${HERMES_HOME:-$HOME/.hermes}"
  seed_watchdog_home="${WATCHDOG_HOME:-$seed_hermes_home/watchdog}"
  : "${WATCHDOG_ENV_FILE:=$seed_watchdog_home/config/watchdog.env}"
}

derive_watchdog_paths() {
  derive_watchdog_seed_paths
  : "${HERMES_HOME:=$HOME/.hermes}"
  : "${WATCHDOG_HOME:=$HERMES_HOME/watchdog}"
  : "${WATCHDOG_STATE_DIR:=$WATCHDOG_HOME/.state/runtime}"
  : "${WATCHDOG_LOG_DIR:=$WATCHDOG_HOME/logs}"
  : "${STATE_FILE:=$WATCHDOG_STATE_DIR/gateway_watchdog_state.json}"
  : "${WATCHDOG_DISABLE_FILE:=$WATCHDOG_STATE_DIR/gateway_watchdog.disabled}"
  : "${WATCHDOG_LOCK_DIR:=$WATCHDOG_STATE_DIR/gateway_watchdog.lock}"
  : "${WATCHDOG_RUNTIME_TMP_DIR:=$WATCHDOG_STATE_DIR/tmp}"
  : "${LOG_FILE:=$WATCHDOG_LOG_DIR/gateway-watchdog.log}"
  : "${GATEWAY_STATE_FILE:=$HERMES_HOME/gateway_state.json}"
}

load_watchdog_env_file() {
  local file="$1" line key value

  [[ -f "$file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"

    case "$key" in
      HERMES_HOME|WATCHDOG_HOME|WATCHDOG_ENV_FILE|WATCHDOG_STATE_DIR|WATCHDOG_LOG_DIR|STATE_FILE|WATCHDOG_DISABLE_FILE|WATCHDOG_LOCK_DIR|WATCHDOG_RUNTIME_TMP_DIR|LOG_FILE|GATEWAY_STATE_FILE|WATCHDOG_DISPLAY_NAME|WATCHDOG_ENABLED|FAIL_THRESHOLD|MAX_RESTART_FAILURES|COOLDOWN_SEC|POST_RESTART_RETRIES|POST_RESTART_SLEEP_SEC|INITIAL_GRACE_SEC|TRANSITION_GRACE_SEC|LOCK_STALE_SEC|GATEWAY_LABEL|CLOUDFLARED_LABEL|CLOUDFLARED_READY_URL|FEISHU_WEBHOOK_PROBE_URL|GATEWAY_STATE_MAX_AGE_SEC|CURL_BIN|JQ_BIN|LAUNCHCTL_BIN|LSOF_BIN|NOTIFIER|DISCORD_WATCHDOG_WEBHOOK_URL|DISCORD_WEBHOOK_URL|FEISHU_BOT_APP_ID|FEISHU_BOT_APP_SECRET|FEISHU_BOT_CHAT_ID|FEISHU_BOT_RECEIVE_ID_TYPE|FEISHU_BOT_API_BASE)
        [[ -n "${!key:-}" ]] || printf -v "$key" '%s' "$value"
        ;;
      *)
        if declare -F log >/dev/null 2>&1; then
          log WARN config_key_ignored "key=$key source=env_file"
        fi
        ;;
    esac
  done < "$file"
}

apply_watchdog_defaults() {
  : "${WATCHDOG_ENABLED:=1}"
  : "${WATCHDOG_DISPLAY_NAME:=Hermes Gateway Watchdog}"
  : "${FAIL_THRESHOLD:=3}"
  : "${MAX_RESTART_FAILURES:=10}"
  : "${COOLDOWN_SEC:=300}"
  : "${POST_RESTART_RETRIES:=3}"
  : "${POST_RESTART_SLEEP_SEC:=5}"
  : "${INITIAL_GRACE_SEC:=60}"
  : "${TRANSITION_GRACE_SEC:=45}"
  : "${LOCK_STALE_SEC:=120}"
  : "${GATEWAY_LABEL:=com.hermes.gateway}"
  : "${CLOUDFLARED_LABEL:=com.cloudflare.cloudflared}"
  : "${CLOUDFLARED_READY_URL:=http://127.0.0.1:20241/ready}"
  : "${FEISHU_WEBHOOK_PROBE_URL:=http://127.0.0.1:8765/feishu/webhook}"
  : "${GATEWAY_STATE_MAX_AGE_SEC:=90}"
  : "${NOTIFIER:=composite}"
  : "${DISCORD_WATCHDOG_WEBHOOK_URL:=}"
  : "${DISCORD_WEBHOOK_URL:=}"
  : "${FEISHU_BOT_APP_ID:=}"
  : "${FEISHU_BOT_APP_SECRET:=}"
  : "${FEISHU_BOT_CHAT_ID:=}"
  : "${FEISHU_BOT_RECEIVE_ID_TYPE:=chat_id}"
  : "${FEISHU_BOT_API_BASE:=https://open.feishu.cn/open-apis}"
  : "${CURL_BIN:=}"
  : "${JQ_BIN:=}"
  : "${LAUNCHCTL_BIN:=}"
  : "${LSOF_BIN:=}"
}

watchdog_is_disabled() {
  [[ "${WATCHDOG_ENABLED}" == "0" ]] && return 0
  [[ -f "${WATCHDOG_DISABLE_FILE}" ]] && return 0
  return 1
}

resolve_required_bins() {
  REQUIRED_TOOL_REASON=""

  CURL_BIN="${CURL_BIN:-$(command -v curl 2>/dev/null || true)}"
  JQ_BIN="${JQ_BIN:-$(command -v jq 2>/dev/null || true)}"
  LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-$(command -v launchctl 2>/dev/null || true)}"
  LSOF_BIN="${LSOF_BIN:-$(command -v lsof 2>/dev/null || true)}"

  if [[ -z "$CURL_BIN" ]] || [[ ! -x "$CURL_BIN" ]]; then
    REQUIRED_TOOL_REASON="required_tool_missing"
    return 1
  fi
  if [[ -z "$JQ_BIN" ]] || [[ ! -x "$JQ_BIN" ]]; then
    REQUIRED_TOOL_REASON="required_tool_missing"
    return 1
  fi
  if [[ -z "$LAUNCHCTL_BIN" ]] || [[ ! -x "$LAUNCHCTL_BIN" ]]; then
    REQUIRED_TOOL_REASON="required_tool_missing"
    return 1
  fi
  if [[ -z "$LSOF_BIN" ]] || [[ ! -x "$LSOF_BIN" ]]; then
    REQUIRED_TOOL_REASON="required_tool_missing"
    return 1
  fi

  return 0
}

load_watchdog_config() {
  derive_watchdog_seed_paths
  load_watchdog_env_file "$WATCHDOG_ENV_FILE"
  apply_watchdog_defaults
  derive_watchdog_paths

  DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-${DISCORD_WATCHDOG_WEBHOOK_URL:-}}"
}
