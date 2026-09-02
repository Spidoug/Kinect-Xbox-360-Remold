# Kinect NUI Audio UACFirmware input — V1

The Windows V1 build uses Microsoft **UACFirmware 01.02.709.00** from Kinect for Windows Runtime v1.8 for the `045E:02AD` NUI Audio boot state on both Xbox 360 Kinect models 1414 and 1473.

Normal connected builds download the pinned Microsoft Runtime v1.8 installer, validate its SHA-256, extract `UACFirmware` from `KinectDrivers-v1.8-x86.WHQL.msi` without installing the Kinect Runtime, and embed the firmware bytes into `Kinect360RemoldAudioBridge.exe`.

For an offline build, place the already-extracted **01.02.709.00** image here as:

```text
UACFirmware-01.02.709.00
```

The Microsoft firmware binary itself is not committed to or redistributed in this source package.
