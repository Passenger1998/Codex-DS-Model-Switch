#!/bin/zsh
# claude-provider: managed launch wrapper (standalone CLI compatibility only)
# Locates and execs the real `claude` CLI without injecting credentials into
# its environment. Current Claude Code reads apiKeyHelper from settings.json;
# official mode restores the user's original helper exactly.
#
# NOTE: Claude Desktop 3P mode is configured independently through its
# Claude-3p config library. This wrapper exists only as an optional
# compatibility layer for a standalone `claude` CLI.
set -euo pipefail

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
