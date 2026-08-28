#!/bin/zsh
# claude-provider: Claude Desktop gateway credential helper
# Prints the DeepSeek API key for Claude Code from the macOS Keychain.
# The Claude Desktop runs this executable with no arguments and reads stdout
# (trimmed); exit code must be 0.  The key is never stored in any config
# file or log.
set -euo pipefail

exec /usr/bin/security find-generic-password \
  -s claude-code-deepseek-api-key \
  -a deepseek \
  -w
