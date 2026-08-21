# Codex 模型切换器 / Codex Model Switcher

一个可双击运行的 macOS 小工具，用于在 **ChatGPT**、**DeepSeek V4 Pro · High** 与 **DeepSeek V4 Pro · Max** 三种实际状态之间安全切换。配置切换成功并通过健康检查后会自动退出并重新打开 Codex。

A double-clickable macOS utility that safely switches Codex between three real states: **ChatGPT**, **DeepSeek V4 Pro · High**, and **DeepSeek V4 Pro · Max**. After a successful switch and health check it automatically quits and reopens Codex.

- 版本 / Version：**1.5.0（build 8）**
- 最低系统 / Minimum OS：**macOS 13.0**
- 兼容桥 / Compatibility bridge：`Support/deepseek_responses_proxy.py` **v1.1.4**

---

## 中文

### 已包含的完整链路

Codex 自定义 Provider 只接受 OpenAI Responses API，而 DeepSeek V4 提供 Chat Completions API。本项目内置一个仅监听 `127.0.0.1` 的本地兼容桥：

```text
Codex ── Responses API ──> 本地兼容桥 ── Chat Completions ──> DeepSeek
```

兼容桥支持：

- Responses 文本流式与非流式响应
- Function / Custom Tool 调用与工具结果回传
- DeepSeek 思考模式的 `reasoning_content` 安全回放（不展示给客户端）
- 最多 128 个工具的相关性筛选及超长工具名映射
- SSE keep-alive、错误转换和 token usage 转换
- 启动时读取 macOS HTTP/HTTPS 系统代理，DeepSeek 上游显式走当前代理，本地回环通信始终直连
- DNS/连接、流式空闲和非流式生成使用互相独立的超时
- macOS LaunchAgent 自动启动和崩溃恢复（KeepAlive）
- 请求时从 macOS Keychain 动态读取 DeepSeek API Key，不落盘、不写日志
- 固定本地 bearer token，真实 API Key 不写入 Codex 配置、不经环境变量传播

### 安装或修复

首次使用、升级或复检后运行：

```bash
./install.sh
```

安装器会：

1. 运行测试并重新构建 `Codex 模型切换器.app`。
2. 安装本地兼容桥到 `~/.codex/deepseek-proxy/`。
3. 安装安全切换命令到 `~/.codex/bin/codex-provider`。
4. 写入专用模型目录 `~/.codex/deepseek.models.json`（内含 `deepseek-v4-pro` 与 `deepseek-v4-flash` 两个条目）。
5. 只更新 `config.toml` 的 `[model_providers.deepseek]` 相关表：

```toml
[model_providers.deepseek]
name = "DeepSeek via local Responses proxy"
base_url = "http://127.0.0.1:4878/v1"
wire_api = "responses"
supports_websockets = false
request_max_retries = 4
stream_max_retries = 8
stream_idle_timeout_ms = 600000

[model_providers.deepseek.auth]
command = "/usr/bin/printf"
args = ["codex-deepseek-local"]
refresh_interval_ms = 0
timeout_ms = 5000
```

6. 安装并启动 `~/Library/LaunchAgents/local.codex-deepseek-proxy.plist`。

安装器不会读取或写出 API Key。请先确保钥匙串中存在服务名 `codex-deepseek-api-key` 的条目，例如：

```bash
security add-generic-password -s codex-deepseek-api-key -a deepseek -w sk-你的-key
```

### 使用

1. 双击 `Codex 模型切换器.app`（或命令行执行 `Codex 模型切换器.app/Contents/MacOS/CodexModelSwitcher {chatgpt|deepseek-high|deepseek-max|deepseek|status}`）。
2. 选择 `ChatGPT`、`DeepSeek V4 Pro · High` 或 `DeepSeek V4 Pro · Max`。
3. 界面显示的当前状态来自 Codex 配置、LaunchAgent plist 与 proxy 实际运行参数，不使用“上次点击”记录；状态不一致时会明确提示。
4. DeepSeek 模式会同步更新 Codex reasoning effort 和 proxy 启动参数，重载 proxy，并检查本地状态与 `/upstream-health` 后再提交配置。
5. 配置切换成功后，切换器会正常退出 Codex，等待退出后重新打开它。
6. 如果 Codex 未响应正常退出请求，切换器会在等待 8 秒后强制退出；正在执行的任务会被中断。

