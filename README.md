# Codex & Claude Code 模型切换器 / Model Switcher

一个可双击运行的 macOS 小工具，用于统一管理 **Codex** 与 **Claude Code** 两个工具的模型 / Provider。界面是两级选择：

1. **目标工具**：Codex / Claude Code
2. **目标模型 / Provider**：随工具动态变化

An double-clickable macOS utility that manages both **Codex** and **Claude Code** from one window, using a two-level selection:

1. **Tool**: Codex / Claude Code
2. **Model / Provider**: changes with the selected tool

- 版本 / Version：**2.0.2（build 11）**
- 最低系统 / Minimum OS：**macOS 13.0**
- Codex 兼容桥 / Codex bridge：`Support/deepseek_responses_proxy.py` **v1.1.5**（不变 / unchanged）

---

## 中文

### 总览

| 工具 | 可选模型 / Provider | 数据链路 |
| --- | --- | --- |
| Codex | ChatGPT、DeepSeek V4 Pro | 沿用既有 Responses 兼容桥（不变） |
| Claude Code | Claude 官方、DeepSeek V4 Pro、DeepSeek V4 Flash | 直连 DeepSeek Anthropic 兼容端点（不经过 Codex proxy），主目标为 Claude Desktop 内置 Claude Code |

Codex 的既有逻辑（`codex-provider`、Responses 兼容桥、健康检查、备份回滚）保持不变，未被重构。Claude Code 使用一套**独立**的管理层（`claude-provider`），两者互不污染。

### Codex（保持不变）

Codex 自定义 Provider 只接受 OpenAI Responses API，而 DeepSeek V4 提供 Chat Completions API。本项目内置一个仅监听 `127.0.0.1` 的本地兼容桥：

```text
Codex ── Responses API ──> 本地兼容桥 ── Chat Completions ──> DeepSeek
```

推理强度不再由切换器管理，而是完全跟随 Codex 每个会话自身的「推理强度」设置（高 = High，极高 = Max）。切换成功并通过健康检查后会自动退出并重新打开 Codex。DeepSeek 模式只切换 Provider/模型并检查 `/upstream-health`，不做其它改动。

### Claude Code（以 Claude Desktop 内置引擎为主目标）

Claude Code → DeepSeek **不经过现有 Codex Python proxy**。DeepSeek 原生提供 Anthropic-compatible API，直接使用：

```text
ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
```

**主目标**是新版 Claude Desktop.app 内置的 Claude Code 引擎（`~/Library/Application Support/Claude/claude-code/*/claude.app`）。独立的 `claude` CLI 走同一份配置，仅作为可选兼容目标，不是前置条件。

切换器同时管理**两层配置**：

1. `~/.claude/settings.json` —— Claude Code 引擎官方用户配置（`env` + `apiKeyHelper`），新会话启动时读取，是 **Claude Code DeepSeek 状态的主要事实来源**；
2. `~/Library/Application Support/Claude/developer_settings.json` —— Claude Desktop 的 **Developer Mode / Custom 3p Provider** 配置，作为**可选的 Desktop 层信息**。DeepSeek 模式下把 Desktop 的推理 Provider 设为指向 `https://api.deepseek.com/anthropic` 的 gateway，凭据为 Keychain helper 脚本，模型列表带 Anthropic 家族标注（opus/sonnet/haiku）。Desktop 在**应用启动时**读取该文件，所以 GUI 切换后会自动退出并重新打开 Claude Desktop（与 Codex 相同）。

> 实测确认（Claude Desktop 1.37937.1 / Claude Code 2.1.246）：即使 `developer_settings.json` 仅含 `{"allowDevTools": true}`，内置 Claude Code 依靠 `settings.json` 已可正常经 DeepSeek 工作。因此**只要 `settings.json` 正确，状态就不会因 Developer 配置缺 DeepSeek `inference/models` 而判定为「配置不一致」**；Developer 层仅作为可选信息展示。

