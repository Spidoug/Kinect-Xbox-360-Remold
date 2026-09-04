# SynKinect Studio runtime templates

These files are source templates used by the platform build scripts.

They are intentionally kept separate from `applications/binaries/`, which is a generated build-output directory and is not committed in the clean source release.

- `windows-x64/SynKinectStudio.cmd` — standard-user Windows launcher template.
- `linux-x64/SynKinectStudio.sh` — standard-user Linux launcher template.
- `linux-x64/SynKinectStudio.desktop` — Linux desktop entry template.

The build stages these templates, downloads the pinned Java/JOGL dependencies with SHA-256 validation, compiles SynKinect Studio, and creates the platform runtime trees under `applications/binaries/`.
