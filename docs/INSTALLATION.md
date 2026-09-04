# Installation — V1

Native drivers are built from the source in this repository. The source archive does not include a native driver executable/package payload.

## Windows x64

Requirements:

- Windows 11 x64;
- Visual Studio/MSBuild with the current Microsoft desktop driver-development components (bootstrapped automatically when absent);
- Windows SDK/Driver Kit 10.0.28000 (bootstrapped automatically when absent);
- PowerShell 5.1+.

Build:

```text
drivers\windows\BUILD.cmd
```

The command generates `drivers\windows\binaries\` from the current source. Then run:

```text
drivers\windows\binaries\KINECT.cmd
```

and choose Install / Reinstall. `KINECT.cmd` itself stays at normal user integrity; UAC is requested only when an administrative operation begins. SynKinect Studio is never launched elevated.

The build/signing flow must use the intended Windows signing environment. V1 does not require weakening Secure Boot, BCD or Code Integrity policy.

## Linux x86-64

### Build and install current source

Preferred interactive entry point:

```bash
./drivers/linux/INSTALL.sh
```

The Linux panel runs as the desktop user and requests `sudo`/`pkexec` only for system-changing actions. For automation, `sudo ./drivers/linux/INSTALL.sh --direct` remains available. The installer resolves supported build dependencies, compiles the current native source and installs that exact build. Use `--no-deps` only when required packages are already installed.

V1 requires `v4l2loopback >= 0.15.0` for virtual-camera client-usage events.

### Build Debian package

```bash
./drivers/linux/packages/build-deb.sh amd64
```

The builder compiles the native runtime in a temporary directory and creates a new `.deb` under `drivers/linux/packages/output/`.

### RPM-family distributions

Use `drivers/linux/packages/rpm/kinect360-remold.spec` in the target RPM build environment. The spec compiles the current source during `%build`.

## SynKinect Studio

The editable Processing source is under:

```text
applications/processing/SynKinectStudio/
```

Application launchers are generated during the build and then appear under `applications/binaries/<platform>/`.

Windows requires Java 17+ x64. Linux also targets Java 17. The Studio launchers actively prevent an Administrator/root Java process; if invoked from an elevated context they relaunch/drop to the standard desktop user where possible.
