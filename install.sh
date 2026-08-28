#!/bin/zsh
set -euo pipefail

root_dir="$(cd "$(dirname "$0")" && pwd)"
codex_home="${CODEX_SWITCHER_CODEX_HOME:-$HOME/.codex}"
claude_home="${CODEX_SWITCHER_CLAUDE_HOME:-$HOME/.claude}"
launch_agents_dir="${CODEX_SWITCHER_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
launch_agent="$launch_agents_dir/local.codex-deepseek-proxy.plist"
proxy_dir="$codex_home/deepseek-proxy"
bin_dir="$codex_home/bin"
claude_bin_dir="$claude_home/bin"
claude_helper="$claude_home/deepseek-keychain-helper"
log_dir="$codex_home/log"
label="local.codex-deepseek-proxy"
domain="gui/$(id -u)"

if [[ "${1:-}" != "--skip-build" ]]; then
  "$root_dir/build.sh"
fi

PYTHONPYCACHEPREFIX="$proxy_dir/.pycache" /usr/bin/python3 -m py_compile \
  "$root_dir/Support/deepseek_responses_proxy.py" \
  "$root_dir/Support/install_config.py"

install -d -m 700 "$codex_home" "$proxy_dir" "$bin_dir" "$log_dir"
install -d -m 700 "$launch_agents_dir"
install -d -m 700 "$claude_home" "$claude_bin_dir"
install -m 700 "$root_dir/Support/deepseek_responses_proxy.py" "$proxy_dir/proxy.py"
install -m 700 "$root_dir/Support/codex-provider" "$bin_dir/codex-provider"
install -m 700 "$root_dir/Support/claude-provider" "$bin_dir/claude-provider"
if [[ ! -e "$claude_helper" ]]; then
  install -m 700 "$root_dir/Support/claude-gateway-cred-helper.sh" "$claude_helper"
fi
install -m 600 "$root_dir/Support/deepseek.models.json" "$codex_home/deepseek.models.json"

# Install the optional standalone-CLI launch wrapper only when it does not
# clobber an existing user-managed `claude` binary at the same path.  The
# Claude Desktop built-in Claude Code reads ~/.claude/settings.json directly
# (including its apiKeyHelper) and does not need this wrapper.
if [[ -e "$claude_bin_dir/claude" ]] && ! grep -q "claude-provider: managed launch wrapper" "$claude_bin_dir/claude" 2>/dev/null; then
  mv "$claude_bin_dir/claude" "$claude_bin_dir/claude.pre-switcher.bak"
fi
install -m 700 "$root_dir/Support/claude-wrapper.sh" "$claude_bin_dir/claude"

/usr/bin/python3 "$root_dir/Support/install_config.py" \
  --codex-home "$codex_home" \
  --launch-agent "$launch_agent"

/bin/launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
for attempt in {1..30}; do
  /bin/launchctl print "$domain/$label" >/dev/null 2>&1 || break
  sleep 0.1
done
loaded=0
for attempt in {1..3}; do
  if /bin/launchctl bootstrap "$domain" "$launch_agent"; then
    loaded=1
    break
  fi
  sleep 0.2
done
[[ "$loaded" -eq 1 ]] || { print -u2 "DeepSeek LaunchAgent 加载失败。"; exit 1; }
/bin/launchctl kickstart -k "$domain/$label"

for attempt in {1..200}; do
  if /usr/bin/curl --fail --silent --max-time 1 http://127.0.0.1:4878/health >/dev/null 2>&1; then
    print "安装完成：$root_dir/Codex 模型切换器.app"
    "$bin_dir/codex-provider" status
    "$bin_dir/claude-provider" status
    exit 0
  fi
  sleep 0.1
done

print -u2 "安装已写入，但 DeepSeek 本地代理未启动。"
print -u2 "请检查：$log_dir/deepseek-proxy.err.log"
exit 1
