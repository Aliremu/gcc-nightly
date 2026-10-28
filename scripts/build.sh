#!/usr/bin/env bash
# Builds GCC toolchain archives from the gcc/ checkout into dist/.
# Runs on x86-64 Debian; CI runs it inside a debian container (see
# scripts/build-in-docker.sh), which also installs the needed packages.
set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${SOURCE:-$REPO/gcc}"
WORK="${WORK:-$REPO/work}"
OUT="${OUT:-$REPO/dist}"
JOBS="${JOBS:-$(nproc)}"
BUILD_TARGETS="${BUILD_TARGETS:-windows,windows-native,linux-native,linux-arm64}"
BINUTILS_VERSION="${BINUTILS_VERSION:-2.45.1}"
MINGW_SYSROOT="${MINGW_SYSROOT:-/usr/x86_64-w64-mingw32}"
export M4="${M4:-/usr/bin/m4}"
BUILD_PROFILE="mingw64-full-gcc-headers-v7"
NATIVE_WINDOWS_PROFILE="windows-hosted-gcc-with-binutils-v2"
NATIVE_LINUX_PROFILE="linux-native-gcc-with-stdlib-v1"
LINUX_ARM64_CROSS_PROFILE="linux-arm64-cross-gcc-with-stdlib-v5"
LINUX_ARM64_PROFILE="linux-arm64-hosted-gcc-v3"

[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || {
    echo "Run this script on x86-64 Debian." >&2; exit 1;
}
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || {
    echo "JOBS must be a positive integer." >&2; exit 1;
}
IFS=',' read -r -a selected_targets <<< "$BUILD_TARGETS"
for selected_target in "${selected_targets[@]}"; do
    case "$selected_target" in
        windows|windows-native|linux-native|linux-arm64) ;;
        *) echo "Unknown BUILD_TARGETS entry: $selected_target" >&2; exit 1 ;;
    esac
done
# The x86-64 binaries are linked against this system's glibc; the Docker
# images use the same Debian release.
. /etc/os-release
[[ "$ID" == debian ]] || { echo "The x86-64 builder must be Debian." >&2; exit 1; }
command -v zstd >/dev/null
command -v file >/dev/null
command -v readelf >/dev/null

[[ -f "$SOURCE/gcc/BASE-VER" ]] || {
    echo "No GCC source at $SOURCE; run scripts/fetch-gcc.sh first." >&2; exit 1;
}
COMMIT="$(git -C "$SOURCE" rev-parse --short=12 HEAD)"
mkdir -p "$WORK" "$OUT"
WORK="$(cd "$WORK" && pwd)"
OUT="$(cd "$OUT" && pwd)"

# Download GMP, MPFR, MPC and ISL into the source tree once.
if [[ ! -e "$SOURCE/gmp" ]]; then
    (cd "$SOURCE" && ./contrib/download_prerequisites)
fi

# A failed flex run can leave an empty generated lexer behind, and the gcc/
# build directory needs a .deps directory per source directory.
prepare_gcc_build_dir() {
    local build="$1"
    find "$build" -path '*/gcc/gengtype-lex.cc' -type f -size 0 -delete
    while IFS= read -r source_dir; do
        local relative_dir="${source_dir#"$SOURCE/gcc"}"
        mkdir -p "$build/gcc$relative_dir/.deps"
    done < <(find "$SOURCE/gcc" -type f \( -name '*.c' -o -name '*.cc' \) -printf '%h\n' | sort -u)
}

# Build trees cannot safely be reused after the source moves to a different
# commit, or after the configure profile changes.
reset_build_dir() {
    local build="$1" profile="$2"
    if [[ ! -f "$build/.source-commit" ]] || [[ "$(<"$build/.source-commit")" != "$COMMIT:$profile" ]]; then
        rm -rf "$build"
    fi
    mkdir -p "$build"
}

