# CodexModelSwitcher

A small double-clickable macOS utility that switches Codex between the default ChatGPT mode and the DeepSeek V4 Pro model by editing `~/.codex/config.toml` directly.

The application does not download or execute remote scripts. It only changes the minimum set of fields required for the switch, preserves your existing DeepSeek API key, and creates a timestamped backup before every real modification.

## Features

- Switch to `deepseek-v4-pro` with one click.
- Restore Codex to its default OpenAI/ChatGPT mode.
- Automatically quit and reopen the ChatGPT desktop app during the switch.
- Create `config.toml.switcher-backup-*` backups before each actual change.
- Preserve `[model_providers.deepseek]`, plugins, MCP servers, projects, desktop settings, and all unrelated configuration.
- Show a confirmation dialog only when an error occurs; a successful switch exits silently.

## Requirements

- macOS 13.0 or newer.
- Xcode Command Line Tools with `swiftc`.
- Codex installed and configured, with a valid `[model_providers.deepseek]` section already present in `~/.codex/config.toml`.
- ChatGPT desktop app (optional; used only for automatic restart).

## Setup on macOS

1. Make sure macOS 13.0 or newer is installed.
2. Install Apple Command Line Tools:

```bash
xcode-select --install
```

3. Make sure Codex is already installed and configured.
4. Build the app from this project:

```bash
./build.sh
```

The script compiles `Sources/CodexModelSwitcher/*.swift`, produces an ad-hoc signed app at `CodexModelSwitcher.app`, and removes any legacy `Codex 模型切换器.app` bundle left from older versions.

5. Open the generated `CodexModelSwitcher.app`. Because the app is ad-hoc signed, the first launch may require right-clicking it in Finder and choosing **Open**.

## Adding the DeepSeek API key

The API key belongs to the existing Codex provider, not to the switcher. Add it to `~/.codex/config.toml`.

Using the locally verified format:

```toml
[model_providers.deepseek]
name = "deepseek"
base_url = "https://api.deepseek.com/"
wire_api = "responses"
experimental_bearer_token = "sk-your-deepseek-api-key"
```

For a safer setup, keep the key in an environment variable if your Codex build supports `env_key`:

```toml
[model_providers.deepseek]
name = "deepseek"
base_url = "https://api.deepseek.com/"
wire_api = "responses"
env_key = "DEEPSEEK_API_KEY"
```

Then export it in your shell profile:

```bash
export DEEPSEEK_API_KEY="sk-your-deepseek-api-key"
```

After adding the provider, open the switcher and choose `DeepSeek`. The tool only requires that `[model_providers.deepseek]` exists; it will not create or overwrite your key.

## Usage

1. Double-click `CodexModelSwitcher.app`.
2. Choose a target:
   - `DeepSeek`: switch to `deepseek-v4-pro`.
   - `ChatGPT（恢复默认）`: restore Codex to the default OpenAI/ChatGPT mode.
3. The tool quits ChatGPT, edits the configuration, and reopens ChatGPT automatically.
4. On success the switcher exits without any extra dialog; a dialog appears only when something fails.

## What the tool edits

The utility writes only to `~/.codex/config.toml`.

When switching to DeepSeek, it writes or updates these five top-level fields:

```toml
model = "deepseek-v4-pro"
model_provider = "deepseek"
preferred_auth_method = "apikey"
forced_login_method = "api"
model_catalog_json = "~/.codex/models.json"
```

When switching back to ChatGPT, it removes only those five top-level fields.

Important guarantees:

- `[model_providers.deepseek]` and the API key inside it are never modified or removed.
- `model_reasoning_effort`, plugins, MCP servers, projects, desktop settings, and other configuration are kept untouched.
- If the DeepSeek provider is missing, the tool reports the problem and stops instead of creating or overwriting a provider.
- `~/.codex/models.json`, `~/.codex/deepseek.config.toml`, and `DeepSeek API Key.txt` are not read or modified.

## Tests

Run the lightweight config-editor tests with:

```bash
swiftc -swift-version 5 \
  Sources/CodexModelSwitcher/ConfigEditor.swift \
  Tests/ConfigEditorTests.swift \
  -o /tmp/CodexConfigEditorTests
/tmp/CodexConfigEditorTests
```

