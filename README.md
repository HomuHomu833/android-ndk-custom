# Android NDK Custom

A custom-built Android NDK that replaces the default toolchain with a modified LLVM using **musl libc from [Zig](https://ziglang.org)** and **[Cosmopolitan](https://justine.lol/cosmopolitan)**. Inspired by [Zongou's build system](https://github.com/zongou/build/tree/main/.github/workflows).

## Features

- **Custom LLVM** build, sourced from Google's repositories.
- Built using Zig, Cosmopolitan and Android NDK itself.
- **Additional Tools Built**:
  - **Shaderc**
  - **Python**
  - **Make**
  - **Yasm**

### Architecture and Platform Support

- **Zig-based Environment**
  - **Platforms**:
    - Windows **(Planned)**
    - Linux
    - Android
    - NetBSD **(Planned)**
    - FreeBSD **(Planned)**
  - **Architectures**:
    - **X**: `x86`, `x86_64`
    - **ARM**: `armhf`, `armeb`, `aarch64`, `aarch64_be`
    - **RISC-V**: `riscv32`, `riscv64`
    - **PowerPC**: `powerpc`, `powerpc64`, `powerpc64le`
    - **MIPS**: `mips`, `mipsel`, `mips64`, `mips64el`
    - **Other**: `loongarch64`, `s390x`

- **Cosmopolitan Environment**
  - **Platforms**:
    - Windows
    - Linux
    - macOS
    - Android
    - NetBSD
    - FreeBSD
    - OpenBSD 7.3
  - **Architectures**:
    - **X**: `x86_64`
    - **ARM**: `aarch64`
   
- **Bionic Environment**
  - **Platforms**:
    - Android
  - **Architectures**:
    - **X**: `x86`, `x86_64`
    - **ARM**: `armv7a`, `aarch64`

## Usage

This NDK functions like the standard Android NDK. Simply extract the archive and use it as you would with the official version.

## License

This project is licensed under the **MIT License**. See the [LICENSE](LICENSE) file for more details.

---

Feel free to open pull requests or issues if you have any contributions or feedback!
