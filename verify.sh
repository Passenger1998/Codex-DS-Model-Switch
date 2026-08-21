#!/bin/zsh
set -euo pipefail

root_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$root_dir"
verify_cache="$(mktemp -d "${TMPDIR:-/tmp}/codex-switcher-verify.XXXXXX")"
trap 'rm -rf "$verify_cache"' EXIT

PYTHONPYCACHEPREFIX="$verify_cache" /usr/bin/python3 -m py_compile Support/deepseek_responses_proxy.py Support/install_config.py Tests/ProxyTests.py
python3 Tests/ProxyTests.py
zsh -n Support/codex-provider install.sh build.sh
plutil -lint Sources/CodexModelSwitcher/Info.plist
codesign --verify --deep --strict "Codex 模型切换器.app"
"Codex 模型切换器.app/Contents/MacOS/CodexModelSwitcher" status