`claude-provider` 只精确修改 `~/.claude/settings.json` 里的 `env` 对象与 `apiKeyHelper` 字段，管理的 env：

```text
ANTHROPIC_BASE_URL
ANTHROPIC_MODEL
ANTHROPIC_DEFAULT_OPUS_MODEL
ANTHROPIC_DEFAULT_SONNET_MODEL
ANTHROPIC_DEFAULT_HAIKU_MODEL
ANTHROPIC_SMALL_FAST_MODEL
CLAUDE_CODE_SUBAGENT_MODEL
HTTP_PROXY
HTTPS_PROXY
```

- **模型按 Claude Desktop 的真实映射机制实现**：请求发送的是 Anthropic 原生模型名，由 DeepSeek 服务端按官方规则映射 —— `claude-opus*` → DeepSeek V4 Pro，`claude-sonnet*` / `claude-haiku*` → DeepSeek V4 Flash。切换器只写入引擎当前版本的规范模型名（Pro = `claude-opus-5`，Flash = `claude-sonnet-5`），**不把模型名硬写成 `deepseek-v4-pro` / `deepseek-v4-flash`**。
- **Pro / Flash 在 Desktop 里如何区分**：Developer 配置的模型列表包含三条（`claude-opus-5` = DeepSeek V4 Pro / Opus 档、`claude-sonnet-5` = DeepSeek V4 Flash / Sonnet 档、`claude-haiku-4-5-20251001` = DeepSeek V4 Flash / Haiku 档），并带 `anthropicFamilyTier` 家族标注；切换 Pro 或 Flash 时把对应条目放到列表首位（默认档）。会话实际使用的模型由 **Claude Desktop 的模型选择器**决定，切换器不伪造“已切换模型”，GUI 会如实提示。
- `apiKeyHelper` 指向一条 Keychain 读取命令（`security find-generic-password … -w`），DeepSeek API Key 由引擎在**请求时**动态获取，`settings.json` 中**不含任何明文 Key**（见下文「Claude Code 凭据」）。
- Desktop 的 gateway 凭据同样使用 Keychain helper（`~/.codex/bin/claude-gateway-cred-helper`），`developer_settings.json` 中不含任何明文 Key。
- **系统代理（关键修复）**：本机直连 `api.deepseek.com` 会超时，必须走 macOS 系统代理。切换到 DeepSeek 时，`claude-provider` 复用 Codex 兼容桥的 `scutil --proxy` 解析设计，动态读取当前系统 HTTP/HTTPS 代理并写入 `env.HTTP_PROXY` / `env.HTTPS_PROXY`（代理地址每次切换时动态生成，不写死端口）。系统代理未启用时**不生成任何代理配置**，并保留用户已有的自定义代理值；这两个字段纳入官方状态快照，切回「Claude 官方」时恢复切换前的原始值。
- `settings.json` 中的 permissions、hooks、MCP/plugins、projects 等其它配置一律保留。
- 切换到 DeepSeek 前会保存两份原始状态（`claude-official.env.json` 与 `claude-official.developer-settings.json`）；切回「Claude 官方」时完整恢复，而不是写死一套默认值。
- 写入原子化，切换前备份，失败自动回滚，带并发锁，写入后做最终校验。

Claude Code 是会话式工具：Desktop 内置引擎在每个新会话启动时读取 `settings.json`；而 **Developer Provider 配置需重启 Claude Desktop 才生效**，因此 GUI 切换后会自动退出并重新打开 Claude Desktop（正在执行的 Claude 会话会被中断，与 Codex 一致）。切换器不会误重启 Codex；Claude Desktop 未运行时不视为错误，只提示「下次启动生效」。

状态检测以真实配置为准：

