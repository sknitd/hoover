#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/hoover-stress.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
mkdir -p .build/cache/clang
export CLANG_MODULE_CACHE_PATH="$PWD/.build/cache/clang"
swiftc -O -parse-as-library Sources/HooverCore/*.swift scripts/stress-core.swift -o "$work_dir/stress"
"$work_dir/stress"
