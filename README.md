# Kinect Xbox 360 Remold

A Windows/Linux driver-runtime and application suite for **Kinect for Xbox 360 / Kinect 1414**.


<img width="897" height="668" alt="Kinect Xbox 360" src="https://github.com/user-attachments/assets/b0bf0a19-4427-4d04-924a-494c156e9355" />


The project exposes RGB, infrared, calibrated metric depth, motor/tilt, LED, accelerometer and the four-microphone array. On Linux, the Kinect camera protocol is handled directly in user space with **libusb-1.0**; the runtime does not link to `libfreenect`.

> **Important terminology:** the Linux implementation is a **user-space driver/runtime**, not a custom Linux kernel module. The kernel provides generic USB/audio/video infrastructure; Remold owns Kinect protocol, stream arbitration, application IPC, hot-plug behavior and recovery policy.

## Why Remold is different

Remold is not intended to be another generic Kinect API. Its design target is a continuously running sensor subsystem for robotics and applications.

- **Direct Kinect USB backend on Linux.** RGB/IR/depth are configured and streamed through `libusb-1.0` without `libfreenect.so` in the runtime chain.
- **One owner of the physical Kinect.** Applications use stable local IPC instead of competing for the USB interfaces.
- **Shared sensor runtime.** Depth can be shared while RGB/IR ownership follows the real Kinect 1414 hardware limitation.
- **Hot-plug oriented.** `udev` + `systemd` keep the Linux runtime restartable across unplug/replug cycles.
- **Native Linux integration.** Unix-domain sockets, ALSA, V4L2 loopback and systemd are used instead of emulating Windows APIs.
- **Factory depth calibration.** Linux reads Kinect calibration and only labels depth as millimeters when calibration is valid.
- **Application-oriented policy.** Scanner, surveillance, virtual camera, IP camera and audio applications share the same managed runtime.
- **Cross-platform protocol boundary.** Windows named pipes and Linux Unix sockets transport the same Remold application-level contracts.

Remold currently has much less real-hardware mileage than mature projects such as OpenKinect/libfreenect and the in-kernel `gspca_kinect` driver. That maturity difference is documented explicitly; see [Driver comparison](docs/DRIVER-COMPARISON.md) and [Project status](docs/PROJECT-STATUS.md).

## Repository layout

Source code and release artifacts are deliberately separated by platform and lifecycle stage:

```text
Kinect-Xbox-360-Remold/
├── README.md
├── THIRD-PARTY-NOTICES.md
├── applications/
│   ├── processing/                 # editable Processing sketches (.pde)
│   └── binaries/
│       ├── windows-x64/            # exported .exe/.jar/data payload
│       └── linux-x64/              # reserved Linux application release payload
├── drivers/
│   ├── windows/
│   │   ├── source/                 # Windows driver/runtime source
│   │   └── binaries/               # compiled Windows driver/runtime package
│   └── linux/
│       ├── source/                 # direct libusb Linux driver/runtime source
│       └── binaries/
│           └── x86_64/             # compiled Linux ELF runtime payload
├── docs/
│   ├── ARCHITECTURE.md
│   ├── BUILD.md
│   ├── DRIVER-COMPARISON.md
│   ├── PROJECT-STATUS.md
│   ├── REPOSITORY-LAYOUT.md
│   ├── linux/
│   ├── windows/
│   └── images/
├── licenses/
└── scripts/
    ├── windows/
    └── linux/
```

See [Repository layout](docs/REPOSITORY-LAYOUT.md) for ownership rules and where new files should go.

## Drivers

### Linux — direct libusb runtime

Linux uses a Remold-owned userspace backend:

```text
Kinect 1414
   │
   ├── 045e:02ae Camera
   │      └── libusb-1.0
   │           ├── endpoint 0x81 → RGB or IR
   │           └── endpoint 0x82 → Depth
   │
   ├── 045e:02b0 Motor
   │      └── libusb → tilt / LED / accelerometer
   │
   └── 045e:02ad Audio boot
          └── libusb → UACFirmware → 045e:02bb → ALSA
```

