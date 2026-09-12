# Protocols

## NUI Audio boot protocol

Boot device: `USB\VID_045E&PID_02AD`, Microsoft WinUSB, interface 0.

- bulk OUT: `0x01`
- bulk IN: `0x81`
- command magic: `0x06022009`
- status magic: `0x0A6FE000`
- UACFirmware load address: `0x00080000`
- UACFirmware entry point: `0x00080030`
- UAC bootloader sequence starts at `1` (the post-firmware 1473 LED/tilt/status tag sequence is a different protocol and starts at `0`)
- write command: `0x03`
- launch command: `0x04`
- page size: 16 KiB
- bulk payload chunks: 512 bytes

The UACFirmware image is consumed as the raw Microsoft UAC firmware payload; no Remold wrapper/header is added. AudioBridge launches a given physical 02AD boot epoch once and does not repeatedly reflash the same connected sensor if the runtime fails to appear; a new firmware attempt is armed only after that Kinect is physically absent long enough to represent a real disconnect.

## Runtime Windows audio

After firmware launch the device re-enumerates into the Microsoft Kinect UAC family (`USB\VID_045E&PID_02BB` or `USB\VID_045E&PID_02C3`); `MI_02` is consumed through the inbox Microsoft USB Audio class driver. AudioBridge opens the corresponding MMDevice/WASAPI capture endpoint and does not submit runtime USB ISO requests itself.

## Raw microphone pipe

Pipe: `\\.\pipe\Kinect360RemoldAudio`

The ABI is defined by `components/device/shared/Kinect360RemoldAudioPort.h`.

- request: `SubscribeMicrophones`
- sample rate: 16 kHz
- channels: 4 physical microphones
- sample format: signed 32-bit little-endian PCM
- frame payload: 256 samples/channel
- `channelMask`: bit 0..3 identifies the four physical microphone channels

Consumers never open `02AD` or the `02BB/02C3` UAC runtime directly; AudioBridge owns the transition and capture boundary.

## Kinect 1473 motor/LED control profile

The 1473 exposes motor, LED and accelerometer control through the post-firmware `045E:02BB/02C3&MI_00` WinUSB function instead of the 1414 `045E:02B0` control function. The V1 bulk ABI uses endpoint `0x01` for commands and `0x81` for replies. Commands use magic `0x06022009`; normal replies use magic `0x0A6FE000`. LED uses command `0x10`, tilt uses `0x803B`, and status uses `0x8032`. The 1473 command tag sequence begins at zero. Reply acceptance is based on valid reply magic and zero status; an echoed tag is not treated as a hard validity condition.

Normal 1473 control opens do not reset, abort or flush `MI_00`: `02BB/02C3` is a composite runtime family and `MI_02` may be carrying live four-channel USB Audio at the same time. Transfer time is bounded so a missing ACK cannot hold the Broker in a non-stoppable service state. If an explicit LED/tilt/status transaction fails, the Broker closes the MI_00 handle, waits briefly and performs one fresh-handle retry; persistent failure is returned to the caller without restarting the audio composite. Installation checks only that the WinUSB transport is configured and does not use a live LED/tilt response as a pass/fail gate. CameraBridge does not open MI_00 directly. For model 1473 it asks the Broker for the internal one-shot controller preparation before arming camera ISO; if the full 02BB runtime is not ready, camera streaming is deferred instead of entering a USB reconnect loop.

## Per-device ScannerPort camera transport

Pipe: `\\.\pipe\Kinect360RemoldScanner-<device-id>`

The V1 handshake reply is **68 bytes**. Every client must consume the complete reply before reading a frame header. The payload contract on Windows is sensor-native for Studio-facing camera streams:

- RGB VGA: GRBG8 Bayer, 640×480, 307200 bytes.
- RGB HQ: GRBG8 Bayer, 1280×1024, 1310720 bytes.
- Infrared: packed 10-bit sensor payload, 640×488, 390400 bytes.
- Depth: packed 11-bit shift payload, 640×480, 422400 bytes.

The handshake carries the per-device factory depth constants. SynKinect Studio unpacks Depth and performs raw-shift→millimetre conversion. It also demosaics RGB and unpacks/crops IR in user-space. The Windows Media Foundation virtual camera is a separate consumer and continues to receive NV12 through the shared mapping.

There is no decoded ScannerPort camera format in V1. NV12, Gray16 and unpacked Depth are invalid on this pipe; clients must match the declared RAW pixel format and exact payload length. The 68-byte reply and 76-byte frame header are fixed V1 ABI structures.

Normal Studio module open/close does not define WinUSB endpoint lifetime. Endpoint `0x81` keeps one registered ISO buffer across RGB/IR/HQ handoffs, and endpoint `0x82` remains registered after its first Depth activation until the physical camera session ends. Endpoint reset/re-registration is reserved for genuine transport failure.
