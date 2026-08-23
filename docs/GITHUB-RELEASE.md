# GitHub release procedure — v1.0.0

This repository tree is prepared as the source package for tag **v1.0.0**.

## Before publishing the repository

- Confirm `VERSION` is `1.0.0`.
- Confirm `drivers/windows/source/build/Product.psd1` reports `Version = '1.0.0'` and `VersionQuad = '1.0.0.0'`.
- Confirm SynKinect Studio contains no `static` declarations.
- Confirm there is only one `.pde` file in the application tree.
- Confirm no split/obsolete application executables or directories are present.
- Decide the top-level project license. The retained third-party license texts do not grant a project-wide license. After choosing it, add a top-level `LICENSE` and update the RPM `License:` field if necessary.

## Windows native payload

The source archive intentionally contains a prepared `drivers/windows/binaries/` target rather than an older native package.

On the Windows release machine:

1. Check out/tag the exact V1 source.
2. Run `drivers\windows\BUILD.cmd`.
3. Verify the output against `drivers/windows/BINARY-PAYLOAD.md`.
4. Validate Install / Repair on a clean Windows 11 x64 system.
5. Test RGB, depth, IR, motor/LED, audio, virtual camera and IP camera using a physical Kinect.
6. Copy/publish the freshly generated binary payload as the V1 Windows release asset.

## Linux native package

1. Build `drivers/linux/BUILD.sh` on the intended x86-64 distribution/toolchain.
2. Build the Debian package with `drivers/linux/packages/build-deb.sh`.
3. Validate package metadata and install/remove behavior.
4. Test with a physical Kinect, including sustained simultaneous video + depth capture.
5. Build the RPM from the provided spec on the target RPM-family distribution when publishing an RPM asset.

## Application

- Validate all five tabs open in one window, global language propagation works, and Interactivity starts with desktop control disabled.
- Switch repeatedly between Scanner and Surveillance to exercise RGB/IR ownership release.
- Confirm depth frame gaps are surfaced rather than silently hidden.
- Start a scan, then pause/switch tabs and confirm accepted reconstruction work drains cleanly.
- Export STL, PLY and OBJ; verify the Save dialog, extension, mesh validity and expected reduced file size.

## Suggested GitHub release assets

```text
Kinect-Xbox-360-Remold-v1.0.0-source.zip
kinect360-remold_1.0.0-1_amd64.deb
kinect360-remold-1.0.0-1.x86_64.rpm              # after target-distro build
Kinect-Xbox-360-Remold-v1.0.0-windows-x64.zip    # after Windows build/test
SynKinectStudio-v1.0.0-windows-x64.zip            # optional application-only asset
SynKinectStudio-v1.0.0-linux-x64.zip              # optional application-only asset
SHA256SUMS
```

## Release description

Use `docs/RELEASE-V1.0.0.md` as the starting point for the GitHub Release body. Do not mark hardware validation as complete unless the corresponding physical-device tests were actually run.
