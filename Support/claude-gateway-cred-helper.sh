#!/bin/zsh
# claude-provider: Claude Desktop / direct CLI credential helper
# Installed as ~/.claude/deepseek-keychain-helper. Prints the DeepSeek API
# key for Claude Code from its dedicated macOS Keychain service and active
# non-secret Credential Profile metadata.
# The Claude Desktop runs this executable with no arguments and reads stdout
# (trimmed); exit code must be 0.  The key is never stored in any config
# file or log.
set -euo pipefail

claude_home="${CODEX_SWITCHER_CLAUDE_HOME:-$HOME/.claude}"
profiles_file="$claude_home/deepseek-credential-profiles.json"

if [[ ! -f "$profiles_file" ]]; then
  # Backward-compatible mapping for the documented single-key account.
  profile_id=deepseek
elif ! profile_id="$(/usr/bin/python3 -c '
import json, re, sys
try:
    value = json.load(open(sys.argv[1], encoding="utf-8"))
    active = value.get("activeProfileId")
    profiles = value.get("profiles")
    valid = isinstance(profiles, list) and isinstance(active, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", active)
    valid = valid and any(isinstance(item, dict) and item.get("id") == active for item in profiles)
    if not valid:
        raise ValueError
    print(active)
except Exception:
    raise SystemExit(1)
' "$profiles_file")"; then
  print -u2 "Claude DeepSeek Credential Profile 元数据缺失、无效或引用了不存在的 Profile。"
  exit 1
fi

exec /usr/bin/security find-generic-password \
  -s claude-code-deepseek-api-key \
  -a "$profile_id" \
  -w
