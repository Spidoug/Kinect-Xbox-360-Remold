# Repository helper scripts

- `windows/BUILD-DRIVER.cmd` — forwards to the Windows native driver build.
- `windows/BUILD-APPLICATION-RUNTIME.cmd` — generates the minimized Windows Java runtime for exported applications.
- `linux/BUILD-DRIVER.sh` — forwards to the Linux native build.
- `linux/INSTALL-DRIVER.sh` — builds and installs the Linux runtime.

Platform-local driver entry points also remain under `drivers/windows/` and `drivers/linux/` so users do not need these helpers for normal work.
