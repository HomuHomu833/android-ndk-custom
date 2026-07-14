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
# Build make/yasm/shaderc/python, fetch the llvm-custom toolchain, splice into the
# official NDK, then archive (xz; 7z for windows).
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

# Download with retries: re-run aria2c on any failure so transient GitHub errors
# recover. Pass aria2c args, e.g. fetch --dir=/tmp -o f.zip URL.
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

# BSD system name (FreeBSD/NetBSD/OpenBSD) from field 2 of the triple.
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

  # yasm version from the official NDK's prebuilt yasm
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
      # Darwin host tools use osxcross (cctools + clang wrappers); zig segfaults
      # on macOS targets. Wrappers carry the SDK sysroot.
      TC=/opt/osxcross
      # osxcross bin on PATH so clang finds the cctools linker (<triple>-ld) for
      # every link, including CMake's compiler probes.
      export PATH="$TC/bin:$PATH"
      case "$TARGET" in
        arm64e-*)          ARCH=arm64e ;;   # distinct PAC ABI, not arm64
        aarch64-*|arm64-*) ARCH=arm64 ;;
        x86_64h-*)         ARCH=x86_64h ;;  # Haswell+ x86_64 slice (same ABI)
        x86_64-*)          ARCH=x86_64 ;;
        *) echo "Unsupported macOS arch in TARGET='$TARGET'" >&2; exit 1 ;;
      esac
      # wrapper names carry the SDK's darwin version; glob it rather than pin.
      CCWRAP="$(ls "$TC/bin/${ARCH}-apple-darwin"*-clang 2>/dev/null | head -n1 || true)"
      [ -n "$CCWRAP" ] || { echo "osxcross clang wrapper for $ARCH not found in $TC/bin" >&2; exit 1; }
      HOST="$(basename "${CCWRAP%-clang}")"
      CROSS_CC="$TC/bin/${HOST}-clang"; CROSS_CXX="$TC/bin/${HOST}-clang++"
      CROSS_AR="$TC/bin/${HOST}-ar"; CROSS_RANLIB="$TC/bin/${HOST}-ranlib"
      CROSS_STRIP="$TC/bin/${HOST}-strip"; CROSS_LD="$TC/bin/${HOST}-ld"
      CROSS_OBJCOPY=""                  # cctools ships no objcopy; unused here
      NDK_HOST=linux-x86_64; SYSTEM_NAME=Darwin
      # shaderc calls a bare `libtool -static -o`; shim the cctools libtool onto
      # PATH so it wins over host GNU libtool (which can't merge archives).
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

  # Extra cmake (shaderc) flags: env-supplied plus Darwin SDK/arch/deployment
  # pins so CMake doesn't probe a host Xcode. Other platforms need none.
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
                      LDFLAGS="-static -Wl,--undefined-version"
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
      bionic)  args+=( LDFLAGS="-static" ) ;;
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
    case "$PLATFORM" in
      windows)
        make -j"$(ncpu)" install
        ;;
      macos)
        make CC=/usr/bin/cc genperf genmacro genversion genstring
        make -j"$(ncpu)" install
        ;;
      *)
        make CC=/usr/bin/cc re2c genperf genmacro genversion genstring
        make -j"$(ncpu)" install
        ;;
    esac
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
    # spirv-tools rejects unknown platforms; downgrade to a warning, assume Linux
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
    bionic)  exelink="-static" ;;
    linux)    exelink="$CROSS_LDFLAGS"; cflags="$CROSS_CFLAGS"
             [ "$TARGET" = hexagon-linux-musl ] && cflags="-Wno-bitfield-width -Wno-error=bitfield-width $CROSS_CFLAGS" ;;
    bsd)     cflags="-Wno-error=date-time $CROSS_CFLAGS"; exelink="$CROSS_LDFLAGS" ;;
    macos)   cflags="-Wno-error=date-time $CROSS_CFLAGS"; exelink="$CROSS_LDFLAGS" ;;
    windows) exelink="-static-libstdc++ -static-libgcc -pthread"; cflags="-Wno-error=implicit-function-declaration" ;;
  esac
  # pass CMAKE_OBJCOPY only when the toolchain has one (empty on macos).
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
# windows builds the msys2-contrib cpython-mingw fork (vanilla CPython can't
# build under mingw); every other host uses the upstream tarball.
build_python() {
  log "Building Python 3.11.4"
  ( cd "$BUILD"
    if [ "$PLATFORM" = windows ]; then
      # mingw-v3.11.4 branch = CPython 3.11.4 + msys2 mingw patches; its
      # generated configure is stale, regenerated via autoreconf below.
      fetch --dir=/tmp -o python.tar.gz "https://codeload.github.com/msys2-contrib/cpython-mingw/tar.gz/refs/heads/mingw-v3.11.4" && tar -xzf /tmp/python.tar.gz && rm /tmp/python.tar.gz
      rm -rf python; mv cpython-mingw-mingw-v3.11.4 python
    else
      fetch --dir=/tmp -o python.tar.xz https://www.python.org/ftp/python/3.11.4/Python-3.11.4.tar.xz && xz -d < /tmp/python.tar.xz | tar -x && rm /tmp/python.tar.xz
      rm -rf python; mv Python-3.11.4 python
    fi
    cd python
    # the bsd configure carries the Darwin cross-build fixups too
    case "$PLATFORM" in bsd|macos) cp "$ROOT/patches/bsd/python/configure" "$PWD/configure" ;; esac
    # OpenBSD: thread_pthread.h calls getthrid() under #ifdef __OpenBSD__ (not a
    # HAVE_ knob); zig's headers don't declare it, so inject a forward decl.
    if [ "$SYSTEM_NAME" = OpenBSD ]; then
      sed -i 's|#elif defined(__OpenBSD__)|#elif defined(__OpenBSD__)\n    extern pid_t getthrid(void); /* not in zig cross headers */|' Python/thread_pthread.h
    fi
    # bionic: configure sets HAVE_SEM_CLOCKWAIT but bionic only ships
    # sem_clockwait from API 30. Supply an implementation for API < 30 by
    # including it into thread_pthread.h (its only user). It goes here, not via a
    # global -include, because the header pulls system headers and CPython
    # requires Python.h before any system header — thread_pthread.h is included
    # well after Python.h, so the ordering stays correct.
    if [ "$PLATFORM" = bionic ]; then
      cp "$ROOT/patches/bionic/sem_clockwait.h" Python/sem_clockwait.h
      sed -i '1i #include "sem_clockwait.h"' Python/thread_pthread.h
      # close_range: bionic ships it from API 34, but configure enables
      # HAVE_CLOSE_RANGE, so its callers (fileutils.c, _posixsubprocess.c) fail to
      # compile below 34. Inject a syscall-backed impl right after each caller's
      # Python.h (so it follows Python's feature macros). grep tracks the caller
      # set across CPython versions.
      cr="$ROOT/patches/bionic/close_range.h"
      grep -rl 'close_range(' Python Modules 2>/dev/null | while IFS= read -r f; do
        sed -i "s|#include \"Python.h\"|#include \"Python.h\"\n#include \"$cr\"|" "$f"
      done
      # libc_compat: aggregate shim for ctermid, futimes, lutimes, fexecve,
      # and posix_spawn.  Each function is either missing from bionic entirely
      # (ctermid) or hidden from headers below its API level (futimes/lutimes
      # at API<26, posix_spawn at API<28) or suppressed by CPython's _POSIX_C_SOURCE
      # (fexecve).  Inject the compat header after Python.h in every file that
      # references one of the affected functions.
      lc="$ROOT/patches/bionic/libc_compat.h"
      for fn in ctermid futimes lutimes fexecve posix_spawn preadv2 pwritev2 copy_file_range getloadavg; do
        grep -rl "${fn}(" Python Modules 2>/dev/null | while IFS= read -r f; do
          grep -qF "$lc" "$f" && continue
          sed -i "s|#include \"Python.h\"|#include \"Python.h\"\n#include \"$lc\"|" "$f"
        done
      done
    fi
    # windows: regenerate configure from the patched configure.ac
    [ "$PLATFORM" = windows ] && autoreconf -vfi
    # newer config.sub/config.guess (exotic triples); after autoreconf, which
    # would otherwise overwrite them
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
    [ "$PLATFORM" = bionic ] && printf 'ac_cv_header_spawn_h=no\n' >> config.site
    # macos: configure defines HAVE_SENDFILE, but the prototype is hidden without
    # _DARWIN_C_SOURCE; mkfifoat/mknodat pull in compiler-rt availability checks.
    # Host tools need none, so disable all three.
    [ "$PLATFORM" = macos ] && printf 'ac_cv_func_sendfile=no\nac_cv_func_mkfifoat=no\nac_cv_func_mknodat=no\n' >> config.site
    # OpenBSD: configure link tests pass (zig's libc is musl-derived) but these
    # are wrong/absent on OpenBSD, so force CPython's fallbacks: memrchr (not
    # declared), sendfile (BSD ABI), getrandom (use getentropy), posix_fadvise/
    # posix_fallocate (absent).
    if [ "$SYSTEM_NAME" = OpenBSD ]; then
      printf 'ac_cv_func_memrchr=no\nac_cv_func_sendfile=no\nac_cv_func_getrandom=no\nac_cv_func_posix_fadvise=no\nac_cv_func_posix_fallocate=no\n' >> config.site
    fi
    # NetBSD: memfd_create is Linux-only, and dup3 is exported as __dup3100 which
    # zig's libc stubs lack; both break the interpreter link. Use the fallbacks.
    if [ "$SYSTEM_NAME" = NetBSD ]; then
      printf 'ac_cv_func_memfd_create=no\nac_cv_func_dup3=no\n' >> config.site
    fi
    # Link every stdlib extension into the interpreter instead of emitting .so:
    # force MODULE_BUILDTYPE=static and point MODULES_SETUP_STDLIB at Setup.stdlib
    # (as the wasm path does) so setup.py builds nothing shared. Needed when the
    # interpreter is a static executable with no working dlopen at runtime:
    #  - linux/musl: zig's musl is static-only.
    #  - bionic:     host tools are linked -static.
    force_static_modules=no
    [ "$PLATFORM" = bionic ] && force_static_modules=yes
    case "$TARGET" in *musl*) [ "$PLATFORM" = linux ] && force_static_modules=yes ;; esac
    if [ "$force_static_modules" = yes ]; then
      sed -i '/^case \$host_cpu in #(/,/^esac$/c\
MODULE_BUILDTYPE=static
' configure
      sed -i 's#^\([[:space:]]*\)MODULES_SETUP_STDLIB=$#\1MODULES_SETUP_STDLIB=Modules/Setup.stdlib#' configure
    fi
    # linux/bsd (zig): neuter setup.py's add_cross_compiling_paths(). Its
    # `$(CC) -E -v` probe leaks the host's /usr/include into the cross build,
    # breaking every extension. zig resolves its own sysroot internally, so drop
    # the probe. macos/mingw report correct sysroots and keep it.
    case "$PLATFORM" in
      linux|bsd) sed -i 's/^\( *\)def add_cross_compiling_paths(self):/\1def add_cross_compiling_paths(self):\n\1    return  # NDK: zig embeds its sysroot; host \/usr\/include must not leak in/' setup.py ;;
    esac

    # PKG_CONFIG=/bin/false: host pkg-config reports x86_64-linux libs and would
    # wrongly enable modules (zlib/_lzma/_uuid/...) the cross sysroot lacks.
    local args=( --prefix="$PWD/build" --build=x86_64-linux-gnu --host="$TARGET"
                 --with-build-python --without-ensurepip
                 CONFIG_SITE=config.site TARGET="$TARGET" PKG_CONFIG=/bin/false
                 CC="$CROSS_CC" AS="$CROSS_CC" CXX="$CROSS_CXX" LD="$CROSS_LD" OBJCOPY="$CROSS_OBJCOPY"
                 READELF="$NDK_LLVM_BIN/llvm-readelf" LLVM_PROFDATA="$NDK_LLVM_BIN/llvm-profdata"
                 AR="$CROSS_AR" RANLIB="$CROSS_RANLIB" STRIP="$CROSS_STRIP" )
    # mingw is a shared build (libpython3.11.dll); every other host is static.
    if [ "$PLATFORM" != windows ]; then
      args+=( --disable-shared --disable-ipv6 LDSHARED="$CROSS_CC -shared -fPIC"
              _PYTHON_HOST_PLATFORM="$TARGET" )
    fi
    # _ctypes_test: test-only, unused. (_ctypes has no knob; it self-skips when
    # ffi.h is absent, which it always is since libffi is never built.)
    args+=( py_cv_module__ctypes_test=n/a )
    case "$PLATFORM" in
      bionic) # grp/pwd n/a below API 26.
              local grpna=""; [ "$API" -lt 26 ] && grpna="py_cv_module_grp=n/a"
              local pwdna=""; [ "$API" -lt 26 ] && pwdna="py_cv_module_pwd=n/a"
              # Stub LIBC_N version script for 32-bit ARM __aeabi_* symbols.
              # Disable test .so modules: -static + i686 libc.a non-PIC conflict.
              local testna="py_cv_module__testimportmultiple=n/a py_cv_module__testmultiphase=n/a py_cv_module_xxlimited=n/a py_cv_module_xxlimited_35=n/a"
              local ndk_vs=""
              case "$TARGET" in arm-*|armv7a-*|armv7l-*)
                ndk_vs="$PWD/ndk_version.map"
                [ -f "$ndk_vs" ] || printf '%s\n' 'LIBC_N { };' > "$ndk_vs"
                ndk_vs="-Wl,--version-script=$ndk_vs"
              esac
              args+=( TOOLCHAIN="$TC" API="$API"
                      LD_LIBRARY_PATH="$TC/sysroot/usr/lib/$TARGET"
                      LDFLAGS="-static $ndk_vs"
                      $grpna $pwdna $testna ) ;;
      linux)   args+=( CFLAGS="-Wno-error=date-time $CROSS_CFLAGS"
                      CXXFLAGS="-Wno-error=date-time $CROSS_CFLAGS"
                      LDFLAGS="$CROSS_LDFLAGS" ) ;;
      bsd)    # -fPIC: configure omits CCSHARED for the "unknown" platform tag,
              # so the shared stdlib .so fail to link (R_AARCH64_* "recompile
              # with -fPIC"); build everything PIC. OpenBSD: -D_BSD_SOURCE
              # restores BSD visibility hidden when CPython sets _POSIX_C_SOURCE.
              # nis: OpenBSD dropped YP/NIS (no rpcsvc/yp_prot.h), so mark n/a.
              local obsd="" nisna=""
              if [ "$SYSTEM_NAME" = OpenBSD ]; then obsd="-D_BSD_SOURCE"; nisna="py_cv_module_nis=n/a"; fi
              args+=( CFLAGS="-fPIC -Wno-error=date-time $obsd $CROSS_CFLAGS"
                      CXXFLAGS="-fPIC -Wno-error=date-time $obsd $CROSS_CFLAGS"
                      LDFLAGS="$CROSS_LDFLAGS" $nisna ) ;;
      macos)  # _DARWIN_C_SOURCE: expose BSD extensions masked by _POSIX_C_SOURCE.
              # LDSHARED -bundle -undefined dynamic_lookup: defer Python API
              # symbols to the interpreter at dlopen().
              args+=( CFLAGS="-D_DARWIN_C_SOURCE -Wno-error=date-time $CROSS_CFLAGS"
                      CXXFLAGS="-D_DARWIN_C_SOURCE -Wno-error=date-time $CROSS_CFLAGS"
                      LDFLAGS="$CROSS_LDFLAGS"
                      LDSHARED="$CROSS_CC -bundle -undefined dynamic_lookup" ) ;;
      windows) # mingw shared interpreter. Static the compiler runtime so
               # python.exe/.dll don't drag in llvm-mingw DLLs; i686 wants
               # --large-address-aware. WINDRES compiles the PC/*.rc resources
               # (off-PATH, so pass it explicitly). -Wno-incompatible-pointer-
               # types: semaphore.c mispasses int*/long* on every mingw target.
               local laa=""; [ "$TARGET" = i686-w64-mingw32 ] && laa=" -Wl,--large-address-aware"
               args+=( --enable-shared
                       CFLAGS="-O2 -Wno-error=implicit-function-declaration -Wno-error=date-time -Wno-incompatible-pointer-types"
                       CXXFLAGS="-O2 -Wno-error=implicit-function-declaration -Wno-error=date-time -Wno-incompatible-pointer-types"
                       LDFLAGS="-static-libstdc++ -static-libgcc$laa"
                       LDSHARED="$CROSS_CC -shared"
                       WINDRES="$TC/bin/${TARGET}-windres" ) ;;
    esac
    ./configure "${args[@]}"
    # windows: sharedmods links .pyd against -lpython3.11 but doesn't depend on
    # the import lib, so under -j it races. Build the DLL (and its import lib)
    # first.
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

  # build cmp/echo before the replace loop (bionic needs the official clang the
  # loop later overwrites)
  "$CROSS_CC" $CROSS_CFLAGS "$ROOT/sources/portable_cmp.c" -o "$PREBUILT_BIN/cmp"
  "$CROSS_CC" $CROSS_CFLAGS "$ROOT/sources/portable_echo.c" -o "$PREBUILT_BIN/echo"

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

