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
  local timestamp="$1"

  "${JQ_BIN:-$(command -v jq)}" -nr --arg ts "$timestamp" 'try ($ts | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) catch empty'
}

probe_emit() {
  PROBE_STATUS="$1"
  PROBE_REASON="$2"
  printf '%s\n' "$1"
}

probe_gateway() {
  local state_file gateway_state="" feishu_state="" updated_at="" updated_epoch="" now_epoch
  local listener_ok=0 ready_output="" ready_http="" ready_body="" ready_connections=""
  local webhook_output="" webhook_http=""
  local max_age ready_url webhook_url
  local gateway_failure_reason="" gateway_partial_reason=""
  local cloudflared_failure_reason="" cloudflared_partial_reason=""

  PROBE_REASON="ok"
  PROBE_STATUS="ok"
  PROBE_GATEWAY_HEALTH="unknown"
  PROBE_CLOUDFLARED_HEALTH="unknown"
  max_age="${GATEWAY_STATE_MAX_AGE_SEC:-90}"
  ready_url="${CLOUDFLARED_READY_URL:-http://127.0.0.1:20241/ready}"
  webhook_url="${FEISHU_WEBHOOK_PROBE_URL:-http://127.0.0.1:8765/feishu/webhook}"
  state_file="$(gateway_state_file_path)"

  if [[ ! -f "$state_file" ]]; then
    if [[ "${PROBE_WITHIN_GRACE:-0}" == "1" ]] && [[ -n "${CURRENT_GATEWAY_PID:-}" ]]; then
      gateway_partial_reason="gateway_state_missing"
    else
      gateway_failure_reason="gateway_state_missing"
    fi
  elif ! "${JQ_BIN:-$(command -v jq)}" -e . >/dev/null 2>&1 < "$state_file"; then
    gateway_failure_reason="gateway_state_invalid_json"
  else
    gateway_state="$("${JQ_BIN:-$(command -v jq)}" -r '.gateway_state // empty' "$state_file")"
    feishu_state="$("${JQ_BIN:-$(command -v jq)}" -r '.platforms.feishu.state // empty' "$state_file")"
    updated_at="$("${JQ_BIN:-$(command -v jq)}" -r '.updated_at // empty' "$state_file")"

    if [[ -z "$updated_at" ]]; then
      if [[ "${PROBE_WITHIN_GRACE:-0}" == "1" ]] && [[ "$gateway_state" == "starting" || -n "${CURRENT_GATEWAY_PID:-}" ]]; then
        gateway_partial_reason="gateway_state_timestamp_invalid"
      else
        gateway_failure_reason="gateway_state_timestamp_invalid"
      fi
    else
      updated_epoch="$(parse_timestamp_epoch "$updated_at")"
      if [[ -z "$updated_epoch" ]]; then
        if [[ "${PROBE_WITHIN_GRACE:-0}" == "1" ]] && [[ "$gateway_state" == "starting" || -n "${CURRENT_GATEWAY_PID:-}" ]]; then
          gateway_partial_reason="gateway_state_timestamp_invalid"
        else
          gateway_failure_reason="gateway_state_timestamp_invalid"
        fi
      else
        now_epoch="$(date +%s)"
        if (( now_epoch - updated_epoch > max_age )); then
          gateway_failure_reason="gateway_state_stale"
        fi
      fi
    fi

    if [[ -z "$gateway_failure_reason" ]]; then
      if [[ "$gateway_state" == "starting" ]] && [[ "${PROBE_WITHIN_GRACE:-0}" == "1" ]]; then
        gateway_partial_reason="${gateway_partial_reason:-gateway_not_running}"
      elif [[ "$gateway_state" != "running" ]]; then
        gateway_failure_reason="gateway_not_running"
      fi
    fi

    if [[ -z "$gateway_failure_reason" && "$feishu_state" != "connected" ]]; then
      if [[ "${PROBE_WITHIN_GRACE:-0}" == "1" ]]; then
        gateway_partial_reason="${gateway_partial_reason:-feishu_not_connected}"
      else
        gateway_failure_reason="feishu_not_connected"
      fi
    fi
  fi

  if check_gateway_listener; then
    listener_ok=1
  else
    if [[ "${PROBE_WITHIN_GRACE:-0}" == "1" ]] && [[ "$gateway_state" == "starting" || -n "${CURRENT_GATEWAY_PID:-}" ]]; then
      gateway_partial_reason="${gateway_partial_reason:-gateway_not_running}"
    else
      gateway_failure_reason="${gateway_failure_reason:-gateway_listener_down}"
    fi
  fi

  if ! ready_output="$(http_probe "$ready_url")"; then
    cloudflared_failure_reason="cloudflared_ready_unreachable"
  else
    ready_http="${ready_output%%$'\t'*}"
    ready_body="${ready_output#*$'\t'}"

    if [[ "$ready_http" != "200" && "$ready_http" != "503" ]]; then
      cloudflared_failure_reason="cloudflared_ready_http_error"
    else
      ready_connections="$("${JQ_BIN:-$(command -v jq)}" -r 'if (.readyConnections | type) == "number" then .readyConnections else empty end' <<<"$ready_body" 2>/dev/null || true)"
      if [[ -z "$ready_connections" ]]; then
        cloudflared_failure_reason="cloudflared_ready_invalid_json"
      elif [[ "$ready_http" == "503" ]] || (( ready_connections == 0 )); then
        if [[ "${PROBE_WITHIN_GRACE:-0}" == "1" ]]; then
          cloudflared_partial_reason="cloudflared_ready_zero"
        else
          cloudflared_failure_reason="cloudflared_ready_zero"
        fi
      fi
    fi
  fi

  if (( listener_ok == 1 )); then
    if ! webhook_output="$(http_probe "$webhook_url")"; then
      gateway_failure_reason="${gateway_failure_reason:-webhook_probe_unreachable}"
    else
      webhook_http="${webhook_output%%$'\t'*}"
      case "$webhook_http" in
        405) ;;
        404) gateway_failure_reason="${gateway_failure_reason:-webhook_route_missing}" ;;
        *) gateway_failure_reason="${gateway_failure_reason:-webhook_probe_unreachable}" ;;
      esac
    fi
  fi

  if [[ -n "$gateway_failure_reason" ]]; then
    PROBE_GATEWAY_HEALTH="bad"
  elif [[ -n "$gateway_partial_reason" ]]; then
    PROBE_GATEWAY_HEALTH="partial"
  else
    PROBE_GATEWAY_HEALTH="ok"
  fi

  if [[ -n "$cloudflared_failure_reason" ]]; then
    PROBE_CLOUDFLARED_HEALTH="bad"
  elif [[ -n "$cloudflared_partial_reason" ]]; then
    PROBE_CLOUDFLARED_HEALTH="partial"
  else
    PROBE_CLOUDFLARED_HEALTH="ok"
  fi

  if [[ -n "$gateway_failure_reason" || -n "$cloudflared_failure_reason" ]]; then
    if [[ -n "$gateway_failure_reason" ]]; then
      probe_emit fail "$gateway_failure_reason"
    else
      probe_emit fail "$cloudflared_failure_reason"
    fi
    return 0
  fi

  if [[ -n "$gateway_partial_reason" || -n "$cloudflared_partial_reason" ]]; then
    if [[ -n "$gateway_partial_reason" ]]; then
      probe_emit neutral "$gateway_partial_reason"
    else
      probe_emit neutral "$cloudflared_partial_reason"
    fi
    return 0
  fi

  probe_emit ok ok
  return 0
}
