# Kinect Xbox 360 Remold


Version 1 keeps all authored Kinect logic out of kernel mode. Motor and Camera use Microsoft's inbox `winusb.sys`; NUI Audio uses WinUSB only in the `045E:02AD` boot state, then Microsoft's Kinect SDK UACFirmware re-enumerates the audio function as the `045E:02BB` USB Audio runtime handled by the inbox Windows USB Audio class driver.

## Physical ownership

- `USB\VID_045E&PID_02B0` Motor → WinUSB → persistent control Broker (Tilt, accelerometer, LED).
- `USB\VID_045E&PID_02AE` Camera → WinUSB → CameraBridge (RGB/IR/Depth).
- `USB\VID_045E&PID_02AD` NUI Audio boot → WinUSB → AudioBridge uploads Microsoft UACFirmware.
- `USB\VID_045E&PID_02BB&MI_02` NUI Audio runtime → inbox Microsoft USB Audio → WASAPI → AudioBridge.
- Virtual Camera publishes RGB through Media Foundation.
- Native `Kinect360RemoldCameraIp` service publishes password-protected HTTP/MJPEG from the same `Global\Kinect360RemoldFrame` RGB transport; it does not open USB or ScannerPort.
- Scanner Port v1 exposes reconnectable RGB + calibrated metric Depth sessions to `SynKinect3DScanner`; stale Processing clients are detected by pipe state plus client PID.
- AudioBridge publishes the physical four-microphone S32LE stream to `\\.\pipe\Kinect360RemoldAudio`.

There is no packaged `libusbK.sys`, custom WaveRT/SysVAD endpoint driver, authored NUI Audio filter, or other Remold audio `.sys`. This removes the Code-52 failure mode introduced by the experimental kernel interval filter while still providing a normal Windows microphone endpoint through Microsoft's own USB Audio stack.

## NUI Audio: Microsoft UAC runtime

`components/device/Build.ps1` obtains the Kinect for Windows SDK Beta 2 x86 package pinned in `build/Product.psd1`, validates the known MSI identity, extracts `UACFirmware.*` without installing the SDK, and compiles that raw image into `Kinect360RemoldAudioBridge.exe`. For offline builds, place the extracted file at `components/device/firmware/UACFirmware`.

The bridge follows the established Kinect UAC boot protocol: bulk OUT `0x01`, bulk IN `0x81`, raw firmware load address `0x00080000`, 16 KiB pages split into 512-byte transfers, and launch address `0x00080030`. It does not upload `audios.bin` in this branch.

After launch, AudioBridge no longer owns a runtime USB isochronous pipe. It discovers the active Windows capture endpoint by `PKEY_Device_InstanceId`, preferring `VID_045E&PID_02BB&MI_02`, opens it with WASAPI shared/event-driven capture, and normalizes supported PCM/float formats to the stable four-channel Remold S32LE pipe ABI. This leaves USB scheduling to the Microsoft USB Audio class driver instead of trying to make WinUSB accept the Kinect's historical `bInterval=5` runtime endpoint.

## Build and install

`BUILD.cmd` detects the installed Visual C++ toolset and a coherent Windows SDK/WDK, resolves only the pinned dependencies still used (`Windows-Camera` and Microsoft Kinect SDK UACFirmware), builds the native components and creates four PnP packages: visible device, Motor WinUSB, Camera WinUSB and the `02AD` Audio boot WinUSB package. The unified distribution also contains the user-mode `Kinect360RemoldCameraIp.exe` runtime service. Python is not required for this normal build path.

The distribution contains no authored audio kernel binary. The installer does not delete historical NUI Audio devnodes, services, or Driver Store packages during normal installation. It stages the newer `02AD` WinUSB package, starts AudioBridge, and accepts either the `02BB` USB Audio runtime or a fresh `uac-runtime-capturing` WASAPI status as functional readiness. Virtual-camera registration success is authoritative; delayed Media Foundation/PnP publication is treated as asynchronous rather than as an installation warning. It never changes BCD, Secure Boot or Code Integrity policy.

## Experimental independent audio firmware

`components/device/firmware/remold-audio/` contains the clean-room audio runtime work and an embedded acoustic-scanning DSP core. It is deliberately excluded from the normal flash path until the Kinect 1414 audio MMIO/DMA/CPU map is confirmed. `TEST-DSP.cmd` in that directory tests the SRP-PHAT and active-echo algorithms without touching hardware.

- AudioBridge fans the same 4-channel WASAPI capture to independent `Kinect360RemoldAudio` and `Kinect360RemoldAcoustic` pipes, so microphone monitoring and acoustic scanning do not contend for one client.

## Native IP camera

Install/Repair copies `runtime\Kinect360RemoldCameraIp.exe` to `%ProgramFiles%\Kinect Xbox 360 Remold`, creates the `Kinect360RemoldCameraIp` Windows service, generates a non-hardcoded password under protected ProgramData, and creates a TCP 8088 inbound firewall rule for the Private profile. See `../../../docs/windows/IP-CAMERA-RUNTIME.md`.


For complete build requirements, output layout and the portable Processing Java runtime workflow, see `../../../docs/BUILD.md`.