build_compiler_and_runtimes() {
    local build="$1" stage="$2"
    make -C "$build" configure-gcc
    prepare_gcc_build_dir "$build"

    make -C "$build" -j"$JOBS" all-gcc
    make -C "$build" -j"$JOBS" all-target-libgcc
    make -C "$build" -j"$JOBS" all-target-libatomic
    make -C "$build" -j"$JOBS" all-target-libgomp
    make -C "$build" -j"$JOBS" all-target-libstdc++-v3

    # Install to a staging directory, not into the host.
    rm -rf "$stage"
    mkdir -p "$stage"
    make -C "$build" install-gcc DESTDIR="$stage"
    make -C "$build" install-target-libgcc DESTDIR="$stage"
    make -C "$build" install-target-libatomic DESTDIR="$stage"
    make -C "$build" install-target-libgomp DESTDIR="$stage"
    make -C "$build" install-target-libstdc++-v3 DESTDIR="$stage"
}

build_windows_binutils() {
    local stage="$1"
    local source="$WORK/binutils-$BINUTILS_VERSION"
    local build="$WORK/build-binutils-windows-native"
    local archive="$WORK/binutils-$BINUTILS_VERSION.tar.xz"
    local profile="$BINUTILS_VERSION:windows-static-v1"
    if [[ ! -d "$source" ]]; then
        if [[ ! -f "$archive" ]]; then
            curl -fL --retry 3 \
                "https://ftp.gnu.org/gnu/binutils/binutils-$BINUTILS_VERSION.tar.xz" \
                -o "$archive.part"
            mv "$archive.part" "$archive"
        fi
        tar -C "$WORK" -xf "$archive"
    fi
    if [[ ! -f "$build/.profile" ]] || [[ "$(<"$build/.profile")" != "$profile" ]]; then
        rm -rf "$build"
    fi
    mkdir -p "$build"
    if [[ ! -f "$build/Makefile" ]]; then
        (
            cd "$build"
            CC=x86_64-w64-mingw32-gcc-posix \
            CXX=x86_64-w64-mingw32-g++-posix \
            CC_FOR_BUILD=gcc CXX_FOR_BUILD=g++ LDFLAGS=-static \
            "$source/configure" \
                --build="$("$source/config.guess")" \
                --host=x86_64-w64-mingw32 --target=x86_64-w64-mingw32 \
                --prefix=/gcc-trunk --disable-shared --enable-static \
                --disable-nls --disable-werror --disable-gdb \
                --disable-gprofng --disable-sim --disable-gold \
                --without-zstd --without-debuginfod --with-system-zlib=no
        )
        printf '%s\n' "$profile" > "$build/.profile"
    fi
    make -C "$build" -j"$JOBS" LDFLAGS=-static
    make -C "$build" install DESTDIR="$stage" LDFLAGS=-static
    # Make unprefixed tools available when gcc-trunk/bin is on Windows PATH.
    local tool
    for tool in as ld ar ranlib nm objcopy objdump strip size strings addr2line dlltool windres; do
        if [[ -f "$stage/gcc-trunk/bin/x86_64-w64-mingw32-$tool.exe" ]]; then
            cp -f "$stage/gcc-trunk/bin/x86_64-w64-mingw32-$tool.exe" \
                "$stage/gcc-trunk/bin/$tool.exe"
        fi
    done
    test -f "$stage/gcc-trunk/bin/as.exe"
    test -f "$stage/gcc-trunk/bin/ld.exe"
}

# Linux-hosted compiler targeting Windows (MinGW-w64).
build_windows() {
    local name=windows
    local build="$WORK/build-$name"
    local stage="$WORK/stage-$name"
    local prefix="/opt/gcc-trunk"

    # GCC's MinGW config always searches <sysroot>/mingw/{include,lib}, but
    # Debian installs the headers and libraries in <sysroot>/{include,lib}.
    local dir
    mkdir -p "$MINGW_SYSROOT/mingw"
    for dir in include lib; do
        if [[ ! -e "$MINGW_SYSROOT/mingw/$dir" ]]; then
            ln -s "../$dir" "$MINGW_SYSROOT/mingw/$dir"
        fi
    done

    reset_build_dir "$build" "$BUILD_PROFILE"
    if [[ ! -f "$build/Makefile" ]]; then
        (
            cd "$build"
            M4="$M4" "$SOURCE/configure" \
                --prefix="$prefix" \
                --target=x86_64-w64-mingw32 \
                --with-sysroot="$MINGW_SYSROOT" \
                --with-native-system-header-dir=/include \
                --with-as=/usr/bin/x86_64-w64-mingw32-as \
                --with-ld=/usr/bin/x86_64-w64-mingw32-ld \
                --enable-languages=c,c++ \
                --disable-shared \
                --enable-static \
                --enable-threads=posix \
                --with-system-zlib \
                --enable-libgomp \
                --enable-libatomic \
                --enable-graphite \
                --disable-libstdcxx-pch \
                --disable-libstdcxx-debug \
                --disable-multilib \
                --disable-lto \
                --disable-nls \
                --disable-werror \
                --enable-checking=release
        )
        printf '%s\n' "$COMMIT:$BUILD_PROFILE" > "$build/.source-commit"
    fi

    build_compiler_and_runtimes "$build" "$stage"

    local archive="$OUT/gcc-$name-$COMMIT.tar.zst"
    tar -C "$stage" -I 'zstd -T0' -cf "$archive" "${prefix#/}"
    echo "Created Linux-hosted Windows-targeting GCC artifact: $archive"
}

