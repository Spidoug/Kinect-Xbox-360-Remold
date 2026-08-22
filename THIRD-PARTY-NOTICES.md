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

Microsoft Kinect UAC firmware is not committed as a binary redistribution in this repository. The Windows/Linux build/install tooling identifies and extracts the firmware from the pinned Microsoft Kinect SDK package when required.

External dependency identities and integrity pins used by the Windows native build are centralized in:

- `drivers/windows/source/build/Product.psd1`

This notice is an attribution/index document and is not a new project-wide license grant.
