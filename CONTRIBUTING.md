# Contributing

Thank you for improving Kinect Xbox 360 Remold.

## Ground rules

- Keep editable source separate from generated binaries.
- `applications/processing/SynKinectStudio/SynKinectStudio.pde` is the single V1 Processing source of truth.
- Do not reintroduce split Processing applications or `static` declarations into the `.pde` source.
- Preserve cross-platform transport behavior: Windows uses named pipes; Linux uses Unix-domain sockets.
- Do not describe a hardware path as validated unless it was tested with a physical Kinect and the test conditions are recorded.

## Before opening a pull request

1. Build or syntax-check the component you changed.
2. Search the Processing source for `static` declarations.
3. Keep generated build directories and logs out of commits.
4. Update documentation when changing protocols, package layout, configuration keys or release behavior.
5. For changes to camera/depth buffering, include the queue/ownership implications in the PR description.
6. For native Windows changes, state the Windows SDK/WDK/toolset used.
7. For Linux changes, state the distribution/compiler and whether a physical Kinect was tested.

## Commit scope

Prefer small, reviewable commits grouped by behavior: application, Windows runtime, Linux runtime, packaging or documentation.
