# Windows V1 binary payload manifest

`drivers/windows/binaries/` is the final publication target created by `drivers/windows/BUILD.cmd`.

The V1 source package deliberately does not ship an unverified/stale native Windows payload. Build the current source on Windows, then publish the resulting directory exactly as generated.

Expected layout:

```text
drivers/windows/binaries/
├── KINECT.cmd
├── Kinect360RemoldDevelopment.cer
├── README.txt
├── VERSION.txt
├── drivers/
│   ├── camera/
│   │   ├── Kinect360RemoldCamera.inf
│   │   ├── Kinect360RemoldCamera.cat
│   │   └── Kinect360RemoldCameraBridge.exe
│   ├── device/
│   │   ├── Kinect360RemoldDevice.inf
│   │   ├── Kinect360RemoldDevice.cat
│   │   └── Kinect360RemoldBroker.exe
│   ├── nui/
│   │   ├── Kinect360RemoldNui.inf
│   │   └── Kinect360RemoldNui.cat
│   └── audio/
│       ├── Kinect360RemoldAudio.inf
│       ├── Kinect360RemoldAudio.cat
│       └── Kinect360RemoldAudioBridge.exe
├── runtime/
│   └── Kinect360RemoldCameraIp.exe
├── webcam/
│   ├── Kinect360RemoldCameraSource.dll
│   └── Kinect360RemoldWebcam.exe
├── tools/
│   ├── Kinect360RemoldNui.exe
│   └── Kinect360RemoldSetup.exe
└── system/
    ├── Common.ps1
    ├── Install.ps1
    ├── Kinect.ps1
    ├── Product.psd1
    └── Uninstall.ps1
```

## Required before publishing

1. Build using the current V1 source, not files from an earlier package.
2. Confirm `VERSION.txt` reports `v1.0.0`.
3. Confirm all four `.cat` files were generated/signed by the intended release signing process.
4. Run `KINECT.cmd` on a clean Windows 11 x64 test system and complete Install / Repair.
5. Validate RGB, depth, IR, motor/LED, microphone capture, webcam and IP-camera paths with a physical Kinect.
6. Generate SHA-256 hashes for the final release assets.

The build script deletes and recreates this directory, so the generated folder itself is the authoritative native binary package after a successful Windows build.
