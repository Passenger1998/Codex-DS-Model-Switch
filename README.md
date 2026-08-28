# Codex & Claude Code 模型切换器

一个可双击运行的 macOS GUI，用同一个两级选择器管理 Codex 与 Claude Code：

- 工具：Codex / Claude Code
- Codex：ChatGPT / DeepSeek V4 Pro
- Claude Code：Claude 官方 / DeepSeek V4 Pro / DeepSeek V4 Flash

当前版本：**2.1.0（build 12）**，最低系统 macOS 13。

## Claude Desktop 的真实配置来源

Claude Desktop 的 3P 状态不以 `~/.claude/settings.json` 或旧的
`developer_settings.json` 为准。当前 Desktop 构建由以下文件持久化 GUI 中
Developer → Configure Third-Party Inference 的结果：

```text
~/Library/Application Support/Claude-3p/
├── claude_desktop_config.json       # deploymentMode: 1p / 3p
└── configLibrary/
    ├── _meta.json                   # appliedId + 配置条目
    └── <appliedId>.json             # 活动 3P Provider/模型配置
```

活动配置使用 Desktop 自身的扁平字段：

```json
{
  "inferenceProvider": "gateway",
  "inferenceGatewayBaseUrl": "https://api.deepseek.com/anthropic",
  "inferenceCredentialKind": "helper-script",
  "inferenceCredentialHelper": "/Users/当前用户/.claude/deepseek-keychain-helper",
  "inferenceGatewayAuthScheme": "bearer",
  "modelDiscoveryEnabled": false,
  "inferenceModels": []
}
```

模型列表首项是 Desktop 的默认模型：

- Pro：`claude-opus-5` / `anthropicFamilyTier: opus` 位于首项；
- Flash：`claude-sonnet-5` / `anthropicFamilyTier: sonnet` 位于首项。

Desktop 运行时生成的 `host-creds-*.json` 可能包含临时认证环境。切换器不读取、
不备份、不打印、也不修改这类文件。

## Desktop 与直接 CLI 是两层配置

```text
Claude Desktop 内置 Claude Code
  └─ Claude-3p deploymentMode + configLibrary 活动配置

直接运行的 claude CLI
  └─ ~/.claude/settings.json 的 env + apiKeyHelper
```

切换器同时修改并核对两层；只有两层状态相同才显示切换成功。仅仅把
`~/.claude/settings.json` 写成 DeepSeek 不会被报告为 Desktop 已切换。

DeepSeek 模式下，直接 CLI 使用：

```text
ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
ANTHROPIC_MODEL=claude-opus-5 或 claude-sonnet-5
ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-5
ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5
```

切换时还会读取当前 macOS `scutil --proxy` 的已启用 HTTP/HTTPS 代理，写入
`HTTP_PROXY` / `HTTPS_PROXY`。切回官方时恢复原值。

## 凭据隔离

Claude 使用独立 Keychain service：

```text
service: claude-code-deepseek-api-key
account: deepseek
```

Codex 继续使用 `codex-deepseek-api-key`，两者互不影响。Claude 配置中只保存
Helper 路径：

```text
~/.claude/deepseek-keychain-helper
```

API Key 不写入 JSON、源码或日志。Provider 的状态检查只查询 Keychain 条目是否
存在，不请求 `-w`，因此不会把 Key 读进切换器进程。真正请求模型时由 Claude
执行 Helper 并读取 Keychain。

首次保存 Claude Key（切换器不会代用户执行）：

```bash
security add-generic-password \
  -s claude-code-deepseek-api-key \
  -a deepseek \
  -w '你的 DeepSeek API Key'
```

## 安全切换事务

每次写配置均执行：

1. 获取 `~/.claude/.claude-provider.lock` 排他锁；
2. 首次从官方切到 DeepSeek 前，对所有将修改的文件做逐字节官方快照；
3. 为本次事务创建时间戳备份；
4. 写同目录临时文件，`fsync` 文件，原子替换，再 `fsync` 目录；
5. 从 Desktop 部署域、活动配置库和直接 CLI 配置重新推导状态；
6. 任一步失败时按原字节原子回滚。

官方快照位于：

```text
~/.claude/official-config-snapshots/<timestamp>/
~/.claude/claude-official-snapshot.v2.json
```

快照只包含切换器会修改的四个文件，不包含 Cookies、会话数据、
`host-creds-*.json` 或 Keychain 内容。切回官方时只恢复切换器管理的字段；
DeepSeek 使用期间新改动的 permissions、hooks、MCP、plugins、projects 和活动
配置中的其它字段会保留。

## GUI 与 CLI

GUI 切换成功后自动退出并重新打开对应 App：

- Codex 切换：只重启 Codex；
- Claude Code 切换：只重启 Claude Desktop。

CLI 只修改并校验配置，不自动重启 App：

```bash
"Codex 模型切换器.app/Contents/MacOS/CodexModelSwitcher" status

"Codex 模型切换器.app/Contents/MacOS/CodexModelSwitcher" codex chatgpt
"Codex 模型切换器.app/Contents/MacOS/CodexModelSwitcher" codex deepseek

"Codex 模型切换器.app/Contents/MacOS/CodexModelSwitcher" claude default
"Codex 模型切换器.app/Contents/MacOS/CodexModelSwitcher" claude deepseek-pro
"Codex 模型切换器.app/Contents/MacOS/CodexModelSwitcher" claude deepseek-flash
```

兼容旧命令 `chatgpt` / `deepseek` 保持不变，它们仍分别等价于
`codex chatgpt` / `codex deepseek`。

## 安装、构建与验证

```bash
./install.sh
./build.sh
./verify.sh
```

`install.sh` 会在目标不存在时把 Claude Helper 安装到
`~/.claude/deepseek-keychain-helper`（已有 Helper 保持不变），并把 Provider 管理命令安装到
`~/.codex/bin/claude-provider`。该路径只用于放置切换命令，不会复用 Codex 的
DeepSeek Keychain service。

`verify.sh` 的 Claude 测试全部在临时目录中运行，Keychain 与 App 检测被替身
替换，不发送真实模型请求。测试覆盖：

- Claude 官方 → DeepSeek V4 Pro → DeepSeek V4 Flash → Claude 官方；
- `deploymentMode`、活动 config ID、首模型/default tier；
- bearer、Helper script、关闭 Model discovery；
- 系统代理写入与原值恢复；
- 完整官方快照、无关字段保留、幂等、写后校验与失败回滚；
- `settings.json` 单层配置不能冒充 Desktop 成功；
- Claude/Codex Keychain service 隔离；
- 不持久化 API Key 或 `ANTHROPIC_AUTH_TOKEN`。

本地自动化测试不会证明真实上游路由。真实端到端验证必须结合 Claude-3p 日志、
到 `api.deepseek.com` 的网络目的地以及 DeepSeek 后台计费/用量；不能只看 UI 模型
名称或模型自报身份。

## 项目结构

```text
Sources/CodexModelSwitcher/       Swift GUI、状态解析、App 重启
Support/codex-provider            现有 Codex 切换逻辑（保持兼容）
Support/claude-provider           Claude Desktop/CLI 事务切换器
Support/claude-gateway-cred-helper.sh
Tests/ClaudeProviderTests.py      Claude 临时目录零成本测试
Tests/ConfigEditorTests.swift     Swift/Codex 兼容测试
Tests/ProxyTests.py               Codex 本地模拟上游测试
```
