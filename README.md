# Android NDK Custom

**Android NDK Custom** is a custom-built Android NDK that replaces the default toolchain with a rebuilt **LLVM** and related binaries.

It integrates alternative libc implementations like **musl** (via **[Zig](https://ziglang.org)**), **Bionic** (from the official Android NDK), **[llvm-mingw](https://github.com/mstorsjo/llvm-mingw)** and the macOS SDK (via **[osxcross](https://github.com/tpoechtrager/osxcross)**) to provide a more flexible and portable build environment.

This project is inspired by [Zongou’s build system](https://github.com/zongou/build/tree/main/.github/workflows).

---

## 🚀 Features

- **Custom LLVM build** sourced from official Google repositories.
- Built using various toolchain's libc.
- **Additional Tools Built**:
  - **Shaderc**
  - **Python**
  - **Make**
  - **Yasm**

---

## 🧭 Architecture & Platform Support

### 🔹 Zig-based Environment

**Platforms**
- Linux
- Android
- NetBSD
- FreeBSD
- OpenBSD

**Architectures**
- **X86 Family**: `x86`, `x86_64`, `x32`
- **ARM Family**: `armhf`, `armeb`, `aarch64`, `aarch64_be`
- **RISC-V**: `riscv32`, `riscv64`
- **PowerPC**: `powerpc`, `powerpc64`, `powerpc64le`
- **MIPS**: `mips`, `mipsel`, `mips64`, `mips64el`
- **Thumb**: `thumb`, `thumbeb`
- **Other**: `loongarch64`, `s390x`, `hexagon`

---

### 🔹 Native Environment

**Platforms**
- Windows
- macOS
- Android

**Architectures**
- `x86`, `x86_64`
- `aarch64`
- `armv7a` *(Android-only)*
- `arm64e`, `x86_64h` *(macOS-only)*

---

## 🧰 Usage

This custom NDK works as a **drop-in replacement** for the standard Android NDK.<br>
Simply extract the archive and use it in your build setup just as you would with the official version.

---

## ⚖️ License

This project is licensed under the **MIT License**.<br>
See the **[LICENSE](LICENSE)** file for more details.

---

## 💬 Contributing
Feel free to open pull requests or issues if you have any contributions or feedback!
