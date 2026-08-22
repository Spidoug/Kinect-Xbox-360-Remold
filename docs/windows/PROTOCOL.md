# Protocols

## NUI Audio boot protocol

Boot device: `USB\VID_045E&PID_02AD`, Microsoft WinUSB, interface 0.

- bulk OUT: `0x01`
- bulk IN: `0x81`
- command magic: `0x06022009`
- status magic: `0x0A6FE000`
- UACFirmware load address: `0x00080000`
- UACFirmware entry point: `0x00080030`
- write command: `0x03`
- launch command: `0x04`
- page size: 16 KiB
- bulk payload chunks: 512 bytes

The UACFirmware image is raw; unlike `audios.bin`, no Remold firmware-header parser is applied.

## Runtime Windows audio

After firmware launch the device re-enumerates as `USB\VID_045E&PID_02BB`; `MI_02` is consumed through the inbox Microsoft USB Audio class driver. AudioBridge opens the corresponding MMDevice/WASAPI capture endpoint and does not submit runtime USB ISO requests itself.

## Raw microphone pipe

Pipe: `\\.\pipe\Kinect360RemoldAudio`

The ABI is defined by `components/device/shared/Kinect360RemoldAudioPort.h`.

- request: `SubscribeMicrophones`
- sample rate: 16 kHz
- channels: 4 physical microphones
- sample format: signed 32-bit little-endian PCM
- frame payload: 256 samples/channel
- `channelMask`: bit 0..3 identifies the four physical microphone channels

Consumers never open `02AD` or `02BB` directly; AudioBridge owns the transition and capture boundary.
