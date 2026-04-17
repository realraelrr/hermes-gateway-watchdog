import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '..');
const fixturesDir = path.join(__dirname, 'fixtures');
const wrapperPath = path.join(repoRoot, 'gateway-watchdog.sh');
const corePath = path.join(repoRoot, 'watchdog-core.sh');
const healthyGatewayStatePath = path.join(fixturesDir, 'gateway-state.healthy.json');
const startingGatewayStatePath = path.join(fixturesDir, 'gateway-state.starting.json');
const healthyReadyPath = path.join(fixturesDir, 'cloudflared-ready.healthy.json');
const zeroReadyPath = path.join(fixturesDir, 'cloudflared-ready.zero.json');

function readFile(filePath) {
  return fs.readFileSync(filePath, 'utf8');
}

function writeJson(filePath, value) {
  fs.writeFileSync(filePath, `${JSON.stringify(value)}\n`);
}

function runBash(script, { env = {} } = {}) {
  return execFileSync('/bin/bash', ['-lc', script], {
    encoding: 'utf8',
    env: { ...process.env, ...env },
  });
}

function runProbe(script, { env = {} } = {}) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hermes-watchdog-probe-run-'));
  const probeStatusFile = path.join(tempDir, 'probe.status');

  return runBash(
    `${script}
probe_gateway > "${probeStatusFile}"
printf '%s|%s\\n' "$(cat "${probeStatusFile}")" "$PROBE_REASON"
`,
    { env },
  );
}

function escapeForRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

test('wrapper: gateway-watchdog.sh is a thin entrypoint shell', () => {
  const script = readFile(wrapperPath);

  assert.match(script, /^#!\/usr\/bin\/env bash/m);
  assert.match(script, /^set -euo pipefail$/m);
  assert.match(script, /source "\$SCRIPT_DIR\/watchdog-core\.sh"/);
  assert.match(script, /watchdog_main "\$@"/);
  assert.doesNotMatch(script, /probe_gateway\(\)/);
  assert.doesNotMatch(script, /run_repair_plan\(\)/);
});

test('config precedence: HERMES_HOME and WATCHDOG_HOME derive env, state, and log paths', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hermes-watchdog-config-'));
  const watchdogHome = path.join(tempDir, 'watchdog');
  const envFile = path.join(tempDir, 'watchdog.env');

  fs.writeFileSync(
    envFile,
    [
      `WATCHDOG_HOME=${watchdogHome}`,
      'FAIL_THRESHOLD=9',
      'NOTIFIER=feishu',
      '',
    ].join('\n'),
  );

  const output = runBash(
    `
      source "${corePath}"
      load_watchdog_config
      printf '%s\\n' \
        "HERMES_HOME=$HERMES_HOME" \
        "WATCHDOG_HOME=$WATCHDOG_HOME" \
        "WATCHDOG_ENV_FILE=$WATCHDOG_ENV_FILE" \
        "STATE_FILE=$STATE_FILE" \
        "LOG_FILE=$LOG_FILE" \
        "FAIL_THRESHOLD=$FAIL_THRESHOLD" \
        "NOTIFIER=$NOTIFIER"
    `,
    {
      env: {
        HOME: tempDir,
        HERMES_HOME: path.join(tempDir, 'hermes'),
        WATCHDOG_ENV_FILE: envFile,
        FAIL_THRESHOLD: '5',
      },
    },
  );

  assert.match(output, new RegExp(`HERMES_HOME=${escapeForRegex(path.join(tempDir, 'hermes'))}`));
  assert.match(output, new RegExp(`WATCHDOG_HOME=${escapeForRegex(watchdogHome)}`));
  assert.match(output, new RegExp(`WATCHDOG_ENV_FILE=${escapeForRegex(envFile)}`));
  assert.match(
    output,
    new RegExp(
      `STATE_FILE=${escapeForRegex(path.join(watchdogHome, '.state', 'runtime', 'gateway_watchdog_state.json'))}`,
    ),
  );
  assert.match(
    output,
    new RegExp(`LOG_FILE=${escapeForRegex(path.join(watchdogHome, 'logs', 'gateway-watchdog.log'))}`),
  );
  assert.match(output, /FAIL_THRESHOLD=5/);
  assert.match(output, /NOTIFIER=feishu/);
});

test('disable semantics: watchdog_main exits before probe or repair', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hermes-watchdog-disabled-'));
  const output = runBash(`
    source "${corePath}"
    load_watchdog_config() {
      WATCHDOG_ENABLED=0
      WATCHDOG_DISABLE_FILE="${path.join(tempDir, 'disabled')}"
      WATCHDOG_LOCK_DIR="${path.join(tempDir, 'gateway.lock')}"
      WATCHDOG_RUNTIME_TMP_DIR="${path.join(tempDir, 'tmp')}"
      STATE_FILE="${path.join(tempDir, 'state.json')}"
      LOG_FILE="${path.join(tempDir, 'watchdog.log')}"
      NOTIFIER=composite
    }
    probe_gateway() { printf 'probe-called\\n'; }
    run_repair_plan() { printf 'repair-called\\n'; }
    log() { :; }
    load_notifier() { :; }
    notifier_init() { :; }
    notifier_cleanup() { :; }
    watchdog_main
    printf 'done\\n'
  `);

  assert.equal(output.trim(), 'done');
});

