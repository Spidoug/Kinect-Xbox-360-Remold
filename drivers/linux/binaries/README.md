# Compiled Linux runtime payloads

Compiled Linux artifacts are grouped by architecture:

```text
binaries/
└── x86_64/
    ├── bin/
    ├── libexec/
    ├── support/
    ├── BUILD-INFO.txt
    └── SHA256SUMS
```

The committed x86_64 payload is a development convenience. Use `../BUILD.sh` to rebuild from source on the target distribution when ABI compatibility matters.
