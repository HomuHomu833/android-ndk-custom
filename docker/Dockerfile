# Prebuilt build image for android-ndk-custom. Bakes the build tools and the
# zig / llvm-mingw / zig-as-llvm / osxcross toolchains so CI only pulls.
# zig: linux/bsd host tools; llvm-mingw: windows; osxcross (cctools-port):
# macOS (zig segfaults on macOS binaries).
# Build scripts are bind-mounted from the checkout at run time, not copied in.
#
#   docker run --rm -v "$PWD:/work" -w /work \
#     -e PLATFORM=bionic -e TARGET=x86_64-linux-android -e NDK_VERSION=30 \
#     ghcr.io/<owner>/ndk-builder \
#     bash -c 'scripts/make-ndk.sh'
FROM ubuntu:24.04

ARG ZIG_VERSION=0.17.0-dev.857+2b2b85c5f
ARG LLVM_MINGW_VERSION=20260505
ARG REPO_OWNER=HomuHomu833
ARG MACOS_SDK_VERSION=15.5

ENV DEBIAN_FRONTEND=noninteractive
# python3.11: build interpreter for cross-compiling CPython 3.11.4 (24.04 ships
#   3.12, so pull 3.11 from deadsnakes).
# p7zip-full: 7z for the windows NDK archive.
# autoconf-archive + pkg-config: needed by the windows autoreconf.
RUN apt-get update && apt-get install -y --no-install-recommends software-properties-common \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates aria2 xz-utils unzip git make cmake ninja-build \
        build-essential file p7zip-full python3 python3.11 \
        autoconf automake libtool autoconf-archive pkg-config \
        clang lld zlib1g-dev libssl-dev libxml2-dev liblzma-dev libbz2-dev uuid-dev cpio bzip2 \
    && rm -rf /var/lib/apt/lists/*

# fetch: download with retries, re-running aria2c on any failure so transient
# GitHub errors recover. make-ndk.sh defines an identical helper for standalone
# runs.
RUN printf '%s\n' '#!/bin/sh' \
    'i=0; until aria2c --console-log-level=error --check-certificate=false --max-tries=5 --retry-wait=2 --connect-timeout=15 "$@"; do' \
    '  i=$((i+1)); [ "$i" -ge 5 ] && { echo "fetch: giving up after $i attempts" >&2; exit 1; }' \
    '  echo "fetch: aria2c failed, retry $i/5 in 2s..." >&2; sleep 2' \
    'done' > /usr/local/bin/fetch && chmod +x /usr/local/bin/fetch

# qemu-user-static + x86_64 libs so the NDK's prebuilt binaries run on non-x86 hosts
RUN arch="$(uname -m)"; \
    if [ "$arch" != x86_64 ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            qemu-user-static libc6-amd64-cross \
        && rm -rf /var/lib/apt/lists/* \
        && fetch --dir=/tmp -o zlib.deb \
            "http://archive.ubuntu.com/ubuntu/pool/main/z/zlib/zlib1g_1.3.dfsg-3.1ubuntu2.1_amd64.deb" \
        && dpkg-deb -x /tmp/zlib.deb /tmp/zlib \
        && cp -a /tmp/zlib/usr/lib/x86_64-linux-gnu/* /usr/x86_64-linux-gnu/lib/ \
        && rm -rf /tmp/zlib.deb /tmp/zlib \
        && fetch --dir=/tmp -o gcc.deb \
            "http://archive.ubuntu.com/ubuntu/pool/main/g/gcc-14/libgcc-s1_14.2.0-4ubuntu2~24.04.1_amd64.deb" \
        && dpkg-deb -x /tmp/gcc.deb /tmp/gcc \
        && cp -a /tmp/gcc/usr/lib/x86_64-linux-gnu/* /usr/x86_64-linux-gnu/lib/ \
        && rm -rf /tmp/gcc.deb /tmp/gcc; \
    fi

# zig (provides the cross C/C++ toolchain for linux/bsd targets)
RUN arch="$(uname -m)"; \
    case "$arch" in \
        x86_64)       zig_arch="x86_64" ;; \
        aarch64)      zig_arch="aarch64" ;; \
        armv7l|armv8l) zig_arch="arm" ;; \
        riscv64)      zig_arch="riscv64" ;; \
        ppc64le)      zig_arch="powerpc64le" ;; \
        i686|i386)    zig_arch="x86" ;; \
        loongarch64)  zig_arch="loongarch64" ;; \
        s390x)        zig_arch="s390x" ;; \
        *) echo "WARNING: unsupported zig host arch '$arch'; skipping zig and zig-as-llvm"; touch /opt/.no-zig ;; \
    esac; \
    if [ ! -f /opt/.no-zig ]; then \
        case "$ZIG_VERSION" in \
            *dev*) zig_base="https://ziglang.org/builds" ;;        \
            *)     zig_base="https://ziglang.org/download/${ZIG_VERSION}" ;; \
        esac; \
        fetch --dir=/tmp -o zig.tar.xz \
            "${zig_base}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz" \
        && tar -xJf /tmp/zig.tar.xz -C /opt \
        && rm /tmp/zig.tar.xz \
        && mv "/opt/zig-${zig_arch}-linux-${ZIG_VERSION}" /opt/zig \
        && chmod -R a+w /opt/zig/lib; \
    fi   # make-ndk.sh overlays patches/musl/zig here at run time (non-root)

# llvm-mingw (windows targets; only x86_64 / aarch64 linux hosts)
RUN arch="$(uname -m)"; \
    case "$arch" in \
        x86_64|aarch64) \
            fetch --dir=/tmp -o llvm-mingw.tar.xz \
                "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-${arch}.tar.xz" \
            && tar -xJf /tmp/llvm-mingw.tar.xz -C /opt \
            && rm /tmp/llvm-mingw.tar.xz \
            && mv "/opt/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-${arch}" /opt/llvm-mingw ;; \
        *) echo "WARNING: llvm-mingw does not support host arch '$arch'; Windows cross-builds will be unavailable" ;; \
    esac

# zig-as-llvm: thin cc/c++/ar/... wrappers around zig, keyed off $ZIG_TARGET.
# The wrappers `exec zig ...`, so zig must be on PATH (below) for linux/bsd builds.
RUN if [ ! -f /opt/.no-zig ]; then \
        git clone --depth 1 "https://github.com/${REPO_OWNER}/zig-as-llvm" /opt/zig-as-llvm; \
    fi

# zig on PATH so the zig-as-llvm wrappers resolve it. llvm-mingw stays off PATH
# (called by absolute path) so its clang doesn't shadow zig.
ENV QEMU_LD_PREFIX=/usr/x86_64-linux-gnu

ENV PATH="/opt/zig:${PATH}"

# osxcross -> /opt/osxcross: macOS cross toolchain (cctools-port + clang
# wrappers) with the SDK baked into /opt/osxcross/SDK. make-ndk.sh points the
# darwin tools at the arch-prefixed wrappers in /opt/osxcross/bin. Only the
# target arches (x86_64/x86_64h/arm64/arm64e) are built to keep it quick.
ARG OSXCROSS_REF=master
RUN git clone https://github.com/tpoechtrager/osxcross /tmp/osxcross \
    && git -C /tmp/osxcross checkout "$OSXCROSS_REF" \
    && fetch \
        --dir=/tmp/osxcross/tarballs -o "MacOSX${MACOS_SDK_VERSION}.sdk.tar.xz" \
        "https://github.com/joseluisq/macosx-sdks/releases/download/${MACOS_SDK_VERSION}/MacOSX${MACOS_SDK_VERSION}.sdk.tar.xz" \
    && cd /tmp/osxcross \
    && UNATTENDED=1 ENABLE_ARCHS="x86_64 x86_64h arm64 arm64e" OSX_VERSION_MIN=11.0 \
       TARGET_DIR=/opt/osxcross ./build.sh \
    && cd / \
    && rm -rf /tmp/osxcross

WORKDIR /work
