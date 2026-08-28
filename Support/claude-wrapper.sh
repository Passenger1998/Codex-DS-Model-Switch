#!/bin/zsh
# claude-provider: managed launch wrapper (standalone CLI compatibility only)
# Injects the DeepSeek API token from macOS Keychain into the environment and
# then execs the real `claude` CLI.  The token is read at launch time only and
# is never persisted, logged, or written into settings.json.
#
# NOTE: the primary target is the Claude Code engine bundled inside the
# Claude Desktop app, which reads ~/.claude/settings.json (including its
# apiKeyHelper) directly.  This wrapper exists only as an optional
# compatibility layer for a standalone `claude` CLI.
set -euo pipefail

service="claude-code-deepseek-api-key"
account="deepseek"

if token="$(/usr/bin/security find-generic-password -s "$service" -a "$account" -w 2>/dev/null)"; then
  export ANTHROPIC_AUTH_TOKEN="$token"
fi

self="$0"

find_real_claude() {
  local candidate dir
  local -a search_path
  if [[ -n "${CLAUDE_CODE_REAL_BINARY:-}" && -x "$CLAUDE_CODE_REAL_BINARY" ]]; then
    print -r -- "$CLAUDE_CODE_REAL_BINARY"
    return 0
  fi
  IFS=':' read -rA search_path <<< "$PATH"
  for dir in "${search_path[@]}"; do
    [[ -z "$dir" ]] && dir="."
    candidate="$dir/claude"
    if [[ -x "$candidate" && "$candidate" != "$self" ]]; then
      print -r -- "$candidate"
      return 0
    fi
  done
  for candidate in \
    "$HOME/.claude/local/claude" \
    "$HOME/.local/bin/claude" \
    "$HOME/.npm-global/bin/claude" \
    "/usr/local/bin/claude" \
    "/opt/homebrew/bin/claude"; do
    if [[ -x "$candidate" && "$candidate" != "$self" ]]; then
      print -r -- "$candidate"
      return 0
    fi
  done
  return 1
}

if ! real_claude="$(find_real_claude)"; then
  print -u2 "claude-provider: 未找到真实的 claude CLI。请安装 Claude Code，或设置 CLAUDE_CODE_REAL_BINARY。"
  exit 127
fi

exec "$real_claude" "$@"
