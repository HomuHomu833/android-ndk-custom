#!/usr/bin/env bash
# Assemble one Android NDK for a single cross target. Driven entirely by env vars
# so it runs identically in CI and in `docker run`.
#
#   PLATFORM    bionic | linux | bsd | windows
#   TARGET      target triple, e.g.
#                 aarch64-linux-android        (bionic)
#                 x86_64-linux-gnu / -musl     (linux)
#                 aarch64-freebsd-none         (bsd)
#                 x86_64-w64-mingw32           (windows)
#   NDK_VERSION   required (e.g. 30)
#   NDK_REVISION  optional (e.g. b)
#   ANDROID_PLATFORM  bionic API level (default 25, riscv64 forced to 35)
#   ROOTDIR     work dir = checkout root (default: cwd); holds sources/ config/
#               patches/ binaries/. HOME is also set here in CI.
#   REPO_OWNER  GitHub owner for the llvm-custom release download (default HomuHomu833)
#
# Steps mirror the old make_ndk_*.yml workflows 1:1: build make/yasm/shaderc/python,
# download the matching llvm-custom toolchain, splice everything into the official
# NDK, then archive (xz; 7z for windows).
set -euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
ROOT="$ROOTDIR"                       # repo assets: sources/ config/ patches/ binaries/
: "${PLATFORM:?set PLATFORM}" "${TARGET:?set TARGET}" "${NDK_VERSION:?set NDK_VERSION}"
NDK_REVISION="${NDK_REVISION:-}"
REPO_OWNER="${REPO_OWNER:-HomuHomu833}"
BUILD="${BUILD:-$ROOTDIR/build}"      # scratch for tool source trees (NOT the checkout root)

NDK_NAME="android-ndk-r${NDK_VERSION}${NDK_REVISION}"
NDK_TAG="ndk-r${NDK_VERSION}${NDK_REVISION}"
MAKE_VERSION=4.4
LLVM_PKG="${LLVM_PKG:-bolt+clang+clang-tools-extra+lld}"
SHADERC_BASE="https://android.googlesource.com/platform/external/shaderc"

mkdir -p "$BUILD"
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ncpu() { nproc 2>/dev/null || echo 4; }

# Lowercased BSD system name (FreeBSD/NetBSD/OpenBSD) derived from the triple,
# matching the old workflow's char-twiddling on field 2 of the triple.
bsd_system_name() {
  local field first middle last
  field=$(echo "$TARGET" | cut -d- -f2)
  first=${field:0:1}; middle=${field:1:${#field}-4}; last=${field: -3}
  echo "$(tr '[:lower:]' '[:upper:]' <<<"$first")$middle$(tr '[:lower:]' '[:upper:]' <<<"$last")"
}

# --- download the official NDK(s) ------------------------------------------
download_official_ndk() {
  local base="https://dl.google.com/android/repository/${NDK_NAME}"
  log "Downloading official NDK (linux)"
  aria2c --max-tries=20 --retry-wait=2 --connect-timeout=15 --dir="$BUILD" -o ndk-linux.zip "${base}-linux.zip"
  unzip -qq "$BUILD/ndk-linux.zip" -d "$BUILD/ndk-linux"
  rm -f "$BUILD/ndk-linux.zip"
  LINUX_NDK="$BUILD/ndk-linux/$NDK_NAME"
  NDK_LLVM_BIN="$LINUX_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"

  if [ "$PLATFORM" = windows ]; then
    log "Downloading official NDK (windows)"
    aria2c --max-tries=20 --retry-wait=2 --connect-timeout=15 --dir="$BUILD" -o ndk-windows.zip "${base}-windows.zip"
    unzip -qq "$BUILD/ndk-windows.zip" -d "$ROOTDIR/ndk-windows"
    rm -f "$BUILD/ndk-windows.zip"
    NDK="$ROOTDIR/ndk-windows/$NDK_NAME"
  else
    NDK="$LINUX_NDK"
  fi

  # yasm version comes from the official NDK's (linux) prebuilt yasm
  YASM_VERSION=$("$LINUX_NDK/prebuilt/linux-x86_64/bin/yasm" --version | sed -n '1s/.*yasm \([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p')
}

# --- toolchain selection (mirrors build.sh's case "$PLATFORM") -------------
setup_toolchain() {
  STATIC=""; STATIC_LD=""; SYSTEM_NAME=Linux
  case "$PLATFORM" in
    bionic)
      API="${ANDROID_PLATFORM:-25}"; [ "$TARGET" = riscv64-linux-android ] && API=35
      TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
      CROSS_CC="$TC/bin/${TARGET}${API}-clang"; CROSS_CXX="${CROSS_CC}++"
      CROSS_LD="$TC/bin/ld"; CROSS_AR="$TC/bin/llvm-ar"; CROSS_RANLIB="$TC/bin/llvm-ranlib"
      CROSS_STRIP="$TC/bin/llvm-strip"; CROSS_OBJCOPY="$TC/bin/llvm-objcopy"
      NDK_HOST=linux-x86_64
      ;;
    linux)
      TC=/opt/zig-as-llvm; export ZIG_TARGET="$TARGET"
      # overlay the musl libc source fixes onto zig's bundled musl (lib is a+w)
      [ -d "$ROOT/patches/musl/zig" ] && cp -R "$ROOT/patches/musl/zig/." /opt/zig/ || true
      CROSS_CC="$TC/bin/cc"; CROSS_CXX="$TC/bin/c++"; CROSS_LD="$TC/bin/ld"; CROSS_AR="$TC/bin/ar"
      CROSS_RANLIB="$TC/bin/ranlib"; CROSS_STRIP="$TC/bin/strip"; CROSS_OBJCOPY="$TC/bin/objcopy"
      NDK_HOST=linux-x86_64
      case "$TARGET" in
        *musl*) STATIC="-static"; STATIC_LD="-static" ;;
        *)      STATIC="";        STATIC_LD="-static-libstdc++ -static-libgcc" ;;
      esac
      ;;
    bsd)
      TC=/opt/zig-as-llvm; export ZIG_TARGET="$TARGET"
      CROSS_CC="$TC/bin/cc"; CROSS_CXX="$TC/bin/c++"; CROSS_LD="$TC/bin/ld"; CROSS_AR="$TC/bin/ar"
      CROSS_RANLIB="$TC/bin/ranlib"; CROSS_STRIP="$TC/bin/strip"; CROSS_OBJCOPY="$TC/bin/objcopy"
      NDK_HOST=linux-x86_64
      SYSTEM_NAME="$(bsd_system_name)"
      ;;
    windows)
      TC=/opt/llvm-mingw
      CROSS_CC="$TC/bin/${TARGET}-clang"; CROSS_CXX="$TC/bin/${TARGET}-clang++"; CROSS_LD="$TC/bin/${TARGET}-ld"
      CROSS_AR="$TC/bin/${TARGET}-ar"; CROSS_RANLIB="$TC/bin/${TARGET}-ranlib"
      CROSS_STRIP="$TC/bin/${TARGET}-strip"; CROSS_OBJCOPY="$TC/bin/${TARGET}-objcopy"
      NDK_HOST=windows-x86_64; SYSTEM_NAME=Windows
      ;;
    *) echo "Unknown PLATFORM='$PLATFORM'" >&2; exit 1 ;;
  esac
  NDK_TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$NDK_HOST"
}

