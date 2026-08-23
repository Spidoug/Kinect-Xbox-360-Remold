# V1 general rules

This repository has one active contract: **V1**. Historical compatibility paths are not runtime behavior.

## 1. Protocol and configuration

- IPC protocol version is exactly `1`.
- Each feature has one canonical endpoint; no alternate endpoint is accepted when the canonical endpoint is unavailable.
- Each setting has one canonical key. Historical aliases are not translated.
- English (`en-US`) is the primary/default Studio language and is first in the configured locale order.
- Invalid frame version, dimensions, format, capability mask, ordering or payload size terminates the current session and enters the normal reconnect path.

## 2. Thread ownership

The Processing render/input thread is UI-only. It must never perform blocking Kinect connection work, video encoding or heavy frame analysis.

- **Studio lifecycle thread**: activates/deactivates modules and owns blocking module transitions.
- **Kinect I/O threads**: open/close local transport, subscribe to streams, read frames, validate headers and reconnect.
- **Shared RGBD source**: owns the single synchronized RGB + metric-Depth session used by both 3D Scanner and Interactivity, including liveness, reconnect, timestamp pairing and stream-offset estimation.
- **Interactivity 3D fusion worker**: metric-Depth person segmentation, calibrated RGB refinement, XYZ joint lifting, kinematic stabilization and hand/finger analysis.
- **Surveillance recorder worker**: feeds compact event frames to FFmpeg/H.264 without blocking render/acquisition.
- **Render thread**: consumes immutable/latest published snapshots and draws them.

No module may add a synchronous connection/encoding fallback inside `draw()`, `mouse*()` or `key*()`.

## 3. Backpressure

- Continuous transports use bounded queues or a latest-frame mailbox.
- Heavy Interactivity processing keeps at most the newest synchronized **RGB + Depth pair**. Stale unprocessed pairs are intentionally replaced.
- Reconstruction/export paths that require every accepted item use bounded FIFO queues and explicit drain rules.
- Surveillance recording uses a constant-frame-rate output timeline and must not accumulate an unbounded encode queue.

## 4. Kinect ownership and Interactivity stream

One native runtime owns the physical Kinect. Applications use the Remold user-space ABI only. RGB and IR remain mutually exclusive because Kinect 1414 shares their video engine; Depth can run with RGB.

**Scanner and Interactivity consume the same `STREAM_RGB | STREAM_DEPTH` source.** Interactivity never subscribes to IR, never opens a second camera connection and has no fallback tracker. Scanner gets FIFO canonical pairs; Interactivity gets the latest canonical pair. Calibration and Depth→RGB registration are single shared instances configured only by `scanner.properties`.

## 5. Metric 3D skeleton and hand model

V1 exposes a camera-space metric 3D skeleton. Depth is the geometry authority and RGB is a calibrated refinement signal:

- head, neck, chest, spine and pelvis;
- left/right shoulders, elbows, wrists and hands;
- left/right hips, knees, ankles and feet;
- wrist and palm per tracked hand;
- named thumb/index/middle/ring/pinky tip candidates;
- per-joint image coordinates, XYZ metres, confidence and tracking state;
- finger count, openness, grab strength and pinch strength.

Depth connected components select the user. Candidate joints are refined against RGB luminance edges through the calibrated Depth→RGB projection and then lifted with robust local Depth sampling. A kinematic/temporal solver penalizes implausible bone lengths and smooths joint motion. Desktop control maps hands in a body-relative 3D interaction volume; raw 2D pixels are used only for visualization.

## 6. Compact Surveillance recording

Event video has one canonical format: **MP4/H.264 via FFmpeg/libx264**. AVI/MJPEG is not a fallback. The default profile is 512×384, 10 fps, 384 kbit/s target / 512 kbit/s maximum bitrate with a long GOP, which corresponds to about 2.9 MB/minute of nominal video payload before MP4 overhead. Timestamp text remains burned into frames. If FFmpeg/libx264 is unavailable, recording fails explicitly.

## 7. Release rule

Source, staged binaries, configuration, documentation and manifest version must describe the same V1 contract. Do not publish binaries produced from a different source tree or retain old generated payloads beside new source.
