# Native drivers and runtimes — V1

The native driver tree is **source-only** in the repository.

```text
drivers/
├── windows/
│   ├── BUILD.cmd
│   ├── BINARY-PAYLOAD.md
│   └── source/
└── linux/
    ├── BUILD.sh
    ├── VERIFY-V1.sh
    ├── source/
    └── packages/
```

Compiled native executables, catalogs, shared libraries and OS packages are generated outputs. They are not committed or shipped as inputs to another build.

- Windows builder output: `drivers/windows/binaries/`
- Linux builder output: `drivers/linux/dist/<architecture>/`
- Debian package output: `drivers/linux/packages/output/`

All three locations are ignored by `.gitignore` and recreated from the source included in the release.

See [native driver build](../docs/BUILD-DRIVERS.md) and [architecture](../docs/ARCHITECTURE.md).
