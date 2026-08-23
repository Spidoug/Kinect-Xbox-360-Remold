# Windows driver/runtime — V1

Windows V1 separates editable native source from the generated installable payload.

```text
drivers/windows/
├── BUILD.cmd
├── source/
├── BINARY-PAYLOAD.md
└── binaries/          # generated/publish target
```

## Source package state

The GitHub source package intentionally leaves `binaries/` prepared without native executables. This prevents an older Windows build from being confused with the V1 source.

Build on the supported Windows 11 x64 + Visual Studio/SDK/WDK environment:

```text
BUILD.cmd
```

The build recreates `binaries/`, stages all PnP packages and user-mode components, signs/verifies the expected catalogs according to the development signing flow, and validates the output manifest.

After a successful V1 build, run:

```text
binaries\KINECT.cmd
```

and choose Install / Repair. The generated control panel also exposes option `10` to open the Windows SynKinect Studio launcher from the repository/application payload.

See `BINARY-PAYLOAD.md` for the exact required filenames and release validation procedure.

## Architecture

Windows keeps authored Kinect policy in user mode. Motor/Camera use Microsoft inbox WinUSB; NUI Audio uses WinUSB for firmware boot and Microsoft USB Audio/WASAPI after re-enumeration. The virtual camera uses Media Foundation. No Remold-authored general-purpose Kinect kernel `.sys` is required by the normal design.

Windows-specific contracts and diagnostics are under `docs/windows/`.
