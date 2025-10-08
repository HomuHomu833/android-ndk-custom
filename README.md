# Android NDK Custom

**Android NDK Custom** is a custom-built Android NDK that replaces the default toolchain with a rebuilt **LLVM** and related binaries.

It integrates alternative libc implementations like **musl** (via [Zig](https://ziglang.org)), **[Cosmopolitan](https://justine.lol/cosmopolitan)**, **Bionic** (from the official Android NDK), and **[llvm-mingw](https://github.com/mstorsjo/llvm-mingw)** to provide a more flexible and portable build environment.

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
- ❌ ~~macOS~~ ([#14 comment](https://github.com/HomuHomu833/android-ndk-custom/issues/14#issuecomment-3346720483))  
- Android  
- NetBSD  
- FreeBSD  
- ❌ ~~OpenBSD~~ ([#15 comment](https://github.com/HomuHomu833/android-ndk-custom/issues/15#issuecomment-3378450872))

**Architectures**
- **X86 Family**: `x86`, `x86_64`  
- **ARM Family**: `armhf`, `armeb`, `aarch64`, `aarch64_be`  
- **RISC-V**: `riscv32`, `riscv64`  
- **PowerPC**: `powerpc`, `powerpc64`, `powerpc64le`  
- **MIPS**: `mips`, `mipsel`, `mips64`, `mips64el`  
- **Thumb**: `thumb`, `thumbeb`  
- **Other**: `loongarch64`, `s390x`

---

### 🔹 Cosmopolitan Environment *(Discontinued)*

**Platforms**
- Windows  
- Linux  
- macOS  
- Android  
- NetBSD  
- FreeBSD  
- OpenBSD 7.3  

**Architectures**
- `x86_64`  
- `aarch64`

---

### 🔹 Native Environment

**Platforms**
- Windows  
- Android  

**Architectures**
- `x86`, `x86_64`  
- `armv7a` *(Android-only)*  
- `aarch64`

---

## 🧰 Usage

This custom NDK works as a **drop-in replacement** for the standard Android NDK.  
Simply extract the archive and use it in your build setup just as you would with the official version.

---

## ⚖️ License

This project is licensed under the **MIT License**.  
See the [LICENSE](LICENSE) file for more details.

---

## 💬 **Contributing**  
Feel free to open pull requests or issues with improvements, bug reports, or feedback.
