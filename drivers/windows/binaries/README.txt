# Windows driver/runtime

This platform directory deliberately separates editable native source from the compiled installable package.

```text
drivers/windows/
├── BUILD.cmd
├── source/
└── binaries/
```

## Install the compiled package

Run:

```text
binaries\KINECT.cmd
```

The compiled payload contains the PnP packages, Remold user-mode services, virtual-camera components, setup/control tools and development-signing certificate used by this release.

## Build from source

Run:

```text
BUILD.cmd
```

The source tree is under `source/`, and the unified build publishes directly back into `binaries/` instead of creating another mixed `dist` tree.

## Architecture

Windows keeps authored Kinect policy in user mode. Motor/Camera use Microsoft inbox WinUSB; NUI Audio uses WinUSB for the firmware boot phase and Microsoft USB Audio/WASAPI after re-enumeration. The virtual camera uses Media Foundation.

There is no Remold-authored general-purpose Kinect kernel `.sys` required for the normal runtime design.

Windows-specific native contracts and diagnostics are documented under repository path `docs/windows/`.
