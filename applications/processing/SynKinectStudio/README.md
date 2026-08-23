# SynKinect Studio

`SynKinectStudio.pde` is the single editable Processing application for the Kinect Xbox 360 Remold project. V1 exposes five modules as tabs in one window:

- **3D Scanner** — RGB + calibrated metric depth reconstruction, mesh editing and OBJ/STL/PLY export.
- **Acoustic Scanner** — passive four-microphone GCC-PHAT/SRP directional visualization.
- **Microphones** — four-channel monitor, diagnostics, playback and recording.
- **Surveillance** — RGB/IR motion surveillance with compact MP4/H.264 event recording.
- **Interactivity** — synchronized RGB + metric-Depth full-body XYZ skeleton, hand/finger tracking and body-relative 3D desktop interaction on Windows and Linux.

Use the top tab bar or keys `1`..`5` to switch modules. Camera ownership is explicit because Kinect RGB and infrared share one physical video engine. **3D Scanner and Interactivity share one canonical RGB + metric-Depth source, synchronizer and calibration instance.** Direct transitions between those tabs keep that source live; Interactivity never subscribes to IR.


## Instance-owned Studio runtime

`SynKinectStudio.pde` keeps the Processing callbacks only as the required `PApplet` host boundary. The Studio itself is a `StudioController` instance that owns five `StudioModule` instances. Each module has instance lifecycle methods for initialization, activation, deactivation, drawing, input and disposal. Protocols, themes, transports, UI objects and the 3D viewport are also normal object instances; the PDE contains no `static` declaration.

Tab switching is asynchronous. The render/UI thread only requests a target module; a dedicated lifecycle worker releases the current native transport and activates the latest requested module. Rapid tab changes are coalesced, so blocking pipe/socket shutdown and worker joins never run in the Processing draw/input thread.

Interactivity uses the shared RGBD core plus an isolated heavy-tracking boundary. The single Kinect I/O worker owned by the shared core opens the transport, reads **RGB + metric Depth**, and the canonical adaptive synchronizer publishes immutable `RgbdFramePair` objects once for both Scanner and Interactivity. Scanner drains the bounded pair FIFO for reconstruction; Interactivity reads only the newest published pair and sends it through its separate heavy worker for metric-depth person segmentation, calibrated Depth→RGB edge refinement, XYZ joint lifting, kinematic stabilization and hand/finger analysis. The Processing render thread only consumes the latest immutable tracking snapshot. Stale unprocessed Interactivity work is replaced rather than queued, preventing tracking latency. The RGB preview has an independent refresh cap.

The Surveillance module is reset to **Disarmed** every time its tab is entered. Its video transport uses a bounded FIFO and drains multiple frames per draw tick. Event recording is strictly **MP4/H.264 via FFmpeg/libx264**; there is no AVI/MJPEG fallback. The default 512×384, 10 fps, 384 kbit/s profile targets roughly 2.9 MB/minute before MP4 overhead, while retaining the burned-in timestamp.


## Global seven-language policy

Language ownership is centralized in `StudioController`/`StudioShellI18n`. The supported order is configured by `data/studio.properties` and contains `en-US`, `pt-BR`, `es-ES`, `fr-FR`, `de-DE`, `it-IT` and `ja-JP`. **English (`en-US`) is the primary/default language.** The shell exposes exactly one Language control in the top bar. It cycles the shared locale and propagates it to every initialized module; modules created later start directly in the current shell locale. Module-local language buttons and shortcuts were removed.

There is one physical catalog directory: `data/i18n/`. It contains exactly seven locale files. Separation of concerns is preserved by key namespaces inside each file: `studio.*`, `scanner.*`, `acoustic.*`, `microphone.*`, `surveillance.*` and `interaction.*`. The seven files are key-parity checked in this release; the old per-module i18n directories no longer exist.

## Responsive typography

`studioUiScale()`, `responsiveFontSize()`, `fitCurrentTextSize()` and `ellipsizeToWidth()` are the shared typography policy. Base font size follows the actual window dimensions. Text that lives inside a finite control is then fitted against that control's real width/height, with an ellipsis only if the configured minimum size still cannot fit. Tabs, buttons, cards, metrics, pills, status rows and Interactivity fields use this policy.

## Interactivity pipeline

The Interactivity module acquires **synchronized Kinect RGB + metric Depth** and does not subscribe to IR. Depth connected components choose the tracked user. Every candidate joint is refined against RGB luminance edges through the calibrated Kinect Depth→RGB projection, then lifted to metric camera-space XYZ from robust local Depth samples. The resulting `InteractionSkeleton3D` covers head, neck, chest, spine, pelvis, shoulders, elbows, wrists, hands, hips, knees, ankles and feet. Each joint has image coordinates, XYZ metres, confidence and tracking state.