如果 DeepSeek 模式预检失败，配置不会切换；切换中途失败会自动回滚。

### 配置修改规则

DeepSeek 模式只激活以下顶层字段：

```toml
model = "deepseek-v4-pro"
model_provider = "deepseek"
model_reasoning_effort = "high" # Max 档使用 Codex 支持的 "xhigh"
model_catalog_json = "/Users/你的用户名/.codex/deepseek.models.json"
```

- DeepSeek 模式不携带 ChatGPT/OpenAI 的 `service_tier`。
- High 和 Max 都保持 `thinking = enabled`。High 使用 Codex `high` → DeepSeek `high`；Max 使用 Codex `xhigh` → 兼容桥明确翻译为 DeepSeek 上游 `max`。这是因为当前 Codex 配置枚举不接受 `max`，状态输出会同时显示传输档和上游有效档。
- 已存在的 DeepSeek High 任务会保留任务级 `high`。当全局切到 Max 后重新打开这类任务，Max proxy 会把该旧任务的 `high` 明确翻译为上游 `max`，并在 `/health` 的 `last_request_reasoning_effort_translation` 中显示 `high->max`。反方向不允许：High proxy 收到 `xhigh` 仍会失败，避免静默降档。
- 每次切换到 Max 时，切换器还会要求 proxy 健康端点声明 `accepted_codex_reasoning_efforts=["high","xhigh"]`；不满足时切换失败并回滚，不会显示成功。
- ChatGPT 模式恢复 `~/.codex/chatgpt.activation.toml` 保存的 OpenAI 偏好。
- Provider、Keychain、LaunchAgent 和专用 model catalog 永久保留。
- plugins、MCP、projects、desktop、权限及其他配置保持不变。
- 每次切换前的备份保存在 `~/.codex/provider-switch-backups/`。

### 检查与验证

查看当前状态：

```bash
"Codex 模型切换器.app/Contents/MacOS/CodexModelSwitcher" status
```

完整本地验证（使用模拟上游，不会请求真实模型）：

```bash
./verify.sh
```

单独检查兼容桥：

```bash
curl --noproxy '*' http://127.0.0.1:4878/health
tail -n 50 ~/.codex/log/deepseek-proxy.err.log
```

需要验证网络、钥匙串凭据和模型授权（不调用推理）时：

```bash
curl --noproxy '*' -H 'Authorization: Bearer codex-deepseek-local' http://127.0.0.1:4878/upstream-health
```

### 重新构建

```bash
./build.sh
```

构建脚本生成当前 Mac 架构、最低 macOS 13.0 的本地临时签名应用。它先在临时目录编译、运行测试和签名，成功后再替换旧 App。

### 安全边界

- 兼容桥拒绝绑定非回环地址。
- DeepSeek API Key 只在请求时从 Keychain 读取，不落盘、不写日志。
- Codex 到本地桥使用独立固定 token，不传输真实 DeepSeek Key。
- 安装和验证默认不发送真实模型推理请求。

### 测试

- `Tests/ConfigEditorTests.swift`：Swift 配置编辑单元测试，`build.sh` 构建时自动运行。
- `Tests/ProxyTests.py`：兼容桥集成测试，使用模拟 DeepSeek 上游、只走本地回环，不产生真实推理；由 `verify.sh` 运行，也可直接执行 `python3 Tests/ProxyTests.py`。

### 项目结构

```text
.
├── build.sh                       # 构建 + 单元测试 + ad-hoc 签名
├── install.sh                     # 一键安装 / 修复
├── verify.sh                      # 本地端到端验证
├── Sources/CodexModelSwitcher/
│   ├── main.swift                 # GUI 与命令行入口
│   ├── ConfigEditor.swift         # config.toml 最小化安全编辑
│   ├── CodexAppRestarter.swift    # 退出并重新打开 Codex
│   └── Info.plist                 # v1.5.0 / macOS 13.0+
├── Support/
│   ├── deepseek_responses_proxy.py  # Responses → Chat Completions 兼容桥
│   ├── codex-provider               # 安全切换命令
│   ├── install_config.py            # config.toml / LaunchAgent 写入
│   └── deepseek.models.json         # 专用模型目录
└── Tests/
    ├── ConfigEditorTests.swift
    └── ProxyTests.py
```

### 仓库说明

