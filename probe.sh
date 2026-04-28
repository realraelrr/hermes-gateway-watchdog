#!/usr/bin/env bash

gateway_state_file_path() {
  printf '%s\n' "$GATEWAY_STATE_FILE"
}

check_gateway_listener() {
  "${LSOF_BIN:-$(command -v lsof)}" -nP -iTCP:8765 -sTCP:LISTEN 2>/dev/null | grep -Eq '127\.0\.0\.1:8765|localhost:8765'
}

http_probe() {
  local url="$1"
  local http_code
  local body_file="${PROBE_OUTPUT_FILE}.body"
  local err_file="${PROBE_OUTPUT_FILE}.err"

  if ! http_code="$("${CURL_BIN:-$(command -v curl)}" -sS --connect-timeout 2 --max-time 4 -o "$body_file" -w '%{http_code}' "$url" 2>"$err_file")"; then
    return 1
  fi

  printf '%s\t%s\n' "$http_code" "$(cat "$body_file" 2>/dev/null)"
}

parse_timestamp_epoch() {
  local timestamp="$1" normalized=""

  normalized="$(printf '%s' "$timestamp" | sed -E 's/\.[0-9]+([Z+-])/\1/; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/')"

  if [[ "$normalized" == *Z ]]; then
    date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$normalized" '+%s' 2>/dev/null || true
    return 0
  fi

  date -j -f '%Y-%m-%dT%H:%M:%S%z' "$normalized" '+%s' 2>/dev/null || true
}

probe_emit() {
  PROBE_STATUS="$1"
  PROBE_REASON="$2"
  printf '%s\n' "$1"
}

reset_probe_result() {
  PROBE_REASON="ok"
  PROBE_STATUS="ok"
  PROBE_GATEWAY_HEALTH="unknown"
  PROBE_CLOUDFLARED_HEALTH="unknown"

  PROBE_GATEWAY_STATE=""
  PROBE_FEISHU_STATE=""
  PROBE_GATEWAY_LISTENER_OK=0
  PROBE_GATEWAY_FAILURE_REASON=""
  PROBE_GATEWAY_PARTIAL_REASON=""
  PROBE_CLOUDFLARED_FAILURE_REASON=""
  PROBE_CLOUDFLARED_PARTIAL_REASON=""
}

probe_in_grace() {
  [[ "${PROBE_WITHIN_GRACE:-0}" == "1" ]]
}

gateway_transition_grace_applies() {
  probe_in_grace && [[ "${PROBE_GATEWAY_STATE:-}" == "starting" || -n "${CURRENT_GATEWAY_PID:-}" ]]
}

set_gateway_failure_if_empty() {
  PROBE_GATEWAY_FAILURE_REASON="${PROBE_GATEWAY_FAILURE_REASON:-$1}"
}

set_gateway_partial_if_empty() {
  PROBE_GATEWAY_PARTIAL_REASON="${PROBE_GATEWAY_PARTIAL_REASON:-$1}"
}

set_gateway_failure_or_partial() {
  local reason="$1"
  local grace_mode="${2:-transition}"

  case "$grace_mode" in
    pid)
      if probe_in_grace && [[ -n "${CURRENT_GATEWAY_PID:-}" ]]; then
        set_gateway_partial_if_empty "$reason"
      else
        set_gateway_failure_if_empty "$reason"
      fi
      ;;
    any)
      if probe_in_grace; then
        set_gateway_partial_if_empty "$reason"
      else
        set_gateway_failure_if_empty "$reason"
      fi
      ;;
    *)
      if gateway_transition_grace_applies; then
        set_gateway_partial_if_empty "$reason"
      else
        set_gateway_failure_if_empty "$reason"
      fi
      ;;
  esac
}

check_gateway_timestamp() {
  local updated_at="$1"
  local updated_epoch="" now_epoch
  local max_age="${GATEWAY_STATE_MAX_AGE_SEC:-90}"

  if [[ -z "$updated_at" ]]; then
    set_gateway_failure_or_partial gateway_state_timestamp_invalid transition
    return 0
  fi

  updated_epoch="$(parse_timestamp_epoch "$updated_at")"
  if [[ -z "$updated_epoch" ]]; then
    set_gateway_failure_or_partial gateway_state_timestamp_invalid transition
    return 0
  fi

  now_epoch="$(date +%s)"
  if (( now_epoch - updated_epoch > max_age )); then
    set_gateway_failure_if_empty gateway_state_stale
  fi
}

check_gateway_state_file() {
  local state_file="$1" updated_at=""

  if [[ ! -f "$state_file" ]]; then
    set_gateway_failure_or_partial gateway_state_missing pid
    return 0
  fi

  if ! "${JQ_BIN:-$(command -v jq)}" -e . >/dev/null 2>&1 < "$state_file"; then
    set_gateway_failure_if_empty gateway_state_invalid_json
    return 0
  fi

  PROBE_GATEWAY_STATE="$("${JQ_BIN:-$(command -v jq)}" -r '.gateway_state // empty' "$state_file")"
  PROBE_FEISHU_STATE="$("${JQ_BIN:-$(command -v jq)}" -r '.platforms.feishu.state // empty' "$state_file")"
  updated_at="$("${JQ_BIN:-$(command -v jq)}" -r '.updated_at // empty' "$state_file")"

  check_gateway_timestamp "$updated_at"

  if [[ -z "$PROBE_GATEWAY_FAILURE_REASON" ]]; then
    if [[ "$PROBE_GATEWAY_STATE" == "starting" ]] && probe_in_grace; then
      set_gateway_partial_if_empty gateway_not_running
    elif [[ "$PROBE_GATEWAY_STATE" != "running" ]]; then
      set_gateway_failure_if_empty gateway_not_running
    fi
  fi

  if [[ -z "$PROBE_GATEWAY_FAILURE_REASON" && "$PROBE_FEISHU_STATE" != "connected" ]]; then
    set_gateway_failure_or_partial feishu_not_connected any
  fi
}

