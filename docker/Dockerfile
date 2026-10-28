# syntax=docker/dockerfile:1
# Runnable Debian image with a prebuilt GCC under /opt/gcc-trunk.
# The build context holds the archives renamed to <TOOLCHAIN>.tar.zst:
#   linux-amd64 (linux-native), linux-arm64 (linux-arm64-native), windows.
ARG BASE_IMAGE=debian:bookworm

# Unpack natively on the build host, even for an emulated target platform.
FROM --platform=$BUILDPLATFORM ${BASE_IMAGE} AS unpack
RUN apt-get update && apt-get install -y --no-install-recommends zstd \
    && rm -rf /var/lib/apt/lists/*
ARG TARGETARCH
ARG TOOLCHAIN=linux-${TARGETARCH}
COPY ${TOOLCHAIN}.tar.zst /tmp/gcc.tar.zst
RUN mkdir /out && tar -C /out -I zstd -xf /tmp/gcc.tar.zst

FROM ${BASE_IMAGE}
ARG TARGETARCH
ARG TOOLCHAIN=linux-${TARGETARCH}
ARG GCC_COMMIT
ARG GCC_VERSION
LABEL org.opencontainers.image.title="GCC ${GCC_VERSION} (${TOOLCHAIN})" \
      org.opencontainers.image.version="${GCC_VERSION}" \
      dev.gcc.commit="${GCC_COMMIT}"
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates binutils libc6-dev zlib1g libzstd1 make \
    && if [ "$TOOLCHAIN" = windows ]; then \
         apt-get install -y --no-install-recommends \
           binutils-mingw-w64-x86-64 mingw-w64-x86-64-dev \
         # The compiler searches <sysroot>/mingw/{include,lib} for MinGW files.
         && mkdir -p /usr/x86_64-w64-mingw32/mingw \
         && ln -s ../include /usr/x86_64-w64-mingw32/mingw/include \
         && ln -s ../lib /usr/x86_64-w64-mingw32/mingw/lib; \
       fi \
    && rm -rf /var/lib/apt/lists/*
COPY --from=unpack /out/opt/gcc-trunk /opt/gcc-trunk
RUN if [ "$TOOLCHAIN" = windows ]; then \
      ln -sf x86_64-w64-mingw32-gcc /opt/gcc-trunk/bin/gcc; \
      ln -sf x86_64-w64-mingw32-g++ /opt/gcc-trunk/bin/g++; \
    fi
ENV PATH=/opt/gcc-trunk/bin:${PATH} \
    CC=/opt/gcc-trunk/bin/gcc \
    CXX=/opt/gcc-trunk/bin/g++
RUN printf '%s\n' '#include <iostream>' 'int main(){std::cout << "ok\n";}' > /tmp/t.cc \
    && if [ "$TOOLCHAIN" = windows ]; then \
         g++ -std=c++26 -static /tmp/t.cc -o /tmp/t.exe; \
         od -An -tx1 -N2 /tmp/t.exe | tr -d ' \n' | grep -qx 4d5a; \
       else \
         g++ -std=c++26 /tmp/t.cc -o /tmp/t && /tmp/t; \
       fi \
    && rm -f /tmp/t /tmp/t.exe /tmp/t.cc
CMD ["g++", "--version"]
