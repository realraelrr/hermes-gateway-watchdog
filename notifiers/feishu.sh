#!/usr/bin/env bash

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

notify_webhook() {
  local provider="$1"
  local webhook_url="$2"
  local payload="$3"
  local notify_summary http_code
  local notify_body_file notify_err_file

  notify_body_file="${NOTIFY_OUTPUT_FILE}.${provider}.body"
  notify_err_file="${NOTIFY_OUTPUT_FILE}.${provider}.err"

  if [[ -z "$webhook_url" ]]; then
    log WARN notify_skip "provider=$provider reason=missing_webhook"
    return 1
  fi

  if ! http_code="$("${CURL_BIN:-$(command -v curl)}" -sS --connect-timeout 2 --max-time 4 -o "$notify_body_file" -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -d "$payload" \
    "$webhook_url" 2>"$notify_err_file")"; then
    notify_summary="$(head -n 1 "$notify_err_file" 2>/dev/null | tr ' ' '_')"
    log ERROR notify_failed "provider=$provider reason=transport status=000 summary=${notify_summary:-unknown}"
    return 1
  fi

  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    notify_summary="$(head -n 1 "$notify_body_file" 2>/dev/null | tr ' ' '_')"
    if [[ -z "$notify_summary" ]]; then
      notify_summary="$(head -n 1 "$notify_err_file" 2>/dev/null | tr ' ' '_')"
    fi
    log ERROR notify_failed "provider=$provider reason=http_status status=${http_code:-000} summary=${notify_summary:-empty}"
    return 1
  fi

  log INFO notify_ok "provider=$provider status=$http_code"
  return 0
}

notify_feishu() {
  local text="$1"
  local provider="feishu"

  notify_webhook "$provider" "$FEISHU_WEBHOOK_URL" \
    "$("${JQ_BIN:-$(command -v jq)}" -cn --arg text "$text" '{msg_type:"text",content:{text:$text}}')"
}

notify_send() {
  notify_feishu "$1"
}
