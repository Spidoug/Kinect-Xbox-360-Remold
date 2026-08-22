import java.io.*;
import java.nio.*;
import java.net.*;
import java.nio.channels.*;
import java.nio.file.*;
import java.util.*;
import javax.imageio.ImageIO;
import java.awt.image.BufferedImage;

PFont scannerFontRegular, scannerFontHeading;

AppConfig config;
I18n i18n;
KinectSource kinectSource;
Calibration calibration;
DepthAnalyzer depthAnalyzer;
DepthPreviewRenderer depthRenderer;
PointCloudBuilder pointCloudBuilder;
RgbDepthRegistration rgbRegistration;
IcpTracker tracker;
TSDFVolume volume;
Mesh3D mesh;
ExternalPhotoManager photos;
ScannerUI ui;
STLExporter stlExporter;
OBJExporter objExporter;
PLYExporter plyExporter;
MeshEditor meshEditor;
Mesh3D meshUndo;
ScanCoverageTracker scanCoverage;
DepthTargetTracker depthTarget;
PointCloudBuildStats cloudStats;
DepthDiagnostics latestDepthDiagnostics;

PImage depthPreview;
PImage colorPreview;
DepthFrame latestDepth;
volatile RgbSnapshot latestRgbSnapshot;

class RgbSnapshot {
  final int[] pixels; final int width,height; final long capturedMs,frameNumber,timestampUs; final PImage image;
  RgbSnapshot(PImage image,long frameNumber,long timestampUs,long capturedMs){
    this.image=image;this.pixels=image==null?null:image.pixels;this.width=image==null?0:image.width;this.height=image==null?0:image.height;
    this.frameNumber=frameNumber;this.timestampUs=timestampUs;this.capturedMs=capturedMs;
  }
}

final ArrayDeque<RgbSnapshot> rgbHistory = new ArrayDeque<RgbSnapshot>();
volatile float latestRgbDepthSkewMs = Float.NaN;

final Object reconstructionQueueLock = new Object();
final Object reconstructionStateLock = new Object();
volatile boolean reconstructionRun = false;
Thread reconstructionThread = null;
ScanWorkItem pendingScanWork = null;

volatile boolean meshBusy=false;
Thread meshThread=null;
volatile int deferredExportPrompt=0;

volatile boolean scanActive = false;
volatile boolean scanPaused = false;
volatile boolean volumeInitialized = false;
volatile float lockedObjectDepth = Float.NaN;
volatile long integratedFrames = 0;
volatile long rejectedTrackingFrames = 0;
final int EXPORT_NONE = 0, EXPORT_STL = 1, EXPORT_OBJ = 2, EXPORT_PLY = 3;
volatile int pendingExport = EXPORT_NONE;
volatile String appStatus = "";

float previewYaw = -0.45f;
float previewPitch = 0.25f;
float previewZoom = 1.0f;

void settings() { size(UiTheme.WINDOW_WIDTH, UiTheme.WINDOW_HEIGHT, P3D); smooth(4); }

void setup() {
  config = new AppConfig();
  config.load(new File(dataPath("scanner.properties")));
  frameRate(config.uiFrameRate);
  i18n = new I18n(config.language);
  initializeScannerTypography();
  surface.setTitle(i18n.tr("app.title"));
  surface.setResizable(true);
  appStatus = i18n.tr("status.connecting");

  calibration = new Calibration();
  calibration.configure(config);
  depthAnalyzer = new DepthAnalyzer();
  depthRenderer = new DepthPreviewRenderer();
  rgbRegistration = new RgbDepthRegistration(config, calibration);
  pointCloudBuilder = new PointCloudBuilder(config, rgbRegistration);
  tracker = new IcpTracker(config);
  volume = new TSDFVolume(config.volumeSize, config.voxelSizeM, config.truncationM, config.rgbTemporalColorWeightMax);
  mesh = new Mesh3D();
  photos = new ExternalPhotoManager(i18n);
  stlExporter = new STLExporter(); objExporter = new OBJExporter(); plyExporter = new PLYExporter();
  meshEditor = new MeshEditor(config);
  scanCoverage = new ScanCoverageTracker(config);
  depthTarget = new DepthTargetTracker(config, depthAnalyzer);
  cloudStats = new PointCloudBuildStats();
  ui = new ScannerUI();

  try {
    kinectSource = new KinectSource(config, calibration, i18n);
    kinectSource.start();
    appStatus = i18n.tr("status.worker_started");
  } catch (Exception e) {
    appStatus = i18n.format("status.init_failed", safeExceptionMessage(e));
    println(appStatus); e.printStackTrace();
  }
  startReconstructionWorker();
}

