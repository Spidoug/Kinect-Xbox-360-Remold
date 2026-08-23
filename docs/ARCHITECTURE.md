# Architecture

## Design goal

Remold treats the Kinect 1414 as a managed sensor subsystem rather than as a library handle owned independently by every application.

The key rule is:

> **One native runtime owns physical hardware; applications consume stable user-space protocols.**

This is the main architectural difference between Remold and a conventional application linking directly to a Kinect library.

## Cross-platform boundary

```text
                         Applications
                              │
                    Remold application ABI
                              │
           ┌──────────────────┴──────────────────┐
           │                                     │
        Windows                                Linux
   Named Pipes / shared memory            Unix Domain Sockets
           │                                     │
   WinUSB / WASAPI / MF                 libusb / ALSA / V4L2
           │                                     │
           └──────────────────┬──────────────────┘
                              │
                         Kinect 1414
```

The applications should not need to understand USB endpoints, ALSA device enumeration, WinUSB interfaces or Kinect firmware state.

## Linux physical ownership

```text
045e:02ae Camera
   ├── endpoint 0x81 ── RGB or IR
   └── endpoint 0x82 ── Depth

045e:02b0 Motor
   └── control transfer ── Tilt / LED / accelerometer

045e:02ad NUI Audio boot
   └── UACFirmware upload
          ↓ re-enumeration
045e:02bb USB Audio
   └── ALSA ── four-channel S32LE 16 kHz
```

The Linux camera process claims the camera interface with libusb and handles the Kinect packet protocol in user space. It maintains RGB/IR/depth frame state and exposes scanner clients through `/run/kinect360-remold/scanner.sock`.

## Video arbitration

Kinect 1414 has a shared raw-video engine for RGB and IR. Remold therefore rejects requests that would require RGB and IR simultaneously. Depth is independent and can run alongside either video mode.

```text
RGB ─┐
     ├── physical endpoint/video engine 0x81
IR  ─┘

Depth ───────────────────────── endpoint 0x82
```

This constraint belongs in the runtime, not in each application.

Virtual-camera and IP-camera services acquire RGB only while they have active consumers. They must not keep RGB permanently selected and thereby starve an IR surveillance session.

## Depth calibration

The direct Linux backend obtains Kinect factory calibration values and builds a raw-depth-to-millimeter conversion table. A depth frame is marked with the Remold calibrated flag only when this data is valid.

If calibration cannot be obtained, raw disparity is **not** mislabeled as millimeters. The current backend withholds metric values rather than publishing false units.

## Audio ownership

The NUI Audio device starts in a firmware boot identity. Remold uploads Microsoft's UAC firmware through the boot USB interface. After the device re-enumerates as USB Audio, the operating system's audio stack owns isochronous scheduling:

- Windows: inbox USB Audio + WASAPI;
- Linux: ALSA (and therefore normal PipeWire integration above ALSA if desired).

AudioBridge fans the physical four-channel stream to independent microphone and acoustic clients so those applications do not contend for one capture handle.

## Failure and reconnect model

Linux native services are long-lived and retry device discovery. The direct camera backend marks its session invalid when an asynchronous USB transfer can no longer be resubmitted or the device disappears; the outer runtime loop closes and attempts a clean reopen.

System installation uses udev/systemd so hardware reconnection does not require reinstalling the project.

Current recovery is service/session oriented. Fine-grained independent stream watchdogs are a roadmap item, not a completed feature.

## IPC endpoints on Linux

| Endpoint | Role |
| --- | --- |
| `/run/kinect360-remold/control.sock` | motor/status/tilt/LED control |
| `/run/kinect360-remold/scanner.sock` | RGB/IR/depth ScannerPort v1 |
| `/run/kinect360-remold/audio.sock` | microphone application fan-out |
| `/run/kinect360-remold/acoustic.sock` | acoustic application fan-out |
| `/run/kinect360-remold/audio-bridge-status.txt` | audio diagnostics |

See `drivers/linux/source/include/remold/protocol.hpp` for the binary contracts.

## SynKinect Studio object and lifecycle model

The Processing sketch is the UI host, not the Kinect owner. `StudioController` owns module lifecycle on `SynKinectStudio-Lifecycle`; no blocking device transition belongs to the Processing render/input thread.

3D Scanner and Interactivity are two consumers of one canonical RGBD core:

```text
Studio lifecycle worker
        │
        ▼
Shared Kinect RGBD source
  one ScannerPort subscription: STREAM_RGB | STREAM_DEPTH
  frame-order validation / liveness / reconnect
        │
        ├── short raw RGB history
        └── short metric-Depth history
                │
                ▼
Adaptive timestamp synchronizer
  estimates stable RGB↔Depth clock offset
  selects the minimum-residual pair
  discards only samples proven older than the pairing window
                │
                ▼
Immutable RgbdFramePair + one shared Depth→RGB registration instance
        │                                      │
        ├── Scanner: bounded FIFO               └── Interactivity: latest pair
        │                                              │
        ▼                                              ▼
ICP / TSDF reconstruction                    isolated 3D skeleton worker
```

A direct Scanner ↔ Interactivity tab transition keeps the RGBD source alive and changes only the consumer. There is no second camera pipe, no independent last-RGB/last-Depth matcher and no duplicated stereo calibration. Transitions to camera modes that require IR release the shared RGBD source through the Studio lifecycle worker. Interactivity never subscribes to IR.

Depth is the metric authority. Both modules use the same `Calibration` and `RgbDepthRegistration` instances. The Scanner uses the pair residual as its texture-sync quality, performs edge-preserving 3×3 depth median filtering plus majority-neighbor rejection, and runs a tighter ICP profile before TSDF integration. Interactivity receives the exact same metric `DepthFrame`, projects/refines anatomical candidates against the paired RGB frame, and publishes image `(u,v)` plus camera-space `(x,y,z)` in metres, confidence and tracking state. The skeleton covers head, neck, chest, spine, pelvis, shoulders, elbows, wrists, hands, hips, knees, ankles and feet; hand ROIs add wrist/palm geometry and named finger-tip candidates.

The Processing render/input thread never performs transport, pairing, reconstruction or skeleton extraction; it consumes published snapshots only.

Surveillance event recording is encoded in a dedicated recorder path as MP4/H.264 via FFmpeg/libx264. The default 512×384, 10 fps, 384 kbit/s profile is designed for small evidence files while retaining burned-in date/time. There is no AVI/MJPEG recording fallback.

The 3D reconstruction view has its own off-screen P3D renderer instance. It cannot alter the camera, clipping, depth state or projection of the main Studio surface, and its buffer follows the live reconstruction-card dimensions after window resizing.

Surveillance enters in Disarmed mode on every activation. Its incoming video frames are buffered in a bounded FIFO so short UI/render stalls do not turn the transport into a last-frame-only path.

The unified application JAR is identical in Windows and Linux staging. Platform-specific differences are limited to the launcher/runtime-native libraries and native Remold transport implementation.
