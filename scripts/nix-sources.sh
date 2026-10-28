#!/usr/bin/env bash
# Writes nix/sources/<system>.json for the Linux-hosted archives in a directory,
# which point flake.nix at the prebuilt archives.
# Usage: scripts/nix-sources.sh <archive-dir> <base-url> <gcc-version>
#   e.g. scripts/nix-sources.sh dist https://github.com/o/r/releases/download/T 17.0.0
#        scripts/nix-sources.sh dist "file://$PWD/dist" 17.0.0   (local testing)
set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dir="$1" base_url="${2%/}" version="$3"

write_source() {
    local system="$1" name="$2"
    local archive
    archive="$(find "$dir" -maxdepth 1 -name "gcc-$name-*.tar.zst" -print -quit)"
    [[ -n "$archive" ]] || return 0
    local file="${archive##*/}"
    local commit="${file#"gcc-$name-"}"
    commit="${commit%.tar.zst}"
    mkdir -p "$REPO/nix/sources"
    printf '{\n  "file": "%s",\n  "url": "%s",\n  "sha256": "%s",\n  "version": "%s",\n  "commit": "%s"\n}\n' \
        "$file" "$base_url/$file" "$(sha256sum "$archive" | cut -d' ' -f1)" \
        "$version" "$commit" > "$REPO/nix/sources/$system.json"
    echo "Wrote nix/sources/$system.json for $file"
}

write_source x86_64-linux linux-native
write_source aarch64-linux linux-arm64-native
