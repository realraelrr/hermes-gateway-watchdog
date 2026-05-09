#!/usr/bin/env bash

state_now_iso() {
  date -u +%FT%TZ
}

state_now_epoch() {
  date +%s
}

init_state() {
  local now_iso now_epoch

  now_iso="$(state_now_iso)"
  now_epoch="$(state_now_epoch)"
  mkdir -p "$(dirname "$STATE_FILE")"
  cat > "$STATE_FILE" <<JSON
{"watchdog_boot_at":"$now_iso","has_seen_ok":false,"consecutive_failures":0,"restart_failures":0,"last_ok_at":"","last_failure_at":"","last_restart_at":"","cooldown_until_epoch":0,"initial_grace_until_epoch":$((now_epoch + INITIAL_GRACE_SEC)),"transition_grace_until_epoch":0,"transition_reason":"","last_gateway_pid":"","last_cloudflared_pid":"","last_reason":"","last_repair_action":""}
JSON
}

ensure_state() {
  local jq_bin

  jq_bin="${JQ_BIN:-$(command -v jq 2>/dev/null || true)}"
  if [[ ! -f "$STATE_FILE" ]]; then
    init_state
    return 0
  fi
  if [[ -z "$jq_bin" ]]; then
    if ! grep -q '"watchdog_boot_at"' "$STATE_FILE" 2>/dev/null; then
      if declare -F log >/dev/null 2>&1; then
        log WARN state_corrupt "message=reinitialize_state_file"
      fi
      init_state
    fi
    return 0
  fi
  if ! "$jq_bin" -e . >/dev/null 2>&1 < "$STATE_FILE"; then
    if declare -F log >/dev/null 2>&1; then
      log WARN state_corrupt "message=reinitialize_state_file"
    fi
    init_state
  fi
}

read_state_field_fallback() {
  case "$1" in
    .watchdog_boot_at) sed -n 's/.*"watchdog_boot_at":"\([^"]*\)".*/\1/p' "$STATE_FILE" | head -n 1 ;;
    .has_seen_ok) sed -n 's/.*"has_seen_ok":\([^,}]*\).*/\1/p' "$STATE_FILE" | head -n 1 | tr -d ' ' ;;
    .consecutive_failures) sed -n 's/.*"consecutive_failures":\([-0-9]*\).*/\1/p' "$STATE_FILE" | head -n 1 ;;
    .restart_failures) sed -n 's/.*"restart_failures":\([-0-9]*\).*/\1/p' "$STATE_FILE" | head -n 1 ;;
    .last_ok_at) sed -n 's/.*"last_ok_at":"\([^"]*\)".*/\1/p' "$STATE_FILE" | head -n 1 ;;
    .last_failure_at) sed -n 's/.*"last_failure_at":"\([^"]*\)".*/\1/p' "$STATE_FILE" | head -n 1 ;;
    .last_restart_at) sed -n 's/.*"last_restart_at":"\([^"]*\)".*/\1/p' "$STATE_FILE" | head -n 1 ;;
    .cooldown_until_epoch) sed -n 's/.*"cooldown_until_epoch":\([-0-9]*\).*/\1/p' "$STATE_FILE" | head -n 1 ;;
    .initial_grace_until_epoch) sed -n 's/.*"initial_grace_until_epoch":\([-0-9]*\).*/\1/p' "$STATE_FILE" | head -n 1 ;;
    .transition_grace_until_epoch) sed -n 's/.*"transition_grace_until_epoch":\([-0-9]*\).*/\1/p' "$STATE_FILE" | head -n 1 ;;
    .transition_reason) sed -n 's/.*"transition_reason":"\([^"]*\)".*/\1/p' "$STATE_FILE" | head -n 1 ;;
    .last_gateway_pid) sed -n 's/.*"last_gateway_pid":"\([^"]*\)".*/\1/p' "$STATE_FILE" | head -n 1 ;;
    .last_cloudflared_pid) sed -n 's/.*"last_cloudflared_pid":"\([^"]*\)".*/\1/p' "$STATE_FILE" | head -n 1 ;;
    .last_reason) sed -n 's/.*"last_reason":"\([^"]*\)".*/\1/p' "$STATE_FILE" | head -n 1 ;;
    .last_repair_action) sed -n 's/.*"last_repair_action":"\([^"]*\)".*/\1/p' "$STATE_FILE" | head -n 1 ;;
    *) printf '\n' ;;
  esac
}

