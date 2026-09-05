# Linux V1 UAC firmware input

Kinect Xbox 360 Remold V1 uses Microsoft Kinect Runtime 1.8 **UACFirmware 01.02.709.00**, matching the Windows V1 audio path for models 1414 and 1473.

The firmware blob is not committed or redistributed. The Linux V1 installer deliberately does **not** download non-V1 SDK firmware packages.

For a source install, provide the raw current image either by setting `KINECT_UAC_FIRMWARE=/path/to/UACFirmware` (preserve it through `sudo -E`) or by placing it here as:

```text
UACFirmware-01.02.709.00
```

A Windows V1 build can extract this same image from the pinned Microsoft Kinect Runtime 1.8 package. Camera, IR and Depth do not depend on this file; Linux audio remains pending until the image is supplied.
