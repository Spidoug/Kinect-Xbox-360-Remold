# Repository helper scripts — V1

## Native drivers

- `windows/BUILD-DRIVER.cmd` — builds the current Windows native driver/runtime source.
- `linux/BUILD-DRIVER.sh` — builds the current Linux native driver/runtime source.
- `linux/INSTALL-DRIVER.sh` — builds and installs the current Linux runtime.

## SynKinect Studio

- `windows/BUILD-STUDIO.cmd` — bootstraps pinned Processing/JOGL/GlueGen dependencies, stages runtime templates and rebuilds the self-contained Java 17 Studio JAR.
- `windows/BUILD-APPLICATION-RUNTIME.cmd` — creates the minimized Windows Java runtime used by a portable application package.
- `windows/PACKAGE-APPLICATION.cmd` — packages the Windows application runtime.
- `linux/BUILD-STUDIO.sh` — bootstraps pinned dependencies and JDK 17+ when needed, rebuilds the Studio JAR, and creates the self-contained Linux Java runtime with `jdeps`/`jlink`.

Native driver outputs and generated Studio payloads are build outputs and are not repository inputs.
