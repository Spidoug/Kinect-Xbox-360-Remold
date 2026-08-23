# Project status and validation matrix — V1

Remold is a hardware-facing project. V1 distinguishes source implementation, software/build validation and physical-Kinect validation.

## Linux direct USB runtime

| Capability | Implemented in source | Software/build validation | Physical Kinect validation in this development environment |
| --- | ---: | ---: | ---: |
| direct `libusb` camera open/config | yes | yes | pending |
| RGB Bayer 640×480 reassembly/demosaic | yes | yes | pending |
| IR packed 10-bit 640×488 unpack | yes | yes | pending |
| depth packed 11-bit 640×480 unpack | yes | yes | pending |
| factory depth calibration to mm | yes | code-path validated | pending |
| independent bounded video/depth FIFOs | yes | build/software validated | pending under sustained hardware load |
| RGB/IR mutual exclusion | yes | yes | pending under load |
| motor tilt/LED/status | yes | build validated | pending |
| UAC firmware bootstrap | yes | build validated | pending `02ad -> 02bb` cycle |
| ALSA four-channel capture | yes | build validated | pending device-node validation |
| V4L2 loopback bridge | yes | build validated | pending consumer validation |
| authenticated MJPEG IP camera | yes | build validated | pending end-to-end validation |
| service reconnect policy | yes | process behavior validated without hardware | repeated physical hot-plug pending |

## SynKinect Studio

| Capability | Implemented | Software validation | Physical Kinect validation |
| --- | ---: | ---: | ---: |
| one-window/five-tab application | yes | structural validation | pending |
| `.pde` with no `static` declarations | yes | checked | n/a |
| Windows named pipe / Linux Unix socket selection | yes | code-path validation | pending full cross-platform device test |
| shared Scanner/Interactivity RGBD synchronizer | yes | compile + offset/out-of-order pairing smoke test | pending sustained physical Kinect test |
| reconstruction drain on pause/exit | yes | code-path validation | pending long scan test |
| Save-file OBJ/STL/PLY export | yes | code-path validation | geometry/output inspection recommended |
| compact indexed mesh export | yes | code-path validation | representative scan size/quality comparison pending |
| Interactivity RGB + metric-Depth 3D fusion | yes | source compile + synthetic RGBD smoke test | pending physical Kinect calibration/tuning |
| shared RGBD acquisition + isolated Interactivity 3D fusion | yes | source compile + canonical-pair/thread-boundary review | pending sustained hardware test |
| face/torso/shoulder/elbow/arm/hand 2D anatomy model | yes | source compile + code-path review | physical anatomy accuracy pending |
| Leap-style palm + fingertip hand model | yes | source compile + code-path review | physical finger-tracking accuracy pending |
| compact Surveillance MP4/H.264 recorder | yes | FFmpeg software encode test | physical event-size/quality validation pending |
| English-first/default language policy | yes | configuration/catalog review | n/a |
| strict V1 audio/acoustic endpoint policy | yes | source/config review | pending Windows/Linux runtime validation |

## Windows runtime

The V1 native source/build system is present and versioned `1.0.0`. A freshly compiled Windows binary payload is intentionally not claimed as part of this source package. The maintainer should build it on the supported Windows toolchain, validate against `drivers/windows/BINARY-PAYLOAD.md`, test with physical hardware and then publish it as a V1 release asset.

## Release rule

Do not move any physical-device validation state to “validated” based only on a successful compile, package build or process-level test. Record the Kinect hardware, OS, active streams and duration for meaningful soak tests.
