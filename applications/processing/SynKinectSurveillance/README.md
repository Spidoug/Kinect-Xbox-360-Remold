# SynKinect Surveillance

Processing surveillance application for the Kinect 1414 camera/depth bridge.

## State machine

The Kinect 1414 raw-video engine is exclusive: RGB and raw IR cannot be streamed at the same instant.

- **Armed / idle:** subscribes to `IR + Depth`; motion is detected on raw IR.
- **Recording:** after sustained motion, creates an event directory, stores the trigger IR image and switches to `RGB + Depth`. Depth remains subscribed so the IR projector stays active.
- **Low-light fallback:** sustained dark RGB switches the same event back to `IR + Depth`; recording continues in IR rather than ending or keeping unusably dark RGB.
- **Return to guard:** after `motion.stopAfterMs` without motion (default 60 seconds), the AVI is finalized and monitoring returns to `IR + Depth`.

Only one ScannerPort mode-changing client should run at a time.

## Corrected video generation

The recorder owns a constant-frame-rate timeline at `record.fps`. Incoming Kinect frames update the latest source image; AVI timing no longer depends directly on when source frames happen to arrive. This keeps playback duration stable across short RGB↔IR mode changes, transport jitter and short reconnect gaps.

A recent frame can be held for up to `record.frameHoldMs`. Beyond that interval, the burned-in mode label includes `STALE` so a held image is not presented as fresh video.

Each event is written as:

- `surveillance-motion.avi.partial` while the event is active;
- `surveillance-motion.avi` after successful AVI finalization;
- `trigger-ir.jpg` for the IR trigger frame;
- `event.properties` for state, timeline and recorder diagnostics.

The writer checkpoints RIFF/frame sizes every `record.checkpointFrames` frames. On clean close it appends an AVI 1.0 `idx1` index, flushes the file and renames the partial output. Index offsets are relative to `movi` and point to each `00dc` MJPEG chunk.

The live preview and recorded MJPEG frames include the configured date/time and active RGB/IR mode.

## Native IP camera runtime

This sketch does not host HTTP. Password-protected HTTP/MJPEG is provided by `Kinect360RemoldCameraIp.exe` in the installed driver/runtime package. It consumes the shared RGB broker used by the Windows virtual camera and does not own ScannerPort.

When Surveillance owns IR, the camera bridge marks shared RGB offline immediately. IP and virtual-camera consumers remain unavailable until a legitimate RGB owner restores RGB; they do not force the physical endpoint out of IR mode.

Use the driver administration panel to view credentials or persistently enable/disable the native IP camera.

## Configuration

Runtime policy is in `data/surveillance.properties`. User-facing strings are in `data/i18n/*.properties`, with English as the canonical/default locale.
