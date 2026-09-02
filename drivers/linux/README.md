# Linux native runtime — V1

The Linux runtime is built directly from `drivers/linux/source/`. The source release contains no Linux driver executable or `.deb` payload.

## Build

```bash
./BUILD.sh --clean
```

Generated runtime:

```text
dist/<architecture>/
```

Required build facilities include CMake, a C++17 compiler, pkg-config, libusb-1.0 development headers, ALSA development headers and libjpeg development headers.

## Install from current source

Interactive control panel:

```bash
./INSTALL.sh
```

Direct source build + install:

```bash
sudo ./INSTALL.sh --direct
```

The direct installer installs required dependencies on supported package managers unless `--no-deps` is supplied, compiles the current source in a temporary build directory and installs that build.

## Debian package

```bash
./packages/build-deb.sh amd64
```

The package builder performs a fresh compile and then creates `packages/output/kinect360-remold_1.0-1_amd64.deb`. The output directory is generated and is not part of the source release.

## RPM

`packages/rpm/kinect360-remold.spec` compiles the current source in its `%build` stage and installs from that build.

## Validate

```bash
./VERIFY-V1.sh
```

Use `--require-hardware-build` when the machine has all hardware development dependencies and the complete native runtime must compile as a release gate.

## Runtime architecture

The camera/depth backend talks directly to Kinect 1414 using `libusb-1.0`. Linux uses generic kernel USB, ALSA/USB Audio and V4L2 facilities; the Kinect-specific protocol and service policy stay in user space.

The camera runtime enumerates multiple Kinects and publishes a stable manifest plus one Unix socket per physical device. RGB and Depth can fan out to multiple consumers. The optional RGB-HQ stream exposes 1280×1024 GRBG Bayer keyframes while an HQ Scanner client requests it.

See `../../docs/linux/DRIVER-RUNTIME.md` and `../../docs/BUILD-DRIVERS.md`.
