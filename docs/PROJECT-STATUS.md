# Project status and validation matrix

Remold is an experimental hardware project. Documentation distinguishes **implemented**, **software-validated**, **hardware-validated**, and **roadmap** states.

## Linux direct USB runtime

| Capability | Implemented in source | Software/build validation | Physical Kinect validation in this development environment |
| --- | ---: | ---: | ---: |
| direct `libusb` camera open/config | yes | yes | pending |
| RGB Bayer 640×480 reassembly/demosaic | yes | yes | pending |
| IR packed 10-bit 640×488 unpack | yes | yes | pending |
| Depth packed 11-bit 640×480 unpack | yes | yes | pending |
| factory depth calibration to mm | yes | code-path validated | pending |
| RGB/IR mutual exclusion | yes | yes | pending under load |
| depth shared with video | yes | yes | pending under load |
| motor tilt/LED/status | yes | build validated | pending |
| UAC firmware bootstrap | yes | build validated | pending `02ad → 02bb` cycle |
| ALSA four-channel capture | yes | build validated | pending device-node validation |
| V4L2 loopback bridge | yes | build validated | pending camera-consumer validation |
| authenticated MJPEG IP camera | yes | build validated | pending end-to-end sensor validation |
| service reconnect loops | yes | process behavior validated without hardware | repeated physical hot-plug pending |

The repository includes x86_64 Linux development binaries for convenient inspection/testing. Hardware certification is **not** implied by their presence.

## Application status

Processing source supports platform-specific local transport selection. The committed exported application bundle remains Windows x64. A clean Linux launcher/application release package is roadmap work.

## Roadmap

These items are architectural targets and must not be advertised as completed:

1. per-endpoint packet loss, resync, latency and effective-FPS telemetry;
2. independent watchdog/restart state machine for RGB/IR, depth and audio;
3. persistent multi-Kinect identity based on USB topology/serial information where available;
4. per-device runtime namespaces such as `kinect0`, `kinect1`, ...;
5. recorded and simulated sensor backends for test automation;
6. automated physical hardware soak tests;
7. exported Linux application bundle.

## Release rule

A future release should move a row from “pending” to hardware-validated only when tested on a physical Kinect with the test conditions recorded. A successful compile is not a substitute for USB isochronous hardware validation.
