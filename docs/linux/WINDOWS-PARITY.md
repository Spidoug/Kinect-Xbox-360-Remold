# Windows/Linux functional parity

The two platforms should expose the same user-visible Kinect capabilities, but they do not need — and should not try — to use the same driver architecture.

| Capability | Windows runtime | Linux runtime | Parity |
| --- | --- | --- | --- |
| Motor / tilt / LED / accelerometer | WinUSB native runtime | libusb user-space broker | Yes |
| RGB camera | native camera bridge | direct libusb camera bridge | Yes |
| Infrared camera | native camera bridge | direct libusb camera bridge | Yes |
| Raw Depth + Studio metric conversion | raw 11-bit transport + factory calibration handshake | raw 11-bit transport + factory calibration handshake | Yes |
| RGB + depth | supported | supported | Yes |
| IR + depth | supported | supported | Yes |
| RGB + IR simultaneously | not supported by the single physical video engine | not supported by the single physical video engine | Same hardware limit |
| Four microphones | Microsoft USB Audio + WASAPI bridge | UAC firmware + ALSA bridge | Yes |
| Passive acoustic scanner | four-channel IPC | four-channel IPC | Yes |
| Virtual webcam | Media Foundation path | V4L2 loopback path | Equivalent function |
| Authenticated IP/MJPEG camera | native service | native service | Yes |
| Automatic reconnect | service/native retry | systemd/udev + native retry | Yes |
| Desktop/no-terminal installation | Windows setup package | `.deb` package; RPM recipe supplied | Yes for supported package family |

## Why Linux is different internally

Windows needs Windows-specific USB/audio/camera plumbing and installer integration. Linux already has generic kernel USB, USB Audio, ALSA and V4L2 infrastructure. The Remold Linux runtime therefore stays in user space for Kinect protocol and stream ownership, with `libusb` as the direct camera/control access layer and `v4l2loopback` as the virtual webcam kernel facility.

Installing a custom Remold kernel USB driver only to resemble the Windows stack would increase maintenance and kernel-version risk without adding Kinect functionality.

## Distribution-dependent items

`v4l2loopback` is an external project packaged differently by distributions. The Debian package declares the Debian-family dependency. The RPM spec marks the corresponding facility for the RPM build environment rather than hard-coding one repository-specific package name.

Firewall configuration is also distribution-specific. The IP camera service is installed and configurable on Linux, but this project does not silently rewrite arbitrary firewalld/nftables/ufw policy. A distribution package may add an opt-in firewall integration if its target policy is known.
