#!/usr/bin/env bash
# Assemble one Android NDK for a single cross target. Driven entirely by env vars
# so it runs identically in CI and in `docker run`.
#
#   PLATFORM    bionic | linux | bsd | windows | macos
#   TARGET      target triple, e.g.
#                 aarch64-linux-android        (bionic)
#                 x86_64-linux-gnu / -musl     (linux)
#                 aarch64-freebsd-none         (bsd)
#                 x86_64-w64-mingw32           (windows)
#                 arm64-apple-darwin           (macos)
#   NDK_VERSION   required (e.g. 30)
#   NDK_REVISION  optional (e.g. b)
#   ANDROID_PLATFORM  bionic API level (default 25, riscv64 forced to 35)
#   ROOTDIR     work dir = checkout root (default: cwd); holds sources/ config/
#               patches/. HOME is also set here in CI.
#   REPO_OWNER  GitHub owner for the llvm-custom release download (default HomuHomu833)
#   EXTRA_CMAKE_FLAGS  optional extra -D flags for the cmake (shaderc) configure
#
# Steps mirror the old make_ndk_*.yml workflows 1:1: build make/yasm/shaderc/python,
# download the matching llvm-custom toolchain, splice everything into the official
# NDK, then archive (xz; 7z for windows).
set -euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
ROOT="$ROOTDIR"                       # repo assets: sources/ config/ patches/
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

# Download with retries: re-run aria2c on any failure so transient GitHub 501/504
# (and the like) recover. Doesn't rely on aria2's --retry-on-unknown, which older
# aria2 builds don't have. Pass aria2c args, e.g. fetch --dir=/tmp -o f.zip URL.
fetch() {
  local i=0
  until aria2c --console-log-level=error --check-certificate=false \
               --max-tries=5 --retry-wait=2 --connect-timeout=15 "$@"; do
    i=$((i + 1)); [ "$i" -ge 5 ] && { echo "fetch: giving up after $i attempts" >&2; return 1; }
    echo "fetch: aria2c failed, retry $i/5 in 2s..." >&2; sleep 2
  done
}

