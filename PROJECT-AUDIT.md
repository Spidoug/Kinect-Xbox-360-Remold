# Project audit — cleaned source release

## Scope

This audit covers the repository structure, source-vs-artifact policy, screenshot assets, build scripts and the main public documentation.

## Actions performed

1. Removed the committed `tests/` directory from the deliverable.
2. Removed generated application payloads under `applications/binaries/`.
3. Removed the helper script `scripts/linux/TEST-STUDIO.sh` because it depended on the removed `tests/` tree.
4. Replaced the six repository screenshots in `docs/images/` with the new screenshots supplied by the user.
5. Updated `.gitignore` to ignore `applications/binaries/`.
6. Updated repository documentation so it describes a source-only, artifact-free release.
7. Simplified source-release validation so it no longer depends on the removed tests or prebuilt application launchers.

## Audit findings

### Cleanups completed

- **Tests removed from deliverable**: the repository no longer ships the `tests/` folder.
- **Generated application artifacts removed**: `applications/binaries/` is now absent from the cleaned source release.
- **Documentation aligned**: README and docs now describe generated payloads as build outputs rather than repository inputs.
- **Screenshot refresh completed**: the new UI screenshots are now the repository screenshots used in `docs/images/`.

### Risks and follow-up notes

- The validation surface is now **static/source-oriented**. If you later want automated runtime regression coverage again, it should live in a separate CI/test package, not inside this clean source release.
- Build/install scripts still reference generated Studio launchers under `applications/binaries/`. This is expected: those files are created by the build and are not meant to be committed.
- The Windows and Linux native source trees remain intact; only deliverable hygiene and repository consistency were changed here.

## Final release intent

This repository revision is intended to behave as a **clean source release**:

- editable source included;
- documentation included;
- build scripts included;
- generated runtime/application artifacts excluded;
- tests excluded from the deliverable;
- user-provided screenshots installed as the repository images.
