# Architecture

## USB ownership

The physical stack deliberately separates transport by device state:

- `045E:02B0` Motor → Microsoft `winusb.sys` → Broker.
- `045E:02AE` Camera → Microsoft `winusb.sys` → CameraBridge.
- `045E:02AD` NUI Audio boot → Microsoft `winusb.sys` → AudioBridge bootloader uploader.
- `045E:02BB&MI_02` NUI Audio runtime → Microsoft inbox USB Audio class driver → WASAPI → AudioBridge.

The audio path is therefore:

`02AD boot/WinUSB → Microsoft UACFirmware upload → 02BB MI_02/USB Audio → WASAPI → raw 4-channel fan-out → `Kinect360RemoldAudio` / `Kinect360RemoldAcoustic` → SynKinectMicrophones + SynKinectAcousticScanner`

No Remold USB/audio kernel binary is required. The virtual camera remains a Media Foundation user-mode component.

## UAC firmware transition

The build extracts the `UACFirmware.*` image from Microsoft's Kinect for Windows SDK Beta 2 instead of modifying `audios.bin`. AudioBridge uploads the raw UAC image at `0x00080000` through boot bulk endpoints `0x01/0x81` and launches entry point `0x00080030`. The `02AD` boot function then disconnects and the UAC runtime appears as `045E:02BB`.

This architecture intentionally avoids the unsupported WinUSB high-speed ISO polling geometry that motivated the earlier `bInterval` experiment. Runtime USB scheduling belongs to the inbox USB Audio driver; AudioBridge works at the Windows audio endpoint boundary.

## WASAPI capture boundary

AudioBridge enumerates active capture endpoints through MMDevice and identifies the Kinect runtime primarily from `PKEY_Device_InstanceId` containing `VID_045E&PID_02BB` and `MI_02`, with a Kinect-named fallback for diagnostic resilience. It accepts compatible 4-or-more-channel 16 kHz PCM16/24/32 or float32 shared-mode formats and converts the first four channels to the Remold S32LE ABI.

The public microphone contract does not change: 4 channels, 16 kHz, 32-bit signed little-endian PCM, 256 samples/channel, local named pipe `\\.\pipe\Kinect360RemoldAudio`.

## Camera frame fan-out and native IP runtime

`Kinect360RemoldCameraBridge.exe` remains the only user-mode owner of the physical camera WinUSB interface. Every RGB frame is converted once to NV12 and published through `Global\Kinect360RemoldFrame` using a double-buffered seqlock. The Media Foundation virtual-camera source and `Kinect360RemoldCameraIp.exe` are read-only consumers of that shared frame.

The IP service performs NV12-to-BGR conversion and Windows Imaging Component JPEG encoding, then serves authenticated HTTP/MJPEG with Winsock. It never calls WinUSB and never connects to `Kinect360RemoldScanner`, so adding a network client cannot steal the scanner session or reconfigure RGB/IR mode. Deployment defaults, firewall scope, port, frame rate and JPEG quality are centralized in `build/Product.psd1`.
