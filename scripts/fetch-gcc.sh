#!/usr/bin/env bash
# Shallow-fetches a GCC branch, tag or full commit hash into the gcc/ submodule.
# Usage: scripts/fetch-gcc.sh [ref]   (default: master, i.e. trunk)
set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF="${1:-master}"

if [[ ! -e "$REPO/gcc/.git" ]]; then
    git -C "$REPO" submodule update --init --depth 1 gcc
fi
git -C "$REPO/gcc" fetch --depth 1 origin "$REF"
git -C "$REPO/gcc" checkout --quiet --detach FETCH_HEAD
git -C "$REPO/gcc" log -1 --format='GCC %H (%cd)'