- Claude Desktop 是否安装（`/Applications/Claude.app` 版本）；
- 内置 Claude Code 引擎是否存在及版本；
- 独立 `claude` CLI 是否存在（不在 PATH 只显示「独立 CLI 未安装/不可用」，**绝不**判定「Claude Code 未安装」）；
- 当前是 Claude 官方还是 DeepSeek；能可靠判断档位时（`ANTHROPIC_MODEL` 为 opus/sonnet/haiku 系）才显示 Pro / Flash，否则显示「配置不一致」及原因。
- `env.HTTP_PROXY` / `env.HTTPS_PROXY` 与当前系统代理（供诊断）。

### Claude Code 凭据（首次配置）

Claude Code 使用**独立于 Codex** 的 DeepSeek API Key，存放在 macOS Keychain 的独立 service 中：

```bash
security add-generic-password -s claude-code-deepseek-api-key -a deepseek -w sk-你的-key
```

（Codex 仍使用 `codex-deepseek-api-key`，两者互不影响。）

真实 Key 不写进仓库、不写日志、不硬编码、不明文写进 `settings.json` 或 `developer_settings.json`。`claude-provider` 在 `settings.json` 中写入 Claude Code 官方的 `apiKeyHelper`（`/usr/bin/security find-generic-password -s claude-code-deepseek-api-key -a deepseek -w`），并在 Desktop Developer 配置中把凭据设为 helper 脚本 `~/.codex/bin/claude-gateway-cred-helper`（同样从 Keychain 动态取 Key）。

`install.sh` 另外安装一个可选兼容层 wrapper 到 `~/.claude/bin/claude`（仅在独立 CLI 需要时使用；把 `~/.claude/bin` 放到 `PATH` 最前即可）。Desktop 内置引擎不需要它。

### 安装或修复

首次使用、升级或复检后运行：

```bash
./install.sh
```

安装器会：

1. 运行测试并重新构建 `Codex 模型切换器.app`。
2. 安装 Codex 兼容桥到 `~/.codex/deepseek-proxy/`。
3. 安装 `~/.codex/bin/codex-provider`（Codex 安全切换命令）。
4. 安装 `~/.codex/bin/claude-provider`（Claude Code 配置/凭据管理层）。
5. 安装 Desktop 凭据 helper 到 `~/.codex/bin/claude-gateway-cred-helper`。
6. 安装可选兼容层 wrapper 到 `~/.claude/bin/claude`（Desktop 内置引擎不需要）。
6. 写入专用模型目录 `~/.codex/deepseek.models.json`。
7. 只更新 `config.toml` 的 `[model_providers.deepseek]` 相关表（与旧版一致）。
8. 安装并启动 `~/Library/LaunchAgents/local.codex-deepseek-proxy.plist`。

安装器不会读取或写出任何 API Key。

### 使用

双击 `Codex 模型切换器.app`，或使用命令行：

```bash
# 查看 Codex 与 Claude Code 的当前实际状态
"Codex 模型切换器.app/Contents/MacOS/CodexModelSwitcher" status

# Codex
"Codex 模型切换器.app/Contents/MacOS/CodexModelSwitcher" codex chatgpt
"Codex 模型切换器.app/Contents/MacOS/CodexModelSwitcher" codex deepseek

# Claude Code
"Codex 模型切换器.app/Contents/MacOS/CodexModelSwitcher" claude default
"Codex 模型切换器.app/Contents/MacOS/CodexModelSwitcher" claude deepseek-pro
"Codex 模型切换器.app/Contents/MacOS/CodexModelSwitcher" claude deepseek-flash
```

兼容旧用法：`chatgpt` / `deepseek` 等价于 `codex chatgpt` / `codex deepseek`。

GUI 界面：

```text
工具        [ Codex ▼ ]
模型        [ ChatGPT ▼ ]
当前状态：  Codex · ChatGPT
```

选择 Claude Code 时会动态显示它自己的模型列表：

```text
工具        [ Claude Code ▼ ]
模型        [ DeepSeek V4 Pro ▼ ]
当前状态：  Claude Code · DeepSeek V4 Pro
```