void draw() {
  background(UiTheme.BG);
  consumeKinectFrames();
  serviceDeferredUiActions();
  ui.draw();
}

void serviceDeferredUiActions(){
  int type=deferredExportPrompt;if(type==EXPORT_NONE)return;deferredExportPrompt=EXPORT_NONE;
  pendingExport=type;selectFolder(i18n.tr("dialog.export"),"exportFolderSelected");
}

void consumeKinectFrames() {
  if (kinectSource == null) return;
  kinectSource.updateLiveness();

  // Update RGB first. The previous implementation queued Depth before publishing
  // the RGB frame from the same UI cycle, which could color the mesh with the
  // previous video frame while the object/camera was moving.
  RgbSnapshot rgbFrame = kinectSource.pollVideoSnapshot();
  if (rgbFrame != null) {
    colorPreview = rgbFrame.image;
    latestRgbSnapshot = rgbFrame;
    rgbHistory.addLast(rgbFrame);
    while(rgbHistory.size()>config.rgbSyncHistoryFrames)rgbHistory.removeFirst();
  }

  DepthFrame depthFrame = kinectSource.pollDepth();
  if (depthFrame != null) {
    latestDepth = depthFrame;
    latestDepthDiagnostics = depthAnalyzer.analyze(depthFrame, config);
    depthPreview = depthRenderer.render(depthFrame, latestDepthDiagnostics);
    RgbSnapshot matchedRgb = nearestRgbForDepth(depthFrame.timestampUs);

    if (scanActive && !scanPaused && calibration.valid) {
      if (!depthFrame.deviceCalibrated) appStatus = i18n.tr("status.depth_uncalibrated_frame");
      else if (!latestDepthDiagnostics.healthy(config)) appStatus = i18n.format("status.depth_unhealthy",
        i18n.format("depth.summary", latestDepthDiagnostics.plausiblePixels, latestDepthDiagnostics.totalPixels, latestDepthDiagnostics.plausibleRatio * 100.0f, latestDepthDiagnostics.p05Mm, latestDepthDiagnostics.medianMm, latestDepthDiagnostics.p95Mm));
      else queueScanFrame(depthFrame, latestDepthDiagnostics, matchedRgb);
    }
  }
}

RgbSnapshot nearestRgbForDepth(long timestampUs){
  RgbSnapshot best=null;long bestSkew=Long.MAX_VALUE;
  for(RgbSnapshot rgb:rgbHistory){long skew=Math.abs(rgb.timestampUs-timestampUs);if(skew<bestSkew){bestSkew=skew;best=rgb;}}
  latestRgbDepthSkewMs=best==null?Float.NaN:bestSkew/1000.0f;
  if(best==null||latestRgbDepthSkewMs>config.rgbMaxSyncSkewMs)return null;
  return best;
}

void startScan() {
  if(meshBusy){appStatus=i18n.tr("status.mesh_busy");return;}
  if (kinectSource == null || latestDepth == null) { appStatus = i18n.tr("status.no_depth"); return; }
  if (!latestDepth.deviceCalibrated) { appStatus = i18n.tr("status.no_metric"); return; }
  if (latestDepthDiagnostics == null || !latestDepthDiagnostics.healthy(config)) { appStatus = i18n.tr("status.depth_sparse"); return; }
  scanActive = true; scanPaused = false; clearPendingScanWork(); resetReconstructionState();
  queueScanFrame(latestDepth, latestDepthDiagnostics, nearestRgbForDepth(latestDepth.timestampUs));
  appStatus = i18n.tr("status.scan_started");
}

void togglePause() {
  if (!scanActive) return;
  scanPaused = !scanPaused;
  if (scanPaused) clearPendingScanWork();
  appStatus = i18n.tr(scanPaused ? "status.scan_paused" : "status.scan_resumed");
}

void resetScan() {
  if(meshBusy){appStatus=i18n.tr("status.mesh_busy");return;}
  scanActive = false; scanPaused = false; clearPendingScanWork(); resetReconstructionState();
  appStatus = i18n.tr("status.scan_reset");
}

