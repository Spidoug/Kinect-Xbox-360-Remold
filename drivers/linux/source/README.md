# Kinect Xbox 360 Remold — Linux V1 source

This directory contains the complete Linux-native runtime source. Kinect protocol and stream ownership stay in user space; Linux provides generic USB, ALSA/USB Audio, V4L2 and systemd/udev facilities.

## Camera and Depth

`kinect360-remold-camera` claims the Kinect for Xbox 360 (1414/1473) camera interface directly through `libusb-1.0`:

- endpoint `0x81` — RGB / RGB-HQ / IR video engine;
- endpoint `0x82` — Depth;
- raw depth factory constants — metric conversion;
- one stable registry entry and Unix socket per physical Kinect;
- concurrent application subscribers through bounded client queues.

V1 RGB-HQ exposes raw 1280×1024 GRBG8 Bayer frames while requested by an HQ Scanner client. Ordinary RGB clients receive a VGA representation from the same color-engine session. Raw IR and RGB remain mutually exclusive per physical Kinect because they share the sensor video engine. Depth remains concurrent.

The public OpenKinect/libfreenect implementation is a protocol reference and is credited in `../../../THIRD-PARTY-NOTICES.md`. The Linux Remold runtime does not link to `libfreenect.so`.

## Audio

The NUI Audio boot identity receives Microsoft UACFirmware through libusb. After re-enumeration in the Runtime 1.8 `045e:02bb/02c3` family, ALSA owns the four-channel USB Audio capture endpoint. The Remold audio service fans that stream out to microphone and acoustic consumers.

The firmware image is not committed to the repository. V1 uses Runtime 1.8 UACFirmware 01.02.709.00 on both platforms; Linux accepts that current raw image through `KINECT_UAC_FIRMWARE` or `source/firmware/UACFirmware-01.02.709.00` and does not download non-V1 SDK firmware packages.

## Plug and play

udev recognizes Kinect USB identities and requests `kinect360-remold.target` through `SYSTEMD_WANTS`. The target is not enabled as an unconditional boot service. Native services remain alive after activation and retry device discovery after disconnect/reconnect.

The camera service atomically publishes:

```text
/run/kinect360-remold/devices.tsv
/run/kinect360-remold/devices/<device-id>.sock
```

SynKinect Studio uses the registry for device selection; Surveillance subscribes to all listed Kinects.

## Build

From `drivers/linux/`:

```bash
./BUILD.sh --clean
```

The build compiles current source and stages generated output under `drivers/linux/dist/<architecture>/`. That output is intentionally excluded from the source release.

Dependencies: CMake, C++17 compiler, pkg-config, libusb-1.0 development headers, ALSA development headers and libjpeg development headers.

## Install

```bash
sudo ./INSTALL.sh --direct
```

The installer compiles current source in a temporary build directory and installs that exact build.

## Packages

Debian:

```bash
./packages/build-deb.sh amd64
```

RPM: use `packages/build-rpm.sh` on an RPM build host.

Both package paths compile the current source and never consume a repository binary payload.

## Validation

```bash
./VERIFY-V1.sh
```

Use `--require-hardware-build` to make missing hardware development dependencies a validation failure.
