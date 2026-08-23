# Kinect Xbox 360 Remold — Linux runtime

This directory is the Linux port of the Remold v1 driver/runtime. It preserves the Windows design rule that **authored Kinect logic stays in user space**. Linux supplies generic USB, ALSA/PipeWire and V4L2 infrastructure; Remold owns device policy and the stable local application protocols.


## Direct libusb camera backend

The Linux camera service no longer links to or loads `libfreenect`. It claims the Kinect v1 camera interface directly through `libusb-1.0`, uses endpoint `0x81` for RGB/IR and `0x82` for depth, and configures the sensor through its USB control protocol. The kernel camera driver is detached automatically while Remold owns the interface and is eligible for reattachment when the handle is released.

RGB is received as 640x480 Bayer and demosaiced inside Remold. IR is received as packed 10-bit data and exposed as Gray16. Depth is received as packed 11-bit data; the service reads zero-plane and constant-shift calibration from the physical Kinect and converts it to millimeters. If factory calibration cannot be read, the frame is not marked calibrated and depth values are withheld instead of falsely labeling raw disparity as millimeters.

The USB protocol behavior was cross-checked against the public OpenKinect/libfreenect implementation. Remold does **not** depend on `libfreenect.so` at build or runtime. Attribution and the referenced Apache-2.0 license text are retained in `../../../THIRD-PARTY-NOTICES.md` and `../../../licenses/Apache-2.0-OpenKinect.txt`.

## Plug and play model

From the repository root, install the packaged x86_64 payload with `sudo ./drivers/linux/INSTALL-PREBUILT.sh`, or build for the target distribution with `sudo ./drivers/linux/INSTALL.sh`.

After installation, reconnecting a Kinect 1414 is automatic. `udev` recognizes `045e:02b0`, `02ae`, `02ad` and the post-firmware `02bb` identity and requests `kinect360-remold.target`. The systemd services are restartable and remain alive when the Kinect is unplugged, so hot-unplug/hot-plug does not require reinstalling anything.

The installer also configures a V4L2 loopback camera at `/dev/video42` named **Kinect Xbox 360 Camera**. Applications that use PipeWire/V4L2 can consume it like another webcam. Scanner/Surveillance clients continue to receive the Remold v1 RGB/IR/depth frame ABI over `/run/kinect360-remold/scanner.sock`.

## Linux component mapping

| Windows v1 | Linux port |
| --- | --- |
| WinUSB Motor | libusb user-space broker (`control.sock`) |
| WinUSB CameraBridge | direct libusb-1.0 camera backend + Remold scanner Unix socket |
| named pipes | Unix Domain Sockets under `/run/kinect360-remold` |
| Media Foundation virtual camera | `v4l2loopback` + `kinect360-remold-v4l2` |
| UACFirmware WinUSB upload | libusb UACFirmware upload using the same Remold boot protocol |
| WASAPI 4-channel capture | ALSA hardware capture after `045e:02bb` re-enumeration |
| Windows service manager | systemd |
| PnP INF matching | udev rules |
| IP camera service | native Linux HTTP/MJPEG service (same shared RGB ownership rule) |

The UAC firmware is not committed to this repository. `fetch-uac-firmware.sh` downloads the same pinned Microsoft Kinect SDK Beta 2 MSI used by the Windows build, validates its MD5 and extracts `UACFirmware` from the embedded MSI cabinet with recursive `7z` extraction.

## IPC endpoints

- `/run/kinect360-remold/control.sock` — tilt, LED, accelerometer/status.
- `/run/kinect360-remold/scanner.sock` — RGB/IR/depth Remold ScannerPort v1 ABI.
- `/run/kinect360-remold/audio.sock` — four-channel S32LE 16 kHz microphone ABI.
- `/run/kinect360-remold/acoustic.sock` — independent audio fan-out for the acoustic scanner.
- `/run/kinect360-remold/audio-bridge-status.txt` — diagnostics compatible with the Processing monitor.

RGB and IR remain mutually exclusive because Kinect 1414 has one raw-video engine. Multiple RGB clients may share the camera. An IR session is rejected with `EBUSY` while RGB consumers are active, and vice-versa. Depth/projector ownership is reference-counted.

## Configuration

Runtime policy is centralized in `/etc/kinect360-remold/remold.conf`. The installer generates an IP-camera password on first install instead of shipping a default password. Important keys:

```text
v4l2.device=/dev/video42
ip.enabled=true
ip.port=8088
ip.user=admin
ip.password=<generated>
ip.jpeg_quality=78
```

## Build without installing

```bash
./scripts/build.sh
```

Dependencies are CMake, a C++17 compiler, libusb-1.0, ALSA development headers, libjpeg and (for webcam publication) v4l2loopback at runtime.

## Hardware validation note

The Linux source is structured to compile against normal distro libraries and talks to the camera with `libusb-1.0` directly, but USB isochronous behavior, the exact ALSA PCM node after the Microsoft UACFirmware transition, V4L2 loopback publication and hot-unplug recovery must still be exercised on a physical Kinect 1414. There is intentionally no kernel module authored by this project.
