# V1.0.0 package validation record

Validation performed on the clean V1 source tree on 2026-08-23:

- exactly one Processing `.pde` exists: `applications/processing/SynKinectStudio/SynKinectStudio.pde`;
- the Processing source compiles to Java 17 with the staged Processing 4.4.6 core/JOGL dependencies;
- the staged Linux and Windows application JARs are byte-identical and advertise `Implementation-Version: 1.0.0`;
- final application JAR SHA-256 is `dd5804893608deb8a5e7f36a453c2a00777d93bfbf4350ac610c8926d51d1418`;
- the JAR contains the V1 shared `KinectSource`/`RgbdFramePair` synchronizer plus `InteractionRuntime`, `InteractionFrameProcessor`, `InteractionTracker3D`, `InteractionSkeleton3D`, `InteractionJoint3D` and `InteractionHandPose3D`; the removed `InteractionVisionSource` class is absent;
- Interactivity render code consumes published snapshots only; one shared RGBD I/O/synchronizer feeds Scanner and the isolated Interactivity heavy-3D worker;
- Scanner and Interactivity consume the identical canonical `RgbdFramePair`: Scanner in FIFO order for reconstruction, Interactivity latest-frame for low latency; no independent RGB/Depth matching remains in either consumer;
- Scanner depth prefilter uses an edge-preserving 3×3 coherent-neighborhood median/majority rule and ICP uses the tightened V1 matching profile (`10` iterations, `4500` max samples, `0.055 m` max correspondence distance);
- obsolete Acoustic/Microphone alternate IPC endpoint keys, protocol fallbacks and old Interactivity configuration aliases are absent;
- obsolete localization labels for alternate IPC endpoints are absent from source and staged application data;
- Linux V4L2 client-activity compatibility behavior is removed and the bridge now requires the V1 event contract;
- Windows audio endpoint selection has no friendly-name compatibility path and requires the Kinect USB runtime identity;
- local shell scripts pass `bash -n` syntax validation;
- staged Python helper sources parse successfully;
- unified SynKinect Studio JAR archives are structurally readable;
- Debian V1 package builds as `kinect360-remold_1.0.0-1_amd64.deb`;
- Debian control metadata reports version `1.0.0-1` / architecture `amd64`;
- Debian maintainer scripts pass shell syntax validation.

## Native rebuild status

Rebuilt from the current V1 Linux source in this environment:

- `kinect360-remoldctl`;
- `kinect360-remold-v4l2`;
- `kinect360-remold-camera-ip`.

The environment does not provide `libusb-1.0` development headers or ALSA development headers, and package-network access is unavailable. Therefore these unchanged native services are retained from the repository's existing x86-64 payload and are explicitly not claimed as freshly rebuilt:

- `kinect360-remold-broker`;
- `kinect360-remold-camera`;
- `kinect360-remold-audio`.

The Debian package was regenerated after staging the rebuilt V1 binaries above. For a hardware-certified distribution, rebuild all native services on the target Linux distribution with libusb/ALSA development packages installed.

Native Windows driver/runtime executables are intentionally absent from this source package; the Windows application JAR is rebuilt, while native Windows drivers must be produced on the maintainer's Windows/WDK machine.

## RGB + Depth 3D skeleton validation scope

The V1 shared RGBD source publishes synchronized Kinect RGB + metric Depth pairs to both Scanner and Interactivity. Software validation includes deliberately out-of-order streams with a +110 ms clock offset: the pairer recovered three pairs with 0 ms residual, and the same canonical DepthFrame then produced a valid synthetic skeleton at approximately 1.8 m with metric chest/hand XYZ coordinates and hand candidates. The source/build path is validated in this environment. A physical Kinect 1414 is still required to tune real-world occlusion, clothing/background geometry, calibration residuals, hand rotation and finger separation; this software validation is not hardware certification.

## Compact-video validation scope

Surveillance event recording uses only MP4/H.264 through FFmpeg/libx264. The default profile is 512×384 at 10 fps with a 384 kbit/s target bitrate and a 512 kbit/s maximum bitrate. A 60-second FFmpeg software encode test using the exact default profile produced **2,882,662 bytes (2.88 MB decimal)** on 2026-08-23. Physical camera evidence size still depends on scene complexity and event duration.

Physical Kinect USB/video/audio behavior remains pending unless separately recorded; software/package validation is not hardware certification.
