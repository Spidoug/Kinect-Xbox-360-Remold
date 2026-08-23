# Quick start — V1

## 1. Choose the platform runtime

### Linux x86-64

For Debian/Ubuntu-family systems, install the V1 `.deb` from:

```text
drivers/linux/packages/output/
```

Open it in the distribution's graphical software installer. Reconnect the Kinect after installation so udev/systemd can apply the runtime policy.

For Fedora/RHEL-family systems, build the package from:

```text
drivers/linux/packages/rpm/kinect360-remold.spec
```

### Windows x64

Build the V1 native runtime from `drivers/windows/BUILD.cmd`, or insert the maintainer-built V1 payload under `drivers/windows/binaries/` following `drivers/windows/BINARY-PAYLOAD.md`.

After a successful build, run:

```text
drivers\windows\binaries\KINECT.cmd
```

and choose Install / Repair.

## 2. Start SynKinect Studio

The editable source is:

```text
applications/processing/SynKinectStudio/SynKinectStudio.pde
```

Exported launchers are staged under `applications/binaries/<platform>/`.

Tabs/shortcuts:

- `1` — 3D Scanner
- `2` — Acoustic Scanner
- `3` — Microphones
- `4` — Surveillance
- `5` — Interactivity

## 3. First 3D scan

1. Open the 3D Scanner tab.
2. Confirm RGB/depth are updating and there are no persistent frame-gap warnings.
3. Position the subject inside the calibrated depth range.
4. Start capture/reconstruction.
5. Move the Kinect/subject slowly enough to preserve overlap between depth frames.
6. Pause/finish the scan and allow the reconstruction queue to drain.
7. Export OBJ, STL or PLY using the Save dialog.

For smaller files, keep `export.maxTriangles`, `export.weldToleranceM`, `export.textureMaxSize` and `export.jpegQuality` at the V1 defaults unless more detail is required.