test('probe: returns ok for healthy Hermes contract', () => {
  const output = runProbe(`
    source "${corePath}"
    log() { :; }
    JQ_BIN="$(command -v jq)"
    CURRENT_GATEWAY_PID=111
    CURRENT_CLOUDFLARED_PID=222
    gateway_state_file_path() { printf '%s\\n' "${healthyGatewayStatePath}"; }
    check_gateway_listener() { return 0; }
    http_probe() {
      case "$1" in
        *"/ready") printf '200\\t%s\\n' "$(cat "${healthyReadyPath}")" ;;
        *"/feishu/webhook") printf '405\\t{}\\n' ;;
      esac
    }
  `);

  assert.equal(output.trim(), 'ok|ok');
});

test('probe: accepts Hermes offset timestamps in gateway_state.json', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hermes-watchdog-offset-ts-'));
  const offsetPath = path.join(tempDir, 'gateway_state.json');
  const offsetTs = new Date().toISOString().replace('Z', '+00:00');
  writeJson(offsetPath, {
    gateway_state: 'running',
    updated_at: offsetTs,
    platforms: { feishu: { state: 'connected' } },
  });

  const output = runProbe(`
    source "${corePath}"
    log() { :; }
    JQ_BIN="$(command -v jq)"
    CURRENT_GATEWAY_PID=111
    CURRENT_CLOUDFLARED_PID=222
    gateway_state_file_path() { printf '%s\\n' "${offsetPath}"; }
    check_gateway_listener() { return 0; }
    http_probe() {
      case "$1" in
        *"/ready") printf '200\\t%s\\n' "$(cat "${healthyReadyPath}")" ;;
        *"/feishu/webhook") printf '405\\t{}\\n' ;;
      esac
    }
  `);

  assert.equal(output.trim(), 'ok|ok');
});

test('probe: returns fail when gateway_state.json is stale', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hermes-watchdog-stale-'));
  const stalePath = path.join(tempDir, 'gateway_state.json');
  writeJson(stalePath, {
    gateway_state: 'running',
    updated_at: '2020-01-01T00:00:00Z',
    platforms: { feishu: { state: 'connected' } },
  });

  const output = runProbe(`
    source "${corePath}"
    log() { :; }
    JQ_BIN="$(command -v jq)"
    GATEWAY_STATE_MAX_AGE_SEC=90
    gateway_state_file_path() { printf '%s\\n' "${stalePath}"; }
    check_gateway_listener() { return 0; }
    http_probe() {
      case "$1" in
        *"/ready") printf '200\\t%s\\n' "$(cat "${healthyReadyPath}")" ;;
        *"/feishu/webhook") printf '405\\t{}\\n' ;;
      esac
    }
  `);

  assert.equal(output.trim(), 'fail|gateway_state_stale');
});

test('probe: returns fail on malformed gateway_state.json', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hermes-watchdog-invalid-state-'));
  const invalidPath = path.join(tempDir, 'gateway_state.json');
  fs.writeFileSync(invalidPath, '{bad json\n');

  const output = runProbe(`
    source "${corePath}"
    log() { :; }
    JQ_BIN="$(command -v jq)"
    gateway_state_file_path() { printf '%s\\n' "${invalidPath}"; }
    check_gateway_listener() { return 0; }
    http_probe() {
      case "$1" in
        *"/ready") printf '200\\t%s\\n' "$(cat "${healthyReadyPath}")" ;;
        *"/feishu/webhook") printf '405\\t{}\\n' ;;
      esac
    }
  `);

  assert.equal(output.trim(), 'fail|gateway_state_invalid_json');
});

test('probe: returns fail on invalid top-level updated_at', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hermes-watchdog-bad-ts-'));
  const invalidTsPath = path.join(tempDir, 'gateway_state.json');
  writeJson(invalidTsPath, {
    gateway_state: 'running',
    updated_at: 'not-a-time',
    platforms: { feishu: { state: 'connected' } },
  });

  const output = runProbe(`
    source "${corePath}"
    log() { :; }
    JQ_BIN="$(command -v jq)"
    gateway_state_file_path() { printf '%s\\n' "${invalidTsPath}"; }
    check_gateway_listener() { return 0; }
    http_probe() {
      case "$1" in
        *"/ready") printf '200\\t%s\\n' "$(cat "${healthyReadyPath}")" ;;
        *"/feishu/webhook") printf '405\\t{}\\n' ;;
      esac
    }
  `);

  assert.equal(output.trim(), 'fail|gateway_state_timestamp_invalid');
});