- 状态始终根据**真实配置**推导，不是「上次点击」的记录。
- Codex 与 Claude Code 的状态分别保存/检测，互不覆盖。
- 切换 Codex 后按既有逻辑重启 Codex；切换 Claude Code 会自动退出并重新打开 Claude Desktop（仅 Claude，不会误重启 Codex）。
- 配置异常时显示「配置不一致」及简短原因。

切换到 DeepSeek 后，请在 Claude Desktop 的**模型选择器**中确认选择：DeepSeek V4 Pro（Opus 档）或 DeepSeek V4 Flash（Sonnet/Haiku 档）。切换器已把所选档位设为默认条目，但 Desktop 会记住用户上次的选择。

### 配置修改规则

Codex 部分与旧版一致（只激活 `model` / `model_provider` / `model_catalog_json` 顶层字段，恢复 `~/.codex/chatgpt.activation.toml`，Provider/Keychain/LaunchAgent/模型目录永久保留）。每次切换前备份到 `~/.codex/provider-switch-backups/`。

Claude Code 部分只修改 `~/.claude/settings.json` 的 `env` 对象与 `apiKeyHelper` 字段，以及 `~/Library/Application Support/Claude/developer_settings.json` 的 `inference` 与 `models` 字段（其余 Developer 设置保留），切换前备份到 `~/.claude/provider-switch-backups/`，并保存原始状态到 `~/.claude/claude-official.env.json` 与 `~/.claude/claude-official.developer-settings.json` 供「Claude 官方」恢复。

### 检查与验证

```bash
# 完整本地验证（使用模拟上游，不会请求真实模型）
./verify.sh

# 单独查看 Claude Code 状态
CODEX_SWITCHER_CLAUDE_HOME="$HOME/.claude" python3 Support/claude-provider status

# Codex 兼容桥
curl --noproxy '*' http://127.0.0.1:4878/health
```

### 重新构建

```bash
./build.sh
```

### 安全边界

- Codex 兼容桥拒绝绑定非回环地址；DeepSeek API Key 只在请求时从 Keychain 读取。
- Claude Code 的 DeepSeek Key 独立存放在 `claude-code-deepseek-api-key`，由 wrapper 在启动时动态注入，不落盘、不写日志、不明文进 `settings.json`。
- 安装与验证默认不发送真实模型推理请求。

### 测试

- `Tests/ConfigEditorTests.swift` + `Tests/ClaudeProviderTests.swift`：Swift 单元测试（参数传递、状态解析、目录覆盖、缺失命令守护、Codex 重启），`build.sh` 构建时自动运行。
- `Tests/ProxyTests.py`：Codex 兼容桥集成测试（模拟 DeepSeek 上游、仅回环，不产生真实推理），由 `verify.sh` 运行。
- `Tests/ClaudeProviderTests.py`：Claude Desktop 管理层单元测试（Desktop/内置引擎/独立 CLI 检测、opus→Pro 与 sonnet/haiku→Flash 映射、`scutil --proxy` 解析（存在/不存在/禁用/回退/IPv6）、DeepSeek 切换写入系统代理、无系统代理不写无效值并保留自定义代理、切回官方恢复原代理、developer_settings.json 网关配置与恢复、`{"allowDevTools": true}` 时状态仍正确、默认↔Pro↔Flash 切换、apiKeyHelper、原配置保留、独立凭据、无 Key/非法 JSON、中途回滚、幂等、Codex↔Claude 互不污染），由 `verify.sh` 运行。
- `Tests/mock_anthropic_server.py`：本地模拟 Anthropic Messages API，用于对内置 Claude Code 引擎做零成本端到端验证。

### 项目结构

