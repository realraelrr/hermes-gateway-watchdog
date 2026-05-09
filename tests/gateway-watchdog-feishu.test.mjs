import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '..');
const launchdDir = path.join(repoRoot, 'launchd');

const core = fs.readFileSync(path.join(repoRoot, 'watchdog-core.sh'), 'utf8');
const discord = fs.readFileSync(path.join(repoRoot, 'notifiers', 'discord.sh'), 'utf8');
const feishu = fs.readFileSync(path.join(repoRoot, 'notifiers', 'feishu.sh'), 'utf8');
const composite = fs.readFileSync(path.join(repoRoot, 'notifiers', 'composite.sh'), 'utf8');
const readme = fs.readFileSync(path.join(repoRoot, 'README.md'), 'utf8');
const readmeZhCN = fs.readFileSync(path.join(repoRoot, 'README.zh-CN.md'), 'utf8');
const configExample = fs.readFileSync(path.join(repoRoot, 'config.example.env'), 'utf8');
const installLaunchAgent = fs.readFileSync(
  path.join(launchdDir, 'install-gateway-watchdog-launchagent.sh'),
  'utf8',
);
const plistTemplate = fs.readFileSync(
  path.join(launchdDir, 'ai.hermes.gateway-watchdog.plist.template'),
  'utf8',
);

function runBash(script, { env = {} } = {}) {
  return spawnSync('/bin/bash', ['-c', script], {
    encoding: 'utf8',
    env: { ...process.env, ...env },
  });
}

test('notify: core loads notifier modules through whitelist case mapping', () => {
  assert.match(core, /load_notifier\(\) \{/);
  assert.match(core, /discord\)\s+notifier_file="\$SCRIPT_DIR\/notifiers\/discord\.sh"/);
  assert.match(core, /feishu\)\s+notifier_file="\$SCRIPT_DIR\/notifiers\/feishu\.sh"/);
  assert.match(core, /composite\)\s+notifier_file="\$SCRIPT_DIR\/notifiers\/composite\.sh"/);
});

test('notify: provider modules use resolved binaries and provider-qualified temp files', () => {
  assert.match(discord, /\$\{CURL_BIN:-\$\(command -v curl\)\}/);
  assert.match(discord, /\$\{JQ_BIN:-\$\(command -v jq\)\}/);
  assert.match(discord, /notify_body_file="\$\{NOTIFY_OUTPUT_FILE\}\.\$\{provider\}\.body"/);
  assert.match(feishu, /\$\{CURL_BIN:-\$\(command -v curl\)\}/);
  assert.match(feishu, /\$\{JQ_BIN:-\$\(command -v jq\)\}/);
  assert.match(feishu, /tenant_access_token\/internal/);
  assert.match(feishu, /im\/v1\/messages\?receive_id_type=\$\{FEISHU_BOT_RECEIVE_ID_TYPE:-chat_id\}/);
  assert.match(feishu, /notify_err_file="\$\{NOTIFY_OUTPUT_FILE\}\.\$\{provider\}\.err"/);
});

test('composite: module sources both providers and aggregates success across them', () => {
  assert.match(composite, /source "\$SCRIPT_DIR\/notifiers\/discord\.sh"/);
  assert.match(composite, /source "\$SCRIPT_DIR\/notifiers\/feishu\.sh"/);
  assert.match(composite, /overall_success=1/);
  assert.match(composite, /if notify_discord "\$text"; then overall_success=0; fi/);
  assert.match(composite, /if notify_feishu "\$text"; then overall_success=0; fi/);
});

