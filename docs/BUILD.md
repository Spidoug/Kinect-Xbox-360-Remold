# Build guide — V1

The repository separates editable source from generated release payloads.

## Windows driver/runtime

Source:

```text
drivers\windows\source\
```

Requirements: Windows 11 x64, Visual Studio C++/MSBuild, Windows SDK, WDK and PowerShell 5.1+.

Build:

```text
drivers\windows\BUILD.cmd
```

The build deletes/recreates `drivers\windows\binaries\` and verifies the expected package manifest. The GitHub source archive leaves this target prepared but without an older native payload; compile the V1 source on Windows before publishing binaries.

See `drivers/windows/BINARY-PAYLOAD.md`.

## Linux driver/runtime

Source:

```text
drivers/linux/source/
```

Requirements:

- CMake 3.16+;
- C++17 compiler;
- pkg-config;
- libusb-1.0 development files;
- ALSA development files;
- libjpeg development files.

Build:

```bash
./drivers/linux/BUILD.sh
```

The build stages architecture-specific native output under:

```text
drivers/linux/binaries/<architecture>/
```

`libfreenect` is not required.

### Debian package

```bash
./drivers/linux/packages/build-deb.sh
```

Default V1 package version: `1.0.0-1`. Override only for packaging/revision work with `REMOLD_DEB_VERSION`.

### RPM package

Use `drivers/linux/packages/rpm/kinect360-remold.spec` from an RPM build environment after staging the intended x86-64 Linux payload.

## Processing application

Editable source:

```text
applications/processing/SynKinectStudio/SynKinectStudio.pde
```

V1 uses exactly one `.pde`. Generated JARs/launchers belong under `applications/binaries/<platform>/`. Do not edit exported JARs as source.

The `.pde` must remain free of `static` declarations for Processing/Linux compatibility.

## Application launch bundles

Current staging paths:

```text
applications/binaries/windows-x64/
applications/binaries/linux-x64/
```

When exporting a new application build, replace the platform payload atomically so the launcher, JAR, libraries and `data/` configuration stay in sync.
