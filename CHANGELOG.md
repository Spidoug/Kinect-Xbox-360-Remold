# Changelog

## 1.0.0 — clean V1 baseline

- Removed historical application compatibility aliases and alternate audio/acoustic IPC endpoint fallbacks.
- Made Windows Kinect audio endpoint selection strict to the Kinect `VID_045E&PID_02BB` / `MI_02` runtime identity.
- Made the Linux V4L2 bridge require the V1 client-activity event contract instead of supporting old loopback behavior.
- Made **English (`en-US`) the first/preferred/default language** across the Studio and staged module configuration.
- Unified 3D Scanner and Interactivity on one canonical **RGB + metric Depth** acquisition, synchronization and calibration instance; Interactivity never opens a second camera session and never uses IR.
- Replaced last-frame RGB/Depth matching with a bounded timestamp-pair synchronizer that estimates stable stream clock offset, pairs by minimum residual, drops only proven-stale samples and publishes one immutable `RgbdFramePair` to both Scanner and Interactivity.
- Added calibrated Depth→RGB joint refinement and metric camera-space XYZ joints for head, torso, arms and legs, with per-joint confidence/tracking state.
- Added 3D wrist/palm tracking plus named thumb/index/middle/ring/pinky tip candidates, openness, grab strength and pinch strength.
- Added body-relative 3D desktop mapping and XYZ diagnostics to SynKinect Studio.
- Replaced Surveillance event AVI/MJPEG output with strict **MP4/H.264 (`libx264`) via FFmpeg**, defaulting to 512×384 at 10 fps and ~384 kbit/s (about 2.9 MB/minute nominal video payload).
- Kept Surveillance timestamps burned into encoded frames and preserved low-light RGB→IR recording behavior without changing the event session.
- Consolidated documentation around one V1 contract and removed obsolete point-release migration notes.
- Normalized documentation image filenames, added an image manifest, embedded the five SynKinect Studio tabs and Windows control interface in the root README, and corrected stale four-module directory documentation.
- Rebuilt the staged application JARs from the V1 source; native hardware services not modified by these application changes are not falsely claimed as newly rebuilt.