test('probe: returns fail when the local listener is down', () => {
  const output = runProbe(`
    source "${corePath}"
    log() { :; }
    JQ_BIN="$(command -v jq)"
    gateway_state_file_path() { printf '%s\\n' "${healthyGatewayStatePath}"; }
    check_gateway_listener() { return 1; }
    http_probe() {
      case "$1" in
        *"/ready") printf '200\\t%s\\n' "$(cat "${healthyReadyPath}")" ;;
        *"/feishu/webhook") printf '405\\t{}\\n' ;;
      esac
    }
  `);

  assert.equal(output.trim(), 'fail|gateway_listener_down');
});

test('probe: returns fail for zero readyConnections outside grace', () => {
  const output = runProbe(`
    source "${corePath}"
    log() { :; }
    JQ_BIN="$(command -v jq)"
    CURRENT_GATEWAY_PID=111
    CURRENT_CLOUDFLARED_PID=222
    gateway_state_file_path() { printf '%s\\n' "${healthyGatewayStatePath}"; }
    check_gateway_listener() { return 0; }
    http_probe() {
      case "$1" in
        *"/ready") printf '503\\t%s\\n' "$(cat "${zeroReadyPath}")" ;;
        *"/feishu/webhook") printf '405\\t{}\\n' ;;
      esac
    }
  `);

  assert.equal(output.trim(), 'fail|cloudflared_ready_zero');
});

test('probe: returns neutral for zero readyConnections inside grace', () => {
  const output = runProbe(`
    source "${corePath}"
    log() { :; }
    JQ_BIN="$(command -v jq)"
    PROBE_WITHIN_GRACE=1
    CURRENT_GATEWAY_PID=111
    CURRENT_CLOUDFLARED_PID=222
    gateway_state_file_path() { printf '%s\\n' "${healthyGatewayStatePath}"; }
    check_gateway_listener() { return 0; }
    http_probe() {
      case "$1" in
        *"/ready") printf '503\\t%s\\n' "$(cat "${zeroReadyPath}")" ;;
        *"/feishu/webhook") printf '405\\t{}\\n' ;;
      esac
    }
  `);

  assert.equal(output.trim(), 'neutral|cloudflared_ready_zero');
});

test('probe: returns fail for invalid /ready JSON', () => {
  const output = runProbe(`
    source "${corePath}"
    log() { :; }
    JQ_BIN="$(command -v jq)"
    gateway_state_file_path() { printf '%s\\n' "${healthyGatewayStatePath}"; }
    check_gateway_listener() { return 0; }
    http_probe() {
      case "$1" in
        *"/ready") printf '200\\t{"bad":true}\\n' ;;
        *"/feishu/webhook") printf '405\\t{}\\n' ;;
      esac
    }
  `);

  assert.equal(output.trim(), 'fail|cloudflared_ready_invalid_json');
});

test('probe: returns fail when /ready is unreachable', () => {
  const output = runProbe(`
    source "${corePath}"
    log() { :; }
    JQ_BIN="$(command -v jq)"
    gateway_state_file_path() { printf '%s\\n' "${healthyGatewayStatePath}"; }
    check_gateway_listener() { return 0; }
    http_probe() {
      case "$1" in
        *"/ready") return 7 ;;
        *"/feishu/webhook") printf '405\\t{}\\n' ;;
      esac
    }
  `);

  assert.equal(output.trim(), 'fail|cloudflared_ready_unreachable');
});

test('probe: returns fail for non-200 or non-503 /ready responses', () => {
  const output = runProbe(`
    source "${corePath}"
    log() { :; }
    JQ_BIN="$(command -v jq)"
    gateway_state_file_path() { printf '%s\\n' "${healthyGatewayStatePath}"; }
    check_gateway_listener() { return 0; }
    http_probe() {
      case "$1" in
        *"/ready") printf '500\\t{"detail":"upstream"}\\n' ;;
        *"/feishu/webhook") printf '405\\t{}\\n' ;;
      esac
    }
  `);

  assert.equal(output.trim(), 'fail|cloudflared_ready_http_error');
});

test('probe: returns fail for missing webhook route', () => {
  const output = runProbe(`
    source "${corePath}"
    log() { :; }
    JQ_BIN="$(command -v jq)"
    gateway_state_file_path() { printf '%s\\n' "${healthyGatewayStatePath}"; }
    check_gateway_listener() { return 0; }
    http_probe() {
      case "$1" in
        *"/ready") printf '200\\t%s\\n' "$(cat "${healthyReadyPath}")" ;;
        *"/feishu/webhook") printf '404\\t{}\\n' ;;
      esac
    }
  `);

  assert.equal(output.trim(), 'fail|webhook_route_missing');
});

test('probe: returns fail when webhook probe is unreachable', () => {
  const output = runProbe(`
    source "${corePath}"
    log() { :; }
    JQ_BIN="$(command -v jq)"
    gateway_state_file_path() { printf '%s\\n' "${healthyGatewayStatePath}"; }
    check_gateway_listener() { return 0; }
    http_probe() {
      case "$1" in
        *"/ready") printf '200\\t%s\\n' "$(cat "${healthyReadyPath}")" ;;
        *"/feishu/webhook") return 7 ;;
      esac
    }
  `);

  assert.equal(output.trim(), 'fail|webhook_probe_unreachable');
});

