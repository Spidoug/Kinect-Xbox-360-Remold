# Windows native runtime — V1

The Windows driver/runtime source lives entirely under `source/`. The source release contains no generated Windows driver payload.

## Build environment

- Windows 11 x64;
- Visual Studio 2022 C++ build tools/MSBuild;
- Windows SDK;
- Windows Driver Kit (WDK);
- PowerShell 5.1 or newer.

Build:

```text
BUILD.cmd
```

The builder compiles the current source and creates `binaries\` as the generated publication directory. It builds the per-device/multi-client camera bridge with RGB-HQ support, motor/device broker, audio bridge, virtual camera, IP camera, setup tools and PnP package artifacts.

`binaries\` is deleted/recreated by the build and is ignored by source control. Do not populate it from another package.

After a successful build, run:

```text
binaries\KINECT.cmd
```

and choose Install / Reinstall.

The normal V1 architecture uses Microsoft inbox WinUSB/USB Audio facilities and user-mode Remold services. See `BINARY-PAYLOAD.md`, `../../docs/BUILD-DRIVERS.md` and `../../docs/windows/ARCHITECTURE.md`.

## Camera stability policy

The physical Kinect color engine always starts in the proven 640×480 RGB mode. Scanner 3D uses RGB 640×480 + Depth as its default live transport. IR is selected only by a real IR consumer. RGB-HQ remains an isolated Scanner capability and is never requested by the Windows virtual camera or by Studio startup.

The virtual camera is a read-only 640×480/30 consumer of the shared RGB stream and has no authority to change the physical Kinect mode.
