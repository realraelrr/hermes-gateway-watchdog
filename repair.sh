#!/usr/bin/env bash

get_launchd_pid() {
  local label="$1"

  "${LAUNCHCTL_BIN:-$(command -v launchctl)}" list 2>/dev/null | awk -v label="$label" '$3 == label { if ($1 != "-") print $1; exit }'
}

launchctl_restart_label() {
  local label="$1"
  local service_label="gui/$(id -u)/$label"

  : > "$REPAIR_OUTPUT_FILE"
  if ! "${LAUNCHCTL_BIN:-$(command -v launchctl)}" kickstart -k "$service_label" >> "$REPAIR_OUTPUT_FILE" 2>&1; then
    RESTART_FAILURE_REASON="launchctl_restart_failed"
    return 1
  fi
}

determine_repair_action() {
  case "${PROBE_REASON:-}" in
    required_tool_missing|launchctl_restart_failed)
      printf 'none\n'
      return 0
      ;;
  esac

  case "${PROBE_GATEWAY_HEALTH:-unknown}:${PROBE_CLOUDFLARED_HEALTH:-unknown}" in
    ok:bad)
      printf 'restart_cloudflared\n'
      return 0
      ;;
    bad:ok)
      printf 'restart_gateway\n'
      return 0
      ;;
    bad:bad)
      printf 'restart_cloudflared_then_gateway\n'
      return 0
      ;;
  esac

  case "${PROBE_REASON:-}" in
    cloudflared_ready_zero|cloudflared_ready_unreachable|cloudflared_ready_invalid_json|cloudflared_ready_http_error)
      printf 'restart_cloudflared\n'
      ;;
    gateway_listener_down|gateway_state_missing|gateway_state_invalid_json|gateway_state_stale|gateway_state_timestamp_invalid|gateway_not_running|feishu_not_connected|webhook_route_missing|webhook_probe_unreachable)
      printf 'restart_gateway\n'
      ;;
    *)
      printf 'restart_cloudflared_then_gateway\n'
      ;;
  esac
}

wait_for_probe_recovery() {
  local attempt=1 probe_status="" grace_deadline now_epoch max_attempts grace_attempts transition_grace_sec

  transition_grace_sec="${TRANSITION_GRACE_SEC:-0}"

  grace_deadline="${REPAIR_GRACE_UNTIL_EPOCH:-0}"
  max_attempts="${POST_RESTART_RETRIES:-0}"
  if (( POST_RESTART_SLEEP_SEC > 0 )); then
    grace_attempts=$(((transition_grace_sec + POST_RESTART_SLEEP_SEC - 1) / POST_RESTART_SLEEP_SEC))
  else
    grace_attempts="$transition_grace_sec"
  fi
  if (( grace_attempts + 1 > max_attempts )); then
    max_attempts=$((grace_attempts + 1))
  fi

  while (( attempt <= max_attempts )); do
    sleep "$POST_RESTART_SLEEP_SEC"
    now_epoch="$(state_now_epoch)"
    if (( now_epoch <= grace_deadline )); then
      PROBE_WITHIN_GRACE=1
    else
      PROBE_WITHIN_GRACE=0
    fi
    probe_gateway >/dev/null
    probe_status="${PROBE_STATUS:-fail}"
    if [[ "$probe_status" == "ok" ]]; then
      return 0
    fi
    if [[ "$probe_status" == "neutral" && "${PROBE_WITHIN_GRACE:-0}" == "1" ]]; then
      attempt=$((attempt + 1))
      continue
    fi
    if (( attempt >= max_attempts )); then
      RESTART_FAILURE_REASON="${PROBE_REASON:-recovery_timeout}"
      return 1
    fi
    attempt=$((attempt + 1))
  done

  RESTART_FAILURE_REASON="${PROBE_REASON:-recovery_timeout}"
  return 1
}

run_single_repair_action() {
  case "$1" in
    restart_cloudflared)
      launchctl_restart_label "${CLOUDFLARED_LABEL:-com.cloudflare.cloudflared}" || return 1
      ;;
    restart_gateway)
      launchctl_restart_label "${GATEWAY_LABEL:-com.hermes.gateway}" || return 1
      ;;
  esac

  REPAIR_EXECUTED=1
  REPAIR_GRACE_UNTIL_EPOCH=$(( $(state_now_epoch) + ${TRANSITION_GRACE_SEC:-0} ))
  PROBE_WITHIN_GRACE=1
}

run_repair_plan() {
  REPAIR_ACTION="$(determine_repair_action)"
  RESTART_FAILURE_REASON=""
  REPAIR_EXECUTED=0
  REPAIR_GRACE_UNTIL_EPOCH=0

  case "$REPAIR_ACTION" in
    none)
      RESTART_FAILURE_REASON="${PROBE_REASON:-required_tool_missing}"
      return 1
      ;;
    restart_cloudflared|restart_gateway)
      run_single_repair_action "$REPAIR_ACTION" || return 1
      wait_for_probe_recovery
      ;;
    restart_cloudflared_then_gateway)
      run_single_repair_action restart_cloudflared || return 1
      if wait_for_probe_recovery; then
        return 0
      fi
      if [[ "${PROBE_GATEWAY_HEALTH:-unknown}" == "bad" ]]; then
        run_single_repair_action restart_gateway || return 1
        wait_for_probe_recovery
        return $?
      fi
      RESTART_FAILURE_REASON="recovery_timeout"
      return 1
      ;;
  esac
}
