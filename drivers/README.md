# Native drivers and runtimes

Platform implementations are intentionally separated.

```text
drivers/
├── windows/
│   ├── source/
│   └── binaries/
└── linux/
    ├── source/
    └── binaries/<architecture>/
```

`source/` is editable code. `binaries/` is the release/staging area and should contain only compiled/installable artifacts plus small support files needed to identify them.

For architecture and comparison with known Kinect stacks, see `../docs/ARCHITECTURE.md` and `../docs/DRIVER-COMPARISON.md`.
