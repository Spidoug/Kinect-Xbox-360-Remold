# Repository layout and ownership

The repository is organized around two independent axes: **platform** for drivers and **lifecycle stage** for applications.


## Migration from the previous layout

| Previous path | New path |
| --- | --- |
| `driver/Kinect-Xbox-360-Remold-v1/` (Windows source) | `drivers/windows/source/` |
| `driver/Kinect-Xbox-360-Remold-v1/linux/` | `drivers/linux/source/` |
| `binaries/driver/` | `drivers/windows/binaries/` |
| `apps/processing/` | `applications/processing/` |
| `binaries/applications/` | `applications/binaries/windows-x64/` |
| `driver/Kinect-Xbox-360-Remold-v1/docs/` | `docs/windows/` |
| `driver/Kinect-Xbox-360-Remold-v1/licenses/` | `licenses/` |
| `tools/Build-ApplicationRuntime.ps1` | `scripts/windows/Build-ApplicationRuntime.ps1` |

The old mixed `driver/Kinect-Xbox-360-Remold-v1/` hierarchy is intentionally removed so future Windows and Linux changes cannot accidentally land in the same platform tree.

## Top-level policy

```text
drivers/<platform>/source      editable native driver/runtime source
drivers/<platform>/binaries    compiled/installable native payload
applications/processing        editable Processing source
applications/binaries          exported application payloads
docs                           architecture, operation and status
scripts                        repository-level build helpers
licenses                       third-party license texts
```

Do not place generated native binaries inside a source tree. Do not place `.pde` source beside exported `.exe` launchers.

## Windows driver

```text
drivers/windows/
├── BUILD.cmd
├── README.md
├── source/
│   ├── build/
│   ├── components/
│   ├── install/
│   └── source/setup/
└── binaries/
    ├── drivers/
    ├── runtime/
    ├── system/
    ├── tools/
    └── webcam/
```

`drivers/windows/source/build/Build.ps1` now publishes the unified distribution to `drivers/windows/binaries/`. Component-local `dist`, `work`, `cache` and build directories remain intermediate and should not be committed as release payloads.

## Linux driver/runtime

```text
drivers/linux/
├── BUILD.sh
├── INSTALL.sh
├── UNINSTALL.sh
├── source/
│   ├── include/remold/
│   ├── src/
│   ├── scripts/
│   ├── systemd/
│   ├── udev/
│   ├── config/
│   ├── modprobe/
│   └── modules-load/
└── binaries/
    └── <architecture>/
        ├── bin/
        ├── libexec/
        └── support/
```

`drivers/linux/source/scripts/build.sh` builds in an architecture-specific intermediate directory and stages installable artifacts into `drivers/linux/binaries/<uname -m>/`.

## Applications

```text
applications/
├── processing/
│   ├── SynKinect3DScanner/
│   ├── SynKinectSurveillance/
│   ├── SynKinectMicrophones/
│   └── SynKinectAcousticScanner/
└── binaries/
    ├── windows-x64/
    └── linux-x64/
```

The Processing directory is the editable source of truth. Exported release bundles go only under `applications/binaries/<platform>/`.

The current Windows application bundle contains launchers, shared JARs, Processing/JOGL dependencies and application data. Linux source transport support exists, but the Linux launcher bundle remains a separate release task.

## Documentation

General documents remain at `docs/`. Platform-specific native contracts live under `docs/windows/` and `docs/linux/`.

New documentation should be placed according to its audience:

- cross-platform design → `docs/`;
- Linux USB/runtime behavior → `docs/linux/`;
- Windows INF/WASAPI/Media Foundation behavior → `docs/windows/`;
- source-local notes that are required to build a component may stay next to that component.
