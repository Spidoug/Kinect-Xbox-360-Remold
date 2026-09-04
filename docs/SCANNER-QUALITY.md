# 3D Scanner V1 — quality, benchmarks and market comparison

## Purpose

The V1 3D Scanner is designed to extract the highest practical reconstruction quality from Kinect for Xbox 360 while keeping capture responsive. It is intended for bodies, busts, sculptures, props, furniture-scale parts and other medium/large organic or decorative objects.

It is **not** a metrology scanner and it should not be used as a substitute for a modern scanner when a printed part must hold sub-millimetre mechanical tolerances.

## Current V1 reconstruction pipeline

```text
Kinect 360
  ├─ Depth 640×480
  │    ↓
  │  per-device metric correction + per-pixel noise confidence
  │    ↓
  │  edge-aware filtering
  │    ↓
  │  real-time pose / 192³ preview
  │    ↓
  │  selected full-resolution keyframes
  │    ↓
  │  robust coarse-to-fine ICP against a local multi-view map
  │    ↓
  │  loop-closure correction
  │    ↓
  │  pose-fixed 2× multi-frame depth super-resolution
  │    ├─ subpixel reprojection
  │    ├─ foreground z-buffer
  │    ├─ temporal outlier rejection
  │    └─ confidence/distance weighting
  │    ↓
  │  288³ TSDF, 2.3 mm voxel, 9 mm truncation band
  │    ↓
  │  indexed mesh cleanup, up to 600,000 triangles
  │
  └─ RGB-HQ keyframes
       ├─ optional raw 1280×1024 GRBG Bayer capture (~10 fps)
       ├─ edge-aware demosaic
       ├─ sharpness/exposure quality gate
       ├─ photometric normalization
       ├─ conservative sharpening
       └─ quality-weighted multi-view color fusion → up to 4K texture
```

The 192³ volume is only the interactive preview. The exported HQ mesh is rebuilt after capture from the retained keyframes and refined poses.

## Internal V1 benchmarks

These benchmark figures come from the project deterministic synthetic regression workflow. They validate the algorithms; they are **not a physical accuracy certificate for Kinect hardware**.

### Per-device depth calibration

Held-out planar test (the validation distance is not one of the five calibration distances):

| Pipeline | RMS geometric error | Relative result |
| --- | ---: | ---: |
| Raw synthetic depth | 5.661 mm | baseline |
| HQ filter without device correction | 5.626 mm | 0.6% lower than raw |
| HQ + per-device depth correction | **3.531 mm** | **37.2% lower than HQ filter** |

The important result is that filtering alone cannot remove fixed-pattern depth distortion. The per-pixel calibration is what corrects systematic surface error.

### Multi-frame depth super-resolution

Synthetic five-view subpixel test with injected near-surface outliers and background leakage:

| Metric | Conventional HQ depth | V1 Depth SR | Change |
| --- | ---: | ---: | ---: |
| Useful samples | 68,200 | **273,680** | **4.01×** |
| Surface RMS | 1.418 mm | **0.662 mm** | **53.3% lower** |
| Temporal outliers rejected | — | 3,836 | — |
| Occluded/background samples rejected | — | 7,574 | — |

The 0.662 mm value measures the synthetic fusion stage under controlled geometry. It must not be presented as real-world Kinect accuracy.

### Robust pose refinement

The synthetic HQ ICP regression reduces correspondence RMS from approximately **15.29 mm to 9.60 mm** from a deliberately perturbed starting pose. This test protects the pose-refinement path from regressions.

## Comparison with current 3D scanners used for 3D printing

The values below use official manufacturer specifications available on 2026-08-24. Vendor accuracy/precision specifications are measured under each manufacturer's own test conditions and are not directly equivalent to Remold's synthetic regression RMS or TSDF voxel size.

| Characteristic | Kinect 360 Remold V1 | Revopoint POP 3 Plus | Creality Otter Lite |
| --- | --- | --- | --- |
| 3D acquisition | Kinect v1 structured-light depth, 640×480 | Dual-camera infrared structured light | Four-lens NIR stereo structured light |
| Certified/advertised physical accuracy | **Not certified yet** | up to **0.08 mm** single-frame accuracy | up to **0.05 mm @ 100 mm** |
| Precision / 3D resolution | 2.3 mm final TSDF voxel; this is a reconstruction parameter, not sensor accuracy | up to **0.04 mm** single-frame precision; **0.05 mm** fused point distance | **0.1–2 mm** 3D resolution |
| Scan rate | Depth 30 fps; RGB-HQ keyframes ~10 fps | up to **18 fps** | up to **30 fps** |
| Pose/tracking | calibrated RGBD, robust ICP, local map, loop closure, multi-frame depth fusion | feature/marker tracking + 9-axis IMU + global marker mode | marker/geometry/texture alignment + IMU |
| Color | optional 1280×1024 raw Bayer HQ keyframes + multi-view color fusion | HD RGB camera | 24-bit full-color scanning |
| Mesh output | OBJ / STL / PLY; up to 600k triangles by default | common 3D-print/CAD formats through Revo Scan | OBJ / STL / PLY |
| Best V1 use | busts, bodies, sculptures, props and medium/large decorative objects | 3D printing and reverse engineering of small/medium objects | broad small-to-large object scanning |
| Small mechanical features / tight fits | **Limited by Kinect hardware** | strong | strong |

### Official comparison sources

- Revopoint POP 3 Plus product page: https://www.revopoint3d.com/products/portable-3d-scanner-pop3
  - single-frame accuracy up to 0.08 mm
  - single-frame precision up to 0.04 mm
  - fused point distance up to 0.05 mm
  - scanning speed up to 18 fps
  - working distance 150–400 mm
- Creality Otter Lite product page: https://www.creality.com/products/creality-cr-scan-otter-lite-3d-scanner
  - accuracy 0.05 mm @ 100 mm
  - 3D resolution 0.1–2 mm
  - scanning speed up to 30 fps
  - working distance 120–1200 mm

Sources accessed 2026-08-24.

## What the comparison means for 3D printing

### Strong use cases for Remold V1

- human heads, torsos and full-body captures;
- busts and statues;
- cosplay props;
- furniture-scale geometry;
- decorative objects where the important features are several millimetres or larger;
- visual replicas that will be cleaned/sculpted before printing.

### Use a modern dedicated scanner instead when

- a printed part must mate with another part at sub-millimetre tolerance;
- threads, gear teeth, connector geometry or small holes are critical;
- reverse engineering needs reliable dimensional inspection;
- features below approximately a few millimetres must be captured directly rather than reconstructed/edited.

## Quality rules for real scans

For best results with Kinect 360 Remold V1:

1. Calibrate each physical Kinect from the Studio before dimensional work.
2. Keep the object in the close/mid depth range where Kinect v1 noise is lower.
3. Use diffuse surfaces and avoid direct sunlight or strong IR contamination.
4. Move slowly with large overlap between views.
5. Complete a full sweep when possible so loop closure can correct accumulated drift.
6. Let the HQ build complete before judging geometry; the live 192³ preview is intentionally lower quality.
7. For STL printing, judge geometry independently from the RGB texture. RGB-HQ improves appearance and can support alignment, but it does not change the physical depth sensor resolution.

## Release claim

The V1 quality claim is intentionally narrow:

> Remold V1 substantially improves reconstruction quality over single-frame/simple Kinect 360 scanning through per-device calibration, robust pose refinement, loop closure and multi-frame subpixel depth fusion. It remains hardware-limited and is not claimed to match the certified sub-millimetre accuracy of current dedicated 3D scanners.