void resetReconstructionState() {
  synchronized (reconstructionStateLock) {
    integratedFrames = 0; rejectedTrackingFrames = 0; lockedObjectDepth = Float.NaN;
    depthTarget.reset(); cloudStats.clear(); tracker.reset(); volume.clear(); volumeInitialized = false;
    rgbHistory.clear(); latestRgbDepthSkewMs=Float.NaN;
    mesh = new Mesh3D(); meshUndo = null; scanCoverage.reset();
  }
}

void buildMesh() {
  if (!volumeInitialized) { appStatus = i18n.tr("status.no_volume"); return; }
  if (meshBusy) { appStatus = i18n.tr("status.mesh_busy"); return; }
  scanPaused = true; clearPendingScanWork();
  startMeshTask("build", null);
}

void startMeshTask(final String operation, final Mesh3D source){
  if(meshBusy)return;meshBusy=true;appStatus=i18n.tr("status.mesh_processing");
  meshThread=new Thread(new Runnable(){public void run(){
    try{
      // Barrier: let any already-running fusion frame leave the state section.
      synchronized(reconstructionStateLock){}
      Mesh3D result;
      if("build".equals(operation)){
        Mesh3D raw=volume.extractMesh(config.meshMinWeight);
        result=meshEditor.polish(raw);
      }else if("clean".equals(operation))result=meshEditor.clean(source);
      else if("smooth".equals(operation))result=meshEditor.polish(source);
      else if("center".equals(operation))result=meshEditor.center(source);
      else return;
      result.recalculateNormals();
      synchronized(reconstructionStateLock){
        if(!"build".equals(operation))meshUndo=source;else meshUndo=null;
        mesh=result;
      }
      if("build".equals(operation))appStatus=i18n.format("status.mesh_built",result.triangleCount());
      else if("clean".equals(operation))appStatus=i18n.format("status.mesh_clean",source==null?0:source.triangleCount(),result.triangleCount());
      else if("smooth".equals(operation))appStatus=i18n.format("status.mesh_polished",config.meshPolishIterations);
      else appStatus=i18n.tr("status.mesh_center");
      if("build".equals(operation)&&pendingExport!=EXPORT_NONE){deferredExportPrompt=pendingExport;pendingExport=EXPORT_NONE;}
    }catch(Exception e){appStatus=i18n.format("status.mesh_failed",safeExceptionMessage(e));println(appStatus);e.printStackTrace();}
    finally{meshBusy=false;meshThread=null;}
  }},"SynKinect3D-Mesh");meshThread.setDaemon(true);meshThread.setPriority(Thread.MIN_PRIORITY);meshThread.start();
}

void chooseExternalPhotos() { selectFolder(i18n.tr("dialog.photos"), "photoFolderSelected"); }
void photoFolderSelected(File folder) {
  if (folder == null) return;
  photos.importFolder(folder, volumeInitialized ? volume.center.copy() : new PVector(0, 0, 0.75f), config);
  appStatus = photos.status;
}

void requestExport(int type) {
  if(meshBusy){appStatus=i18n.tr("status.mesh_busy");return;}
  if (mesh == null || mesh.triangleCount() == 0) { pendingExport=type; buildMesh(); return; }
  pendingExport = type; selectFolder(i18n.tr("dialog.export"), "exportFolderSelected");
}

void exportFolderSelected(File folder) {
  if (folder == null) { pendingExport = EXPORT_NONE; return; }
  if (pendingExport == EXPORT_NONE) return;
  String type = pendingExport == EXPORT_STL ? "STL" : pendingExport == EXPORT_OBJ ? "OBJ" : "PLY";
  try {
    if (pendingExport == EXPORT_STL) stlExporter.writeBinary(mesh, new File(folder, config.exportBaseName + ".stl"));
    else if (pendingExport == EXPORT_OBJ) objExporter.write(mesh, photos, folder, config.exportBaseName);
    else if (pendingExport == EXPORT_PLY) plyExporter.write(mesh, new File(folder, config.exportBaseName + ".ply"));
    appStatus = i18n.format("status.exported", type);
  } catch (Exception e) {
    appStatus = i18n.format("status.export_failed", safeExceptionMessage(e)); println(appStatus); e.printStackTrace();
  } finally { pendingExport = EXPORT_NONE; }
}