# --- GNU Make ---------------------------------------------------------------
build_make() {
  log "Building GNU Make $MAKE_VERSION"
  ( cd "$BUILD"
    tar -xzf "$ROOT/sources/make-$MAKE_VERSION.tar.gz"
    rm -rf make; mv "make-$MAKE_VERSION" make
    cd make
    if [ "$PLATFORM" = windows ]; then
      git init --quiet
      for p in "$ROOT"/patches/windows/make/*.patch; do git apply "$p" || true; done
      rm -rf .git
    fi
    cp "$ROOT/config/config.sub" "$ROOT/config/config.guess" build-aux/
    local args=( --prefix="$PWD/build" --build=x86_64-linux-gnu --host="$TARGET"
                 CC="$CROSS_CC" CXX="$CROSS_CXX" LD="$CROSS_LD" OBJCOPY="$CROSS_OBJCOPY" AR="$CROSS_AR" RANLIB="$CROSS_RANLIB" STRIP="$CROSS_STRIP" )
    case "$PLATFORM" in
      bionic)  args+=( --disable-posix-spawn
                       CFLAGS="-Wno-error=implicit-function-declaration"
                       CXXFLAGS="-Wno-error=implicit-function-declaration"
                       LDFLAGS="-static-libstdc++ -static-libgcc"
                       ac_cv_lib_elf_elf_begin=no am_cv_func_iconv=no ac_cv_func_pselect=yes ) ;;
      linux)   args+=( CFLAGS="-Wno-error=incompatible-pointer-types $STATIC"
                       CXXFLAGS="-Wno-error=incompatible-pointer-types $STATIC"
                       LDFLAGS="$STATIC_LD" )

        case "$TARGET" in
          *musl*)
               args+=( ac_cv_func_setgid=no ac_cv_func_setresgid=no
                       ac_cv_func_setresuid=no ac_cv_func_setreuid=no
                       ac_cv_func_setregid=no ac_cv_func_setuid=no
                       ac_cv_func_seteuid=no ac_cv_func_setfsgid=no
                       ac_cv_func_setfsuid=no ac_cv_func_setegid=no
                       ac_cv_func_getloadavg=no ac_cv_have_decl_getloadavg=no) ;;
        esac
        ;;
      bsd)     args+=( CFLAGS="-Wno-error=incompatible-pointer-types"
                       CXXFLAGS="-Wno-error=incompatible-pointer-types" ) ;;
      windows) args+=( CFLAGS="-Wno-error=implicit-function-declaration"
                       CXXFLAGS="-Wno-error=implicit-function-declaration" ) ;;
    esac
    ./configure "${args[@]}"
    make -j"$(ncpu)" install
  )
}

# --- yasm -------------------------------------------------------------------
build_yasm() {
  log "Building yasm $YASM_VERSION"
  ( cd "$BUILD"
    tar -xzf "$ROOT/sources/yasm-$YASM_VERSION.tar.gz"
    rm -rf yasm; mv "yasm-$YASM_VERSION" yasm
    cd yasm
    cp "$ROOT/config/config.sub" "$ROOT/config/config.guess" config/
    local args=( --prefix="$PWD/build" --build=x86_64-linux-gnu --host="$TARGET" --disable-nls
                 CC="$CROSS_CC" CXX="$CROSS_CXX" LD="$CROSS_LD" OBJCOPY="$CROSS_OBJCOPY" AR="$CROSS_AR" RANLIB="$CROSS_RANLIB" STRIP="$CROSS_STRIP" )
    case "$PLATFORM" in
      bionic)  args+=( LDFLAGS="-static-libstdc++ -static-libgcc" ) ;;
      linux)    args+=( CFLAGS="-fwrapv -Wno-error=date-time $STATIC"
                       CXXFLAGS="-fwrapv -Wno-error=date-time $STATIC"
                       LDFLAGS="$STATIC_LD" ) ;;
      bsd)     args+=( CFLAGS="-fwrapv" CXXFLAGS="-fwrapv" ) ;;
      windows) args+=( CFLAGS="-Wno-error=implicit-function-declaration -fwrapv -Wno-error=date-time"
                       CXXFLAGS="-Wno-error=implicit-function-declaration -fwrapv -Wno-error=date-time" ) ;;
    esac
    ./configure "${args[@]}"
    make -j"$(ncpu)" install
  )
}

# --- SPIRV-Tools + shaderc --------------------------------------------------
build_shaderc() {
  log "Building shaderc"
  local SH="$BUILD/shaderc"
  rm -rf "$SH"; mkdir -p "$SH"
  ( cd "$SH" && aria2c --console-log-level=error --check-certificate=false --max-tries=5 --retry-wait=2 --connect-timeout=15 --dir=/tmp -o shaderc.tar.gz "$SHADERC_BASE/shaderc/+archive/refs/tags/$NDK_TAG.tar.gz" && tar -xzf /tmp/shaderc.tar.gz && rm /tmp/shaderc.tar.gz )
  mkdir -p "$SH/third_party/spirv-tools"
  ( cd "$SH/third_party/spirv-tools" && aria2c --console-log-level=error --check-certificate=false --max-tries=5 --retry-wait=2 --connect-timeout=15 --dir=/tmp -o spirv-tools.tar.gz "$SHADERC_BASE/spirv-tools/+archive/refs/tags/$NDK_TAG.tar.gz" && tar -xzf /tmp/spirv-tools.tar.gz && rm /tmp/spirv-tools.tar.gz )
  if [ "$PLATFORM" = bsd ]; then
    # spirv-tools refuses unknown platforms; downgrade to a warning + assume Linux
    sed -i 's/message(FATAL_ERROR "Your platform '\''${CMAKE_SYSTEM_NAME}'\'' is not supported!")/message(WARNING "Your platform '\''${CMAKE_SYSTEM_NAME}'\'' is not supported! Assuming Linux.")\n  add_definitions(-DSPIRV_LINUX)/' "$SH/third_party/spirv-tools/CMakeLists.txt"
  fi
  mkdir -p "$SH/third_party/spirv-tools/external/spirv-headers"
  ( cd "$SH/third_party/spirv-tools/external/spirv-headers" && aria2c --console-log-level=error --check-certificate=false --max-tries=5 --retry-wait=2 --connect-timeout=15 --dir=/tmp -o spirv-headers.tar.gz "$SHADERC_BASE/spirv-headers/+archive/refs/tags/$NDK_TAG.tar.gz" && tar -xzf /tmp/spirv-headers.tar.gz && rm /tmp/spirv-headers.tar.gz )
  mkdir -p "$SH/third_party/glslang"
  ( cd "$SH/third_party/glslang" && aria2c --console-log-level=error --check-certificate=false --max-tries=5 --retry-wait=2 --connect-timeout=15 --dir=/tmp -o glslang.tar.gz "$SHADERC_BASE/glslang/+archive/refs/tags/$NDK_TAG.tar.gz" && tar -xzf /tmp/glslang.tar.gz && rm /tmp/glslang.tar.gz )
  if [ "$PLATFORM" = bionic ]; then
    sed -i '/^elseif(UNIX)$/,/^[[:space:]]*endif()$/d' "$SH/third_party/glslang/StandAlone/CMakeLists.txt"
  fi
  ( cd "$SH/third_party/spirv-tools" && git init --quiet && git apply "$ROOT/patches/ndk/spirv/full_static.patch" && rm -rf .git )
  ( cd "$SH" && git init --quiet && git apply "$ROOT/patches/ndk/shaderc/full_static.patch" && rm -rf .git )

  local cflags="" exelink=""
  case "$PLATFORM" in
    bionic)  exelink="-static-libstdc++ -static-libgcc" ;;
    linux)    exelink="$STATIC_LD"; cflags="$STATIC"
             [ "$TARGET" = hexagon-linux-musl ] && cflags="-Wno-bitfield-width -Wno-error=bitfield-width $STATIC" ;;
    bsd)     cflags="-Wno-error=date-time" ;;
    windows) exelink="-static-libstdc++ -static-libgcc -pthread"; cflags="-Wno-error=implicit-function-declaration" ;;
  esac
  cmake -S "$SH" -B "$SH/build" -G Ninja \
    -DCMAKE_INSTALL_PREFIX="$SH/install" \
    -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DCMAKE_C_FLAGS="$cflags" -DCMAKE_CXX_FLAGS="$cflags" \
    -DCMAKE_EXE_LINKER_FLAGS="$exelink" \
    -DCMAKE_CROSSCOMPILING=True -DCMAKE_SYSTEM_NAME="$SYSTEM_NAME" \
    -DCMAKE_C_COMPILER="$CROSS_CC" -DCMAKE_CXX_COMPILER="$CROSS_CXX" -DCMAKE_ASM_COMPILER="$CROSS_CC" \
    -DCMAKE_LINKER="$CROSS_LD" -DCMAKE_OBJCOPY="$CROSS_OBJCOPY" -DCMAKE_AR="$CROSS_AR" \
    -DCMAKE_RANLIB="$CROSS_RANLIB" -DCMAKE_STRIP="$CROSS_STRIP" \
    -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  cmake --build "$SH/build" --target install
}

# --- CPython (target build; windows uses prebuilt binaries/ instead) --------
build_python() {
  [ "$PLATFORM" = windows ] && return 0
  log "Building Python 3.11.4"
  ( cd "$BUILD"
    aria2c --console-log-level=error --check-certificate=false --max-tries=5 --retry-wait=2 --connect-timeout=15 --dir=/tmp -o python.tar.xz https://www.python.org/ftp/python/3.11.4/Python-3.11.4.tar.xz && xz -d < /tmp/python.tar.xz | tar -x && rm /tmp/python.tar.xz
    rm -rf python; mv Python-3.11.4 python
    cp "$ROOT/config/config.sub" "$ROOT/config/config.guess" python/
    cd python
    [ "$PLATFORM" = bsd ] && cp "$ROOT/patches/bsd/python/configure" "$PWD/configure"
    mkdir -p build
    if [ "$PLATFORM" = linux ]; then
      cat > config.site <<'EOF'
ac_cv_file__dev_ptmx=no
ac_cv_file__dev_ptc=no
ac_cv_func_setgid=no
ac_cv_func_setresgid=no
ac_cv_func_setresuid=no
ac_cv_func_setreuid=no
ac_cv_func_setregid=no
ac_cv_func_setuid=no
ac_cv_func_seteuid=no
ac_cv_func_setfsgid=no
ac_cv_func_setfsuid=no
ac_cv_func_setegid=no
ac_cv_func_getloadavg=no
ac_cv_have_decl_getloadavg=no
EOF
    else
      cat > config.site <<'EOF'
ac_cv_file__dev_ptmx=no
ac_cv_file__dev_ptc=no
EOF
    fi
    # linux: force static extension modules
    if [ "$PLATFORM" = linux ]; then
      case "$TARGET" in
        *musl*) sed -i '/^case \$host_cpu in #(/,/^esac$/c\
MODULE_BUILDTYPE=static
' configure ;;
      esac
    fi
    local args=( --prefix="$PWD/build" --build=x86_64-linux-gnu --host="$TARGET"
                 --disable-shared --disable-ipv6 --with-build-python --without-ensurepip
                 CONFIG_SITE=config.site TARGET="$TARGET"
                 CC="$CROSS_CC" AS="$CROSS_CC" CXX="$CROSS_CXX" LD="$CROSS_LD" OBJCOPY="$CROSS_OBJCOPY"
                 READELF="$NDK_LLVM_BIN/llvm-readelf" LLVM_PROFDATA="$NDK_LLVM_BIN/llvm-profdata"
                 AR="$CROSS_AR" RANLIB="$CROSS_RANLIB" STRIP="$CROSS_STRIP"
                 LDSHARED="$CROSS_CC -shared -fPIC"
                 _PYTHON_HOST_PLATFORM="$TARGET" )
    case "$PLATFORM" in
      bionic) args+=( TOOLCHAIN="$TC" API="$API"
                      LD_LIBRARY_PATH="$TC/sysroot/usr/lib/$TARGET"
                      LDFLAGS="-static-libstdc++ -static-libgcc" ) ;;
      linux)   args+=( CFLAGS="-Wno-error=date-time $STATIC"
                      CXXFLAGS="-Wno-error=date-time $STATIC"
                      LDFLAGS="$STATIC_LD" ) ;;
      bsd)    args+=( CFLAGS="-Wno-error=date-time" CXXFLAGS="-Wno-error=date-time" ) ;;
    esac
    ./configure "${args[@]}"
    make -j"$(ncpu)" build_all || echo "WARNING: issue in building python for $TARGET"
    make install
  )
}

# --- strip the freshly built host tools -------------------------------------
strip_deps() {
  local files f
  if [ "$PLATFORM" = windows ]; then
    files=( "$BUILD/make/build/bin/make.exe"
            "$BUILD/yasm/build/bin/yasm.exe" "$BUILD/yasm/build/bin/ytasm.exe" "$BUILD/yasm/build/bin/vsyasm.exe" )
  else
    files=( "$BUILD/make/build/bin/make"
            "$BUILD/yasm/build/bin/yasm" "$BUILD/yasm/build/bin/ytasm" "$BUILD/yasm/build/bin/vsyasm"
            "$BUILD/python/build/python" )
  fi
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    if [ "$PLATFORM" = bionic ]; then "$CROSS_STRIP" -s "$f"; else "$CROSS_STRIP" "$f"; fi
  done
}

# --- download the matching llvm-custom toolchain ----------------------------
fetch_llvm() {
  local name="${LLVM_PKG}-r${NDK_VERSION}${NDK_REVISION}-${TARGET}"
  log "Fetching LLVM ($name)"
  aria2c --console-log-level=error --check-certificate=false --max-tries=5 --retry-wait=2 --connect-timeout=15 --dir=/tmp -o llvm-custom.tar.xz "https://github.com/${REPO_OWNER}/llvm-custom/releases/download/llvm-r${NDK_VERSION}/${name}.tar.xz" && tar -xJf /tmp/llvm-custom.tar.xz -C "$BUILD" && rm /tmp/llvm-custom.tar.xz
  HOST_TOOLCHAIN="$BUILD/$name"
}

# --- splice everything into the official NDK --------------------------------
assemble_ndk() {
  log "Assembling NDK ($PLATFORM / $TARGET)"
  if [ "$PLATFORM" = windows ]; then assemble_windows; else assemble_unix; fi

  cd "$NDK"
  /usr/bin/cc "$ROOT/sources/package-generator.c" -o "$BUILD/package-generator"
  "$BUILD/package-generator" package.xml "$(grep '^Pkg\.Revision =' source.properties | cut -d'=' -f2 | tr -d ' ')"
}

assemble_unix() {
  local PREBUILT_BIN="$NDK/prebuilt/linux-x86_64/bin"

  # cmp/echo are built before the replace loop so bionic uses the *official* NDK
  # clang (the loop overwrites it with llvm-custom's). Harmless for musl/bsd,
  # which use zig cc and write to a different dir than the loop touches.
  "$CROSS_CC" "$ROOT/sources/portable_cmp.c" -o "$PREBUILT_BIN/cmp"
  "$CROSS_CC" "$ROOT/sources/portable_echo.c" -o "$PREBUILT_BIN/echo"

  # replace ELF tools with the rebuilt ones; convert bash shebangs; drop the rest
  find "$NDK_TOOLCHAIN/bin" -type f | while IFS= read -r file; do
    bname="$(basename "$file")"
    if [ -f "$HOST_TOOLCHAIN/bin/$bname" ] && file "$file" | grep -q 'ELF'; then
      echo "Replacing $bname"; cp "$HOST_TOOLCHAIN/bin/$bname" "$file"
    elif file "$file" | grep -q 'Bourne-Again shell script'; then
      echo "Replacing SheBang $bname"; sed -i 's,#!/usr/bin/env bash,#!/usr/bin/env sh,' "$file"
    elif ! file "$file" | grep -Eq 'Python script|Perl script|ASCII text'; then
      echo "Removing $bname"; rm "$file"
    fi
  done

  sed -i 's,#!/usr/bin/env bash,#!/usr/bin/env sh,' "$NDK/build/tools/ndk_bin_common.sh" "$NDK/build/tools/make_standalone_toolchain.py" "$NDK/build/ndk-build"
  sed -i 's,#!/bin/bash,#!/bin/sh,' "$PREBUILT_BIN/ndk-gdb" "$PREBUILT_BIN/ndk-stack" "$PREBUILT_BIN/ndk-which" "$NDK/simpleperf/inferno.sh" "$NDK_TOOLCHAIN/bin/lldb.sh"
  cp "$ROOT/patches/ndk/scripts/clang-tidy.sh" "$NDK_TOOLCHAIN/bin"
  cp "$ROOT/patches/ndk/scripts/ndk-which" "$PREBUILT_BIN"

  fixup_host_arch
  [ "$PLATFORM" = bsd ] && fixup_bsd_host_os

  # remove unused resources
  rm -rf "$NDK_TOOLCHAIN/python3"
  rm -rf "$NDK_TOOLCHAIN/musl"
  rm -rf "$NDK/prebuilt/linux_x86-64/bin/*asm"
  find "$NDK_TOOLCHAIN/lib" -maxdepth 1 -mindepth 1 -not -name clang -exec rm -rf {} \;
  find "$NDK_TOOLCHAIN" -maxdepth 5 -path "*/lib/clang/[0-9][0-9]/lib/*" -not -name linux -exec rm -rf {} \;

  # copy compiled binaries
  cp -R "$HOST_TOOLCHAIN/lib/clang" "$NDK_TOOLCHAIN/lib"
  cp -R "$HOST_TOOLCHAIN/lib/libear" "$NDK_TOOLCHAIN/lib"
  cp -R "$HOST_TOOLCHAIN/lib/libscanbuild" "$NDK_TOOLCHAIN/lib"
  cp "$BUILD/make/build/bin/make" "$PREBUILT_BIN"
  cp "$BUILD/yasm/build/bin/yasm" "$PREBUILT_BIN"
  cp "$BUILD/yasm/build/bin/yasm" "$NDK_TOOLCHAIN/bin"
  cp "$BUILD/yasm/build/bin/ytasm" "$PREBUILT_BIN"
  cp "$BUILD/yasm/build/bin/vsyasm" "$PREBUILT_BIN"
  mkdir -p "$NDK_TOOLCHAIN/python3/bin" "$NDK_TOOLCHAIN/python3/lib"
  cp "$BUILD/python/build/python" "$NDK_TOOLCHAIN/python3/bin/python3"
  cp -R "$BUILD/python/build/lib/python3.11" "$NDK_TOOLCHAIN/python3/lib"
  cp "$ROOT/patches/musl/llvm/lldb" "$NDK_TOOLCHAIN/bin/lldb"
  chmod 755 "$NDK_TOOLCHAIN/bin/lldb"
  find "$NDK/shader-tools/linux-x86_64" -type f | while IFS= read -r file; do
    bname="$(basename "$file")"; echo "Replacing $bname"
    cp "$BUILD/shaderc/install/bin/$bname" "$file" || true
  done
  rm -rf "$NDK/shader-tools/linux-x86_64/libc++.so"

  rename_host
  patch_cmake_toolchain
}

# ndk_bin_common.sh HOST_ARCH normalization (bionic has a smaller arch list)
fixup_host_arch() {
  if [ "$PLATFORM" = bionic ]; then
    sed -i -E '/case \$HOST_ARCH in/,/esac/ c\
case $HOST_ARCH in\
  armv5te|armv6|armv6l|armv7|armv7l|armv8l) HOST_ARCH=arm;;\
  armv8b) HOST_ARCH=arm_be;;\
  aarch64) HOST_ARCH=arm64;;\
  aarch64_be) HOST_ARCH=arm64_be;;\
  loongarch64) HOST_ARCH=loong64;;\
  i?86) HOST_ARCH=x86;;\
  amd64) HOST_ARCH=x86_64;;\
  arm64|x86_64|riscv32|riscv64|ppc|ppcle|ppc64|ppc64le|mips|mips64|s390x) HOST_ARCH=$HOST_ARCH;;\
  *) echo "ERROR: Unknown host CPU architecture: $HOST_ARCH"; exit 1;;\
esac' "$NDK/build/tools/ndk_bin_common.sh"
  else
    sed -i -E '/case \$HOST_ARCH in/,/esac/ c\
case $HOST_ARCH in\
  armv5te|armv5tel|armv6|armv6l|armv7|armv7l|armv8l) HOST_ARCH=arm;;\
  armv7b|armv8b) HOST_ARCH=arm_be;;\
  aarch64) HOST_ARCH=arm64;;\
  aarch64_be) HOST_ARCH=arm64_be;;\
  loongarch64) HOST_ARCH=loong64;;\
  i?86) HOST_ARCH=x86;;\
  amd64) HOST_ARCH=x86_64;;\
  arm64|x86_64|riscv32|riscv64|ppc|ppcle|ppc64|ppc64le|mips|mips64|s390x) HOST_ARCH=$HOST_ARCH;;\
  *) echo "ERROR: Unknown host CPU architecture: $HOST_ARCH"; exit 1;;\
esac' "$NDK/build/tools/ndk_bin_common.sh"
  fi
}

# bsd: add NetBSD/OpenBSD to the HOST_OS case and fix FreeBsd casing
fixup_bsd_host_os() {
  sed -i -e 's/FreeBsd/FreeBSD/' \
         -e '/case \$HOST_OS in/a \
NetBSD) HOST_OS=netbsd;;\
OpenBSD) HOST_OS=openbsd;;' "$NDK/build/tools/ndk_bin_common.sh"
}

# map a target triple's arch field to the NDK host-tag arch
host_tag_arch() {
  local arch="${TARGET%%-*}"
  if [ "$PLATFORM" = bionic ]; then
    case "$arch" in
      aarch64) arch=arm64 ;;
      armv7a)  arch=arm ;;
      i686)    arch=x86 ;;
    esac
  else
    case "$arch" in
      aarch64)         arch=arm64 ;;
      aarch64_be)      arch=arm64_be ;;
      loongarch64)     arch=loong64 ;;
      powerpc64le)     arch=ppc64le ;;
      powerpc64)       arch=ppc64 ;;
      powerpcle)       arch=ppcle ;;
      powerpc)         arch=ppc ;;
      thumb)           arch=arm ;;
      thumbeb|armeb)   arch=arm_be ;;
      x86)             arch=i686 ;;
    esac
  fi
  echo "$arch"
}

# rename prebuilt/<host> dirs to the target host tag + leave linux-x86_64 symlinks
rename_host() {
  local tag arch
  arch="$(host_tag_arch)"
  case "$PLATFORM" in
    bionic)  [ "$TARGET" = x86_64-linux-android ] && return 0; tag="linux-$arch" ;;
    linux)    case "$TARGET" in x86_64-linux-musl|x86_64-linux-muslx32|x86_64-linux-gnu|x86_64-linux-gnux32) return 0 ;; esac; tag="linux-$arch" ;;
    bsd)     tag="${SYSTEM_NAME,,}-$arch" ;;
  esac

  mv "$NDK/prebuilt/linux-x86_64" "$NDK/prebuilt/$tag"
  mv "$NDK/toolchains/llvm/prebuilt/linux-x86_64" "$NDK/toolchains/llvm/prebuilt/$tag"
  mv "$NDK/shader-tools/linux-x86_64" "$NDK/shader-tools/$tag"
  ( cd "$NDK/toolchains/llvm/prebuilt" && ln -s "$tag" linux-x86_64 )
  ( cd "$NDK/prebuilt" && ln -s "$tag" linux-x86_64 )
  ( cd "$NDK/shader-tools" && ln -s "$tag" linux-x86_64 )
  local f
  for f in "$NDK/ndk-gdb" "$NDK/ndk-lldb" "$NDK/ndk-stack" "$NDK/ndk-which"; do
    sed -i "s|linux-x86_64|$tag|g" "$f"
  done
}

# rewrite the ANDROID_HOST_TAG block in the cmake toolchain files
patch_cmake_toolchain() {
  local files=( "$NDK/build/cmake/android.toolchain.cmake" "$NDK/build/cmake/android-legacy.toolchain.cmake" )
  case "$PLATFORM" in
    bionic)
      sed -i -E '/^if\(CMAKE_HOST_SYSTEM_NAME STREQUAL Linux\)$/,/^endif\(\)$/c\
if(CMAKE_HOST_SYSTEM_NAME STREQUAL Linux OR CMAKE_HOST_SYSTEM_NAME STREQUAL Android)\
    execute_process(\
        COMMAND uname -m\
        OUTPUT_VARIABLE HOST_ARCH\
        OUTPUT_STRIP_TRAILING_WHITESPACE\
    )\
\
    if(HOST_ARCH STREQUAL "aarch64")\
        set(ARCH "arm64")\
    elseif(HOST_ARCH MATCHES "^armv[0-9]+l$")\
        set(ARCH "arm")\
    elseif(HOST_ARCH STREQUAL "arm64" OR HOST_ARCH STREQUAL "arm64e")\
        set(ARCH "arm64")\
    elseif(HOST_ARCH STREQUAL "aarch64_be")\
        set(ARCH "arm64_be")\
    elseif(HOST_ARCH STREQUAL "loongarch64")\
        set(ARCH "loong64")\
    elseif(HOST_ARCH STREQUAL "powerpc64le")\
        set(ARCH "ppc64le")\
    elseif(HOST_ARCH STREQUAL "powerpc64")\
        set(ARCH "ppc64")\
    elseif(HOST_ARCH STREQUAL "powerpcle")\
        set(ARCH "ppcle")\
    elseif(HOST_ARCH STREQUAL "powerpc")\
        set(ARCH "ppc")\
    elseif(HOST_ARCH STREQUAL "amd64")\
        set(ARCH "x86_64")\
    elseif(HOST_ARCH MATCHES "^i[3-6]86$")\
        set(ARCH "x86")\
    else()\
        set(ARCH "${HOST_ARCH}")\
    endif()\
\
    set(ANDROID_HOST_TAG "linux-${ARCH}")\
\
elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL Darwin)\
    set(ANDROID_HOST_TAG "darwin-x86_64")\
elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL Windows)\
    set(ANDROID_HOST_TAG "windows-x86_64")\
endif()' "${files[@]}"
      ;;
    linux)
      sed -i -E '/^if\(CMAKE_HOST_SYSTEM_NAME STREQUAL Linux\)$/,/^endif\(\)$/c\
if(CMAKE_HOST_SYSTEM_NAME STREQUAL Linux OR CMAKE_HOST_SYSTEM_NAME STREQUAL Android)\
    execute_process(\
        COMMAND uname -m\
        OUTPUT_VARIABLE HOST_ARCH\
        OUTPUT_STRIP_TRAILING_WHITESPACE\
    )\
\
    if(HOST_ARCH STREQUAL "aarch64")\
        set(ARCH "arm64")\
    elseif(HOST_ARCH MATCHES "^armv[0-9]+l$")\
        set(ARCH "arm")\
    elseif(HOST_ARCH STREQUAL "armv7b" OR HOST_ARCH STREQUAL "armv8b")\
        set(ARCH "arm_be")\
    elseif(HOST_ARCH STREQUAL "arm64" OR HOST_ARCH STREQUAL "arm64e")\
        set(ARCH "arm64")\
    elseif(HOST_ARCH STREQUAL "aarch64_be")\
        set(ARCH "arm64_be")\
    elseif(HOST_ARCH STREQUAL "loongarch64")\
        set(ARCH "loong64")\
    elseif(HOST_ARCH STREQUAL "powerpc64le")\
        set(ARCH "ppc64le")\
    elseif(HOST_ARCH STREQUAL "powerpc64")\
        set(ARCH "ppc64")\
    elseif(HOST_ARCH STREQUAL "powerpcle")\
        set(ARCH "ppcle")\
    elseif(HOST_ARCH STREQUAL "powerpc")\
        set(ARCH "ppc")\
    elseif(HOST_ARCH STREQUAL "amd64")\
        set(ARCH "x86_64")\
    elseif(HOST_ARCH MATCHES "^i[3-6]86$")\
        set(ARCH "x86")\
    else()\
        set(ARCH "${HOST_ARCH}")\
    endif()\
\
    set(ANDROID_HOST_TAG "linux-${ARCH}")\
\
elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL Darwin)\
    set(ANDROID_HOST_TAG "darwin-x86_64")\
elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL Windows)\
    set(ANDROID_HOST_TAG "windows-x86_64")\
endif()' "${files[@]}"
      ;;
    bsd)
      sed -i -E '/^if\(CMAKE_HOST_SYSTEM_NAME STREQUAL Linux\)$/,/^endif\(\)$/c\
if(CMAKE_HOST_SYSTEM_NAME STREQUAL NetBSD OR CMAKE_HOST_SYSTEM_NAME STREQUAL FreeBSD OR CMAKE_HOST_SYSTEM_NAME STREQUAL OpenBSD)\
    execute_process(\
        COMMAND uname -m\
        OUTPUT_VARIABLE HOST_ARCH\
        OUTPUT_STRIP_TRAILING_WHITESPACE\
    )\
\
    if(HOST_ARCH STREQUAL "aarch64")\
        set(ARCH "arm64")\
    elseif(HOST_ARCH MATCHES "^armv[0-9]+l$")\
        set(ARCH "arm")\
    elseif(HOST_ARCH STREQUAL "armv7b" OR HOST_ARCH STREQUAL "armv8b")\
        set(ARCH "arm_be")\
    elseif(HOST_ARCH STREQUAL "arm64" OR HOST_ARCH STREQUAL "arm64e")\
        set(ARCH "arm64")\
    elseif(HOST_ARCH STREQUAL "aarch64_be")\
        set(ARCH "arm64_be")\
    elseif(HOST_ARCH STREQUAL "loongarch64")\
        set(ARCH "loong64")\
    elseif(HOST_ARCH STREQUAL "powerpc64le")\
        set(ARCH "ppc64le")\
    elseif(HOST_ARCH STREQUAL "powerpc64")\
        set(ARCH "ppc64")\
    elseif(HOST_ARCH STREQUAL "powerpcle")\
        set(ARCH "ppcle")\
    elseif(HOST_ARCH STREQUAL "powerpc")\
        set(ARCH "ppc")\
    elseif(HOST_ARCH STREQUAL "amd64")\
        set(ARCH "x86_64")\
    elseif(HOST_ARCH MATCHES "^i[3-6]86$")\
        set(ARCH "x86")\
    else()\
        set(ARCH "${HOST_ARCH}")\
    endif()\
\
    string(TOLOWER "${CMAKE_HOST_SYSTEM_NAME}" HOST_SYSTEM_NAME_LOWER)\
\
    set(ANDROID_HOST_TAG "${HOST_SYSTEM_NAME_LOWER}-${ARCH}")\
\
elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL Linux)\
    set(ANDROID_HOST_TAG "linux-x86_64")\
elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL Darwin)\
    set(ANDROID_HOST_TAG "darwin-x86_64")\
elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL Windows)\
    set(ANDROID_HOST_TAG "windows-x86_64")\
endif()' "${files[@]}"
      ;;
  esac
}

assemble_windows() {
  local PREBUILT_BIN="$NDK/prebuilt/windows-x86_64/bin"

  # llvm-custom ships some bin/ entries as symlinks; turn them into hard links
  # so the copy below picks up real PE files
  find "$HOST_TOOLCHAIN/bin" -type l | while IFS= read -r file; do
    if [ -L "$file" ]; then
      target="$(readlink -f "$file")"; echo "Hard linking $(basename "$file")"
      rm "$file"; ln "$target" "$file"
    fi
  done

  find "$NDK_TOOLCHAIN/bin" -type f | while IFS= read -r file; do
    bname="$(basename "$file")"
    if [ -f "$HOST_TOOLCHAIN/bin/$bname" ] && file "$file" | grep -q 'PE32'; then
      echo "Replacing $bname"; cp "$HOST_TOOLCHAIN/bin/$bname" "$file"
    elif ! file "$file" | grep -Eq 'Python script|Perl script|ASCII text'; then
      echo "Removing $bname"; rm "$file"
    fi
  done

  sed -i -E '/case \$HOST_ARCH in/,/esac/ c\
HOST_ARCH=x86_64' "$NDK/build/tools/ndk_bin_common.sh"
  sed -i '/^HOST_ARCH=$(uname -m)$/d' "$NDK/build/tools/ndk_bin_common.sh"

  # remove unused resources
  rm -rf "$NDK_TOOLCHAIN/python3"
  rm -rf "$NDK/prebuilt/windows_x86-64/bin/*asm.exe"
  rm -rf "$NDK/prebuilt/windows_x86-64/bin/echo.exe"
  rm -rf "$NDK/prebuilt/windows_x86-64/bin/cmp.exe"
  find "$NDK_TOOLCHAIN/lib" -maxdepth 1 -mindepth 1 -not -name clang -exec rm -rf {} \;
  find "$NDK_TOOLCHAIN" -maxdepth 5 -path "*/lib/clang/[0-9][0-9]/lib/*" -not -name linux -exec rm -rf {} \;

  # copy compiled binaries
  cp -R "$HOST_TOOLCHAIN/lib/clang" "$NDK_TOOLCHAIN/lib"
  cp -R "$HOST_TOOLCHAIN/lib/libear" "$NDK_TOOLCHAIN/lib"
  cp -R "$HOST_TOOLCHAIN/lib/libscanbuild" "$NDK_TOOLCHAIN/lib"
  cp "$BUILD/make/build/bin/make.exe" "$PREBUILT_BIN"
  cp "$BUILD/yasm/build/bin/yasm.exe" "$PREBUILT_BIN"
  cp "$BUILD/yasm/build/bin/yasm.exe" "$NDK_TOOLCHAIN/bin"
  cp "$BUILD/yasm/build/bin/ytasm.exe" "$PREBUILT_BIN"
  cp "$BUILD/yasm/build/bin/vsyasm.exe" "$PREBUILT_BIN"
  "$CROSS_CC" "$ROOT/sources/portable_cmp.c" -o "$PREBUILT_BIN/cmp.exe"
  "$CROSS_CC" "$ROOT/sources/portable_echo.c" -o "$PREBUILT_BIN/echo.exe"
  mkdir -p "$NDK_TOOLCHAIN/python3"
  unzip -qq "$ROOT/binaries/python-3.11.4-${TARGET}.zip" -d "$NDK_TOOLCHAIN/python3"
  find "$NDK/shader-tools/windows-x86_64" -type f | while IFS= read -r file; do
    bname="$(basename "$file")"; echo "Replacing $bname"
    cp "$BUILD/shaderc/install/bin/$bname" "$file" || true
  done
}

# --- package ----------------------------------------------------------------
archive() {
  local parent base out
  parent="$(dirname "$NDK")"; base="$(basename "$NDK")"
  if [ "$PLATFORM" = windows ]; then
    out="$ROOTDIR/${NDK_NAME}-${TARGET}.7z"
    ( cd "$parent" && 7z a -snl -t7z -mx=9 -m0=LZMA2 -md=256m -mfb=273 -mtc=on -mmt=on "$out" "$base" )
  else
    out="$ROOTDIR/${NDK_NAME}-${TARGET}.tar.xz"
    ( cd "$parent" && tar -cf - "$base" | xz -T0 -9e --lzma2=dict=256MiB > "$out" )
  fi
  log "Archive -> $out"
}

# --- orchestrate ------------------------------------------------------------
download_official_ndk
setup_toolchain
build_make
build_yasm
build_shaderc
build_python
strip_deps
fetch_llvm
assemble_ndk
archive
log "Done -> $NDK"
