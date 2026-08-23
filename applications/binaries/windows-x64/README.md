# SynKinect Studio Windows x64

`lib/SynKinectStudio.jar` is the unified SynKinect Studio application. The release launcher is `SynKinectStudio.cmd`. English (`en-US`) is the default/first UI language.

## Java runtime policy

A distributed Windows release is **portable** and must contain `java/bin/java.exe`. Build the release with:

```text
scripts\windows\PACKAGE-APPLICATION.cmd
```

That command first creates the minimal Java runtime with `jlink`, validates the required application payload and only then creates the ZIP. A source checkout may still fall back to `JAVA_HOME`, `JDK_HOME`, Java on `PATH`, or a Java runtime bundled with a Processing installation, but that fallback is not considered a valid release package.

Startup and JVM diagnostics are written to `logs/SynKinectStudio.log` so renderer or native-library failures are no longer hidden by `javaw.exe`.

The Processing window icon is embedded in the JAR and mirrored under `data/`. Only Windows x64 JOGL/GlueGen native libraries are staged here.

## Compact Surveillance video

Surveillance event recording requires **FFmpeg with libx264**. You need to place ffmpeg.exe in this folder to use the surveillance mode.

3D Scanner and Interactivity share one synchronized **RGB + metric Depth** source and stereo-calibration instance. Interactivity never opens a second Kinect session and never subscribes to IR.
