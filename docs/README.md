# Kinect Xbox 360 Remold documentation

This directory contains the engineering documentation behind the public project overview in the root README.

## Start here

- [Quick start](QUICKSTART.md) — shortest path from source tree to a running system.
- [Installation](INSTALLATION.md) — Windows/Linux installation details.
- [V1 release contract](RELEASE-V1.md) — what belongs to the current V1 baseline.
- [Architecture](ARCHITECTURE.md) — cross-platform runtime structure and ownership rules.
- [3D Scanner quality](SCANNER-QUALITY.md) — reconstruction pipeline, benchmarks and limitations.
- [Native driver builds](BUILD-DRIVERS.md) — toolchains, outputs and packaging.
- [Project audit](PROJECT-AUDIT.md) — clean-source repository audit.

## Windows

- [Windows architecture](windows/ARCHITECTURE.md)
- [Windows protocol](windows/PROTOCOL.md)
- [UAC audio runtime](windows/UAC-AUDIO-RUNTIME.md)
- [Microphone endpoint](windows/WINDOWS-MICROPHONE-ENDPOINT.md)
- [Microphone diagnostic](windows/MICROPHONE-DIAGNOSTIC.md)
- [Raw sensor lifecycle](windows/RAW-SENSOR-LIFECYCLE.md)
- [Acoustic environment scan](windows/ACOUSTIC-ENVIRONMENT-SCAN.md)
- [IP camera runtime](windows/IP-CAMERA-RUNTIME.md)

## Linux

- [Driver/runtime](linux/DRIVER-RUNTIME.md)
- [USB backend](linux/USB-BACKEND.md)
- [Windows parity](linux/WINDOWS-PARITY.md)

## Current Studio screenshots

<table>
<tr><td><img src="images/synkinect-studio-home.png" alt="Home"></td><td><img src="images/synkinect-studio-3d-scanner.png" alt="3D Scanner"></td></tr>
<tr><td><img src="images/synkinect-studio-acoustic-scanner.png" alt="Acoustic Scanner"></td><td><img src="images/synkinect-studio-microphones.png" alt="Microphones"></td></tr>
<tr><td><img src="images/synkinect-studio-surveillance.png" alt="Surveillance"></td><td><img src="images/synkinect-studio-interactivity.png" alt="Interactivity"></td></tr>
</table>
