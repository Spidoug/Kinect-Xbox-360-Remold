# Kinect UAC audio runtime

This branch uses Microsoft's Kinect SDK UACFirmware instead of patching `audios.bin` or installing a custom kernel filter.

## Build-time firmware source

`build/Product.psd1` pins the Kinect for Windows SDK Beta 2 x86 MSI. `components/device/Build.ps1` validates a known MD5/size identity and extracts `UACFirmware.C9C6E852_35A3_41DC_A57D_BDDEB43DFD04` (or a file named `UACFirmware`) without installing the SDK. Offline builds may provide `components/device/firmware/UACFirmware` directly.

The raw firmware is converted to a generated C++ byte array; it is not redistributed as a standalone firmware file in the final driver package.

## Runtime state machine

1. `045E:02AD` appears in boot state and is bound to inbox WinUSB.
2. AudioBridge sends the bootloader probe and validates the boot status tag/magic.
3. The raw UAC image is written to `0x00080000` in 16 KiB pages using 512-byte bulk chunks.
4. AudioBridge launches address `0x00080030`.
5. `02AD` disconnects.
6. Windows enumerates `045E:02BB`; the `MI_02` interface becomes a capture endpoint through the inbox USB Audio class driver.
7. AudioBridge finds that endpoint through MMDevice, verifies a compatible 4-channel/16-kHz capture format and publishes the first four channels through the existing Remold pipe.

No `bInterval` rewriting, URB interception, lower filter, custom WaveRT endpoint, or authored kernel driver is involved.
