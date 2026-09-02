# Architecture

## Design goal

Remold treats Kinect Xbox 360 models 1414 and 1473 as managed sensor subsystems rather than library handles owned independently by every application.

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
                    Kinect 1414 / 1473
```

The applications should not need to understand USB endpoints, ALSA device enumeration, WinUSB interfaces or Kinect firmware state.


## Unified hardware-control contract

The runtime presents one control contract for both Kinect Xbox 360 revisions:

```text
status -> accelerometer + measured tilt
tilt   -> requested degrees; success only after measured-angle confirmation
led    -> logical Remold LED mode
```

Connection details stay behind the broker backend. Model 1414 opens the dedicated `045E:02B0` motor interface and uses the dedicated 02B0 USB control protocol. Model 1473 preserves `045E:02C2` as the Microsoft hub and opens `045E:02BB/02C3&MI_00` after audio firmware re-enumeration, using the alternate bulk command protocol. Windows and Linux use the same model-neutral command/reply ABI and the same issue/retry/verify semantics; only discovery, USB encoding and safe polling cadence differ.

Revision-specific preparation, endpoint discovery and USB encoding stay entirely inside the physical backend.

## Linux physical ownership

```text
045e:02ae Camera
   ├── endpoint 0x81 ── RGB or IR
   └── endpoint 0x82 ── Depth

1414: 045e:02b0 Motor
   └── control transfer ── Tilt / LED / accelerometer

1473: 045e:02c2 Microsoft hub
   └── post-firmware 045e:02bb interface 0
          └── bulk control ── Tilt / LED / accelerometer

045e:02ad NUI Audio boot
   └── UACFirmware upload
          ↓ re-enumeration
045e:02bb USB Audio
   └── ALSA ── four-channel S32LE 16 kHz
```

The Linux camera process enumerates every Kinect camera interface with libusb. Each physical USB topology path receives a stable V1 ID and its own Unix socket under `/run/kinect360-remold/devices/`. `/run/kinect360-remold/devices.tsv` is the atomic discovery manifest consumed by the Studio. Each device maintains independent RGB/IR/depth state and permits multiple clients on its own endpoint.

## Video arbitration

Kinect 1414 and 1473 share the same Kinect v1 camera RGB/IR engine behavior. Remold therefore rejects requests that would require RGB and IR simultaneously. Depth is independent and can run alongside either video mode.

```text
RGB ─┐
     ├── physical endpoint/video engine 0x81
IR  ─┘

Depth ───────────────────────── endpoint 0x82
```

This constraint belongs in the runtime, not in each application.

Virtual-camera and IP-camera services acquire RGB only while they have active consumers and follow the registry primary camera. Foreground Surveillance dynamically chooses exactly RGB or IR and never subscribes Depth. A luminance hysteresis switches to IR in low light; RGB recovery checks are evidence-driven and cooldown-limited. Motion is temporal appearance/luminance change in whichever video stream is active. Because RGB and IR are physically exclusive, leaving the Surveillance tab releases IR and returns its background transport to RGB, preventing Scanner/Interactivity starvation.

## Depth calibration

Both native camera backends expose the same RAW-only ScannerPort camera ABI. Depth is the sensor-native packed 11-bit payload on Windows and Linux, and both handshakes expose the factory calibration constants. SynKinect Studio is the only application-side unpack/raw→millimetre authority, so USB acquisition/recovery remains isolated from metric reconstruction math. There is no unpacked-uint16 camera wire format in V1.

If calibration cannot be obtained, raw shift samples can still traverse the private transport, but Studio marks metric Depth unavailable and never labels those samples as millimetres.

Above that factory disparity→metric conversion, the Studio can apply a **per-device surface calibration**. It collects averaged views of one flat wall at multiple ranges, robustly fits one plane per range, and solves a bounded affine correction independently for each depth pixel. The same capture also estimates temporal sigma per pixel. The profile is keyed by the central device registry ID, so USB enumeration order does not select calibration. The corrected depth accessor is the single authority used by target estimation, point-cloud construction and Depth→RGB registration; HQ TSDF additionally consumes the learned confidence as an observation weight.

## Audio ownership

The NUI Audio device starts in a firmware boot identity. Remold uploads Microsoft's UAC firmware through the boot USB interface. After the device re-enumerates as USB Audio, the operating system's audio stack owns isochronous scheduling:

- Windows: inbox USB Audio + WASAPI;
- Linux: ALSA (and therefore normal PipeWire integration above ALSA if desired).

AudioBridge publishes one phase-preserving four-channel stream on a multi-client raw bus, so any number of software consumers can subscribe without contending for the WASAPI capture handle. Microphones and Acoustic Scanner each instantiate the same DSP pipeline off the UI thread: GCC-PHAT/TDOA estimates DOA, a near-field grid estimates horizontal x/z, and fractional-delay delay-and-sum beamforming provides AUTO or MANUAL spatial isolation to the system playback output.

## Failure and reconnect model

Linux native services are long-lived and retry device discovery. The direct camera backend marks its session invalid when an asynchronous USB transfer can no longer be resubmitted or the device disappears; the outer runtime loop closes and attempts a clean reopen.

System installation uses udev/systemd so hardware reconnection does not require reinstalling the project.

Recovery is service/session oriented: a dead transport session is closed, its queues are cleared, and the runtime attempts a clean reopen.

## IPC endpoints on Linux

| Endpoint | Role |
| --- | --- |
| `/run/kinect360-remold/control.sock` | motor/status/tilt/LED control |
| `/run/kinect360-remold/devices.tsv` | discovered Kinect IDs, labels and per-device ScannerPort endpoints |
| `/run/kinect360-remold/devices/<device-id>.sock` | RGB/IR/depth ScannerPort v1 for one physical Kinect; multi-client |
| `/run/kinect360-remold/audio.sock` | multi-client raw 4-channel audio bus; each software module owns its DSP instance |
| `/run/kinect360-remold/audio-bridge-status.txt` | audio diagnostics |

See `drivers/linux/source/include/remold/protocol.hpp` for the binary contracts.

## SynKinect Studio object and lifecycle model

The Processing sketch is the UI host, not the Kinect owner. `StudioController` owns module lifecycle on `SynKinectStudio-Lifecycle`; no blocking device transition belongs to the Processing render/input thread.

3D Scanner and Interactivity use the same RGBD protocol and synchronization algorithm, but each module owns its own transport instance:

```text
Studio lifecycle worker
        │
        ├──────── Scanner tab ────────┐
        │                             ▼
        │                     KinectSource instance A
        │                     RGB + metric Depth
        │                     bounded synchronizer
        │                             │
        │                             ▼
        │                     ICP / TSDF reconstruction
        │
        └──── Interactivity tab ──────┐
                                      ▼
                              KinectSource instance B
                              RGB + metric Depth
                              bounded synchronizer
                                      │
                                      ▼
                              SynKinect Body V1 / Depth geometry
