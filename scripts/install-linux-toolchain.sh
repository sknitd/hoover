#!/bin/bash
# Install the pinned compiler only after official detached-signature verification.
set -euo pipefail
[[ "$(uname -s)" == Linux ]] || { echo "This helper is for Linux core development; macOS uses Xcode tools." >&2; exit 1; }
[[ "$(uname -m)" == x86_64 ]] || { echo "This pinned Linux toolchain requires x86_64." >&2; exit 1; }

toolchain_root="${HOOVER_TOOLCHAIN_ROOT:-/workspace/toolchains}"
toolchain_dir="$toolchain_root/swift"
if [[ -x "$toolchain_dir/usr/bin/swift" ]] && "$toolchain_dir/usr/bin/swift" --version | head -n 1 | grep -q 'Swift version 6.1.3'; then
  echo "Swift 6.1.3 already installed at $toolchain_dir"
  exit 0
fi
for command in curl gpg tar; do command -v "$command" >/dev/null; done
mkdir -p "$toolchain_root/downloads"
work_dir="$(mktemp -d "$toolchain_root/verify-swift.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
mkdir -m 700 "$work_dir/gnupg"
release_url='https://download.swift.org/swift-6.1.3-release/ubuntu2404/swift-6.1.3-RELEASE/swift-6.1.3-RELEASE-ubuntu24.04.tar.gz'
archive="$toolchain_root/downloads/swift-6.1.3.tar.gz"
curl --fail --location --proto '=https' --tlsv1.2 "$release_url" -o "$archive"
curl --fail --location --proto '=https' --tlsv1.2 "$release_url.sig" -o "$archive.sig"
# Pinned official Swift website mirror. Public keys only; no private credentials.
keys_url='https://raw.githubusercontent.com/swiftlang/swift-org-website/1268dc96e77d9bf37da25f6d538bece4e46006a5/keys/all-keys.asc'
curl --fail --location --proto '=https' --tlsv1.2 "$keys_url" -o "$work_dir/swift-keys.asc"
gpg --homedir "$work_dir/gnupg" --batch --import "$work_dir/swift-keys.asc"
gpg --homedir "$work_dir/gnupg" --batch --status-fd 1 --verify "$archive.sig" "$archive" > "$work_dir/signature-status"
awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && $3 == "52BB7E3DE28A71BE22EC05FFEF80A866B47A981F" { valid=1 } END { exit !valid }' "$work_dir/signature-status"
mkdir "$work_dir/toolchain"
tar -xzf "$archive" --strip-components=1 -C "$work_dir/toolchain"
"$work_dir/toolchain/usr/bin/swift" --version
[[ ! -e "$toolchain_dir" ]] || { echo "Refusing to overwrite an existing different toolchain: $toolchain_dir" >&2; exit 1; }
mv "$work_dir/toolchain" "$toolchain_dir"
echo "Verified Swift installed at $toolchain_dir"
