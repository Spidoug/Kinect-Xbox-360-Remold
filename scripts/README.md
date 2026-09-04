# Repository helper scripts — V1

## Native drivers

- `windows/BUILD-DRIVER.cmd` — builds the current Windows native driver/runtime source.
- `linux/BUILD-DRIVER.sh` — builds the current Linux native driver/runtime source.
- `linux/INSTALL-DRIVER.sh` — builds and installs the current Linux runtime.
- `VERIFY-SOURCE-RELEASE.sh` — validates that the cleaned source release contains no generated application/native payloads and no non-V1 contracts.

## SynKinect Studio

- `windows/BUILD-STUDIO.cmd` — bootstraps pinned Processing/JOGL/GlueGen dependencies, stages runtime templates and rebuilds the self-contained Java 17 Studio JAR.
- `windows/BUILD-APPLICATION-RUNTIME.cmd` — creates the minimized Windows Java runtime used by a portable application package.
- `windows/PACKAGE-APPLICATION.cmd` — packages the Windows application runtime.
- `linux/BUILD-STUDIO.sh` — bootstraps the same pinned dependencies, rebuilds the Java 17 Studio JAR on Linux and stages both platform runtime trees.

Native driver outputs and generated Studio payloads are build outputs and are not source-release inputs.
