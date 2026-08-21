#!/bin/zsh
set -euo pipefail

root_dir="$(cd "$(dirname "$0")" && pwd)"
codex_home="${CODEX_SWITCHER_CODEX_HOME:-$HOME/.codex}"
launch_agents_dir="${CODEX_SWITCHER_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
launch_agent="$launch_agents_dir/local.codex-deepseek-proxy.plist"
proxy_dir="$codex_home/deepseek-proxy"
bin_dir="$codex_home/bin"
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
install -m 700 "$root_dir/Support/deepseek_responses_proxy.py" "$proxy_dir/proxy.py"
install -m 700 "$root_dir/Support/codex-provider" "$bin_dir/codex-provider"
install -m 600 "$root_dir/Support/deepseek.models.json" "$codex_home/deepseek.models.json"

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
    exit 0
  fi
  sleep 0.1
done

print -u2 "安装已写入，但 DeepSeek 本地代理未启动。"
print -u2 "请检查：$log_dir/deepseek-proxy.err.log"
exit 1
