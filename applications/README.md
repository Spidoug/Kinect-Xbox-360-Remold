# Applications

The application tree separates editable Processing sketches from exported runtime payloads.

```text
applications/
├── processing/
│   ├── SynKinect3DScanner/
│   ├── SynKinectSurveillance/
│   ├── SynKinectMicrophones/
│   └── SynKinectAcousticScanner/
└── binaries/
    ├── windows-x64/
    └── linux-x64/
```

Make application changes in `processing/`. Exported `.exe`, `.jar`, native libraries and data belong in `binaries/<platform>/`.

The current committed executable application bundle is Windows x64. Linux-aware transport code is already present in the Processing source, but the Linux launcher bundle is still a release task.
