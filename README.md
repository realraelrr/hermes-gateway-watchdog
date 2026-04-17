# Hermes Gateway Watchdog

Keep the local Hermes Feishu webhook deployment recoverable on macOS.

Hermes Gateway Watchdog is a standalone Bash-first `launchd` watchdog for the local Hermes gateway, Cloudflare Tunnel, and Feishu webhook route. It monitors the operational health contract, restarts only the allowed LaunchAgents, and sends Feishu or Discord alerts when recovery begins, succeeds, or fails.

[中文文档](./README.zh-CN.md)

License: MIT

## What It Monitors

The healthy contract requires all of the following:

- `~/.hermes/gateway_state.json` exists and is valid JSON.
- `gateway_state == "running"`.
- `platforms.feishu.state == "connected"`.
- Top-level `updated_at` is fresh within `GATEWAY_STATE_MAX_AGE_SEC`.
- Hermes listens on `127.0.0.1:8765`.
- `http://127.0.0.1:20241/ready` returns HTTP `200` with `readyConnections >= 1`.
- `GET http://127.0.0.1:8765/feishu/webhook` returns `405`.

This v1 does not attempt an external synthetic Feishu round-trip. It treats local webhook exposure, tunnel readiness, and Hermes Feishu state as the supported contract.

## Recovery Boundary

The watchdog may restart only:

- `com.hermes.gateway`
- `com.cloudflare.cloudflared`

It does not manage Clash, system proxy state, DNS, or Hermes upgrades.

## Prerequisites

- macOS
- `jq`
- `curl`
- `launchctl`
- `lsof`
- User-level LaunchAgents for `com.hermes.gateway` and `com.cloudflare.cloudflared`

## Quick Start

1. Create a private env file:
   - `mkdir -p "${WATCHDOG_HOME:-$HOME/.hermes-watchdog}/config"`
   - `cp config.example.env "${WATCHDOG_ENV_FILE:-$HOME/.hermes-watchdog/config/watchdog.env}"`
2. Fill in webhook values and any optional overrides in that private env file.
3. Install the LaunchAgent:
   - `bash launchd/install-gateway-watchdog-launchagent.sh`
4. Verify the agent is loaded:
   - `launchctl list | rg "ai\.hermes\.gateway-watchdog"`
5. Tail the watchdog log:
   - `tail -n 20 "${WATCHDOG_LOG_DIR:-$HOME/.hermes-watchdog/logs}/gateway-watchdog.log"`

## Configuration

Configuration precedence is fixed as `process env > watchdog env file > defaults`.

Path variables:

- `HERMES_HOME`
- `WATCHDOG_HOME`
- `WATCHDOG_STATE_DIR`
- `WATCHDOG_LOG_DIR`
- `WATCHDOG_ENV_FILE`
- `WATCHDOG_DISABLE_FILE`

Behavior variables:

- `WATCHDOG_ENABLED`
- `NOTIFIER`
- `FAIL_THRESHOLD`
- `COOLDOWN_SEC`
- `POST_RESTART_RETRIES`
- `POST_RESTART_SLEEP_SEC`
- `INITIAL_GRACE_SEC`
- `TRANSITION_GRACE_SEC`
- `LOCK_STALE_SEC`
- `GATEWAY_STATE_MAX_AGE_SEC`
- `GATEWAY_LABEL`
- `CLOUDFLARED_LABEL`
- `CLOUDFLARED_READY_URL`
- `FEISHU_WEBHOOK_PROBE_URL`
- `DISCORD_WATCHDOG_WEBHOOK_URL`
- `FEISHU_WATCHDOG_WEBHOOK_URL`

The private env file is parsed through an allowlisted `key=value` reader. It is not sourced as a shell script.

## Notifications

Supported notifiers:

- `discord`
- `feishu`
- `composite`

The notification payload includes the event type, host, failure count, primary reason, and chosen repair action.

## Verification

```bash
bash -n gateway-watchdog.sh
bash -n watchdog-core.sh
bash -n config.sh
bash -n state.sh
bash -n probe.sh
bash -n repair.sh
bash -n notifiers/discord.sh
bash -n notifiers/feishu.sh
bash -n notifiers/composite.sh
bash -n launchd/install-gateway-watchdog-launchagent.sh
bash -n launchd/uninstall-gateway-watchdog-launchagent.sh
node --test tests/gateway-watchdog-core.test.mjs tests/gateway-watchdog-feishu.test.mjs
launchctl list | rg "ai\.hermes\.gateway-watchdog"
tail -n 20 "${WATCHDOG_LOG_DIR:-$HOME/.hermes-watchdog/logs}/gateway-watchdog.log"
```

## Security Notes

1. Do not commit the private watchdog env file.
2. Webhook URLs are secrets and should live in the private env file.
3. Notifier loading is whitelist-based and restricted to the controlled `notifiers/` directory.
4. The rendered LaunchAgent stores only paths and non-secret environment variables.

## Known Limits

1. `NOTIFIER=composite` is synchronous and serial.
2. The watchdog uses local operational probes, not an end-to-end Feishu loopback.
3. The repository is intentionally scoped to `macOS + launchd + Hermes webhook mode`.