resolve_shaderc_ref() {
  local tag_url="$SHADERC_BASE/shaderc/+archive/refs/tags/$NDK_TAG.tar.gz"

  if aria2c \
      --console-log-level=error \
      --check-certificate=false \
      --max-tries=1 \
      --connect-timeout=15 \
      --dry-run=true \
      "$tag_url" >/dev/null 2>&1; then
    echo "refs/tags/$NDK_TAG"
  else
    echo "refs/heads/mirror-goog-main-ndk"
  fi
}

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
  fetch --dir="$BUILD" -o ndk-linux.zip "${base}-linux.zip"
  unzip -qq "$BUILD/ndk-linux.zip" -d "$BUILD/ndk-linux"
  rm -f "$BUILD/ndk-linux.zip"
  LINUX_NDK="$BUILD/ndk-linux/$NDK_NAME"
  NDK_LLVM_BIN="$LINUX_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"

  if [ "$PLATFORM" = windows ]; then
    log "Downloading official NDK (windows)"
    fetch --dir="$BUILD" -o ndk-windows.zip "${base}-windows.zip"
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
  CROSS_CFLAGS="-fno-sanitize=undefined"; CROSS_LDFLAGS=""; SYSTEM_NAME=Linux
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
        *musl*) CROSS_CFLAGS="-static -fno-sanitize=undefined"; CROSS_LDFLAGS="-static" ;;
        *)      CROSS_LDFLAGS="-static-libstdc++ -static-libgcc" ;;
      esac
      ;;
    bsd)
      TC=/opt/zig-as-llvm; export ZIG_TARGET="$TARGET"
      CROSS_CC="$TC/bin/cc"; CROSS_CXX="$TC/bin/c++"; CROSS_LD="$TC/bin/ld"; CROSS_AR="$TC/bin/ar"
      CROSS_RANLIB="$TC/bin/ranlib"; CROSS_STRIP="$TC/bin/strip"; CROSS_OBJCOPY="$TC/bin/objcopy"
      NDK_HOST=linux-x86_64; SYSTEM_NAME="$(bsd_system_name)"
      ;;
    macos)
      # Darwin host tools build with osxcross (cctools-port + clang wrappers),
      # not zig: zig segfaults building macOS binaries, and osxcross is a proper
      # Apple cross toolchain. The wrappers carry the macOS SDK sysroot, so no
      # -isysroot/-iframework juggling is needed here.
      TC=/opt/osxcross
      # Put osxcross bin on PATH so clang discovers the cctools linker by its
      # prefixed name (<triple>-ld) instead of falling through to the host
      # /usr/bin/ld. CMake's compiler-probe try-compiles don't honor
      # CMAKE_EXE_LINKER_FLAGS, so a -fuse-ld/--ld-path flag alone wouldn't reach
      # them, PATH-based discovery covers every link uniformly.
      export PATH="$TC/bin:$PATH"
      case "$TARGET" in
        arm64e-*)          ARCH=arm64e ;;   # distinct PAC ABI, not arm64
        aarch64-*|arm64-*) ARCH=arm64 ;;
        x86_64h-*)         ARCH=x86_64h ;;  # Haswell+ x86_64 slice (same ABI)
        x86_64-*)          ARCH=x86_64 ;;
        *) echo "Unsupported macOS arch in TARGET='$TARGET'" >&2; exit 1 ;;
      esac
      # osxcross names its wrappers with the SDK's darwin version (e.g.
      # arm64-apple-darwin24.5-clang); resolve that prefix by globbing rather
      # than pinning a version that drifts with the baked SDK.
      CCWRAP="$(ls "$TC/bin/${ARCH}-apple-darwin"*-clang 2>/dev/null | head -n1 || true)"
      [ -n "$CCWRAP" ] || { echo "osxcross clang wrapper for $ARCH not found in $TC/bin" >&2; exit 1; }
      HOST="$(basename "${CCWRAP%-clang}")"
      CROSS_CC="$TC/bin/${HOST}-clang"; CROSS_CXX="$TC/bin/${HOST}-clang++"
      CROSS_AR="$TC/bin/${HOST}-ar"; CROSS_RANLIB="$TC/bin/${HOST}-ranlib"
      CROSS_STRIP="$TC/bin/${HOST}-strip"; CROSS_LD="$TC/bin/${HOST}-ld"
      CROSS_OBJCOPY=""                  # cctools ships no objcopy; nothing here needs it
      NDK_HOST=linux-x86_64; SYSTEM_NAME=Darwin
      # shaderc's combined-archive step invokes a bare `libtool -static -o`
      # (Apple's archive merge), hardcoded rather than CMAKE_LIBTOOL-aware. Host
      # GNU libtool can't merge archives, so expose the cctools libtool under the
      # plain `libtool` name on PATH via a shim dir.
      LIBTOOLBIN="$(ls "$TC/bin/${ARCH}-apple-darwin"*-libtool 2>/dev/null | head -n1 || true)"
      if [ -n "$LIBTOOLBIN" ]; then
        mkdir -p "$BUILD/.macos-shims"
        ln -sf "$LIBTOOLBIN" "$BUILD/.macos-shims/libtool"
        export PATH="$BUILD/.macos-shims:$PATH"
      fi
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

  # Extra flags for the cmake-based configure (shaderc): anything passed in via
  # the EXTRA_CMAKE_FLAGS env var, plus platform-specific additions. The Darwin
  # (osxcross) block points CMake's Apple support at the osxcross SDK so it
  # doesn't probe a host Xcode, and pins the arch + deployment target; the
  # zig/llvm-mingw/NDK platforms need none of this. (CMAKE_LIBTOOL is left to
  # CMake's find_program, which picks up the cctools libtool shim on PATH.)
  EXTRA_CMAKE_FLAGS=(${EXTRA_CMAKE_FLAGS:-})
  if [ "$SYSTEM_NAME" = Darwin ]; then
    SDKROOT="$(ls -d "$TC/SDK/MacOSX"*.sdk 2>/dev/null | head -n1 || true)"
    [ -n "$SDKROOT" ] && EXTRA_CMAKE_FLAGS+=(-DCMAKE_OSX_SYSROOT="$SDKROOT")
    EXTRA_CMAKE_FLAGS+=(-DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0)
  fi
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
      linux)   args+=( CFLAGS="-Wno-error=incompatible-pointer-types $CROSS_CFLAGS"
                       CXXFLAGS="-Wno-error=incompatible-pointer-types $CROSS_CFLAGS"
                       LDFLAGS="$CROSS_LDFLAGS" )

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
      bsd)     args+=( CFLAGS="-Wno-error=incompatible-pointer-types $CROSS_CFLAGS"
                       CXXFLAGS="-Wno-error=incompatible-pointer-types $CROSS_CFLAGS"
                       LDFLAGS="$CROSS_LDFLAGS" ) ;;
      macos)   args+=( CFLAGS="-Wno-error=incompatible-pointer-types $CROSS_CFLAGS"
                       CXXFLAGS="-Wno-error=incompatible-pointer-types $CROSS_CFLAGS"
                       LDFLAGS="$CROSS_LDFLAGS" ) ;;
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
      linux)    args+=( CFLAGS="-fwrapv -Wno-error=date-time $CROSS_CFLAGS"
                       CXXFLAGS="-fwrapv -Wno-error=date-time $CROSS_CFLAGS"
                       LDFLAGS="$CROSS_LDFLAGS" ) ;;
      bsd)     args+=( CFLAGS="-fwrapv $CROSS_CFLAGS" CXXFLAGS="-fwrapv $CROSS_CFLAGS"
                       LDFLAGS="$CROSS_LDFLAGS" ) ;;
      macos)   args+=( CFLAGS="-fwrapv $CROSS_CFLAGS" CXXFLAGS="-fwrapv $CROSS_CFLAGS"
                       LDFLAGS="$CROSS_LDFLAGS" ) ;;
      windows) args+=( CFLAGS="-Wno-error=implicit-function-declaration -fwrapv -Wno-error=date-time"
                       CXXFLAGS="-Wno-error=implicit-function-declaration -fwrapv -Wno-error=date-time" ) ;;
    esac
    ./configure "${args[@]}"
    make CC=/usr/bin/cc re2c genperf genmacro genversion genstring
    make -j"$(ncpu)" install
  )
}

