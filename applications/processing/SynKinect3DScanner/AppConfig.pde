class AppConfig {
  String language = "en-US";
  int uiFrameRate = 30;
  int workerJoinMs = 1500;
  String uiFontFamily = "Segoe UI";
  String uiHeadingFontFamily = "Segoe UI Semibold";
  String uiFontFallback = "Arial";

  int pointStep = 3;
  int integrationPointStep = 1;
  int minimumTrackingPoints = 220;

  float minDepthM = 0.20f;
  float maxDepthM = 4.50f;

  // Metric depth intrinsics are externalized so scanner geometry can be tuned
  // without changing source when a calibrated Kinect profile is available.
  float depthFx = 594.2143421192325f;
  float depthFy = 591.0405369687078f;
  float depthCx = 339.30780975300314f;
  float depthCy = 242.73913761751615f;
  float depthScale = 0.001f;

  float objectDepthBandM = 0.24f;
  float maxObjectDepthBandM = 0.48f;
  float depthTargetSmoothing = 0.18f;
  float depthTargetStableToleranceM = 0.12f;
  float depthTargetMaxJumpM = 0.38f;
  int depthTargetStableFrames = 3;
  int depthTargetLostFramesForReacquire = 6;
  int depthTargetMinSamples = 80;
  float depthTargetMinConfidence = 0.040f;
  int depthHistogramBinMm = 20;
  float depthRoiLeft = 0.24f;
  float depthRoiRight = 0.76f;
  float depthRoiTop = 0.20f;
  float depthRoiBottom = 0.80f;
  int depthRoiSampleStep = 2;
  float depthPreferredTargetWindowM = 0.30f;

  int depthMinValidPixels = 1200;
  float depthMinValidRatio = 0.004f;
  int depthPlausibleMinMm = 180;
  int depthPlausibleMaxMm = 6000;
  long streamStaleTimeoutMs = 1200;
  long connectionStaleTimeoutMs = 2500;
  int reconnectDelayMs = 250;

  boolean pointCloudSpatialFilter = true;
  float pointCloudNeighborToleranceM = 0.085f;

  int volumeSize = 160;
  float voxelSizeM = 0.0045f;
  float truncationM = 0.022f;
  int meshMinWeight = 2;

  int icpIterations = 7;
  int icpMinimumMatches = 50;
  float icpCellSizeM = 0.030f;
  float icpMaxDistanceM = 0.075f;
  int icpMaxSamples = 3000;
  float icpGoodRmsM = 0.045f;

  float scanFullTurnDeg = 360.0f;
  float scanCompleteDeg = 355.0f;
  float scanRotationDeadbandDeg = 0.30f;
  float scanRotationMaxStepDeg = 24.0f;
  float scanDirectionLockDeg = 5.0f;
  float scanMaxSensorTiltDriftDeg = 10.0f;
  boolean autoPauseOnFullTurn = true;

  float meshCleanupMaxEdgeM = 0.10f;
  float meshCleanupMinAreaM2 = 0.00000010f;
  float meshWeldToleranceM = 0.0015f;
  int meshSmoothIterations = 2;
  float meshSmoothLambda = 0.30f;
  int meshPolishIterations = 3;
  float meshPolishLambda = 0.34f;
  float meshPolishMu = -0.36f;
  int meshMinimumComponentTriangles = 32;
  float meshMinimumComponentRatio = 0.002f;
  boolean meshColorEnabled = true;

  // RGB/depth registration. The intrinsic/extrinsic defaults are a representative
  // Kinect v1 stereo calibration profile; every value remains externalized so a
  // per-device calibration can replace it without source changes.
  float rgbFx = 529.215081f, rgbFy = 525.563936f, rgbCx = 328.942720f, rgbCy = 267.480682f;
  float depthK1 = -0.263864f, depthK2 = 0.999668f, depthP1 = -0.000762f, depthP2 = 0.005035f, depthK3 = -1.305362f;
  float rgbK1 = 0.207966f, rgbK2 = -0.586138f, rgbP1 = 0.000722f, rgbP2 = 0.001048f, rgbK3 = 0.498570f;
  float regR00=0.9998463f, regR01=0.0012635f, regR02=-0.0174872f;
  float regR10=-0.0014779f, regR11=0.9999239f, regR12=-0.0122514f;
  float regR20=0.0174704f, regR21=0.0122753f, regR22=0.9997720f;
  float regTx=0.01998524f, regTy=-0.00074424f, regTz=-0.01091674f;
  float colorRegistrationOffsetX = 0.0f;
  float colorRegistrationOffsetY = 0.0f;
  int rgbSyncHistoryFrames = 8;
  float rgbMaxSyncSkewMs = 24.0f;
  boolean rgbOcclusionFilter = true;
  float rgbOcclusionToleranceM = 0.025f;
  boolean rgbAutoRefine = true;
  int rgbRefineEveryFrames = 8;
  int rgbRefineSearchPx = 4;
  int rgbRefineSampleStep = 10;
  int rgbRefineEdgeThresholdMm = 65;
  int rgbRefineMinimumEdges = 36;
  float rgbRefineAlpha = 0.12f;
  float rgbRefineMaxOffsetPx = 8.0f;
  int rgbExposureLowLuma = 24;
  int rgbExposureHighLuma = 235;
  int rgbTemporalColorWeightMax = 8;

  float defaultPhotoHorizontalFovDeg = 55.0f;
  float defaultPhotoDistanceM = 0.35f;
  float defaultPhotoPitchDeg = 0.0f;

  String exportBaseName = "SynKinectScan";
  String photoPoseFileName = "SynKinect_photo_poses.csv";

  void load(File file) {
    if (file == null || !file.isFile()) return;
    Properties p = new Properties();
    Reader reader = null;
    try {
      reader = new InputStreamReader(new FileInputStream(file), "UTF-8");
      p.load(reader);
      language = textValue(p, "app.language", language);
      uiFrameRate = intValue(p, "ui.frameRate", uiFrameRate, 10, 120);
      workerJoinMs = intValue(p, "lifecycle.workerJoinMs", workerJoinMs, 250, 10000);
      uiFontFamily = textValue(p, "ui.font.family", uiFontFamily);
      uiHeadingFontFamily = textValue(p, "ui.font.headingFamily", uiHeadingFontFamily);
      uiFontFallback = textValue(p, "ui.font.fallback", uiFontFallback);
      pointStep = intValue(p, "cloud.previewStep", pointStep, 1, 16);
      integrationPointStep = intValue(p, "cloud.integrationStep", integrationPointStep, 1, 16);
      minimumTrackingPoints = intValue(p, "tracking.minimumPoints", minimumTrackingPoints, 50, 20000);
      minDepthM = floatValue(p, "depth.minM", minDepthM, 0.10f, 9.0f);
      maxDepthM = floatValue(p, "depth.maxM", maxDepthM, minDepthM + 0.10f, 10.0f);
      depthFx = floatValue(p, "calibration.depth.fx", depthFx, 100.0f, 2000.0f);
      depthFy = floatValue(p, "calibration.depth.fy", depthFy, 100.0f, 2000.0f);
      depthCx = floatValue(p, "calibration.depth.cx", depthCx, 0.0f, ScannerProtocol.WIDTH);
      depthCy = floatValue(p, "calibration.depth.cy", depthCy, 0.0f, ScannerProtocol.HEIGHT);
      depthScale = floatValue(p, "calibration.depth.scale", depthScale, 0.00001f, 0.10f);
      objectDepthBandM = floatValue(p, "target.bandM", objectDepthBandM, 0.03f, 2.0f);
      maxObjectDepthBandM = floatValue(p, "target.maxBandM", maxObjectDepthBandM, objectDepthBandM, 3.0f);
      depthTargetSmoothing = floatValue(p, "target.smoothing", depthTargetSmoothing, 0.01f, 1.0f);
      depthTargetStableToleranceM = floatValue(p, "target.stableToleranceM", depthTargetStableToleranceM, 0.01f, 1.0f);
      depthTargetMaxJumpM = floatValue(p, "target.maxJumpM", depthTargetMaxJumpM, 0.05f, 3.0f);
      depthTargetStableFrames = intValue(p, "target.stableFrames", depthTargetStableFrames, 1, 60);
      depthTargetLostFramesForReacquire = intValue(p, "target.reacquireFrames", depthTargetLostFramesForReacquire, 1, 120);
      depthTargetMinSamples = intValue(p, "target.minimumSamples", depthTargetMinSamples, 16, 50000);
      depthTargetMinConfidence = floatValue(p, "target.minimumConfidence", depthTargetMinConfidence, 0.001f, 0.80f);
      depthHistogramBinMm = intValue(p, "depth.histogramBinMm", depthHistogramBinMm, 5, 200);
      depthRoiLeft = floatValue(p, "target.roi.left", depthRoiLeft, 0.0f, 0.90f);
      depthRoiRight = floatValue(p, "target.roi.right", depthRoiRight, depthRoiLeft + 0.05f, 1.0f);
      depthRoiTop = floatValue(p, "target.roi.top", depthRoiTop, 0.0f, 0.90f);
      depthRoiBottom = floatValue(p, "target.roi.bottom", depthRoiBottom, depthRoiTop + 0.05f, 1.0f);
      depthRoiSampleStep = intValue(p, "target.roi.sampleStep", depthRoiSampleStep, 1, 8);
      depthPreferredTargetWindowM = floatValue(p, "target.preferredWindowM", depthPreferredTargetWindowM, 0.05f, 3.0f);
      depthMinValidPixels = intValue(p, "depth.minimumValidPixels", depthMinValidPixels, 1, ScannerProtocol.WIDTH * ScannerProtocol.HEIGHT);
      depthMinValidRatio = floatValue(p, "depth.minimumValidRatio", depthMinValidRatio, 0.0001f, 1.0f);
      depthPlausibleMinMm = intValue(p, "depth.plausibleMinMm", depthPlausibleMinMm, 1, 9999);
      depthPlausibleMaxMm = intValue(p, "depth.plausibleMaxMm", depthPlausibleMaxMm, depthPlausibleMinMm + 1, 10000);
      streamStaleTimeoutMs = longValue(p, "transport.streamStaleMs", streamStaleTimeoutMs, 100, 30000);
      connectionStaleTimeoutMs = longValue(p, "transport.connectionStaleMs", connectionStaleTimeoutMs, streamStaleTimeoutMs, 60000);
      reconnectDelayMs = intValue(p, "transport.reconnectMs", reconnectDelayMs, 50, 5000);
      pointCloudSpatialFilter = boolValue(p, "cloud.spatialFilter", pointCloudSpatialFilter);
      pointCloudNeighborToleranceM = floatValue(p, "cloud.neighborToleranceM", pointCloudNeighborToleranceM, 0.005f, 1.0f);
      volumeSize = intValue(p, "fusion.volumeSize", volumeSize, 48, 384);
      voxelSizeM = floatValue(p, "fusion.voxelSizeM", voxelSizeM, 0.001f, 0.05f);
      truncationM = floatValue(p, "fusion.truncationM", truncationM, voxelSizeM, 0.20f);
      meshMinWeight = intValue(p, "mesh.minimumWeight", meshMinWeight, 1, 255);
      icpIterations = intValue(p, "tracking.icpIterations", icpIterations, 1, 50);
      icpMinimumMatches = intValue(p, "tracking.icpMinimumMatches", icpMinimumMatches, 12, 5000);
      icpCellSizeM = floatValue(p, "tracking.icpCellSizeM", icpCellSizeM, 0.002f, 0.50f);
      icpMaxDistanceM = floatValue(p, "tracking.icpMaxDistanceM", icpMaxDistanceM, 0.005f, 1.0f);
      icpMaxSamples = intValue(p, "tracking.icpMaxSamples", icpMaxSamples, 100, 50000);
      icpGoodRmsM = floatValue(p, "tracking.icpGoodRmsM", icpGoodRmsM, 0.001f, 0.50f);
      scanFullTurnDeg = floatValue(p, "scan.fullTurnDeg", scanFullTurnDeg, 90.0f, 720.0f);
      scanCompleteDeg = floatValue(p, "scan.completeDeg", scanCompleteDeg, 30.0f, scanFullTurnDeg);
      scanRotationDeadbandDeg = floatValue(p, "scan.rotationDeadbandDeg", scanRotationDeadbandDeg, 0.0f, 10.0f);
      scanRotationMaxStepDeg = floatValue(p, "scan.rotationMaxStepDeg", scanRotationMaxStepDeg, 1.0f, 90.0f);
      scanDirectionLockDeg = floatValue(p, "scan.directionLockDeg", scanDirectionLockDeg, 0.1f, 45.0f);
      scanMaxSensorTiltDriftDeg = floatValue(p, "scan.maxSensorTiltDriftDeg", scanMaxSensorTiltDriftDeg, 0.5f, 45.0f);
      autoPauseOnFullTurn = boolValue(p, "scan.autoPauseOnFullTurn", autoPauseOnFullTurn);
      meshCleanupMaxEdgeM = floatValue(p, "mesh.cleanupMaxEdgeM", meshCleanupMaxEdgeM, voxelSizeM, 2.0f);
      meshCleanupMinAreaM2 = floatValue(p, "mesh.cleanupMinAreaM2", meshCleanupMinAreaM2, 0.000000001f, 0.01f);
      meshWeldToleranceM = floatValue(p, "mesh.weldToleranceM", meshWeldToleranceM, 0.00001f, 0.05f);
      meshSmoothIterations = intValue(p, "mesh.smoothIterations", meshSmoothIterations, 0, 100);
      meshSmoothLambda = floatValue(p, "mesh.smoothLambda", meshSmoothLambda, 0.01f, 1.0f);
      meshPolishIterations = intValue(p, "mesh.polishIterations", meshPolishIterations, 0, 20);
      meshPolishLambda = floatValue(p, "mesh.polishLambda", meshPolishLambda, 0.01f, 0.95f);
      meshPolishMu = floatValue(p, "mesh.polishMu", meshPolishMu, -0.95f, -0.01f);
      meshMinimumComponentTriangles = intValue(p, "mesh.minimumComponentTriangles", meshMinimumComponentTriangles, 1, 1000000);
      meshMinimumComponentRatio = floatValue(p, "mesh.minimumComponentRatio", meshMinimumComponentRatio, 0.0f, 0.25f);
      meshColorEnabled = boolValue(p, "mesh.rgb.enabled", meshColorEnabled);
      rgbFx = floatValue(p, "calibration.rgb.fx", rgbFx, 100.0f, 2000.0f);
      rgbFy = floatValue(p, "calibration.rgb.fy", rgbFy, 100.0f, 2000.0f);
      rgbCx = floatValue(p, "calibration.rgb.cx", rgbCx, -1000.0f, 2000.0f);
      rgbCy = floatValue(p, "calibration.rgb.cy", rgbCy, -1000.0f, 2000.0f);
      depthK1=floatValue(p,"calibration.depth.k1",depthK1,-5.0f,5.0f); depthK2=floatValue(p,"calibration.depth.k2",depthK2,-5.0f,5.0f);
      depthP1=floatValue(p,"calibration.depth.p1",depthP1,-1.0f,1.0f); depthP2=floatValue(p,"calibration.depth.p2",depthP2,-1.0f,1.0f); depthK3=floatValue(p,"calibration.depth.k3",depthK3,-10.0f,10.0f);
      rgbK1=floatValue(p,"calibration.rgb.k1",rgbK1,-5.0f,5.0f); rgbK2=floatValue(p,"calibration.rgb.k2",rgbK2,-5.0f,5.0f);
      rgbP1=floatValue(p,"calibration.rgb.p1",rgbP1,-1.0f,1.0f); rgbP2=floatValue(p,"calibration.rgb.p2",rgbP2,-1.0f,1.0f); rgbK3=floatValue(p,"calibration.rgb.k3",rgbK3,-10.0f,10.0f);
      regR00=floatValue(p,"calibration.depthToRgb.r00",regR00,-2.0f,2.0f); regR01=floatValue(p,"calibration.depthToRgb.r01",regR01,-2.0f,2.0f); regR02=floatValue(p,"calibration.depthToRgb.r02",regR02,-2.0f,2.0f);
      regR10=floatValue(p,"calibration.depthToRgb.r10",regR10,-2.0f,2.0f); regR11=floatValue(p,"calibration.depthToRgb.r11",regR11,-2.0f,2.0f); regR12=floatValue(p,"calibration.depthToRgb.r12",regR12,-2.0f,2.0f);
      regR20=floatValue(p,"calibration.depthToRgb.r20",regR20,-2.0f,2.0f); regR21=floatValue(p,"calibration.depthToRgb.r21",regR21,-2.0f,2.0f); regR22=floatValue(p,"calibration.depthToRgb.r22",regR22,-2.0f,2.0f);
      regTx=floatValue(p,"calibration.depthToRgb.tx",regTx,-0.20f,0.20f); regTy=floatValue(p,"calibration.depthToRgb.ty",regTy,-0.20f,0.20f); regTz=floatValue(p,"calibration.depthToRgb.tz",regTz,-0.20f,0.20f);
      colorRegistrationOffsetX = floatValue(p, "mesh.rgb.offsetX", colorRegistrationOffsetX, -32.0f, 32.0f);
      colorRegistrationOffsetY = floatValue(p, "mesh.rgb.offsetY", colorRegistrationOffsetY, -32.0f, 32.0f);
      rgbSyncHistoryFrames=intValue(p,"mesh.rgb.syncHistoryFrames",rgbSyncHistoryFrames,2,60);
      rgbMaxSyncSkewMs=floatValue(p,"mesh.rgb.maxSyncSkewMs",rgbMaxSyncSkewMs,1.0f,200.0f);
      rgbOcclusionFilter=boolValue(p,"mesh.rgb.occlusionFilter",rgbOcclusionFilter);
      rgbOcclusionToleranceM=floatValue(p,"mesh.rgb.occlusionToleranceM",rgbOcclusionToleranceM,0.001f,0.25f);
      rgbAutoRefine=boolValue(p,"mesh.rgb.autoRefine",rgbAutoRefine);
      rgbRefineEveryFrames=intValue(p,"mesh.rgb.refineEveryFrames",rgbRefineEveryFrames,1,120);
      rgbRefineSearchPx=intValue(p,"mesh.rgb.refineSearchPx",rgbRefineSearchPx,0,16);
      rgbRefineSampleStep=intValue(p,"mesh.rgb.refineSampleStep",rgbRefineSampleStep,2,32);
      rgbRefineEdgeThresholdMm=intValue(p,"mesh.rgb.refineEdgeThresholdMm",rgbRefineEdgeThresholdMm,5,1000);
      rgbRefineMinimumEdges=intValue(p,"mesh.rgb.refineMinimumEdges",rgbRefineMinimumEdges,8,10000);
      rgbRefineAlpha=floatValue(p,"mesh.rgb.refineAlpha",rgbRefineAlpha,0.01f,1.0f);
      rgbRefineMaxOffsetPx=floatValue(p,"mesh.rgb.refineMaxOffsetPx",rgbRefineMaxOffsetPx,0.0f,32.0f);
      rgbExposureLowLuma=intValue(p,"mesh.rgb.exposureLowLuma",rgbExposureLowLuma,1,127);
      rgbExposureHighLuma=intValue(p,"mesh.rgb.exposureHighLuma",rgbExposureHighLuma,128,254);
      rgbTemporalColorWeightMax=intValue(p,"mesh.rgb.temporalColorWeightMax",rgbTemporalColorWeightMax,1,32);
      defaultPhotoHorizontalFovDeg = floatValue(p, "photos.defaultHorizontalFovDeg", defaultPhotoHorizontalFovDeg, 10.0f, 160.0f);
      defaultPhotoDistanceM = floatValue(p, "photos.defaultDistanceM", defaultPhotoDistanceM, 0.05f, 20.0f);
      defaultPhotoPitchDeg = floatValue(p, "photos.defaultPitchDeg", defaultPhotoPitchDeg, -89.0f, 89.0f);
      exportBaseName = textValue(p, "export.baseName", exportBaseName);
      photoPoseFileName = textValue(p, "photos.poseFile", photoPoseFileName);
    } catch (Exception e) {
      println("Configuration warning: " + e.getMessage());
    } finally {
      if (reader != null) try { reader.close(); } catch (IOException ignored) {}
    }
  }

  String textValue(Properties p, String key, String fallback) {
    String v = p.getProperty(key);
    return v == null || v.trim().length() == 0 ? fallback : v.trim();
  }
  boolean boolValue(Properties p, String key, boolean fallback) {
    String v = p.getProperty(key); if (v == null) return fallback;
    String value = v.trim();
    if ("true".equalsIgnoreCase(value) || "1".equals(value)) return true;
    if ("false".equalsIgnoreCase(value) || "0".equals(value)) return false;
    return fallback;
  }
  int intValue(Properties p, String key, int fallback, int lo, int hi) {
    try { return constrain(Integer.parseInt(textValue(p,key,String.valueOf(fallback))), lo, hi); }
    catch (Exception e) { return fallback; }
  }
  long longValue(Properties p, String key, long fallback, long lo, long hi) {
    try { long v=Long.parseLong(textValue(p,key,String.valueOf(fallback))); return Math.max(lo,Math.min(hi,v)); }
    catch (Exception e) { return fallback; }
  }
  float floatValue(Properties p, String key, float fallback, float lo, float hi) {
    try { return constrain(Float.parseFloat(textValue(p,key,String.valueOf(fallback))), lo, hi); }
    catch (Exception e) { return fallback; }
  }
}
