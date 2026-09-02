# Native Linux packages — V1

Package artifacts are generated from current source and are not stored in the source release.

## Debian / Ubuntu / Mint

```bash
./build-deb.sh amd64
```

The builder creates a temporary CMake build, compiles the complete native runtime, stages that exact output and generates:

```text
output/kinect360-remold_1.0-1_amd64.deb
```

The package installs the control broker, RGB/RGB-HQ/IR/Depth camera bridge, four-channel audio bridge, V4L2 bridge, IP camera, control tool, udev rules, systemd units, configuration and UAC firmware bootstrap helper.

## Fedora / RHEL family

```bash
./build-rpm.sh
```

The RPM builder creates a temporary source archive from `drivers/linux/source/` and invokes `rpmbuild`. `rpm/kinect360-remold.spec` compiles that source in `%build`; no generated driver payload is used as an input.

Distribution package names for facilities such as `v4l2loopback` can vary. V1 requires v4l2loopback 0.15.0 or newer at runtime.