# macos: stock ndk_bin_common.sh folds darwin-arm64 onto darwin-x86_64 (Google
# ships universal binaries); we ship per-arch, so drop that remap.
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

# rename prebuilt/<host> dirs to the target host tag + a fallback symlink
# (linux->linux-x86_64, darwin->darwin-x86_64).
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
      # uname -m reports only arm64/x86_64, so collapse the sub-slices onto them.
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

  # llvm-custom ships some bin/ entries as symlinks; hard-link them so the copy
  # below picks up real PE files
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
  "$CROSS_CC" $CROSS_CFLAGS "$ROOT/sources/portable_cmp.c" -o "$PREBUILT_BIN/cmp.exe"
  "$CROSS_CC" $CROSS_CFLAGS "$ROOT/sources/portable_echo.c" -o "$PREBUILT_BIN/echo.exe"
  # python3: python.exe at the python3/ root (ndk-build's Windows layout);
  # libpython3.11.dll and the winpthread runtime ride next to it.
  mkdir -p "$NDK_TOOLCHAIN/python3/lib"
  cp "$BUILD/python/build/bin/python3.11.exe" "$NDK_TOOLCHAIN/python3/python.exe"
  cp "$BUILD/python/build/bin/libpython3.11.dll" "$NDK_TOOLCHAIN/python3/"
  # libpython3.dll: stable-ABI forwarder for limited-API extensions
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