build_linux_native() {
    local name="linux-native"
    local build="$WORK/build-$name"
    local stage="$WORK/stage-$name"
    local prefix="/opt/gcc-trunk"

    reset_build_dir "$build" "$NATIVE_LINUX_PROFILE"
    if [[ ! -f "$build/Makefile" ]]; then
        (
            cd "$build"
            M4="$M4" "$SOURCE/configure" \
                --prefix="$prefix" \
                --enable-languages=c,c++ \
                --disable-shared \
                --enable-static \
                --enable-threads=posix \
                --with-system-zlib \
                --enable-libgomp \
                --enable-libatomic \
                --enable-graphite \
                --disable-libstdcxx-pch \
                --disable-libstdcxx-debug \
                --disable-multilib \
                --disable-lto \
                --disable-nls \
                --disable-werror \
                --enable-checking=release
        )
        printf '%s\n' "$COMMIT:$NATIVE_LINUX_PROFILE" > "$build/.source-commit"
    fi

    build_compiler_and_runtimes "$build" "$stage"

    if ! find "$stage$prefix" -type f -name 'libstdc++.a' -print -quit | grep -q .; then
        echo "Expected the Linux libstdc++ static runtime under $stage$prefix" >&2
        return 1
    fi
    if ! find "$stage$prefix/include/c++" -type f -path '*/bits/c++config.h' -print -quit | grep -q .; then
        echo "Expected the Linux libstdc++ headers under $stage$prefix/include/c++" >&2
        return 1
    fi

    # Verify the native Linux toolchain before packaging it.
    printf '%s\n' '#include <iostream>' 'int main(){std::cout << "ok\n";}' > "$build/smoke.cc"
    "$stage$prefix/bin/g++" -std=c++26 "$build/smoke.cc" -o "$build/smoke"
    "$build/smoke"

    local archive="$OUT/gcc-$name-$COMMIT.tar.zst"
    tar -C "$stage" -I 'zstd -T0' -cf "$archive" "${prefix#/}"
    echo "Created Linux-native GCC artifact: $archive"
}

