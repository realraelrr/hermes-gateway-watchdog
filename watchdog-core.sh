#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/state.sh"
source "$SCRIPT_DIR/probe.sh"
source "$SCRIPT_DIR/repair.sh"

STATE_FILE=""
LOG_FILE=""
PROBE_OUTPUT_FILE=""
REPAIR_OUTPUT_FILE=""
NOTIFY_OUTPUT_FILE=""
DISCORD_WEBHOOK_URL=""
REQUIRED_TOOL_REASON=""
PROBE_REASON="ok"
PROBE_STATUS="ok"
PROBE_GATEWAY_HEALTH="unknown"
PROBE_CLOUDFLARED_HEALTH="unknown"
REPAIR_ACTION="none"
RESTART_FAILURE_REASON=""
REPAIR_EXECUTED=0
CURRENT_GATEWAY_PID=""
CURRENT_CLOUDFLARED_PID=""

notifier_init() { return 0; }
notify_send() { return 0; }
notifier_cleanup() { return 0; }

load_notifier() {
  local notifier_file=""

  notifier_init() { return 0; }
  notify_send() { return 0; }
  notifier_cleanup() { return 0; }

  case "${NOTIFIER:-composite}" in
    discord) notifier_file="$SCRIPT_DIR/notifiers/discord.sh" ;;
    feishu) notifier_file="$SCRIPT_DIR/notifiers/feishu.sh" ;;
    composite) notifier_file="$SCRIPT_DIR/notifiers/composite.sh" ;;
    *) log WARN notifier_unknown "notifier=${NOTIFIER:-unset}" ;;
  esac

  [[ -n "$notifier_file" ]] || return 0
  source "$notifier_file"
}

log() {
  printf '%s level=%s event=%s %s\n' "$(date -u +%FT%TZ)" "$1" "$2" "${3:-}" >> "$LOG_FILE"
}

short_hostname() {
  hostname -s 2>/dev/null || hostname
}

event_title() {
  case "$1" in
    restart_triggered) printf '自动重启已触发\n' ;;
    restart_succeeded) printf '自动重启已恢复\n' ;;
    restart_failed) printf '自动重启失败\n' ;;
    manual_restart_triggered) printf '手动重启已触发\n' ;;
    manual_restart_succeeded) printf '手动重启成功\n' ;;
    manual_restart_failed) printf '手动重启失败\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

event_source() {
  case "$1" in
    manual_restart_*) printf 'local CLI\n' ;;
    *) printf 'passive watchdog\n' ;;
  esac
}

reason_component() {
  case "$1" in
    feishu_not_connected) printf 'Hermes Gateway / Feishu 连接\n' ;;
    gateway_listener_down) printf 'Hermes Gateway / 本地监听\n' ;;
    gateway_state_missing|gateway_state_invalid_json|gateway_state_stale|gateway_state_timestamp_invalid|gateway_not_running) printf 'Hermes Gateway / 状态文件\n' ;;
    webhook_route_missing|webhook_probe_unreachable) printf 'Hermes Gateway / Feishu webhook 路由\n' ;;
    cloudflared_ready_zero|cloudflared_ready_unreachable|cloudflared_ready_invalid_json|cloudflared_ready_http_error) printf 'Cloudflare Tunnel\n' ;;
    required_tool_missing) printf 'Watchdog 运行环境\n' ;;
    launchctl_restart_failed) printf 'macOS launchd\n' ;;
    manual_request) printf '本地主动控制\n' ;;
    ok) printf '健康检查\n' ;;
    *) printf '未知环节\n' ;;
  esac
}

