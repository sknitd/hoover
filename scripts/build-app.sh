#!/bin/bash
# Build a real, signed native app. Requires macOS with Xcode Command Line Tools.
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo "Hoover.app must be compiled on macOS with the Apple SDK. Run this script on a Mac or use the macOS Build workflow." >&2
  exit 1
fi

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
dist_dir="${HOOVER_DIST_DIR:-$repo_dir/dist}"
app_dir="$dist_dir/Hoover.app"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/hoover-build.XXXXXX")"
smoke_pid=""
cleanup() {
  if [[ -n "$smoke_pid" ]]; then
    kill "$smoke_pid" 2>/dev/null || true
    wait "$smoke_pid" 2>/dev/null || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

command -v swift >/dev/null
xcrun --find swift >/dev/null
swift --version
swift test --parallel

# On hosted macOS runners both architectures can be built against the macOS SDK.
# Set HOOVER_ARCHS to the current architecture for a quicker local iteration.
IFS=' ' read -r -a archs <<< "${HOOVER_ARCHS:-arm64 x86_64}"
binaries=()
resource_dirs=()
for arch in "${archs[@]}"; do
  case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
  swift build --configuration release --arch "$arch" --product Hoover
  bin_dir="$(swift build --configuration release --arch "$arch" --show-bin-path)"
  [[ -x "$bin_dir/Hoover" ]] || { echo "Compiled Hoover executable is missing." >&2; exit 1; }
  cp "$bin_dir/Hoover" "$work_dir/Hoover-$arch"
  binaries+=("$work_dir/Hoover-$arch")
  resource_dirs+=("$bin_dir")
done

mkdir -p "$dist_dir" "$work_dir/Hoover.app/Contents/MacOS" "$work_dir/Hoover.app/Contents/Resources"
if [[ ${#binaries[@]} -gt 1 ]]; then
  lipo -create "${binaries[@]}" -output "$work_dir/Hoover.app/Contents/MacOS/Hoover"
else
  cp "${binaries[0]}" "$work_dir/Hoover.app/Contents/MacOS/Hoover"
fi
cp Sources/Hoover/Resources/Info.plist "$work_dir/Hoover.app/Contents/Info.plist"
plutil -lint "$work_dir/Hoover.app/Contents/Info.plist"
xcrun swift scripts/generate-icon.swift "$work_dir/Hoover.iconset"
iconutil --convert icns "$work_dir/Hoover.iconset" --output "$work_dir/Hoover.app/Contents/Resources/Hoover.icns"

# Keep SwiftPM resources available to its generated Bundle.module accessor.
# Bundle.main.bundleURL resolves to the .app on macOS, hence the root location.
for bundle in "${resource_dirs[0]}"/*.bundle; do
  [[ -d "$bundle" ]] || continue
  cp -R "$bundle" "$work_dir/Hoover.app/"
done

signing_identity="${HOOVER_SIGNING_IDENTITY:--}"
codesign --force --options runtime --entitlements Sources/Hoover/Resources/Hoover.entitlements --sign "$signing_identity" "$work_dir/Hoover.app"
codesign --verify --deep --strict --verbose=2 "$work_dir/Hoover.app"
file "$work_dir/Hoover.app/Contents/MacOS/Hoover"
lipo -info "$work_dir/Hoover.app/Contents/MacOS/Hoover"

# Only replace output after compilation and signature verification succeed.
if [[ -e "$app_dir" ]]; then
  [[ -d "$app_dir/Contents/MacOS" && -f "$app_dir/Contents/Info.plist" ]] || { echo "Refusing to replace a non-app path: $app_dir" >&2; exit 1; }
  rm -rf "$app_dir"
fi
mv "$work_dir/Hoover.app" "$app_dir"
if [[ "${HOOVER_LAUNCH_SMOKE_TEST:-0}" == 1 ]]; then
  mkdir -p "$dist_dir/build-results"
  launch_log="$dist_dir/build-results/launch.log"
  "$app_dir/Contents/MacOS/Hoover" > "$launch_log" 2>&1 &
  smoke_pid=$!
  sleep 2
  if ! kill -0 "$smoke_pid" 2>/dev/null; then
    echo "error: Packaged Hoover exited during native launch smoke." >&2
    cat "$launch_log" >&2
    exit 1
  fi
  if ! /usr/bin/grep -q 'Hoover native launch completed' "$launch_log"; then
    echo "error: Packaged Hoover did not report applicationDidFinishLaunching during native launch smoke." >&2
    cat "$launch_log" >&2
    exit 1
  fi
  kill "$smoke_pid"
  wait "$smoke_pid" 2>/dev/null || true
  smoke_pid=""
  echo "Native launch smoke passed: compiled app completed launch and remained running."
fi
ditto -c -k --keepParent "$app_dir" "$dist_dir/Hoover-macOS.zip"
echo "Built $app_dir"
echo "Archive: $dist_dir/Hoover-macOS.zip"
