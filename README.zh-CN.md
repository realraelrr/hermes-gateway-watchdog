# Hermes Gateway Watchdog

让本机的 Hermes 飞书 webhook 部署在 macOS 上可恢复，而不是“进程还在但链路已经死了”。

Hermes Gateway Watchdog 是一个独立的 Bash-first `launchd` watchdog，用来监控本机 Hermes gateway、Cloudflare Tunnel 和飞书 webhook 路由的运行合同。在探测失败后，它只会重启允许的 LaunchAgent，并通过飞书或 Discord 发出告警。

[English README](./README.md)

许可证：MIT

## 它监控什么

健康合同要求同时满足：

- `~/.hermes/gateway_state.json` 存在且是合法 JSON。
- `gateway_state == "running"`。
- `platforms.feishu.state == "connected"`。
- 顶层 `updated_at` 在 `GATEWAY_STATE_MAX_AGE_SEC` 内足够新。
- Hermes 正在监听 `127.0.0.1:8765`。
- `http://127.0.0.1:20241/ready` 返回 HTTP `200` 且 `readyConnections >= 1`。
- `GET http://127.0.0.1:8765/feishu/webhook` 返回 `405`。

v1 不做真正的外部飞书回环探测。它把本地 webhook 暴露、tunnel readiness 和 Hermes 的飞书连接状态当作受支持的运行合同。

## 恢复边界

watchdog 只允许重启：

- `com.hermes.gateway`
- `com.cloudflare.cloudflared`

它不会管理 Clash、系统代理、DNS 或 Hermes 升级。

## 前置依赖

- macOS
- `jq`
- `curl`
- `launchctl`
- `lsof`
- 已存在的用户级 LaunchAgent：`com.hermes.gateway` 与 `com.cloudflare.cloudflared`

## 快速开始

1. 创建私有 env 文件：
   - `mkdir -p "${WATCHDOG_HOME:-$HOME/.hermes-watchdog}/config"`
   - `cp config.example.env "${WATCHDOG_ENV_FILE:-$HOME/.hermes-watchdog/config/watchdog.env}"`
2. 在私有 env 文件里填入 webhook 和可选覆盖项。
3. 安装 LaunchAgent：
   - `bash launchd/install-gateway-watchdog-launchagent.sh`
   - 安装器会把可运行副本部署到 `${WATCHDOG_HOME:-$HOME/.hermes-watchdog}/runtime/current`，避免 `launchd` 依赖云盘同步目录里的 repo 路径。
4. 确认 agent 已加载：
   - `launchctl list | rg "ai\.hermes\.gateway-watchdog"`
5. 查看 watchdog 日志：
   - `tail -n 20 "${WATCHDOG_LOG_DIR:-$HOME/.hermes-watchdog/logs}/gateway-watchdog.log"`

## 配置

配置优先级固定为：`process env > watchdog env file > defaults`

路径变量：

- `HERMES_HOME`
- `WATCHDOG_HOME`
- `WATCHDOG_STATE_DIR`
- `WATCHDOG_LOG_DIR`
- `WATCHDOG_ENV_FILE`
- `WATCHDOG_DISABLE_FILE`

行为变量：

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

私有 env 文件通过 allowlist 的 `key=value` 解析器读取，不会被直接 `source`。

## 通知

支持的 notifier：

- `discord`
- `feishu`
- `composite`

通知内容会包含事件类型、主机名、失败次数、主故障原因和本次修复动作。

## 验证命令

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

## 安全说明

1. 不要提交私有 watchdog env 文件。
2. Webhook URL 属于 secret，应放在私有 env 文件中。
3. notifier 采用白名单加载，只允许受控的 `notifiers/` 目录。
4. 渲染后的 LaunchAgent 只写入路径和非 secret 环境变量。

## 已知限制

1. `NOTIFIER=composite` 仍然是同步串行发送。
2. watchdog 使用的是本地运行合同探测，不是完整的飞书端到端回环。
3. 仓库刻意只支持 `macOS + launchd + Hermes webhook mode`。
