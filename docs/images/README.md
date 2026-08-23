# Documentation images

This directory contains the visual assets used by the repository documentation. Documentation-only screenshots belong here; runtime icons and Processing export icons remain in the application directories where the build expects them.

| File | Purpose | Used in |
| --- | --- | --- |
| `kinect-xbox-360-sensor.png` | Kinect for Xbox 360 hardware reference | Root `README.md` |
| `synkinect-studio-icon.png` | SynKinect Studio documentation/logo copy | Root `README.md` |
| `synkinect-studio-3d-scanner.png` | 3D Scanner tab | Root `README.md` |
| `synkinect-studio-acoustic-scanner.png` | Acoustic Scanner tab | Root `README.md` |
| `synkinect-studio-microphones.png` | Microphones tab | Root `README.md` |
| `synkinect-studio-surveillance.png` | Surveillance tab | Root `README.md` |
| `synkinect-studio-interactivity.png` | Interactivity tab | Root `README.md` |
| `windows-driver-control-panel.png` | Windows driver/control menu | Root `README.md` |

## Naming policy

- Use lowercase `kebab-case` names for documentation images.
- Prefer descriptive names based on the screen or component shown; do not commit timestamp-based screenshot names.
- Keep documentation screenshots under `docs/images/`.
- Keep application runtime assets under `applications/processing/SynKinectStudio/` and `applications/processing/SynKinectStudio/data/`.
- Mirrored assets under `applications/binaries/` are generated/staged runtime files and should not be used as the canonical documentation source.
