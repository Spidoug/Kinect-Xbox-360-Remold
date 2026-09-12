# Architecture

## USB ownership

The physical stack deliberately separates transport by device state:

- `045E:02B0` Motor → Microsoft `winusb.sys` → Broker.
- `045E:02AE` Camera → Microsoft `winusb.sys` → CameraBridge.
- `045E:02AD` NUI Audio boot → Microsoft `winusb.sys` → AudioBridge bootloader uploader.
- `045E:02BB&MI_02` / `045E:02C3&MI_02` NUI Audio runtime → Microsoft inbox USB Audio class driver → WASAPI → AudioBridge.
- `045E:02BB&MI_00` / `045E:02C3&MI_00` 1473 control runtime → existing Microsoft WinUSB or Remold fallback → Broker.

For model 1473, setup applies port-scoped identity to camera revision 02.05 and preserves `02C2` on the Microsoft hub stack. The `02AE` camera, `02BB/02C3&MI_00` control function and `02BB/02C3&MI_02` USB Audio function are configured independently: a control-protocol failure never blocks camera or audio installation.

Model 1473 is a distinct physical backend behind the same public control contract as model 1414. Its `02AE` camera keeps the same product ID as the 1414 camera but reports a different USB device revision; CameraBridge keeps the same per-device discovery/pipe architecture. LED, tilt and accelerometer commands use the alternate bulk protocol on `02BB/02C3&MI_00` (`OUT 0x01`, `IN 0x81`), while `MI_02` remains owned by Microsoft USB Audio/WASAPI. The Broker does not generate cosmetic LED or motor traffic. Explicit control transactions receive one fresh-handle retry and do not reset/flush the `MI_00` pipes. Scanner motion metadata uses the same logical status contract on both models; 1414 polls the dedicated `02B0` path at 25 ms, while 1473 uses a conservative 250 ms cadence on `MI_00` so the sibling audio runtime is not hammered.

The audio path is therefore:

`02AD boot/WinUSB → Microsoft UACFirmware 01.02.709.00 upload → 02BB/02C3 MI_02/USB Audio → WASAPI → one multi-client raw 4-channel bus `Kinect360RemoldAudio` → independent SynKinect Studio DSP instances (Microphones + Acoustic Scanner)`

No Remold USB/audio kernel binary is required. The virtual camera remains a Media Foundation user-mode component.

## UAC firmware transition

The build downloads the pinned Microsoft Kinect for Windows Runtime v1.8 installer, verifies its SHA-256, extracts UACFirmware 01.02.709.00 without installing the Runtime, and embeds it into AudioBridge. The same image is used for models 1414 and 1473. AudioBridge uploads the raw UAC image at `0x00080000` through boot bulk endpoints `0x01/0x81` and launches entry point `0x00080030`. The `02AD` boot function then disconnects and the UAC runtime is discovered in the Microsoft 1.8 `045E:02BB/02C3` family.

Runtime USB-audio scheduling belongs to the inbox USB Audio driver; AudioBridge works at the Windows audio endpoint boundary and never captures microphone ISO traffic through the Remold WinUSB control path.

## WASAPI capture boundary

AudioBridge enumerates active capture endpoints through MMDevice and accepts only the Kinect runtime whose `PKEY_Device_InstanceId` contains `VID_045E&PID_02BB` or `VID_045E&PID_02C3`, plus `MI_02`. V1 has no friendly-name fallback. It accepts compatible 4-or-more-channel 16 kHz PCM16/24/32 or float32 shared-mode formats and converts the first four channels to the Remold S32LE ABI.

The public microphone contract does not change: 4 channels, 16 kHz, 32-bit signed little-endian PCM, 256 samples/channel, local named pipe `\\.\pipe\Kinect360RemoldAudio`.

## Camera frame fan-out and native IP runtime

`Kinect360RemoldCameraBridge.exe` is the only user-mode owner of the physical camera WinUSB interface. ScannerPort receives sensor-native camera payloads directly. Separately, baseline RGB is converted to NV12 only for the RGB-only `Global\Kinect360RemoldFrame` operating-system fan-out. That mapping carries no Depth region. IP camera and Media Foundation virtual camera are read-only consumers; neither can request a physical sensor mode change.


The camera bridge enumerates every installed Kinect camera interface. Each interface receives a stable hashed V1 ID derived primarily from its Windows USB physical location path (with device instance/path fallback), a private named pipe `\\.\pipe\Kinect360RemoldScanner-<device-id>`, and an entry in `%ProgramData%\Kinect360Remold\devices.tsv`. This avoids treating the model-1473 camera placeholder serial `0000000000000000` as a unique identity. Hot-plug reconciliation is incremental, so a path change on one sensor does not stop every other camera worker. Named-pipe transport is multi-client for stream sets allowed by the single-video-engine hardware mask. Scanner owns RGB 640×480 + Depth. Surveillance owns exactly RGB or IR and never subscribes Depth; when it leaves the foreground it releases IR and returns to RGB so other RGB clients can resume without a persistent endpoint conflict. The first discovered camera remains the source for the Windows virtual-camera shared mapping; direct Studio capture is not restricted to that primary device. The primary source publishes stable VGA RGB to Windows consumers.

Physical camera state is device-owned rather than module-owned. ScannerPort clients only express desired streams; the bridge arbitrates endpoint `0x81` modes and gives projector/depth ownership to the Depth supervisor. ScannerPort receives sensor-native RGB Bayer, packed IR10 and packed Depth11; SynKinect Studio performs demosaic, IR unpack/crop and calibrated raw→millimetre conversion in user-space. The WinUSB isoch buffer for `0x81` remains registered across normal RGB/IR/HQ module handoffs; the bridge stops firmware capture, cancels/requeues reads on the same buffer and restarts the selected mode without a normal pipe reset. After the first Depth request, endpoint `0x82` likewise remains registered until the physical camera session ends, while register `0x06` is merely toggled according to active Depth/IR demand. A video-engine fault terminates only the affected device's current WinUSB camera session; a genuine depth fault rebuilds only `0x82` from a defined OFF state. Scanner, Interactivity, Surveillance, virtual camera and external ScannerPort clients all use this same per-device runtime.

The IP service reads the RGB-only NV12 shared mapping, performs NV12-to-BGR conversion and Windows Imaging Component JPEG encoding, then serves authenticated HTTP/MJPEG with Winsock. It never calls WinUSB and never connects to a per-device `Kinect360RemoldScanner-<device-id>` endpoint, so adding a network client cannot steal a scanner session or reconfigure RGB/IR mode. Deployment defaults, firewall scope, port, frame rate and JPEG quality are centralized in `build/Product.psd1`.
