# SynKinect3DScanner

Processing 3D scanner for the Kinect Xbox 360 Remold Scanner Port.

## Architecture

The application keeps one RGB + metric-Depth subscription (`mask=5`) per transport session. Start, Pause, Reset, mesh editing and export change reconstruction state only; transport ownership stays in `KinectSource` and protocol constants stay in `ScannerProtocol`. If Processing exits, is killed, or a pipe stays open without delivering frames, the source closes the stale handle and creates a fresh subscription automatically.

The scanner is split into independent blocks:

- `ScannerProtocol.pde` — Scanner Port ABI and stream/flag rules;
- `AppConfig.pde` + `data/scanner.properties` — runtime policy, calibration, thresholds and tuning;
- `KinectSource.pde` — named-pipe transport and frame validation;
- `DepthDetection.pde` — depth diagnostics, target detection/tracking and depth preview;
- `PointCloud.pde` — cloud filtering and spatial index;
- `IcpTracker.pde` / `TSDFVolume.pde` — tracking and fusion;
- `Mesh*.pde` / `Exporters.pde` — mesh processing and output;
- `Localization.pde` + `data/i18n/*.properties` / `UI.pde` — locale loading, gray visual tokens and presentation.

The microphone transport remains independent in `SynKinectMicrophones` and is never opened by Scanner3D.

## Depth reliability

Depth arrives as unsigned little-endian millimetres (`DepthMm16`, zero = invalid). Calibration state and USB recovery state are carried on every frame; reconstruction never relies on a stale global calibration decision.

The native bridge retries the device metric calibration query when Depth is requested. A transient control-transfer failure at service startup therefore no longer requires a service restart. The isochronous frame assembler tolerates a small packet-sequence gap, fills missing depth packet slots with raw invalid samples and marks the published frame as recovered instead of discarding the complete frame.

The Processing side always keeps the latest depth frame visible for diagnostics, even if it is too sparse for fusion. Quality gates are applied only to tracking/reconstruction.

## Target detection and ICP

Depth analysis uses a configurable central ROI and histogram. Initial acquisition favors the nearest statistically significant foreground cluster; after lock, candidates close to the current target depth are preferred, reducing jumps to a wall or background surface.

Point-cloud generation can reject isolated spatial outliers. The ICP spatial hash searches a radius derived from `icpMaxDistanceM / icpCellSizeM`; it is not limited to adjacent cells, so all correspondences inside the configured ICP distance can be found.

ICP and TSDF run on a dedicated reconstruction worker with latest-frame semantics. Slow fusion drops stale work instead of blocking RGB/Depth preview or building an unbounded queue.

## UI and language

The interface uses a neutral-gray responsive card layout with dedicated RGB, metric-depth and reconstruction areas. Actions are grouped into Capture, Mesh, Export and View panels; diagnostic prose was reduced to compact states and metrics so the working area stays visually clean. Theme values live in `UiTheme` instead of being repeated as coordinates/colors throughout the sketch.

Text is loaded from UTF-8 locale catalogs under `data/i18n/`. `I18n` discovers available catalogs at runtime from each file's `meta.locale`; one catalog declares `meta.default=true`, and `meta.short` supplies the compact UI label. `app.language=en-US` makes English the primary interface language, while any installed locale can still be selected in `data/scanner.properties` or at runtime. Press `G` or the Language button to cycle the discovered catalogs at runtime.

## Runtime configuration

Tune the UTF-8 `data/scanner.properties` file instead of editing code. It contains depth range and plausibility gates, Kinect depth intrinsics, target ROI/stability rules, transport reconnect/stale timeouts, cloud filtering, ICP, TSDF, mesh cleanup/smoothing, turn coverage, photo defaults and export filenames.

The configuration loader and locale loader both decode UTF-8 explicitly. Defaults remain compiled as safe fallbacks only; a missing or malformed property falls back to its bounded default rather than aborting the scanner.

## Export