test('probe: returns neutral for gateway starting inside grace', () => {
  const output = runProbe(`
    source "${corePath}"
    log() { :; }
    JQ_BIN="$(command -v jq)"
    PROBE_WITHIN_GRACE=1
    CURRENT_GATEWAY_PID=111
    CURRENT_CLOUDFLARED_PID=222
    gateway_state_file_path() { printf '%s\\n' "${startingGatewayStatePath}"; }
    check_gateway_listener() { return 1; }
    http_probe() {
      case "$1" in
        *"/ready") printf '503\\t%s\\n' "$(cat "${zeroReadyPath}")" ;;
        *"/feishu/webhook") return 7 ;;
      esac
    }
  `);

  assert.equal(output.trim(), 'neutral|gateway_not_running');
});

test('repair: chooses cloudflared-only action for tunnel-side failures', () => {
  const output = runBash(`
    source "${corePath}"
    PROBE_REASON="cloudflared_ready_zero"
    PROBE_GATEWAY_HEALTH="ok"
    PROBE_CLOUDFLARED_HEALTH="bad"
    printf '%s\\n' "$(determine_repair_action)"
  `);

  assert.equal(output.trim(), 'restart_cloudflared');
});

test('repair: chooses gateway-only action for Hermes-side failures', () => {
  const output = runBash(`
    source "${corePath}"
    PROBE_REASON="feishu_not_connected"
    PROBE_GATEWAY_HEALTH="bad"
    PROBE_CLOUDFLARED_HEALTH="ok"
    printf '%s\\n' "$(determine_repair_action)"
  `);

  assert.equal(output.trim(), 'restart_gateway');
});

test('repair: staged repair restarts cloudflared before escalating to gateway', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hermes-watchdog-repair-'));
  const callsFile = path.join(tempDir, 'calls.log');
  const counterFile = path.join(tempDir, 'probe.count');

  const output = runBash(`
    source "${corePath}"
    log() { :; }
    COOLDOWN_SEC=300
    POST_RESTART_RETRIES=2
    POST_RESTART_SLEEP_SEC=0
    GATEWAY_LABEL="com.hermes.gateway"
    CLOUDFLARED_LABEL="com.cloudflare.cloudflared"
    REPAIR_OUTPUT_FILE="${path.join(tempDir, 'repair.out')}"
    sleep() { :; }
    launchctl_restart_label() {
      printf '%s\\n' "$1" >> "${callsFile}"
      return 0
    }
    probe_gateway() {
      local count
      count="$(cat "${counterFile}" 2>/dev/null || printf '0')"
      count=$((count + 1))
      printf '%s\\n' "$count" > "${counterFile}"
      case "$count" in
        1)
          PROBE_STATUS="fail"
          PROBE_REASON="feishu_not_connected"
          PROBE_GATEWAY_HEALTH="bad"
          PROBE_CLOUDFLARED_HEALTH="ok"
          printf 'fail\\n'
          ;;
        2)
          PROBE_STATUS="fail"
          PROBE_REASON="feishu_not_connected"
          PROBE_GATEWAY_HEALTH="bad"
          PROBE_CLOUDFLARED_HEALTH="ok"
          printf 'fail\\n'
          ;;
        *)
          PROBE_STATUS="ok"
          PROBE_REASON="ok"
          PROBE_GATEWAY_HEALTH="ok"
          PROBE_CLOUDFLARED_HEALTH="ok"
          printf 'ok\\n'
          ;;
      esac
    }
    PROBE_REASON="cloudflared_ready_unreachable"
    PROBE_GATEWAY_HEALTH="bad"
    PROBE_CLOUDFLARED_HEALTH="bad"
    if run_repair_plan; then
      printf 'status=0 action=%s\\n' "$REPAIR_ACTION"
    else
      printf 'status=%s action=%s reason=%s\\n' "$?" "$REPAIR_ACTION" "$RESTART_FAILURE_REASON"
    fi
    cat "${callsFile}"
  `);

  assert.match(output, /status=0 action=restart_cloudflared_then_gateway/);
  assert.match(output, /com\.cloudflare\.cloudflared/);
  assert.match(output, /com\.hermes\.gateway/);
});