# x86-64 -> aarch64 cross compiler; supplies the target runtimes for the native build.
build_linux_arm64_cross() {
    local target=aarch64-linux-gnu
    local build="$WORK/build-linux-arm64"
    local stage="$WORK/stage-linux-arm64"
    local prefix="/opt/gcc-trunk"
    local sysroot="${AARCH64_SYSROOT:-/usr/aarch64-linux-gnu}"
    local tool cross_as cross_ld

    for tool in aarch64-linux-gnu-gcc aarch64-linux-gnu-g++ aarch64-linux-gnu-as aarch64-linux-gnu-ld; do
        command -v "$tool" >/dev/null || {
            echo "Missing $tool; install gcc-aarch64-linux-gnu, g++-aarch64-linux-gnu, binutils-aarch64-linux-gnu, libc6-dev-arm64-cross." >&2
            return 1
        }
    done
    if [[ ! -d "$sysroot/include" || ! -d "$sysroot/lib" ]]; then
        echo "ARM64 sysroot must contain include/ and lib/: $sysroot (set AARCH64_SYSROOT)." >&2
        return 1
    fi

    # GNU ld's --sysroot expects sysroot/usr/{include,lib} for Linux targets.
    if [[ "$sysroot" == "/usr/aarch64-linux-gnu" && ! -e "$sysroot/usr/include" ]]; then
        mkdir -p "$sysroot/usr"
        ln -s ../include "$sysroot/usr/include"
        ln -s ../lib "$sysroot/usr/lib"
    fi
    if [[ "$sysroot" == "/usr/aarch64-linux-gnu" ]]; then
        local debian_cross_lib="$sysroot/usr/aarch64-linux-gnu/lib"
        local runtime_file
        mkdir -p "$debian_cross_lib"
        for runtime_file in libc.so.6 libc_nonshared.a ld-linux-aarch64.so.1; do
            if [[ -f "$sysroot/lib/$runtime_file" && ! -e "$debian_cross_lib/$runtime_file" ]]; then
                cp -a "$sysroot/lib/$runtime_file" "$debian_cross_lib/"
            fi
        done
    fi
    if [[ -f "$sysroot/lib/libatomic.so.1" && ! -e "$sysroot/lib/libatomic_asneeded.so" ]]; then
        ln -s libatomic.so.1 "$sysroot/lib/libatomic_asneeded.so"
    fi

    cross_as="$(command -v aarch64-linux-gnu-as)"
    cross_ld="$(command -v aarch64-linux-gnu-ld)"

    reset_build_dir "$build" "$LINUX_ARM64_CROSS_PROFILE"
    if [[ ! -f "$build/Makefile" ]]; then
        (
            cd "$build"
            M4="$M4" "$SOURCE/configure" \
                --prefix="$prefix" \
                --target="$target" \
                --with-sysroot="$sysroot" \
                --with-native-system-header-dir=/include \
                --with-as="$cross_as" \
                --with-ld="$cross_ld" \
                --enable-languages=c,c++ \
                --disable-shared \
                --enable-static \
                --enable-threads=posix \
                --with-system-zlib \
                --enable-libgomp \
                --enable-libatomic \
                --enable-graphite \
                --disable-libstdcxx-pch \
                --disable-libstdcxx-debug \
                --disable-multilib \
                --disable-lto \
                --disable-nls \
                --disable-werror \
                --enable-checking=release
        )
        printf '%s\n' "$COMMIT:$LINUX_ARM64_CROSS_PROFILE" > "$build/.source-commit"
    fi

    build_compiler_and_runtimes "$build" "$stage"

    if ! find "$stage$prefix/$target/include/c++" -type f -path '*/bits/c++config.h' -print -quit | grep -q .; then
        echo "Expected the ARM64 libstdc++ headers under $stage$prefix/$target/include/c++" >&2
        return 1
    fi
}