- 本仓库不含任何 API Key：`DeepSeek API Key.txt` 已被 `.gitignore` 排除，Key 只存放在 macOS Keychain。
- 构建产物 `Codex 模型切换器.app/` 与本地开发备份 `Backups/` 不入库，可用 `./install.sh` 或 `./build.sh` 随时重新生成。
- 可通过 `CODEX_SWITCHER_CODEX_HOME`、`CODEX_SWITCHER_LAUNCH_AGENTS_DIR`、`CODEX_SWITCHER_CODEX_BIN`、`CODEX_SWITCHER_PROXY_PLIST` 等环境变量覆盖安装路径，便于非标准环境部署。

---

## English

### Full pipeline

Codex custom providers only accept the OpenAI Responses API, while DeepSeek V4 exposes a Chat Completions API. This project ships a local compatibility bridge that listens on `127.0.0.1` only:

```text
Codex ── Responses API ──> local bridge ── Chat Completions ──> DeepSeek
```

The bridge supports:

- Streaming and non-streaming Responses text output
- Function / custom tool calls with tool-result round trips
- Safe replay of DeepSeek thinking-mode `reasoning_content` (hidden from the client)
- Relevance filtering for up to 128 tools and long tool-name mapping
- SSE keep-alive, error translation, and token usage conversion
- Reading the macOS HTTP/HTTPS system proxy at startup; the DeepSeek upstream always uses the current proxy while loopback traffic stays direct
- Independent timeouts for DNS/connect, stream idle, and non-streaming generation
- Automatic start and crash recovery via a macOS LaunchAgent (KeepAlive)
- DeepSeek API Key read from the macOS Keychain at request time only — never written to disk or logs
- A fixed local bearer token; the real API Key is never written into Codex config or passed through environment variables

### Install or repair

Run after first-time setup, upgrades, or rechecks:

```bash
./install.sh
```

The installer:

1. Runs the tests and rebuilds `Codex 模型切换器.app`.
2. Installs the bridge into `~/.codex/deepseek-proxy/`.
3. Installs the safe switch command into `~/.codex/bin/codex-provider`.
4. Writes the dedicated model catalog `~/.codex/deepseek.models.json` (contains `deepseek-v4-pro` and `deepseek-v4-flash`).
5. Updates only the `[model_providers.deepseek]` tables in `config.toml`:

```toml
[model_providers.deepseek]
name = "DeepSeek via local Responses proxy"
base_url = "http://127.0.0.1:4878/v1"
wire_api = "responses"
supports_websockets = false
request_max_retries = 4
stream_max_retries = 8
stream_idle_timeout_ms = 600000

[model_providers.deepseek.auth]
command = "/usr/bin/printf"
args = ["codex-deepseek-local"]
refresh_interval_ms = 0
timeout_ms = 5000
```

6. Installs and starts `~/Library/LaunchAgents/local.codex-deepseek-proxy.plist`.

The installer never reads or writes the API Key. Make sure a Keychain item with service name `codex-deepseek-api-key` exists first, for example:

```bash
security add-generic-password -s codex-deepseek-api-key -a deepseek -w sk-your-key
```

### Usage

1. Double-click `Codex 模型切换器.app` (or run `Codex 模型切换器.app/Contents/MacOS/CodexModelSwitcher {chatgpt|deepseek-high|deepseek-max|deepseek|status}` from the command line).
2. Choose `ChatGPT`, `DeepSeek V4 Pro · High`, or `DeepSeek V4 Pro · Max`.
3. The current state shown in the UI is derived from the Codex configuration, the LaunchAgent plist, and the proxy's actual runtime parameters — not from the last click. Inconsistent states are flagged explicitly.
4. DeepSeek mode updates the Codex reasoning effort and proxy startup arguments together, reloads the proxy, and checks the local `/health` and `/upstream-health` endpoints before committing the configuration.
5. After a successful switch, the switcher quits Codex gracefully, waits for it to exit, and reopens it.
6. If Codex does not respond to a graceful quit, the switcher force-quits it after 8 seconds; running tasks will be interrupted.

If the DeepSeek preflight fails, the configuration is not switched. If a switch fails midway, it is rolled back automatically.

### Configuration rules

DeepSeek mode only activates these top-level fields:

```toml
model = "deepseek-v4-pro"
model_provider = "deepseek"
model_reasoning_effort = "high" # Max uses Codex-supported "xhigh"
model_catalog_json = "/Users/your-user/.codex/deepseek.models.json"
```