test('repair: neutral probes during grace do not fail recovery early', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hermes-watchdog-repair-grace-'));
  const seenFile = path.join(tempDir, 'seen.log');
  const countFile = path.join(tempDir, 'count.log');

  const output = runBash(`
    source "${corePath}"
    POST_RESTART_RETRIES=1
    POST_RESTART_SLEEP_SEC=0
    TRANSITION_GRACE_SEC=3
    GATEWAY_LABEL="com.hermes.gateway"
    REPAIR_OUTPUT_FILE="${path.join(tempDir, 'repair.out')}"
    sleep() { :; }
    launchctl_restart_label() { return 0; }
    state_now_epoch() {
      local count
      count="$(cat "${countFile}" 2>/dev/null || printf '0')"
      count=$((count + 1))
      printf '%s\\n' "$count" > "${countFile}"
      printf '%s\\n' "$count"
    }
    probe_gateway() {
      local count
      count="$(cat "${countFile}")"
      printf 'grace=%s\\n' "\${PROBE_WITHIN_GRACE:-unset}" >> "${seenFile}"
      if (( count <= 3 )); then
        PROBE_STATUS="neutral"
        PROBE_REASON="feishu_not_connected"
        PROBE_GATEWAY_HEALTH="partial"
        PROBE_CLOUDFLARED_HEALTH="ok"
        printf 'neutral\\n'
      else
        PROBE_STATUS="ok"
        PROBE_REASON="ok"
        PROBE_GATEWAY_HEALTH="ok"
        PROBE_CLOUDFLARED_HEALTH="ok"
        printf 'ok\\n'
      fi
    }
    PROBE_REASON="feishu_not_connected"
    PROBE_GATEWAY_HEALTH="bad"
    PROBE_CLOUDFLARED_HEALTH="ok"
    if run_repair_plan; then
      printf 'status=0\\n'
    else
      printf 'status=%s reason=%s\\n' "$?" "$RESTART_FAILURE_REASON"
    fi
    printf 'count=%s\\n' "$(cat "${countFile}")"
    cat "${seenFile}"
  `);

  assert.match(output, /status=0/);
  assert.match(output, /count=4/);
  assert.match(output, /grace=1/);
});

test('lock: stale lock is reaped and reacquired before taking ownership', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hermes-watchdog-lock-'));
  const lockDir = path.join(tempDir, 'gateway.lock');

  const output = runBash(`
    source "${corePath}"
    log() { :; }
    WATCHDOG_LOCK_DIR="${lockDir}"
    LOCK_STALE_SEC=1
    mkdir -p "$WATCHDOG_LOCK_DIR"
    printf '999999\\n' > "$WATCHDOG_LOCK_DIR/pid"
    printf '0\\n' > "$WATCHDOG_LOCK_DIR/started_at"
    if acquire_watchdog_lock; then
      printf 'acquired=%s\\n' "$(cat "$WATCHDOG_LOCK_DIR/pid")"
    else
      printf 'locked\\n'
    fi
  `);

  assert.match(output, /acquired=/);
  assert.doesNotMatch(output, /999999/);
});

test('watchdog_main: missing required tools is a non-repairable failure path', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hermes-watchdog-required-tool-'));
  const stateFile = path.join(tempDir, 'state.json');
  const repairFile = path.join(tempDir, 'repair.log');

  const output = runBash(`
    source "${corePath}"
    load_watchdog_config() {
      WATCHDOG_ENABLED=1
      FAIL_THRESHOLD=1
      COOLDOWN_SEC=300
      POST_RESTART_RETRIES=1
      POST_RESTART_SLEEP_SEC=0
      INITIAL_GRACE_SEC=0
      TRANSITION_GRACE_SEC=0
      WATCHDOG_DISABLE_FILE="${path.join(tempDir, 'disabled')}"
      WATCHDOG_LOCK_DIR="${path.join(tempDir, 'gateway.lock')}"
      WATCHDOG_RUNTIME_TMP_DIR="${path.join(tempDir, 'tmp')}"
      STATE_FILE="${stateFile}"
      LOG_FILE="${path.join(tempDir, 'watchdog.log')}"
      GATEWAY_LABEL="com.hermes.gateway"
      CLOUDFLARED_LABEL="com.cloudflare.cloudflared"
      NOTIFIER=composite
    }
    load_notifier() { :; }
    notifier_init() { :; }
    notifier_cleanup() { :; }
    notify_send() { :; }
    log() { :; }
    resolve_required_bins() {
      REQUIRED_TOOL_REASON="required_tool_missing"
      return 1
    }
    run_repair_plan() { printf 'repair\\n' >> "${repairFile}"; }
    watchdog_main
    cat "${stateFile}"
  `);

  const state = JSON.parse(output.trim());
  assert.equal(state.last_reason, 'required_tool_missing');
  assert.equal(state.last_repair_action, 'none');
  assert.equal(fs.existsSync(repairFile), false);
});

test('watchdog_main: missing required tools emits a failure notification at threshold', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hermes-watchdog-required-tool-notify-'));
  const noticesFile = path.join(tempDir, 'notices.log');

  const output = runBash(`
    source "${corePath}"
    load_watchdog_config() {
      WATCHDOG_ENABLED=1
      FAIL_THRESHOLD=1
      COOLDOWN_SEC=300
      POST_RESTART_RETRIES=1
      POST_RESTART_SLEEP_SEC=0
      INITIAL_GRACE_SEC=0
      TRANSITION_GRACE_SEC=0
      WATCHDOG_DISABLE_FILE="${path.join(tempDir, 'disabled')}"
      WATCHDOG_LOCK_DIR="${path.join(tempDir, 'gateway.lock')}"
      WATCHDOG_RUNTIME_TMP_DIR="${path.join(tempDir, 'tmp')}"
      STATE_FILE="${path.join(tempDir, 'state.json')}"
      LOG_FILE="${path.join(tempDir, 'watchdog.log')}"
      GATEWAY_LABEL="com.hermes.gateway"
      CLOUDFLARED_LABEL="com.cloudflare.cloudflared"
      NOTIFIER=composite
    }
    load_notifier() { :; }
    notifier_init() { :; }
    notifier_cleanup() { :; }
    notify_send() { printf '%s\\n' "$1" >> "${noticesFile}"; }
    log() { :; }
    resolve_required_bins() {
      REQUIRED_TOOL_REASON="required_tool_missing"
      return 1
    }
    watchdog_main
    cat "${noticesFile}"
  `);

  assert.match(output, /event=restart_failed/);
  assert.match(output, /reason=required_tool_missing/);
  assert.match(output, /action=none/);
});

