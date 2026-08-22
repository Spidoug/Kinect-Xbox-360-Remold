# Build guide

The repository deliberately separates source trees from compiled payloads.

## Windows driver/runtime

Source:

```text
drivers\windows\source\
```

Build entry point:

```text
drivers\windows\BUILD.cmd
```

Requirements:

- Windows 11 x64;
- Visual Studio C++/MSBuild;
- Windows SDK and WDK;
- PowerShell 5.1 or newer.

The unified distribution is published to:

```text
drivers\windows\binaries\
```

The build still uses component-local intermediate directories, but the final compiled package is no longer mixed with editable source.

## Linux driver/runtime

Source:

```text
drivers/linux/source/
```

Build:

```bash
./drivers/linux/BUILD.sh
```

Required build dependencies:

- CMake 3.16+;
- C++17 compiler;
- pkg-config;
- libusb-1.0 development package;
- ALSA development package;
- libjpeg development package.

Runtime integration additionally uses systemd, udev and v4l2loopback.

`libfreenect` is **not** required for the Linux build or runtime.

The build uses an architecture-specific intermediate directory and then stages the installable payload to:

```text
drivers/linux/binaries/<uname -m>/
```

Typical x86-64 output:

```text
drivers/linux/binaries/x86_64/
├── bin/kinect360-remoldctl
├── libexec/kinect360-remold/
│   ├── kinect360-remold-audio
│   ├── kinect360-remold-broker
│   ├── kinect360-remold-camera
│   ├── kinect360-remold-camera-ip
│   └── kinect360-remold-v4l2
└── support/
```

Install the committed x86_64 development payload:

```bash
sudo ./drivers/linux/INSTALL-PREBUILT.sh
```

Or rebuild on the target distribution before installing:

```bash
sudo ./drivers/linux/INSTALL.sh
```

The normal installer builds local source before installation. The prebuilt installer uses `drivers/linux/binaries/<architecture>/`. Both install the udev/systemd/V4L2 policy and obtain the UAC firmware source used for the Kinect audio transition. Prebuilt binaries are convenient test artifacts, not a substitute for rebuilding when distro ABI compatibility matters.

## Processing application source

Editable sketches:

```text
applications/processing/
```

Do not edit the exported JARs as source. Changes belong in the `.pde` trees and should then be exported into the appropriate platform release directory.

## Windows application runtime bundle

Current exported payload:

```text
applications/binaries/windows-x64/
```

The optional minimized Java runtime can be generated with:

```text
scripts\windows\BUILD-APPLICATION-RUNTIME.cmd
```

The helper analyzes the application JARs with `jdeps` and creates a `java/` runtime under the Windows application binary directory.

## Linux application binaries

`applications/binaries/linux-x64/` is intentionally separate. The Processing source already contains Linux Unix-socket transport support, but a final Linux launcher bundle has not yet been exported and should not be represented as completed.
