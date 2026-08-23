# Kinect Xbox 360 Remold v1.0.0

V1 consolidates the application suite into **SynKinect Studio**, a single cross-platform Processing application with 3D Scanner, Acoustic Scanner, Microphones, Surveillance and Interactivity tabs.

The 3D capture pipeline was redesigned around bounded queues and controlled draining so depth frames are not silently replaced while processing is busy. Linux native capture likewise uses independent FIFO handling for video and depth instead of fixed RGB-first delivery. Export now uses a correct Save-file workflow and produces substantially more compact OBJ/STL/PLY output through indexed geometry, binary formats and texture limits.

Linux V1 provides direct `libusb` Kinect camera/depth handling, ALSA audio integration, V4L2/systemd/udev integration and desktop-installable Debian packaging, plus an RPM recipe. Windows V1 retains the native user-mode/inbox-driver architecture and a reproducible build that publishes a single binary payload directory.

Scanner and Interactivity use one synchronized RGB + metric Depth acquisition/calibration instance in V1. The canonical pairer handles real stream timing offsets and feeds FIFO Scanner reconstruction plus latest-frame full-body XYZ skeleton fusion, eliminating the separate Interactivity camera/synchronizer path. Surveillance event recording is compact MP4/H.264 through FFmpeg/libx264, and English is the first/default UI language.

The source package does not carry older split SynKinect executables. Native Windows binaries should be built from this exact V1 source and published only after Windows/hardware validation.

See `CHANGELOG.md`, `docs/PROJECT-STATUS.md` and `docs/GITHUB-RELEASE.md` for details and validation status.