void cleanMesh() {
  Mesh3D source=mesh;if(source==null||source.triangleCount()==0){appStatus=i18n.tr("status.mesh_required");return;}
  if(meshBusy){appStatus=i18n.tr("status.mesh_busy");return;}startMeshTask("clean",source);
}
void smoothMesh() {
  Mesh3D source=mesh;if(source==null||source.triangleCount()==0){appStatus=i18n.tr("status.mesh_required");return;}
  if(meshBusy){appStatus=i18n.tr("status.mesh_busy");return;}startMeshTask("smooth",source);
}
void centerMesh() {
  Mesh3D source=mesh;if(source==null||source.triangleCount()==0){appStatus=i18n.tr("status.mesh_required");return;}
  if(meshBusy){appStatus=i18n.tr("status.mesh_busy");return;}startMeshTask("center",source);
}
void undoMeshEdit() {
  if(meshBusy){appStatus=i18n.tr("status.mesh_busy");return;}
  Mesh3D undo=meshUndo;if(undo==null){appStatus=i18n.tr("status.no_undo");return;}
  Mesh3D current=mesh;mesh=undo;meshUndo=current;appStatus=i18n.tr("status.undo");
}

void toggleLanguage() {
  i18n.toggle(); surface.setTitle(i18n.tr("app.title")); appStatus = i18n.format("status.language", i18n.shortLanguage());
}

void dispatchUiAction(int action) {
  switch(action) {
    case ScannerUI.ACTION_START: startScan(); break; case ScannerUI.ACTION_PAUSE: togglePause(); break;
    case ScannerUI.ACTION_RESET: resetScan(); break; case ScannerUI.ACTION_MESH: buildMesh(); break;
    case ScannerUI.ACTION_PHOTOS: chooseExternalPhotos(); break; case ScannerUI.ACTION_STL: requestExport(EXPORT_STL); break;
    case ScannerUI.ACTION_OBJ: requestExport(EXPORT_OBJ); break; case ScannerUI.ACTION_PLY: requestExport(EXPORT_PLY); break;
    case ScannerUI.ACTION_CLEAN: cleanMesh(); break; case ScannerUI.ACTION_SMOOTH: smoothMesh(); break;
    case ScannerUI.ACTION_CENTER: centerMesh(); break; case ScannerUI.ACTION_UNDO: undoMeshEdit(); break;
    case ScannerUI.ACTION_LANGUAGE: toggleLanguage(); break;
    default: println("Ignored unknown UI action: " + action); break;
  }
}

void mousePressed() { if (ui.handleMousePressed(mouseX, mouseY)) return; }
void mouseDragged() {
  if (ui.isOver3D(mouseX, mouseY)) {
    previewYaw += (mouseX - pmouseX) * 0.008f; previewPitch += (mouseY - pmouseY) * 0.008f;
    previewPitch = constrain(previewPitch, -1.45f, 1.45f);
  }
}
void mouseWheel(processing.event.MouseEvent event) { previewZoom *= pow(1.08f, -event.getCount()); previewZoom = constrain(previewZoom, 0.2f, 4.0f); }
void keyPressed() {
  if (key == ' ') togglePause(); if (key == 'r' || key == 'R') resetScan(); if (key == 'm' || key == 'M') buildMesh();
  if (key == 'p' || key == 'P') chooseExternalPhotos(); if (key == 's' || key == 'S') requestExport(EXPORT_STL);
  if (key == 'o' || key == 'O') requestExport(EXPORT_OBJ); if (key == 'l' || key == 'L') requestExport(EXPORT_PLY);
  if (key == 'c' || key == 'C') cleanMesh(); if (key == 'f' || key == 'F') smoothMesh(); if (key == 'x' || key == 'X') centerMesh();
  if (key == 'u' || key == 'U') undoMeshEdit(); if (key == 'g' || key == 'G') toggleLanguage();
}
void dispose() {
  stopReconstructionWorker();
  Thread mt=meshThread;if(mt!=null){mt.interrupt();try{mt.join(config.workerJoinMs);}catch(InterruptedException ignored){Thread.currentThread().interrupt();}}
  if (kinectSource != null) kinectSource.stop();
}

class ScanWorkItem {
  final DepthFrame frame; final DepthDiagnostics diagnostics; final RgbSnapshot rgb;
  ScanWorkItem(DepthFrame frame, DepthDiagnostics diagnostics,RgbSnapshot rgb) { this.frame=frame;this.diagnostics=diagnostics;this.rgb=rgb; }
}

