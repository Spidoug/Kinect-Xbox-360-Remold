# Installation — V1

## Linux

### Desktop installation with `.deb`

The Debian-family package is designed so end users do not have to manually recreate driver setup commands in a terminal.

1. Open `drivers/linux/packages/output/`.
2. Double-click the `kinect360-remold_1.0.0-1_amd64.deb` package.
3. Install it using the distribution software/package installer.
4. Reconnect the Kinect.
5. Start SynKinect Studio.

The package installs the native runtime, udev rules, systemd units, configuration, V4L2 integration policy and the UAC firmware bootstrap helper. Package dependencies are declared in the `.deb` metadata.

Developer/recovery scripts remain available under `drivers/linux/`, but they are not required for the normal desktop installation flow.

### RPM-family distributions

The repository contains `drivers/linux/packages/rpm/kinect360-remold.spec`. Build it using the distribution's normal RPM build environment. Package names for external facilities such as `v4l2loopback` can vary by distribution and repository.

## Windows

The V1 GitHub source package contains the full native source/build tree. The native Windows output folder is intentionally prepared for the maintainer's freshly compiled payload.

Requirements:

- Windows 11 x64;
- Visual Studio C++ build tools/MSBuild;
- Windows SDK;
- Windows Driver Kit (WDK);
- PowerShell 5.1 or newer.

Build:

```text
drivers\windows\BUILD.cmd
```

The build publishes into `drivers\windows\binaries\` and verifies the expected package contents. See `drivers/windows/BINARY-PAYLOAD.md` for the complete output manifest.

After building, launch `KINECT.cmd` from the generated binary directory and choose Install / Repair. Follow the documented release-signing policy; do not weaken Windows Code Integrity, Secure Boot or BCD policy to make a package install.

## SynKinect Studio application

The current unified source is under `applications/processing/SynKinectStudio/`. Exported application launchers/JARs belong under `applications/binaries/windows-x64/` and `applications/binaries/linux-x64/`.