STL, OBJ and PLY share one export-space transform. The Y-axis reflection and triangle winding are handled once so all formats preserve the same geometry orientation and outward face direction. External-photo pose CSV handling supports quoted filenames and its filename is configurable.

## Restart/reconnect behavior

`KinectSource` treats a connected pipe with no frame activity for `transport.connectionStaleMs` as a dead session. It closes that handle, resets per-session frame ordering, and retries after `transport.reconnectMs`. The native Scanner Port additionally validates the named-pipe client PID so an abruptly terminated Processing process cannot retain the scanner session.

## v14 retained RGB mesh pipeline

Final mesh generation is deliberately separated from the Processing render thread. Pressing Mesh pauses fusion, waits for any in-flight reconstruction frame to leave the state section, and then runs extraction, component cleanup, Taubin polish and normal regeneration on the low-priority `SynKinect3D-Mesh` worker. The published mesh is immutable; the P3D thread compiles it into retained `PShape` chunks incrementally and only replays those chunks afterward instead of rebuilding every triangle on every UI frame.

Kinect RGB is accumulated together with the TSDF surface during scanning. Depth samples carry the latest immutable RGB observation into reconstruction, surface voxels maintain a bounded running RGB average, and extracted vertices inherit the closest observed Kinect color. This gives a baked multi-view Kinect RGB mesh rather than applying only the final camera image. `mesh.rgb.*` properties expose the full depth/RGB lens and stereo model plus bounded automatic fine alignment, so per-device calibration can replace the representative Kinect-v1 profile without source changes. PLY export now includes RGB vertex properties.

Automatic final polish applies geometric rejection, removes small disconnected components and uses lambda/mu Taubin smoothing to reduce Kinect/voxel stair-stepping without the strong shrinkage of ordinary repeated Laplacian smoothing. `mesh.minimumWeight=2` also rejects single-observation TSDF surfaces by default. Manual Clean/Smooth/Center operations use the same background worker, and Undo swaps immutable mesh snapshots instead of eagerly deep-copying the complete mesh before every edit.


## Near-object policy

The scanner now accepts calibrated metric samples from 0.20 m upward and treats 180 mm as the diagnostic plausibility floor. This removes the previous software-side 0.45 m rejection and narrows foreground acquisition for close objects. The Kinect 1414 still has a physical structured-light minimum range: pixels returned by the hardware as invalid/zero remain invalid and are never fabricated. UI typography is centralized in `UiTheme` and uses a larger baseline for all labels, buttons, status text, and metrics.


## Interface

The scanner uses the native Windows `Segoe UI` family when available, with a runtime-resolved fallback instead of bundling font files. Headings prefer `Segoe UI Semibold`; all type sizes, panel spacing, colors, and status accents are centralized in `UiTheme`, while font-family policy lives in `scanner.properties`.

## Interface policy

The scanner uses the same semantic panel/typography policy as the other Processing tools; see `../UI-PANEL-STANDARD.md`.


## RGB/depth registration and temporal detail

The scanner pairs RGB and metric-depth frames by capture timestamps taken at USB start-of-frame, before RGB/depth conversion, before a frame enters reconstruction. Frames outside the configured synchronization skew are fused geometrically without stale color instead of applying the wrong RGB image.

Color registration is depth-dependent. Each depth pixel is undistorted, back-projected into 3D, transformed into the RGB camera coordinate system, projected through the RGB lens model, occlusion-tested and bilinearly sampled. The bundled calibration is a representative Kinect-v1 profile; `scanner.properties` intentionally exposes every intrinsic/extrinsic value so a per-device stereo calibration can replace it without source changes. A conservative edge-based fine offset corrector can compensate small unit-to-unit mounting shifts during scanning.

Longer scan time improves effective reconstruction detail through temporal fusion rather than pretending the 640x480 sensors have more physical pixels. Accepted poses are tracked with a sparse cloud but fused from dense depth samples, while synchronized/well-exposed RGB observations receive more surface-color weight. The default TSDF is 192^3 at 3.5 mm voxels.
