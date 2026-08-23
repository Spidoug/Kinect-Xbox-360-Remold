# Native Linux packages — V1

The preferred desktop installation is a distribution package rather than manually reproducing setup commands.

## Debian / Ubuntu / Mint (.deb)

Build with:

```bash
./build-deb.sh
```

The default V1 output is:

```text
output/kinect360-remold_1.0.0-1_amd64.deb
```

It can be opened from a file manager/software installer and performs privileged setup through the package manager. It installs the Remold broker, RGB/IR/depth camera bridge, four-channel audio bridge, V4L2 bridge, IP camera, control tool, udev rules, systemd units, configuration and the UAC firmware bootstrap helper.

Runtime dependencies are declared in the package metadata so the graphical package manager can resolve them.

## Fedora / RHEL family (.rpm)

`rpm/kinect360-remold.spec` contains the equivalent V1 packaging recipe. Build it in the target RPM-family environment using the staged x86_64 payload. External package naming, especially `v4l2loopback`, can vary by distribution.