reason_summary() {
  case "$1" in
    feishu_not_connected) printf 'Feishu 连接未就绪\n' ;;
    gateway_listener_down) printf '127.0.0.1:8765 未监听\n' ;;
    gateway_state_missing) printf 'gateway_state.json 不存在\n' ;;
    gateway_state_invalid_json) printf 'gateway_state.json 不是合法 JSON\n' ;;
    gateway_state_stale) printf 'gateway_state.json 更新时间过旧\n' ;;
    gateway_state_timestamp_invalid) printf 'gateway_state.json updated_at 缺失或无效\n' ;;
    gateway_not_running) printf 'Hermes gateway 未处于 running 状态\n' ;;
    webhook_route_missing) printf '本地 Feishu webhook 路由缺失\n' ;;
    webhook_probe_unreachable) printf '本地 Feishu webhook 探测不可达\n' ;;
    cloudflared_ready_zero) printf 'Cloudflare Tunnel readyConnections 为 0\n' ;;
    cloudflared_ready_unreachable) printf 'Cloudflare Tunnel readiness 端点不可达\n' ;;
    cloudflared_ready_invalid_json) printf 'Cloudflare Tunnel readiness 响应不是预期 JSON\n' ;;
    cloudflared_ready_http_error) printf 'Cloudflare Tunnel readiness 返回异常 HTTP 状态\n' ;;
    required_tool_missing) printf 'watchdog 依赖命令缺失\n' ;;
    launchctl_restart_failed) printf 'launchctl kickstart 执行失败\n' ;;
    manual_request) printf '本地手动请求\n' ;;
    ok) printf '健康检查通过\n' ;;
    *) printf '未分类原因\n' ;;
  esac
}

action_summary() {
  case "$1" in
    restart_gateway) printf '重启 Hermes gateway\n' ;;
    restart_cloudflared) printf '重启 cloudflared\n' ;;
    restart_cloudflared_then_gateway|restart_all) printf '先重启 cloudflared，再重启 Hermes gateway\n' ;;
    none|"") printf '不执行重启\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

action_launchagents() {
  case "$1" in
    restart_gateway) printf '%s\n' "${GATEWAY_LABEL:-com.hermes.gateway}" ;;
    restart_cloudflared) printf '%s\n' "${CLOUDFLARED_LABEL:-com.cloudflare.cloudflared}" ;;
    restart_cloudflared_then_gateway|restart_all) printf '%s, %s\n' "${CLOUDFLARED_LABEL:-com.cloudflare.cloudflared}" "${GATEWAY_LABEL:-com.hermes.gateway}" ;;
    none|"") printf 'none\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

format_notification() {
  local event="$1"
  local failure_count="$2"
  local reason="${3:-${LAST_REASON:-unknown}}"
  local action="${4:-${LAST_REPAIR_ACTION:-none}}"
  local host title source component summary action_text labels

  host="$(short_hostname)"
  title="$(event_title "$event")"
  source="$(event_source "$event")"
  component="$(reason_component "$reason")"
  summary="$(reason_summary "$reason")"
  action_text="$(action_summary "$action")"
  labels="$(action_launchagents "$action")"

  printf '[%s] %s\n\n主机: %s\n来源: %s\n故障环节: %s\n检测结果: gateway=%s, cloudflared=%s\n原因: %s - %s\n动作: %s\nLaunchAgent: %s\n连续失败: %s\nraw: event=%s host=%s failures=%s reason=%s action=%s\n' \
    "${WATCHDOG_DISPLAY_NAME:-Hermes Gateway Watchdog}" \
    "$title" \
    "$host" \
    "$source" \
    "$component" \
    "${PROBE_GATEWAY_HEALTH:-unknown}" \
    "${PROBE_CLOUDFLARED_HEALTH:-unknown}" \
    "$reason" \
    "$summary" \
    "$action_text" \
    "$labels" \
    "$failure_count" \
    "$event" \
    "$host" \
    "$failure_count" \
    "$reason" \
    "$action"
}

usage() {
  printf 'Usage: %s [restart gateway|cloudflared|all]\n' "${0##*/}" >&2
}

is_manual_restart_command() {
  [[ "${1:-}" == "restart" || "${1:-}" == "--restart" ]]
}