```

Only the active single-camera module owns a live transport. Scanner and Interactivity share calibration data and registration mathematics only. A tab transition immediately revokes the old module's transport generation and closes its pipe; the next module opens its required mode without waiting for the old worker to join. Interactivity never subscribes to IR.

Scanner and Interactivity use the same calibrated RGB↔Depth registration mathematics while keeping independent live transport/state objects. Scanner uses pair residual as texture-sync quality, edge-preserving depth filtering and robust ICP before TSDF integration. Interactivity runs one **SynKinect Body V1** instance per module. It segments the person directly in metric Depth, derives the articulated body landmarks from connected silhouette geometry and anthropometric proportions, lifts them to camera-space XYZ, temporally stabilizes the joints, and projects the filtered result into calibrated RGB coordinates. No external pose model/runtime is loaded.

The interaction renderer is clipped to the exact RGB image rectangle and all published joint image coordinates are clamped to the 640×480 Kinect viewport. Pose inference is isolated from the Processing render/input thread; the UI only consumes immutable published snapshots.

The Processing render/input thread never performs transport, pairing, reconstruction or skeleton extraction; it consumes published snapshots only.

Surveillance is multi-camera by contract. Every discovered Kinect has an independent compressed JPEG ring retained in RAM for 10 minutes by default. Appearance/luminance motion from any active RGB/IR camera opens one event session; every camera recorder first drains its own 60-second pre-roll and then receives live JPEG packets that the internal Java AVI writer stores as indexed Motion-JPEG frames. This preserves synchronized evidence across cameras without retaining raw 640×480 RGB frames in RAM.

The 3D reconstruction view has its own off-screen P3D renderer instance. It cannot alter the camera, clipping, depth state or projection of the main Studio surface, and its buffer follows the live reconstruction-card dimensions after window resizing.

Surveillance starts disarmed at application startup and is active only while its tab owns the video resources. Leaving the tab disarms Surveillance, closes an active recording asynchronously and releases RGB/IR ownership. While Surveillance is active, hot-plug discovery is centralized in `KinectDeviceRegistry`; newly connected cameras are added automatically and disconnected cameras are removed without changing the Studio selector for unrelated devices.

The unified application JAR is identical in Windows and Linux staging. Platform-specific differences are limited to the launcher/runtime-native libraries and native Remold transport implementation.


## V1 stability rules

- The visible ROOT product devnode is a software container for the broker service; it is not a WinUSB function and is not required to report DN_STARTED.
- The live 3D Scanner owns one stable RGB 640×480 + Depth session for the duration of the tab. On Windows, ScannerPort carries raw Bayer RGB and packed raw Depth; Studio performs the user-space conversions. START SCAN starts reconstruction only and never reprograms or reopens the physical camera transport.
- Reconstruction is bounded and low-priority (default 8 fusion frames/s) so the UI and shared camera consumers stay responsive.
- Windows audio keeps 02BB MI_02 on the inbox USB Audio driver and captures the four raw microphones with WASAPI. Kinect-named capture endpoints are format-validated instead of relying only on one PnP instance-string representation. The Studio ABI remains 4ch S32LE at 16 kHz.
