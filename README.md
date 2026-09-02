# Repository helper scripts — V1

## Native drivers

- `windows/BUILD-DRIVER.cmd` — builds the current Windows native driver/runtime source.
- `linux/BUILD-DRIVER.sh` — builds the current Linux native driver/runtime source.
- `linux/INSTALL-DRIVER.sh` — builds and installs the current Linux runtime.
- `VERIFY-SOURCE-RELEASE.sh` — validates that the cleaned source release contains no generated application/native payloads and no retired V1 contracts.

## SynKinect Studio

- `windows/BUILD-STUDIO.cmd` — rebuilds the self-contained Java 17 Studio JAR; body tracking and MJPEG AVI recording are internal.
- `windows/BUILD-APPLICATION-RUNTIME.cmd` — creates the minimized Windows Java runtime used by a portable application package.
- `windows/PACKAGE-APPLICATION.cmd` — packages the Windows application runtime.
- `linux/BUILD-STUDIO.sh` — rebuilds the Java 17 Studio JAR on Linux and stages generated runtime assets.

Native driver outputs and generated Studio payloads are build outputs and are not source-release inputs.