```text
.
├── build.sh                       # 构建 + 单元测试 + ad-hoc 签名
├── install.sh                     # 一键安装 / 修复
├── verify.sh                      # 本地端到端验证
├── AppIcon-preview.png            # 应用图标预览
├── Sources/CodexModelSwitcher/
│   ├── main.swift                 # 两级 GUI 与统一 CLI 入口
│   ├── ConfigEditor.swift         # Codex/Claude 状态解析与安全命令封装
│   ├── CodexAppRestarter.swift    # 退出并重新打开 Codex
│   ├── AppIcon.icns               # 应用图标（构建时打包）
│   └── Info.plist                 # v2.0.2 / macOS 13.0+
├── Support/
│   ├── deepseek_responses_proxy.py  # Codex Responses → Chat Completions 兼容桥
│   ├── codex-provider               # Codex 安全切换命令
│   ├── claude-provider              # Claude Desktop 配置/凭据管理层（settings.json + developer_settings.json）
│   ├── claude-gateway-cred-helper.sh# Claude Desktop gateway 凭据 helper（Keychain）
│   ├── claude-wrapper.sh            # Claude Code 启动 wrapper（动态注入 Key）
│   ├── install_config.py            # config.toml / LaunchAgent 写入
│   ├── generate_app_icon.swift      # 生成 AppIcon.icns 与预览图
│   └── deepseek.models.json         # Codex 专用模型目录
└── Tests/
    ├── ConfigEditorTests.swift
    ├── ClaudeProviderTests.swift
    ├── ProxyTests.py
    ├── ClaudeProviderTests.py
    └── mock_anthropic_server.py
```

### 仓库说明

- 本仓库不含任何 API Key：`DeepSeek API Key.txt` 已被 `.gitignore` 排除，Key 只存放在 macOS Keychain。
- 构建产物 `Codex 模型切换器.app/` 与本地开发备份 `Backups/` 不入库，可用 `./install.sh` 或 `./build.sh` 随时重新生成。
- 可通过 `CODEX_SWITCHER_CODEX_HOME`、`CODEX_SWITCHER_CLAUDE_HOME`、`CODEX_SWITCHER_LAUNCH_AGENTS_DIR`、`CODEX_SWITCHER_CODEX_BIN`、`CODEX_SWITCHER_PROXY_PLIST` 等环境变量覆盖安装路径，便于非标准环境部署。

---

## English

### Overview

| Tool | Models / Providers | Data path |
| --- | --- | --- |
| Codex | ChatGPT, DeepSeek V4 Pro | Existing Responses bridge (unchanged) |
| Claude Code | Claude official, DeepSeek V4 Pro, DeepSeek V4 Flash | Direct DeepSeek Anthropic-compatible endpoint (not via the Codex proxy) |

The existing Codex pipeline (`codex-provider`, Responses bridge, health checks, backup/rollback) is untouched. Claude Code uses an independent manager (`claude-provider`); the two never pollute each other.

### Codex (unchanged)

The local `127.0.0.1`-only Responses bridge translates Codex Responses calls into DeepSeek Chat Completions. Reasoning effort follows each Codex session's own setting; a successful switch quits and reopens Codex.

### Claude Code (new)

Claude Code → DeepSeek uses DeepSeek's native Anthropic-compatible API directly:

```text
ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
```

`claude-provider` manages two layers: the `env` object and `apiKeyHelper` of `~/.claude/settings.json` (the single source of truth for the Claude Code state), and the `inference`/`models` sections of the Claude Desktop `developer_settings.json` (optional Desktop-layer info). The Desktop loads the latter at app start, so the GUI restarts Claude Desktop after a switch (just like Codex). It manages `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL`, `ANTHROPIC_SMALL_FAST_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL`, `HTTP_PROXY`, and `HTTPS_PROXY`.

Verified on this machine (Claude Desktop 1.37937.1 / Claude Code 2.1.246): direct connections to `api.deepseek.com` time out and the engine works only through the macOS system proxy. On every DeepSeek switch the manager reuses the Codex bridge's `scutil --proxy` parsing design and writes the dynamically detected proxy into `env.HTTP_PROXY` / `env.HTTPS_PROXY` (never hardcoding a port). When no system proxy is configured, no invalid proxy values are generated and pre-existing custom values are kept; the proxy keys are part of the official-state snapshot and are restored on "Claude 官方". The DeepSeek state is judged from `settings.json` only — a `developer_settings.json` containing just `{"allowDevTools": true}` (or no DeepSeek `inference`/`models`) never marks a working engine as inconsistent.

