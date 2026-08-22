# Linux driver/runtime

- Editable source: `source/`
- Compiled/staged artifacts: `binaries/<architecture>/`
- Build: `./BUILD.sh`
- Install prebuilt x86_64 payload: `sudo ./INSTALL-PREBUILT.sh`
- Build locally and install: `sudo ./INSTALL.sh`
- Uninstall: `sudo ./UNINSTALL.sh`

The camera/depth backend talks directly to Kinect 1414 through `libusb-1.0`. `libfreenect` is not linked by the Linux Remold runtime.

See `../../docs/linux/DRIVER-RUNTIME.md` and `../../docs/linux/USB-BACKEND.md`.
