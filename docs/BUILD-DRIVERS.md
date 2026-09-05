# Native driver build — V1 source-only policy

## Release invariant

The V1 repository is distributed here as a **clean source release**.

Generated native files such as `.exe`, `.dll`, `.sys`, `.cat`, ELF executables, `.deb`, `.rpm`, generated JAR/runtime payloads and temporary build directories are build outputs. They are intentionally absent from the source ZIP and ignored by `.gitignore`.

This guarantees that a package cannot silently mix current source with an executable from another build.

## Windows x64

Requirements:

- Windows 11 x64;
- Windows PowerShell 5.1 or newer;
- Internet access for the first clean build when prerequisites are absent.

`BUILD.cmd` first uses any healthy installed toolchain. If native prerequisites are missing, the V1 preflight applies the bundled snapshot of Microsoft's official WDK WinGet configuration. That configuration installs Visual Studio Community with the desktop driver-development component set plus Windows SDK/WDK 10.0.28000; WinGet/Visual Studio may request administrator approval as needed. No Python build dependency is used. If JDK 17+ is absent, the Studio builder downloads the pinned Microsoft OpenJDK archive, validates its published SHA-256 and keeps it under the repository-local `.cache`; the generated application receives one minimal Java runtime produced by `jdeps`/`jlink`.

Build from the repository root (recommended for double-click use):

```text
BUILD.cmd
```

The root launcher first runs the Studio build/dependency bootstrap and then the native Windows build, whose preflight bootstraps missing Microsoft C++/SDK/WDK prerequisites through the bundled Microsoft WDK WinGet configuration and validates the installed toolchain before compiling. It always leaves the console open after success or failure. The equivalent developer shortcuts are:

```text
scripts\windows\BUILD-STUDIO.cmd
scripts\windows\BUILD-DRIVER.cmd
drivers\windows\BUILD.cmd
```

The build system compiles the current source tree, generates `applications\binaries\` for the Studio runtime payload and creates `drivers\windows\binaries\` as a generated publication directory. The build recreates those directories, compiles the camera bridge, multi-Kinect transport, RGB-HQ path, motor/device services, audio bridge, virtual camera, IP camera and setup tools, then generates/signs the PnP catalogs according to the configured development/release signing environment.

The source release does not contain those directories before the build.

SynKinect Studio no longer depends on pre-staged JARs. The Windows/Linux Studio builders bootstrap pinned Processing Core 4.4.6, JOGL 2.5.0 and GlueGen 2.5.0 artifacts into the generated runtime, validate them by SHA-256 and copy launcher templates from `applications/runtime-templates/`.

The Windows virtual camera is fixed to the stable 640×480/30 RGB publication and never requests a physical Kinect mode change.

## Linux x86-64

Required development packages:

- C++17 compiler;
- CMake;
- pkg-config;
- libusb-1.0 development headers;
- ALSA development headers;
- libjpeg development headers;
- v4l2loopback >= 0.15.0 for the installed webcam runtime.

Build current source:

```bash
./scripts/linux/BUILD-DRIVER.sh --clean
```

Generated output is placed under:

```text
drivers/linux/dist/<architecture>/
```

This directory is generated and is not part of the source release.

### Debian package

```bash
./drivers/linux/packages/build-deb.sh amd64
```

The package builder performs a **fresh CMake compile inside a temporary build directory**, stages those exact executables and then creates:

```text
drivers/linux/packages/output/kinect360-remold_1.0-1_amd64.deb
```

No precompiled binary directory is an input to the package builder.

### RPM package

Build on an RPM-family build host with:

```bash
./drivers/linux/packages/build-rpm.sh
```

The script creates a temporary source tarball from `drivers/linux/source/` and runs `rpmbuild` with `packages/rpm/kinect360-remold.spec`. The spec has its own CMake `%build` stage and installs only from that fresh build.

## Linux validation

Run:

```bash
./drivers/linux/VERIFY-V1.sh
```

The validator checks the source-only invariant, shell syntax, udev policy, systemd lifecycle, multi-Kinect/camera transport contracts and a C++17 control build. When libusb/ALSA development packages are available, it also compiles the complete hardware runtime and exercises the Debian package builder.

To require the complete hardware compile:

```bash
./drivers/linux/VERIFY-V1.sh --require-hardware-build
```

## Source release validation

Run:

```bash
./scripts/VERIFY-SOURCE-RELEASE.sh
```

This check rejects committed native driver binaries/packages, generated driver output directories, generated Studio payloads, and non-V1 singleton/Surveillance text contracts.
