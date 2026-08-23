# Linux driver/runtime

- Editable native source: `source/`
- Compiled/staged artifacts: `binaries/<architecture>/`
- Desktop packages: `packages/`
- Build native runtime: `./BUILD.sh`
- Scripted fallback install: `sudo ./INSTALL-PREBUILT.sh`
- Interactive control panel / installation screen: `./INSTALL.sh` (or `./KINECT.sh`)
- Direct scripted build + install: `sudo ./INSTALL.sh --direct`
- Uninstall script: `sudo ./UNINSTALL.sh`
- Control-panel option `10`: opens `applications/binaries/linux-x64/SynKinectStudio.sh` (or a driver-local `studio/SynKinectStudio.sh` payload)

## Recommended desktop installation

On Debian/Ubuntu/Mint, use the generated package in `packages/output/`. It can be opened from the file manager or graphical Software installer; normal package-manager authentication and dependency resolution replace the old requirement to run the driver installer manually in a terminal.

For Fedora/RHEL-family systems, `packages/rpm/kinect360-remold.spec` contains the equivalent RPM recipe. The exact `v4l2loopback` package/module name is distribution-specific, so the repository ships the recipe rather than pretending one binary RPM is portable across all RPM distributions.

The camera/depth backend talks directly to Kinect 1414 through `libusb-1.0`. `libfreenect` is not linked by the Linux Remold runtime. Linux does not need a Remold-specific kernel USB driver: USB access is handled by the kernel/libusb stack, audio by USB Audio/ALSA, and virtual webcam output by V4L2 loopback.

The native ScannerPort camera bridge now keeps bounded FIFO queues for RGB, IR and depth instead of overwriting the last frame. Delivery is selected chronologically and depth wins timestamp ties, preventing a continuously advancing RGB stream from starving depth consumers.

See `../../docs/linux/DRIVER-RUNTIME.md`, `../../docs/linux/WINDOWS-PARITY.md` and `../../docs/linux/USB-BACKEND.md`.