test('watchdog_main: required_tool_missing respects cooldown before notifying again', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hermes-watchdog-required-tool-cooldown-'));
  const noticesFile = path.join(tempDir, 'notices.log');
  const futureEpoch = Math.floor(Date.now() / 1000) + 600;

  const output = runBash(`
    source "${corePath}"
    load_watchdog_config() {
      WATCHDOG_ENABLED=1
      FAIL_THRESHOLD=1
      COOLDOWN_SEC=300
      POST_RESTART_RETRIES=1
      POST_RESTART_SLEEP_SEC=0
      INITIAL_GRACE_SEC=0
      TRANSITION_GRACE_SEC=0
      WATCHDOG_DISABLE_FILE="${path.join(tempDir, 'disabled')}"
      WATCHDOG_LOCK_DIR="${path.join(tempDir, 'gateway.lock')}"
      WATCHDOG_RUNTIME_TMP_DIR="${path.join(tempDir, 'tmp')}"
      STATE_FILE="${path.join(tempDir, 'state.json')}"
      LOG_FILE="${path.join(tempDir, 'watchdog.log')}"
      GATEWAY_LABEL="com.hermes.gateway"
      CLOUDFLARED_LABEL="com.cloudflare.cloudflared"
      NOTIFIER=composite
    }
    load_notifier() { :; }
    notifier_init() { :; }
    notifier_cleanup() { :; }
    notify_send() { printf '%s\\n' "$1" >> "${noticesFile}"; }
    log() { :; }
    resolve_required_bins() {
      REQUIRED_TOOL_REASON="required_tool_missing"
      return 1
    }
    load_watchdog_config
    init_state
    cat <<JSON | write_state
{"watchdog_boot_at":"2026-04-17T00:00:00Z","has_seen_ok":true,"consecutive_failures":1,"last_ok_at":"2026-04-17T00:00:00Z","last_failure_at":"","last_restart_at":"","cooldown_until_epoch":${futureEpoch},"initial_grace_until_epoch":0,"transition_grace_until_epoch":0,"transition_reason":"","last_gateway_pid":"111","last_cloudflared_pid":"111","last_reason":"required_tool_missing","last_repair_action":"none"}
JSON
    watchdog_main
    if [[ -f "${noticesFile}" ]]; then cat "${noticesFile}"; fi
  `);

  assert.equal(output.trim(), '');
});

test('watchdog_main: probe marks both gateway and cloudflared bad on combined failure', () => {
  const output = runBash(`
    source "${corePath}"
    log() { :; }
    JQ_BIN="$(command -v jq)"
    gateway_state_file_path() { printf '%s\\n' "${healthyGatewayStatePath}"; }
    check_gateway_listener() { return 1; }
    http_probe() {
      case "$1" in
        *"/ready") printf '503\\t%s\\n' "$(cat "${zeroReadyPath}")" ;;
        *"/feishu/webhook") printf '405\\t{}\\n' ;;
      esac
    }
    probe_gateway > /dev/null
    printf '%s|%s|%s\\n' "$PROBE_REASON" "$PROBE_GATEWAY_HEALTH" "$PROBE_CLOUDFLARED_HEALTH"
  `);

  assert.equal(output.trim(), 'gateway_listener_down|bad|bad');
});