# ARM64-hosted GCC targeting ARM64, cross-built on x86-64 (no emulation).
build_linux_arm64() {
    local name=linux-arm64-native
    local target=aarch64-linux-gnu
    local build="$WORK/build-$name"
    local stage="$WORK/stage-$name"
    local prefix="/opt/gcc-trunk"
    local cross_prefix="$WORK/stage-linux-arm64$prefix"

    build_linux_arm64_cross

    reset_build_dir "$build" "$LINUX_ARM64_PROFILE"
    if [[ ! -f "$build/Makefile" ]]; then
        (
            cd "$build"
            M4="$M4" \
                CC=aarch64-linux-gnu-gcc \
                CXX=aarch64-linux-gnu-g++ \
                CC_FOR_BUILD=gcc \
                CXX_FOR_BUILD=g++ \
                LDFLAGS="-static" \
                "$SOURCE/configure" \
                --build="$("$SOURCE/config.guess")" \
                --host="$target" \
                --target="$target" \
                --prefix="$prefix" \
                --enable-multiarch \
                --enable-languages=c,c++ \
                --disable-shared \
                --enable-static \
                --enable-threads=posix \
                --disable-libstdcxx-pch \
                --disable-libstdcxx-debug \
                --disable-multilib \
                --disable-lto \
                --disable-nls \
                --disable-werror \
                --enable-checking=release
        )
        printf '%s\n' "$COMMIT:$LINUX_ARM64_PROFILE" > "$build/.source-commit"
    fi

    find "$build" -path '*/gcc/gengtype-lex.cc' -type f -size 0 -delete
    make -C "$build" -j"$JOBS" \
        CC=aarch64-linux-gnu-gcc \
        CXX=aarch64-linux-gnu-g++ \
        CC_FOR_BUILD=gcc \
        CXX_FOR_BUILD=g++ \
        LDFLAGS="-static" \
        all-gcc

    rm -rf "$stage"
    mkdir -p "$stage"
    make -C "$build" install-gcc DESTDIR="$stage" LDFLAGS="-static"

    # Target runtimes come from the x86-64-hosted cross build.
    cp -a "$cross_prefix/$target" "$stage$prefix/"
    rm -rf "$stage$prefix/$target/bin"
    # An arm64-hosted g++ looks in $prefix/include/c++ and $prefix/lib64, not $prefix/$target.
    mkdir -p "$stage$prefix/include" "$stage$prefix/lib" "$stage$prefix/lib64"
    cp -a "$stage$prefix/$target/include/c++" "$stage$prefix/include/"
    cp -a "$stage$prefix/$target/lib/." "$stage$prefix/lib/"
    cp -a "$stage$prefix/$target/lib64/." "$stage$prefix/lib64/"
    local gcc_version
    gcc_version="$("$cross_prefix/bin/$target-gcc" -dumpfullversion)"
    local target_lib_dir="lib/gcc/$target/$gcc_version"
    mkdir -p "$stage$prefix/$target_lib_dir"
    find "$cross_prefix/$target_lib_dir" -maxdepth 1 -type f \( -name '*.a' -o -name '*.o' \) \
        -exec cp -a -t "$stage$prefix/$target_lib_dir" {} +

    file "$stage$prefix/bin/gcc" | grep -q 'ARM aarch64'
    file "$stage$prefix/bin/g++" | grep -q 'ARM aarch64'
    if ! find "$stage$prefix" -type f -name 'libstdc++.a' -print -quit | grep -q .; then
        echo "Expected the ARM64 libstdc++ static runtime under $stage$prefix" >&2
        return 1
    fi

    local archive="$OUT/gcc-$name-$COMMIT.tar.zst"
    tar -C "$stage" -I 'zstd -T0' -cf "$archive" "${prefix#/}"
    echo "Created ARM64-hosted GCC artifact: $archive"
}

