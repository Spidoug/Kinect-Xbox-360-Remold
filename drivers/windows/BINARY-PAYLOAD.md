# Windows V1 generated payload manifest

`drivers/windows/binaries/` is a generated publication directory created by `drivers/windows/BUILD.cmd`. It is intentionally absent from the V1 source release.

A successful current-source build produces:

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

## Publication gate

1. Run `drivers\windows\BUILD.cmd` in the supported Visual Studio/SDK/WDK environment.
2. Confirm `VERSION.txt` reports `v1.0`.
3. Confirm the expected PnP catalogs were generated and signed by the intended signing process.
4. Test Install / Reinstall on Windows 11 x64.
5. Validate RGB, RGB-HQ, Depth, IR, multi-client fan-out, motor/LED, microphone capture, virtual camera and IP camera with physical Kinect hardware.
6. Generate SHA-256 hashes for published native assets.

The builder deletes and recreates the publication directory, so every file in a published Windows native package comes from the source/build invocation that generated it.