Model mapping follows the real Claude Desktop mechanism: requests carry native Anthropic model ids and DeepSeek maps them server-side — `claude-opus*` → DeepSeek V4 Pro, `claude-sonnet*` / `claude-haiku*` → DeepSeek V4 Flash. The switcher writes the engine's canonical ids (`claude-opus-5` for Pro, `claude-sonnet-5` for Flash) and never hardcodes DeepSeek model names. The DeepSeek key is delivered through the official `apiKeyHelper` (a `security … -w` command backed by macOS Keychain), never stored in plaintext. All other settings are preserved, writes are atomic, and switches are backed up and rolled back on failure.

The Developer-mode model list carries Anthropic family tiers: `claude-opus-5` (opus → DeepSeek V4 Pro) and `claude-sonnet-5` / `claude-haiku-4-5-20251001` (sonnet/haiku → DeepSeek V4 Flash); the switcher puts the requested mode first as the default picker entry. The session model is chosen in the Desktop's own model picker — the switcher reports the real state and never fakes a model switch. A switch never touches Codex, and "Claude not running" is not an error. Status detection reports the Claude Desktop app/version, the bundled Claude Code engine/version, the Desktop provider state, and the standalone CLI separately — a missing `claude` in `PATH` only means "standalone CLI unavailable", never "Claude Code not installed".

### Claude Code credentials (first-time setup)

Store a separate DeepSeek key in Keychain:

```bash
security add-generic-password -s claude-code-deepseek-api-key -a deepseek -w sk-your-key
```

`claude-provider` writes the official `apiKeyHelper` (`security find-generic-password -s claude-code-deepseek-api-key -a deepseek -w`) into `~/.claude/settings.json` and configures the Desktop's Developer-mode credential as a helper script (`~/.codex/bin/claude-gateway-cred-helper`); both fetch the key from Keychain at request time. `install.sh` additionally installs an optional compat wrapper at `~/.claude/bin/claude` for standalone-CLI use (put `~/.claude/bin` at the front of your `PATH`); the Desktop's built-in engine does not need it.

### Usage

Double-click `Codex 模型切换器.app`, or:

```bash
"Codex 模型切换器.app/Contents/MacOS/CodexModelSwitcher" status
"Codex 模型切换器.app/Contents/MacOS/CodexModelSwitcher" codex chatgpt
"Codex 模型切换器.app/Contents/MacOS/CodexModelSwitcher" codex deepseek
"Codex 模型切换器.app/Contents/MacOS/CodexModelSwitcher" claude default
"Codex 模型切换器.app/Contents/MacOS/CodexModelSwitcher" claude deepseek-pro
"Codex 模型切换器.app/Contents/MacOS/CodexModelSwitcher" claude deepseek-flash
```

Legacy `chatgpt` / `deepseek` still map to `codex chatgpt` / `codex deepseek`.

### Verification

```bash
./verify.sh
```

Uses a mock upstream only; it never calls a real model.

### Tests

- `Tests/ConfigEditorTests.swift` + `Tests/ClaudeProviderTests.swift`: Swift unit tests, run by `build.sh`.
- `Tests/ProxyTests.py`: Codex bridge integration tests (loopback mock upstream), run by `verify.sh`.
- `Tests/ClaudeProviderTests.py`: Claude Desktop manager unit tests, run by `verify.sh`.

### Repository notes

- No API key is committed; keys live only in macOS Keychain.
- Build artifacts and local backups are regenerated with `./install.sh` or `./build.sh`.
- `CODEX_SWITCHER_CODEX_HOME`, `CODEX_SWITCHER_CLAUDE_HOME`, `CODEX_SWITCHER_LAUNCH_AGENTS_DIR`, `CODEX_SWITCHER_CODEX_BIN`, and `CODEX_SWITCHER_PROXY_PLIST` override install paths.
