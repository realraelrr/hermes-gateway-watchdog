# Hermes Gateway Watchdog

Local macOS `launchd` watchdog for a local Hermes Feishu webhook deployment. It monitors the Hermes gateway, Cloudflare Tunnel readiness, and the local Feishu webhook route; when the contract fails repeatedly, it restarts only the approved LaunchAgents and sends Feishu/Discord alerts.

[中文文档](./README.zh-CN.md)

License: MIT

## Scope

Healthy means:

- `~/.hermes/gateway_state.json` exists and is valid JSON.
- `gateway_state == "running"`.
- `platforms.feishu.state == "connected"`.
- top-level `updated_at` is fresh within `GATEWAY_STATE_MAX_AGE_SEC`.
- Hermes listens on `127.0.0.1:8765`.
- `http://127.0.0.1:20241/ready` returns `200` with `readyConnections >= 1`.
- `GET http://127.0.0.1:8765/feishu/webhook` returns `405`.

Recovery is limited to:

- `com.hermes.gateway`
- `com.cloudflare.cloudflared`

It does not manage Clash, system proxy settings, DNS, Hermes upgrades, or external Feishu loopback tests. If both gateway and cloudflared are unhealthy, the passive repair policy is staged: restart cloudflared first, then restart Hermes gateway if recovery still has not succeeded.

## Manual Restart

Run a local restart without waiting for passive probes:

```bash
bash gateway-watchdog.sh restart gateway
bash gateway-watchdog.sh restart cloudflared
bash gateway-watchdog.sh restart all
```

`all` restarts cloudflared before Hermes gateway. This is local-only; there is no chat command, webhook receiver, or remote control endpoint.

## Install

Requirements: macOS, `jq`, `curl`, `launchctl`, `lsof`, and existing user LaunchAgents for Hermes and cloudflared.

```bash
mkdir -p "${WATCHDOG_HOME:-$HOME/.hermes-watchdog}/config"
cp config.example.env "${WATCHDOG_ENV_FILE:-$HOME/.hermes-watchdog/config/watchdog.env}"
bash launchd/install-gateway-watchdog-launchagent.sh
launchctl list | rg "ai\.hermes\.gateway-watchdog"
tail -n 20 "${WATCHDOG_LOG_DIR:-$HOME/.hermes-watchdog/logs}/gateway-watchdog.log"
```

The installer stages a runnable copy under `${WATCHDOG_HOME:-$HOME/.hermes-watchdog}/runtime/current` so `launchd` does not depend on a cloud-synced repo path.

## Configuration

Precedence: `process env > watchdog env file > defaults`.

Common options:

- `WATCHDOG_DISPLAY_NAME`: alert title, useful when Hermes and OpenClaw both have watchdogs.
- `NOTIFIER`: `discord`, `feishu`, or `composite`.
- `FAIL_THRESHOLD`, `COOLDOWN_SEC`, `POST_RESTART_RETRIES`, `POST_RESTART_SLEEP_SEC`.
- `INITIAL_GRACE_SEC`, `TRANSITION_GRACE_SEC`, `LOCK_STALE_SEC`.
- `GATEWAY_STATE_MAX_AGE_SEC`.
- `GATEWAY_LABEL`, `CLOUDFLARED_LABEL`.
- `CLOUDFLARED_READY_URL`, `FEISHU_WEBHOOK_PROBE_URL`.
- `DISCORD_WATCHDOG_WEBHOOK_URL`, `FEISHU_WATCHDOG_WEBHOOK_URL`.

Path overrides include `HERMES_HOME`, `WATCHDOG_HOME`, `WATCHDOG_STATE_DIR`, `WATCHDOG_LOG_DIR`, `WATCHDOG_ENV_FILE`, and `WATCHDOG_DISABLE_FILE`.

The private env file is parsed through an allowlist and is not sourced as shell code. Webhook URLs are secrets and should live in the private env file.

## Alerts

Alerts are multi-line and user-facing. They include:

- watchdog display name and event status
- host and source (`passive watchdog` or `local CLI`)
- failing component, raw reason, and a short explanation
- gateway/cloudflared health
- chosen action and LaunchAgent label
- a final raw line for troubleshooting

Example:

```text
[Hermes Gateway Watchdog] 自动重启已触发

主机: my-mac
来源: passive watchdog
故障环节: Hermes Gateway / Feishu 连接
检测结果: gateway=bad, cloudflared=ok
原因: feishu_not_connected - Feishu 连接未就绪
动作: 重启 Hermes gateway
LaunchAgent: com.hermes.gateway
连续失败: 3
raw: event=restart_triggered host=my-mac failures=3 reason=feishu_not_connected action=restart_gateway
```

## Verify

```bash
bash -n gateway-watchdog.sh watchdog-core.sh config.sh state.sh probe.sh repair.sh \
  notifiers/discord.sh notifiers/feishu.sh notifiers/composite.sh \
  launchd/install-gateway-watchdog-launchagent.sh \
  launchd/uninstall-gateway-watchdog-launchagent.sh
node --test tests/gateway-watchdog-core.test.mjs tests/gateway-watchdog-feishu.test.mjs
```

## Limits

- `NOTIFIER=composite` sends synchronously and serially.
- Probes are local operational checks, not full Feishu end-to-end tests.
- The repo is intentionally scoped to `macOS + launchd + Hermes webhook mode`.
