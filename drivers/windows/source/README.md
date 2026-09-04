# Kinect Xbox 360 Remold — Windows V1 source

V1 keeps Kinect-specific policy in user mode and uses Microsoft inbox Windows facilities for the kernel-facing pieces.

## Physical ownership

- Kinect 1414: `USB\VID_045E&PID_02B0` Motor/control → Microsoft WinUSB → Remold control Broker.
- Kinect 1473: `USB\VID_045E&PID_02C2` is the parent USB hub/controller and remains on the Microsoft inbox USB hub driver; it is never matched by a Remold WinUSB INF.
- Kinect 1473 after audio firmware: `USB\VID_045E&PID_02BB&MI_00` vendor control → existing Microsoft Kinect Audio Array Control WinUSB when available, otherwise Remold WinUSB fallback → control Broker (motor/LED/accelerometer).
- `USB\VID_045E&PID_02AE` Camera → Microsoft WinUSB → Remold CameraBridge.
- `USB\VID_045E&PID_02AD` NUI Audio boot → Microsoft WinUSB → UACFirmware upload.
- `USB\VID_045E&PID_02BB&MI_02` NUI Audio runtime → Microsoft USB Audio → WASAPI → Remold AudioBridge.

For 1473 setup, camera revision 02.05 uses Windows `IgnoreHWSerNum` so its placeholder serial `0000000000000000` cannot become the logical device identity. The installer keeps the 02AE camera, 02BB&MI_00 control and 02BB&MI_02 audio paths independent; it does not require a live 1473 LED/motor reply before binding the camera. CameraBridge uses USB location paths for stable per-port IDs and performs incremental hot-plug reconciliation.
- Media Foundation virtual camera publishes RGB.
- `Kinect360RemoldCameraIp` publishes authenticated HTTP/MJPEG from the shared RGB transport.

No Remold-authored general-purpose Kinect kernel `.sys` is required by the V1 architecture.

## Multi-Kinect camera runtime

`Kinect360RemoldCameraBridge` enumerates every Remold camera interface and derives a stable device ID from the Windows device-instance identity. It publishes:

```text
%ProgramData%\Kinect360Remold\devices.tsv
\\.\pipe\Kinect360RemoldScanner-<device-id>
```

Each per-device pipe supports concurrent local clients. RGB and Depth fan out through bounded client queues. Raw IR remains exclusive with the color engine per physical Kinect.

The physical color endpoint always starts from the proven RGB 640×480 baseline. Scanner 3D uses RGB 640×480 + Depth by default. RGB-HQ is isolated to an explicit Scanner request and is never required for Scanner startup. If an explicit HQ attempt cannot form complete frames, the bridge locks that physical session back to stable VGA rather than retrying continuously.

The Windows virtual camera is a read-only 640×480/30 consumer. It never writes a mode request, never owns a sensor lease and never changes RGB/IR/Depth/HQ hardware state.

## Audio runtime

`components/device/Build.ps1` obtains the pinned Microsoft Kinect Runtime v1.8 UACFirmware 01.02.709.00 image, validates it and embeds it in the AudioBridge build. For offline builds, place the extracted 01.02.709.00 image at `components/device/firmware/UACFirmware-01.02.709.00`.

AudioBridge uploads firmware in the `02AD` boot state, waits for `02BB&MI_02` or `02C3&MI_02`, captures through WASAPI and normalizes the first four channels to the Remold S32LE application ABI. `02BB&MI_00`/`02C3&MI_00` is a separate vendor-control interface. The installer preserves an already healthy Microsoft WinUSB binding and uses a dedicated fallback INF only when required; `MI_02` is never rebound and stays on USB Audio.

## Build

Use Windows 11 x64 with PowerShell 5.1+. The V1 builder discovers any healthy compatible MSVC/SDK/WDK installation. When those native prerequisites are absent, `BUILD.cmd` applies the bundled snapshot of Microsoft's official WDK WinGet configuration, which installs Visual Studio Community with the required driver-development components and the 10.0.28000 Windows SDK/WDK family. WinGet/Visual Studio requests administrator approval when Windows requires it; the build then validates the actual tools found on disk before compiling. Python is not a build dependency.

From `drivers/windows/`:

```text
BUILD.cmd
```

The builder compiles the current source and recreates `drivers\windows\binaries\`. That generated directory is intentionally absent from the source release.

V1 build launchers are UTF-8 **without BOM** so `cmd.exe` reads the first `@echo` correctly. During preparation of the pinned Microsoft Media Foundation virtual-camera sample, the builder pins `NOMINMAX` and the generated C++ source also protects `std::min/std::max` from the Win32 `min/max` macros. This behavior is part of the cleaned V1 source contract and is covered by the repository audit and source-review checks.

The generated publication contains the camera/device/audio PnP packages, user-mode bridges, virtual camera, IP camera, setup utility and installation scripts. Development/release signing is performed by the configured build environment.

See `../BINARY-PAYLOAD.md` and `../../../docs/BUILD-DRIVERS.md`.