build_windows_native() {
    local build="$WORK/build-windows-native"
    local stage="$WORK/stage-windows-native"
    local prefix="/gcc-trunk"

    # This is a cross build of a native Windows compiler: Linux builds GCC hosted on
    # Windows, which in turn target Windows. Runtime libraries are built in the
    # Linux-hosted cross build, then copied into this Windows-hosted toolchain.
    reset_build_dir "$build" "$NATIVE_WINDOWS_PROFILE"
    if [[ ! -f "$build/Makefile" ]]; then
        (
            cd "$build"
            M4="$M4" \
                CC=x86_64-w64-mingw32-gcc-posix \
                CXX=x86_64-w64-mingw32-g++-posix \
                CC_FOR_BUILD=gcc \
                CXX_FOR_BUILD=g++ \
                LDFLAGS="-static" \
                "$SOURCE/configure" \
                --build="$("$SOURCE/config.guess")" \
                --host=x86_64-w64-mingw32 \
                --target=x86_64-w64-mingw32 \
                --prefix="$prefix" \
                --enable-languages=c,c++ \
                --disable-shared \
                --enable-static \
                --enable-threads=posix \
                --disable-libstdcxx-pch \
                --disable-libstdcxx-debug \
                --disable-multilib \
                --disable-lto \
                --disable-nls \
                --disable-werror \
                --enable-checking=release
        )
        printf '%s\n' "$COMMIT:$NATIVE_WINDOWS_PROFILE" > "$build/.source-commit"
    fi

    find "$build" -path '*/gcc/gengtype-lex.cc' -type f -size 0 -delete
    make -C "$build" -j"$JOBS" \
        CC=x86_64-w64-mingw32-gcc-posix \
        CXX=x86_64-w64-mingw32-g++-posix \
        CC_FOR_BUILD=gcc \
        CXX_FOR_BUILD=g++ \
        LDFLAGS="-static" \
        all-gcc

    rm -rf "$stage"
    mkdir -p "$stage"
    make -C "$build" install-gcc DESTDIR="$stage" LDFLAGS="-static"

    local cross_prefix="$WORK/stage-windows/opt/gcc-trunk"
    if [[ ! -d "$cross_prefix/x86_64-w64-mingw32/include/c++" ]]; then
        echo "Windows target runtime not found under $cross_prefix; build the windows target first" >&2
        return 1
    fi

    mkdir -p "$stage$prefix/x86_64-w64-mingw32"
    # Dereference Debian's header/library symlinks to make the Windows archive portable.
    cp -aL "$MINGW_SYSROOT/include" "$stage$prefix/x86_64-w64-mingw32/"
    cp -aL "$MINGW_SYSROOT/lib" "$stage$prefix/x86_64-w64-mingw32/"
    cp -a "$cross_prefix/x86_64-w64-mingw32/." "$stage$prefix/x86_64-w64-mingw32/"
    # A Windows-hosted compiler must not contain Linux /usr/bin executables.
    rm -rf "$stage$prefix/x86_64-w64-mingw32/bin"

    local gcc_version
    gcc_version="$("$cross_prefix/bin/x86_64-w64-mingw32-gcc" -dumpfullversion)"
    local target_lib_dir="lib/gcc/x86_64-w64-mingw32/$gcc_version"
    local cross_lib="$cross_prefix/$target_lib_dir"
    local native_lib="$stage$prefix/$target_lib_dir"
    mkdir -p "$native_lib"
    find "$cross_lib" -maxdepth 1 -type f \( -name '*.a' -o -name '*.o' \) \
        -exec cp -a -t "$native_lib" {} +

    local installed_bin="$stage$prefix/bin"
    if ! find "$installed_bin" -maxdepth 1 -type f -name '*gcc*.exe' -print -quit | grep -q .; then
        echo "Expected a Windows GCC executable under $installed_bin" >&2
        return 1
    fi

    if ! find "$stage$prefix" -type f -name 'libstdc++.a' -print -quit | grep -q .; then
        echo "Expected the Windows libstdc++ static runtime under $stage$prefix" >&2
        return 1
    fi

    if ! find "$stage$prefix/x86_64-w64-mingw32/include/c++" -type f -path '*/bits/c++config.h' -print -quit | grep -q .; then
        echo "Expected the Windows libstdc++ headers under $stage$prefix/x86_64-w64-mingw32/include/c++" >&2
        return 1
    fi

    # Supply MinGW's POSIX threading DLL for programs that use it.
    find "$MINGW_SYSROOT" -type f -iname '*.dll' \
        -exec cp -f -t "$stage$prefix/bin" {} +
    # Add Windows-native assembler/linker and other binutils executables.
    build_windows_binutils "$stage"
    local tool
    for tool in gcc g++ as ld; do
        file "$stage$prefix/bin/$tool.exe" | grep -q 'PE32+.*x86-64'
    done
    find "$stage$prefix/bin" -maxdepth 1 -type f -name '*.exe' -exec file {} +
    # Linux can inspect these PE files, but cannot run them natively.
    if find "$stage$prefix" -type l -lname '/*' -print -quit | grep -q .; then
        echo "Windows archive contains an absolute symlink; inspect $stage$prefix" >&2
        return 1
    fi

    local archive="$OUT/gcc-windows-native-$COMMIT.tar.zst"
    # Windows extraction should not require creating Unix symlinks.
    tar -h -C "$stage" -I 'zstd -T0' -cf "$archive" "${prefix#/}"
    echo "Created Windows-hosted GCC artifact: $archive"
}

build_selected() {
    case ",$BUILD_TARGETS," in
        *,"$1",*) return 0 ;;
        *) return 1 ;;
    esac
}

# The Windows-hosted GCC reuses target runtimes from the Linux-to-Windows build.
if build_selected windows || build_selected windows-native; then
    build_windows
fi
if build_selected windows-native; then
    build_windows_native
fi
if build_selected linux-native; then
    build_linux_native
fi
if build_selected linux-arm64; then
    build_linux_arm64
fi
printf 'Finished GCC commit %s\nArchives: %s\n' "$COMMIT" "$OUT"
ls -l "$OUT"
