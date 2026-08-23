# Linux x86_64 development binaries

This directory contains compiled ELF artifacts staged from the current Linux Remold source for x86_64 testing and inspection.

Layout:

```text
bin/kinect360-remoldctl
libexec/kinect360-remold/kinect360-remold-broker
libexec/kinect360-remold/kinect360-remold-camera
libexec/kinect360-remold/kinect360-remold-audio
libexec/kinect360-remold/kinect360-remold-v4l2
libexec/kinect360-remold/kinect360-remold-camera-ip
support/
```

These binaries are **not a claim of physical Kinect certification**. Rebuild on the target distribution with `../../BUILD.sh` when ABI compatibility is important. The normal installer builds from local source before installation.