# --- SPIRV-Tools + shaderc --------------------------------------------------
build_shaderc() {
  log "Building shaderc"
  local SH="$BUILD/shaderc"
  local SHADERC_REF="$(resolve_shaderc_ref)"
  rm -rf "$SH"; mkdir -p "$SH"
  ( cd "$SH" && fetch --dir=/tmp -o shaderc.tar.gz "$SHADERC_BASE/shaderc/+archive/$SHADERC_REF.tar.gz" && tar -xzf /tmp/shaderc.tar.gz && rm /tmp/shaderc.tar.gz )
  mkdir -p "$SH/third_party/spirv-tools"
  ( cd "$SH/third_party/spirv-tools" && fetch --dir=/tmp -o spirv-tools.tar.gz "$SHADERC_BASE/spirv-tools/+archive/$SHADERC_REF.tar.gz" && tar -xzf /tmp/spirv-tools.tar.gz && rm /tmp/spirv-tools.tar.gz )
  if [ "$PLATFORM" = bsd ]; then
    # spirv-tools refuses unknown platforms; downgrade to a warning + assume Linux
    sed -i 's/message(FATAL_ERROR "Your platform '\''${CMAKE_SYSTEM_NAME}'\'' is not supported!")/message(WARNING "Your platform '\''${CMAKE_SYSTEM_NAME}'\'' is not supported! Assuming Linux.")\n  add_definitions(-DSPIRV_LINUX)/' "$SH/third_party/spirv-tools/CMakeLists.txt"
  fi
  mkdir -p "$SH/third_party/spirv-tools/external/spirv-headers"
  ( cd "$SH/third_party/spirv-tools/external/spirv-headers" && fetch --dir=/tmp -o spirv-headers.tar.gz "$SHADERC_BASE/spirv-headers/+archive/$SHADERC_REF.tar.gz" && tar -xzf /tmp/spirv-headers.tar.gz && rm /tmp/spirv-headers.tar.gz )
  mkdir -p "$SH/third_party/glslang"
  ( cd "$SH/third_party/glslang" && fetch --dir=/tmp -o glslang.tar.gz "$SHADERC_BASE/glslang/+archive/$SHADERC_REF.tar.gz" && tar -xzf /tmp/glslang.tar.gz && rm /tmp/glslang.tar.gz )
  if [ "$PLATFORM" = bionic ]; then
    sed -i '/^elseif(UNIX)$/,/^[[:space:]]*endif()$/d' "$SH/third_party/glslang/StandAlone/CMakeLists.txt"
  fi
  ( cd "$SH/third_party/spirv-tools" && git init --quiet && git apply "$ROOT/patches/ndk/spirv/full_static.patch" && rm -rf .git )
  ( cd "$SH" && git init --quiet && git apply "$ROOT/patches/ndk/shaderc/full_static.patch" && rm -rf .git )

  local cflags="" exelink=""
  case "$PLATFORM" in
    bionic)  exelink="-static-libstdc++ -static-libgcc" ;;
    linux)    exelink="$CROSS_LDFLAGS"; cflags="$CROSS_CFLAGS"
             [ "$TARGET" = hexagon-linux-musl ] && cflags="-Wno-bitfield-width -Wno-error=bitfield-width $CROSS_CFLAGS" ;;
    bsd)     cflags="-Wno-error=date-time $CROSS_CFLAGS"; exelink="$CROSS_LDFLAGS" ;;
    macos)   cflags="-Wno-error=date-time $CROSS_CFLAGS"; exelink="$CROSS_LDFLAGS" ;;
    windows) exelink="-static-libstdc++ -static-libgcc -pthread"; cflags="-Wno-error=implicit-function-declaration" ;;
  esac
  # cctools has no objcopy, so CROSS_OBJCOPY is empty for macos; only pass
  # CMAKE_OBJCOPY when the toolchain actually provides one. The Darwin SDK/
  # libtool/arch settings ride in via EXTRA_CMAKE_FLAGS (see setup_toolchain).
  cmake -S "$SH" -B "$SH/build" -G Ninja \
    -DCMAKE_INSTALL_PREFIX="$SH/install" \
    -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DCMAKE_C_FLAGS="$cflags" -DCMAKE_CXX_FLAGS="$cflags" \
    -DCMAKE_EXE_LINKER_FLAGS="$exelink" -DCMAKE_SHARED_LINKER_FLAGS="$exelink" \
    -DCMAKE_CROSSCOMPILING=True -DCMAKE_SYSTEM_NAME="$SYSTEM_NAME" \
    -DCMAKE_C_COMPILER="$CROSS_CC" -DCMAKE_CXX_COMPILER="$CROSS_CXX" -DCMAKE_ASM_COMPILER="$CROSS_CC" \
    -DCMAKE_LINKER="$CROSS_LD" ${CROSS_OBJCOPY:+-DCMAKE_OBJCOPY="$CROSS_OBJCOPY"} -DCMAKE_AR="$CROSS_AR" \
    -DCMAKE_RANLIB="$CROSS_RANLIB" -DCMAKE_STRIP="$CROSS_STRIP" \
    -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    "${EXTRA_CMAKE_FLAGS[@]}"
  cmake --build "$SH/build" --target install
}

