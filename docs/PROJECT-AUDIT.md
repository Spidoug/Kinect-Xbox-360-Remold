# Project audit — V1 clean-source release

## Scope

This audit covers repository layout, generated artifacts, public presentation assets, source/build consistency, SynKinect Studio bootstrapping and the main Windows/Linux runtime boundaries.

## Repository cleanup

- Removed the committed `tests/` tree from the public clean-source deliverable.
- Removed generated application runtime payloads from `applications/binaries/`.
- Removed the test-only Linux helper that depended on the removed test tree.
- Kept generated native driver/package directories out of the source release.
- Added/confirmed `.gitignore` rules for generated application payloads and `.cache/`.
- Moved launcher files that are actual source into `applications/runtime-templates/` rather than hiding them inside a generated binary tree.
- Replaced the public Studio screenshots with the current screenshots supplied by the project owner.

## Build audit and correction

The cleanup exposed a real source-release problem: the former Studio build expected Processing/JOGL/GlueGen JARs to already exist inside `applications/binaries/`. Once generated artifacts were correctly removed, a fresh clone could no longer build SynKinect Studio.

That dependency inversion was corrected.

The current Studio builders now:

1. create `applications/binaries/` only as generated output;
2. download pinned Processing Core 4.4.6, JOGL 2.5.0 and GlueGen 2.5.0 artifacts when missing;
3. validate every downloaded JAR by SHA-256;
4. stage Windows/Linux native JOGL/GlueGen JARs into the appropriate generated runtime;
5. copy source launchers from `applications/runtime-templates/`;
6. compile one deterministic `SynKinectStudio.jar` and place the same JAR in both platform runtimes.

The revised Linux builder was exercised with a cache populated by the exact previously pinned dependencies. It reproduced the known Studio JAR SHA-256:

`1a8cd99c0009bb1e78bfa8e4312d98874af381f51e2970f2a9a69f19ca6b9ff7`

This confirms that the bootstrap correction changes the source-release/build boundary, not the compiled Studio application logic.

## Architecture review

Static source checks confirm the current V1 architecture still contains:

- stable location-path identity for Kinect camera devices;
- debounced Windows hardware presence handling;
- independent 1473 camera and audio/control setup;
- raw sensor-oriented camera transport;
- four-channel Kinect UAC endpoint discovery on Windows;
- Acoustic Scanner delay-and-sum beamforming and near-field localization;
- Surveillance IR/RGB day-night arbitration and foreground release behavior;
- Processing pixel-density handling for the current Studio UI.

## Public release policy

The clean source archive is intended to contain:

- editable application source and assets;
- Windows/Linux native source;
- build/install/package scripts;
- runtime launcher templates;
- public documentation and screenshots;
- third-party notices/license texts.

It intentionally excludes:

- generated application JAR/runtime trees;
- native executables, DLLs, catalogs, packages and PDBs;
- build caches and logs;
- internal regression test trees;
- Microsoft firmware blobs.

## Validation boundary

Because the clean public tree intentionally excludes the internal tests, `scripts/VERIFY-SOURCE-RELEASE.sh` performs source/repository contract validation rather than pretending to be a complete hardware test suite. Hardware/runtime validation still belongs on the target Windows/Linux machines after a fresh build.
