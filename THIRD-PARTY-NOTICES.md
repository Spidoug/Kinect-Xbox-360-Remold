# Third-party notices

## OpenKinect / libfreenect protocol reference

The Linux direct-USB backend interoperates with Kinect v1 using protocol behavior that has been publicly documented and implemented by the OpenKinect/libfreenect project. Remold does not require or bundle `libfreenect.so`; the Linux runtime is linked directly to `libusb-1.0`.

Reference project: https://github.com/OpenKinect/libfreenect

The Apache License 2.0 text retained for the OpenKinect reference is stored at:

- `licenses/Apache-2.0-OpenKinect.txt`

## Microsoft Windows Camera reference

The Windows virtual-camera implementation uses Microsoft Windows Camera material under the license retained at:

- `licenses/MIT-Microsoft-Windows-Camera.txt`

## Microsoft Kinect UAC firmware

Microsoft Kinect UAC firmware is not committed as a binary redistribution in this repository. The Windows build obtains UACFirmware 01.02.709.00 from the pinned Microsoft Kinect for Windows Runtime v1.8 package, validates the Runtime installer and embeds the extracted firmware into AudioBridge. Linux retains its own platform-specific firmware acquisition path.

External dependency identities and integrity pins used by the Windows native build are centralized in:

- `drivers/windows/source/build/Product.psd1`

## WiX Toolset v3 build-time extractor

The Windows source build downloads the `wix` 3.14.1 NuGet package only as a build-time tool and uses its portable `dark.exe` to unpack the Microsoft Kinect Runtime v1.8 Burn bundle. WiX is not installed system-wide and is not included in the Remold source ZIP or installed Remold runtime. The NuGet package identifies its license as Microsoft Reciprocal License (MS-RL).

This notice is an attribution/index document and is not a new project-wide license grant.




## Kinect Runtime firmware separation

The Microsoft Kinect body/skeleton runtime is **not** linked or used by SynKinect Studio. Remold keeps its own Kinect camera transport. Existing build/install logic may use the pinned Kinect Runtime v1.8 package only to obtain Microsoft's Kinect UAC firmware for the audio boot path; that is separate from pose estimation.
