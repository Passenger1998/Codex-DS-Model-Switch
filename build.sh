#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="CodexModelSwitcher"
LEGACY_APP_NAME="Codex 模型切换器"
APP_DIR="$ROOT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
CACHE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-model-switcher.XXXXXX")"
MODULE_CACHE_DIR="$CACHE_ROOT/modulecache"
CLANG_MODULE_CACHE_DIR="$CACHE_ROOT/clang"
trap 'rm -rf "$CACHE_ROOT"' EXIT

rm -rf "$APP_DIR" "$ROOT_DIR/$LEGACY_APP_NAME.app"
mkdir -p "$MACOS_DIR"
mkdir -p "$CLANG_MODULE_CACHE_DIR"

SWIFT_MODULE_CACHE_DIR="$MODULE_CACHE_DIR" \
CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_DIR" \
swiftc -swift-version 5 -O -framework AppKit \
  -o "$MACOS_DIR/CodexModelSwitcher" \
  "$ROOT_DIR/Sources/CodexModelSwitcher/ConfigEditor.swift" \
  "$ROOT_DIR/Sources/CodexModelSwitcher/main.swift"

cp "$ROOT_DIR/Sources/CodexModelSwitcher/Info.plist" "$CONTENTS_DIR/Info.plist"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

codesign --force --deep --sign - "$APP_DIR"

echo "已生成：$APP_DIR"