manual_restart_action_for_target() {
  case "${1:-}" in
    gateway) printf 'restart_gateway\n' ;;
    cloudflared) printf 'restart_cloudflared\n' ;;
    all) printf 'restart_all\n' ;;
    *) return 1 ;;
  esac
}

run_manual_restart_action() {
  case "$1" in
    restart_gateway)
      launchctl_restart_label "$GATEWAY_LABEL" || return 1
      ;;
    restart_cloudflared)
      launchctl_restart_label "$CLOUDFLARED_LABEL" || return 1
      ;;
    restart_all)
      launchctl_restart_label "$CLOUDFLARED_LABEL" || return 1
      launchctl_restart_label "$GATEWAY_LABEL" || return 1
      ;;
    *)
      RESTART_FAILURE_REASON="manual_restart_invalid_action"
      return 1
      ;;
  esac
}

watchdog_manual_restart() {
  local target="${1:-}" action="" rc=0

  if ! action="$(manual_restart_action_for_target "$target")"; then
    usage
    return 64
  fi

  load_watchdog_config
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  load_notifier
  notifier_init || true
  if ! acquire_watchdog_lock; then
    return 0
  fi
  trap 'watchdog_cleanup' EXIT
  init_runtime_paths

  if ! resolve_required_bins; then
    log ERROR required_tool_missing "reason=${REQUIRED_TOOL_REASON:-required_tool_missing} command=manual_restart target=$target"
    notify_send "$(format_notification manual_restart_failed 0 "${REQUIRED_TOOL_REASON:-required_tool_missing}" "$action")" || true
    return 1
  fi

  log INFO manual_restart_triggered "target=$target action=$action"
  notify_send "$(format_notification manual_restart_triggered 0 "manual_request" "$action")" || true
  run_manual_restart_action "$action" || rc=$?

  if (( rc == 0 )); then
    log INFO manual_restart_succeeded "target=$target action=$action"
    notify_send "$(format_notification manual_restart_succeeded 0 "manual_request" "$action")" || true
  else
    log ERROR manual_restart_failed "target=$target action=$action reason=${RESTART_FAILURE_REASON:-manual_restart_failed}"
    notify_send "$(format_notification manual_restart_failed 0 "${RESTART_FAILURE_REASON:-manual_restart_failed}" "$action")" || true
  fi

  return "$rc"
}

log_resolved_tools() {
  log INFO tools_resolved "curl=$CURL_BIN jq=$JQ_BIN launchctl=$LAUNCHCTL_BIN lsof=$LSOF_BIN"
}

load_state_vars() {
  WATCHDOG_BOOT_AT="$(read_state_field '.watchdog_boot_at')"
  HAS_SEEN_OK="$(read_state_field '.has_seen_ok')"
  CONSECUTIVE_FAILURES="$(read_state_field '.consecutive_failures')"
  RESTART_FAILURES="$(read_state_field '.restart_failures')"
  [[ "$RESTART_FAILURES" =~ ^-?[0-9]+$ ]] || RESTART_FAILURES=0
  LAST_OK_AT="$(read_state_field '.last_ok_at')"
  LAST_FAILURE_AT="$(read_state_field '.last_failure_at')"
  LAST_RESTART_AT="$(read_state_field '.last_restart_at')"
  COOLDOWN_UNTIL_EPOCH="$(read_state_field '.cooldown_until_epoch')"
  INITIAL_GRACE_UNTIL_EPOCH="$(read_state_field '.initial_grace_until_epoch')"
  TRANSITION_GRACE_UNTIL_EPOCH="$(read_state_field '.transition_grace_until_epoch')"
  TRANSITION_REASON="$(read_state_field '.transition_reason')"
  LAST_GATEWAY_PID="$(read_state_field '.last_gateway_pid')"
  LAST_CLOUDFLARED_PID="$(read_state_field '.last_cloudflared_pid')"
  LAST_REASON="$(read_state_field '.last_reason')"
  LAST_REPAIR_ACTION="$(read_state_field '.last_repair_action')"
}