test('watchdog_main: success notification preserves the triggering reason and action', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hermes-watchdog-success-notify-'));
  const noticesFile = path.join(tempDir, 'notices.log');
  const recoveredFlag = path.join(tempDir, 'recovered.flag');

  const output = runBash(`
    source "${corePath}"
    load_watchdog_config() {
      WATCHDOG_ENABLED=1
      FAIL_THRESHOLD=1
      COOLDOWN_SEC=300
      POST_RESTART_RETRIES=1
      POST_RESTART_SLEEP_SEC=0
      INITIAL_GRACE_SEC=0
      TRANSITION_GRACE_SEC=0
      WATCHDOG_DISABLE_FILE="${path.join(tempDir, 'disabled')}"
      WATCHDOG_LOCK_DIR="${path.join(tempDir, 'gateway.lock')}"
      WATCHDOG_RUNTIME_TMP_DIR="${path.join(tempDir, 'tmp')}"
      STATE_FILE="${path.join(tempDir, 'state.json')}"
      LOG_FILE="${path.join(tempDir, 'watchdog.log')}"
      GATEWAY_LABEL="com.hermes.gateway"
      CLOUDFLARED_LABEL="com.cloudflare.cloudflared"
      NOTIFIER=composite
    }
    load_notifier() { :; }
    notifier_init() { :; }
    notifier_cleanup() { :; }
    notify_send() { printf '%s\\n' "$1" >> "${noticesFile}"; }
    log() { :; }
    resolve_required_bins() {
      CURL_BIN="/usr/bin/curl"
      JQ_BIN="$(command -v jq)"
      LAUNCHCTL_BIN="/bin/echo"
      LSOF_BIN="/usr/sbin/lsof"
      return 0
    }
    get_launchd_pid() { printf '111\\n'; }
    probe_gateway() {
      if [[ -f "${recoveredFlag}" ]]; then
        PROBE_STATUS="ok"
        PROBE_REASON="ok"
        PROBE_GATEWAY_HEALTH="ok"
        PROBE_CLOUDFLARED_HEALTH="ok"
        printf 'ok\\n'
        return 0
      fi
      PROBE_STATUS="fail"
      PROBE_REASON="feishu_not_connected"
      PROBE_GATEWAY_HEALTH="bad"
      PROBE_CLOUDFLARED_HEALTH="ok"
      printf 'fail\\n'
    }
    determine_repair_action() { printf 'restart_gateway\\n'; }
    run_repair_plan() {
      touch "${recoveredFlag}"
      REPAIR_ACTION="restart_gateway"
      return 0
    }
    watchdog_main
    cat "${noticesFile}"
  `);

  assert.match(output, /event=restart_triggered/);
  assert.match(output, /event=restart_succeeded/);
  assert.match(output, /event=restart_triggered .*reason=feishu_not_connected action=restart_gateway/);
  assert.match(output, /event=restart_succeeded .*reason=feishu_not_connected action=restart_gateway/);
  assert.doesNotMatch(output, /event=restart_succeeded .*reason=ok/);
});

test('watchdog_main: logs resolved tool paths on a healthy tick', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hermes-watchdog-tools-log-'));
  const logFile = path.join(tempDir, 'watchdog.log');

  runBash(`
    source "${corePath}"
    load_watchdog_config() {
      WATCHDOG_ENABLED=1
      FAIL_THRESHOLD=3
      COOLDOWN_SEC=300
      POST_RESTART_RETRIES=1
      POST_RESTART_SLEEP_SEC=0
      INITIAL_GRACE_SEC=0
      TRANSITION_GRACE_SEC=0
      WATCHDOG_DISABLE_FILE="${path.join(tempDir, 'disabled')}"
      WATCHDOG_LOCK_DIR="${path.join(tempDir, 'gateway.lock')}"
      WATCHDOG_RUNTIME_TMP_DIR="${path.join(tempDir, 'tmp')}"
      STATE_FILE="${path.join(tempDir, 'state.json')}"
      LOG_FILE="${logFile}"
      GATEWAY_LABEL="com.hermes.gateway"
      CLOUDFLARED_LABEL="com.cloudflare.cloudflared"
      NOTIFIER=composite
    }
    load_notifier() { :; }
    notifier_init() { :; }
    notifier_cleanup() { :; }
    notify_send() { :; }
    resolve_required_bins() {
      CURL_BIN="/usr/bin/curl"
      JQ_BIN="$(command -v jq)"
      LAUNCHCTL_BIN="/bin/echo"
      LSOF_BIN="/usr/sbin/lsof"
      return 0
    }
    get_launchd_pid() { printf '111\\n'; }
    probe_gateway() {
      PROBE_REASON="ok"
      PROBE_GATEWAY_HEALTH="ok"
      PROBE_CLOUDFLARED_HEALTH="ok"
      printf 'ok\\n'
    }
    watchdog_main
    cat "${logFile}"
  `);

  const log = fs.readFileSync(logFile, 'utf8');
  assert.match(log, /event=tools_resolved/);
  assert.match(log, /curl=\/usr\/bin\/curl/);
  assert.match(log, /launchctl=\/bin\/echo/);
});

