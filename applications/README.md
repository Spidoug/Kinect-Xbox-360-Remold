# Applications

V1 has one editable Processing application: **SynKinect Studio**.

```text
applications/
├── processing/
│   └── SynKinectStudio/
│       ├── SynKinectStudio.pde
│       ├── README.md
│       ├── icon-*.png
│       └── data/
│           ├── i18n/
│           └── synkinect-studio-icon.png
└── binaries/
    ├── windows-x64/
    └── linux-x64/
```

`SynKinectStudio.pde` contains the five modules shown as tabs in one window: 3D Scanner, Acoustic Scanner, Microphones, Surveillance and Interactivity. It is the only `.pde` source of truth in V1.

Generated JARs, launchers and platform libraries belong only under `binaries/<platform>/`. Do not edit exported JARs as source.


## Notes

- In the 3D Scanner, **STL**, **OBJ** and **PLY** are save/export file actions.
- The former standalone **Photos** action was removed; OBJ export automatically uses compatible photos found in the chosen export directory when available.
- The canonical runtime window icon is `processing/SynKinectStudio/data/synkinect-studio-icon.png`; Processing export icon sizes remain beside the sketch as `icon-*.png` and runtime copies are staged under `binaries/`.
- Documentation screenshots are not application runtime assets; they belong under [`../docs/images/`](../docs/images/).