persist_state() {
  cat <<JSON | write_state
{"watchdog_boot_at":"${WATCHDOG_BOOT_AT:-}","has_seen_ok":${HAS_SEEN_OK:-false},"consecutive_failures":${CONSECUTIVE_FAILURES:-0},"restart_failures":${RESTART_FAILURES:-0},"last_ok_at":"${LAST_OK_AT:-}","last_failure_at":"${LAST_FAILURE_AT:-}","last_restart_at":"${LAST_RESTART_AT:-}","cooldown_until_epoch":${COOLDOWN_UNTIL_EPOCH:-0},"initial_grace_until_epoch":${INITIAL_GRACE_UNTIL_EPOCH:-0},"transition_grace_until_epoch":${TRANSITION_GRACE_UNTIL_EPOCH:-0},"transition_reason":"${TRANSITION_REASON:-}","last_gateway_pid":"${LAST_GATEWAY_PID:-}","last_cloudflared_pid":"${LAST_CLOUDFLARED_PID:-}","last_reason":"${LAST_REASON:-}","last_repair_action":"${LAST_REPAIR_ACTION:-}"}
JSON
}

within_grace_window() {
  local now_epoch="$1"

  if [[ "${HAS_SEEN_OK:-false}" != "true" ]] && (( now_epoch <= INITIAL_GRACE_UNTIL_EPOCH )); then
    return 0
  fi
  if (( now_epoch <= TRANSITION_GRACE_UNTIL_EPOCH )); then
    return 0
  fi
  return 1
}

extend_transition_grace() {
  local reason="$1"
  local now_epoch="$2"

  TRANSITION_REASON="$reason"
  TRANSITION_GRACE_UNTIL_EPOCH=$((now_epoch + TRANSITION_GRACE_SEC))
}

observe_pid_changes() {
  local now_epoch="$1"

  CURRENT_GATEWAY_PID="$(get_launchd_pid "$GATEWAY_LABEL" || true)"
  CURRENT_CLOUDFLARED_PID="$(get_launchd_pid "$CLOUDFLARED_LABEL" || true)"

  if [[ "${CURRENT_GATEWAY_PID:-}" != "${LAST_GATEWAY_PID:-}" ]]; then
    LAST_GATEWAY_PID="${CURRENT_GATEWAY_PID:-}"
    extend_transition_grace gateway_pid_changed "$now_epoch"
  fi
  if [[ "${CURRENT_CLOUDFLARED_PID:-}" != "${LAST_CLOUDFLARED_PID:-}" ]]; then
    LAST_CLOUDFLARED_PID="${CURRENT_CLOUDFLARED_PID:-}"
    extend_transition_grace cloudflared_pid_changed "$now_epoch"
  fi
}

watchdog_cleanup() {
  notifier_cleanup || true
  cleanup_runtime_paths
  release_lock
}