void startReconstructionWorker() {
  if (reconstructionRun) return; reconstructionRun = true;
  reconstructionThread = new Thread(new Runnable() { public void run() { reconstructionLoop(); } }, "SynKinect3D-Reconstruction");
  reconstructionThread.setDaemon(true); reconstructionThread.start();
}
void stopReconstructionWorker() {
  reconstructionRun = false;
  synchronized (reconstructionQueueLock) { pendingScanWork = null; reconstructionQueueLock.notifyAll(); }
  Thread t = reconstructionThread; reconstructionThread = null;
  if (t != null) try { t.join(config.workerJoinMs); } catch (InterruptedException ignored) { Thread.currentThread().interrupt(); }
}
void queueScanFrame(DepthFrame frame, DepthDiagnostics diagnostics,RgbSnapshot rgb) {
  if (!reconstructionRun || frame == null || diagnostics == null) return;
  synchronized (reconstructionQueueLock) { pendingScanWork = new ScanWorkItem(frame, diagnostics, rgb); reconstructionQueueLock.notifyAll(); }
}
void clearPendingScanWork() { synchronized (reconstructionQueueLock) { pendingScanWork = null; } }
void reconstructionLoop() {
  while (reconstructionRun) {
    ScanWorkItem work = null;
    synchronized (reconstructionQueueLock) {
      while (reconstructionRun && pendingScanWork == null) {
        try { reconstructionQueueLock.wait(100); } catch (InterruptedException ignored) { Thread.currentThread().interrupt(); return; }
      }
      if (!reconstructionRun) return; work = pendingScanWork; pendingScanWork = null;
    }
    if (work != null) processScanFrame(work.frame, work.diagnostics, work.rgb);
  }
}

void processScanFrame(DepthFrame depthFrame, DepthDiagnostics diagnostics,RgbSnapshot rgb) {
  if (!scanActive || scanPaused || depthFrame == null || diagnostics == null || !calibration.valid) return;
  if (!depthFrame.deviceCalibrated || !diagnostics.healthy(config)) return;

  synchronized (reconstructionStateLock) {
    if (!scanActive || scanPaused) return;
    scanCoverage.updateImu(depthFrame.motion);
    if (!scanCoverage.imuStable) {
      rejectedTrackingFrames++; appStatus = i18n.format("status.sensor_moved", scanCoverage.imuDeviationDeg); return;
    }

    boolean targetReady = depthTarget.update(depthFrame); lockedObjectDepth = depthTarget.depthM;
    scanCoverage.updateDetection(targetReady && !Float.isNaN(lockedObjectDepth));
    if (!targetReady || Float.isNaN(lockedObjectDepth)) { cloudStats.clear(); appStatus = i18n.tr("status.target_acquiring"); return; }

    // Tracking stays sparse for responsiveness. Once the pose is accepted, a
    // second dense cloud is built for TSDF integration. This lets longer scan
    // time contribute genuinely more spatial samples instead of repeatedly
    // integrating the same 1/18th subset of the VGA depth image.
    PointCloud trackingCloud = pointCloudBuilder.build(depthFrame, calibration, config.pointStep, lockedObjectDepth, depthTarget.bandM, cloudStats, rgb);
    if (trackingCloud.size() < config.minimumTrackingPoints) {
      scanCoverage.updateDetection(false); rejectedTrackingFrames++; appStatus = i18n.format("status.cloud_sparse", trackingCloud.size()); return;
    }
    scanCoverage.updateDetection(true);

    RigidTransform pose = tracker.track(trackingCloud, depthFrame.motion);
    if (!tracker.trackingGood) { rejectedTrackingFrames++; appStatus = i18n.format("status.icp_wait", tracker.matches); return; }

    PointCloud fusionCloud = config.integrationPointStep==config.pointStep ? trackingCloud :
      pointCloudBuilder.build(depthFrame, calibration, config.integrationPointStep, lockedObjectDepth, depthTarget.bandM, null, rgb);
    if (!volumeInitialized) { volume.resetAround(fusionCloud.centroidTransformed(pose)); volumeInitialized = true; }
    volume.integrate(fusionCloud, pose, 1); integratedFrames++; scanCoverage.update(pose, depthFrame.motion);

    if (scanCoverage.complete && config.autoPauseOnFullTurn) {
      scanPaused = true; clearPendingScanWork(); appStatus = i18n.format("status.full_turn", scanCoverage.sweepDeg);
    } else appStatus = i18n.format("status.scanning", scanCoverage.progress() * 100.0f);
  }
}

String safeExceptionMessage(Exception e) {
  String m = e.getMessage(); return (m == null || m.length() == 0) ? e.getClass().getSimpleName() : m;
}
