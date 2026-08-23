# SynKinect Studio Linux x86-64

`SynKinectStudio.jar` is the same unified application binary used by the Windows staging area. `SynKinectStudio.sh` prefers a bundled `java/bin/java` runtime when present and otherwise uses Java 17+ from PATH. English (`en-US`) is the default/first UI language.

The Processing window icon is embedded in the JAR and mirrored under `data/`. `synkinect-studio-icon.png` and `SynKinectStudio.desktop` are provided for Linux desktop packaging.

Install the native Kinect runtime first with the graphical `.deb` package under `drivers/linux/packages/output/` so the Unix-domain sockets and device services are available.

Surveillance event video uses **MP4/H.264 via FFmpeg/libx264 only**. Install a distribution `ffmpeg` build with libx264, or set `record.ffmpegExecutable` in `data/surveillance.properties`. The default 512×384 / 10 fps / 384 kbit/s profile targets about 2.9 MB per minute before container overhead.

3D Scanner and Interactivity share one synchronized **RGB + metric Depth** source and stereo-calibration instance. Interactivity never opens a second Kinect session and never subscribes to IR.
