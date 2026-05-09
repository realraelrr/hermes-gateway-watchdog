#!/usr/bin/env bash

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

feishu_response_summary() {
  local file="$1" summary=""

  if [[ -f "$file" ]]; then
    summary="$("${JQ_BIN:-$(command -v jq)}" -r '.msg // .message // .error // empty' "$file" 2>/dev/null || true)"
    if [[ -z "$summary" ]]; then
      summary="$(head -n 1 "$file" 2>/dev/null || true)"
    fi
  fi

  printf '%s' "${summary:-empty}" | tr ' ' '_'
}

feishu_tenant_access_token() {
  local provider="feishu"
  local base_url="${FEISHU_BOT_API_BASE:-https://open.feishu.cn/open-apis}"
  local token_body_file="${NOTIFY_OUTPUT_FILE}.${provider}.token.body"
  local token_err_file="${NOTIFY_OUTPUT_FILE}.${provider}.token.err"
  local token_payload http_code api_code token notify_summary

  base_url="${base_url%/}"
  token_payload="$("${JQ_BIN:-$(command -v jq)}" -cn \
    --arg app_id "$FEISHU_BOT_APP_ID" \
    --arg app_secret "$FEISHU_BOT_APP_SECRET" \
    '{app_id:$app_id,app_secret:$app_secret}')"

  if ! http_code="$("${CURL_BIN:-$(command -v curl)}" -sS --connect-timeout 2 --max-time 4 -o "$token_body_file" -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -d "$token_payload" \
    "$base_url/auth/v3/tenant_access_token/internal" 2>"$token_err_file")"; then
    notify_summary="$(head -n 1 "$token_err_file" 2>/dev/null | tr ' ' '_' || true)"
    log ERROR notify_failed "provider=$provider mode=bot step=token reason=transport status=000 summary=${notify_summary:-unknown}"
    return 1
  fi

  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    notify_summary="$(feishu_response_summary "$token_body_file")"
    log ERROR notify_failed "provider=$provider mode=bot step=token reason=http_status status=${http_code:-000} summary=${notify_summary:-empty}"
    return 1
  fi

  api_code="$("${JQ_BIN:-$(command -v jq)}" -r '.code // "unknown"' "$token_body_file" 2>/dev/null || true)"
  token="$("${JQ_BIN:-$(command -v jq)}" -r '.tenant_access_token // empty' "$token_body_file" 2>/dev/null || true)"
  if [[ "$api_code" != "0" || -z "$token" ]]; then
    notify_summary="$(feishu_response_summary "$token_body_file")"
    log ERROR notify_failed "provider=$provider mode=bot step=token reason=api_error status=$http_code code=${api_code:-unknown} summary=${notify_summary:-empty}"
    return 1
  fi

  printf '%s' "$token"
}

notify_feishu() {
  local text="$1"
  local provider="feishu"
  local base_url="${FEISHU_BOT_API_BASE:-https://open.feishu.cn/open-apis}"
  local notify_body_file="${NOTIFY_OUTPUT_FILE}.${provider}.body"
  local notify_err_file="${NOTIFY_OUTPUT_FILE}.${provider}.err"
  local token payload http_code api_code notify_summary

  if [[ -z "${FEISHU_BOT_APP_ID:-}" || -z "${FEISHU_BOT_APP_SECRET:-}" || -z "${FEISHU_BOT_CHAT_ID:-}" ]]; then
    log WARN notify_skip "provider=$provider mode=bot reason=missing_bot_config"
    return 1
  fi

  base_url="${base_url%/}"
  if ! token="$(feishu_tenant_access_token)"; then
    return 1
  fi

  payload="$("${JQ_BIN:-$(command -v jq)}" -cn \
    --arg receive_id "$FEISHU_BOT_CHAT_ID" \
    --arg text "$text" \
    '{receive_id:$receive_id,msg_type:"text",content:({text:$text}|tojson)}')"

  if ! http_code="$("${CURL_BIN:-$(command -v curl)}" -sS --connect-timeout 2 --max-time 4 -o "$notify_body_file" -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $token" \
    -d "$payload" \
    "$base_url/im/v1/messages?receive_id_type=${FEISHU_BOT_RECEIVE_ID_TYPE:-chat_id}" 2>"$notify_err_file")"; then
    notify_summary="$(head -n 1 "$notify_err_file" 2>/dev/null | tr ' ' '_' || true)"
    log ERROR notify_failed "provider=$provider mode=bot step=message reason=transport status=000 summary=${notify_summary:-unknown}"
    return 1
  fi

  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    notify_summary="$(feishu_response_summary "$notify_body_file")"
    log ERROR notify_failed "provider=$provider mode=bot step=message reason=http_status status=${http_code:-000} summary=${notify_summary:-empty}"
    return 1
  fi

  api_code="$("${JQ_BIN:-$(command -v jq)}" -r '.code // "unknown"' "$notify_body_file" 2>/dev/null || true)"
  if [[ "$api_code" != "0" ]]; then
    notify_summary="$(feishu_response_summary "$notify_body_file")"
    log ERROR notify_failed "provider=$provider mode=bot step=message reason=api_error status=$http_code code=${api_code:-unknown} summary=${notify_summary:-empty}"
    return 1
  fi

  log INFO notify_ok "provider=$provider mode=bot status=$http_code"
  return 0
}

notify_send() {
  notify_feishu "$1"
}
