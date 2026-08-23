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

The preferred Debian/Ubuntu/Mint installation is the package generated under:

```text
drivers/linux/packages/output/kinect360-remold_*.deb
```

Open the `.deb` in the file manager/Software installer. The graphical package manager asks for administrator authorization, installs dependencies and executes the same system setup without requiring the user to type installation commands in a terminal.

For Fedora/RHEL-family distributions, build `drivers/linux/packages/rpm/kinect360-remold.spec` in the target RPM build environment. `v4l2loopback` packaging differs among RPM distributions, so its repository/package availability must be satisfied by that distribution.

The package installs/configures:

- udev rules for Kinect USB identities;
- systemd target/services;
- V4L2 loopback module policy;
- `/etc/kinect360-remold/remold.conf`;
- UAC firmware extraction/bootstrap helper;
- native runtime binaries.

The scripted `INSTALL-PREBUILT.sh` and `INSTALL.sh` paths remain available for developers and recovery use, but the graphical package-manager path is recommended for desktop installation.

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

## Camera ownership and frame delivery

RGB and IR use the same physical video engine and cannot be requested at the same time. Depth has a separate stream and can run concurrently with RGB or IR.

The V4L2 and IP camera bridges acquire RGB on demand. Their purpose is to avoid permanently holding the physical Kinect in RGB mode when no real consumer exists.

ScannerPort no longer uses latest-frame-only storage. The native camera bridge keeps bounded FIFO queues for RGB, IR and depth and selects the oldest available timestamp for each client; depth wins timestamp ties. This removes the previous fixed RGB-first priority that could starve depth while RGB was continuously available. When the final user of a stream releases it, that stream's queue is cleared so a later client cannot receive stale frames from the previous session.

The Processing `SynKinectStudio` application adds another bounded capture queue and a separate bounded reconstruction queue. During active 3D scanning it applies backpressure before removing more depth frames from capture, so render/export work cannot silently replace the frame waiting for fusion.

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