check_gateway_listener_health() {
  if check_gateway_listener; then
    PROBE_GATEWAY_LISTENER_OK=1
    return 0
  fi

  if gateway_transition_grace_applies; then
    set_gateway_partial_if_empty gateway_not_running
  else
    set_gateway_failure_if_empty gateway_listener_down
  fi
}

check_cloudflared_ready_health() {
  local ready_url="${CLOUDFLARED_READY_URL:-http://127.0.0.1:20241/ready}"
  local ready_output="" ready_http="" ready_body="" ready_connections=""

  if ! ready_output="$(http_probe "$ready_url")"; then
    PROBE_CLOUDFLARED_FAILURE_REASON="cloudflared_ready_unreachable"
    return 0
  fi

  ready_http="${ready_output%%$'\t'*}"
  ready_body="${ready_output#*$'\t'}"

  if [[ "$ready_http" != "200" && "$ready_http" != "503" ]]; then
    PROBE_CLOUDFLARED_FAILURE_REASON="cloudflared_ready_http_error"
    return 0
  fi

  ready_connections="$("${JQ_BIN:-$(command -v jq)}" -r 'if (.readyConnections | type) == "number" then .readyConnections else empty end' <<<"$ready_body" 2>/dev/null || true)"
  if [[ -z "$ready_connections" ]]; then
    PROBE_CLOUDFLARED_FAILURE_REASON="cloudflared_ready_invalid_json"
  elif [[ "$ready_http" == "503" ]] || (( ready_connections == 0 )); then
    if probe_in_grace; then
      PROBE_CLOUDFLARED_PARTIAL_REASON="cloudflared_ready_zero"
    else
      PROBE_CLOUDFLARED_FAILURE_REASON="cloudflared_ready_zero"
    fi
  fi
}

check_webhook_route_health() {
  local webhook_url="${FEISHU_WEBHOOK_PROBE_URL:-http://127.0.0.1:8765/feishu/webhook}"
  local webhook_output="" webhook_http=""

  (( PROBE_GATEWAY_LISTENER_OK == 1 )) || return 0

  if ! webhook_output="$(http_probe "$webhook_url")"; then
    set_gateway_failure_if_empty webhook_probe_unreachable
    return 0
  fi

  webhook_http="${webhook_output%%$'\t'*}"
  case "$webhook_http" in
    405) ;;
    404) set_gateway_failure_if_empty webhook_route_missing ;;
    *) set_gateway_failure_if_empty webhook_probe_unreachable ;;
  esac
}

set_probe_health_fields() {
  if [[ -n "$PROBE_GATEWAY_FAILURE_REASON" ]]; then
    PROBE_GATEWAY_HEALTH="bad"
  elif [[ -n "$PROBE_GATEWAY_PARTIAL_REASON" ]]; then
    PROBE_GATEWAY_HEALTH="partial"
  else
    PROBE_GATEWAY_HEALTH="ok"
  fi

  if [[ -n "$PROBE_CLOUDFLARED_FAILURE_REASON" ]]; then
    PROBE_CLOUDFLARED_HEALTH="bad"
  elif [[ -n "$PROBE_CLOUDFLARED_PARTIAL_REASON" ]]; then
    PROBE_CLOUDFLARED_HEALTH="partial"
  else
    PROBE_CLOUDFLARED_HEALTH="ok"
  fi
}

emit_probe_result_from_reasons() {
  if [[ -n "$PROBE_GATEWAY_FAILURE_REASON" || -n "$PROBE_CLOUDFLARED_FAILURE_REASON" ]]; then
    if [[ -n "$PROBE_GATEWAY_FAILURE_REASON" ]]; then
      probe_emit fail "$PROBE_GATEWAY_FAILURE_REASON"
    else
      probe_emit fail "$PROBE_CLOUDFLARED_FAILURE_REASON"
    fi
    return 0
  fi

  if [[ -n "$PROBE_GATEWAY_PARTIAL_REASON" || -n "$PROBE_CLOUDFLARED_PARTIAL_REASON" ]]; then
    if [[ -n "$PROBE_GATEWAY_PARTIAL_REASON" ]]; then
      probe_emit neutral "$PROBE_GATEWAY_PARTIAL_REASON"
    else
      probe_emit neutral "$PROBE_CLOUDFLARED_PARTIAL_REASON"
    fi
    return 0
  fi

  probe_emit ok ok
}

probe_gateway() {
  local state_file

  reset_probe_result
  state_file="$(gateway_state_file_path)"

  check_gateway_state_file "$state_file"
  check_gateway_listener_health
  check_cloudflared_ready_health
  check_webhook_route_health
  set_probe_health_fields
  emit_probe_result_from_reasons
}
