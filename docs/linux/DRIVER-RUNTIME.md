# Linux driver/runtime

## Scope

The Linux implementation is a user-space Kinect 1414 driver/runtime. It does not install a Remold-authored kernel USB driver. Generic Linux facilities provide USB, audio and video infrastructure; Remold owns Kinect protocol, stream policy, IPC and service lifecycle.

## Native components

| Binary | Responsibility |
| --- | --- |
| `kinect360-remold-broker` | motor, tilt, LED and accelerometer/status control |
| `kinect360-remold-camera` | direct libusb RGB/IR/depth acquisition + ScannerPort |
| `kinect360-remold-audio` | UAC firmware bootstrap + ALSA four-channel fan-out |
| `kinect360-remold-v4l2` | V4L2 loopback RGB webcam publication |
| `kinect360-remold-camera-ip` | authenticated HTTP/MJPEG RGB service |
| `kinect360-remoldctl` | command-line status/tilt/LED client |

## Plug-and-play lifecycle

Packaged x86_64 install:

```bash
sudo ./drivers/linux/INSTALL-PREBUILT.sh
```

Build-and-install on the target distribution:

```bash
sudo ./drivers/linux/INSTALL.sh
```

The installation sets up:

- udev rules for Kinect USB identities;
- systemd target/services;
- V4L2 loopback module policy;
- `/etc/kinect360-remold/remold.conf`;
- UAC firmware extraction/placement;
- native runtime binaries.

After installation, unplug/replug is handled by service retry loops plus udev/systemd activation. Reinstallation should not be required for normal reconnects.

## IPC

```text
/run/kinect360-remold/control.sock
/run/kinect360-remold/scanner.sock
/run/kinect360-remold/audio.sock
/run/kinect360-remold/acoustic.sock
/run/kinect360-remold/audio-bridge-status.txt
```

The binary structures are defined in `drivers/linux/source/include/remold/protocol.hpp`.

## Camera ownership

RGB and IR use the same physical video engine and cannot be requested at the same time. Depth has a separate stream and can run concurrently with RGB or IR.

The V4L2 and IP camera bridges acquire RGB on demand. Their purpose is to avoid permanently holding the physical Kinect in RGB mode when no real consumer exists.

## Audio

The Kinect NUI Audio boot device (`045e:02ad`) receives the Microsoft UAC firmware image through libusb. The re-enumerated USB Audio device (`045e:02bb`) is then opened with ALSA as four-channel, 16 kHz, signed 32-bit little-endian PCM.

The firmware image is not committed to the repository.

## Configuration

Default policy source:

```text
drivers/linux/source/config/remold.conf
```

Installed policy:

```text
/etc/kinect360-remold/remold.conf
```

Current keys include V4L2 output device and IP camera settings. The installer generates an IP-camera password rather than shipping a fixed default password.

## Recovery semantics

The services are written to keep retrying device discovery. The camera backend also treats a failed asynchronous isochronous transfer resubmission or a removed device as a dead session, closes the USB handle and allows the outer loop to reopen a clean session.

This is currently session-level recovery. Per-stream watchdogs and health telemetry are roadmap items.