The tests cover round-trip switching, CRLF preservation, backup creation, missing-provider protection, file-permission preservation, and protection of unrelated config values.

## Project layout

```text
.
├── build.sh
├── Sources/CodexModelSwitcher/
│   ├── main.swift
│   ├── ConfigEditor.swift
│   └── Info.plist
└── Tests/
    └── ConfigEditorTests.swift
```

## Publishing to GitHub

Make sure no local secrets or generated artifacts are committed. A recommended `.gitignore` is:

```gitignore
.DS_Store
*.app/
DeepSeek API Key.txt
```

Then initialize and push the repository:

```bash
git init
git add .
git commit -m "Initial commit: CodexModelSwitcher"
git branch -M main
git remote add origin https://github.com/<your-username>/<your-repository>.git
git push -u origin main
```

Replace `<your-username>` and `<your-repository>` with your GitHub account and repository name.

## Troubleshooting

- **"未找到 [model_providers.deepseek]"**: add a valid DeepSeek provider section to `~/.codex/config.toml` first; the switcher will not create one automatically.
- **ChatGPT does not reopen**: make sure ChatGPT is installed in `/Applications/ChatGPT.app` or `~/Applications/ChatGPT.app`.
- **macOS blocks the app**: use right-click > Open on the first launch, or re-run `./build.sh` and then open it once.

## 中文说明

`CodexModelSwitcher` 是一个可直接双击运行的 macOS 小工具，用于在 Codex 默认 ChatGPT 模式和 DeepSeek V4 Pro 之间切换。

工具直接修改 `~/.codex/config.toml`，每次真正修改前都会创建带时间戳的备份，并自动退出、重新打开 ChatGPT。它不会下载或执行远程脚本。

### macOS 上如何配置

1. 使用 macOS 13 或更新版本。
2. 安装 Apple Command Line Tools：

```bash
xcode-select --install
```

3. 确保本机已经安装并配置好 Codex。
4. 在项目目录里构建：

```bash
./build.sh
```

5. 打开生成的 `CodexModelSwitcher.app`。因为是 ad-hoc 签名，第一次可能需要在 Finder 里右键 > 打开。

### API Key 怎么添加

API Key 属于 Codex 的 DeepSeek provider，不是写进切换器。你需要把它加到 `~/.codex/config.toml` 里。

与你当前本机可用的配置一致：

```toml
[model_providers.deepseek]
name = "deepseek"
base_url = "https://api.deepseek.com/"
wire_api = "responses"
experimental_bearer_token = "sk-你的-deepseek-api-key"
```

如果希望更安全，也可以尝试用环境变量方式：

```toml
[model_providers.deepseek]
name = "deepseek"
base_url = "https://api.deepseek.com/"
wire_api = "responses"
env_key = "DEEPSEEK_API_KEY"
```

然后在 shell 配置里导出：

```bash
export DEEPSEEK_API_KEY="sk-你的-deepseek-api-key"
```

添加完成后，再打开切换器选择 `DeepSeek` 即可。工具只要求 `[model_providers.deepseek]` 这个 provider 存在，不会自动创建或覆盖你的 Key。

### 使用方式

1. 双击 `CodexModelSwitcher.app`。
2. 选择 `DeepSeek` 切换到 `deepseek-v4-pro`，或选择 `ChatGPT（恢复默认）` 恢复默认模式。
3. 切换前会自动退出 ChatGPT，完成后自动重新打开。
4. 成功后工具静默退出，只有出错时才会弹窗提示。

工具只维护 `~/.codex/config.toml`，每次实际修改前会在 `~/.codex/` 创建带时间戳的备份。`[model_providers.deepseek]` 及其 API Key、插件、MCP、projects、desktop 等配置都会原样保留。

### 上传到 GitHub

上传前请确保 `.DS_Store`、编译生成的 `*.app/` 以及 `DeepSeek API Key.txt` 等本地文件没有被提交；建议添加上述 `.gitignore` 规则后再执行 `git add`、`git commit` 和 `git push`。
