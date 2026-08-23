# SynKinect Studio application payloads

V1 has one application and one object model. The Windows and Linux staging areas contain the same freshly built `SynKinectStudio.jar`; only the Processing/OpenGL native runtime libraries and launcher format differ by platform. English (`en-US`) is the primary/default locale.

- `windows-x64/` — Windows launcher, unified JAR, Windows x64 JOGL/GlueGen natives, synchronized data files and `SynKinectStudio.ico`.
- `linux-x64/` — Linux launcher, unified JAR, Linux x86-64 JOGL/GlueGen natives, synchronized data files, application icon and desktop entry.

The JAR embeds `synkinect-studio-icon.png` in addition to the external `data/` copy, so the Processing window can set the icon in an exported application.

3D Scanner and Interactivity share one canonical synchronized Kinect RGB + metric-Depth source and one stereo-calibration/registration instance. Scanner consumes FIFO pairs; Interactivity consumes the latest pair on its isolated 3D skeleton/hand fusion worker. Surveillance event recording is strict MP4/H.264 through external FFmpeg/libx264; no legacy AVI/MJPEG recorder is included.

There are no split application payloads or cross-platform native JAR bundles in the Windows staging directory. Source changes belong in `../processing/SynKinectStudio/`; a release build must rebuild the unified JAR and copy that exact JAR to both platform staging areas.
