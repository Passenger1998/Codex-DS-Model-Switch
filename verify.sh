#!/bin/zsh
set -euo pipefail

root_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$root_dir"
verify_cache="$(mktemp -d "${TMPDIR:-/tmp}/codex-switcher-verify.XXXXXX")"
trap 'rm -rf "$verify_cache"' EXIT

PYTHONPYCACHEPREFIX="$verify_cache" /usr/bin/python3 -m py_compile Support/deepseek_responses_proxy.py Support/install_config.py Support/claude-provider Tests/ProxyTests.py Tests/ClaudeProviderTests.py Tests/mock_anthropic_server.py
python3 Tests/ProxyTests.py
python3 Tests/ClaudeProviderTests.py
zsh -n Support/codex-provider Support/claude-wrapper.sh Support/claude-gateway-cred-helper.sh install.sh build.sh
plutil -lint Sources/CodexModelSwitcher/Info.plist
codesign --verify --deep --strict "Codex 模型切换器.app"
test -x "Codex 模型切换器.app/Contents/Resources/claude-provider"
"Codex 模型切换器.app/Contents/MacOS/CodexModelSwitcher" status
