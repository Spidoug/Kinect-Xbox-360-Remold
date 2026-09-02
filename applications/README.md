# Applications

V1 has one editable application: **SynKinect Studio**.

```text
applications/
├── processing/
│   └── SynKinectStudio/               # editable Processing/Java source and assets
└── runtime-templates/
    ├── windows-x64/SynKinectStudio.cmd
    └── linux-x64/
        ├── SynKinectStudio.sh
        └── SynKinectStudio.desktop
```

Generated JARs, platform JOGL/GlueGen libraries, launchers copied from these templates and runtime data are created under `applications/binaries/<platform>/` by the build. That directory is intentionally absent from the clean source release.

The Studio build bootstraps the pinned Java graphics dependencies itself when required:

- Processing Core 4.4.6;
- JOGL 2.5.0;
- GlueGen Runtime 2.5.0;
- Windows/Linux AMD64 native JOGL/GlueGen JARs.

Every downloaded dependency is checked against the repository-pinned SHA-256 before compilation or staging.

`SynKinectStudio.pde` and the other `.pde` tabs contain the five modules shown in one window: 3D Scanner, Acoustic Scanner, Microphones, Surveillance and Interactivity.

## Assets

- `processing/SynKinectStudio/data/synkinect-studio-icon.png` is the runtime window icon.
- `icon-*.png` are the Processing/export icon sizes.
- Public documentation screenshots are stored separately under [`../docs/images/`](../docs/images/).
