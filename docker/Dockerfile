# Prebuilt build image for the android-ndk-custom builds. Bakes the build tools
# and the zig / llvm-mingw / zig-as-llvm toolchains so CI only pulls (fast).
# The build scripts are NOT copied in — they are bind-mounted from the checkout
# at run time, so editing scripts/ needs no image rebuild.
#
#   docker run --rm -v "$PWD:/work" -w /work \
#     -e PLATFORM=bionic -e TARGET=x86_64-linux-android -e NDK_VERSION=30 \
#     ghcr.io/<owner>/ndk-builder \
#     bash -c 'scripts/make-ndk.sh'
FROM ubuntu:24.04

ARG ZIG_VERSION=0.17.0-dev.304+9787df942
ARG LLVM_MINGW_VERSION=20260505
ARG REPO_OWNER=HomuHomu833

ENV DEBIAN_FRONTEND=noninteractive
# python3.11 is the *build* interpreter for cross-compiling target CPython 3.11.4
# (configure --with-build-python); 24.04 ships 3.12, so pull 3.11 from deadsnakes.
# p7zip-full provides 7z for the windows NDK archive.
RUN apt-get update && apt-get install -y --no-install-recommends software-properties-common \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils unzip git make cmake ninja-build \
        build-essential file p7zip-full python3 python3.11 \
    && rm -rf /var/lib/apt/lists/*

# zig (provides the cross C/C++ toolchain for linux/bsd targets)
RUN curl -fSL "https://ziglang.org/builds/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
      | tar -xJ -C /opt \
    && mv "/opt/zig-x86_64-linux-${ZIG_VERSION}" /opt/zig \
    && chmod -R a+w /opt/zig/lib   # make-ndk.sh overlays patches/musl/zig here at run time (non-root)

# llvm-mingw (windows targets)
RUN curl -fSL "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-x86_64.tar.xz" \
      | tar -xJ -C /opt \
    && mv "/opt/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-x86_64" /opt/llvm-mingw

# zig-as-llvm: thin cc/c++/ar/... wrappers around zig, keyed off $ZIG_TARGET.
# The wrappers `exec zig ...`, so zig must be on PATH (below) for linux/bsd builds.
RUN git clone --depth 1 "https://github.com/${REPO_OWNER}/zig-as-llvm" /opt/zig-as-llvm

# zig on PATH so the zig-as-llvm wrappers resolve it. llvm-mingw is intentionally
# *not* on PATH — the windows branch calls it by absolute path, and keeping its
# windows-targeting clang off PATH avoids it shadowing the zig toolchain.
ENV PATH="/opt/zig:${PATH}"

WORKDIR /work
