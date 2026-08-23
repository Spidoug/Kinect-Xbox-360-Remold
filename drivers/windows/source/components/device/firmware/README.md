# NUI Audio firmware input

This branch uses Microsoft's **UACFirmware** from the Kinect for Windows SDK Beta 2. It is not redistributed in the source package.

`components/device/Build.ps1` downloads the pinned Microsoft SDK MSI declared in `build/Product.psd1`, validates its known package hash, extracts `UACFirmware.C9C6E852_35A3_41DC_A57D_BDDEB43DFD04` without installing the SDK, and embeds the raw firmware image into `Kinect360RemoldAudioBridge.exe`. Extraction does not depend on an administrative MSI install: `tools/Extract-KinectUacFirmware.ps1` reads the embedded cabinet through the Windows Installer `msi.dll` stream API and expands the pinned firmware with the inbox `expand.exe`.

For an offline build, place the SDK-extracted firmware at:

`components/device/firmware/UACFirmware`

The boot transport remains `USB\VID_045E&PID_02AD` on Microsoft `winusb.sys`. AudioBridge uploads the raw UAC image at load address `0x00080000` and launches entry point `0x00080030`. The Kinect then re-enumerates as the UAC runtime (`045E:02BB`); its `MI_02` audio interface is handled by the inbox Microsoft USB Audio class driver and captured by AudioBridge through WASAPI.

Do not place `audios.bin` here for this branch. No NUI Audio kernel filter or custom audio `.sys` is used.
