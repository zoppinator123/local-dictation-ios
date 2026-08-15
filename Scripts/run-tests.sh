#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
export CLANG_MODULE_CACHE_PATH="$root/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$root/.build/swift-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
echo "Running Local Dictation iOS shared-core tests…"
swift run --disable-sandbox LocalDictationTestRunner