# --- CPython (cross-compiled for every host, windows included) --------------
# Vanilla CPython can't be built with mingw, so the windows host builds the
# msys2-contrib cpython-mingw fork instead of the python.org tarball; every
# other host keeps using the upstream source.
build_python() {
  log "Building Python 3.11.4"
  ( cd "$BUILD"
    if [ "$PLATFORM" = windows ]; then
      # cpython-mingw's mingw-v3.11.4 branch == CPython 3.11.4 + the mingw patch
      # set used by msys2's mingw-w64-python recipe. The branch ships a stale
      # generated configure, so it is regenerated with autoreconf below.
      fetch --dir=/tmp -o python.tar.gz "https://codeload.github.com/msys2-contrib/cpython-mingw/tar.gz/refs/heads/mingw-v3.11.4" && tar -xzf /tmp/python.tar.gz && rm /tmp/python.tar.gz
      rm -rf python; mv cpython-mingw-mingw-v3.11.4 python
    else
      fetch --dir=/tmp -o python.tar.xz https://www.python.org/ftp/python/3.11.4/Python-3.11.4.tar.xz && xz -d < /tmp/python.tar.xz | tar -x && rm /tmp/python.tar.xz
      rm -rf python; mv Python-3.11.4 python
    fi
    cd python
    # the bsd configure carries the Darwin cross-build fixups too (darwin was
    # built through the bsd path before it moved to its own osxcross platform)
    case "$PLATFORM" in bsd|macos) cp "$ROOT/patches/bsd/python/configure" "$PWD/configure" ;; esac
    # OpenBSD: thread_pthread.h uses `#ifdef __OpenBSD__` (not HAVE_GETTHRID)
    # to call getthrid(), so config.site can't suppress it.  zig's OpenBSD
    # headers don't expose getthrid() transitively, so inject a forward
    # declaration before the call site to satisfy -Werror=implicit-function-declaration.
    if [ "$SYSTEM_NAME" = OpenBSD ]; then
      sed -i 's|#elif defined(__OpenBSD__)|#elif defined(__OpenBSD__)\n    extern pid_t getthrid(void); /* not in zig cross headers */|' Python/thread_pthread.h
    fi
    # windows: regenerate configure (+ pyconfig.h.in) from the patched
    # configure.ac (needs autoconf-archive + pkg.m4, baked into the build image)
    [ "$PLATFORM" = windows ] && autoreconf -vfi
    # newer config.sub/config.guess (recognise the exotic triples); copied after
    # autoreconf, which rewrites them with the autotools-bundled copies
    cp "$ROOT/config/config.sub" "$ROOT/config/config.guess" "$PWD/"
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
    # macos: configure detects sendfile() by a link test (the symbol lives in
    # libSystem, so HAVE_SENDFILE gets defined), but posixmodule.c's Apple
    # sendfile() branch needs the prototype from <sys/socket.h>, which is gated
    # behind _DARWIN_C_SOURCE and stays hidden here -> implicit-declaration
    # error. NDK host tools don't need os.sendfile, so just skip the whole path
    # by forcing the cache var off (config.site is honored: the cross build
    # already relies on it for the /dev/ptmx AC_CHECK_FILE).
    # mkfifoat/mknodat: Python 3.11 wraps these in __builtin_available(macOS 13)
    # which compiles to ___isPlatformVersionAtLeast (compiler-rt). osxcross
    # cross-links don't pull that in automatically; disable both to avoid it.
    [ "$PLATFORM" = macos ] && printf 'ac_cv_func_sendfile=no\nac_cv_func_mkfifoat=no\nac_cv_func_mknodat=no\n' >> config.site
    # OpenBSD: -D_BSD_SOURCE (CFLAGS above) keeps __BSD_VISIBLE=1 even when
    # CPython defines _POSIX_C_SOURCE, restoring BSD function visibility.
    # memrchr: OpenBSD's <string.h> never declares it even with __BSD_VISIBLE=1
    # — it is simply absent from OpenBSD's libc interface.  The configure link
    # test passes (symbol present in zig's bundled libc from musl), so force
    # the cache var off so CPython uses its own pure-C fallback.
    # Block functions whose configure link test passes but whose runtime
    # semantics are wrong on OpenBSD:
    #   sendfile    — CPython's posixmodule.c only handles Linux/macOS/FreeBSD
    #                 variants; OpenBSD's sendfile(2) has BSD arguments and
    #                 falls through to the Linux path if HAVE_SENDFILE is set.
    #   getrandom   — Linux-specific syscall; OpenBSD uses getentropy(3).
    #   posix_fadvise / posix_fallocate — absent from OpenBSD entirely.
    if [ "$SYSTEM_NAME" = OpenBSD ]; then
      printf 'ac_cv_func_memrchr=no\nac_cv_func_sendfile=no\nac_cv_func_getrandom=no\nac_cv_func_posix_fadvise=no\nac_cv_func_posix_fallocate=no\n' >> config.site
    fi
    # linux/musl: force every extension module to be linked into the interpreter
    # (zig's musl is static-only -- it cannot produce the .so files setup.py would
    # otherwise emit, and -static + -shared is contradictory). CPython builds the
    # stdlib extensions via makesetup+Modules/Setup.stdlib only when
    # MODULES_SETUP_STDLIB points at it, which configure does solely for
    # Emscripten/WASI; every other host leaves it empty and the modules fall
    # through to setup.py as shared .so. So (1) force MODULE_BUILDTYPE=static (the
    # *static* marker makesetup honours) and (2) activate Setup.stdlib for this
    # host too, matching the wasm static path. setup.py then skips the
    # makesetup-built modules, so nothing is built shared.
    if [ "$PLATFORM" = linux ]; then
      case "$TARGET" in
        *musl*)
          sed -i '/^case \$host_cpu in #(/,/^esac$/c\
MODULE_BUILDTYPE=static
' configure
          sed -i 's#^\([[:space:]]*\)MODULES_SETUP_STDLIB=$#\1MODULES_SETUP_STDLIB=Modules/Setup.stdlib#' configure
          ;;
      esac
    fi
    # linux/bsd (zig): neuter setup.py's add_cross_compiling_paths(). It probes
    # `$(CC) -E -v` and adds every "#include <...>" dir that isn't a /gcc/ or
    # /clang/ path -- but zig's clang reports the host's /usr/include and
    # /usr/local/include there, so those leak into the cross build. The host
    # glibc <stdlib.h> then pulls <bits/libc-header-start.h> from the Debian
    # multiarch dir zig never searches -> every extension fails to compile. zig
    # resolves its own sysroot internally (not via -I), so the probe is pure
    # downside here; drop it. macos/osxcross and windows/mingw report correct
    # sysroots from the same probe, so they keep it.
    case "$PLATFORM" in
      linux|bsd) sed -i 's/^\( *\)def add_cross_compiling_paths(self):/\1def add_cross_compiling_paths(self):\n\1    return  # NDK: zig embeds its sysroot; host \/usr\/include must not leak in/' setup.py ;;
    esac

    # Neutralise the build host's pkg-config (PKG_CONFIG=/bin/false). These are
    # cross builds, so a host pkg-config only ever reports x86_64-linux libs;
    # letting CPython's configure see it wrongly flips Makefile-built modules
    # (zlib/_lzma/_uuid/...) to "enabled" against libraries the cross sysroot
    # lacks, which then fail to link. The image carries pkg-config purely so the
    # windows autoreconf can expand PKG_CHECK_MODULES; this keeps every build's
    # module set identical to a host without pkg-config installed at all.
    local args=( --prefix="$PWD/build" --build=x86_64-linux-gnu --host="$TARGET"
                 --with-build-python --without-ensurepip
                 CONFIG_SITE=config.site TARGET="$TARGET" PKG_CONFIG=/bin/false
                 CC="$CROSS_CC" AS="$CROSS_CC" CXX="$CROSS_CXX" LD="$CROSS_LD" OBJCOPY="$CROSS_OBJCOPY"
                 READELF="$NDK_LLVM_BIN/llvm-readelf" LLVM_PROFDATA="$NDK_LLVM_BIN/llvm-profdata"
                 AR="$CROSS_AR" RANLIB="$CROSS_RANLIB" STRIP="$CROSS_STRIP" )
    # mingw is a shared build (libpython3.11.dll) and lets configure derive
    # _PYTHON_HOST_PLATFORM (mingw); every other host is a static interpreter.
    if [ "$PLATFORM" != windows ]; then
      args+=( --disable-shared --disable-ipv6 LDSHARED="$CROSS_CC -shared -fPIC"
              _PYTHON_HOST_PLATFORM="$TARGET" )
    fi
    # _ctypes_test: test-only module, never useful in an NDK host tool.
    # _ctypes has no py_cv_module_ knob; it self-skips when ffi.h is absent,
    # which is always the case here since libffi is never built.
    args+=( py_cv_module__ctypes_test=n/a )
    case "$PLATFORM" in
      bionic) # grp: bionic only declares/exports the getgrent/setgrent/endgrent
              # family from API 26, so below that grpmodule.c neither compiles
              # (clang hard-errors the implicit decls) nor links -- mark it n/a
              # only when targeting < 26; at 26+ let it build normally.
              local grpna=""; [ "$API" -lt 26 ] && grpna="py_cv_module_grp=n/a"
              args+=( TOOLCHAIN="$TC" API="$API"
                      LD_LIBRARY_PATH="$TC/sysroot/usr/lib/$TARGET"
                      LDFLAGS="-static-libstdc++ -static-libgcc"
                      $grpna ) ;;
      linux)   args+=( CFLAGS="-Wno-error=date-time $CROSS_CFLAGS"
                      CXXFLAGS="-Wno-error=date-time $CROSS_CFLAGS"
                      LDFLAGS="$CROSS_LDFLAGS" ) ;;
      bsd)    # -fPIC: bsd keeps a static libpython but setup.py still emits the
              # stdlib extensions as shared .so, and they reference external
              # preemptible data (PyExc_*, type objects, _Py_NoneStruct) that needs
              # GOT indirection. configure doesn't set CCSHARED=-fPIC for the
              # "unknown" platform tag, so without this the .so links fail with
              # R_AARCH64_* "recompile with -fPIC". Making the whole build PIC is
              # harmless for a static host tool.
              # OpenBSD via zig: CPython (or its transitive headers) defines
              # _POSIX_C_SOURCE, which causes OpenBSD's sys/cdefs.h to set
              # __BSD_VISIBLE=0, hiding u_long (sys/types.h), chflags, wait3/4,
              # dup3, pipe2, preadv/pwritev, getloadavg, etc.  The correct
              # override is -D_BSD_SOURCE, which sys/cdefs.h recognises as an
              # explicit opt-in to BSD visibility even when POSIX macros are set.
              # _GNU_SOURCE has no effect on OpenBSD headers (it is not handled
              # by sys/cdefs.h) and was removed.
              # nis: OpenBSD removed YP/NIS support, so zig ships no
              # rpcsvc/yp_prot.h and nismodule.c can't compile. Mark it n/a only
              # for OpenBSD; FreeBSD/NetBSD still provide the rpcsvc headers.
              local obsd="" nisna=""
              if [ "$SYSTEM_NAME" = OpenBSD ]; then obsd="-D_BSD_SOURCE"; nisna="py_cv_module_nis=n/a"; fi
              args+=( CFLAGS="-fPIC -Wno-error=date-time $obsd $CROSS_CFLAGS"
                      CXXFLAGS="-fPIC -Wno-error=date-time $obsd $CROSS_CFLAGS"
                      LDFLAGS="$CROSS_LDFLAGS" $nisna ) ;;
      macos)  # _DARWIN_C_SOURCE: expose BSD extensions masked by _POSIX_C_SOURCE
              #   (needed so sendfile() is declared; -Wno-error alone won't help
              #   because Python re-appends -Werror=implicit-function-declaration).
              # LDSHARED: use -bundle -undefined dynamic_lookup (not -shared -fPIC)
              #   so ld64 defers Python API symbols to the interpreter at dlopen().
              args+=( CFLAGS="-D_DARWIN_C_SOURCE -Wno-error=date-time $CROSS_CFLAGS"
                      CXXFLAGS="-D_DARWIN_C_SOURCE -Wno-error=date-time $CROSS_CFLAGS"
                      LDFLAGS="$CROSS_LDFLAGS"
                      LDSHARED="$CROSS_CC -bundle -undefined dynamic_lookup" ) ;;
      windows) # mingw: shared interpreter linking libpython3.11.dll. Static the
               # compiler runtime so python.exe/.dll don't drag in llvm-mingw's
               # libc++/unwind DLLs; i686 wants --large-address-aware (matches the
               # msys2 mingw-w64-python recipe). WINDRES compiles the PC/*.rc
               # resource files (python_nt.o etc., needed by the DLL/exe links);
               # llvm-mingw's bin is off PATH, so configure can't auto-detect it.
               # -Wno-incompatible-pointer-types: clang makes this diagnostic a
               # hard error by default, but _multiprocessing/semaphore.c passes an
               # int* to _GetSemaphoreValue(HANDLE, long*) on every mingw target;
               # downgrade it so the extension (and any sibling) keeps building.
               local laa=""; [ "$TARGET" = i686-w64-mingw32 ] && laa=" -Wl,--large-address-aware"
               args+=( --enable-shared
                       CFLAGS="-O2 -Wno-error=implicit-function-declaration -Wno-error=date-time -Wno-incompatible-pointer-types"
                       CXXFLAGS="-O2 -Wno-error=implicit-function-declaration -Wno-error=date-time -Wno-incompatible-pointer-types"
                       LDFLAGS="-static-libstdc++ -static-libgcc$laa"
                       LDSHARED="$CROSS_CC -shared"
                       WINDRES="$TC/bin/${TARGET}-windres" ) ;;
    esac
    ./configure "${args[@]}"
    # windows: the extension-module pass (sharedmods -> setup.py build) links each
    # .pyd against -lpython3.11, but the Makefile's sharedmods rule has no
    # dependency on the import library libpython3.11.dll.a (emitted as a side
    # effect of the libpython3.11.dll link rule). Under -j that races -> a swarm
    # of "lld: error: unable to find library -lpython3.11". Build the DLL (and
    # thus its import lib) first so it always exists before the extensions link.
    [ "$PLATFORM" = windows ] && make -j"$(ncpu)" libpython3.11.dll
    make -j"$(ncpu)" build_all
    make install
  )
}

