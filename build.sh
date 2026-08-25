#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Codex 模型切换器"
APP_DIR="$ROOT_DIR/$APP_NAME.app"
BUILD_ROOT="$(mktemp -d "$ROOT_DIR/.codex-model-switcher-build.XXXXXX")"
STAGED_APP_DIR="$BUILD_ROOT/$APP_NAME.app"
PREVIOUS_APP_DIR="$BUILD_ROOT/previous.app"
CONTENTS_DIR="$STAGED_APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
MODULE_CACHE_DIR="$BUILD_ROOT/modulecache"
CLANG_MODULE_CACHE_DIR="$BUILD_ROOT/clang"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
TARGET_ARCH="${CODEX_SWITCHER_ARCH:-$(uname -m)}"
OLD_APP_MOVED=0
TEST_BINARY="$BUILD_ROOT/ConfigEditorTests"

PYTHONPYCACHEPREFIX="$BUILD_ROOT/pycache" /usr/bin/python3 -m py_compile \
  "$ROOT_DIR/Support/deepseek_responses_proxy.py" \
  "$ROOT_DIR/Support/install_config.py"
zsh -n "$ROOT_DIR/Support/codex-provider" "$ROOT_DIR/install.sh"

cleanup() {
  if [[ "$OLD_APP_MOVED" -eq 1 && ! -e "$APP_DIR" && -e "$PREVIOUS_APP_DIR" ]]; then
    mv "$PREVIOUS_APP_DIR" "$APP_DIR"
  fi
  rm -rf "$BUILD_ROOT"
}
trap cleanup EXIT

case "$TARGET_ARCH" in
  arm64|x86_64) ;;
  *)
    echo "不支持的构建架构：$TARGET_ARCH" >&2
    exit 1
    ;;
esac

if [[ ! "$DEPLOYMENT_TARGET" =~ '^[0-9]+([.][0-9]+){1,2}$' ]]; then
  echo "无效的 macOS deployment target：$DEPLOYMENT_TARGET" >&2
  exit 1
fi

if [[ -n "${CODEX_SWITCHER_SDK_PATH:-}" ]]; then
  SDK_PATH="$CODEX_SWITCHER_SDK_PATH"
elif [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
  # The installed Swift compiler and newest beta SDK can briefly be out of sync.
  # This app only needs macOS 13 APIs, so the stable 15.4 SDK is sufficient.
  SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
else
  SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
fi
SWIFT_TARGET="$TARGET_ARCH-apple-macosx$DEPLOYMENT_TARGET"

mkdir -p "$MACOS_DIR"
mkdir -p "$CLANG_MODULE_CACHE_DIR"

SWIFT_MODULE_CACHE_DIR="$MODULE_CACHE_DIR" \
CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_DIR" \
swiftc -swift-version 5 -O \
  -target "$SWIFT_TARGET" \
  -sdk "$SDK_PATH" \
  -framework AppKit \
  -o "$TEST_BINARY" \
  "$ROOT_DIR/Sources/CodexModelSwitcher/ConfigEditor.swift" \
  "$ROOT_DIR/Sources/CodexModelSwitcher/CodexAppRestarter.swift" \
  "$ROOT_DIR/Tests/ConfigEditorTests.swift"

"$TEST_BINARY"

SWIFT_MODULE_CACHE_DIR="$MODULE_CACHE_DIR" \
CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_DIR" \
swiftc -swift-version 5 -O \
  -target "$SWIFT_TARGET" \
  -sdk "$SDK_PATH" \
  -framework AppKit \
  -o "$MACOS_DIR/CodexModelSwitcher" \
  "$ROOT_DIR/Sources/CodexModelSwitcher/ConfigEditor.swift" \
  "$ROOT_DIR/Sources/CodexModelSwitcher/CodexAppRestarter.swift" \
  "$ROOT_DIR/Sources/CodexModelSwitcher/main.swift"

cp "$ROOT_DIR/Sources/CodexModelSwitcher/Info.plist" "$CONTENTS_DIR/Info.plist"
mkdir -p "$CONTENTS_DIR/Resources"
cp "$ROOT_DIR/Sources/CodexModelSwitcher/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

xattr -cr "$STAGED_APP_DIR"
codesign --force --deep --sign - "$STAGED_APP_DIR"
codesign --verify --deep --strict "$STAGED_APP_DIR"

if [[ -e "$APP_DIR" ]]; then
  mv "$APP_DIR" "$PREVIOUS_APP_DIR"
  OLD_APP_MOVED=1
fi

mv "$STAGED_APP_DIR" "$APP_DIR"
OLD_APP_MOVED=0

echo "已生成：$APP_DIR"
