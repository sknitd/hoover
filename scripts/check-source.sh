#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Hosted/cloud machines may have a read-only home. Keep caches in the checkout's
# ignored build directory without altering HOME or the toolchain trust settings.
mkdir -p .build/cache/clang .build/cache/swiftpm .build/cache/config .build/cache/security
export CLANG_MODULE_CACHE_PATH="$PWD/.build/cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift test --cache-path "$PWD/.build/cache/swiftpm" --config-path "$PWD/.build/cache/config" --security-path "$PWD/.build/cache/security" --parallel
if [[ "$(uname -s)" == Darwin ]]; then
  swift build --product Hoover
else
  # Linux cannot type-check AppKit. Parsing still catches malformed native source.
  find Sources/Hoover -name '*.swift' -print0 | xargs -0 -r swiftc -frontend -parse
fi
swift scripts/check-bundle.swift
