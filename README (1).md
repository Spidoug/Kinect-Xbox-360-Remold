# Kinect Xbox 360 Remold V1.0

Kinect Xbox 360 Remold is a cross-platform runtime and application suite for **Kinect for Xbox 360 models 1414 and 1473**. V1 uses one current architecture across Windows and Linux and one Processing application: **SynKinect Studio**.

<p align="center">
  <img src="docs/images/kinect-xbox-360-sensor.png" alt="Kinect for Xbox 360 sensor" width="560">
</p>

## V1 highlights

## Clean V1 contract

Version 1.0 is a new baseline. It does not negotiate, decode, accept or emit an older ScannerPort camera ABI. The internal camera transport is sensor-native only: GRBG8 Bayer for RGB, packed 10-bit for IR and packed 11-bit shift codes for Depth. SynKinect Studio owns display/metric conversion. OS-facing adapters such as Media Foundation, V4L2 and HTTP/MJPEG convert only at their output boundary and are not alternate ScannerPort formats.

The physical camera session is device-owned and outlives individual Studio module views. Closing and reopening Scanner, Interactivity or Surveillance releases only that consumer; it does not tear down healthy USB ISO registrations. Re-registration/reset is reserved for a real transport fault.

Every Studio service, protocol, module state and module object is explicitly constructed by the V1 controller. Startup is neutral: instances exist, but no hardware transport is opened until the user selects a module.

- **3D Scanner** with per-device depth calibration, robust pose refinement, loop closure, multi-frame 2× depth super-resolution, 288³ HQ TSDF reconstruction and RGB-HQ Bayer keyframes.
- **Acoustic Scanner** with 4-channel GCC-PHAT/TDOA DOA, voice-activity gating, adaptive noise suppression, conservative AUTO/MANUAL beam steering and beamformed Windows/Linux playback output.
- **Microphones** with its own instance of the same voice-aware GCC-PHAT/TDOA + noise-suppression + AUTO/MANUAL beamforming pipeline as Acoustic Scanner, plus raw four-channel recording and diagnostics.
- **Surveillance** across every connected Kinect, using RGB in normal light or IR in low light — never Depth — with appearance/luminance motion detection, a 10-minute compressed RAM ring per camera and 60-second pre-roll.
- **Interactivity** with the in-house SynKinect Body V1 depth-silhouette engine, calibrated metric XYZ joints, per-joint temporal filtering and viewport-clipped virtual-rig rendering.
- **Multi-Kinect registry** with stable device identity and per-device native transport.
- **Source-first release**: the repository contains editable source and documentation. Generated application payloads, native binaries, packages, tests and temporary artifacts are not part of this cleaned source release.

## Project audit summary

This repository revision was audited and cleaned with the following goals:

- remove the committed `tests/` tree from the deliverable;
- remove generated application artifacts under `applications/binaries/`;
- keep the repository centered on editable source, build scripts and documentation;
- update `.gitignore` to ignore generated application runtime payloads;
- keep the Windows/Linux build flow source-based;
- replace the repository UI screenshots with the six new screenshots provided by the user.

The detailed audit report is available in [PROJECT-AUDIT.md](PROJECT-AUDIT.md).

## 3D Scanner quality path

The live scan and the final reconstruction are intentionally separate.

```text
Capture
  Depth 640×480 + RGB 640×480 keyframes
      ↓
  per-device depth correction + noise confidence
      ↓
  responsive 192³ live preview
      ↓
HQ build
  robust local-map ICP
      ↓
  loop closure
      ↓
  2× multi-frame subpixel depth fusion
      ↓
  foreground/occlusion + temporal-outlier rejection
      ↓
  288³ TSDF / 2.3 mm voxel / 9 mm truncation
      ↓
  indexed mesh cleanup / OBJ STL PLY
```

For color, the live Scanner uses the canonical **640×480 RGB** physical transport. The reconstruction pipeline remains high quality in software—calibration, ICP, loop closure, multi-frame depth fusion and TSDF refinement do not require the physical camera to enter 1280×1024 mode.

The scanner remains limited by Kinect v1 optics and structured-light depth physics. V1 is aimed at high-quality visual/printable reconstruction of medium and large objects, not certified metrology. See [3D Scanner quality and market comparison](docs/SCANNER-QUALITY.md).

## Per-device calibration

The Scanner exposes **CALIBRATE** for the selected physical Kinect. It collects several averaged views of one large flat surface at different distances and learns:

- per-pixel affine depth correction;
- per-pixel temporal noise confidence;
- one profile keyed by the stable Kinect device ID.

The correction is applied before point-cloud construction, registration, ICP and HQ fusion. Profiles are stored as user data:

- Windows: `%LOCALAPPDATA%\Kinect360Remold\calibration\`
- Linux: `${XDG_CONFIG_HOME:-~/.config}/kinect360-remold/calibration/`

## Multi-Kinect model

The native runtime discovers physical devices centrally. Scanner and Interactivity use the Kinect selected in the Studio shell. Surveillance subscribes to **all** discovered devices.

Xbox 360 hardware-family support includes model 1414 (`045E:02B0` dedicated motor/control) and model 1473. On the 1473, `045E:02C2` is preserved on the Microsoft inbox USB hub stack; after UAC firmware, motor/LED/accelerometer control is exposed through `045E:02BB/02C3&MI_00`, while `MI_02` remains the Windows USB Audio endpoint. On Windows the installer binds every present Remold-owned function instance and only reports a required transport READY when all matching PnP instances are STARTED.

For model 1473, Windows setup treats the camera's USB serial `0000000000000000` as a placeholder: the installer configures the known 02AE revision 02.05 to use port-scoped USB identity, preserves the 02C2 hub, and configures the independent `02AE` camera, `02BB/02C3&MI_00` control, and `02BB/02C3&MI_02` audio paths without making one a prerequisite for the others. A normal reinstall stages/binds current packages without first uninstalling a healthy 02BB/02C3 control/audio stack. If the sensor is already in the partial post-firmware state `MI_00/MI_01` with neither `MI_02` nor `02AD`, setup performs at most one targeted restart and one targeted cycle of the active `02BB/02C3` audio composite; it never uses that recovery to rebind the 02C2 hub. CameraBridge derives its per-device ID from the Windows USB location path and reconciles hot-plug incrementally, so one 1473 re-enumerating does not restart other connected cameras.

### Unified 1414 / 1473 control contract

Models 1414 and 1473 expose one logical Remold control surface: `status`, `tilt` and `led`. Applications and the command-line utility do not select a model-specific command. The broker selects the physical backend internally: 1414 uses the dedicated `02B0` WinUSB/control-transfer path; 1473 uses the post-firmware `02BB/02C3&MI_00` bulk-control path. Both backends normalize accelerometer and tilt into the same reply structure, apply the same configured tilt limits, retry one fresh physical handle after a failed transaction, and only report a successful tilt after status polling confirms the measured angle reached the target.

Scanner motion metadata follows the same contract on both models. The 1414 dedicated motor endpoint is inexpensive enough for 25 ms polling; the 1473 control interface shares the `02BB/02C3` composite runtime with USB Audio, so it uses a conservative 250 ms status cadence. This cadence difference is a transport detail and does not change the frame ABI or application behavior. Before a fresh 1473 camera/control session, the broker performs one bounded controller preparation equivalent to libfreenect's one-shot audio-control keep-alive; it is internal to the backend, not a public model-specific command and never becomes a periodic LED heartbeat. The 02AD UAC bootloader uses its own sequence starting at 1, while the post-firmware 02BB/02C3 control protocol starts at 0. AudioBridge never reflashes the same continuously connected boot epoch in a loop.

Linux publishes:

```text
/run/kinect360-remold/devices.tsv
/run/kinect360-remold/devices/<device-id>.sock
```

Windows uses the equivalent V1 device manifest and one named pipe per physical device.

## Acoustic DOA and beamforming

The Studio consumes every raw 4×256 audio block at 16 kHz. GCC-PHAT/TDOA across all six microphone pairs estimates azimuth; a near-field x/z grid provides an approximate horizontal position. Before AUTO can move the beam, a per-instance voice detector must confirm persistent speech-like energy in the configured voice band, sufficient signal-to-noise ratio, stable angular evidence and a dwell window. Attack/release hysteresis, angular clustering, deadband and a slew-rate limit prevent isolated peaks or background noise from making the beam hunt. A spectral noise estimator/suppressor runs after fractional-delay delay-and-sum beamforming. MANUAL mode bypasses automatic steering and keeps direct user control of the beam angle. The processed mono result is published to the current system playback device without modifying the raw four-channel source bus.

On Windows, AudioBridge first uses the endpoint's native four-channel shared format when Windows exposes it directly. If the shared mix is only mono/stereo, it does **not** synthesize four channels through the mixer (which would destroy TDOA timing); it falls back to the endpoint's exclusive 4-channel/16 kHz raw format. Installation reports the Remold audio transport READY when the Kinect `MI_02` runtime is present and the persistent AudioBridge service is running. Actual four-channel capture health is reported by the runtime diagnostics (`audio-bridge-status.txt`) and by the Studio when a client subscribes.

## Studio startup and Scanner transport

SynKinect Studio opens on a neutral **Início** presentation screen. No Scanner, audio, Surveillance or Interactivity pipe is opened until the user explicitly selects a module. Returning to Início releases the active module transport. Each module negotiates only the streams it needs.

The 3D Scanner opens the canonical **raw GRBG8 RGB 640×480 + packed raw 11-bit Depth 640×480** transport on Windows. Factory depth constants are negotiated once and SynKinect Studio unpacks raw shift codes and converts them to metric millimetres before Scanner/Interactivity processing. The Windows bridge now limits itself to USB framing for Scanner RGB/IR/Depth; user-space Studio owns Bayer reconstruction, packed-IR unpack/crop and metric Depth conversion. Pressing `SCAN` changes only reconstruction state; it never changes camera resolution or reopens USB. ICP/TSDF work runs on a low-priority worker and the UI reads lock-free progress snapshots.

## Camera resource rules

The physical Kinect has one video engine (`0x81`) and one Depth engine (`0x82`). RGB is the idle/default video mode. IR is selected only by an explicit IR consumer. Depth illumination/firmware streaming is enabled only when Depth or IR really needs the projector. Virtual camera/IP camera are consumers and never command physical resolution. The WinUSB ISO registration for `0x81` now lives for the whole physical camera session: RGB/IR/HQ handoff stops register `0x05`, cancels the outstanding reads, reconfigures the sensor, requeues reads on the **same registered ISO buffer**, and starts the selected mode again. Normal module handoff does not unregister or reset the pipe. A new scanner client from the same Studio process supersedes its stale previous pipe session immediately, so a blocked Windows `RandomAccessFile` cannot retain video ownership after a tab/module switch. After the first Depth subscriber arms `0x82`, its ISO registration also remains alive for the whole physical camera session; closing a Studio module only turns register `0x06` off when no Depth/IR consumer remains. Reopening Depth therefore reuses the already-registered endpoint instead of tearing it down and reconstructing host USB state. Only a genuinely failed/stuck endpoint is cancelled/unregistered and rebuilt with an endpoint-local pipe reset. A video-engine failure ends only that Kinect's current WinUSB camera session so its `CameraNode` can reopen a clean handle without restarting other connected Kinects.

Surveillance does not perform blind periodic RGB probes while in IR. It requests a brief RGB check only after sustained IR evidence suggests ambient light changed and after a cooldown. This prevents day/night logic from turning into a periodic physical camera reset.

SynKinect Studio uses 1280×800 as its 100% design size. Layout scale stays within a narrow readable range and all module typography uses one global font multiplier (`ui.fontScale`, default `1.10`).

## Surveillance retention

Each connected Kinect owns an independent compressed JPEG ring in RAM. V1 defaults:

- retention horizon: **10 minutes**;
- retention frame rate: **10 fps**;
- pre-roll written on an event: **60 seconds**;
- event output: compact Motion-JPEG AVI written directly by SynKinect Studio; no external encoder process;
- motion authority: temporal appearance/luminance change in the active RGB or IR stream; Surveillance never subscribes Depth.

One motion trigger opens one synchronized event; every connected camera writes its own video file beginning with its available pre-roll.

## Interactivity

Interactivity has one body engine: **SynKinect Body V1**. It is implemented in the Studio source with no external pose library or neural-model runtime. Metric Depth is segmented into a person silhouette, anatomical landmark hypotheses are derived from connected-body geometry and proportions, and every accepted joint is deprojected to calibrated camera-space XYZ. A confidence/velocity filter stabilizes the joints and reprojects them into the RGB viewport for the existing skeleton drawing.

The Microsoft Kinect body/skeleton runtime is not used. Remold owns the camera transport; the Microsoft Runtime v1.8 remains relevant only as the official source of UACFirmware 01.02.709.00 for Kinect audio.

## Repository layout

```text
Kinect-Xbox-360-Remold-1.0/
├── BUILD.cmd                         # recommended Windows double-click build launcher
├── README.md
├── PROJECT-AUDIT.md
├── THIRD-PARTY-NOTICES.md
├── applications/
│   └── processing/SynKinectStudio/   # editable Studio source
├── drivers/
│   ├── windows/
│   │   ├── BUILD.cmd
│   │   └── source/                   # native Windows source
│   └── linux/
│       ├── BUILD.sh
│       ├── source/                   # native Linux source
│       └── packages/                 # source-based DEB/RPM recipes
├── docs/
│   ├── SCANNER-QUALITY.md
│   ├── BUILD-DRIVERS.md
│   ├── RELEASE-V1.md
│   ├── linux/
│   └── windows/
├── scripts/
└── licenses/
```

Generated directories such as `applications/binaries/`, `drivers/windows/binaries/`, `drivers/linux/dist/` and `drivers/linux/packages/output/` are builder outputs and are intentionally absent from this cleaned source release.

## Building native drivers

See [docs/BUILD-DRIVERS.md](docs/BUILD-DRIVERS.md).

Windows (recommended):

```text
BUILD.cmd
```

The launcher keeps its console open and reports the error code/log location if the build fails.

Linux:

```bash
./scripts/linux/BUILD-DRIVER.sh --clean
```

Linux Debian package:

```bash
./drivers/linux/packages/build-deb.sh amd64
```

## Starting SynKinect Studio

Editable source:

```text
applications/processing/SynKinectStudio/
```

Generated application launchers are created after a Studio build under:

```text
applications/binaries/windows-x64/SynKinectStudio.cmd
applications/binaries/linux-x64/SynKinectStudio.sh
```

The Windows launcher requires Java 17+ x64 and handles Java installations whose path contains spaces, including `C:\Program Files\...`.

## Documentation

Start with [docs/README.md](docs/README.md).

The cleaned source release can be checked with:

```bash
./scripts/VERIFY-SOURCE-RELEASE.sh
```

Surveillance uses an adaptive per-frame JPEG budget (10 KiB by default at 320×240 / 5 fps), targeting roughly **2.9 MiB per minute** before small AVI container overhead while retaining standard MJPEG/AVI playback.