The physical RGB stream is Bayer 640×480. IR is packed 10-bit 640×488. Depth is packed 11-bit 640×480. The runtime reassembles isochronous USB packets, converts the formats expected by Remold clients and reads the Kinect factory depth calibration before publishing metric depth.

Build:

```bash
./drivers/linux/BUILD.sh
```

Install the packaged x86_64 binaries directly:

```bash
sudo ./drivers/linux/INSTALL-PREBUILT.sh
```

Or rebuild locally for the target distribution and install:

```bash
sudo ./drivers/linux/INSTALL.sh
```

After installation, reconnecting the Kinect is handled by the installed udev/systemd policy. Runtime details are in [Linux driver/runtime](docs/linux/DRIVER-RUNTIME.md) and [Direct USB backend](docs/linux/USB-BACKEND.md).

### Windows — inbox drivers + Remold user-mode runtime

Windows keeps authored Kinect logic out of custom kernel-mode code. The stack uses Microsoft inbox facilities such as WinUSB, USB Audio/WASAPI and Media Foundation, with Remold user-mode services implementing device policy and application transports.

Build:

```text
drivers\windows\BUILD.cmd
```

Compiled Windows release payload:

```text
drivers\windows\binaries\KINECT.cmd
```

Windows-specific protocol and runtime documents are under [`docs/windows/`](docs/windows/).

## Applications

Editable Processing projects are intentionally kept separate from exported binaries:

| Application | Processing source | Purpose |
| --- | --- | --- |
| SynKinect 3D Scanner | `applications/processing/SynKinect3DScanner/` | RGB + metric-depth reconstruction |
| SynKinect Surveillance | `applications/processing/SynKinectSurveillance/` | IR/RGB motion surveillance and recording |
| SynKinect Microphones | `applications/processing/SynKinectMicrophones/` | four-channel microphone monitor/recorder |
| SynKinect Acoustic Scanner | `applications/processing/SynKinectAcousticScanner/` | passive directional acoustic visualization |

Current exported application launchers are under `applications/binaries/windows-x64/`. The Linux application release directory is separate so Windows `.exe` files are never confused with Linux binaries.

## Runtime ownership model

The runtime is the single owner of the Kinect hardware:

```text
                         Kinect 1414
                              │
                        Remold Runtime
                              │
          ┌───────────────────┼───────────────────┐
          │                   │                   │
      Scanner IPC         Audio IPC          RGB consumers
          │                   │                   │
   3D / Surveillance   Mic / Acoustic      V4L2 / IP Camera
```

This enables the runtime to enforce the Kinect's actual physical constraints centrally. In particular, RGB and raw IR are mutually exclusive on the Kinect 1414 video engine, while depth is independently streamed and shared by reference.

## Current vs roadmap

Implemented now:

- direct Linux `libusb` camera/depth backend;
- RGB/IR/depth frame reassembly;
- factory depth calibration to millimeters;
- motor, tilt, LED and accelerometer control;
- UAC firmware bootstrap + ALSA four-channel capture;
- Unix-socket application transports;
- V4L2 loopback webcam bridge;
- authenticated native MJPEG IP camera;
- udev/systemd installation and reconnect loops;
- Windows/Linux transport selection in the Processing source.

Planned, **not presented as completed**:

- detailed per-endpoint USB packet-loss/latency telemetry;
- watchdog and independent restart policy per stream;
- persistent multi-Kinect identity and simultaneous-device namespaces;
- recorded/simulated sensor backends;
- exported native Linux application launcher bundle.

See [Project status](docs/PROJECT-STATUS.md) for the validation matrix.

## Build documentation

See [docs/BUILD.md](docs/BUILD.md). The Linux build requires C++17, CMake, pkg-config, libusb-1.0 development files, ALSA development files and libjpeg. **`libfreenect` is not a build or runtime dependency.**

## License and third-party work

See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) and [`licenses/`](licenses/). The Linux Kinect protocol implementation was cross-checked against publicly documented/open-source Kinect v1 behavior, including OpenKinect/libfreenect and the Linux `gspca_kinect` implementation. Remold does not redistribute Microsoft UAC firmware; the installer obtains the pinned firmware source separately.