- DeepSeek mode never carries the ChatGPT/OpenAI `service_tier`.
- High and Max both keep `thinking = enabled`. High uses Codex `high` → DeepSeek `high`; Max uses Codex `xhigh`, which the compatibility bridge explicitly translates to the DeepSeek upstream `max`. The current Codex config enum does not accept `max`, so status output shows both the transport tier and the effective upstream tier.
- Existing DeepSeek High tasks keep their task-level `high`. When the global mode switches to Max and such tasks are reopened, the Max proxy explicitly translates that legacy `high` to upstream `max`, shown as `high->max` in `/health`'s `last_request_reasoning_effort_translation`. The reverse direction is not allowed: the High proxy still fails on `xhigh` to avoid a silent downgrade.
- On every switch to Max, the switcher requires the proxy health endpoint to declare `accepted_codex_reasoning_efforts=["high","xhigh"]`; otherwise the switch fails and rolls back without reporting success.
- ChatGPT mode restores the OpenAI preferences saved in `~/.codex/chatgpt.activation.toml`.
- The provider, Keychain entry, LaunchAgent, and dedicated model catalog are kept permanently.
- Plugins, MCP servers, projects, desktop settings, permissions, and other configuration stay untouched.
- Backups are saved before every switch in `~/.codex/provider-switch-backups/`.

### Check & verify

Show the current state:

```bash
"Codex 模型切换器.app/Contents/MacOS/CodexModelSwitcher" status
```

Full local verification (uses a mock upstream, never calls a real model):

```bash
./verify.sh
```

Check the bridge on its own:

```bash
curl --noproxy '*' http://127.0.0.1:4878/health
tail -n 50 ~/.codex/log/deepseek-proxy.err.log
```

Verify network, Keychain credentials, and model authorization without invoking inference:

```bash
curl --noproxy '*' -H 'Authorization: Bearer codex-deepseek-local' http://127.0.0.1:4878/upstream-health
```

### Rebuild

```bash
./build.sh
```

The build script produces an ad-hoc signed app for the current Mac architecture targeting macOS 13.0 or newer. It compiles, runs the tests, and signs in a temporary directory first, then replaces the old app only on success.

### Security boundaries

- The bridge refuses to bind to non-loopback addresses.
- The DeepSeek API Key is read from the Keychain only at request time; it is never persisted or logged.
- Codex talks to the local bridge with a separate fixed token; the real DeepSeek Key is never transmitted.
- Installation and verification do not send real inference requests by default.

### Tests

- `Tests/ConfigEditorTests.swift`: Swift unit tests for the config editor, run automatically by `build.sh`.
- `Tests/ProxyTests.py`: bridge integration tests against a mock DeepSeek upstream over loopback only — no real inference; run by `verify.sh` or directly with `python3 Tests/ProxyTests.py`.

### Project layout

```text
.
├── build.sh                       # Build + unit tests + ad-hoc signing
├── install.sh                     # One-shot install / repair
├── verify.sh                      # Local end-to-end verification
├── Sources/CodexModelSwitcher/
│   ├── main.swift                 # GUI and CLI entry point
│   ├── ConfigEditor.swift         # Minimal safe config.toml editing
│   ├── CodexAppRestarter.swift    # Quit and relaunch Codex
│   └── Info.plist                 # v1.5.0 / macOS 13.0+
├── Support/
│   ├── deepseek_responses_proxy.py  # Responses → Chat Completions bridge
│   ├── codex-provider               # Safe switch command
│   ├── install_config.py            # config.toml / LaunchAgent writer
│   └── deepseek.models.json         # Dedicated model catalog
└── Tests/
    ├── ConfigEditorTests.swift
    └── ProxyTests.py
```

### Repository notes

- This repository contains no API Key: `DeepSeek API Key.txt` is excluded by `.gitignore`, and the Key lives only in the macOS Keychain.
- The build artifact `Codex 模型切换器.app/` and local development backups `Backups/` are not committed; regenerate them anytime with `./install.sh` or `./build.sh`.
- Environment variables such as `CODEX_SWITCHER_CODEX_HOME`, `CODEX_SWITCHER_LAUNCH_AGENTS_DIR`, `CODEX_SWITCHER_CODEX_BIN`, and `CODEX_SWITCHER_PROXY_PLIST` can override install paths for non-standard deployments.
