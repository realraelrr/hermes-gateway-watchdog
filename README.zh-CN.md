# Hermes Gateway Watchdog

本地 `launchd` watchdog，用于让 macOS 上的 Hermes 飞书 webhook 部署可恢复。它监控 Hermes gateway、Cloudflare Tunnel readiness 和本地飞书 webhook 路由；当运行合同连续失败时，只重启允许的 LaunchAgent，并通过飞书/Discord 告警。

[English README](./README.md)

许可证：MIT

## 范围

健康合同要求：

- `~/.hermes/gateway_state.json` 存在且是合法 JSON。
- `gateway_state == "running"`。
- `platforms.feishu.state == "connected"`。
- 顶层 `updated_at` 在 `GATEWAY_STATE_MAX_AGE_SEC` 内足够新。
- Hermes 正在监听 `127.0.0.1:8765`。
- `http://127.0.0.1:20241/ready` 返回 `200`，且 `readyConnections >= 1`。
- `GET http://127.0.0.1:8765/feishu/webhook` 返回 `405`。

恢复边界只包括：

- `com.hermes.gateway`
- `com.cloudflare.cloudflared`

它不管理 Clash、系统代理、DNS、Hermes 升级，也不做外部飞书端到端回环探测。当 gateway 和 cloudflared 同时不健康时，被动修复策略是分阶段执行：先重启 cloudflared；如果仍未恢复，再重启 Hermes gateway。

## 本地主动重启

不等待被动探测，直接本地触发重启：

```bash
bash gateway-watchdog.sh restart gateway
bash gateway-watchdog.sh restart cloudflared
bash gateway-watchdog.sh restart all
```

`all` 会先重启 cloudflared，再重启 Hermes gateway。这个能力只在本地生效；没有聊天命令、webhook receiver 或远程控制端点。

## 安装

依赖：macOS、`jq`、`curl`、`launchctl`、`lsof`，以及已存在的 Hermes/cloudflared 用户级 LaunchAgent。

```bash
mkdir -p "${WATCHDOG_HOME:-$HOME/.hermes/watchdog}/config"
cp config.example.env "${WATCHDOG_ENV_FILE:-$HOME/.hermes/watchdog/config/watchdog.env}"
bash launchd/install-gateway-watchdog-launchagent.sh
launchctl list | rg "ai\.hermes\.gateway-watchdog"
tail -n 20 "${WATCHDOG_LOG_DIR:-$HOME/.hermes/watchdog/logs}/gateway-watchdog.log"
```

安装脚本会把可运行副本部署到 `${WATCHDOG_HOME:-$HOME/.hermes/watchdog}/runtime/current`，避免 `launchd` 依赖云盘同步目录里的 repo 路径。

## 配置

优先级：`process env > watchdog env file > defaults`。

常用选项：

- `WATCHDOG_DISPLAY_NAME`：告警标题；Hermes 和 OpenClaw 都有 watchdog 时尤其有用。
- `NOTIFIER`：`discord`、`feishu` 或 `composite`。
- `FAIL_THRESHOLD`、`MAX_RESTART_FAILURES`、`COOLDOWN_SEC`、`POST_RESTART_RETRIES`、`POST_RESTART_SLEEP_SEC`。
- `INITIAL_GRACE_SEC`、`TRANSITION_GRACE_SEC`、`LOCK_STALE_SEC`。
- `GATEWAY_STATE_MAX_AGE_SEC`。
- `GATEWAY_LABEL`、`CLOUDFLARED_LABEL`。
- `CLOUDFLARED_READY_URL`、`FEISHU_WEBHOOK_PROBE_URL`。
- `DISCORD_WATCHDOG_WEBHOOK_URL`。
- `FEISHU_BOT_APP_ID`、`FEISHU_BOT_APP_SECRET`、`FEISHU_BOT_CHAT_ID`。

路径覆盖项包括 `HERMES_HOME`、`WATCHDOG_HOME`、`WATCHDOG_STATE_DIR`、`WATCHDOG_LOG_DIR`、`WATCHDOG_ENV_FILE` 和 `WATCHDOG_DISABLE_FILE`。

私有 env 文件通过 allowlist 解析，不会被当作 shell 脚本 source。飞书 bot 凭据属于 secret，不要提交到 git。

## 告警

告警是多行、面向用户的文本，包含：

- watchdog 显示名和事件状态
- 主机和来源（`passive watchdog` 或 `local CLI`）
- 故障环节、raw reason 和简短解释
- gateway/cloudflared 健康状态
- 本次动作和 LaunchAgent label
- 最后一行 raw 字段，便于排查

示例：

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

## 验证

```bash
bash -n gateway-watchdog.sh watchdog-core.sh config.sh state.sh probe.sh repair.sh \
  notifiers/discord.sh notifiers/feishu.sh notifiers/composite.sh \
  launchd/install-gateway-watchdog-launchagent.sh \
  launchd/uninstall-gateway-watchdog-launchagent.sh
node --test tests/gateway-watchdog-core.test.mjs tests/gateway-watchdog-feishu.test.mjs
```

## 限制

- `NOTIFIER=composite` 是同步串行发送。
- 探测是本地运行合同检查，不是完整的飞书端到端测试。
- 仓库刻意只支持 `macOS + launchd + Hermes webhook mode`。