Each hand adds a 3D wrist/palm model and named thumb/index/middle/ring/pinky tip candidates. Finger identity is derived from stable angular ordering within the hand ROI and therefore carries its own confidence; Depth remains the metric authority. Openness, grab strength and pinch strength are temporally stabilized.

Windows and Linux use the same desktop-overlay/action engine. Pointer coordinates are derived from a body-relative 3D interaction volume centered on the chest and shoulder axis, not from raw image pixels. Both hands must be in front of the chest to arm desktop control. Both open hands scroll; primary closed + secondary open drags; both closed generates a debounced double click. Losing tracking, disabling control, changing tabs or pressing `Esc` releases held drag.

`InteractionOrbCloud` remains a visual projection of the primary hand in the Studio/desktop overlay, while all tracking and interaction decisions are based on the 3D skeleton.

## Compact Surveillance video

Surveillance writes `surveillance-motion.mp4` with H.264/libx264. FFmpeg is a required application dependency for event video. On Linux, install a distribution FFmpeg build with libx264; on Windows, put `ffmpeg.exe` on `PATH` or set `record.ffmpegExecutable` in `data/surveillance.properties`. If the encoder is unavailable, recording fails explicitly rather than silently falling back to a larger legacy format.

## Window-close safety

`Esc` is consumed globally by the Studio and acts only as a cancel/release key; Processing's default ESC-to-exit path is disabled. The JOGL native window uses `DO_NOTHING_ON_CLOSE`, and all close requests are routed through the Studio policy. If Surveillance is armed or recording, the close request is rejected and a localized warning is shown. After Surveillance is disarmed, the same close button exits normally.

## Window resize and pointer coordinates

The shell reserves the top `STUDIO_TAB_H` pixels for navigation and renders each module after translating the canvas into content space. Pointer input uses the inverse transform exposed by `StudioController.contentMouseX()/contentMouseY()`; modules must not read global `mouseX`/`mouseY` directly for content controls. This keeps hover, click and drag geometry aligned after resizing the P3D window and prevents the previous 48-pixel offset between a visible control and its hit area.

## 3D viewport containment

The 3D Scanner reconstruction environment is rendered by an instance-owned off-screen `PGraphics(P3D)` viewport. Grid, axes, point cloud and mesh are rendered into that buffer and then composited into the reconstruction card as one image. This prevents camera/projection/depth state from leaking into the Studio renderer or drawing outside the panel. The viewport is recreated to match the actual panel dimensions after a window resize, so the UI follows the generated window size rather than a fixed design-time height.

## Application icon

The SynKinect Studio icon asset is maintained with the application source. The sketch contains Processing export icon sizes (`icon-16.png` through `icon-512.png`), keeps `data/synkinect-studio-icon.png` as the runtime window icon, and embeds the same PNG in the unified application JAR as a fallback resource. Documentation screenshots and the full Kinect hardware reference image are kept separately under `../../../docs/images/`. Windows staging also includes `SynKinectStudio.ico`; Linux staging includes the PNG and a `.desktop` entry.

## Linux/Processing compatibility

The sketch intentionally contains no `static` declarations. Shared protocol/configuration objects are normal instance objects so the same `.pde` source can pass Processing's Linux preprocessing rules.

The application uses one local transport implementation for Windows named pipes and Linux Unix-domain sockets. Transport shutdown is idempotent and actively closes both input and output sides so worker threads do not remain blocked while changing tabs or closing the program.

## 3D scanner buffering

The depth path is buffered end-to-end:

1. the native camera bridge keeps bounded FIFO queues per RGB/IR/depth stream;
2. `KinectSource` keeps independent bounded RGB/depth capture queues;
3. the Processing render loop drains several frames per tick instead of replacing the pending frame;
4. active reconstruction uses its own bounded FIFO and applies backpressure before consuming more depth frames.

Queue sizes and drain rate are configurable in `data/scanner.properties`. Native and Processing frame numbers are monitored so transport gaps are visible instead of being silently hidden.

## Compact mesh export

The Save action uses Processing `selectOutput()` and suggests `SynKinectScan.stl`, `.obj` or `.ply`, so Windows displays a file-save workflow rather than a folder/open selector.

Exports run outside the capture/render thread. Before writing, the mesh is converted to an indexed representation, nearby vertices are welded, degenerate/duplicate faces are removed and triangle count is bounded with conservative geometric clustering. PLY is binary little-endian. OBJ reuses indexed vertices and always exports as a save-file operation; when compatible photos are found automatically in the selected export folder, it also creates material/texture assets from them. These photos are resized and JPEG-compressed according to `scanner.properties`. STL remains binary and uses the compacted face set.

Important export settings in `data/scanner.properties`:

```properties
export.weldToleranceM=0.0015
export.maxWeldToleranceM=0.008
export.maxTriangles=120000
export.textureMaxSize=2048
export.jpegQuality=0.82
```

Increase `export.maxTriangles` or reduce `export.weldToleranceM` when maximum geometric detail matters more than file size.