test('notify: core keeps fail-open notifier defaults and structured notification formatting', () => {
  assert.match(core, /notifier_init\(\) \{ return 0; \}/);
  assert.match(core, /notify_send\(\) \{ return 0; \}/);
  assert.match(core, /format_notification\(\) \{/);
  assert.match(core, /event=%s host=%s failures=%s reason=%s action=%s/);
});

test('docs: README and Chinese README describe Hermes scope and private env usage', () => {
  assert.match(readme, /Hermes Gateway Watchdog/);
  assert.match(readme, /local Hermes Feishu webhook deployment/);
  assert.match(readme, /WATCHDOG_HOME/);
  assert.match(readme, /Feishu bot credentials are secrets and should live in the private env file/);
  assert.match(readmeZhCN, /Hermes Gateway Watchdog/);
  assert.match(readmeZhCN, /飞书 webhook 部署/);
  assert.match(readmeZhCN, /\[English README\]\(\.\/README\.md\)/);
});

test('docs: config example uses Hermes-specific homes and labels', () => {
  assert.match(configExample, /HERMES_HOME=/);
  assert.match(configExample, /WATCHDOG_HOME=/);
  assert.match(configExample, /GATEWAY_LABEL=com\.hermes\.gateway/);
  assert.match(configExample, /CLOUDFLARED_LABEL=com\.cloudflare\.cloudflared/);
  assert.doesNotMatch(configExample, /OPENCLAW_HOME/);
});

test('launchd: plist template uses Hermes label and required placeholders', () => {
  assert.match(plistTemplate, /ai\.hermes\.gateway-watchdog/);
  assert.match(plistTemplate, /__WATCHDOG_SCRIPT_PATH__/);
  assert.match(plistTemplate, /__WATCHDOG_WORKING_DIR__/);
  assert.match(plistTemplate, /__WATCHDOG_ENV_FILE__/);
  assert.match(plistTemplate, /__HERMES_HOME__/);
  assert.match(plistTemplate, /__WATCHDOG_HOME__/);
  assert.doesNotMatch(plistTemplate, /openclaw/);
});

test('launchd: install script derives Hermes paths from repo root and default homes', () => {
  assert.match(installLaunchAgent, /REPO_ROOT="\$\(cd "\$SCRIPT_DIR\/\.\." && pwd\)"/);
  assert.match(installLaunchAgent, /HERMES_HOME="\$\{HERMES_HOME:-\$HOME\/\.hermes\}"/);
  assert.match(installLaunchAgent, /WATCHDOG_HOME="\$\{WATCHDOG_HOME:-\$HERMES_HOME\/watchdog\}"/);
  assert.match(installLaunchAgent, /WATCHDOG_RUNTIME_DIR="\$\{WATCHDOG_RUNTIME_DIR:-\$WATCHDOG_HOME\/runtime\/current\}"/);
  assert.match(installLaunchAgent, /WATCHDOG_ENV_FILE="\$\{WATCHDOG_ENV_FILE:-\$WATCHDOG_HOME\/config\/watchdog\.env\}"/);
  assert.match(installLaunchAgent, /ai\.hermes\.gateway-watchdog/);
});

test('launchd: install script stages a local runtime copy, renders plist, and invokes launchctl bootstrap flow', () => {
  const tempHome = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-launchd-home-'));
  const fakeBinDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-launchd-bin-'));
  const callsFile = path.join(tempHome, 'launchctl.calls');
  const expectedHermesHome = path.join(tempHome, '.hermes');
  const expectedWatchdogHome = path.join(expectedHermesHome, 'watchdog');
  const expectedEnvFile = path.join(expectedWatchdogHome, 'config', 'watchdog.env');
  const expectedLogFile = path.join(expectedWatchdogHome, 'logs', 'gateway-watchdog.log');
  const expectedRuntimeDir = path.join(expectedWatchdogHome, 'runtime', 'current');
  const targetFile = path.join(tempHome, 'Library', 'LaunchAgents', 'ai.hermes.gateway-watchdog.plist');

  fs.writeFileSync(
    path.join(fakeBinDir, 'launchctl'),
    `#!/usr/bin/env bash
printf '%s\\n' "$*" >> "${callsFile}"
exit 0
`,
    { mode: 0o755 },
  );

  const result = runBash(
    `"${path.join(launchdDir, 'install-gateway-watchdog-launchagent.sh')}"`,
    {
      env: {
        HOME: tempHome,
        PATH: `${fakeBinDir}:${process.env.PATH}`,
      },
    },
  );

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Installed:/);
  assert.equal(fs.existsSync(targetFile), true);
  assert.equal(fs.existsSync(path.join(expectedWatchdogHome, 'logs')), true);
  assert.equal(fs.existsSync(path.join(expectedRuntimeDir, 'gateway-watchdog.sh')), true);
  assert.equal(fs.existsSync(path.join(expectedRuntimeDir, 'watchdog-core.sh')), true);
  assert.equal(fs.existsSync(path.join(expectedRuntimeDir, 'notifiers', 'discord.sh')), true);
  const renderedPlist = fs.readFileSync(targetFile, 'utf8');
  assert.match(renderedPlist, new RegExp(expectedEnvFile.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  assert.match(renderedPlist, new RegExp(expectedLogFile.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  assert.match(renderedPlist, new RegExp(expectedHermesHome.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  assert.match(renderedPlist, new RegExp(path.join(expectedRuntimeDir, 'gateway-watchdog.sh').replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  const calls = fs.readFileSync(callsFile, 'utf8');
  assert.match(calls, /bootout gui\/\d+\/ai\.hermes\.gateway-watchdog/);
  assert.match(calls, /bootstrap gui\/\d+ .*ai\.hermes\.gateway-watchdog\.plist/);
  assert.match(calls, /kickstart -k gui\/\d+\/ai\.hermes\.gateway-watchdog/);
});

test('notify: discord notifier succeeds against mocked webhook transport', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-discord-notify-'));
  const fakeBinDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-discord-bin-'));
  const notifyBase = path.join(tempDir, 'notify');
  const logFile = path.join(tempDir, 'watchdog.log');

  fs.writeFileSync(
    path.join(fakeBinDir, 'curl'),
    `#!/usr/bin/env bash
out_file=""
while (($#)); do
  if [[ "$1" == "-o" ]]; then
    out_file="$2"
    shift 2
    continue
  fi
  shift
done
printf 'curl ok\\n' > "$out_file"
printf '204'
`,
    { mode: 0o755 },
  );

  const result = runBash(
    `
      source "${path.join(repoRoot, 'notifiers', 'discord.sh')}"
      LOG_FILE="${logFile}"
      NOTIFY_OUTPUT_FILE="${notifyBase}"
      DISCORD_WEBHOOK_URL="https://example.invalid/discord"
      log() { printf '%s %s %s %s\\n' "$1" "$2" "$3" "$4" >> "$LOG_FILE"; }
      if notify_send "hello discord"; then
        printf 'status=0\\n'
      else
        printf 'status=%s\\n' "$?"
      fi
    `,
    {
      env: {
        PATH: `${fakeBinDir}:${process.env.PATH}`,
      },
    },
  );

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /status=0/);
  const log = fs.readFileSync(logFile, 'utf8');
  assert.match(log, /INFO notify_ok provider=discord status=204/);
});

test('notify: feishu notifier sends text through bot API with tenant token', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-feishu-bot-notify-'));
  const fakeBinDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-feishu-bot-bin-'));
  const notifyBase = path.join(tempDir, 'notify');
  const logFile = path.join(tempDir, 'watchdog.log');
  const requestLog = path.join(tempDir, 'requests.log');

  fs.writeFileSync(
    path.join(fakeBinDir, 'curl'),
    `#!/usr/bin/env bash
out_file=""
data=""
auth=""
while (($#)); do
  if [[ "$1" == "-o" ]]; then
    out_file="$2"
    shift 2
    continue
  fi
  if [[ "$1" == "-d" ]]; then
    data="$2"
    shift 2
    continue
  fi
  if [[ "$1" == "-H" && "$2" == Authorization:* ]]; then
    auth="$2"
    shift 2
    continue
  fi
  url="$1"
  shift
done
printf 'url=%s auth=%s data=%s\\n' "$url" "$auth" "$data" >> "${requestLog}"
case "$url" in
  */auth/v3/tenant_access_token/internal)
    printf '{"code":0,"tenant_access_token":"tenant-token"}\\n' > "$out_file"
    printf '200'
    ;;
  */im/v1/messages?receive_id_type=chat_id)
    printf '{"code":0,"data":{"message_id":"om_test"}}\\n' > "$out_file"
    printf '200'
    ;;
  *)
    printf '{"code":999,"msg":"unexpected url"}\\n' > "$out_file"
    printf '404'
    ;;
esac
`,
    { mode: 0o755 },
  );

  const result = runBash(
    `
      source "${path.join(repoRoot, 'notifiers', 'feishu.sh')}"
      LOG_FILE="${logFile}"
      NOTIFY_OUTPUT_FILE="${notifyBase}"
      FEISHU_BOT_APP_ID="cli_test"
      FEISHU_BOT_APP_SECRET="secret_test"
      FEISHU_BOT_CHAT_ID="oc_ops"
      log() { printf '%s %s %s %s\\n' "$1" "$2" "$3" "$4" >> "$LOG_FILE"; }
      if notify_send "hello feishu"; then
        printf 'status=0\\n'
      else
        printf 'status=%s\\n' "$?"
      fi
    `,
    {
      env: {
        PATH: `${fakeBinDir}:${process.env.PATH}`,
      },
    },
  );

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /status=0/);
  const log = fs.readFileSync(logFile, 'utf8');
  assert.match(log, /INFO notify_ok provider=feishu mode=bot status=200/);
  const requests = fs.readFileSync(requestLog, 'utf8');
  assert.match(requests, /auth\/v3\/tenant_access_token\/internal/);
  assert.match(requests, /im\/v1\/messages\?receive_id_type=chat_id auth=Authorization: Bearer tenant-token/);
  assert.match(requests, /"receive_id":"oc_ops"/);
  assert.match(requests, /"content":"\{\\"text\\":\\"hello feishu\\"\}"/);
});
