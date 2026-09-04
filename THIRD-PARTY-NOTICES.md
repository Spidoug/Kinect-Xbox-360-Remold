# Third-party notices

This document identifies third-party projects and build-time/runtime components referenced by Kinect Xbox 360 Remold. It is an attribution/index document, not a new project-wide license grant.

## Processing Core

SynKinect Studio builds against **Processing Core 4.4.6**. The clean source release does not commit the JAR; the Studio build downloads the pinned artifact and verifies its SHA-256 before use.

Upstream: https://processing.org/

## JogAmp / JOGL / GlueGen

SynKinect Studio uses **JOGL 2.5.0** and **GlueGen Runtime 2.5.0**, including platform-native Windows/Linux AMD64 JARs. These files are generated runtime dependencies and are not committed to the clean source release. The builders obtain them from the JogAmp Maven repository and validate repository-pinned SHA-256 values.

Upstream: https://jogamp.org/

## OpenKinect / libfreenect protocol reference

The Linux direct-USB backend interoperates with Kinect v1 using protocol behavior publicly documented and implemented by OpenKinect/libfreenect. Remold does not require or bundle `libfreenect.so`; the Linux runtime is linked directly to `libusb-1.0`.

Reference project: https://github.com/OpenKinect/libfreenect

The Apache License 2.0 text retained for the OpenKinect reference is stored at:

- `licenses/Apache-2.0-OpenKinect.txt`

## Microsoft Windows Camera reference

The Windows virtual-camera implementation uses Microsoft Windows Camera material under the license retained at:

- `licenses/MIT-Microsoft-Windows-Camera.txt`

The Windows native toolchain bootstrap also includes text snapshots of Microsoft Windows Driver Samples WDK WinGet/Visual Studio configuration files under `drivers/windows/source/build/`. They are retained as build metadata so V1 uses one reviewed toolchain configuration instead of downloading mutable configuration text at build time.

## Microsoft Kinect UAC firmware

Microsoft Kinect UAC firmware is not committed as a binary redistribution in this repository. The Windows build obtains **UACFirmware 01.02.709.00** from the pinned Microsoft Kinect for Windows Runtime v1.8 package, validates the Runtime installer and embeds the extracted firmware into AudioBridge. Linux uses the same current raw Runtime 1.8 image when supplied through `KINECT_UAC_FIRMWARE` or the documented source firmware input; the V1 Linux installer does not download retired SDK firmware packages.

External dependency identities and integrity pins used by the Windows native build are centralized in:

- `drivers/windows/source/build/Product.psd1`

The Microsoft Kinect body/skeleton runtime is not linked or used by SynKinect Studio. The Runtime v1.8 package is used here only as the official source for the Kinect UAC audio firmware path described above.

## WiX Toolset v3 build-time extractor

The Windows source build downloads the `wix` 3.14.1 NuGet package only as a build-time tool and uses its portable `dark.exe` to unpack the Microsoft Kinect Runtime v1.8 Burn bundle. WiX is not installed system-wide and is not included in the clean source ZIP or installed Remold runtime.
