# Linux driver/runtime

## Scope

The Linux implementation is a user-space Kinect 1414/1473 driver/runtime. It does not install a Remold-authored kernel USB driver. Generic Linux facilities provide USB, audio and video infrastructure; Remold owns Kinect protocol, stream policy, IPC and service lifecycle.

## Native components

| Binary | Responsibility |
| --- | --- |
| `kinect360-remold-broker` | motor, tilt, LED and accelerometer/status control |
| `kinect360-remold-camera` | direct libusb RGB/IR/depth acquisition + ScannerPort |
| `kinect360-remold-audio` | UAC firmware bootstrap + ALSA four-channel fan-out |
| `kinect360-remold-v4l2` | V4L2 loopback RGB webcam publication |
| `kinect360-remold-camera-ip` | authenticated HTTP/MJPEG RGB service |
| `kinect360-remoldctl` | command-line status/tilt/LED client |

## Build, install and plug-and-play lifecycle

The V1 source release contains no Linux native executable/package payload. Build and install current source with:

```bash
sudo ./drivers/linux/INSTALL.sh
```

To generate a Debian package from current source:

```bash
./drivers/linux/packages/build-deb.sh amd64
```

For RPM-family systems use `drivers/linux/packages/build-rpm.sh` on the target build host. Both package builders compile the current source before creating a package.

The installed runtime configures:

- udev rules for Kinect USB identities;
- systemd target/services;
- V4L2 loopback module policy;
- `/etc/kinect360-remold/remold.conf`;
- UAC firmware extraction/bootstrap helper;
- the native runtime generated from the current V1 source.

udev requests `kinect360-remold.target` when Kinect hardware appears. The target is not enabled as an unconditional boot target. Runtime services keep retrying device discovery so a normal disconnect/reconnect does not require reinstalling the package.

## IPC

```text
/run/kinect360-remold/control.sock
/run/kinect360-remold/devices.tsv
/run/kinect360-remold/devices/<device-id>.sock
/run/kinect360-remold/audio.sock
/run/kinect360-remold/audio-bridge-status.txt
```

The binary structures are defined in `drivers/linux/source/include/remold/protocol.hpp`.

## Camera ownership and frame delivery

RGB and IR use the same physical video engine and cannot be requested at the same time. Depth has a separate stream and can run concurrently with RGB or IR.

The V4L2 and IP camera bridges acquire RGB on demand. Their purpose is to avoid permanently holding the physical Kinect in RGB mode when no real consumer exists.

ScannerPort uses bounded per-stream queues for RGB, RGB-HQ, IR and Depth. Each client receives frames in timestamp order, with Depth winning timestamp ties. When the final subscriber releases a stream, that stream queue is cleared so a later subscription starts from current capture data.

The Processing `SynKinectStudio` application adds a bounded canonical RGBD queue and a separate bounded reconstruction window. Reconstruction advances toward the newest captured pair and discards stale pending work when it falls behind, preventing unbounded capture-to-reconstruction latency.

## Audio

The Kinect NUI Audio boot device (`045e:02ad`) receives the Microsoft UAC firmware image through libusb. The re-enumerated USB Audio device (`045e:02bb`) is then opened with ALSA as four-channel, 16 kHz, signed 32-bit little-endian PCM.

The firmware image is not committed to the repository. The Linux package's post-install step attempts to obtain/extract it when it is absent; a firmware-download failure does not remove the already installed camera/control runtime, but audio remains unavailable until the firmware is supplied.

## Configuration

Default policy source:

```text
drivers/linux/source/config/remold.conf
```

Installed policy:

```text
/etc/kinect360-remold/remold.conf
```

Current keys include V4L2 output device and IP camera settings. The package generates an IP-camera password rather than shipping a fixed default password.

## Recovery semantics

The services keep retrying device discovery. The camera backend treats failed asynchronous isochronous transfer resubmission or device removal as a dead session, closes the USB handle, clears queued frames and lets the outer loop reopen a clean session. Processing transport shutdown also closes both sides of its local connection so blocked readers are released during tab switches/application exit.

Frame sequence numbers are propagated to Processing. The application reports sequence gaps and queue overflow separately, making data loss observable rather than silently replacing a pending depth frame.
