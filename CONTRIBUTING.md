# Contributing

Thanks for improving Kinect Xbox 360 Remold.

## Repository rule: source first

Please keep the repository free of generated runtime/build payloads. Do not commit:

- `applications/binaries/`;
- `drivers/windows/binaries/`;
- `drivers/linux/dist/`;
- package output directories;
- `.cache/`, logs, PDBs, JARs, EXEs, DLLs or generated catalogs;
- Microsoft Kinect firmware blobs.

Runtime launchers that are actual source belong under `applications/runtime-templates/`.

## Before submitting a source change

1. Build from a clean tree on the target platform when possible.
2. Keep the 1414/1473 logical control API model-independent at the application boundary.
3. Keep the single V1 ScannerPort wire format; do not add alternate protocol paths.
4. Keep raw camera conversion outside the USB capture boundary unless an explicit OS/network adapter requires a decoded output.
5. Preserve synchronized four-channel microphone timing for spatial audio paths.
6. Run:

```bash
./scripts/VERIFY-SOURCE-RELEASE.sh
```

## Documentation and screenshots

Public UI screenshots belong under `docs/images/`. When the UI changes materially, update the screenshot set and the root README together so the repository front page reflects the current application.

## Third-party material

Do not commit Microsoft firmware or other third-party binary payloads unless redistribution rights are explicit and documented. Build-time downloads must be version-pinned and integrity-checked.