read_state_field() {
  local jq_bin

  jq_bin="${JQ_BIN:-$(command -v jq 2>/dev/null || true)}"
  if [[ -n "$jq_bin" ]]; then
    "$jq_bin" -r "$1" "$STATE_FILE"
    return 0
  fi

  read_state_field_fallback "$1"
}

write_state() {
  local state_dir tmp_file

  state_dir="$(dirname "$STATE_FILE")"
  mkdir -p "$state_dir"
  tmp_file="$(mktemp "$state_dir/gateway_watchdog_state.XXXXXX")"
  cat > "$tmp_file"
  mv "$tmp_file" "$STATE_FILE"
}

reap_stale_lock_if_needed() {
  local started_at now_epoch pid dir_mtime

  [[ -d "$WATCHDOG_LOCK_DIR" ]] || return 0

  now_epoch="$(state_now_epoch)"
  if [[ ! -f "$WATCHDOG_LOCK_DIR/pid" || ! -f "$WATCHDOG_LOCK_DIR/started_at" ]]; then
    dir_mtime="$(stat -f %m "$WATCHDOG_LOCK_DIR" 2>/dev/null || echo 0)"
    if (( now_epoch - dir_mtime > LOCK_STALE_SEC )); then
      rm -rf "$WATCHDOG_LOCK_DIR"
    fi
    return 0
  fi

  started_at="$(cat "$WATCHDOG_LOCK_DIR/started_at" 2>/dev/null || echo 0)"
  pid="$(cat "$WATCHDOG_LOCK_DIR/pid" 2>/dev/null || echo '')"

  if (( now_epoch - started_at > LOCK_STALE_SEC )) && { [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; }; then
    rm -f "$WATCHDOG_LOCK_DIR/pid" "$WATCHDOG_LOCK_DIR/started_at"
    rmdir "$WATCHDOG_LOCK_DIR" 2>/dev/null || rm -rf "$WATCHDOG_LOCK_DIR"
  fi
}

acquire_lock() {
  mkdir -p "$(dirname "$WATCHDOG_LOCK_DIR")"
  mkdir "$WATCHDOG_LOCK_DIR" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$WATCHDOG_LOCK_DIR/pid"
  state_now_epoch > "$WATCHDOG_LOCK_DIR/started_at"
}

acquire_watchdog_lock() {
  reap_stale_lock_if_needed
  if acquire_lock; then
    return 0
  fi

  if declare -F log >/dev/null 2>&1; then
    log WARN watchdog_locked "lock_dir=$WATCHDOG_LOCK_DIR"
  fi
  return 1
}

release_lock() {
  rm -f "$WATCHDOG_LOCK_DIR/pid" "$WATCHDOG_LOCK_DIR/started_at"
  rmdir "$WATCHDOG_LOCK_DIR" 2>/dev/null || true
}

init_runtime_paths() {
  mkdir -p "$WATCHDOG_RUNTIME_TMP_DIR"
  PROBE_OUTPUT_FILE="${PROBE_OUTPUT_FILE:-$(mktemp "$WATCHDOG_RUNTIME_TMP_DIR/probe.XXXXXX")}"
  REPAIR_OUTPUT_FILE="${REPAIR_OUTPUT_FILE:-$(mktemp "$WATCHDOG_RUNTIME_TMP_DIR/repair.XXXXXX")}"
  NOTIFY_OUTPUT_FILE="${NOTIFY_OUTPUT_FILE:-$(mktemp "$WATCHDOG_RUNTIME_TMP_DIR/notify.XXXXXX")}"
}

cleanup_runtime_paths() {
  if [[ -n "${PROBE_OUTPUT_FILE:-}" ]]; then
    rm -f "$PROBE_OUTPUT_FILE" "${PROBE_OUTPUT_FILE}.body" "${PROBE_OUTPUT_FILE}.err" 2>/dev/null || true
  fi
  if [[ -n "${REPAIR_OUTPUT_FILE:-}" ]]; then
    rm -f "$REPAIR_OUTPUT_FILE" "${REPAIR_OUTPUT_FILE}.body" "${REPAIR_OUTPUT_FILE}.err" 2>/dev/null || true
  fi
  if [[ -n "${NOTIFY_OUTPUT_FILE:-}" ]]; then
    rm -f "$NOTIFY_OUTPUT_FILE"
    rm -f "${NOTIFY_OUTPUT_FILE}".*.body "${NOTIFY_OUTPUT_FILE}".*.err 2>/dev/null || true
  fi
}