watchdog_main() {
  local now_iso now_epoch probe_status repair_rc=0 incident_reason incident_action repair_reason

  if is_manual_restart_command "${1:-}"; then
    watchdog_manual_restart "${2:-}"
    return $?
  fi

  load_watchdog_config
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  if watchdog_is_disabled; then
    log INFO watchdog_disabled "enabled=$WATCHDOG_ENABLED"
    return 0
  fi

  load_notifier
  notifier_init || true
  if ! acquire_watchdog_lock; then
    return 0
  fi
  trap 'watchdog_cleanup' EXIT
  init_runtime_paths
  ensure_state
  load_state_vars

  now_iso="$(state_now_iso)"
  now_epoch="$(state_now_epoch)"
  observe_pid_changes "$now_epoch"

  if ! resolve_required_bins; then
    CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
    LAST_FAILURE_AT="$now_iso"
    LAST_REASON="${REQUIRED_TOOL_REASON:-required_tool_missing}"
    LAST_REPAIR_ACTION="none"
    log ERROR required_tool_missing "reason=$LAST_REASON"
    if (( CONSECUTIVE_FAILURES >= FAIL_THRESHOLD )); then
      if (( now_epoch >= COOLDOWN_UNTIL_EPOCH )); then
        COOLDOWN_UNTIL_EPOCH=$((now_epoch + COOLDOWN_SEC))
        notify_send "$(format_notification restart_failed "$CONSECUTIVE_FAILURES" "$LAST_REASON" "none")" || true
      fi
    fi
    persist_state
    return 0
  fi

  log_resolved_tools

  if within_grace_window "$now_epoch"; then
    PROBE_WITHIN_GRACE=1
  else
    PROBE_WITHIN_GRACE=0
  fi

  probe_gateway >/dev/null
  probe_status="${PROBE_STATUS:-fail}"
  case "$probe_status" in
    ok)
      HAS_SEEN_OK=true
      CONSECUTIVE_FAILURES=0
      RESTART_FAILURES=0
      LAST_OK_AT="$now_iso"
      LAST_REASON="ok"
      LAST_REPAIR_ACTION=""
      persist_state
      return 0
      ;;
    neutral)
      LAST_REASON="$PROBE_REASON"
      persist_state
      return 0
      ;;
  esac

  CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
  LAST_FAILURE_AT="$now_iso"
  LAST_REASON="$PROBE_REASON"

  if (( now_epoch < COOLDOWN_UNTIL_EPOCH )); then
    persist_state
    return 0
  fi

  if (( CONSECUTIVE_FAILURES < FAIL_THRESHOLD )); then
    persist_state
    return 0
  fi

  if (( ${MAX_RESTART_FAILURES:-10} > 0 && RESTART_FAILURES >= ${MAX_RESTART_FAILURES:-10} )); then
    LAST_REPAIR_ACTION="none"
    log ERROR restart_limit_reached "restart_failures=$RESTART_FAILURES max_restart_failures=${MAX_RESTART_FAILURES:-10} reason=$LAST_REASON"
    persist_state
    return 0
  fi

  incident_reason="$PROBE_REASON"
  LAST_REPAIR_ACTION="$(determine_repair_action)"
  incident_action="$LAST_REPAIR_ACTION"
  notify_send "$(format_notification restart_triggered "$CONSECUTIVE_FAILURES" "$incident_reason" "$incident_action")" || true
  run_repair_plan || repair_rc=$?

  if [[ "${REPAIR_EXECUTED:-0}" == "1" && "${LAST_REPAIR_ACTION}" != "none" ]]; then
    LAST_RESTART_AT="$now_iso"
    COOLDOWN_UNTIL_EPOCH=$((now_epoch + COOLDOWN_SEC))
    extend_transition_grace "repair:${LAST_REPAIR_ACTION}" "$now_epoch"
  fi

  if (( repair_rc == 0 )); then
    HAS_SEEN_OK=true
    CONSECUTIVE_FAILURES=0
    RESTART_FAILURES=0
    LAST_OK_AT="$(state_now_iso)"
    LAST_REASON="ok"
    notify_send "$(format_notification restart_succeeded 0 "$incident_reason" "$incident_action")" || true
  else
    RESTART_FAILURES=$((RESTART_FAILURES + 1))
    repair_reason="${RESTART_FAILURE_REASON:-$incident_reason}"
    LAST_REASON="$repair_reason"
    if [[ "$LAST_REASON" == "required_tool_missing" || "$LAST_REASON" == "launchctl_restart_failed" ]]; then
      LAST_REPAIR_ACTION="none"
    else
      LAST_REPAIR_ACTION="$REPAIR_ACTION"
    fi
    notify_send "$(format_notification restart_failed "$CONSECUTIVE_FAILURES" "$repair_reason" "$LAST_REPAIR_ACTION")" || true
  fi

  persist_state
}