# --- strip the freshly built host tools -------------------------------------
strip_deps() {
  local files f
  if [ "$PLATFORM" = windows ]; then
    files=( "$BUILD/make/build/bin/make.exe"
            "$BUILD/yasm/build/bin/yasm.exe" "$BUILD/yasm/build/bin/ytasm.exe" "$BUILD/yasm/build/bin/vsyasm.exe"
            "$BUILD/python/build/bin/python3.11.exe" "$BUILD/python/build/bin/libpython3.11.dll" )
  else
    files=( "$BUILD/make/build/bin/make"
            "$BUILD/yasm/build/bin/yasm" "$BUILD/yasm/build/bin/ytasm" "$BUILD/yasm/build/bin/vsyasm"
             "$BUILD/python/build/bin/python3.11" )
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
  fetch --dir=/tmp -o llvm-custom.tar.xz "https://github.com/${REPO_OWNER}/llvm-custom/releases/download/llvm-r${NDK_VERSION}/${name}.tar.xz" && tar -xJf /tmp/llvm-custom.tar.xz -C "$BUILD" && rm /tmp/llvm-custom.tar.xz
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
  sed -i 's,#!/bin/bash,#!/bin/sh,' "$PREBUILT_BIN/ndk-gdb" "$PREBUILT_BIN/ndk-stack" "$PREBUILT_BIN/ndk-which" "$NDK_TOOLCHAIN/bin/lldb.sh"
  cp "$ROOT/patches/ndk/scripts/clang-tidy.sh" "$NDK_TOOLCHAIN/bin"
  cp "$ROOT/patches/ndk/scripts/ndk-which" "$PREBUILT_BIN"

  fixup_host_arch
  [ "$PLATFORM" = bsd ] && fixup_bsd_host_os
  [ "$PLATFORM" = macos ] && fixup_macos_host_os

  # remove unused resources
  rm -rf "$NDK_TOOLCHAIN/python3"
  rm -rf "$NDK_TOOLCHAIN/musl"
  rm -rf "$NDK/simpleperf"                 # can't build simpleperf as it requires AOSP sources
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
  cp "$BUILD/python/build/bin/python3.11" "$NDK_TOOLCHAIN/python3/bin/python3"
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

# macos: stock ndk_bin_common.sh folds darwin-arm64 onto darwin-x86_64 because
# Google ships *universal* darwin binaries in the darwin-x86_64 dir. We ship a
# separate per-arch artifact per darwin host, so drop that remap and let ndk-build
# resolve the real darwin-<arch> prebuilt dir that rename_host produced.
fixup_macos_host_os() {
  sed -i '/if \[ \$HOST_TAG = darwin-arm64 \]; then/,/^fi$/d' "$NDK/build/tools/ndk_bin_common.sh"
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

# rename prebuilt/<host> dirs to the target host tag + leave a fallback symlink.
# The fallback tag is host-OS specific: linux hosts fall back to linux-x86_64,
# but darwin hosts must fall back to darwin-x86_64 (never linux-x86_64).
rename_host() {
  local tag arch link
  arch="$(host_tag_arch)"
  case "$PLATFORM" in
    bionic)  [ "$TARGET" = x86_64-linux-android ] && return 0; tag="linux-$arch" ;;
    linux)    case "$TARGET" in x86_64-linux-musl|x86_64-linux-muslx32|x86_64-linux-gnu|x86_64-linux-gnux32) return 0 ;; esac; tag="linux-$arch" ;;
    bsd)     tag="${SYSTEM_NAME,,}-$arch" ;;
    macos)   tag="darwin-$arch" ;;
  esac

  case "$PLATFORM" in
    macos)   link="darwin-x86_64" ;;
    *)       link="linux-x86_64" ;;
  esac

  mv "$NDK/prebuilt/linux-x86_64" "$NDK/prebuilt/$tag"
  mv "$NDK/toolchains/llvm/prebuilt/linux-x86_64" "$NDK/toolchains/llvm/prebuilt/$tag"
  mv "$NDK/shader-tools/linux-x86_64" "$NDK/shader-tools/$tag"
  # only add the fallback symlink when the real dir isn't already that tag
  if [ "$tag" != "$link" ]; then
    ( cd "$NDK/toolchains/llvm/prebuilt" && ln -s "$tag" "$link" )
    ( cd "$NDK/prebuilt" && ln -s "$tag" "$link" )
    ( cd "$NDK/shader-tools" && ln -s "$tag" "$link" )
  fi
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
    macos)
      # uname -m on a Mac reports only arm64 / x86_64 (never the arm64e / x86_64h
      # sub-slices), so collapse both variants onto the base arch's host tag.
      sed -i -E '/^if\(CMAKE_HOST_SYSTEM_NAME STREQUAL Linux\)$/,/^endif\(\)$/c\
if(CMAKE_HOST_SYSTEM_NAME STREQUAL Darwin)\
    execute_process(\
        COMMAND uname -m\
        OUTPUT_VARIABLE HOST_ARCH\
        OUTPUT_STRIP_TRAILING_WHITESPACE\
    )\
\
    if(HOST_ARCH STREQUAL "arm64" OR HOST_ARCH STREQUAL "arm64e")\
        set(ARCH "arm64")\
    elseif(HOST_ARCH STREQUAL "x86_64" OR HOST_ARCH STREQUAL "x86_64h")\
        set(ARCH "x86_64")\
    else()\
        set(ARCH "${HOST_ARCH}")\
    endif()\
\
    set(ANDROID_HOST_TAG "darwin-${ARCH}")\
\
elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL Linux)\
    set(ANDROID_HOST_TAG "linux-x86_64")\
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
  rm -rf "$NDK/simpleperf"                 # can't build simpleperf as it requires AOSP sources
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
  # python3: the freshly cross-built mingw interpreter. python.exe sits at the
  # python3/ root (the layout ndk-build expects on Windows); getpath walks up
  # from there to find python3/lib/python3.11. libpython3.11.dll rides next to
  # python.exe, as does the llvm-mingw winpthread runtime the binaries pull in.
  mkdir -p "$NDK_TOOLCHAIN/python3/lib"
  cp "$BUILD/python/build/bin/python3.11.exe" "$NDK_TOOLCHAIN/python3/python.exe"
  cp "$BUILD/python/build/bin/libpython3.11.dll" "$NDK_TOOLCHAIN/python3/"
  # libpython3.dll: the stable-ABI forwarder limited-API extensions link against
  [ -f "$BUILD/python/build/bin/libpython3.dll" ] && cp "$BUILD/python/build/bin/libpython3.dll" "$NDK_TOOLCHAIN/python3/"
  cp -R "$BUILD/python/build/lib/python3.11" "$NDK_TOOLCHAIN/python3/lib/"
  pthread_dll="$(find "$TC" -name libwinpthread-1.dll -path "*${TARGET}*" 2>/dev/null | head -n1 || true)"
  [ -n "$pthread_dll" ] && cp "$pthread_dll" "$NDK_TOOLCHAIN/python3/"
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