test('watchdog_main: cooldown suppresses repair while still recording the new failure', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hermes-watchdog-cooldown-'));
  const stateFile = path.join(tempDir, 'state.json');
  const repairFile = path.join(tempDir, 'repair.log');
  const futureEpoch = Math.floor(Date.now() / 1000) + 600;

  const output = runBash(`
    source "${corePath}"
    load_watchdog_config() {
      WATCHDOG_ENABLED=1
      FAIL_THRESHOLD=1
      COOLDOWN_SEC=300
      POST_RESTART_RETRIES=1
      POST_RESTART_SLEEP_SEC=0
      INITIAL_GRACE_SEC=0
      TRANSITION_GRACE_SEC=0
      WATCHDOG_DISABLE_FILE="${path.join(tempDir, 'disabled')}"
      WATCHDOG_LOCK_DIR="${path.join(tempDir, 'gateway.lock')}"
      WATCHDOG_RUNTIME_TMP_DIR="${path.join(tempDir, 'tmp')}"
      STATE_FILE="${stateFile}"
      LOG_FILE="${path.join(tempDir, 'watchdog.log')}"
      GATEWAY_LABEL="com.hermes.gateway"
      CLOUDFLARED_LABEL="com.cloudflare.cloudflared"
      NOTIFIER=composite
    }
    load_notifier() { :; }
    notifier_init() { :; }
    notifier_cleanup() { :; }
    notify_send() { :; }
    log() { :; }
    resolve_required_bins() {
      CURL_BIN="/usr/bin/curl"
      JQ_BIN="$(command -v jq)"
      LAUNCHCTL_BIN="/bin/echo"
      LSOF_BIN="/usr/sbin/lsof"
      return 0
    }
    get_launchd_pid() { printf '111\\n'; }
    probe_gateway() {
      PROBE_STATUS="fail"
      PROBE_REASON="cloudflared_ready_zero"
      PROBE_GATEWAY_HEALTH="ok"
      PROBE_CLOUDFLARED_HEALTH="bad"
      printf 'fail\\n'
    }
    run_repair_plan() { printf 'repair\\n' >> "${repairFile}"; }
    load_watchdog_config
    init_state
    cat <<JSON | write_state
{"watchdog_boot_at":"2026-04-17T00:00:00Z","has_seen_ok":true,"consecutive_failures":1,"last_ok_at":"2026-04-17T00:00:00Z","last_failure_at":"","last_restart_at":"","cooldown_until_epoch":${futureEpoch},"initial_grace_until_epoch":0,"transition_grace_until_epoch":0,"transition_reason":"","last_gateway_pid":"111","last_cloudflared_pid":"111","last_reason":"","last_repair_action":""}
JSON
    watchdog_main
    cat "${stateFile}"
  `);

  const state = JSON.parse(output.trim());
  assert.equal(state.consecutive_failures, 2);
  assert.equal(state.cooldown_until_epoch, futureEpoch);
  assert.equal(fs.existsSync(repairFile), false);
});

test('watchdog_main: launchctl restart failure does not start cooldown or grace without a restart', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hermes-watchdog-launchctl-fail-'));
  const stateFile = path.join(tempDir, 'state.json');

  const output = runBash(`
    source "${corePath}"
    load_watchdog_config() {
      WATCHDOG_ENABLED=1
      FAIL_THRESHOLD=1
      COOLDOWN_SEC=300
      POST_RESTART_RETRIES=1
      POST_RESTART_SLEEP_SEC=0
      INITIAL_GRACE_SEC=0
      TRANSITION_GRACE_SEC=45
      WATCHDOG_DISABLE_FILE="${path.join(tempDir, 'disabled')}"
      WATCHDOG_LOCK_DIR="${path.join(tempDir, 'gateway.lock')}"
      WATCHDOG_RUNTIME_TMP_DIR="${path.join(tempDir, 'tmp')}"
      STATE_FILE="${stateFile}"
      LOG_FILE="${path.join(tempDir, 'watchdog.log')}"
      GATEWAY_LABEL="com.hermes.gateway"
      CLOUDFLARED_LABEL="com.cloudflare.cloudflared"
      NOTIFIER=composite
    }
    load_notifier() { :; }
    notifier_init() { :; }
    notifier_cleanup() { :; }
    notify_send() { :; }
    log() { :; }
    resolve_required_bins() {
      CURL_BIN="/usr/bin/curl"
      JQ_BIN="$(command -v jq)"
      LAUNCHCTL_BIN="/bin/echo"
      LSOF_BIN="/usr/sbin/lsof"
      return 0
    }
    get_launchd_pid() { printf '111\\n'; }
    probe_gateway() {
      PROBE_STATUS="fail"
      PROBE_REASON="cloudflared_ready_zero"
      PROBE_GATEWAY_HEALTH="ok"
      PROBE_CLOUDFLARED_HEALTH="bad"
      printf 'fail\\n'
    }
    launchctl_restart_label() {
      RESTART_FAILURE_REASON="launchctl_restart_failed"
      return 1
    }
    load_watchdog_config
    init_state
    cat <<JSON | write_state
{"watchdog_boot_at":"2026-04-17T00:00:00Z","has_seen_ok":true,"consecutive_failures":0,"last_ok_at":"2026-04-17T00:00:00Z","last_failure_at":"","last_restart_at":"","cooldown_until_epoch":0,"initial_grace_until_epoch":0,"transition_grace_until_epoch":0,"transition_reason":"","last_gateway_pid":"111","last_cloudflared_pid":"111","last_reason":"","last_repair_action":""}
JSON
    watchdog_main
    cat "${stateFile}"
  `);

  const state = JSON.parse(output.trim());
  assert.equal(state.last_reason, 'launchctl_restart_failed');
  assert.equal(state.last_repair_action, 'none');
  assert.equal(state.last_restart_at, '');
  assert.equal(state.cooldown_until_epoch, 0);
  assert.equal(state.transition_grace_until_epoch, 0);
});
