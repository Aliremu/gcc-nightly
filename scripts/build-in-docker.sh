#!/usr/bin/env bash
# Runs scripts/build.sh inside a clean Debian container, so the archives link
# against the same glibc as the Docker images. Pass BUILD_TARGETS/JOBS as for
# build.sh. Build trees stay inside the container; archives land in dist/.
set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEBIAN_IMAGE="${DEBIAN_IMAGE:-debian:bookworm}"

docker run --rm --name "${CONTAINER_NAME:-gcc-build-$$}" \
    -v "$REPO:/src" -w /src \
    -e BUILD_TARGETS -e JOBS -e WORK=/work \
    -e HOST_OWNER="$(id -u):$(id -g)" \
    "$DEBIAN_IMAGE" bash -Eeuo pipefail -c '
        # Hand files created in the bind mount back to the caller.
        trap "chown -R \"\$HOST_OWNER\" /src/gcc /src/dist 2>/dev/null || true" EXIT
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends \
            build-essential ca-certificates curl wget git file m4 flex bison \
            texinfo python3 bzip2 xz-utils zstd zlib1g-dev \
            gcc-mingw-w64-x86-64-posix g++-mingw-w64-x86-64-posix \
            binutils-mingw-w64-x86-64 mingw-w64-x86-64-dev \
            gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
            binutils-aarch64-linux-gnu libc6-dev-arm64-cross
        git config --global --add safe.directory "*"
        scripts/build.sh
    '
