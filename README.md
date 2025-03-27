# Android NDK Custom

A custom-built Android NDK that replaces the default toolchain with a modified LLVM, integrating **musl** and **Cosmopolitan libc**. Inspired by [Zongou's build system](https://github.com/zongou/build/tree/main/.github/workflows), this project leverages [Zig](https://ziglang.org) and [Cosmopolitan](https://justine.lol/cosmopolitan) to provide an alternative development environment for Android.

## Features

- **Musl and Cosmopolitan libc** support for enhanced portability.  
- **Custom LLVM** build, sourced from Google's repositories.  
- Built using [Zig](https://ziglang.org) and [Cosmopolitan](https://justine.lol/cosmopolitan) for better cross-compilation.  
- **Additional Tools Built**:  
  - **Shaderc**  
  - **Python** (downloaded via from [Cosmopolitan repository](https://cosmo.zip/pub/cosmos/bin), built in Zig)  
  - **Make** (from GNU source)  
  - **Yasm** (from Debian source)  

### Architecture Support  

- **Zig-based Environment (Linux and Android only)**  
  - **RISC-V**: `riscv32`, `riscv64`  
  - **x86**: `x86`, `x86_64`  
  - **ARM**: `armhf`, `arm64`  
  - **(Planned)** **LoongArch**: `loongarch64`  

- **Cosmopolitan libc Environment**  
  - **Platforms**: Windows, macOS, Linux, Android, NetBSD, FreeBSD, OpenBSD 7.3 (BSD support may not be fully functional)  
  - **Architectures**: `x86_64`, `aarch64`  

## Usage

This NDK functions like the standard Android NDK. Simply extract the archive and use it as you would with the official version.

## License

This project is licensed under the **MIT License**. See the [LICENSE](LICENSE) file for more details.

---

Feel free to open pull requests or issues if you have any contributions or feedback!
