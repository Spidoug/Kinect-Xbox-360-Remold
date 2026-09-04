// ===== SynKinect Studio / 3D Scanner / Module.pde =====
class ScannerModuleState {
  PFont fontRegular,fontHeading;
  AppConfig config;
  I18n i18n;
  KinectSource source;
  Calibration calibration;
  DepthCalibrationStore calibrationStore;
  DepthCalibrationSession calibrationSession;
  DepthAnalyzer depthAnalyzer;
  DepthPreviewRenderer depthRenderer;
  PointCloudBuilder pointCloudBuilder;
  RgbDepthRegistration rgbRegistration;
  IcpTracker tracker;
  TSDFVolume volume;
  volatile Mesh3D mesh,meshUndo;
  ScannerUI ui;
  Scanner3DViewport viewport3D;
  STLExporter stlExporter;
  OBJExporter objExporter;
  PLYExporter plyExporter;
  MeshEditor meshEditor;
  ScanCoverageTracker scanCoverage;
  DepthTargetTracker depthTarget;
  HighQualityScanArchive hqArchive;
  HighQualityReconstructor hqReconstructor;
  PointCloudBuildStats cloudStats;
  DepthDiagnostics latestDepthDiagnostics;
  PImage depthPreview,colorPreview;
  DepthFrame latestDepth;
  volatile RgbdFramePair latestPair;
  volatile float latestRgbDepthSkewMs=Float.NaN;
  final Object reconstructionQueueLock=new Object();
  final Object reconstructionStateLock=new Object();
  volatile boolean reconstructionRun=false,reconstructionBusy=false,pauseAfterDrain=false;
  volatile boolean resetBusy=false;
  volatile long resetGeneration=0;
  Thread reconstructionThread=null;
  final ArrayDeque<ScanWorkItem> reconstructionQueue=new ArrayDeque<ScanWorkItem>();
  volatile long reconstructionQueueOverflows=0;
  volatile boolean meshBusy=false,exportBusy=false;
  volatile boolean hqBusy=false;
  volatile float hqProgress=0;
  Thread meshThread=null,activeExportThread=null;
  volatile int deferredExportPrompt=0;
  volatile boolean scanActive=false,scanPaused=false,volumeInitialized=false;
  volatile float lockedObjectDepth=Float.NaN;
  volatile long integratedFrames=0,rejectedTrackingFrames=0;
  volatile float uiProgress=0.0f,uiTargetDepthM=Float.NaN,uiIcpRmsMm=Float.NaN;
  volatile boolean uiScanComplete=false,uiTrackingGood=false;
  volatile PointCloud uiPreviewCloud=null;
  volatile long lastPreviewRenderMs=0,lastScanQueueMs=0;
  final int EXPORT_NONE=0,EXPORT_STL=1,EXPORT_OBJ=2,EXPORT_PLY=3;
  volatile int pendingExport=EXPORT_NONE;
  volatile String status="";
  float previewYaw=-0.45f,previewPitch=0.25f,previewZoom=1.0f;
}


class RgbSnapshot {
  final int[] pixels;final int width,height;final long capturedMs,frameNumber,timestampUs;final PImage image;
  final float syncResidualMs,rawSkewMs,syncToleranceMs,frameQuality;
  RgbSnapshot(int[] pixels,int width,int height,PImage image,long frameNumber,long timestampUs,long capturedMs,float syncResidualMs,float rawSkewMs,float syncToleranceMs,float frameQuality){
    this.pixels=pixels;this.width=width;this.height=height;this.image=image;this.frameNumber=frameNumber;this.timestampUs=timestampUs;this.capturedMs=capturedMs;this.syncResidualMs=syncResidualMs;this.rawSkewMs=rawSkewMs;this.syncToleranceMs=syncToleranceMs;this.frameQuality=constrain(frameQuality,0.05f,1.0f);
  }
}

void ensureRgbdCore(){
  if(studio.scannerState.config==null){studio.scannerState.config=new AppConfig();studio.scannerState.config.load(new File(dataPath("scanner.properties")));}
  if(studio.scannerState.i18n==null)studio.scannerState.i18n=new I18n(studio.currentLanguage());
  if(studio.scannerState.calibration==null){studio.scannerState.calibration=new Calibration();studio.scannerState.calibration.configure(studio.scannerState.config);}
  if(studio.scannerState.calibrationStore==null)studio.scannerState.calibrationStore=new DepthCalibrationStore();
  refreshScannerCalibrationForSelectedDevice(false);
  if(studio.scannerState.rgbRegistration==null)studio.scannerState.rgbRegistration=new RgbDepthRegistration(studio.scannerState.config,studio.scannerState.calibration);
}
void ensureScannerSource(){
  ensureRgbdCore();
  if(studio.scannerState.source==null)studio.scannerState.source=new KinectSource(studio.scannerState.config,studio.scannerState.calibration,studio.scannerState.i18n);
}


void refreshScannerCalibrationForSelectedDevice(boolean announce){
  if(studio.scannerState.calibration==null||studio.scannerState.calibrationStore==null)return;
  KinectDevice device=studio.selectedKinect();String id=device==null?"":device.id;
  boolean changed=!Objects.equals(studio.scannerState.calibration.deviceId,id);
  if(!changed&&!announce)return;
  studio.scannerState.calibrationSession=null;
  DepthCorrectionProfile profile=id.length()==0?null:studio.scannerState.calibrationStore.load(id,studio.services.scannerProtocol.WIDTH,studio.services.scannerProtocol.HEIGHT);
  studio.scannerState.calibration.selectDevice(id,profile);
  if(studio.scannerState.rgbRegistration!=null)studio.scannerState.rgbRegistration.clearPreparedFrame();
  if(announce&&studio.scannerState.i18n!=null){
    if(profile!=null&&profile.calibrated)studio.scannerState.status=studio.scannerState.i18n.format("status.calibration_loaded",profile.coverage*100.0f,profile.trainingRmsBeforeMm,profile.trainingRmsAfterMm);
    else studio.scannerState.status=studio.scannerState.i18n.tr("status.calibration_not_found");
  }
}

void toggleDepthCalibration(){
  if(studio.scannerState.calibrationSession!=null&&studio.scannerState.calibrationSession.active){
    studio.scannerState.calibrationSession.cancel();studio.scannerState.status=studio.scannerState.i18n.tr("status.calibration_cancelled");return;
  }
  if(studio.scannerState.scanActive){studio.scannerState.status=studio.scannerState.i18n.tr("status.calibration_stop_scan");return;}
  KinectDevice device=studio.selectedKinect();
  if(device==null||studio.scannerState.latestDepth==null){studio.scannerState.status=studio.scannerState.i18n.tr("status.no_depth");return;}
  studio.scannerState.calibrationSession=new DepthCalibrationSession(studio.scannerState.config,studio.scannerState.calibration,studio.scannerState.calibrationStore,device.id);
  studio.scannerState.calibrationSession.start();
  studio.scannerState.status=studio.scannerState.i18n.format("status.calibration_started",studio.scannerState.config.calibrationStations);
}

void serviceDepthCalibration(DepthFrame frame){
  DepthCalibrationSession session=studio.scannerState.calibrationSession;if(session==null||!session.active)return;
  try{
    DepthCorrectionProfile completed=session.offer(frame);
    if(completed!=null){
      studio.scannerState.calibration.selectDevice(session.deviceId,completed);
      if(studio.scannerState.rgbRegistration!=null)studio.scannerState.rgbRegistration.clearPreparedFrame();
      studio.scannerState.status=studio.scannerState.i18n.format("status.calibration_complete",completed.coverage*100.0f,completed.trainingRmsBeforeMm,completed.trainingRmsAfterMm);
      return;
    }
    if(session.waitingForDistance)studio.scannerState.status=studio.scannerState.i18n.format("status.calibration_move",session.stations.size(),studio.scannerState.config.calibrationStations,studio.scannerState.config.calibrationDistanceSeparationM);
    else studio.scannerState.status=studio.scannerState.i18n.format("status.calibration_capture",session.stations.size()+1,studio.scannerState.config.calibrationStations,session.capturedFrames,studio.scannerState.config.calibrationFramesPerStation);
  }catch(Exception e){session.cancel();studio.scannerState.status=studio.scannerState.i18n.format("status.calibration_failed",safeExceptionMessage(e));}
}

void setupScannerModule() {
  ensureScannerSource();
  initializeScannerTypography();
  studio.scannerState.status = studio.scannerState.i18n.tr("status.connecting");

  studio.scannerState.depthAnalyzer = new DepthAnalyzer(studio.scannerState.calibration);
  studio.scannerState.depthRenderer = new DepthPreviewRenderer();
  studio.scannerState.pointCloudBuilder = new PointCloudBuilder(studio.scannerState.config, studio.scannerState.rgbRegistration);
  studio.scannerState.tracker = new IcpTracker(studio.scannerState.config);
  studio.scannerState.volume = new TSDFVolume(studio.scannerState.config.volumeSize, studio.scannerState.config.voxelSizeM, studio.scannerState.config.truncationM, studio.scannerState.config.rgbTemporalColorWeightMax);
  studio.scannerState.mesh = new Mesh3D();
  studio.scannerState.stlExporter = new STLExporter(studio.scannerState.config); studio.scannerState.objExporter = new OBJExporter(studio.scannerState.config); studio.scannerState.plyExporter = new PLYExporter(studio.scannerState.config);
  studio.scannerState.meshEditor = new MeshEditor(studio.scannerState.config);
  studio.scannerState.scanCoverage = new ScanCoverageTracker(studio.scannerState.config);
  studio.scannerState.depthTarget = new DepthTargetTracker(studio.scannerState.config, studio.scannerState.depthAnalyzer);
  studio.scannerState.hqArchive = new HighQualityScanArchive(studio.scannerState.config);
  studio.scannerState.hqReconstructor = new HighQualityReconstructor(studio.scannerState.config, studio.scannerState.calibration, studio.scannerState.pointCloudBuilder, studio.scannerState.rgbRegistration);
  studio.scannerState.cloudStats = new PointCloudBuildStats();
  studio.scannerState.ui = new ScannerUI();
  studio.scannerState.viewport3D = new Scanner3DViewport();

  try {
    ensureScannerSource();
    studio.scannerState.status = studio.scannerState.i18n.tr("status.worker_started");
  } catch (Exception e) {
    studio.scannerState.status = studio.scannerState.i18n.format("status.init_failed", safeExceptionMessage(e));
    println(studio.scannerState.status); e.printStackTrace();
  }
  startReconstructionWorker();
}

void drawScannerModule() {
  background(studio.services.uiTheme.BG);
  consumeKinectFrames();
  serviceDeferredUiActions();
  studio.scannerState.ui.draw();
}

void serviceDeferredUiActions(){
  int type=studio.scannerState.deferredExportPrompt;if(type==studio.scannerState.EXPORT_NONE)return;studio.scannerState.deferredExportPrompt=studio.scannerState.EXPORT_NONE;
  studio.scannerState.pendingExport=type;selectOutput(studio.scannerState.i18n.tr("dialog.export"),"exportFileSelected",defaultExportFile(type));
}

void consumeKinectFrames() {
  if(studio.scannerState.source==null)return;
  studio.scannerState.source.updateLiveness();
  int drained=0;
  RgbdFramePair lastPair=null;
  while(drained<studio.scannerState.config.captureDrainFramesPerDraw){
    RgbdFramePair pair=studio.scannerState.source.pollRgbdPair();
    if(pair==null)break;
    drained++;
    lastPair=pair;
    studio.scannerState.latestDepth=pair.depth;
    studio.scannerState.latestPair=pair;
    studio.scannerState.latestRgbDepthSkewMs=pair.residualUs/1000.0f;
    serviceDepthCalibration(pair.depth);

    if(studio.scannerState.scanActive&&!studio.scannerState.scanPaused&&studio.scannerState.calibration.valid){
      if(!pair.depth.deviceCalibrated)studio.scannerState.status=studio.scannerState.i18n.tr("status.depth_uncalibrated_frame");
      else if(!depthFrameHealthy(pair.depth))studio.scannerState.status=studio.scannerState.i18n.tr("status.depth_sparse");
      else {
        long nowMs=System.currentTimeMillis();
        long minInterval=Math.max(1,1000/Math.max(1,studio.scannerState.config.reconstructionMaxFps));
        if(studio.scannerState.lastScanQueueMs==0||nowMs-studio.scannerState.lastScanQueueMs>=minInterval){
          studio.scannerState.lastScanQueueMs=nowMs;queueScanFrame(pair);
        }
      }
    }
  }

  // Preview work is intentionally performed once for the newest drained pair,
  // never once per queued reconstruction frame. This keeps the Processing
  // render thread responsive even when capture temporarily arrives in bursts.
  long previewNow=System.currentTimeMillis();
  if(lastPair!=null&&previewNow-studio.scannerState.lastPreviewRenderMs>=66){
    studio.scannerState.lastPreviewRenderMs=previewNow;
    studio.scannerState.latestDepthDiagnostics=studio.scannerState.depthAnalyzer.analyze(lastPair.depth,studio.scannerState.config);
    studio.scannerState.depthPreview=studio.scannerState.depthRenderer.render(lastPair.depth,studio.scannerState.latestDepthDiagnostics);
    RgbSnapshot preview=studio.scannerState.source.rgbPreviewSnapshot(lastPair);
    if(preview!=null&&preview.image!=null)studio.scannerState.colorPreview=preview.image;
    if(studio.scannerState.scanActive&&!studio.scannerState.scanPaused&&!studio.scannerState.latestDepthDiagnostics.healthy(studio.scannerState.config))
      studio.scannerState.status=studio.scannerState.i18n.format("status.depth_unhealthy",studio.scannerState.i18n.format("depth.summary",studio.scannerState.latestDepthDiagnostics.plausiblePixels,studio.scannerState.latestDepthDiagnostics.totalPixels,studio.scannerState.latestDepthDiagnostics.plausibleRatio*100.0f,studio.scannerState.latestDepthDiagnostics.p05Mm,studio.scannerState.latestDepthDiagnostics.medianMm,studio.scannerState.latestDepthDiagnostics.p95Mm));
  }
}

boolean depthFrameHealthy(DepthFrame frame){
  if(frame==null||frame.depth==null||!frame.deviceCalibrated)return false;
  int total=frame.depth.length;
  return total>0&&frame.plausibleCount>=studio.scannerState.config.depthMinValidPixels&&frame.plausibleCount/(float)total>=studio.scannerState.config.depthMinValidRatio;
}

void startScan() {
  if(studio.scannerState.meshBusy){studio.scannerState.status=studio.scannerState.i18n.tr("status.mesh_busy");return;}
  if(studio.scannerState.resetBusy)return;
  if (studio.scannerState.source == null || studio.scannerState.latestDepth == null || studio.scannerState.latestPair == null) { studio.scannerState.status = studio.scannerState.i18n.tr("status.no_depth"); return; }
  if (!studio.scannerState.latestDepth.deviceCalibrated) { studio.scannerState.status = studio.scannerState.i18n.tr("status.no_metric"); return; }
  if (studio.scannerState.latestDepthDiagnostics == null || !studio.scannerState.latestDepthDiagnostics.healthy(studio.scannerState.config)) { studio.scannerState.status = studio.scannerState.i18n.tr("status.depth_sparse"); return; }
  // Waiting for the current ICP/TSDF state section must never block Processing's
  // UI thread. Reset and first-frame queueing are completed by a generation-owned worker.
  requestScannerReconstructionReset(true);
}

void togglePause() {
  if (!studio.scannerState.scanActive) return;
  studio.scannerState.scanPaused = !studio.scannerState.scanPaused;
  if (studio.scannerState.scanPaused) clearPendingScanWork();
  studio.scannerState.status = studio.scannerState.i18n.tr(studio.scannerState.scanPaused ? "status.scan_paused" : "status.scan_resumed");
}

void resetScan() {
  if(studio.scannerState.meshBusy){studio.scannerState.status=studio.scannerState.i18n.tr("status.mesh_busy");return;}
  if(studio.scannerState.resetBusy)return;
  requestScannerReconstructionReset(false);
}

void requestScannerReconstructionReset(final boolean startAfterReset){
  ScannerModuleState s=studio.scannerState;
  s.scanActive=false;s.scanPaused=false;clearPendingScanWork();
  s.resetBusy=true;final long generation=++s.resetGeneration;
  if(!startAfterReset)s.status=s.i18n.tr("status.scan_reset");
  studio.services.workers.startLowPriority("Scanner-Reconstruction-Reset",new Runnable(){public void run(){
    try{
      resetReconstructionState();
      if(generation!=studio.scannerState.resetGeneration)return;
      if(startAfterReset){
        if(studio.activeTab!=STUDIO_TAB_SCANNER||!studio.isReady(STUDIO_TAB_SCANNER)||studio.scannerState.source==null)return;
        RgbdFramePair seed=studio.scannerState.latestPair;
        studio.scannerState.scanActive=true;studio.scannerState.scanPaused=false;studio.scannerState.lastScanQueueMs=0;
        if(seed!=null)queueScanFrame(seed);
        studio.scannerState.status=studio.scannerState.i18n.tr("status.scan_started");
      }
    }catch(Exception e){
      if(generation==studio.scannerState.resetGeneration){studio.scannerState.scanActive=false;studio.scannerState.status=safeExceptionMessage(e);}
    }finally{
      if(generation==studio.scannerState.resetGeneration)studio.scannerState.resetBusy=false;
    }
  }});
}

void cancelScannerReconstructionReset(){
  ++studio.scannerState.resetGeneration;studio.scannerState.resetBusy=false;
}

void resetReconstructionState() {
  synchronized (studio.scannerState.reconstructionStateLock) {
    studio.scannerState.integratedFrames = 0; studio.scannerState.rejectedTrackingFrames = 0; studio.scannerState.lockedObjectDepth = Float.NaN;
    studio.scannerState.depthTarget.reset(); studio.scannerState.cloudStats.clear(); studio.scannerState.tracker.reset(); studio.scannerState.volumeInitialized = false;
    if(studio.scannerState.hqArchive!=null)studio.scannerState.hqArchive.clear(); studio.scannerState.hqProgress=0;
    studio.scannerState.latestRgbDepthSkewMs=Float.NaN;
    studio.scannerState.mesh = new Mesh3D(); studio.scannerState.meshUndo = null; studio.scannerState.scanCoverage.reset();
    studio.scannerState.uiProgress=0.0f; studio.scannerState.uiTargetDepthM=Float.NaN; studio.scannerState.uiIcpRmsMm=Float.NaN;
    studio.scannerState.uiScanComplete=false; studio.scannerState.uiTrackingGood=false; studio.scannerState.uiPreviewCloud=null;
  }
}

void buildMesh() {
  if (!studio.scannerState.volumeInitialized) { studio.scannerState.status = studio.scannerState.i18n.tr("status.no_volume"); return; }
  if (studio.scannerState.meshBusy) { studio.scannerState.status = studio.scannerState.i18n.tr("status.mesh_busy"); return; }
  studio.scannerState.scanPaused = true; clearPendingScanWork();
  boolean useHq=studio.scannerState.config.hqEnabled&&studio.scannerState.hqArchive!=null&&studio.scannerState.hqArchive.size()>=studio.scannerState.config.hqMinimumKeyframes;
  startMeshTask(useHq?"build-hq":"build", null);
}

void startMeshTask(final String operation, final Mesh3D source){
  if(studio.scannerState.meshBusy)return;studio.scannerState.meshBusy=true;studio.scannerState.status=studio.scannerState.i18n.tr("status.mesh_processing");
  studio.scannerState.meshThread=studio.services.workers.startLowPriority("Scanner-Mesh",new Runnable(){public void run(){
    try{
      // Barrier: let any already-running fusion frame leave the state section.
      synchronized(studio.scannerState.reconstructionStateLock){}
      Mesh3D result;
      if("build-hq".equals(operation)){
        ArrayList<HighQualityKeyframe> frames=studio.scannerState.hqArchive.snapshot();
        result=studio.scannerState.hqReconstructor.reconstruct(frames);
        if(result==null){Mesh3D raw=studio.scannerState.volume.extractMesh(studio.scannerState.config.meshMinWeight);result=studio.scannerState.meshEditor.polish(raw);}
      }else if("build".equals(operation)){
        Mesh3D raw=studio.scannerState.volume.extractMesh(studio.scannerState.config.meshMinWeight);
        result=studio.scannerState.meshEditor.polish(raw);
      }else if("clean".equals(operation))result=studio.scannerState.meshEditor.clean(source);
      else if("smooth".equals(operation))result=studio.scannerState.meshEditor.polish(source);
      else if("center".equals(operation))result=studio.scannerState.meshEditor.center(source);
      else return;
      result.recalculateNormals();
      synchronized(studio.scannerState.reconstructionStateLock){
        if(!operation.startsWith("build"))studio.scannerState.meshUndo=source;else studio.scannerState.meshUndo=null;
        studio.scannerState.mesh=result;
      }
      if(operation.startsWith("build"))studio.scannerState.status=studio.scannerState.i18n.format("status.mesh_built",result.triangleCount());
      else if("clean".equals(operation))studio.scannerState.status=studio.scannerState.i18n.format("status.mesh_clean",source==null?0:source.triangleCount(),result.triangleCount());
      else if("smooth".equals(operation))studio.scannerState.status=studio.scannerState.i18n.format("status.mesh_polished",studio.scannerState.config.meshPolishIterations);
      else studio.scannerState.status=studio.scannerState.i18n.tr("status.mesh_center");
      if(operation.startsWith("build")&&studio.scannerState.pendingExport!=studio.scannerState.EXPORT_NONE){studio.scannerState.deferredExportPrompt=studio.scannerState.pendingExport;studio.scannerState.pendingExport=studio.scannerState.EXPORT_NONE;}
    }catch(Exception e){studio.scannerState.status=studio.scannerState.i18n.format("status.mesh_failed",safeExceptionMessage(e));println(studio.scannerState.status);e.printStackTrace();}
    finally{studio.scannerState.meshBusy=false;studio.scannerState.meshThread=null;}
  }});
}


void requestExport(int type) {
  if(studio.scannerState.meshBusy){studio.scannerState.status=studio.scannerState.i18n.tr("status.mesh_busy");return;}
  if(studio.scannerState.exportBusy){studio.scannerState.status=studio.scannerState.i18n.tr("status.export_busy");return;}
  if (studio.scannerState.mesh == null || studio.scannerState.mesh.triangleCount() == 0) { studio.scannerState.pendingExport=type; buildMesh(); return; }
  studio.scannerState.pendingExport = type; selectOutput(studio.scannerState.i18n.tr("dialog.export"), "exportFileSelected",defaultExportFile(type));
}

File defaultExportFile(int type){
  String extension=type==studio.scannerState.EXPORT_STL?".stl":type==studio.scannerState.EXPORT_OBJ?".obj":".ply";
  return new File(sketchPath(studio.scannerState.config.exportBaseName+extension));
}

File exportFileWithExtension(File selected,int type){
  String extension=type==studio.scannerState.EXPORT_STL?".stl":type==studio.scannerState.EXPORT_OBJ?".obj":".ply";
  String name=selected.getName();
  if(!name.toLowerCase(Locale.ROOT).endsWith(extension))selected=new File(selected.getParentFile(),name+extension);
  return selected;
}

void exportFileSelected(File selected) {
  if (selected == null) { studio.scannerState.pendingExport = studio.scannerState.EXPORT_NONE; return; }
  final int exportType=studio.scannerState.pendingExport; studio.scannerState.pendingExport=studio.scannerState.EXPORT_NONE;
  if(exportType==studio.scannerState.EXPORT_NONE)return;
  final File destination=exportFileWithExtension(selected,exportType);
  final Mesh3D exportMesh=studio.scannerState.mesh.deepCopy();
  final String type = exportType == studio.scannerState.EXPORT_STL ? "STL" : exportType == studio.scannerState.EXPORT_OBJ ? "OBJ" : "PLY";
  final ExternalPhotoManager exportPhotos = exportType == studio.scannerState.EXPORT_OBJ ? resolveExportPhotos(destination) : null;
  studio.scannerState.exportBusy=true; studio.scannerState.status=studio.scannerState.i18n.format("status.exporting",type);
  studio.scannerState.activeExportThread=studio.services.workers.startCritical("Scanner-Export",new Runnable(){public void run(){
    try {
      if (exportType == studio.scannerState.EXPORT_STL) studio.scannerState.stlExporter.writeBinary(exportMesh,destination);
      else if (exportType == studio.scannerState.EXPORT_OBJ) studio.scannerState.objExporter.write(exportMesh,exportPhotos,destination);
      else studio.scannerState.plyExporter.write(exportMesh,destination);
      studio.scannerState.status = studio.scannerState.i18n.format("status.exported", type);
    } catch (Exception e) {
      studio.scannerState.status = studio.scannerState.i18n.format("status.export_failed", safeExceptionMessage(e)); println(studio.scannerState.status); e.printStackTrace();
    } finally { studio.scannerState.exportBusy=false; studio.scannerState.activeExportThread=null; }
  }});
}

void cleanMesh() {
  Mesh3D source=studio.scannerState.mesh;if(source==null||source.triangleCount()==0){studio.scannerState.status=studio.scannerState.i18n.tr("status.mesh_required");return;}
  if(studio.scannerState.meshBusy){studio.scannerState.status=studio.scannerState.i18n.tr("status.mesh_busy");return;}startMeshTask("clean",source);
}
void smoothMesh() {
  Mesh3D source=studio.scannerState.mesh;if(source==null||source.triangleCount()==0){studio.scannerState.status=studio.scannerState.i18n.tr("status.mesh_required");return;}
  if(studio.scannerState.meshBusy){studio.scannerState.status=studio.scannerState.i18n.tr("status.mesh_busy");return;}startMeshTask("smooth",source);
}
void centerMesh() {
  Mesh3D source=studio.scannerState.mesh;if(source==null||source.triangleCount()==0){studio.scannerState.status=studio.scannerState.i18n.tr("status.mesh_required");return;}
  if(studio.scannerState.meshBusy){studio.scannerState.status=studio.scannerState.i18n.tr("status.mesh_busy");return;}startMeshTask("center",source);
}
void undoMeshEdit() {
  if(studio.scannerState.meshBusy){studio.scannerState.status=studio.scannerState.i18n.tr("status.mesh_busy");return;}
  Mesh3D undo=studio.scannerState.meshUndo;if(undo==null){studio.scannerState.status=studio.scannerState.i18n.tr("status.no_undo");return;}
  Mesh3D current=studio.scannerState.mesh;studio.scannerState.mesh=undo;studio.scannerState.meshUndo=current;studio.scannerState.status=studio.scannerState.i18n.tr("status.undo");
}

void dispatchUiAction(int action) {
  if(action==studio.scannerState.ui.ACTION_START)startScan();
  else if(action==studio.scannerState.ui.ACTION_PAUSE)togglePause();
  else if(action==studio.scannerState.ui.ACTION_RESET)resetScan();
  else if(action==studio.scannerState.ui.ACTION_MESH)buildMesh();
  else if(action==studio.scannerState.ui.ACTION_STL)requestExport(studio.scannerState.EXPORT_STL);
  else if(action==studio.scannerState.ui.ACTION_OBJ)requestExport(studio.scannerState.EXPORT_OBJ);
  else if(action==studio.scannerState.ui.ACTION_PLY)requestExport(studio.scannerState.EXPORT_PLY);
  else if(action==studio.scannerState.ui.ACTION_CLEAN)cleanMesh();
  else if(action==studio.scannerState.ui.ACTION_SMOOTH)smoothMesh();
  else if(action==studio.scannerState.ui.ACTION_CENTER)centerMesh();
  else if(action==studio.scannerState.ui.ACTION_UNDO)undoMeshEdit();
  else if(action==studio.scannerState.ui.ACTION_CALIBRATE)toggleDepthCalibration();
  else println("Ignored unknown UI action: " + action);
}

void scannerMousePressed() { if (studio.scannerState.ui.handleMousePressed(studio.contentMouseX(),studio.contentMouseY())) return; }
void scannerMouseDragged() {
  if (studio.scannerState.ui.isOver3D(studio.contentMouseX(),studio.contentMouseY())) {
    studio.scannerState.previewYaw += (studio.contentMouseX()-studio.contentPMouseX())*0.008f; studio.scannerState.previewPitch += (studio.contentMouseY()-studio.contentPMouseY())*0.008f;
    studio.scannerState.previewPitch = constrain(studio.scannerState.previewPitch, -1.45f, 1.45f);
  }
}
void scannerMouseWheel(processing.event.MouseEvent event) { studio.scannerState.previewZoom *= pow(1.08f, -event.getCount()); studio.scannerState.previewZoom = constrain(studio.scannerState.previewZoom, 0.2f, 4.0f); }
void scannerKeyPressed() {
  if (key == ' ') togglePause(); if (key == 'r' || key == 'R') resetScan(); if (key == 'm' || key == 'M') buildMesh();
  if (key == 's' || key == 'S') requestExport(studio.scannerState.EXPORT_STL);
  if (key == 'o' || key == 'O') requestExport(studio.scannerState.EXPORT_OBJ); if (key == 'l' || key == 'L') requestExport(studio.scannerState.EXPORT_PLY);
  if (key == 'c' || key == 'C') cleanMesh(); if (key == 'f' || key == 'F') smoothMesh(); if (key == 'x' || key == 'X') centerMesh(); if (key == 'k' || key == 'K') toggleDepthCalibration();
  if (key == 'u' || key == 'U') undoMeshEdit();
}
void disposeScannerModule() {
  // Stop native capture first, preserve already received frames, move pending
  // depth into reconstruction, then let the reconstruction worker drain its bounded window.
  if (studio.scannerState.source != null) studio.scannerState.source.stop(false);
  flushCapturedDepthForShutdown();
  studio.scannerState.pauseAfterDrain=false;
  stopReconstructionWorker();
  Thread mt=studio.scannerState.meshThread;if(mt!=null){mt.interrupt();try{mt.join(studio.scannerState.config.workerJoinMs);}catch(InterruptedException ignored){Thread.currentThread().interrupt();}}
  Thread et=studio.scannerState.activeExportThread;if(et!=null){try{et.join(studio.scannerState.config.workerJoinMs*2L);}catch(InterruptedException ignored){Thread.currentThread().interrupt();}}
  if(studio.scannerState.viewport3D!=null)studio.scannerState.viewport3D.dispose();
}

class ScanWorkItem {
  final RgbdFramePair pair;
  ScanWorkItem(RgbdFramePair pair){this.pair=pair;}
}

void startReconstructionWorker() {
  if (studio.scannerState.reconstructionRun) return; studio.scannerState.reconstructionRun = true;
  studio.scannerState.reconstructionThread = studio.services.workers.startLowPriority("Scanner-Reconstruction",new Runnable() { public void run() { reconstructionLoop(); } });
}
void stopReconstructionWorker() {
  studio.scannerState.reconstructionRun = false;
  synchronized (studio.scannerState.reconstructionQueueLock) { studio.scannerState.reconstructionQueueLock.notifyAll(); }
  Thread t = studio.scannerState.reconstructionThread; studio.scannerState.reconstructionThread = null;
  if (t != null) {
    // Do not interrupt first: a clean close must finish all queued fusion work.
    try { t.join(studio.scannerState.config.workerJoinMs*4L); } catch (InterruptedException ignored) { Thread.currentThread().interrupt(); }
    if(t.isAlive()){t.interrupt();try{t.join(studio.scannerState.config.workerJoinMs);}catch(InterruptedException ignored){Thread.currentThread().interrupt();}}
  }
}
int reconstructionQueuedFrames(){synchronized(studio.scannerState.reconstructionQueueLock){return studio.scannerState.reconstructionQueue.size();}}
boolean queueScanFrame(RgbdFramePair pair) {
  if (!studio.scannerState.reconstructionRun || pair == null || pair.depth == null) return false;
  synchronized (studio.scannerState.reconstructionQueueLock) {
    // Reconstruction is latency-sensitive. When capture outruns fusion, retain
    // the newest bounded window instead of building seconds of stale FIFO lag.
    while(studio.scannerState.reconstructionQueue.size()>=studio.scannerState.config.reconstructionQueueFrames){
      studio.scannerState.reconstructionQueue.removeFirst();
      studio.scannerState.reconstructionQueueOverflows++;
    }
    studio.scannerState.reconstructionQueue.addLast(new ScanWorkItem(pair));
    studio.scannerState.reconstructionQueueLock.notifyAll();
    return true;
  }
}
void clearPendingScanWork() { synchronized (studio.scannerState.reconstructionQueueLock) { studio.scannerState.reconstructionQueue.clear(); studio.scannerState.reconstructionQueueLock.notifyAll(); } }
void requestScannerPauseAfterDrain(){
  studio.scannerState.pauseAfterDrain=true; finishScannerPauseAfterDrainIfReady();
}
void finishScannerPauseAfterDrainIfReady(){
  if(!studio.scannerState.pauseAfterDrain||studio.scannerState.reconstructionBusy)return;
  synchronized(studio.scannerState.reconstructionQueueLock){
    if(studio.scannerState.pauseAfterDrain&&!studio.scannerState.reconstructionBusy&&studio.scannerState.reconstructionQueue.isEmpty()){studio.scannerState.scanPaused=true;studio.scannerState.pauseAfterDrain=false;studio.scannerState.reconstructionQueueLock.notifyAll();}
  }
}
void flushCapturedDepthForShutdown(){
  if(studio.scannerState.source==null||!studio.scannerState.scanActive||studio.scannerState.scanPaused)return;
  while(studio.scannerState.source.queuedRgbdPairs()>0){
    int before=studio.scannerState.source.queuedRgbdPairs();consumeKinectFrames();
    if(studio.scannerState.source.queuedRgbdPairs()>=before){try{Thread.sleep(2);}catch(InterruptedException ignored){Thread.currentThread().interrupt();break;}}
  }
}
void reconstructionLoop() {
  while (true) {
    ScanWorkItem work = null;
    synchronized (studio.scannerState.reconstructionQueueLock) {
      while (studio.scannerState.reconstructionRun && studio.scannerState.reconstructionQueue.isEmpty()) {
        try { studio.scannerState.reconstructionQueueLock.wait(100); } catch (InterruptedException ignored) { if(!studio.scannerState.reconstructionRun&&studio.scannerState.reconstructionQueue.isEmpty())return; }
      }
      if (!studio.scannerState.reconstructionRun && studio.scannerState.reconstructionQueue.isEmpty()) break;
      if(!studio.scannerState.reconstructionQueue.isEmpty()){work = studio.scannerState.reconstructionQueue.removeFirst();studio.scannerState.reconstructionBusy=true;}
    }
    if (work != null) {
      try{processScanFrame(work.pair);}
      finally{studio.scannerState.reconstructionBusy=false;finishScannerPauseAfterDrainIfReady();synchronized(studio.scannerState.reconstructionQueueLock){studio.scannerState.reconstructionQueueLock.notifyAll();}}
    }
  }
  studio.scannerState.reconstructionBusy=false;finishScannerPauseAfterDrainIfReady();
}

void processScanFrame(RgbdFramePair pair) {
  DepthFrame depthFrame=pair==null?null:pair.depth;
  if (!studio.scannerState.scanActive || studio.scannerState.scanPaused || depthFrame == null || !studio.scannerState.calibration.valid) return;
  if (!depthFrameHealthy(depthFrame)) return;

  synchronized (studio.scannerState.reconstructionStateLock) {
    if (!studio.scannerState.scanActive || studio.scannerState.scanPaused) return;
    studio.scannerState.scanCoverage.updateImu(depthFrame.motion);
    studio.scannerState.uiProgress=studio.scannerState.scanCoverage.progress();
    studio.scannerState.uiScanComplete=studio.scannerState.scanCoverage.complete;
    if (!studio.scannerState.scanCoverage.imuStable) {
      studio.scannerState.rejectedTrackingFrames++; studio.scannerState.status = studio.scannerState.i18n.format("status.sensor_moved", studio.scannerState.scanCoverage.imuDeviationDeg); return;
    }

    boolean targetReady = studio.scannerState.depthTarget.update(depthFrame); studio.scannerState.lockedObjectDepth = studio.scannerState.depthTarget.depthM;
    studio.scannerState.uiTargetDepthM=studio.scannerState.lockedObjectDepth;
    studio.scannerState.scanCoverage.updateDetection(targetReady && !Float.isNaN(studio.scannerState.lockedObjectDepth));
    if (!targetReady || Float.isNaN(studio.scannerState.lockedObjectDepth)) { studio.scannerState.cloudStats.clear(); studio.scannerState.status = studio.scannerState.i18n.tr("status.target_acquiring"); return; }

    // Tracking deliberately stays geometry-only. RGB decoding/registration is
    // deferred until the pose is accepted, so rejected frames do not pay the
    // cost of color conversion or full stereo registration.
    PointCloud trackingCloud = studio.scannerState.pointCloudBuilder.build(depthFrame, studio.scannerState.calibration, studio.scannerState.config.pointStep, studio.scannerState.lockedObjectDepth, studio.scannerState.depthTarget.bandM, studio.scannerState.cloudStats, null);
    if (trackingCloud.size() < studio.scannerState.config.minimumTrackingPoints) {
      studio.scannerState.scanCoverage.updateDetection(false); studio.scannerState.rejectedTrackingFrames++; studio.scannerState.status = studio.scannerState.i18n.format("status.cloud_sparse", trackingCloud.size()); return;
    }
    studio.scannerState.scanCoverage.updateDetection(true);

    RigidTransform pose = studio.scannerState.tracker.track(trackingCloud, depthFrame.motion);
    studio.scannerState.uiTrackingGood=studio.scannerState.tracker.trackingGood;
    studio.scannerState.uiIcpRmsMm=studio.scannerState.tracker.trackingGood?studio.scannerState.tracker.rms*1000.0f:Float.NaN;
    studio.scannerState.uiPreviewCloud=trackingCloud;
    if (!studio.scannerState.tracker.trackingGood) { studio.scannerState.rejectedTrackingFrames++; studio.scannerState.status = studio.scannerState.i18n.format("status.icp_wait", studio.scannerState.tracker.matches); return; }

    RgbSnapshot rgb=studio.scannerState.config.meshColorEnabled?studio.scannerState.source.rgbReconstructionSnapshot(pair):null;
    boolean rebuildFusion=studio.scannerState.config.integrationPointStep!=studio.scannerState.config.pointStep||rgb!=null;
    PointCloud fusionCloud=rebuildFusion
      ? studio.scannerState.pointCloudBuilder.build(depthFrame, studio.scannerState.calibration, studio.scannerState.config.integrationPointStep, studio.scannerState.lockedObjectDepth, studio.scannerState.depthTarget.bandM, null, rgb)
      : trackingCloud;
    if (!studio.scannerState.volumeInitialized) { studio.scannerState.volume.resetAround(fusionCloud.centroidTransformed(pose)); studio.scannerState.volumeInitialized = true; }
    studio.scannerState.volume.integrate(fusionCloud, pose, 1); studio.scannerState.integratedFrames++; studio.scannerState.scanCoverage.update(pose, depthFrame.motion);
    studio.scannerState.uiProgress=studio.scannerState.scanCoverage.progress();
    studio.scannerState.uiScanComplete=studio.scannerState.scanCoverage.complete;
    if(studio.scannerState.hqArchive!=null&&studio.scannerState.config.hqEnabled)
      studio.scannerState.hqArchive.offer(pair,pair.hq!=null?pair.hq:studio.scannerState.source.bestHqRgbFor(depthFrame.timestampUs),pose,studio.scannerState.lockedObjectDepth,studio.scannerState.depthTarget.bandM,studio.scannerState.scanCoverage.sweepDeg);

    if (studio.scannerState.scanCoverage.complete && studio.scannerState.config.autoPauseOnFullTurn) {
      studio.scannerState.scanPaused = true; clearPendingScanWork(); studio.scannerState.status = studio.scannerState.i18n.format("status.full_turn", studio.scannerState.scanCoverage.sweepDeg);
    } else {
      float pct=studio.scannerState.scanCoverage.progress()*100.0f;
      if(studio.scannerState.config.hqEnabled&&studio.scannerState.hqArchive!=null){int k=studio.scannerState.hqArchive.size();long mb=studio.scannerState.hqArchive.estimatedBytes()/(1024L*1024L);studio.scannerState.status=studio.scannerState.i18n.format("status.scanning_hq",pct,k,mb);}
      else studio.scannerState.status = studio.scannerState.i18n.format("status.scanning", pct);
    }
  }
}

String safeExceptionMessage(Exception e) {
  String m = e.getMessage(); return (m == null || m.length() == 0) ? e.getClass().getSimpleName() : m;
}


// ===== SynKinect Studio / 3D Scanner / AppConfig.pde =====
class AppConfig {
  int uiFrameRate = 30;
  int workerJoinMs = 1500;
  String uiFontFamily = "Segoe UI";
  String uiHeadingFontFamily = "Segoe UI Semibold";
  String uiFontFallback = "Arial";

  int pointStep = 3;
  int integrationPointStep = 2;
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
  int captureDrainFramesPerDraw = 8;
  int reconstructionQueueFrames = 3;
  int reconstructionMaxFps = 8;

  boolean pointCloudSpatialFilter = true;
  float pointCloudNeighborToleranceM = 0.085f;

  int volumeSize = 160;
  float voxelSizeM = 0.0045f;
  float truncationM = 0.022f;
  int meshMinWeight = 2;

  int icpIterations = 7;
  int icpMinimumMatches = 50;
  float icpCellSizeM = 0.075f;
  float icpMaxDistanceM = 0.075f;
  int icpMaxSamples = 3000;
  float icpGoodRmsM = 0.045f;

  // High-quality offline reconstruction. Realtime fusion remains the responsive
  // preview; final mesh generation can re-register retained keyframes and
  // re-integrate them at higher spatial resolution.
  boolean hqEnabled = true;
  int hqMaxKeyframes = 200;
  float hqKeyframeMinRotationDeg = 2.0f;
  float hqKeyframeMinTranslationM = 0.004f;
  int hqMinimumKeyframes = 12;
  int hqIntegrationStep = 1;
  int hqVolumeSize = 288;
  float hqVoxelSizeM = 0.0023f;
  float hqTruncationM = 0.009f;
  int hqMeshMinWeight = 3;
  int hqIcpIterations = 12;
  int hqLocalMapFrames = 3;
  int hqIcpMaxSamples = 12000;
  int hqIcpMinimumMatches = 220;
  float hqIcpMaxDistanceM = 0.030f;
  float hqIcpTrimFraction = 0.78f;
  float hqIcpGoodRmsM = 0.012f;
  boolean hqLoopClosure = true;
  float hqLoopClosureMaxRmsM = 0.018f;
  int hqDepthFilterRadius = 2;
  float hqDepthEdgeToleranceM = 0.028f;
  int hqHoleFillMinimumNeighbors = 12;
  boolean hqDistanceWeightedTsdf = true;
  // Multi-frame depth super-resolution. Neighboring keyframes are reprojected
  // into a supersampled anchor view after pose refinement, then fused with
  // confidence weighting, robust outlier rejection and foreground z-buffering.
  boolean hqDepthSuperResolution = true;
  int hqDepthSrScale = 2;
  int hqDepthSrWindowFrames = 5;
  int hqDepthSrAnchorStride = 2;
  float hqDepthSrMaxRotationDeg = 6.0f;
  float hqDepthSrMaxTranslationM = 0.030f;
  float hqDepthSrOcclusionToleranceM = 0.014f;
  float hqDepthSrOutlierToleranceM = 0.010f;
  int hqDepthSrMinimumViews = 2;
  int hqDepthSrMaxPoints = 420000;
  int hqMeshPolishIterations = 1;
  float hqMeshPolishLambda = 0.18f;
  float hqMeshPolishMu = -0.19f;

  boolean calibrationEnabled = true;
  int calibrationStations = 5;
  int calibrationFramesPerStation = 10;
  int calibrationMinimumStationsPerPixel = 3;
  float calibrationDistanceSeparationM = 0.16f;
  float calibrationStabilityToleranceM = 0.018f;
  float calibrationPlaneResidualMaxM = 0.030f;
  float calibrationSlopeMin = 0.92f;
  float calibrationSlopeMax = 1.08f;
  float calibrationOffsetMaxM = 0.060f;
  float calibrationNoiseFloorM = 0.0015f;
  float calibrationNoiseCeilingM = 0.030f;

  float scanFullTurnDeg = 360.0f;
  float scanCompleteDeg = 355.0f;
  float scanRotationDeadbandDeg = 0.30f;
  float scanRotationMaxStepDeg = 24.0f;
  float scanDirectionLockDeg = 5.0f;
  float scanMaxSensorTiltDriftDeg = 10.0f;
  boolean autoPauseOnFullTurn = true;

  float meshCleanupMaxEdgeM = 0.10f;
  float meshCleanupMinAreaM2 = 0.00000010f;
  float meshWeldToleranceM = 0.0010f;
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
  float rgbMaxSyncSkewMs = 24.0f;
  int rgbdQueueFrames = 8;
  int rgbdSyncHistoryFrames = 10;
  float rgbdSyncMaxResidualMs = 24.0f;
  float rgbdSyncBootstrapMaxSkewMs = 180.0f;
  float rgbdSyncOffsetAlpha = 0.08f;
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
  boolean rgbHqEnabled = false;
  int rgbHqHistoryFrames = 8;
  float rgbHqMaxSyncSkewMs = 90.0f;
  float rgbHqMinimumFrameQuality = 0.22f;
  boolean rgbPhotometricNormalize = true;
  float rgbPhotometricGainMin = 0.72f;
  float rgbPhotometricGainMax = 1.38f;
  float rgbHqSharpenAmount = 0.16f;

  float defaultPhotoHorizontalFovDeg = 55.0f;
  float defaultPhotoDistanceM = 0.35f;
  float defaultPhotoPitchDeg = 0.0f;

  String exportBaseName = "SynKinectScan";
  float exportWeldToleranceM = 0.0010f;
  float exportMaxWeldToleranceM = 0.004f;
  int exportMaxTriangles = 600000;
  int exportTextureMaxSize = 4096;
  float exportJpegQuality = 0.90f;
  String photoPoseFileName = "SynKinect_photo_poses.csv";

  void load(File file) {
    Properties p=studio.services.configRules.load(file,"scanner");
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
      depthCx = floatValue(p, "calibration.depth.cx", depthCx, 0.0f, studio.services.scannerProtocol.WIDTH);
      depthCy = floatValue(p, "calibration.depth.cy", depthCy, 0.0f, studio.services.scannerProtocol.HEIGHT);
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
      depthMinValidPixels = intValue(p, "depth.minimumValidPixels", depthMinValidPixels, 1, studio.services.scannerProtocol.WIDTH * studio.services.scannerProtocol.HEIGHT);
      depthMinValidRatio = floatValue(p, "depth.minimumValidRatio", depthMinValidRatio, 0.0001f, 1.0f);
      depthPlausibleMinMm = intValue(p, "depth.plausibleMinMm", depthPlausibleMinMm, 1, 9999);
      depthPlausibleMaxMm = intValue(p, "depth.plausibleMaxMm", depthPlausibleMaxMm, depthPlausibleMinMm + 1, 10000);
      streamStaleTimeoutMs = longValue(p, "transport.streamStaleMs", streamStaleTimeoutMs, 100, 30000);
      connectionStaleTimeoutMs = longValue(p, "transport.connectionStaleMs", connectionStaleTimeoutMs, streamStaleTimeoutMs, 60000);
      reconnectDelayMs = intValue(p, "transport.reconnectMs", reconnectDelayMs, 50, 5000);
      rgbdQueueFrames = intValue(p,"transport.rgbdQueueFrames",rgbdQueueFrames,4,120);
      rgbdSyncHistoryFrames = intValue(p,"transport.rgbdSyncHistoryFrames",rgbdSyncHistoryFrames,4,60);
      rgbdSyncMaxResidualMs = floatValue(p,"transport.rgbdSyncMaxResidualMs",rgbdSyncMaxResidualMs,1.0f,120.0f);
      rgbdSyncBootstrapMaxSkewMs = floatValue(p,"transport.rgbdSyncBootstrapMaxSkewMs",rgbdSyncBootstrapMaxSkewMs,rgbdSyncMaxResidualMs,500.0f);
      rgbdSyncOffsetAlpha = floatValue(p,"transport.rgbdSyncOffsetAlpha",rgbdSyncOffsetAlpha,0.001f,0.50f);
      captureDrainFramesPerDraw = intValue(p, "transport.drainFramesPerDraw", captureDrainFramesPerDraw, 1, 60);
      reconstructionQueueFrames = intValue(p, "fusion.queueFrames", reconstructionQueueFrames, 2, 120);
      reconstructionMaxFps = intValue(p, "fusion.maxFps", reconstructionMaxFps, 2, 30);
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
      hqEnabled = boolValue(p,"quality.enabled",hqEnabled);
      hqMaxKeyframes = intValue(p,"quality.keyframes.max",hqMaxKeyframes,12,600);
      hqKeyframeMinRotationDeg = floatValue(p,"quality.keyframes.minRotationDeg",hqKeyframeMinRotationDeg,0.1f,30.0f);
      hqKeyframeMinTranslationM = floatValue(p,"quality.keyframes.minTranslationM",hqKeyframeMinTranslationM,0.0005f,0.20f);
      hqMinimumKeyframes = intValue(p,"quality.keyframes.minimum",hqMinimumKeyframes,3,hqMaxKeyframes);
      hqIntegrationStep = intValue(p,"quality.integrationStep",hqIntegrationStep,1,4);
      hqVolumeSize = intValue(p,"quality.volumeSize",hqVolumeSize,128,384);
      hqVoxelSizeM = floatValue(p,"quality.voxelSizeM",hqVoxelSizeM,0.001f,0.010f);
      hqTruncationM = floatValue(p,"quality.truncationM",hqTruncationM,hqVoxelSizeM*2.0f,0.050f);
      hqMeshMinWeight = intValue(p,"quality.meshMinimumWeight",hqMeshMinWeight,1,255);
      hqIcpIterations = intValue(p,"quality.icpIterations",hqIcpIterations,2,40);
      hqLocalMapFrames = intValue(p,"quality.localMapFrames",hqLocalMapFrames,1,8);
      hqIcpMaxSamples = intValue(p,"quality.icpMaxSamples",hqIcpMaxSamples,1000,50000);
      hqIcpMinimumMatches = intValue(p,"quality.icpMinimumMatches",hqIcpMinimumMatches,30,10000);
      hqIcpMaxDistanceM = floatValue(p,"quality.icpMaxDistanceM",hqIcpMaxDistanceM,0.003f,0.15f);
      hqIcpTrimFraction = floatValue(p,"quality.icpTrimFraction",hqIcpTrimFraction,0.40f,1.0f);
      hqIcpGoodRmsM = floatValue(p,"quality.icpGoodRmsM",hqIcpGoodRmsM,0.001f,0.10f);
      hqLoopClosure = boolValue(p,"quality.loopClosure",hqLoopClosure);
      hqLoopClosureMaxRmsM = floatValue(p,"quality.loopClosureMaxRmsM",hqLoopClosureMaxRmsM,0.001f,0.10f);
      hqDepthFilterRadius = intValue(p,"quality.depthFilterRadius",hqDepthFilterRadius,1,3);
      hqDepthEdgeToleranceM = floatValue(p,"quality.depthEdgeToleranceM",hqDepthEdgeToleranceM,0.003f,0.10f);
      hqHoleFillMinimumNeighbors = intValue(p,"quality.holeFillMinimumNeighbors",hqHoleFillMinimumNeighbors,3,48);
      hqDistanceWeightedTsdf = boolValue(p,"quality.distanceWeightedTsdf",hqDistanceWeightedTsdf);
      hqDepthSuperResolution = boolValue(p,"quality.depthSuperResolution.enabled",hqDepthSuperResolution);
      hqDepthSrScale = intValue(p,"quality.depthSuperResolution.scale",hqDepthSrScale,1,3);
      hqDepthSrWindowFrames = intValue(p,"quality.depthSuperResolution.windowFrames",hqDepthSrWindowFrames,1,11);
      if((hqDepthSrWindowFrames&1)==0)hqDepthSrWindowFrames++;
      hqDepthSrAnchorStride = intValue(p,"quality.depthSuperResolution.anchorStride",hqDepthSrAnchorStride,1,8);
      hqDepthSrMaxRotationDeg = floatValue(p,"quality.depthSuperResolution.maxRotationDeg",hqDepthSrMaxRotationDeg,0.1f,20.0f);
      hqDepthSrMaxTranslationM = floatValue(p,"quality.depthSuperResolution.maxTranslationM",hqDepthSrMaxTranslationM,0.001f,0.15f);
      hqDepthSrOcclusionToleranceM = floatValue(p,"quality.depthSuperResolution.occlusionToleranceM",hqDepthSrOcclusionToleranceM,0.002f,0.08f);
      hqDepthSrOutlierToleranceM = floatValue(p,"quality.depthSuperResolution.outlierToleranceM",hqDepthSrOutlierToleranceM,0.001f,hqDepthSrOcclusionToleranceM);
      hqDepthSrMinimumViews = intValue(p,"quality.depthSuperResolution.minimumViews",hqDepthSrMinimumViews,1,hqDepthSrWindowFrames);
      hqDepthSrMaxPoints = intValue(p,"quality.depthSuperResolution.maxPoints",hqDepthSrMaxPoints,50000,1200000);
      hqMeshPolishIterations = intValue(p,"quality.meshPolishIterations",hqMeshPolishIterations,0,8);
      hqMeshPolishLambda = floatValue(p,"quality.meshPolishLambda",hqMeshPolishLambda,0.01f,0.60f);
      hqMeshPolishMu = floatValue(p,"quality.meshPolishMu",hqMeshPolishMu,-0.60f,-0.01f);
      calibrationEnabled = boolValue(p,"calibration.depthCorrection.enabled",calibrationEnabled);
      calibrationStations = intValue(p,"calibration.depthCorrection.stations",calibrationStations,3,12);
      calibrationFramesPerStation = intValue(p,"calibration.depthCorrection.framesPerStation",calibrationFramesPerStation,3,60);
      calibrationMinimumStationsPerPixel = intValue(p,"calibration.depthCorrection.minimumStationsPerPixel",calibrationMinimumStationsPerPixel,2,calibrationStations);
      calibrationDistanceSeparationM = floatValue(p,"calibration.depthCorrection.distanceSeparationM",calibrationDistanceSeparationM,0.05f,0.60f);
      calibrationStabilityToleranceM = floatValue(p,"calibration.depthCorrection.stabilityToleranceM",calibrationStabilityToleranceM,0.003f,0.10f);
      calibrationPlaneResidualMaxM = floatValue(p,"calibration.depthCorrection.planeResidualMaxM",calibrationPlaneResidualMaxM,0.005f,0.10f);
      calibrationSlopeMin = floatValue(p,"calibration.depthCorrection.slopeMin",calibrationSlopeMin,0.70f,1.0f);
      calibrationSlopeMax = floatValue(p,"calibration.depthCorrection.slopeMax",calibrationSlopeMax,1.0f,1.30f);
      calibrationOffsetMaxM = floatValue(p,"calibration.depthCorrection.offsetMaxM",calibrationOffsetMaxM,0.005f,0.20f);
      calibrationNoiseFloorM = floatValue(p,"calibration.depthCorrection.noiseFloorM",calibrationNoiseFloorM,0.0002f,0.02f);
      calibrationNoiseCeilingM = floatValue(p,"calibration.depthCorrection.noiseCeilingM",calibrationNoiseCeilingM,calibrationNoiseFloorM,0.10f);
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
      rgbHqEnabled=boolValue(p,"mesh.rgb.hq.enabled",rgbHqEnabled);
      rgbHqHistoryFrames=intValue(p,"mesh.rgb.hq.historyFrames",rgbHqHistoryFrames,2,24);
      rgbHqMaxSyncSkewMs=floatValue(p,"mesh.rgb.hq.maxSyncSkewMs",rgbHqMaxSyncSkewMs,10.0f,250.0f);
      rgbHqMinimumFrameQuality=floatValue(p,"mesh.rgb.hq.minimumFrameQuality",rgbHqMinimumFrameQuality,0.0f,1.0f);
      rgbPhotometricNormalize=boolValue(p,"mesh.rgb.hq.photometricNormalize",rgbPhotometricNormalize);
      rgbPhotometricGainMin=floatValue(p,"mesh.rgb.hq.gainMin",rgbPhotometricGainMin,0.30f,1.0f);
      rgbPhotometricGainMax=floatValue(p,"mesh.rgb.hq.gainMax",rgbPhotometricGainMax,1.0f,3.0f);
      rgbHqSharpenAmount=floatValue(p,"mesh.rgb.hq.sharpenAmount",rgbHqSharpenAmount,0.0f,0.60f);
      defaultPhotoHorizontalFovDeg = floatValue(p, "photos.defaultHorizontalFovDeg", defaultPhotoHorizontalFovDeg, 10.0f, 160.0f);
      defaultPhotoDistanceM = floatValue(p, "photos.defaultDistanceM", defaultPhotoDistanceM, 0.05f, 20.0f);
      defaultPhotoPitchDeg = floatValue(p, "photos.defaultPitchDeg", defaultPhotoPitchDeg, -89.0f, 89.0f);
      exportBaseName = textValue(p, "export.baseName", exportBaseName);
      exportWeldToleranceM = floatValue(p, "export.weldToleranceM", exportWeldToleranceM, 0.00001f, 0.05f);
      exportMaxWeldToleranceM = floatValue(p, "export.maxWeldToleranceM", exportMaxWeldToleranceM, exportWeldToleranceM, 0.10f);
      exportMaxTriangles = intValue(p, "export.maxTriangles", exportMaxTriangles, 1000, 5000000);
      exportTextureMaxSize = intValue(p, "export.textureMaxSize", exportTextureMaxSize, 256, 8192);
      exportJpegQuality = floatValue(p, "export.jpegQuality", exportJpegQuality, 0.30f, 1.0f);
      photoPoseFileName = textValue(p, "photos.poseFile", photoPoseFileName);
  }

  String textValue(Properties p,String key,String fallback){return studio.services.configRules.text(p,key,fallback);}
  boolean boolValue(Properties p,String key,boolean fallback){return studio.services.configRules.flag(p,key,fallback);}
  int intValue(Properties p,String key,int fallback,int lo,int hi){return studio.services.configRules.integer(p,key,fallback,lo,hi);}
  long longValue(Properties p,String key,long fallback,long lo,long hi){return studio.services.configRules.longNumber(p,key,fallback,lo,hi);}
  float floatValue(Properties p,String key,float fallback,float lo,float hi){return studio.services.configRules.decimal(p,key,fallback,lo,hi);}
}


// ===== SynKinect Studio / 3D Scanner / DepthDetection.pde =====
class DepthDiagnostics {
  int totalPixels = 0;
  int nonZeroPixels = 0;
  int plausiblePixels = 0;
  float plausibleRatio = 0;
  int minMm = 0, p05Mm = 0, medianMm = 0, p95Mm = 0, maxMm = 0;
  boolean recoveredTransport = false;
  boolean calibrated = false;

  boolean healthy(AppConfig cfg) {
    return calibrated && plausiblePixels >= cfg.depthMinValidPixels && plausibleRatio >= cfg.depthMinValidRatio;
  }

}

class DepthTargetEstimate {
  boolean valid = false;
  float depthM = Float.NaN;
  float confidence = 0;
  float spreadM = 0;
  int samples = 0;
}

class DepthAnalyzer {
  final Calibration calibration;DepthAnalyzer(Calibration calibration){this.calibration=calibration;}
  int metricMm(int index,int rawMm){return calibration!=null?calibration.correctedDepthMm(index,rawMm):rawMm;}
  DepthDiagnostics analyze(DepthFrame frame, AppConfig cfg) {
    DepthDiagnostics out = new DepthDiagnostics();
    if (frame == null || frame.depth == null || frame.depth.length == 0) return out;
    out.totalPixels = frame.depth.length;
    out.calibrated = frame.deviceCalibrated;
    out.recoveredTransport = frame.transportRecovered;

    int binMm = max(1, cfg.depthHistogramBinMm);
    int bins = max(1, ((cfg.depthPlausibleMaxMm - cfg.depthPlausibleMinMm) / binMm) + 1);
    int[] hist = new int[bins];
    int minSeen = Integer.MAX_VALUE, maxSeen = 0;

    for (int i = 0; i < frame.depth.length; i++) {
      int mm = frame.depth[i] & 0xFFFF;
      if (mm == 0) continue;mm=metricMm(i,mm);
      out.nonZeroPixels++;
      if (mm < cfg.depthPlausibleMinMm || mm > cfg.depthPlausibleMaxMm) continue;
      out.plausiblePixels++;
      minSeen = min(minSeen, mm);
      maxSeen = max(maxSeen, mm);
      int b = constrain((mm - cfg.depthPlausibleMinMm) / binMm, 0, bins - 1);
      hist[b]++;
    }

    out.plausibleRatio = out.totalPixels > 0 ? out.plausiblePixels / (float)out.totalPixels : 0;
    if (out.plausiblePixels > 0) {
      out.minMm = minSeen; out.maxMm = maxSeen;
      out.p05Mm = percentile(hist, out.plausiblePixels, 0.05f, cfg.depthPlausibleMinMm, binMm);
      out.medianMm = percentile(hist, out.plausiblePixels, 0.50f, cfg.depthPlausibleMinMm, binMm);
      out.p95Mm = percentile(hist, out.plausiblePixels, 0.95f, cfg.depthPlausibleMinMm, binMm);
    }
    return out;
  }

  int percentile(int[] hist, int total, float p, int baseMm, int binMm) {
    if (total <= 0) return 0;
    int target = max(1, ceil(total * p));
    int sum = 0;
    for (int i = 0; i < hist.length; i++) {
      sum += hist[i];
      if (sum >= target) return baseMm + i * binMm + binMm / 2;
    }
    return baseMm + (hist.length - 1) * binMm + binMm / 2;
  }

  DepthTargetEstimate estimateTarget(DepthFrame frame, AppConfig cfg, float preferredDepthM) {
    DepthTargetEstimate out = new DepthTargetEstimate();
    if (frame == null || frame.depth == null || frame.width <= 0 || frame.height <= 0) return out;

    int binMm = max(1, cfg.depthHistogramBinMm);
    int minMm = max(1, round(cfg.minDepthM * 1000.0f));
    int maxMm = max(minMm + binMm, round(cfg.maxDepthM * 1000.0f));
    int bins = max(1, ((maxMm - minMm) / binMm) + 1);
    int[] hist = new int[bins];

    int x0 = constrain(round(frame.width * cfg.depthRoiLeft), 0, frame.width - 1);
    int x1 = constrain(round(frame.width * cfg.depthRoiRight), x0 + 1, frame.width);
    int y0 = constrain(round(frame.height * cfg.depthRoiTop), 0, frame.height - 1);
    int y1 = constrain(round(frame.height * cfg.depthRoiBottom), y0 + 1, frame.height);
    int stride = max(1, cfg.depthRoiSampleStep);
    int samples = 0;

    for (int y = y0; y < y1; y += stride) {
      int row = y * frame.width;
      for (int x = x0; x < x1; x += stride) {
        int index=row+x,mm = frame.depth[index] & 0xFFFF;if(mm!=0)mm=metricMm(index,mm);
        if (mm < minMm || mm > maxMm) continue;
        hist[constrain((mm - minMm) / binMm, 0, bins - 1)]++;
        samples++;
      }
    }
    out.samples = samples;
    if (samples < cfg.depthTargetMinSamples) return out;

    int requiredMass = max(cfg.depthTargetMinSamples, ceil(samples * cfg.depthTargetMinConfidence));
    ArrayList<Integer> peaks = new ArrayList<Integer>();
    for (int b = 0; b < bins; b++) {
      int left = b > 0 ? hist[b - 1] : -1;
      int right = b + 1 < bins ? hist[b + 1] : -1;
      if (hist[b] < left || hist[b] < right) continue;
      int mass = clusterMass(hist, b, 2);
      if (mass >= requiredMass) peaks.add(b);
    }

    int peak = -1;
    if (!peaks.isEmpty()) {
      if (!Float.isNaN(preferredDepthM)) {
        float bestDistance = Float.MAX_VALUE;
        float windowMm = cfg.depthPreferredTargetWindowM * 1000.0f;
        for (int b : peaks) {
          float centerMm = minMm + b * binMm + binMm * 0.5f;
          float distance = abs(centerMm - preferredDepthM * 1000.0f);
          if (distance <= windowMm && distance < bestDistance) { bestDistance = distance; peak = b; }
        }
      }
      // Fresh acquisition favors the nearest significant foreground cluster.
      if (peak < 0) peak = peaks.get(0);
    } else {
      int bestMass = 0;
      for (int b = 0; b < bins; b++) {
        int mass = clusterMass(hist, b, 2);
        if (mass > bestMass) { bestMass = mass; peak = b; }
      }
    }
    if (peak < 0) return out;

    int lo = max(0, peak - 2), hi = min(bins - 1, peak + 2);
    long weighted = 0; int mass = 0;
    for (int b = lo; b <= hi; b++) {
      int count = hist[b];
      weighted += (long)(minMm + b * binMm + binMm / 2) * count;
      mass += count;
    }
    if (mass <= 0) return out;
    float centerMm = weighted / (float)mass;

    float variance = 0; int spreadMass = 0;
    for (int b = max(0, peak - 8); b <= min(bins - 1, peak + 8); b++) {
      int count = hist[b];
      if (count == 0) continue;
      float mm = minMm + b * binMm + binMm / 2.0f;
      float d = mm - centerMm;
      variance += d * d * count;
      spreadMass += count;
    }

    out.confidence = mass / (float)samples;
    out.depthM = centerMm * 0.001f;
    out.spreadM = spreadMass > 0 ? sqrt(variance / spreadMass) * 0.001f : 0;
    out.valid = out.confidence >= cfg.depthTargetMinConfidence && out.depthM >= cfg.minDepthM && out.depthM <= cfg.maxDepthM;
    return out;
  }

  int clusterMass(int[] hist, int center, int radius) {
    int mass = 0;
    for (int k = max(0, center - radius); k <= min(hist.length - 1, center + radius); k++) mass += hist[k];
    return mass;
  }
}

class DepthPreviewRenderer {
  PImage image;
  PImage render(DepthFrame frame, DepthDiagnostics d) {
    if (frame == null || frame.depth == null) return null;
    if(image==null||image.width!=frame.width||image.height!=frame.height)image=createImage(frame.width,frame.height,RGB);
    image.loadPixels();
    int nearMm = d != null && d.p05Mm > 0 ? d.p05Mm : 500;
    int farMm = d != null && d.p95Mm > nearMm ? d.p95Mm : nearMm + 1500;
    if (farMm - nearMm < 350) {
      int mid = d != null && d.medianMm > 0 ? d.medianMm : (nearMm + farMm) / 2;
      nearMm = max(200, mid - 250); farMm = mid + 250;
    }
    int n = min(image.pixels.length, frame.depth.length);
    float invRange=1.0f/max(1,farMm-nearMm);
    for (int i = 0; i < n; i++) {
      int mm = frame.depth[i] & 0xFFFF;
      if (mm == 0) { image.pixels[i] = 0xFF080B10; continue; }
      float t = constrain((mm - nearMm) * invRange, 0, 1);
      int gray = round(228 - 176 * t);
      image.pixels[i] = 0xFF000000|(gray<<16)|(gray<<8)|gray;
    }
    image.updatePixels();
    return image;
  }
}

class DepthTargetTracker {
  AppConfig cfg;
  DepthAnalyzer analyzer;
  float depthM = Float.NaN, bandM = 0, candidateM = Float.NaN;
  int stableFrames = 0, lostFrames = 0;
  DepthTargetEstimate latest = new DepthTargetEstimate();

  DepthTargetTracker(AppConfig cfg, DepthAnalyzer analyzer) { this.cfg = cfg; this.analyzer = analyzer; bandM = cfg.objectDepthBandM; }

  void reset() { depthM = Float.NaN; bandM = cfg.objectDepthBandM; candidateM = Float.NaN; stableFrames = 0; lostFrames = 0; latest = new DepthTargetEstimate(); }

  boolean update(DepthFrame frame) {
    latest = analyzer.estimateTarget(frame, cfg, depthM);
    if (!latest.valid || Float.isNaN(latest.depthM)) {
      lostFrames++;
      if (lostFrames >= cfg.depthTargetLostFramesForReacquire) { depthM = Float.NaN; candidateM = Float.NaN; stableFrames = 0; bandM = cfg.objectDepthBandM; return false; }
      return !Float.isNaN(depthM);
    }

    float suggestedBand = max(cfg.objectDepthBandM, latest.spreadM * 3.0f);
    bandM = constrain(lerp(bandM, suggestedBand, 0.25f), cfg.objectDepthBandM, cfg.maxObjectDepthBandM);

    if (Float.isNaN(depthM)) {
      if (Float.isNaN(candidateM) || abs(latest.depthM - candidateM) > cfg.depthTargetStableToleranceM) { candidateM = latest.depthM; stableFrames = 1; }
      else { candidateM = lerp(candidateM, latest.depthM, 0.35f); stableFrames++; }
      if (stableFrames >= cfg.depthTargetStableFrames) { depthM = candidateM; lostFrames = 0; return true; }
      return false;
    }

    if (abs(latest.depthM - depthM) <= cfg.depthTargetMaxJumpM) {
      depthM = lerp(depthM, latest.depthM, cfg.depthTargetSmoothing);
      candidateM = depthM; stableFrames = cfg.depthTargetStableFrames; lostFrames = 0; return true;
    }

    lostFrames++;
    if (Float.isNaN(candidateM) || abs(latest.depthM - candidateM) > cfg.depthTargetStableToleranceM) { candidateM = latest.depthM; stableFrames = 1; }
    else { candidateM = lerp(candidateM, latest.depthM, 0.35f); stableFrames++; }
    if (stableFrames >= cfg.depthTargetLostFramesForReacquire) { depthM = candidateM; bandM = cfg.objectDepthBandM; stableFrames = cfg.depthTargetStableFrames; lostFrames = 0; return true; }
    return false;
  }

}

class PointCloudBuildStats {
  int sourcePixels = 0, nonZero = 0, inRange = 0, accepted = 0, rejectedRange = 0, rejectedBand = 0, rejectedSpatial = 0;
  void clear() { sourcePixels = nonZero = inRange = accepted = rejectedRange = rejectedBand = rejectedSpatial = 0; }
}


// ===== SynKinect Studio / 3D Scanner / Exporters.pde =====
class ExportSpace {
  PVector position(PVector p) { return new PVector(p.x, -p.y, p.z); }
  Triangle3D triangle(Triangle3D t) {
    // Y reflection changes handedness; swapping B/C preserves outward winding.
    return new Triangle3D(position(t.a), position(t.c), position(t.b), t.ca, t.cc, t.cb);
  }
}

class VertexKey {
  final long x,y,z;
  VertexKey(PVector p,float q){x=Math.round(p.x/q);y=Math.round(p.y/q);z=Math.round(p.z/q);}
  public int hashCode(){long h=x*73856093L^y*19349663L^z*83492791L;return(int)(h^(h>>>32));}
  public boolean equals(Object o){if(!(o instanceof VertexKey))return false;VertexKey k=(VertexKey)o;return x==k.x&&y==k.y&&z==k.z;}
}
class FaceKey {
  final int a,b,c;
  FaceKey(int x,int y,int z){int[] v={x,y,z};Arrays.sort(v);a=v[0];b=v[1];c=v[2];}
  public int hashCode(){return (a*73856093)^(b*19349663)^(c*83492791);}
  public boolean equals(Object o){if(!(o instanceof FaceKey))return false;FaceKey k=(FaceKey)o;return a==k.a&&b==k.b&&c==k.c;}
}
class VertexAccum {
  float x,y,z;long r,g,b;int count;
  void add(PVector p,int colorValue){x+=p.x;y+=p.y;z+=p.z;r+=(colorValue>>16)&255;g+=(colorValue>>8)&255;b+=colorValue&255;count++;}
  PVector point(){float n=Math.max(1,count);return new PVector(x/n,y/n,z/n);}
  int colorValue(){int n=Math.max(1,count);return color((int)(r/n),(int)(g/n),(int)(b/n));}
}
class IndexedFace {
  int a,b,c;Triangle3D source;
  IndexedFace(int a,int b,int c,Triangle3D source){this.a=a;this.b=b;this.c=c;this.source=source;}
}
class IndexedMesh {
  ArrayList<PVector> vertices=new ArrayList<PVector>();
  ArrayList<Integer> colors=new ArrayList<Integer>();
  ArrayList<IndexedFace> faces=new ArrayList<IndexedFace>();
  float toleranceM;
}
class MeshCompactor {
  AppConfig cfg;ExportSpace space=new ExportSpace();
  MeshCompactor(AppConfig cfg){this.cfg=cfg;}
  IndexedMesh compact(Mesh3D source){
    float q=Math.max(0.00001f,cfg.exportWeldToleranceM);IndexedMesh best=null;
    while(true){
      IndexedMesh candidate=compactAt(source,q);best=candidate;
      if(candidate.faces.size()<=cfg.exportMaxTriangles||q>=cfg.exportMaxWeldToleranceM-0.0000001f)break;
      q=Math.min(cfg.exportMaxWeldToleranceM,q*1.35f);
    }
    return best;
  }
  IndexedMesh compactAt(Mesh3D source,float q){
    IndexedMesh out=new IndexedMesh();out.toleranceM=q;
    HashMap<VertexKey,Integer> indices=new HashMap<VertexKey,Integer>();
    ArrayList<VertexAccum> accum=new ArrayList<VertexAccum>();
    HashSet<FaceKey> seenFaces=new HashSet<FaceKey>();
    for(Triangle3D original:source.triangles){
      Triangle3D t=space.triangle(original);
      int ia=indexFor(t.a,t.ca,q,indices,accum),ib=indexFor(t.b,t.cb,q,indices,accum),ic=indexFor(t.c,t.cc,q,indices,accum);
      if(ia==ib||ib==ic||ia==ic)continue;
      FaceKey fk=new FaceKey(ia,ib,ic);if(!seenFaces.add(fk))continue;
      PVector a=accum.get(ia).point(),b=accum.get(ib).point(),c=accum.get(ic).point();
      if(PVector.sub(b,a).cross(PVector.sub(c,a)).magSq()<1e-12f)continue;
      out.faces.add(new IndexedFace(ia,ib,ic,original));
    }
    for(VertexAccum v:accum){out.vertices.add(v.point());out.colors.add(v.colorValue());}
    return out;
  }
  int indexFor(PVector p,int c,float q,HashMap<VertexKey,Integer> indices,ArrayList<VertexAccum> accum){
    VertexKey key=new VertexKey(p,q);Integer idx=indices.get(key);
    if(idx==null){idx=accum.size();indices.put(key,idx);accum.add(new VertexAccum());}
    accum.get(idx).add(p,c);return idx;
  }
}

class STLExporter {
  AppConfig cfg;MeshCompactor compactor;
  STLExporter(AppConfig cfg){this.cfg=cfg;compactor=new MeshCompactor(cfg);}
  void writeBinary(Mesh3D mesh, File file) throws Exception {
    IndexedMesh indexed=compactor.compact(mesh);
    File parent=file.getParentFile();if(parent!=null&&!parent.exists()&&!parent.mkdirs())throw new IOException("Could not create export folder");
    DataOutputStream out = new DataOutputStream(new BufferedOutputStream(new FileOutputStream(file)));
    try {
      byte[] header = new byte[80]; String text="SynKinect Studio compact STL; weld="+indexed.toleranceM+"m";byte[] title=text.getBytes("US-ASCII");
      System.arraycopy(title,0,header,0,Math.min(title.length,80)); out.write(header); writeLEInt(out,indexed.faces.size());
      for(IndexedFace f:indexed.faces){PVector a=indexed.vertices.get(f.a),b=indexed.vertices.get(f.b),c=indexed.vertices.get(f.c);PVector n=PVector.sub(b,a).cross(PVector.sub(c,a));if(n.magSq()>1e-12f)n.normalize();writeVec(out,n,false);writeVec(out,a,true);writeVec(out,b,true);writeVec(out,c,true);writeLEShort(out,0);}
    } finally { out.close(); }
  }
  void writeVec(DataOutputStream out,PVector v,boolean millimeters)throws Exception{float scale=millimeters?1000.0f:1.0f;writeLEFloat(out,v.x*scale);writeLEFloat(out,v.y*scale);writeLEFloat(out,v.z*scale);}
  void writeLEFloat(DataOutputStream out,float value)throws Exception{writeLEInt(out,Float.floatToIntBits(value));}
  void writeLEInt(DataOutputStream out,int value)throws Exception{out.writeByte(value&255);out.writeByte((value>>8)&255);out.writeByte((value>>16)&255);out.writeByte((value>>24)&255);}
  void writeLEShort(DataOutputStream out,int value)throws Exception{out.writeByte(value&255);out.writeByte((value>>8)&255);}
}

class OBJExporter {
  AppConfig cfg;MeshCompactor compactor;
  OBJExporter(AppConfig cfg){this.cfg=cfg;compactor=new MeshCompactor(cfg);}
  void write(Mesh3D mesh,ExternalPhotoManager photos,File obj)throws Exception{
    IndexedMesh indexed=compactor.compact(mesh);File folder=obj.getParentFile();if(folder==null)folder=new File(".");
    if(!folder.exists()&&!folder.mkdirs())throw new IOException("Could not create export folder: "+folder.getAbsolutePath());
    String base=stripExtension(obj.getName());boolean textured=photos!=null&&!photos.cameras.isEmpty();File mtl=new File(folder,base+".mtl"),texDir=new File(folder,base+"_textures");
    if(textured){if(!texDir.exists()&&!texDir.mkdirs())throw new IOException("Could not create texture folder: "+texDir.getAbsolutePath());writeMaterials(photos,texDir,mtl);}
    writeObject(indexed,photos,obj,textured?mtl:null);
  }
  String stripExtension(String name){int p=name.lastIndexOf('.');return p<=0?name:name.substring(0,p);}
  void writeMaterials(ExternalPhotoManager photos,File texDir,File mtl)throws Exception{
    PrintWriter out=new PrintWriter(new BufferedWriter(new FileWriter(mtl)));
    try{
      for(int i=0;i<photos.cameras.size();i++){
        PhotoCamera camera=photos.cameras.get(i);String texName=String.format(Locale.ROOT,"photo_%03d.jpg",i);File target=new File(texDir,texName);
        writeCompressedJpeg(camera.file,target,cfg.exportTextureMaxSize,cfg.exportJpegQuality);
        out.println("newmtl photo_"+i);out.println("Ka 1 1 1");out.println("Kd 1 1 1");out.println("map_Kd "+texDir.getName()+"/"+texName);out.println();
      }
      out.println("newmtl untextured");out.println("Kd 0.75 0.75 0.75");out.println();
    }finally{out.close();}
  }
  void writeCompressedJpeg(File source,File target,int maxSize,float quality)throws Exception{
    BufferedImage input=ImageIO.read(source);if(input==null)throw new IOException("Unsupported image: "+source.getName());
    int w=input.getWidth(),h=input.getHeight();float scale=Math.min(1.0f,maxSize/(float)Math.max(w,h));int nw=Math.max(1,Math.round(w*scale)),nh=Math.max(1,Math.round(h*scale));
    BufferedImage rgb=new BufferedImage(nw,nh,BufferedImage.TYPE_INT_RGB);Graphics2D g=rgb.createGraphics();
    try{g.setRenderingHint(RenderingHints.KEY_INTERPOLATION,RenderingHints.VALUE_INTERPOLATION_BILINEAR);g.drawImage(input,0,0,nw,nh,null);}finally{g.dispose();}
    Iterator<ImageWriter> writers=ImageIO.getImageWritersByFormatName("jpg");if(!writers.hasNext())throw new IOException("JPEG writer unavailable");ImageWriter writer=writers.next();
    ImageOutputStream ios=ImageIO.createImageOutputStream(target);try{writer.setOutput(ios);ImageWriteParam param=writer.getDefaultWriteParam();if(param.canWriteCompressed()){param.setCompressionMode(ImageWriteParam.MODE_EXPLICIT);param.setCompressionQuality(quality);}writer.write(null,new IIOImage(rgb,null,null),param);}finally{try{ios.close();}finally{writer.dispose();}}
  }
  void writeObject(IndexedMesh mesh,ExternalPhotoManager photos,File obj,File mtl)throws Exception{
    PrintWriter out=new PrintWriter(new BufferedWriter(new FileWriter(obj)));
    try{
      if(mtl!=null)out.println("mtllib "+mtl.getName());
      for(int i=0;i<mesh.vertices.size();i++)writeObjVertex(out,mesh.vertices.get(i),mesh.colors.get(i));
      int vtIndex=1;
      for(IndexedFace f:mesh.faces){
        int camIndex=photos==null?-1:photos.bestCamera(f.source);
        if(mtl!=null&&camIndex>=0){
          PhotoCamera camera=photos.cameras.get(camIndex);PVector ua=camera.project(f.source.a),ub=camera.project(f.source.c),uc=camera.project(f.source.b);
          if(ua!=null&&ub!=null&&uc!=null){
            out.println("vt "+ua.x+" "+(1-ua.y));out.println("vt "+ub.x+" "+(1-ub.y));out.println("vt "+uc.x+" "+(1-uc.y));out.println("usemtl photo_"+camIndex);
            out.println("f "+(f.a+1)+"/"+vtIndex+" "+(f.b+1)+"/"+(vtIndex+1)+" "+(f.c+1)+"/"+(vtIndex+2));vtIndex+=3;continue;
          }
        }
        if(mtl!=null)out.println("usemtl untextured");out.println("f "+(f.a+1)+" "+(f.b+1)+" "+(f.c+1));
      }
    }finally{out.close();}
  }
  void writeObjVertex(PrintWriter out,PVector p,int c){float r=((c>>16)&255)/255.0f,g=((c>>8)&255)/255.0f,b=(c&255)/255.0f;out.println("v "+p.x+" "+p.y+" "+p.z+" "+r+" "+g+" "+b);}
}

class PLYExporter {
  AppConfig cfg;MeshCompactor compactor;
  PLYExporter(AppConfig cfg){this.cfg=cfg;compactor=new MeshCompactor(cfg);}
  void write(Mesh3D mesh,File file)throws Exception{
    IndexedMesh indexed=compactor.compact(mesh);File parent=file.getParentFile();if(parent!=null&&!parent.exists()&&!parent.mkdirs())throw new IOException("Could not create export folder");
    BufferedOutputStream raw=new BufferedOutputStream(new FileOutputStream(file));DataOutputStream out=new DataOutputStream(raw);
    try{
      String header="ply\nformat binary_little_endian 1.0\ncomment SynKinect Studio compact indexed mesh\nelement vertex "+indexed.vertices.size()+"\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nelement face "+indexed.faces.size()+"\nproperty list uchar int vertex_indices\nend_header\n";
      out.write(header.getBytes("US-ASCII"));
      for(int i=0;i<indexed.vertices.size();i++){PVector v=indexed.vertices.get(i);int c=indexed.colors.get(i);writeLEFloat(out,v.x);writeLEFloat(out,v.y);writeLEFloat(out,v.z);out.writeByte((c>>16)&255);out.writeByte((c>>8)&255);out.writeByte(c&255);}
      for(IndexedFace f:indexed.faces){out.writeByte(3);writeLEInt(out,f.a);writeLEInt(out,f.b);writeLEInt(out,f.c);}
    }finally{out.close();}
  }
  void writeLEFloat(DataOutputStream out,float value)throws Exception{writeLEInt(out,Float.floatToIntBits(value));}
  void writeLEInt(DataOutputStream out,int value)throws Exception{out.writeByte(value&255);out.writeByte((value>>8)&255);out.writeByte((value>>16)&255);out.writeByte((value>>24)&255);}
}


// ===== SynKinect Studio / 3D Scanner / ExternalPhotos.pde =====
class PhotoCamera {
  int imageWidth,imageHeight; File file; PVector position=new PVector(),target=new PVector(); float horizontalFovRad;
  PVector forward=new PVector(),right=new PVector(),up=new PVector();
  PhotoCamera(int imageWidth,int imageHeight,File file){this.imageWidth=imageWidth;this.imageHeight=imageHeight;this.file=file;}
  void setOrbit(PVector target,float yaw,float pitch,float distance,float hfov){
    this.target.set(target);horizontalFovRad=hfov;
    position.set(target.x+distance*cos(pitch)*sin(yaw),target.y-distance*sin(pitch),target.z+distance*cos(pitch)*cos(yaw));updateBasis();
  }
  void updateBasis(){
    forward=PVector.sub(target,position).normalize();PVector worldUp=new PVector(0,-1,0);right=forward.cross(worldUp);
    if(right.magSq()<1e-8f)right=new PVector(1,0,0);right.normalize();up=right.cross(forward).normalize();
  }
  PVector project(PVector world){
    PVector rel=PVector.sub(world,position);float z=rel.dot(forward);if(z<=0.001f)return null;
    float x=rel.dot(right),y=rel.dot(up),aspect=(float)imageWidth/imageHeight,nx=x/(z*tan(horizontalFovRad*0.5f));
    float verticalFov=2*atan(tan(horizontalFovRad*0.5f)/aspect),ny=y/(z*tan(verticalFov*0.5f));
    float u=0.5f+0.5f*nx,v=0.5f-0.5f*ny;if(u<0||u>1||v<0||v>1)return null;return new PVector(u,v,z);
  }
  float score(Triangle3D t){PVector toCamera=PVector.sub(position,t.center()).normalize();float facing=t.n.dot(toCamera);if(facing<=0.05f)return-1;return project(t.a)==null||project(t.b)==null||project(t.c)==null?-1:facing;}
}

class ExternalPhotoManager {
  ArrayList<PhotoCamera> cameras=new ArrayList<PhotoCamera>(); I18n i18n; String status;
  ExternalPhotoManager(I18n i18n){this.i18n=i18n;status=i18n.tr("photos.none");}

  void importFolder(File folder,PVector target,AppConfig cfg){
    cameras.clear();File[] files=folder.listFiles();if(files==null){status=i18n.tr("photos.empty");return;}
    ArrayList<File> images=new ArrayList<File>();
    for(File f:files){String n=f.getName().toLowerCase(Locale.ROOT);if(n.endsWith(".jpg")||n.endsWith(".jpeg")||n.endsWith(".png"))images.add(f);}
    Collections.sort(images,new Comparator<File>(){public int compare(File a,File b){return a.getName().compareToIgnoreCase(b.getName());}});
    HashMap<String,float[]> saved=readPoseFile(new File(folder,cfg.photoPoseFileName)); int count=images.size();
    for(int i=0;i<count;i++){
      int[] dims=readImageSize(images.get(i));if(dims==null)continue;PhotoCamera cam=new PhotoCamera(dims[0],dims[1],images.get(i));float[] pose=saved.get(images.get(i).getName());
      if(pose!=null&&pose.length>=7){cam.position.set(pose[0],pose[1],pose[2]);cam.target.set(pose[3],pose[4],pose[5]);cam.horizontalFovRad=radians(pose[6]);cam.updateBasis();}
      else{float yaw=TWO_PI*i/max(1,count);cam.setOrbit(target,yaw,radians(cfg.defaultPhotoPitchDeg),cfg.defaultPhotoDistanceM,radians(cfg.defaultPhotoHorizontalFovDeg));}
      cameras.add(cam);
    }
    status=cameras.size()==0?i18n.tr("photos.empty"):i18n.format("photos.loaded",cameras.size());if(!cameras.isEmpty())writePoseTemplate(folder,cfg.photoPoseFileName);
  }

  int[] readImageSize(File file){
    BufferedImage image=null;try{image=ImageIO.read(file);if(image==null)return null;return new int[]{image.getWidth(),image.getHeight()};}
    catch(Exception e){println("Photo read warning: "+file.getName()+" - "+e.getMessage());return null;}finally{if(image!=null)image.flush();}
  }

  HashMap<String,float[]> readPoseFile(File file){
    HashMap<String,float[]> result=new HashMap<String,float[]>();if(!file.exists())return result;
    try{BufferedReader r=new BufferedReader(new FileReader(file));try{r.readLine();String line;while((line=r.readLine())!=null){
      ArrayList<String> p=parseCsvLine(line);if(p.size()<9)continue;try{float[] v={Float.parseFloat(p.get(2)),Float.parseFloat(p.get(3)),Float.parseFloat(p.get(4)),Float.parseFloat(p.get(5)),Float.parseFloat(p.get(6)),Float.parseFloat(p.get(7)),Float.parseFloat(p.get(8))};result.put(p.get(0),v);}catch(NumberFormatException ignored){}
    }}finally{r.close();}}catch(Exception e){println("Photo pose read warning: "+e.getMessage());}return result;
  }

  ArrayList<String> parseCsvLine(String line){
    ArrayList<String> out=new ArrayList<String>();StringBuilder field=new StringBuilder();boolean quoted=false;
    for(int i=0;i<line.length();i++){char ch=line.charAt(i);if(ch=='\"'){if(quoted&&i+1<line.length()&&line.charAt(i+1)=='\"'){field.append('\"');i++;}else quoted=!quoted;}else if(ch==','&&!quoted){out.add(field.toString());field.setLength(0);}else field.append(ch);}out.add(field.toString());return out;
  }
  String csv(String value){if(value==null)return"";return "\""+value.replace("\"","\"\"")+"\"";}

  void writePoseTemplate(File folder,String fileName){
    try{PrintWriter w=new PrintWriter(new File(folder,fileName));try{w.println("file,index,px,py,pz,targetX,targetY,targetZ,horizontalFovDeg");for(int i=0;i<cameras.size();i++){PhotoCamera c=cameras.get(i);w.println(csv(c.file.getName())+","+i+","+c.position.x+","+c.position.y+","+c.position.z+","+c.target.x+","+c.target.y+","+c.target.z+","+degrees(c.horizontalFovRad));}}finally{w.close();}}
    catch(Exception e){println("Photo pose write warning: "+e.getMessage());}
  }
  int bestCamera(Triangle3D t){int best=-1;float score=-1;for(int i=0;i<cameras.size();i++){float s=cameras.get(i).score(t);if(s>score){score=s;best=i;}}return best;}
}


// ===== SynKinect Studio / 3D Scanner / FrameTypes.pde =====
class MotionSample {
  final int FLAG_ACCEL_VALID = 1;
  final int FLAG_TILT_VALID = 2;
  final float COUNTS_PER_G = 819.0f;
  final float GRAVITY_MPS2 = 9.80665f;

  int flags = 0;
  int accelX = 0, accelY = 0, accelZ = 0;
  int tiltTenths = 0;
  long timestampMs = 0;

  boolean accelValid(){ return (flags & FLAG_ACCEL_VALID) != 0; }
  boolean tiltValid(){ return (flags & FLAG_TILT_VALID) != 0; }

  PVector accelerationMps2(){
    float k = GRAVITY_MPS2 / COUNTS_PER_G;
    return new PVector(accelX * k, accelY * k, accelZ * k);
  }

  PVector gravityUnit(){
    if (!accelValid()) return null;
    PVector g = new PVector(accelX, accelY, accelZ);
    float m = g.mag();
    if (m < 1e-4f) return null;
    g.div(m);
    return g;
  }

  boolean gravityReliable(){
    if (!accelValid()) return false;
    float counts = sqrt((float)accelX * accelX + (float)accelY * accelY + (float)accelZ * accelZ);
    return counts > COUNTS_PER_G * 0.72f && counts < COUNTS_PER_G * 1.28f;
  }
}


// ===== SynKinect Studio / 3D Scanner / Per-device depth calibration =====
class PlaneModel {
  float ax=0,by=0,c=Float.NaN,rms=Float.POSITIVE_INFINITY;int samples=0;
  boolean valid(){return Float.isFinite(c)&&samples>64;}
  float depthAt(float nx,float ny){return ax*nx+by*ny+c;}
}

class CalibrationStation {
  final int width,height;final float[] meanM,sigmaM;final PlaneModel plane;final float centerDepthM;
  CalibrationStation(int width,int height,float[] meanM,float[] sigmaM,PlaneModel plane,float centerDepthM){this.width=width;this.height=height;this.meanM=meanM;this.sigmaM=sigmaM;this.plane=plane;this.centerDepthM=centerDepthM;}
}

class DepthCorrectionProfile {
  final String deviceId;final int width,height;final float[] scale,offsetM,noiseM;
  boolean calibrated=false;float coverage=0,trainingRmsBeforeMm=Float.NaN,trainingRmsAfterMm=Float.NaN;long createdEpochMs=System.currentTimeMillis();
  DepthCorrectionProfile(String deviceId,int width,int height){this.deviceId=deviceId==null?"":deviceId;this.width=width;this.height=height;int n=width*height;scale=new float[n];offsetM=new float[n];noiseM=new float[n];Arrays.fill(scale,1.0f);Arrays.fill(noiseM,0.004f);}
  int correctMm(int index,int rawMm){if(rawMm<=0||index<0||index>=scale.length)return rawMm;float m=rawMm*0.001f*scale[index]+offsetM[index];return constrain(round(m*1000.0f),1,10000);}
  float noiseAt(int index,float depthM,AppConfig cfg){float empirical=(index>=0&&index<noiseM.length)?noiseM[index]:cfg.calibrationNoiseFloorM;float z=max(0.35f,depthM);float range=cfg.calibrationNoiseFloorM*(0.55f+0.45f*z*z);return constrain(max(empirical,range),cfg.calibrationNoiseFloorM,cfg.calibrationNoiseCeilingM);}
  float confidenceAt(int index,float depthM,AppConfig cfg){float sigma=noiseAt(index,depthM,cfg);return constrain(cfg.calibrationNoiseFloorM/max(cfg.calibrationNoiseFloorM,sigma),0.20f,1.0f);}

  DepthCorrectionProfile fit(ArrayList<CalibrationStation> stations,Calibration calibration,AppConfig cfg){
    if(stations==null||stations.size()<3)throw new IllegalArgumentException("at least three calibration stations are required");
    int w=width,h=height,n=w*h;DepthCorrectionProfile out=this;int calibratedPixels=0;double before2=0,after2=0;long residualN=0;
    float[] xs=new float[stations.size()],ys=new float[stations.size()],ns=new float[stations.size()];
    for(int idx=0;idx<n;idx++){
      int u=idx%w,v=idx/w;float nx=(u-calibration.cx)/calibration.fx,ny=(v-calibration.cy)/calibration.fy;int count=0;float noiseSum=0;
      for(CalibrationStation st:stations){float measured=st.meanM[idx];if(measured<=0||!st.plane.valid())continue;float target=st.plane.depthAt(nx,ny);if(target<=0)continue;xs[count]=measured;ys[count]=target;ns[count]=st.sigmaM[idx];noiseSum+=st.sigmaM[idx];count++;}
      if(count>=cfg.calibrationMinimumStationsPerPixel){
        double sx=0,sy=0,sxx=0,sxy=0;for(int i=0;i<count;i++){sx+=xs[i];sy+=ys[i];sxx+=xs[i]*xs[i];sxy+=xs[i]*ys[i];}double den=count*sxx-sx*sx;float a=1,b=0;if(Math.abs(den)>1e-10){a=(float)((count*sxy-sx*sy)/den);b=(float)((sy-a*sx)/count);}a=constrain(a,cfg.calibrationSlopeMin,cfg.calibrationSlopeMax);b=constrain(b,-cfg.calibrationOffsetMaxM,cfg.calibrationOffsetMaxM);out.scale[idx]=a;out.offsetM[idx]=b;out.noiseM[idx]=constrain(noiseSum/count,cfg.calibrationNoiseFloorM,cfg.calibrationNoiseCeilingM);calibratedPixels++;
        if((u&1)==0&&(v&1)==0)for(int i=0;i<count;i++){double eb=xs[i]-ys[i],ea=(a*xs[i]+b)-ys[i];before2+=eb*eb;after2+=ea*ea;residualN++;}
      }
    }
    out.coverage=calibratedPixels/(float)Math.max(1,n);out.calibrated=out.coverage>=0.35f;
    if(residualN>0){out.trainingRmsBeforeMm=(float)(Math.sqrt(before2/residualN)*1000.0);out.trainingRmsAfterMm=(float)(Math.sqrt(after2/residualN)*1000.0);}
    if(!out.calibrated)throw new IllegalStateException("insufficient calibrated-pixel coverage: "+out.coverage);
    return out;
  }
}

class DepthCalibrationStore {
  static final int MAGIC=0x314C4143,VERSION=1;
  File root(){String os=System.getProperty("os.name","").toLowerCase(Locale.ROOT);String base;if(os.contains("win")){base=System.getenv("LOCALAPPDATA");if(base==null||base.isBlank())base=System.getProperty("user.home", ".");return new File(new File(base,"Kinect360Remold"),"calibration");}String xdg=System.getenv("XDG_CONFIG_HOME");if(xdg==null||xdg.isBlank())xdg=new File(System.getProperty("user.home","."),".config").getAbsolutePath();return new File(new File(xdg,"kinect360-remold"),"calibration");}
  String safeId(String id){String s=id==null?"kinect":id.replaceAll("[^A-Za-z0-9._-]","_");if(s.length()>80)s=s.substring(0,64)+"_"+Integer.toHexString(id.hashCode());return s;}
  File fileFor(String id){return new File(root(),safeId(id)+".depthcal");}
  void save(DepthCorrectionProfile p)throws IOException{File dir=root();if(!dir.exists()&&!dir.mkdirs())throw new IOException("cannot create calibration directory: "+dir);File target=fileFor(p.deviceId),tmp=new File(target.getAbsolutePath()+".tmp");try(DataOutputStream out=new DataOutputStream(new BufferedOutputStream(new FileOutputStream(tmp)))){out.writeInt(MAGIC);out.writeInt(VERSION);out.writeUTF(p.deviceId);out.writeInt(p.width);out.writeInt(p.height);out.writeLong(p.createdEpochMs);out.writeBoolean(p.calibrated);out.writeFloat(p.coverage);out.writeFloat(p.trainingRmsBeforeMm);out.writeFloat(p.trainingRmsAfterMm);for(float v:p.scale)out.writeFloat(v);for(float v:p.offsetM)out.writeFloat(v);for(float v:p.noiseM)out.writeFloat(v);}try{Files.move(tmp.toPath(),target.toPath(),StandardCopyOption.REPLACE_EXISTING,StandardCopyOption.ATOMIC_MOVE);}catch(AtomicMoveNotSupportedException e){Files.move(tmp.toPath(),target.toPath(),StandardCopyOption.REPLACE_EXISTING);}}
  DepthCorrectionProfile load(String id,int width,int height){File f=fileFor(id);if(!f.isFile())return null;try(DataInputStream in=new DataInputStream(new BufferedInputStream(new FileInputStream(f)))){if(in.readInt()!=MAGIC||in.readInt()!=VERSION)return null;String stored=in.readUTF();int w=in.readInt(),h=in.readInt();if(!Objects.equals(stored,id)||w!=width||h!=height)return null;DepthCorrectionProfile p=new DepthCorrectionProfile(stored,w,h);p.createdEpochMs=in.readLong();p.calibrated=in.readBoolean();p.coverage=in.readFloat();p.trainingRmsBeforeMm=in.readFloat();p.trainingRmsAfterMm=in.readFloat();for(int i=0;i<p.scale.length;i++)p.scale[i]=in.readFloat();for(int i=0;i<p.offsetM.length;i++)p.offsetM[i]=in.readFloat();for(int i=0;i<p.noiseM.length;i++)p.noiseM[i]=in.readFloat();return p.calibrated?p:null;}catch(Exception e){return null;}}
}

class CalibrationAccumulator {
  final int width,height;final long[] sumMm,sumSqMm;final short[] count;int frames=0;
  CalibrationAccumulator(int width,int height){this.width=width;this.height=height;int n=width*height;sumMm=new long[n];sumSqMm=new long[n];count=new short[n];}
  void add(DepthFrame f){for(int i=0;i<f.depth.length;i++){int mm=f.depth[i]&0xffff;if(mm<=0)continue;sumMm[i]+=mm;sumSqMm[i]+=(long)mm*mm;if(count[i]<Short.MAX_VALUE)count[i]++;}frames++;}
  CalibrationStation finish(Calibration calibration){int n=width*height;float[] mean=new float[n],sigma=new float[n];for(int i=0;i<n;i++){int c=count[i]&0xffff;if(c<max(2,frames/2))continue;double m=sumMm[i]/(double)c;double variance=Math.max(0,sumSqMm[i]/(double)c-m*m);mean[i]=(float)(m*0.001);sigma[i]=(float)(Math.sqrt(variance)*0.001);}PlaneModel plane=fitCalibrationPlane(mean,width,height,calibration);float center=medianCalibrationDepth(mean,width,height);return new CalibrationStation(width,height,mean,sigma,plane,center);}
}

PlaneModel fitCalibrationPlane(float[] depth,int width,int height,Calibration calibration){
  PlaneModel first=fitCalibrationPlanePass(depth,width,height,calibration,null,Float.POSITIVE_INFINITY);if(!first.valid())return first;float cutoff=max(0.004f,min(0.040f,first.rms*2.5f));return fitCalibrationPlanePass(depth,width,height,calibration,first,cutoff);
}
PlaneModel fitCalibrationPlanePass(float[] depth,int width,int height,Calibration calibration,PlaneModel reference,float cutoff){
  double sxx=0,syy=0,sxy=0,sx=0,sy=0,sz=0,sxz=0,syz=0;int n=0;int step=3;
  for(int v=8;v<height-8;v+=step)for(int u=8;u<width-8;u+=step){int i=v*width+u;float z=depth[i];if(z<0.35f||z>3.0f)continue;float x=(u-calibration.cx)/calibration.fx,y=(v-calibration.cy)/calibration.fy;if(reference!=null&&abs(z-reference.depthAt(x,y))>cutoff)continue;sxx+=x*x;syy+=y*y;sxy+=x*y;sx+=x;sy+=y;sz+=z;sxz+=x*z;syz+=y*z;n++;}
  PlaneModel out=new PlaneModel();if(n<128)return out;double[][] a={{sxx,sxy,sx,sxz},{sxy,syy,sy,syz},{sx,sy,n,sz}};for(int col=0;col<3;col++){int pivot=col;for(int r=col+1;r<3;r++)if(Math.abs(a[r][col])>Math.abs(a[pivot][col]))pivot=r;if(Math.abs(a[pivot][col])<1e-12)return out;double[] tmp=a[col];a[col]=a[pivot];a[pivot]=tmp;double d=a[col][col];for(int c=col;c<4;c++)a[col][c]/=d;for(int r=0;r<3;r++)if(r!=col){double f=a[r][col];for(int c=col;c<4;c++)a[r][c]-=f*a[col][c];}}
  out.ax=(float)a[0][3];out.by=(float)a[1][3];out.c=(float)a[2][3];out.samples=n;double e2=0;int en=0;for(int v=8;v<height-8;v+=step)for(int u=8;u<width-8;u+=step){float z=depth[v*width+u];if(z<=0)continue;float x=(u-calibration.cx)/calibration.fx,y=(v-calibration.cy)/calibration.fy,r=z-out.depthAt(x,y);if(reference!=null&&abs(r)>cutoff)continue;e2+=r*r;en++;}out.rms=en==0?Float.POSITIVE_INFINITY:(float)Math.sqrt(e2/en);return out;
}
float medianCalibrationDepth(float[] depth,int width,int height){int x0=width*3/8,x1=width*5/8,y0=height*3/8,y1=height*5/8;float[] scratch=new float[(x1-x0)*(y1-y0)/16+64];int n=0;for(int y=y0;y<y1;y+=4)for(int x=x0;x<x1;x+=4){float z=depth[y*width+x];if(z>0){if(n>=scratch.length)scratch=Arrays.copyOf(scratch,scratch.length*2);scratch[n++]=z;}}if(n==0)return Float.NaN;Arrays.sort(scratch,0,n);return scratch[n/2];}

class DepthCalibrationSession {
  final AppConfig cfg;final Calibration calibration;final DepthCalibrationStore store;final String deviceId;final ArrayList<CalibrationStation> stations=new ArrayList<CalibrationStation>();
  boolean active=false,waitingForDistance=false;int capturedFrames=0,lastFrameId=-1;float anchorDepthM=Float.NaN;CalibrationAccumulator accumulator=null;float[] quickDepth=null;
  DepthCalibrationSession(AppConfig cfg,Calibration calibration,DepthCalibrationStore store,String deviceId){this.cfg=cfg;this.calibration=calibration;this.store=store;this.deviceId=deviceId;}
  void start(){active=true;waitingForDistance=false;capturedFrames=0;anchorDepthM=Float.NaN;accumulator=null;stations.clear();}
  void cancel(){active=false;accumulator=null;}
  DepthCorrectionProfile offer(DepthFrame frame)throws IOException{
    if(!active||frame==null||frame.depth==null||frame.frameId==lastFrameId)return null;lastFrameId=frame.frameId;
    if(quickDepth==null||quickDepth.length!=frame.depth.length)quickDepth=new float[frame.depth.length];for(int i=0;i<quickDepth.length;i++){int mm=frame.depth[i]&0xffff;quickDepth[i]=mm>0?mm*0.001f:0;}PlaneModel plane=fitCalibrationPlane(quickDepth,frame.width,frame.height,calibration);float center=medianCalibrationDepth(quickDepth,frame.width,frame.height);if(!plane.valid()||!Float.isFinite(center)||plane.rms>cfg.calibrationPlaneResidualMaxM)return null;
    if(waitingForDistance){float previous=stations.get(stations.size()-1).centerDepthM;if(abs(center-previous)<cfg.calibrationDistanceSeparationM)return null;waitingForDistance=false;anchorDepthM=center;accumulator=new CalibrationAccumulator(frame.width,frame.height);capturedFrames=0;}
    if(accumulator==null){anchorDepthM=center;accumulator=new CalibrationAccumulator(frame.width,frame.height);}
    if(abs(center-anchorDepthM)>cfg.calibrationStabilityToleranceM){accumulator=null;capturedFrames=0;anchorDepthM=Float.NaN;return null;}
    accumulator.add(frame);capturedFrames++;
    if(capturedFrames<cfg.calibrationFramesPerStation)return null;
    CalibrationStation station=accumulator.finish(calibration);accumulator=null;capturedFrames=0;anchorDepthM=Float.NaN;if(!station.plane.valid()||station.plane.rms>cfg.calibrationPlaneResidualMaxM)return null;stations.add(station);
    if(stations.size()<cfg.calibrationStations){waitingForDistance=true;return null;}
    DepthCorrectionProfile profile=new DepthCorrectionProfile(deviceId,calibration.depthWidth,calibration.depthHeight).fit(stations,calibration,cfg);store.save(profile);active=false;return profile;
  }
}

class Calibration {
  volatile boolean valid = false;
  int depthWidth = studio.services.scannerProtocol.WIDTH;
  int depthHeight = studio.services.scannerProtocol.HEIGHT;
  float fx, fy, cx, cy, depthScale;
  String deviceId="";DepthCorrectionProfile depthCorrection=null;AppConfig cfg;

  void configure(AppConfig cfg) {
    this.cfg=cfg;if (cfg == null) { valid = false; return; }
    depthWidth = studio.services.scannerProtocol.WIDTH;
    depthHeight = studio.services.scannerProtocol.HEIGHT;
    fx = cfg.depthFx; fy = cfg.depthFy; cx = cfg.depthCx; cy = cfg.depthCy; depthScale = cfg.depthScale;
    valid = fx > 0 && fy > 0 && depthScale > 0;
  }
  void selectDevice(String id,DepthCorrectionProfile profile){deviceId=id==null?"":id;depthCorrection=profile;}
  boolean hasDepthCorrection(){return cfg!=null&&cfg.calibrationEnabled&&depthCorrection!=null&&depthCorrection.calibrated;}
  int correctedDepthMm(int index,int rawMm){return hasDepthCorrection()?depthCorrection.correctMm(index,rawMm):rawMm;}
  float depthConfidence(int index,float depthM){return hasDepthCorrection()?depthCorrection.confidenceAt(index,depthM,cfg):1.0f;}
}

class DepthFrame {
  int frameId, width, height, stride, pixelFormat;
  long frameNumber, timestampUs;
  short[] depth; // unsigned millimetres; 0 means invalid / missing packet data
  int validCount = 0;
  int plausibleCount = 0;
  boolean deviceCalibrated = false;
  boolean transportRecovered = false;
  MotionSample motion = new MotionSample();

  int validPixelCount() { return validCount; }
}


// ===== SynKinect Studio / 3D Scanner / IcpTracker.pde =====
class IcpTracker {
  AppConfig cfg;
  RigidTransform pose = new RigidTransform();
  PointCloud reference = null;
  boolean trackingGood = false;
  float rms = Float.POSITIVE_INFINITY;
  int matches = 0;
  PVector gravityReference = null;
  boolean motionPriorUsed = false;
  final ArrayList<PVector> matchSrc=new ArrayList<PVector>();
  final ArrayList<PVector> matchDst=new ArrayList<PVector>();
  final ArrayList<PVector> matchPool=new ArrayList<PVector>();
  final QuaternionFit fitter=new QuaternionFit();

  IcpTracker(AppConfig cfg){ this.cfg=cfg; }

  void reset(){ pose.setIdentity(); reference=null; trackingGood=false; rms=Float.POSITIVE_INFINITY; matches=0; gravityReference=null; motionPriorUsed=false; matchSrc.clear();matchDst.clear(); }

  PVector transformedSample(int slot,PVector source,RigidTransform estimate){
    while(matchPool.size()<=slot)matchPool.add(new PVector());
    PVector out=matchPool.get(slot);float[] m=estimate.m;
    out.set(m[0]*source.x+m[1]*source.y+m[2]*source.z+m[3],m[4]*source.x+m[5]*source.y+m[6]*source.z+m[7],m[8]*source.x+m[9]*source.y+m[10]*source.z+m[11]);
    return out;
  }

  RigidTransform track(PointCloud current, MotionSample motion) {
    if(reference==null || reference.size()<cfg.icpMinimumMatches) {
      pose.setIdentity();
      if(motion!=null && motion.gravityReliable()) gravityReference=motion.gravityUnit();
      reference=current.transformed(pose,cfg.icpMaxSamples);
      trackingGood=true; rms=0; matches=reference.size();
      return pose;
    }

    RigidTransform estimate=new RigidTransform(); estimate.set(pose);
    estimate=applyMotionPrior(estimate,motion);
    float finalRms=Float.POSITIVE_INFINITY; int finalMatches=0;

    SpatialHash hash=new SpatialHash(cfg.icpCellSizeM,reference.size());
    for(PVector p:reference.points) hash.add(p);
    int maxSamples=max(1,cfg.icpMaxSamples);
    int stride=max(1,(current.size()+maxSamples-1)/maxSamples);

    for(int iter=0;iter<cfg.icpIterations;iter++) {
      matchSrc.clear();matchDst.clear();
      float sum2=0;int slot=0;
      for(int i=0;i<current.size();i+=stride) {
        PVector world=transformedSample(slot++,current.points.get(i),estimate);
        PVector near=hash.nearest(world,cfg.icpMaxDistanceM);
        if(near!=null){float dx=world.x-near.x,dy=world.y-near.y,dz=world.z-near.z;matchSrc.add(world);matchDst.add(near);sum2+=dx*dx+dy*dy+dz*dz;}
      }
      if(matchSrc.size()<cfg.icpMinimumMatches) break;
      finalRms=sqrt(sum2/matchSrc.size()); finalMatches=matchSrc.size();
      RigidTransform correction=fitter.fit(matchSrc,matchDst);
      estimate=correction.multiply(estimate);
    }

    rms=finalRms; matches=finalMatches;
    trackingGood = matches>=cfg.icpMinimumMatches && rms<cfg.icpGoodRmsM;
    if(trackingGood) {
      pose.set(estimate);
      reference=current.transformed(pose,cfg.icpMaxSamples);
    }
    return pose;
  }

  RigidTransform applyMotionPrior(RigidTransform estimate, MotionSample motion){
    motionPriorUsed=false;
    if(motion==null || !motion.gravityReliable()) return estimate;
    PVector g=motion.gravityUnit();
    if(g==null) return estimate;
    if(gravityReference==null){ gravityReference=g.copy(); return estimate; }

    PVector currentWorld=estimate.rotate(g);
    if(currentWorld.magSq()<1e-8f) return estimate;
    currentWorld.normalize();
    PVector target=gravityReference.copy(); target.normalize();
    RigidTransform correction=rotationBetween(currentWorld,target);
    RigidTransform corrected=correction.multiply(estimate);
    corrected.m[3]=estimate.m[3]; corrected.m[7]=estimate.m[7]; corrected.m[11]=estimate.m[11];
    motionPriorUsed=true;
    return corrected;
  }

  RigidTransform rotationBetween(PVector from, PVector to){
    PVector a=from.copy(); PVector b=to.copy();
    if(a.magSq()<1e-8f || b.magSq()<1e-8f) return new RigidTransform();
    a.normalize(); b.normalize();
    float c=constrain(a.dot(b),-1.0f,1.0f);
    PVector axis=a.cross(b);float magnitude=axis.mag();
    if(magnitude<1e-6f){
      if(c>0) return new RigidTransform();
      axis=abs(a.x)<0.8f?a.cross(new PVector(1,0,0)):a.cross(new PVector(0,1,0));axis.normalize();return axisAngle(axis,PI);
    }
    axis.div(magnitude);return axisAngle(axis,atan2(magnitude,c));
  }

  RigidTransform axisAngle(PVector a,float angle){
    float x=a.x,y=a.y,z=a.z,c=cos(angle),ss=sin(angle),t=1-c;
    float[][] R={{t*x*x+c,t*x*y-ss*z,t*x*z+ss*y},{t*x*y+ss*z,t*y*y+c,t*y*z-ss*x},{t*x*z-ss*y,t*y*z+ss*x,t*z*z+c}};
    return new RigidTransform().fromRotationTranslation(R,new PVector());
  }
}

// ===== SynKinect Studio / 3D Scanner / KinectSource.pde =====
class RawRgbFrame {
 final byte[] data;final int width,height,pixelFormat;final long frameNumber,timestampUs;final float quality;
 volatile byte[] nv12Cache=null;
 RawRgbFrame(byte[] data,int width,int height,int pixelFormat,long frameNumber,long timestampUs,float quality){this.data=data;this.width=width;this.height=height;this.pixelFormat=pixelFormat;this.frameNumber=frameNumber;this.timestampUs=timestampUs;this.quality=quality;}
 boolean highQuality(){return pixelFormat==studio.services.scannerProtocol.PIXEL_BAYER_GRBG8&&width==studio.services.scannerProtocol.RGB_HQ_WIDTH&&height==studio.services.scannerProtocol.RGB_HQ_HEIGHT;}
}
class RgbdFramePair {
  final DepthFrame depth;final RawRgbFrame rgb;final RawRgbFrame hq;final long sequence,rawSkewUs,residualUs;final float syncQuality;
  RgbdFramePair(DepthFrame d,RawRgbFrame r,RawRgbFrame h,long seq,long raw,long residual,float q){depth=d;rgb=r;hq=h;sequence=seq;rawSkewUs=raw;residualUs=residual;syncQuality=q;}
}

class KinectSource {
  AppConfig config;
  Calibration calibration;
  DepthCalibrationStore calibrationStore;
  DepthCalibrationSession calibrationSession;
  I18n i18n;

  volatile boolean portReady = false, deviceConnected = false, depthConnected = false, colorConnected = false;
  volatile boolean metricDepthCalibrated = false, running = false;
  volatile boolean lastDepthRecovered = false;
  volatile boolean factoryDepthCalibrationValid = false;
  volatile double factoryDepthConstShift = 0.0, factoryDepthEmitterDistance = 0.0, factoryDepthReferenceDistance = 0.0, factoryDepthReferencePixelSize = 0.0;
  final int[] factoryDepthRawToMm = new int[2048];
  volatile int acceptedStreams = 0, capabilities = 0, negotiatedMaxPayload = 0, activeSessionMask = 0;
  volatile String lastTransportError = "", depthWarning = "";
  volatile long depthFrames = 0, colorFrames = 0;
  volatile long depthSequenceGaps=0,colorSequenceGaps=0;
  volatile long lastDepthArrivalMs = 0, lastColorArrivalMs = 0, lastAnyArrivalMs = 0;
  volatile long connectedSinceMs = 0, connectionEpoch = 0, reconnectKicks = 0, lastReconnectKickMs = 0;
  volatile MotionSample latestMotion = new MotionSample();

  Thread worker = null;
  volatile long runGeneration = 0;
  volatile LocalTransport activeScannerPipe = null;
 final Object pipeLock = new Object();
 final Object frameLock = new Object();
 final ArrayDeque<DepthFrame> syncDepth = new ArrayDeque<DepthFrame>();
 final ArrayDeque<RawRgbFrame> syncRgb = new ArrayDeque<RawRgbFrame>();
 final ArrayDeque<RawRgbFrame> syncHq = new ArrayDeque<RawRgbFrame>();
 final ArrayDeque<RawRgbFrame> hqRgbHistory = new ArrayDeque<RawRgbFrame>();
 final ArrayDeque<RgbdFramePair> rgbdQueue = new ArrayDeque<RgbdFramePair>();
 volatile RgbdFramePair latestRgbdPair=null;
 volatile long pairedFrames=0,droppedUnpairedDepthFrames=0,droppedUnpairedRgbFrames=0,droppedRgbdPairs=0,lastPairedArrivalMs=0,hqColorFrames=0;
 volatile boolean rgbHqTransportAvailable=true,hqColorRequested=false;
 volatile long firstRgbFallbackMs=0,lastHqFrameArrivalMs=0;
 volatile String rgbHqCapabilityDeviceId="";
 volatile float latestSyncResidualMs=Float.NaN,latestRawSyncSkewMs=Float.NaN;
 double syncOffsetUs=0.0;boolean syncOffsetValid=false;long pairSequence=0;
 final byte[] frameHeaderBuffer = new byte[studio.services.scannerProtocol.FRAME_HEADER_BYTES];
 final byte[] depthPackedPayloadBuffer = new byte[studio.services.scannerProtocol.DEPTH_RAW11_PACKED_BYTES];
 final long[] lastFrameNumber = new long[]{-1L, -1L, -1L, -1L};
 PImage scannerPreviewImage=null;
 int[] reconstructionRgbPixels=null;

  KinectSource(AppConfig config, Calibration calibration, I18n i18n) {
    this.config = config; this.calibration = calibration; this.i18n = i18n;
  }

  synchronized void start() {
    if (running) return;
    resetConnectionState(true); droppedUnpairedDepthFrames=0; droppedUnpairedRgbFrames=0; droppedRgbdPairs=0; pairedFrames=0; depthSequenceGaps=0; colorSequenceGaps=0;
    running = true;
    final long generation=++runGeneration;
    worker = studio.services.workers.start("Scanner-Port",new Runnable(){ public void run(){ streamWorkerLoop(generation); }});
  }

  void requestStop(boolean clearPending) {
    Thread t;
    synchronized(this){
      running=false; ++runGeneration; closeActivePipe(); t=worker; worker=null;
    }
    if(t!=null)t.interrupt();
    synchronized(pipeLock){activeScannerPipe=null;}
    resetConnectionState(clearPending);
  }
  void requestStop(){requestStop(true);}
  void stop() { stop(true); }
  void stop(boolean clearPending) {
    Thread t;
    synchronized(this){
      if(!running&&worker==null){resetConnectionState(clearPending);return;}
      running=false; ++runGeneration; closeActivePipe(); t=worker; worker=null;
    }
    if(t!=null){
      t.interrupt();
      try{t.join(config.workerJoinMs);}catch(InterruptedException ignored){Thread.currentThread().interrupt();}
      if(t.isAlive()){closeActivePipe();t.interrupt();try{t.join(config.workerJoinMs);}catch(InterruptedException ignored){Thread.currentThread().interrupt();}}
    }
    synchronized(pipeLock){activeScannerPipe=null;} resetConnectionState(clearPending);
  }

  long monotonicMs() { return System.nanoTime() / 1000000L; }
  void setActivePipe(LocalTransport pipe){ synchronized(pipeLock){ activeScannerPipe=pipe; } }
  void clearActivePipe(LocalTransport pipe){ synchronized(pipeLock){ if(activeScannerPipe==pipe) activeScannerPipe=null; } }
  void closeActivePipe(){ LocalTransport pipe; synchronized(pipeLock){ pipe=activeScannerPipe; activeScannerPipe=null; } closePipe(pipe); }
  void closePipe(LocalTransport pipe){
    if(pipe==null) return;
    try { pipe.close(); } catch(IOException e) { if(running) println("Scanner pipe close warning: " + e.getMessage()); }
  }

  void resetConnectionState(boolean clearPending) {
    portReady=false; deviceConnected=false; depthConnected=false; colorConnected=false; metricDepthCalibrated=false; lastDepthRecovered=false;
    factoryDepthCalibrationValid=false; factoryDepthConstShift=factoryDepthEmitterDistance=factoryDepthReferenceDistance=factoryDepthReferencePixelSize=0.0; Arrays.fill(factoryDepthRawToMm,0);
    acceptedStreams=0; capabilities=0; negotiatedMaxPayload=0; activeSessionMask=0; depthWarning="";
    connectedSinceMs=0; lastDepthArrivalMs=0; lastColorArrivalMs=0; lastAnyArrivalMs=0; firstRgbFallbackMs=0; lastHqFrameArrivalMs=0;
    for(int i=0;i<lastFrameNumber.length;i++) lastFrameNumber[i]=-1L;
    synchronized(frameLock){
      // Never pair samples across a transport epoch. Preserve already-published pairs
      // only when reconnecting in place so consumers can drain them deterministically.
      syncDepth.clear();syncRgb.clear();syncHq.clear();hqRgbHistory.clear();syncOffsetUs=0;syncOffsetValid=false;latestSyncResidualMs=Float.NaN;latestRawSyncSkewMs=Float.NaN;
      if(clearPending){rgbdQueue.clear();latestRgbdPair=null;pairSequence=0;}
    }
  }

  void updateLiveness() {
    long now = monotonicMs();
    colorConnected = lastColorArrivalMs > 0 && now - lastColorArrivalMs <= config.streamStaleTimeoutMs;
    boolean depthFresh = lastDepthArrivalMs > 0 && now - lastDepthArrivalMs <= config.streamStaleTimeoutMs;
    if (!depthFresh) {
      depthConnected = false; metricDepthCalibrated = false; lastDepthRecovered = false;
      if (lastDepthArrivalMs > 0) depthWarning = i18n.tr("transport.depth_stale");
      else if (portReady && colorFrames >= 30) depthWarning = i18n.tr("transport.depth_no_frames");
    }
    deviceConnected = lastAnyArrivalMs > 0 && now - lastAnyArrivalMs <= config.connectionStaleTimeoutMs;
    // A pipe can remain open while its server-side session is no longer producing frames.
    // Force a fresh subscribe instead of leaving Processing attached to a zombie session.
    long anchor = lastAnyArrivalMs > 0 ? lastAnyArrivalMs : connectedSinceMs;
    if (portReady && anchor > 0 && now - anchor > config.connectionStaleTimeoutMs) requestReconnect("stale-session");
  }

  void setHqColorRequested(boolean requested){
    boolean changed=hqColorRequested!=requested;
    hqColorRequested=requested;
    if(!requested)synchronized(frameLock){hqRgbHistory.clear();}
    // Re-negotiate only when the desired stream set actually changes. The Scanner
    // requests HQ before starting its transport, so pressing SCAN never causes this.
    if(changed&&running){
      boolean sessionHasHq=(activeSessionMask&studio.services.scannerProtocol.STREAM_RGB_HQ)!=0;
      if(sessionHasHq!=requested)requestReconnect(requested?"switch-hq":"switch-vga");
    }
  }

  void requestReconnect(String reason){
    if(!running)return;
    long now=monotonicMs();
    if(now-lastReconnectKickMs<Math.max(100,config.reconnectDelayMs))return;
    lastReconnectKickMs=now; reconnectKicks++; lastTransportError=i18n.format("transport.error",reason);
    studio.services.workers.start("Scanner-Reconnect",new Runnable(){public void run(){closeActivePipe();}});
  }

  RgbdFramePair pollRgbdPair(){synchronized(frameLock){return rgbdQueue.isEmpty()?null:rgbdQueue.removeFirst();}}
  RgbdFramePair latestRgbdPairAfter(long sequence){synchronized(frameLock){RgbdFramePair p=latestRgbdPair;return p!=null&&p.sequence>sequence?p:null;}}
  int queuedRgbdPairs(){synchronized(frameLock){return rgbdQueue.size();}}
  void clearConsumerPairs(){synchronized(frameLock){rgbdQueue.clear();}}
  RgbSnapshot rgbPreviewSnapshot(RgbdFramePair pair){
    if(pair==null)return null;
    if(pair.rgb!=null&&pair.rgb.data!=null){
      int w=pair.rgb.width,h=pair.rgb.height;
      if(scannerPreviewImage==null||scannerPreviewImage.width!=w||scannerPreviewImage.height!=h)scannerPreviewImage=createImage(w,h,RGB);
      scannerPreviewImage.loadPixels();
      boolean decoded=pair.rgb.pixelFormat==studio.services.scannerProtocol.PIXEL_BAYER_GRBG8
        ? RgbHqProcessor.decodeBayerGrbg(pair.rgb.data,w,h,scannerPreviewImage.pixels)
        : decodeNv12ToArgb(pair.rgb.data,w,h,scannerPreviewImage.pixels);
      if(!decoded)return null;
      scannerPreviewImage.updatePixels();
      return new RgbSnapshot(scannerPreviewImage.pixels,w,h,scannerPreviewImage,pair.rgb.frameNumber,pair.rgb.timestampUs,System.currentTimeMillis(),pair.residualUs/1000.0f,pair.rawSkewUs/1000.0f,config.rgbMaxSyncSkewMs,pair.rgb.quality);
    }
    if(pair.hq!=null&&pair.hq.data!=null&&pair.hq.highQuality()){
      int w=pair.hq.width/2,h=pair.hq.height/2;
      if(scannerPreviewImage==null||scannerPreviewImage.width!=w||scannerPreviewImage.height!=h)scannerPreviewImage=createImage(w,h,RGB);
      scannerPreviewImage.loadPixels();
      if(!decodeBayerGrbgHalf(pair.hq.data,pair.hq.width,pair.hq.height,scannerPreviewImage.pixels))return null;
      scannerPreviewImage.updatePixels();
      return new RgbSnapshot(scannerPreviewImage.pixels,w,h,scannerPreviewImage,pair.hq.frameNumber,pair.hq.timestampUs,System.currentTimeMillis(),pair.residualUs/1000.0f,pair.rawSkewUs/1000.0f,config.rgbHqMaxSyncSkewMs,pair.hq.quality);
    }
    return null;
  }

  boolean decodeBayerGrbgHalf(byte[] data,int w,int h,int[] out){
    if(data==null||w<2||h<2||(w&1)!=0||(h&1)!=0||data.length!=w*h||out==null||out.length<(w/2)*(h/2))return false;
    int ow=w/2,index=0;
    for(int y=0;y<h;y+=2){
      int row0=y*w,row1=(y+1)*w;
      for(int x=0;x<w;x+=2){
        int g0=data[row0+x]&0xff,r=data[row0+x+1]&0xff,b=data[row1+x]&0xff,g1=data[row1+x+1]&0xff;
        int g=(g0+g1+1)>>1;
        out[index++]=0xff000000|(r<<16)|(g<<8)|b;
      }
    }
    return true;
  }
  RgbSnapshot rgbReconstructionSnapshot(RgbdFramePair pair){
    if(pair==null||pair.rgb==null||pair.rgb.data==null)return null;
    int w=pair.rgb.width,h=pair.rgb.height,count=w*h;
    if(reconstructionRgbPixels==null||reconstructionRgbPixels.length!=count)reconstructionRgbPixels=new int[count];
    boolean decoded=pair.rgb.pixelFormat==studio.services.scannerProtocol.PIXEL_BAYER_GRBG8
      ? RgbHqProcessor.decodeBayerGrbg(pair.rgb.data,w,h,reconstructionRgbPixels)
      : decodeNv12ToArgb(pair.rgb.data,w,h,reconstructionRgbPixels);
    if(!decoded)return null;
    return new RgbSnapshot(reconstructionRgbPixels,w,h,null,pair.rgb.frameNumber,pair.rgb.timestampUs,System.currentTimeMillis(),pair.residualUs/1000.0f,pair.rawSkewUs/1000.0f,config.rgbMaxSyncSkewMs,pair.rgb.quality);
  }
  void offerDepth(DepthFrame f){synchronized(frameLock){syncDepth.addLast(f);trimSyncQueuesLocked();pairRgbdLocked();}}
  void offerRgb(RawRgbFrame f){
    synchronized(frameLock){
      syncRgb.addLast(f);
      if(hqColorRequested&&lastHqFrameArrivalMs==0){
        long now=monotonicMs();if(firstRgbFallbackMs==0)firstRgbFallbackMs=now;
        if(now-firstRgbFallbackMs>2200)rgbHqTransportAvailable=false;
      }
      trimSyncQueuesLocked();pairRgbdLocked();
    }
  }
  void offerHqRgb(RawRgbFrame f){
    synchronized(frameLock){
      lastHqFrameArrivalMs=monotonicMs();rgbHqTransportAvailable=true;
      syncHq.addLast(f);hqRgbHistory.addLast(f);while(hqRgbHistory.size()>config.rgbHqHistoryFrames)hqRgbHistory.removeFirst();hqColorFrames++;trimSyncQueuesLocked();pairRgbdLocked();
    }
  }
  RawRgbFrame bestHqRgbFor(long timestampUs){synchronized(frameLock){RawRgbFrame best=null;long bestSkew=Long.MAX_VALUE;for(RawRgbFrame f:hqRgbHistory){long skew=Math.abs(f.timestampUs-timestampUs);if(skew<bestSkew){bestSkew=skew;best=f;}}return best!=null&&bestSkew<=Math.round(config.rgbHqMaxSyncSkewMs*1000.0f)?best:null;}}
  void trimSyncQueuesLocked(){
    while(syncDepth.size()>config.rgbdSyncHistoryFrames){syncDepth.removeFirst();droppedUnpairedDepthFrames++;}
    while(syncRgb.size()>config.rgbdSyncHistoryFrames){syncRgb.removeFirst();droppedUnpairedRgbFrames++;}
    while(syncHq.size()>config.rgbdSyncHistoryFrames){syncHq.removeFirst();droppedUnpairedRgbFrames++;}
  }
  RawRgbFrame nearestRgbLocked(long timestampUs){
    RawRgbFrame best=null;long bestSkew=Long.MAX_VALUE;
    for(RawRgbFrame f:syncRgb){long skew=Math.abs(f.timestampUs-timestampUs);if(skew<bestSkew){bestSkew=skew;best=f;}}
    if(best==null||bestSkew>Math.round(config.rgbMaxSyncSkewMs*1000.0f))return null;
    while(!syncRgb.isEmpty()&&syncRgb.peekFirst()!=best){syncRgb.removeFirst();droppedUnpairedRgbFrames++;}
    if(!syncRgb.isEmpty())syncRgb.removeFirst();
    return best;
  }
  void pairRgbdLocked(){
    boolean hqRequested=(activeSessionMask&studio.services.scannerProtocol.STREAM_RGB_HQ)!=0;
    boolean hq=hqRequested&&!syncHq.isEmpty();
    ArrayDeque<RawRgbFrame> colors=hq?syncHq:syncRgb;
    final long maxResidual=(long)((hq?config.rgbHqMaxSyncSkewMs:config.rgbdSyncMaxResidualMs)*1000.0f);
    final long bootstrap=(long)(config.rgbdSyncBootstrapMaxSkewMs*1000.0f);
    while(!syncDepth.isEmpty()&&!colors.isEmpty()){
      DepthFrame bestD=null;RawRgbFrame bestR=null;long bestMetric=Long.MAX_VALUE,bestDelta=0;
      for(DepthFrame d:syncDepth)for(RawRgbFrame r:colors){
        long delta=r.timestampUs-d.timestampUs;
        long metric=Math.abs(delta-(syncOffsetValid?Math.round(syncOffsetUs):0L));
        if(metric<bestMetric){bestMetric=metric;bestDelta=delta;bestD=d;bestR=r;}
      }
      long limit=syncOffsetValid?maxResidual:bootstrap;
      if(bestD!=null&&bestMetric<=limit){
        while(!syncDepth.isEmpty()&&syncDepth.peekFirst()!=bestD){syncDepth.removeFirst();droppedUnpairedDepthFrames++;}if(!syncDepth.isEmpty())syncDepth.removeFirst();
        while(!colors.isEmpty()&&colors.peekFirst()!=bestR){colors.removeFirst();droppedUnpairedRgbFrames++;}if(!colors.isEmpty())colors.removeFirst();
        RawRgbFrame pairedVga=hq?nearestRgbLocked(bestR.timestampUs):bestR;
        if(!syncOffsetValid){syncOffsetUs=bestDelta;syncOffsetValid=true;}else syncOffsetUs=syncOffsetUs*(1.0-config.rgbdSyncOffsetAlpha)+bestDelta*config.rgbdSyncOffsetAlpha;
        long residual=Math.abs(bestDelta-Math.round(syncOffsetUs)),raw=Math.abs(bestDelta);float q=1.0f-constrain(residual/(float)Math.max(1,maxResidual),0,1);
        RgbdFramePair pair=new RgbdFramePair(bestD,pairedVga,hq?bestR:null,++pairSequence,raw,residual,q);
        latestRgbdPair=pair;pairedFrames++;lastPairedArrivalMs=monotonicMs();latestSyncResidualMs=residual/1000.0f;latestRawSyncSkewMs=raw/1000.0f;
        if(rgbdQueue.size()>=config.rgbdQueueFrames){rgbdQueue.removeFirst();droppedRgbdPairs++;}rgbdQueue.addLast(pair);continue;
      }
      DepthFrame d=syncDepth.peekFirst();RawRgbFrame r=colors.peekFirst();long adjusted=(r.timestampUs-d.timestampUs)-(syncOffsetValid?Math.round(syncOffsetUs):0L);
      if(adjusted>limit){syncDepth.removeFirst();droppedUnpairedDepthFrames++;continue;}
      if(adjusted<-limit){colors.removeFirst();droppedUnpairedRgbFrames++;continue;}
      break;
    }
  }

  void streamWorkerLoop(long generation){
    while(running&&generation==runGeneration){
      LocalTransport pipe=null;
      try{
        resetConnectionState(false);
        KinectDevice selected=studio.selectedKinect();if(selected==null)throw new IOException("no Kinect camera available");
        if(!selected.id.equals(rgbHqCapabilityDeviceId)){rgbHqCapabilityDeviceId=selected.id;rgbHqTransportAvailable=true;}
        pipe=studio.services.transportFactory.openEndpoint(selected.endpoint); setActivePipe(pipe);
        int sessionMask=(hqColorRequested&&rgbHqTransportAvailable)
          ?studio.services.scannerProtocol.STREAM_SESSION_HQ
          :studio.services.scannerProtocol.STREAM_SESSION;
        try{subscribe(pipe,sessionMask);}catch(IOException subscribeError){
          if((sessionMask&studio.services.scannerProtocol.STREAM_RGB_HQ)!=0){
            rgbHqTransportAvailable=false;
            throw new IOException("rgb-hq-unavailable; falling back to VGA on reconnect",subscribeError);
          }
          throw subscribeError;
        }
        activeSessionMask=sessionMask;
        connectedSinceMs=monotonicMs(); connectionEpoch++; lastTransportError="";
        while(running&&generation==runGeneration) readFrame(pipe,sessionMask);
      } catch(Exception e) {
        if(generation==runGeneration){
          resetConnectionState(false);
          if(running) lastTransportError=i18n.format("transport.error", safeMessage(e));
        }
      } finally { clearActivePipe(pipe); closePipe(pipe); }
      if(running&&generation==runGeneration) try{Thread.sleep(config.reconnectDelayMs);}catch(InterruptedException ignored){if(!running||generation!=runGeneration)return;Thread.currentThread().interrupt(); return;}
    }
  }

  void subscribe(LocalTransport pipe,int mask)throws IOException{
    if(mask!=studio.services.scannerProtocol.STREAM_SESSION&&mask!=studio.services.scannerProtocol.STREAM_SESSION_HQ) throw new IOException("protocol/stream-mask:"+mask);
    ByteBuffer req=ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN);
    req.putInt(studio.services.scannerProtocol.MAGIC); req.putInt(studio.services.scannerProtocol.VERSION); req.putInt(studio.services.scannerProtocol.CMD_SUBSCRIBE_STREAMS); req.putInt(mask); pipe.write(req.array());

    byte[] rb=new byte[studio.services.scannerProtocol.REPLY_BYTES]; pipe.readFully(rb); ByteBuffer r=ByteBuffer.wrap(rb).order(ByteOrder.LITTLE_ENDIAN);
    int magic=r.getInt(), version=r.getInt(), result=r.getInt(), accepted=r.getInt();
    int w=r.getInt(), h=r.getInt(), caps=r.getInt(), maxPayload=r.getInt();
    int depthCalibrationValid=r.getInt();
    double depthConstShift=r.getDouble(),depthEmitterDistance=r.getDouble(),depthReferenceDistance=r.getDouble(),depthReferencePixelSize=r.getDouble();
    if(magic!=studio.services.scannerProtocol.MAGIC) throw new IOException("protocol/reply-magic");
    if(version!=studio.services.scannerProtocol.VERSION) throw new IOException("protocol/version:"+version);
    if(result<0) throw new IOException("protocol/subscribe:0x"+Integer.toHexString(result));
    if(accepted!=mask) throw new IOException("protocol/accepted-mask:"+accepted+"/"+mask);
    if(w!=studio.services.scannerProtocol.WIDTH||h!=studio.services.scannerProtocol.HEIGHT) throw new IOException("protocol/dimensions:"+w+"x"+h);
    if((caps&studio.services.scannerProtocol.REQUIRED_CAPABILITIES)!=studio.services.scannerProtocol.REQUIRED_CAPABILITIES) throw new IOException("protocol/capabilities:0x"+Integer.toHexString(caps));
    if((mask&studio.services.scannerProtocol.STREAM_RGB_HQ)!=0&&(caps&studio.services.scannerProtocol.CAP_RGB_HQ)==0) throw new IOException("protocol/rgb-hq-capability");
    int requiredPayload=(mask&studio.services.scannerProtocol.STREAM_RGB_HQ)!=0?studio.services.scannerProtocol.RGB_HQ_BYTES:studio.services.scannerProtocol.DEPTH_RAW11_PACKED_BYTES;
    if(maxPayload<requiredPayload) throw new IOException("protocol/max-payload:"+maxPayload+"/"+requiredPayload);
    acceptedStreams=accepted; capabilities=caps; negotiatedMaxPayload=maxPayload;
    configureFactoryDepthCalibration(depthCalibrationValid!=0,depthConstShift,depthEmitterDistance,depthReferenceDistance,depthReferencePixelSize);
    portReady=true;
  }

  void configureFactoryDepthCalibration(boolean valid,double constShift,double emitterDistance,double referenceDistance,double referencePixelSize){
    factoryDepthCalibrationValid=valid&&Double.isFinite(constShift)&&Double.isFinite(emitterDistance)&&Double.isFinite(referenceDistance)&&Double.isFinite(referencePixelSize)&&constShift>0&&emitterDistance>0&&referenceDistance>0&&referencePixelSize>0;
    factoryDepthConstShift=constShift;factoryDepthEmitterDistance=emitterDistance;factoryDepthReferenceDistance=referenceDistance;factoryDepthReferencePixelSize=referencePixelSize;Arrays.fill(factoryDepthRawToMm,0);
    if(!factoryDepthCalibrationValid)return;
    for(int raw=0;raw<2047;raw++){double fixedRefX=((raw-(4.0*constShift))/4.0)-0.375;double metric=fixedRefX*referencePixelSize;double denominator=emitterDistance-metric;if(Math.abs(denominator)<1e-9)continue;double mm=10.0*((metric*referenceDistance/denominator)+referenceDistance);if(Double.isFinite(mm)&&mm>=1.0&&mm<=10000.0)factoryDepthRawToMm[raw]=(int)Math.round(mm);}
    factoryDepthRawToMm[2047]=0;metricDepthCalibrated=true;
  }

  void readFrame(LocalTransport input,int sessionMask)throws IOException{
    input.readFully(frameHeaderBuffer);
    ByteBuffer h=ByteBuffer.wrap(frameHeaderBuffer).order(ByteOrder.LITTLE_ENDIAN);
    int magic=h.getInt(), version=h.getInt(), mode=h.getInt(), w=h.getInt(), hh=h.getInt(), fmt=h.getInt(), bytes=h.getInt(), flags=h.getInt();
    long frameNumber=h.getLong(), tickMs=h.getLong();
    MotionSample motion=new MotionSample();
    motion.flags=h.getInt(); motion.accelX=h.getInt(); motion.accelY=h.getInt(); motion.accelZ=h.getInt(); motion.tiltTenths=h.getInt(); motion.timestampMs=h.getLong();

    if(magic!=studio.services.scannerProtocol.FRAME_MAGIC) throw new IOException("frame/magic");
    if(version!=studio.services.scannerProtocol.VERSION) throw new IOException("frame/version:"+version);
    if(w!=scannerExpectedWidthForMode(mode)||hh!=scannerExpectedHeightForMode(mode)) throw new IOException("frame/dimensions:"+mode+":"+w+"x"+hh);
    int modeMask=scannerMaskForMode(mode);
    if(modeMask==0 || (sessionMask&modeMask)==0) throw new IOException("frame/mode:"+mode);
    if(bytes<0||bytes>negotiatedMaxPayload||bytes>studio.services.scannerProtocol.MAX_PAYLOAD_BYTES) throw new IOException("frame/payload:"+bytes);
    if((flags&~studio.services.scannerProtocol.KNOWN_FRAME_FLAGS)!=0) throw new IOException("frame/flags:0x"+Integer.toHexString(flags));
    boolean dropOutOfOrder=lastFrameNumber[mode]>=0 && frameNumber<=lastFrameNumber[mode];
    if(lastFrameNumber[mode]>=0 && frameNumber>lastFrameNumber[mode]+1){
      long missed=frameNumber-lastFrameNumber[mode]-1;
      if(mode==studio.services.scannerProtocol.MODE_DEPTH)depthSequenceGaps+=missed;else colorSequenceGaps+=missed;
    }
    if(!scannerFormatAllowedForMode(mode,fmt)) throw new IOException("frame/format:"+mode+"/"+fmt);
    if(!scannerPayloadAllowedForMode(mode,fmt,bytes)) throw new IOException("frame/size:"+mode+"/"+fmt+"/"+bytes);

    byte[] payload=mode==studio.services.scannerProtocol.MODE_DEPTH
      ? depthPackedPayloadBuffer
      : new byte[bytes];
    input.readFully(payload);
    long arrival=monotonicMs(); lastAnyArrivalMs=arrival; deviceConnected=true;
    if(dropOutOfOrder){
      lastTransportError=i18n.format("transport.error","frame-order");
      return;
    }
    lastFrameNumber[mode]=frameNumber;
    lastTransportError="";

    if(mode==studio.services.scannerProtocol.MODE_DEPTH){
      DepthFrame f=new DepthFrame();
      f.frameId=(int)(frameNumber&0x7FFFFFFF); f.frameNumber=frameNumber; f.timestampUs=tickMs*1000L;
      f.width=studio.services.scannerProtocol.WIDTH; f.height=studio.services.scannerProtocol.HEIGHT; f.stride=studio.services.scannerProtocol.WIDTH*2; f.pixelFormat=studio.services.scannerProtocol.DEPTH_FRAME_MM16;
      f.depth=new short[studio.services.scannerProtocol.WIDTH*studio.services.scannerProtocol.HEIGHT]; f.motion=motion; latestMotion=motion;
      f.deviceCalibrated=factoryDepthCalibrationValid;
      f.transportRecovered=(flags&studio.services.scannerProtocol.FLAG_FRAME_RECOVERED)!=0;
      int valid=0, plausible=0,srcIndex=0,bitsIn=0; long bitBuffer=0L;
      for(int i=0;i<f.depth.length;i++){
        int raw;
        while(bitsIn<11){bitBuffer=(bitBuffer<<8)|(payload[srcIndex++]&0xFFL);bitsIn+=8;}
        bitsIn-=11;raw=(int)((bitBuffer>>bitsIn)&0x7FFL);
        if(bitsIn==0)bitBuffer=0L;else bitBuffer&=(1L<<bitsIn)-1L;
        int mm=(raw>=0&&raw<factoryDepthRawToMm.length)?factoryDepthRawToMm[raw]:0;f.depth[i]=(short)(mm&0xFFFF);
        if(mm!=0) valid++;
        if(mm>=config.depthPlausibleMinMm && mm<=config.depthPlausibleMaxMm) plausible++;
      }
      f.validCount=valid; f.plausibleCount=plausible;
      float ratio=plausible/(float)f.depth.length;
      depthConnected=f.deviceCalibrated && plausible>=config.depthMinValidPixels && ratio>=config.depthMinValidRatio;
      metricDepthCalibrated=factoryDepthCalibrationValid; lastDepthRecovered=f.transportRecovered;
      depthWarning = depthConnected ? "" : i18n.format(f.deviceCalibrated ? "transport.depth_sparse" : "transport.depth_uncalibrated", plausible, ratio*100.0f);
      offerDepth(f);
      depthFrames++; lastDepthArrivalMs=arrival;
    } else if(mode==studio.services.scannerProtocol.MODE_RGB) {
      float q=RgbFrameQuality.score(payload,w,hh,fmt);
      offerRgb(new RawRgbFrame(payload,w,hh,fmt,frameNumber,tickMs*1000L,q));
      colorConnected=true; colorFrames++; lastColorArrivalMs=arrival;
    } else if(mode==studio.services.scannerProtocol.MODE_RGB_HQ) {
      float q=RgbFrameQuality.score(payload,w,hh,fmt);
      offerHqRgb(new RawRgbFrame(payload,w,hh,fmt,frameNumber,tickMs*1000L,q));
      colorConnected=true; lastColorArrivalMs=arrival;
    }
  }

  boolean decodeNv12ToArgb(byte[] data,int w,int h,int[] out){
    if(data==null||out==null||data.length!=w*h*3/2||out.length<w*h)return false;
    int ySize=w*h;
    for(int y=0;y<h;y++){
      int row=y*w,uvRow=ySize+(y/2)*w;
      for(int x=0;x<w;x++){
        int yi=data[row+x]&0xFF,uv=uvRow+(x&~1),u=(data[uv]&0xFF)-128,v=(data[uv+1]&0xFF)-128;
        int c=max(0,yi-16),rr=(298*c+409*v+128)>>8,gg=(298*c-100*u-208*v+128)>>8,bb=(298*c+516*u+128)>>8;
        out[row+x]=0xFF000000|(constrain(rr,0,255)<<16)|(constrain(gg,0,255)<<8)|constrain(bb,0,255);
      }
    }
    return true;
  }

  String displayError(){
    if(lastTransportError.length()>0)return i18n.tr("transport.unavailable");
    if(droppedRgbdPairs>0)return i18n.format("transport.pairs_dropped",droppedRgbdPairs);
    return depthWarning;
  }
  String safeMessage(Exception e){ String m=e.getMessage(); return(m==null||m.length()==0)?e.getClass().getSimpleName():m; }
}


// ===== SynKinect Studio / 3D Scanner / Localization.pde =====
class I18n extends ModuleI18n {
  I18n(String requested){super("scanner",requested);}
}


class UiTheme {
  // Shared panel policy: high-contrast dark surfaces with a restrained blue
  // status accent. Geometry and typography remain centralized here.
  final int BG = 0xFF11151A;
  final int SURFACE = 0xFF181E25;
  final int SURFACE_ALT = 0xFF202832;
  final int SURFACE_RAISED = 0xFF293440;
  final int BORDER = 0xFF35414D;
  final int TEXT = 0xFFF4F7FA;
  final int TEXT_MUTED = 0xFFAAB6C2;
  final int ACCENT = 0xFF68A9E8;
  final int ACCENT_SOFT = 0xFF203A52;
  final int GOOD = 0xFF7CC7A0;
  final int WARN = 0xFFE4B86B;
  final int BAD = 0xFFE17D7D;
  final int GRID = 0xFF35404A;
  final int PREVIEW = 0xFF0B0F13;
  final int MESH = 0xFFD6E5F3;
  final int RADIUS = 14;
  final int MARGIN = 20;
  final int GAP = 14;
  final int HEADER_H = 68;
  final int TOOLBAR_H = 122;
  final int SIDEBAR_W = 430;
  final int CARD_TITLE_H = 44;

  // Semantic type scale. No scanner panel should contain literal textSize values.
  final int FONT_TINY = 12;
  final int FONT_SMALL = 14;
  final int FONT_BODY = 15;
  final int FONT_METRIC = 19;
  final int FONT_TITLE = 27;
}

void initializeScannerTypography(){
  String regular="SansSerif";
  String heading="SansSerif";
  studio.scannerState.fontRegular=createFont(regular,studio.services.uiTheme.FONT_BODY,true);
  studio.scannerState.fontHeading=createFont(heading,studio.services.uiTheme.FONT_TITLE,true);
  textFont(studio.scannerState.fontRegular);
  textLeading(studio.services.uiTheme.FONT_BODY*1.28f);
}

String resolveInstalledFont(String preferred,String fallback){
  String[] installed=PFont.list();
  String hit=findFontIgnoreCase(installed,preferred);
  if(hit!=null)return hit;
  hit=findFontIgnoreCase(installed,fallback);
  return hit==null?"SansSerif":hit;
}

String findFontIgnoreCase(String[] installed,String wanted){
  if(wanted==null||wanted.trim().length()==0||installed==null)return null;
  String key=wanted.trim();
  for(String candidate:installed)if(candidate.equalsIgnoreCase(key))return candidate;
  return null;
}

void uiText(float size,boolean heading){
  PFont font=heading?studio.scannerState.fontHeading:studio.scannerState.fontRegular;
  if(font!=null)textFont(font);
  textSize(responsiveFontSize(size));
}


// ===== SynKinect Studio / 3D Scanner / Math3D.pde =====
class RigidTransform {
  float[] m = new float[16];

  RigidTransform() { setIdentity(); }

  void setIdentity() {
    Arrays.fill(m, 0);
    m[0] = m[5] = m[10] = m[15] = 1;
  }

  void set(RigidTransform o) { arrayCopy(o.m, m); }
  void setArray(float[] a) { for (int i = 0; i < 16; i++) m[i] = a[i]; }

  PVector apply(PVector p) {
    return new PVector(
      m[0]*p.x + m[1]*p.y + m[2]*p.z + m[3],
      m[4]*p.x + m[5]*p.y + m[6]*p.z + m[7],
      m[8]*p.x + m[9]*p.y + m[10]*p.z + m[11]
    );
  }

  PVector rotate(PVector p) {
    return new PVector(
      m[0]*p.x + m[1]*p.y + m[2]*p.z,
      m[4]*p.x + m[5]*p.y + m[6]*p.z,
      m[8]*p.x + m[9]*p.y + m[10]*p.z
    );
  }

  PVector translation() { return new PVector(m[3], m[7], m[11]); }

  RigidTransform multiply(RigidTransform b) {
    RigidTransform r = new RigidTransform();
    for (int row = 0; row < 4; row++) {
      for (int col = 0; col < 4; col++) {
        float s = 0;
        for (int k = 0; k < 4; k++) s += m[row*4+k] * b.m[k*4+col];
        r.m[row*4+col] = s;
      }
    }
    return r;
  }

  RigidTransform inverseRigid() {
    RigidTransform r=new RigidTransform();
    r.m[0]=m[0];r.m[1]=m[4];r.m[2]=m[8];
    r.m[4]=m[1];r.m[5]=m[5];r.m[6]=m[9];
    r.m[8]=m[2];r.m[9]=m[6];r.m[10]=m[10];
    r.m[3]=-(r.m[0]*m[3]+r.m[1]*m[7]+r.m[2]*m[11]);
    r.m[7]=-(r.m[4]*m[3]+r.m[5]*m[7]+r.m[6]*m[11]);
    r.m[11]=-(r.m[8]*m[3]+r.m[9]*m[7]+r.m[10]*m[11]);
    return r;
  }

  RigidTransform fromRotationTranslation(float[][] R, PVector t) {
    RigidTransform x = new RigidTransform();
    x.m[0]=R[0][0]; x.m[1]=R[0][1]; x.m[2]=R[0][2]; x.m[3]=t.x;
    x.m[4]=R[1][0]; x.m[5]=R[1][1]; x.m[6]=R[1][2]; x.m[7]=t.y;
    x.m[8]=R[2][0]; x.m[9]=R[2][1]; x.m[10]=R[2][2]; x.m[11]=t.z;
    return x;
  }
}

class QuaternionFit {
  RigidTransform fit(ArrayList<PVector> src, ArrayList<PVector> dst) {
    int n=min(src.size(),dst.size());if(n<3)return new RigidTransform();
    double csx=0,csy=0,csz=0,cdx=0,cdy=0,cdz=0;
    for(int i=0;i<n;i++){PVector a=src.get(i),b=dst.get(i);csx+=a.x;csy+=a.y;csz+=a.z;cdx+=b.x;cdy+=b.y;cdz+=b.z;}
    float inv=1.0f/n;float sx=(float)(csx*inv),sy=(float)(csy*inv),sz=(float)(csz*inv),dx=(float)(cdx*inv),dy=(float)(cdy*inv),dz=(float)(cdz*inv);
    float Sxx=0,Sxy=0,Sxz=0,Syx=0,Syy=0,Syz=0,Szx=0,Szy=0,Szz=0;
    for(int i=0;i<n;i++){
      PVector pa=src.get(i),pb=dst.get(i);float ax=pa.x-sx,ay=pa.y-sy,az=pa.z-sz,bx=pb.x-dx,by=pb.y-dy,bz=pb.z-dz;
      Sxx+=ax*bx;Sxy+=ax*by;Sxz+=ax*bz;Syx+=ay*bx;Syy+=ay*by;Syz+=ay*bz;Szx+=az*bx;Szy+=az*by;Szz+=az*bz;
    }
    float tr=Sxx+Syy+Szz;
    float n00=tr,n01=Syz-Szy,n02=Szx-Sxz,n03=Sxy-Syx;
    float n11=Sxx-Syy-Szz,n12=Sxy+Syx,n13=Szx+Sxz;
    float n22=-Sxx+Syy-Szz,n23=Syz+Szy,n33=-Sxx-Syy+Szz;
    float q0=1,q1=0,q2=0,q3=0;
    for(int it=0;it<32;it++){
      float a0=n00*q0+n01*q1+n02*q2+n03*q3;
      float a1=n01*q0+n11*q1+n12*q2+n13*q3;
      float a2=n02*q0+n12*q1+n22*q2+n23*q3;
      float a3=n03*q0+n13*q1+n23*q2+n33*q3;
      float norm=sqrt(a0*a0+a1*a1+a2*a2+a3*a3);if(norm<1e-9f)break;float ni=1.0f/norm;q0=a0*ni;q1=a1*ni;q2=a2*ni;q3=a3*ni;
    }
    float w=q0,x=q1,y=q2,z=q3;
    float r00=1-2*y*y-2*z*z,r01=2*x*y-2*z*w,r02=2*x*z+2*y*w;
    float r10=2*x*y+2*z*w,r11=1-2*x*x-2*z*z,r12=2*y*z-2*x*w;
    float r20=2*x*z-2*y*w,r21=2*y*z+2*x*w,r22=1-2*x*x-2*y*y;
    RigidTransform out=new RigidTransform();out.m[0]=r00;out.m[1]=r01;out.m[2]=r02;out.m[3]=dx-(r00*sx+r01*sy+r02*sz);out.m[4]=r10;out.m[5]=r11;out.m[6]=r12;out.m[7]=dy-(r10*sx+r11*sy+r12*sz);out.m[8]=r20;out.m[9]=r21;out.m[10]=r22;out.m[11]=dz-(r20*sx+r21*sy+r22*sz);return out;
  }
}

// ===== SynKinect Studio / 3D Scanner / Mesh.pde =====
class Triangle3D {
  PVector a,b,c,n;
  int ca,cb,cc;
  Triangle3D(PVector a,PVector b,PVector c){this(a,b,c,0,0,0);}
  Triangle3D(PVector a,PVector b,PVector c,int ca,int cb,int cc){this.a=a;this.b=b;this.c=c;this.ca=ca;this.cb=cb;this.cc=cc;recalc();}
  void recalc(){ n=PVector.sub(b,a).cross(PVector.sub(c,a)); if(n.magSq()>1e-12f)n.normalize(); }
  PVector center(){ return new PVector((a.x+b.x+c.x)/3,(a.y+b.y+c.y)/3,(a.z+b.z+c.z)/3); }
}

class Mesh3D {
  ArrayList<Triangle3D> triangles=new ArrayList<Triangle3D>();
  ArrayList<PShape> renderChunks=new ArrayList<PShape>();
  int renderCursor=0;
  boolean renderCacheComplete=false;
 final int renderChunkTriangles=12000;

  void clear(){triangles.clear();invalidateRenderCache();}
  int triangleCount(){return triangles.size();}
  void addTriangle(PVector a,PVector b,PVector c){addTriangle(a,b,c,0,0,0);}
  void addTriangle(PVector a,PVector b,PVector c,int ca,int cb,int cc){
    if(PVector.sub(b,a).cross(PVector.sub(c,a)).magSq()>1e-12f) triangles.add(new Triangle3D(a,b,c,ca,cb,cc));
  }
  void recalculateNormals(){for(Triangle3D t:triangles)t.recalc();invalidateRenderCache();}
  void invalidateRenderCache(){renderChunks.clear();renderCursor=0;renderCacheComplete=triangles.size()==0;}

  Mesh3D deepCopy(){
    Mesh3D copy=new Mesh3D();
    for(Triangle3D t:triangles) copy.addTriangle(t.a.copy(),t.b.copy(),t.c.copy(),t.ca,t.cb,t.cc);
    return copy;
  }

  PVector boundsCenter(){
    if(triangles.size()==0) return new PVector();
    float minX=Float.POSITIVE_INFINITY,minY=Float.POSITIVE_INFINITY,minZ=Float.POSITIVE_INFINITY;
    float maxX=Float.NEGATIVE_INFINITY,maxY=Float.NEGATIVE_INFINITY,maxZ=Float.NEGATIVE_INFINITY;
    for(Triangle3D t:triangles){
      PVector[] v={t.a,t.b,t.c};
      for(PVector p:v){ minX=min(minX,p.x); minY=min(minY,p.y); minZ=min(minZ,p.z); maxX=max(maxX,p.x); maxY=max(maxY,p.y); maxZ=max(maxZ,p.z); }
    }
    return new PVector((minX+maxX)*0.5f,(minY+maxY)*0.5f,(minZ+maxZ)*0.5f);
  }

  float boundsRadius(){
    if(triangles.size()==0) return 0.2f;
    PVector c=boundsCenter();
    float r=0.0f;
    for(Triangle3D t:triangles){
      r=max(r,max(PVector.dist(c,t.a),max(PVector.dist(c,t.b),PVector.dist(c,t.c))));
    }
    return max(r,0.01f);
  }

  int renderColor(int c,int fallback){ return ((c>>>24)&255)==0 ? fallback : c; }

  void buildNextRenderChunk(int fallbackShade){
    if(renderCacheComplete)return;
    int end=min(triangles.size(),renderCursor+renderChunkTriangles);
    if(end<=renderCursor){renderCacheComplete=true;return;}
    PShape chunk=createShape();
    chunk.beginShape(TRIANGLES);chunk.noStroke();
    for(int i=renderCursor;i<end;i++){
      Triangle3D t=triangles.get(i);
      chunk.normal(t.n.x,t.n.y,t.n.z);
      chunk.fill(renderColor(t.ca,fallbackShade));chunk.vertex(t.a.x,t.a.y,t.a.z);
      chunk.fill(renderColor(t.cb,fallbackShade));chunk.vertex(t.b.x,t.b.y,t.b.z);
      chunk.fill(renderColor(t.cc,fallbackShade));chunk.vertex(t.c.x,t.c.y,t.c.z);
    }
    chunk.endShape();renderChunks.add(chunk);renderCursor=end;renderCacheComplete=renderCursor>=triangles.size();
  }

  void drawMesh(int shade){
    if(triangles.size()==0)return;
    // Retained PShape chunks are compiled incrementally on the render thread.
    // Heavy mesh extraction/polish runs elsewhere; after this cache is warm no
    // triangle list is rebuilt every frame.
    if(!renderCacheComplete)buildNextRenderChunk(shade);
    for(PShape chunk:renderChunks)shape(chunk);
  }
}


// ===== SynKinect Studio / 3D Scanner / MeshEditing.pde =====
class MeshEditor {
 final AppConfig cfg;
  MeshEditor(AppConfig cfg){ this.cfg=cfg; }

  Mesh3D clean(Mesh3D source){
    Mesh3D filtered=new Mesh3D();
    if(source==null)return filtered;
    for(Triangle3D t:source.triangles){
      float ab=PVector.dist(t.a,t.b),bc=PVector.dist(t.b,t.c),ca=PVector.dist(t.c,t.a);
      float area=PVector.sub(t.b,t.a).cross(PVector.sub(t.c,t.a)).mag()*0.5f;
      if(area<cfg.meshCleanupMinAreaM2)continue;
      if(max(ab,max(bc,ca))>cfg.meshCleanupMaxEdgeM)continue;
      filtered.addTriangle(t.a.copy(),t.b.copy(),t.c.copy(),t.ca,t.cb,t.cc);
    }
    Mesh3D components=removeSmallComponents(filtered);
    components.recalculateNormals();return components;
  }

  Mesh3D smooth(Mesh3D source){
    if(source==null)return new Mesh3D();
    Mesh3D work=source.deepCopy();
    for(int i=0;i<cfg.meshSmoothIterations;i++)smoothPass(work,cfg.meshSmoothLambda);
    work.recalculateNormals();return work;
  }

  Mesh3D polish(Mesh3D source){
    Mesh3D work=clean(source);
    // Taubin lambda/mu smoothing removes voxel stair-stepping without the
    // strong shrinkage of repeated plain Laplacian smoothing.
    for(int i=0;i<cfg.meshPolishIterations;i++){
      smoothPass(work,cfg.meshPolishLambda);
      smoothPass(work,cfg.meshPolishMu);
    }
    work.recalculateNormals();return work;
  }

  Mesh3D polishHighQuality(Mesh3D source){
    Mesh3D work=clean(source);
    for(int i=0;i<cfg.hqMeshPolishIterations;i++){smoothPass(work,cfg.hqMeshPolishLambda);smoothPass(work,cfg.hqMeshPolishMu);}
    work.recalculateNormals();return work;
  }

  void smoothPass(Mesh3D mesh,float factor){
    HashMap<Long,PVector> sum=new HashMap<Long,PVector>();
    HashMap<Long,Integer> count=new HashMap<Long,Integer>();
    HashMap<Long,HashSet<Long>> neighbors=new HashMap<Long,HashSet<Long>>();
    for(Triangle3D t:mesh.triangles){
      long ka=key(t.a),kb=key(t.b),kc=key(t.c);
      addVertex(sum,count,ka,t.a);addVertex(sum,count,kb,t.b);addVertex(sum,count,kc,t.c);
      connect(neighbors,ka,kb);connect(neighbors,kb,kc);connect(neighbors,kc,ka);
    }
    HashMap<Long,PVector> center=new HashMap<Long,PVector>(sum.size()*2);
    for(Long k:sum.keySet()){PVector p=sum.get(k).copy();p.div(max(1,count.get(k)));center.put(k,p);}
    HashMap<Long,PVector> moved=new HashMap<Long,PVector>(center.size()*2);
    for(Long k:center.keySet()){
      PVector base=center.get(k),avg=new PVector();int n=0;HashSet<Long> adj=neighbors.get(k);
      if(adj!=null)for(Long other:adj){PVector q=center.get(other);if(q!=null){avg.add(q);n++;}}
      if(n<2){moved.put(k,base.copy());continue;}
      avg.div(n);PVector delta=PVector.sub(avg,base);moved.put(k,PVector.add(base,PVector.mult(delta,factor)));
    }
    for(Triangle3D t:mesh.triangles){PVector a=moved.get(key(t.a)),b=moved.get(key(t.b)),c=moved.get(key(t.c));if(a!=null)t.a.set(a);if(b!=null)t.b.set(b);if(c!=null)t.c.set(c);}
  }

  Mesh3D removeSmallComponents(Mesh3D source){
    if(source==null||source.triangleCount()==0)return new Mesh3D();
    int n=source.triangleCount();
    HashMap<Long,ArrayList<Integer>> incidence=new HashMap<Long,ArrayList<Integer>>();
    for(int i=0;i<n;i++){
      Triangle3D t=source.triangles.get(i);addIncidence(incidence,key(t.a),i);addIncidence(incidence,key(t.b),i);addIncidence(incidence,key(t.c),i);
    }
    boolean[] seen=new boolean[n];ArrayList<ArrayList<Integer>> groups=new ArrayList<ArrayList<Integer>>();int largest=0;
    for(int seed=0;seed<n;seed++){
      if(seen[seed])continue;ArrayList<Integer> group=new ArrayList<Integer>();ArrayDeque<Integer> q=new ArrayDeque<Integer>();q.add(seed);seen[seed]=true;
      while(!q.isEmpty()){
        int i=q.removeFirst();group.add(i);Triangle3D t=source.triangles.get(i);long[] keys={key(t.a),key(t.b),key(t.c)};
        for(long k:keys){ArrayList<Integer> linked=incidence.get(k);if(linked==null)continue;for(Integer other:linked)if(!seen[other]){seen[other]=true;q.addLast(other);}}
      }
      groups.add(group);largest=max(largest,group.size());
    }
    int threshold=max(cfg.meshMinimumComponentTriangles,round(largest*cfg.meshMinimumComponentRatio));
    Mesh3D out=new Mesh3D();
    for(ArrayList<Integer> group:groups)if(group.size()>=threshold)for(Integer idx:group){Triangle3D t=source.triangles.get(idx);out.addTriangle(t.a.copy(),t.b.copy(),t.c.copy(),t.ca,t.cb,t.cc);}
    if(out.triangleCount()==0){
      ArrayList<Integer> best=null;for(ArrayList<Integer> group:groups)if(best==null||group.size()>best.size())best=group;
      if(best!=null)for(Integer idx:best){Triangle3D t=source.triangles.get(idx);out.addTriangle(t.a.copy(),t.b.copy(),t.c.copy(),t.ca,t.cb,t.cc);}
    }
    return out;
  }

  Mesh3D center(Mesh3D source){
    if(source==null)return new Mesh3D();
    Mesh3D out=source.deepCopy();PVector c=out.boundsCenter();
    for(Triangle3D t:out.triangles){t.a.sub(c);t.b.sub(c);t.c.sub(c);t.recalc();}out.invalidateRenderCache();return out;
  }

  long key(PVector p){
    float q=max(0.000001f,cfg.meshWeldToleranceM);long x=round(p.x/q),y=round(p.y/q),z=round(p.z/q);
    return ((x&0x1FFFFFL)<<42)|((y&0x1FFFFFL)<<21)|(z&0x1FFFFFL);
  }
  void addIncidence(HashMap<Long,ArrayList<Integer>> m,long k,int i){ArrayList<Integer> list=m.get(k);if(list==null){list=new ArrayList<Integer>();m.put(k,list);}list.add(i);}
  void addVertex(HashMap<Long,PVector> sum,HashMap<Long,Integer> count,long k,PVector p){PVector acc=sum.get(k);if(acc==null){acc=new PVector();sum.put(k,acc);count.put(k,0);}acc.add(p);count.put(k,count.get(k)+1);}
  void connect(HashMap<Long,HashSet<Long>> n,long a,long b){if(a==b)return;HashSet<Long> aa=n.get(a);if(aa==null){aa=new HashSet<Long>();n.put(a,aa);}aa.add(b);HashSet<Long> bb=n.get(b);if(bb==null){bb=new HashSet<Long>();n.put(b,bb);}bb.add(a);}
}


// ===== SynKinect Studio / 3D Scanner / PointCloud.pde =====
class PointCloudBuilder {
  AppConfig cfg;
  RgbDepthRegistration registration;
  final int[] neighborScratch=new int[8];
  final int[] medianScratch=new int[49];
  PointCloudBuilder(AppConfig cfg,RgbDepthRegistration registration) { this.cfg = cfg; this.registration=registration; }

  PointCloud build(DepthFrame f, Calibration c, int step, float targetZ, float band, PointCloudBuildStats stats, RgbSnapshot rgb) {
    if (stats != null) stats.clear();
    if (f == null || f.depth == null || c == null || !c.valid) return new PointCloud();
    int safeStep = max(1, step);
    int estimated=((f.width+safeStep-1)/safeStep)*((f.height+safeStep-1)/safeStep);
    PointCloud cloud = new PointCloud(estimated);
    boolean includeColor=cfg.meshColorEnabled&&registration!=null&&rgb!=null;
    if(includeColor) registration.prepareFrame(f,rgb);
    for (int v = 0; v < f.height; v += safeStep) {
      int row=v*f.width;
      for (int u = 0; u < f.width; u += safeStep) {
        if (stats != null) stats.sourcePixels++;
        int index=row+u;
        int raw = f.depth[index] & 0xFFFF;
        if (raw == 0) continue;
        if (stats != null) stats.nonZero++;
        int filteredMm=filteredDepthMm(f,u,v,raw,safeStep,c);
        if(filteredMm<=0){if(stats!=null)stats.rejectedSpatial++;continue;}
        float z = filteredMm * c.depthScale;
        if (z < cfg.minDepthM || z > cfg.maxDepthM) { if (stats != null) stats.rejectedRange++; continue; }
        if (stats != null) stats.inRange++;
        if (!Float.isNaN(targetZ) && abs(z - targetZ) > band) { if (stats != null) stats.rejectedBand++; continue; }
        float x = registration!=null ? registration.pointX(index,z) : (u-c.cx)*z/c.fx;
        float y = registration!=null ? registration.pointY(index,z) : (v-c.cy)*z/c.fy;
        int rgbColor = includeColor ? registration.colorAt(index,z) : 0;
        cloud.add(new PVector(x,y,z),rgbColor,c.depthConfidence(index,z));
        if (stats != null) stats.accepted++;
      }
    }
    return cloud;
  }

  int filteredDepthMm(DepthFrame f,int u,int v,int centerMm,int step){return filteredDepthMm(f,u,v,centerMm,step,null);}
  int filteredDepthMm(DepthFrame f,int u,int v,int centerMm,int step,Calibration calibration){
    int centerIndex=v*f.width+u;if(calibration!=null)centerMm=calibration.correctedDepthMm(centerIndex,centerMm);
    int toleranceMm=max(1,round(cfg.pointCloudNeighborToleranceM*1000.0f));
    int n=0;
    for(int dy=-step;dy<=step;dy+=step)for(int dx=-step;dx<=step;dx+=step){
      if(dx==0&&dy==0)continue;
      int x=u+dx,y=v+dy;
      if(x<0||x>=f.width||y<0||y>=f.height)continue;
      int ni=y*f.width+x,mm=f.depth[ni]&0xffff;if(calibration!=null&&mm!=0)mm=calibration.correctedDepthMm(ni,mm);
      if(mm!=0)neighborScratch[n++]=mm;
    }

    int filtered=centerMm;
    if(n>=3){
      sortSmall(neighborScratch,n);
      int median=neighborScratch[n/2],coherent=0;
      for(int i=0;i<n;i++)if(abs(neighborScratch[i]-median)<=toleranceMm)coherent++;
      int majority=max(3,(n*5+7)/8); // ceil(n * 0.625)
      if(coherent>=majority){
        if(abs(centerMm-median)>toleranceMm)filtered=median;
        else{
          int m=0;medianScratch[m++]=centerMm;
          for(int i=0;i<n;i++)if(abs(neighborScratch[i]-median)<=toleranceMm)medianScratch[m++]=neighborScratch[i];
          sortSmall(medianScratch,m);filtered=medianScratch[m/2];
        }
      }
    }

    if(cfg.pointCloudSpatialFilter&&n>2){
      int consistent=0;
      for(int i=0;i<n;i++)if(abs(neighborScratch[i]-filtered)<=toleranceMm)consistent++;
      if(consistent<max(2,(n+1)/2))return -1;
    }
    return filtered;
  }

  PointCloud buildHighQuality(DepthFrame f, Calibration c, float targetZ, float band, RgbSnapshot rgb) {
    if (f == null || f.depth == null || c == null || !c.valid) return new PointCloud();
    int step=max(1,cfg.hqIntegrationStep);
    int estimated=((f.width+step-1)/step)*((f.height+step-1)/step);
    PointCloud cloud=new PointCloud(estimated);
    boolean includeColor=cfg.meshColorEnabled&&registration!=null&&rgb!=null;
    if(includeColor)registration.prepareFrame(f,rgb);
    for(int v=0;v<f.height;v+=step){
      int row=v*f.width;
      for(int u=0;u<f.width;u+=step){
        int index=row+u,raw=f.depth[index]&0xffff;
        int filteredMm=filteredDepthMmHighQuality(f,u,v,raw,c);
        if(filteredMm<=0)continue;
        float z=filteredMm*c.depthScale;
        if(z<cfg.minDepthM||z>cfg.maxDepthM)continue;
        if(!Float.isNaN(targetZ)&&abs(z-targetZ)>band)continue;
        float x=registration!=null?registration.pointX(index,z):(u-c.cx)*z/c.fx;
        float y=registration!=null?registration.pointY(index,z):(v-c.cy)*z/c.fy;
        int color=includeColor?registration.colorAt(index,z):0;
        cloud.add(new PVector(x,y,z),color,c.depthConfidence(index,z));
      }
    }
    return cloud;
  }

  int filteredDepthMmHighQuality(DepthFrame f,int u,int v,int centerMm){return filteredDepthMmHighQuality(f,u,v,centerMm,null);}
  int filteredDepthMmHighQuality(DepthFrame f,int u,int v,int centerMm,Calibration calibration){
    int centerIndex=v*f.width+u;if(calibration!=null&&centerMm!=0)centerMm=calibration.correctedDepthMm(centerIndex,centerMm);
    int radius=max(1,cfg.hqDepthFilterRadius),tolerance=max(1,round(cfg.hqDepthEdgeToleranceM*1000.0f));
    int n=0;
    for(int dy=-radius;dy<=radius;dy++)for(int dx=-radius;dx<=radius;dx++){
      int x=u+dx,y=v+dy;if(x<0||x>=f.width||y<0||y>=f.height)continue;
      int ni=y*f.width+x,mm=f.depth[ni]&0xffff;if(mm==0)continue;if(calibration!=null)mm=calibration.correctedDepthMm(ni,mm);
      if(centerMm==0||abs(mm-centerMm)<=tolerance)medianScratch[n++]=mm;
    }
    if(centerMm==0){
      if(n<cfg.hqHoleFillMinimumNeighbors)return -1;
      sortSmall(medianScratch,n);int median=medianScratch[n/2],coherent=0;
      for(int i=0;i<n;i++)if(abs(medianScratch[i]-median)<=tolerance)coherent++;
      if(coherent<cfg.hqHoleFillMinimumNeighbors)return -1;
      return median;
    }
    if(n<3)return centerMm;
    sortSmall(medianScratch,n);
    int median=medianScratch[n/2];
    // Edge-aware median: only samples already close to the center are present,
    // so this suppresses structured-light speckle without bleeding across depth edges.
    return abs(median-centerMm)<=tolerance?median:centerMm;
  }

  void sortSmall(int[] values,int count){
    for(int i=1;i<count;i++){
      int value=values[i],j=i-1;
      while(j>=0&&values[j]>value){values[j+1]=values[j];j--;}
      values[j+1]=value;
    }
  }
}

class PointCloud {
  ArrayList<PVector> points;
  int[] colors;float[] confidence;
  PointCloud(){this(4096);}
  PointCloud(int capacity){int safe=max(16,capacity);points=new ArrayList<PVector>(safe);colors=new int[safe];confidence=new float[safe];Arrays.fill(confidence,1.0f);}
  int size() { return points.size(); }
  void add(PVector p,int c){add(p,c,1.0f);}
  void add(PVector p,int c,float q){
    int index=points.size();points.add(p);
    if(index>=colors.length){int next=max(index+1,colors.length*2);colors=Arrays.copyOf(colors,next);confidence=Arrays.copyOf(confidence,next);}
    colors[index]=c;confidence[index]=constrain(q,0.05f,1.0f);
  }
  int colorAt(int i){return i>=0&&i<points.size()?colors[i]:0;}
  float confidenceAt(int i){return i>=0&&i<points.size()?confidence[i]:1.0f;}

  PVector centroid() {
    PVector c = new PVector(); if (points.size() == 0) return c;
    for (PVector p : points) c.add(p); return c.div(points.size());
  }
  PVector centroidTransformed(RigidTransform t) {
    if(points.isEmpty())return new PVector();
    double sx=0,sy=0,sz=0;float[] m=t.m;
    for(PVector p:points){sx+=m[0]*p.x+m[1]*p.y+m[2]*p.z+m[3];sy+=m[4]*p.x+m[5]*p.y+m[6]*p.z+m[7];sz+=m[8]*p.x+m[9]*p.y+m[10]*p.z+m[11];}
    float inv=1.0f/points.size();return new PVector((float)(sx*inv),(float)(sy*inv),(float)(sz*inv));
  }
  PointCloud transformed(RigidTransform t, int maxPoints) {
    int limit=max(1,maxPoints),stride=max(1,(points.size()+limit-1)/limit);
    PointCloud out = new PointCloud(min(points.size(),limit)+1);
    for (int i = 0; i < points.size(); i += stride) out.add(t.apply(points.get(i)),colorAt(i),confidenceAt(i)); return out;
  }
}

class SpatialHash {
  float cell;
  HashMap<Long, ArrayList<PVector>> buckets;
  SpatialHash(float cell,int expectedPoints) { this.cell = max(0.000001f, cell);buckets=new HashMap<Long,ArrayList<PVector>>(max(16,expectedPoints*2)); }

  long key(int x,int y,int z) {
    long a=((long)x & 0x1FFFFF), b=((long)y & 0x1FFFFF), c=((long)z & 0x1FFFFF);
    return (a<<42)|(b<<21)|c;
  }
  int cellCoord(float v){ return floor(v/cell); }
  void add(PVector p) {
    long k=key(cellCoord(p.x),cellCoord(p.y),cellCoord(p.z)); ArrayList<PVector> list=buckets.get(k);
    if(list==null){ list=new ArrayList<PVector>(); buckets.put(k,list); } list.add(p);
  }

  PVector nearest(PVector p,float maxDist) {
    int cx=cellCoord(p.x), cy=cellCoord(p.y), cz=cellCoord(p.z);
    int radius=max(1, ceil(maxDist/cell));
    PVector best=null; float best2=maxDist*maxDist;
    for(int dz=-radius;dz<=radius;dz++) for(int dy=-radius;dy<=radius;dy++) for(int dx=-radius;dx<=radius;dx++) {
      ArrayList<PVector> list=buckets.get(key(cx+dx,cy+dy,cz+dz));
      if(list==null) continue;
      for(PVector q:list){float qx=p.x-q.x,qy=p.y-q.y,qz=p.z-q.z,d2=qx*qx+qy*qy+qz*qz;if(d2<best2){best2=d2;best=q;}}
    }
    return best;
  }
}

// ===== SynKinect Studio / 3D Scanner / RgbRegistration.pde =====
class RgbProjection { float u,v,z;boolean valid; }

class RgbDepthRegistration {
  final AppConfig cfg;final Calibration depth;
  float[] rayX,rayY,rgbZBuffer;
  int preparedFrameId=-1;long preparedRgbFrameNumber=-1;int prepareCount=0;
  DepthFrame preparedDepth=null;RgbSnapshot preparedRgb=null;
  final RgbProjection sampleProjection=new RgbProjection();
  final float[] refineX=new float[4096],refineY=new float[4096];
  volatile float autoOffsetX=0.0f,autoOffsetY=0.0f,lastSyncSkewMs=Float.NaN,lastRefineGain=1.0f;volatile int lastRefineEdges=0;
  float projectionScaleX=1.0f,projectionScaleY=1.0f;

  RgbDepthRegistration(AppConfig cfg,Calibration depth){this.cfg=cfg;this.depth=depth;rebuildDepthRays();}
  void rebuildDepthRays(){
    int count=studio.services.scannerProtocol.WIDTH*studio.services.scannerProtocol.HEIGHT;rayX=new float[count];rayY=new float[count];
    for(int v=0;v<studio.services.scannerProtocol.HEIGHT;v++)for(int u=0;u<studio.services.scannerProtocol.WIDTH;u++){
      float xd=(u-depth.cx)/depth.fx,yd=(v-depth.cy)/depth.fy,x=xd,y=yd;
      for(int it=0;it<5;it++){float r2=x*x+y*y,r4=r2*r2,r6=r4*r2,radial=1.0f+cfg.depthK1*r2+cfg.depthK2*r4+cfg.depthK3*r6;if(abs(radial)<1e-6f)break;float ddx=2.0f*cfg.depthP1*x*y+cfg.depthP2*(r2+2.0f*x*x),ddy=cfg.depthP1*(r2+2.0f*y*y)+2.0f*cfg.depthP2*x*y;x=(xd-ddx)/radial;y=(yd-ddy)/radial;}
      int i=v*studio.services.scannerProtocol.WIDTH+u;rayX[i]=x;rayY[i]=y;
    }
  }
  float pointX(int index,float z){return rayX[index]*z;}float pointY(int index,float z){return rayY[index]*z;}
  void project(int index,float z,RgbProjection out,float extraX,float extraY){projectPoint(rayX[index]*z,rayY[index]*z,z,out,extraX,extraY);}
  void projectPoint(float xd,float yd,float zd,RgbProjection out,float extraX,float extraY){
    float xc=cfg.regR00*xd+cfg.regR01*yd+cfg.regR02*zd+cfg.regTx,yc=cfg.regR10*xd+cfg.regR11*yd+cfg.regR12*zd+cfg.regTy,zc=cfg.regR20*xd+cfg.regR21*yd+cfg.regR22*zd+cfg.regTz;
    if(zc<=0.001f){out.valid=false;return;}float x=xc/zc,y=yc/zc,r2=x*x+y*y,r4=r2*r2,r6=r4*r2,radial=1.0f+cfg.rgbK1*r2+cfg.rgbK2*r4+cfg.rgbK3*r6;
    float xDist=x*radial+2.0f*cfg.rgbP1*x*y+cfg.rgbP2*(r2+2.0f*x*x),yDist=y*radial+cfg.rgbP1*(r2+2.0f*y*y)+2.0f*cfg.rgbP2*x*y;
    float nominalU=cfg.rgbFx*xDist+cfg.rgbCx+cfg.colorRegistrationOffsetX+autoOffsetX+extraX,nominalV=cfg.rgbFy*yDist+cfg.rgbCy+cfg.colorRegistrationOffsetY+autoOffsetY+extraY;
    out.u=nominalU*projectionScaleX;out.v=nominalV*projectionScaleY;out.z=zc;out.valid=true;
  }
  void clearPreparedFrame(){preparedFrameId=-1;preparedRgbFrameNumber=-1;preparedDepth=null;preparedRgb=null;}
  void prepareFrame(DepthFrame frame,RgbSnapshot rgb){
    if(frame==null||frame.depth==null||rgb==null||rgb.pixels==null){clearPreparedFrame();return;}
    if(preparedFrameId==frame.frameId&&preparedRgbFrameNumber==rgb.frameNumber&&preparedRgb==rgb)return;
    prepareCount++;projectionScaleX=rgb.width/(float)studio.services.scannerProtocol.WIDTH;projectionScaleY=rgb.height/(float)studio.services.scannerProtocol.HEIGHT;
    lastSyncSkewMs=Float.isNaN(rgb.syncResidualMs)?Math.abs(frame.timestampUs-rgb.timestampUs)/1000.0f:rgb.syncResidualMs;
    if(lastSyncSkewMs>rgb.syncToleranceMs){clearPreparedFrame();return;}
    if(cfg.rgbAutoRefine&&cfg.rgbRefineSearchPx>0&&(prepareCount%cfg.rgbRefineEveryFrames)==0)refineFineOffset(frame,rgb);
    int depthPixels=frame.width*frame.height;
    if(cfg.rgbOcclusionFilter){
      int rgbPixels=rgb.width*rgb.height;if(rgbZBuffer==null||rgbZBuffer.length!=rgbPixels)rgbZBuffer=new float[rgbPixels];Arrays.fill(rgbZBuffer,Float.POSITIVE_INFINITY);RgbProjection q=new RgbProjection();
      for(int i=0;i<depthPixels;i++){int mm=frame.depth[i]&0xffff;if(mm==0)continue;mm=depth.correctedDepthMm(i,mm);float z=mm*depth.depthScale;if(z<cfg.minDepthM||z>cfg.maxDepthM)continue;project(i,z,q,0,0);if(!q.valid)continue;int x=round(q.u),y=round(q.v);if(x<0||x>=rgb.width||y<0||y>=rgb.height)continue;int ri=y*rgb.width+x;if(q.z<rgbZBuffer[ri])rgbZBuffer[ri]=q.z;}
    }
    preparedDepth=frame;preparedRgb=rgb;preparedFrameId=frame.frameId;preparedRgbFrameNumber=rgb.frameNumber;
  }
  int colorAt(int index,float z){
    RgbSnapshot rgb=preparedRgb;if(preparedFrameId<0||rgb==null||preparedDepth==null||index<0||index>=preparedDepth.depth.length)return 0;
    project(index,z,sampleProjection,0,0);return colorFromPreparedProjection(rgb,sampleProjection);
  }
  int colorAtPoint(float x,float y,float z){
    RgbSnapshot rgb=preparedRgb;if(preparedFrameId<0||rgb==null||preparedDepth==null)return 0;
    projectPoint(x,y,z,sampleProjection,0,0);return colorFromPreparedProjection(rgb,sampleProjection);
  }
  int colorFromPreparedProjection(RgbSnapshot rgb,RgbProjection q){
    if(!q.valid||q.u<0||q.v<0||q.u>rgb.width-1.001f||q.v>rgb.height-1.001f)return 0;
    if(cfg.rgbOcclusionFilter&&rgbZBuffer!=null){int zx=constrain(round(q.u),0,rgb.width-1),zy=constrain(round(q.v),0,rgb.height-1);float front=rgbZBuffer[zy*rgb.width+zx];if(Float.isFinite(front)&&q.z>front+cfg.rgbOcclusionToleranceM)return 0;}
    return sampleBilinearWeighted(rgb,q.u,q.v,lastSyncSkewMs);
  }
  int sampleBilinearWeighted(RgbSnapshot rgb,float u,float v,float syncMs){
    int x0=floor(u),y0=floor(v),x1=min(rgb.width-1,x0+1),y1=min(rgb.height-1,y0+1);float fx=u-x0,fy=v-y0;int c00=rgb.pixels[y0*rgb.width+x0],c10=rgb.pixels[y0*rgb.width+x1],c01=rgb.pixels[y1*rgb.width+x0],c11=rgb.pixels[y1*rgb.width+x1];
    float r0=lerp((c00>>16)&255,(c10>>16)&255,fx),r1=lerp((c01>>16)&255,(c11>>16)&255,fx),g0=lerp((c00>>8)&255,(c10>>8)&255,fx),g1=lerp((c01>>8)&255,(c11>>8)&255,fx),b0=lerp(c00&255,c10&255,fx),b1=lerp(c01&255,c11&255,fx);
    int r=constrain(round(lerp(r0,r1,fy)),0,255),g=constrain(round(lerp(g0,g1,fy)),0,255),b=constrain(round(lerp(b0,b1,fy)),0,255),luma=(77*r+150*g+29*b)>>8;float exposure=1.0f;
    if(luma<cfg.rgbExposureLowLuma)exposure=max(0.05f,luma/(float)max(1,cfg.rgbExposureLowLuma));else if(luma>cfg.rgbExposureHighLuma)exposure=max(0.05f,(255-luma)/(float)max(1,255-cfg.rgbExposureHighLuma));float sync=1.0f-constrain(syncMs/max(1.0f,rgb.syncToleranceMs),0.0f,1.0f),quality=constrain(exposure*(0.35f+0.65f*sync)*rgb.frameQuality,0.05f,1.0f);int alpha=constrain(round(quality*255.0f),1,255);return(alpha<<24)|(r<<16)|(g<<8)|b;
  }
  void refineFineOffset(DepthFrame frame,RgbSnapshot rgb){
    int count=0,step=max(2,cfg.rgbRefineSampleStep),threshold=cfg.rgbRefineEdgeThresholdMm;RgbProjection q=new RgbProjection();
    for(int v=step;v<frame.height-step&&count<refineX.length;v+=step)for(int u=step;u<frame.width-step&&count<refineX.length;u+=step){int i=v*frame.width+u,mm=frame.depth[i]&0xffff;if(mm==0)continue;mm=depth.correctedDepthMm(i,mm);int ri=v*frame.width+min(frame.width-1,u+step),di=min(frame.height-1,v+step)*frame.width+u,mr=frame.depth[ri]&0xffff,md=frame.depth[di]&0xffff;if(mr!=0)mr=depth.correctedDepthMm(ri,mr);if(md!=0)md=depth.correctedDepthMm(di,md);boolean edge=(mr!=0&&abs(mr-mm)>=threshold)||(md!=0&&abs(md-mm)>=threshold);if(!edge)continue;float z=mm*depth.depthScale;if(z<cfg.minDepthM||z>cfg.maxDepthM)continue;project(i,z,q,0,0);if(!q.valid||q.u<3||q.v<3||q.u>=rgb.width-3||q.v>=rgb.height-3)continue;refineX[count]=q.u;refineY[count]=q.v;count++;}
    lastRefineEdges=count;if(count<cfg.rgbRefineMinimumEdges){lastRefineGain=1.0f;return;}int search=cfg.rgbRefineSearchPx,bestDx=0,bestDy=0;double base=0,best=-1;
    for(int dy=-search;dy<=search;dy++)for(int dx=-search;dx<=search;dx++){double score=0;for(int i=0;i<count;i++)score+=rgbGradient(rgb,round(refineX[i])+dx,round(refineY[i])+dy);if(dx==0&&dy==0)base=score;if(score>best){best=score;bestDx=dx;bestDy=dy;}}
    lastRefineGain=(float)(best/Math.max(1.0,base));if((bestDx!=0||bestDy!=0)&&best>base*1.01){autoOffsetX=constrain(autoOffsetX+bestDx*cfg.rgbRefineAlpha,-cfg.rgbRefineMaxOffsetPx,cfg.rgbRefineMaxOffsetPx);autoOffsetY=constrain(autoOffsetY+bestDy*cfg.rgbRefineAlpha,-cfg.rgbRefineMaxOffsetPx,cfg.rgbRefineMaxOffsetPx);}
  }
  int rgbGradient(RgbSnapshot rgb,int x,int y){if(x<1||x>=rgb.width-1||y<1||y>=rgb.height-1)return 0;int lx=luma(rgb.pixels[y*rgb.width+x-1]),rx=luma(rgb.pixels[y*rgb.width+x+1]),uy=luma(rgb.pixels[(y-1)*rgb.width+x]),dy=luma(rgb.pixels[(y+1)*rgb.width+x]);return abs(rx-lx)+abs(dy-uy);}int luma(int c){int r=(c>>16)&255,g=(c>>8)&255,b=c&255;return(77*r+150*g+29*b)>>8;}
}

// ===== SynKinect Studio / 3D Scanner / ScanCoverage.pde =====
class ScanCoverageTracker {
 final AppConfig cfg;
  PVector gravityReference = null;
  PVector previousHeading = null;
  float directionProbeDeg = 0;
  int direction = 0;
  float sweepDeg = 0;
  float imuDeviationDeg = 0;
  boolean imuStable = true;
  boolean objectDetected = false;
  boolean complete = false;

  ScanCoverageTracker(AppConfig cfg){ this.cfg=cfg; }

  void reset(){
    gravityReference=null; previousHeading=null; directionProbeDeg=0; direction=0;
    sweepDeg=0; imuDeviationDeg=0; imuStable=true; objectDetected=false; complete=false;
  }

  void updateDetection(boolean detected){ objectDetected=detected; }

  void update(RigidTransform pose, MotionSample motion){
    updateImu(motion);
    if(pose==null || complete) return;
    PVector axis = gravityReference==null ? new PVector(0,1,0) : gravityReference.copy();
    if(axis.magSq()<1e-8f) axis.set(0,1,0);
    axis.normalize();

    PVector heading=pose.rotate(new PVector(0,0,1));
    heading.sub(PVector.mult(axis,heading.dot(axis)));
    if(heading.magSq()<1e-8f) return;
    heading.normalize();
    if(previousHeading==null){ previousHeading=heading; return; }

    float dot=constrain(previousHeading.dot(heading),-1.0f,1.0f);
    float signed=degrees(atan2(axis.dot(previousHeading.cross(heading)),dot));
    previousHeading=heading;
    if(abs(signed)<cfg.scanRotationDeadbandDeg || abs(signed)>cfg.scanRotationMaxStepDeg) return;

    if(direction==0){
      directionProbeDeg+=signed;
      if(abs(directionProbeDeg)>=cfg.scanDirectionLockDeg){
        direction=directionProbeDeg>=0?1:-1;
        sweepDeg=abs(directionProbeDeg);
      }
    }else{
      sweepDeg=max(0,sweepDeg+direction*signed);
    }
    if(sweepDeg>=cfg.scanCompleteDeg){ sweepDeg=min(cfg.scanFullTurnDeg,sweepDeg); complete=true; }
  }

  void updateImu(MotionSample motion){
    if(motion==null || !motion.gravityReliable()){ imuStable=true; imuDeviationDeg=0; return; }
    PVector g=motion.gravityUnit();
    if(g==null) return;
    if(gravityReference==null){ gravityReference=g.copy(); imuStable=true; imuDeviationDeg=0; return; }
    float c=constrain(gravityReference.dot(g),-1.0f,1.0f);
    imuDeviationDeg=degrees(acos(c));
    imuStable=imuDeviationDeg<=cfg.scanMaxSensorTiltDriftDeg;
  }

  float progress(){ return complete ? 1.0f : constrain(sweepDeg/max(1.0f,cfg.scanFullTurnDeg),0,1); }
}


// ===== SynKinect Studio / 3D Scanner / ScannerProtocol.pde =====
class ScannerProtocol {
  final int MAGIC = 0x43534D52;
  final int FRAME_MAGIC = 0x46534D52;
  final int VERSION = 1;
  final int CMD_SUBSCRIBE_STREAMS = 1;

  final int WIDTH = 640;
  final int HEIGHT = 480;
  final int RGB_HQ_WIDTH = 1280;
  final int RGB_HQ_HEIGHT = 1024;
  final int MODE_RGB = 0;
  final int MODE_DEPTH = 2;
  final int MODE_RGB_HQ = 3;
  final int STREAM_RGB = 1;
  final int STREAM_DEPTH = 4;
  final int STREAM_RGB_HQ = 8;
  final int STREAM_SESSION = STREAM_RGB | STREAM_DEPTH;
  final int STREAM_SESSION_HQ = STREAM_RGB | STREAM_DEPTH | STREAM_RGB_HQ;

  final int CAP_RGB_DEPTH_CONCURRENT = 1;
  final int CAP_EXCLUSIVE_VIDEO_MODE = 2;
  final int CAP_PROJECTOR_REFCOUNTED = 4;
  final int CAP_ACCELEROMETER = 8;
  final int CAP_RGB_HQ = 16;
  final int CAP_RAW_SENSOR_FRAMES = 64;
  final int CAP_PERSISTENT_ISO_SESSION = 128;
  final int REQUIRED_CAPABILITIES = CAP_RGB_DEPTH_CONCURRENT | CAP_EXCLUSIVE_VIDEO_MODE | CAP_PROJECTOR_REFCOUNTED | CAP_RAW_SENSOR_FRAMES;

  final int DEPTH_FRAME_MM16 = 1003;
  final int PIXEL_BAYER_GRBG8 = 4;
  final int PIXEL_IR_RAW10_PACKED = 5;
  final int PIXEL_DEPTH_RAW11_PACKED = 6;
  final int FLAG_FRAME_RECOVERED = 1;
  final int KNOWN_FRAME_FLAGS = FLAG_FRAME_RECOVERED;

  final int RGB_RAW_BYTES = WIDTH * HEIGHT;
  final int DEPTH_RAW11_PACKED_BYTES = WIDTH * HEIGHT * 11 / 8;
  final int RGB_HQ_BYTES = RGB_HQ_WIDTH * RGB_HQ_HEIGHT;
  final int MAX_PAYLOAD_BYTES = RGB_HQ_BYTES;
  final int REPLY_BYTES = 68;
  final int FRAME_HEADER_BYTES = 76;

}

// Processing merges PDE tabs into the sketch class. ScannerProtocol is therefore
// an inner type and must contain constants only; executable protocol helpers
// remain sketch methods in this same tab instead of illegal class methods.
int scannerMaskForMode(int mode) {
  return mode == studio.services.scannerProtocol.MODE_RGB ? studio.services.scannerProtocol.STREAM_RGB
       : mode == studio.services.scannerProtocol.MODE_DEPTH ? studio.services.scannerProtocol.STREAM_DEPTH
       : mode == studio.services.scannerProtocol.MODE_RGB_HQ ? studio.services.scannerProtocol.STREAM_RGB_HQ : 0;
}

boolean scannerFormatAllowedForMode(int mode,int fmt) {
  if(mode==studio.services.scannerProtocol.MODE_RGB||mode==studio.services.scannerProtocol.MODE_RGB_HQ)
    return fmt==studio.services.scannerProtocol.PIXEL_BAYER_GRBG8;
  return mode==studio.services.scannerProtocol.MODE_DEPTH&&fmt==studio.services.scannerProtocol.PIXEL_DEPTH_RAW11_PACKED;
}

boolean scannerPayloadAllowedForMode(int mode,int fmt,int bytes) {
  if(mode==studio.services.scannerProtocol.MODE_RGB)
    return fmt==studio.services.scannerProtocol.PIXEL_BAYER_GRBG8&&bytes==studio.services.scannerProtocol.RGB_RAW_BYTES;
  if(mode==studio.services.scannerProtocol.MODE_DEPTH)
    return fmt==studio.services.scannerProtocol.PIXEL_DEPTH_RAW11_PACKED&&bytes==studio.services.scannerProtocol.DEPTH_RAW11_PACKED_BYTES;
  return mode==studio.services.scannerProtocol.MODE_RGB_HQ&&fmt==studio.services.scannerProtocol.PIXEL_BAYER_GRBG8&&bytes==studio.services.scannerProtocol.RGB_HQ_BYTES;
}
int scannerExpectedWidthForMode(int mode){return mode==studio.services.scannerProtocol.MODE_RGB_HQ?studio.services.scannerProtocol.RGB_HQ_WIDTH:studio.services.scannerProtocol.WIDTH;}
int scannerExpectedHeightForMode(int mode){return mode==studio.services.scannerProtocol.MODE_RGB_HQ?studio.services.scannerProtocol.RGB_HQ_HEIGHT:studio.services.scannerProtocol.HEIGHT;}



// ===== SynKinect Studio / 3D Scanner / RGB HQ processing =====
static class RgbFrameQuality {
  static float clamp01(float v){return Math.max(0.0f,Math.min(1.0f,v));}
  static float score(byte[] data,int w,int h,int fmt){
    if(data==null||w<=2||h<=2)return 0.0f;
    return fmt==4&&data.length==w*h?scoreBayer(data,w,h):0.0f;
  }
  static float scoreBayer(byte[] data,int w,int h){
    long grad=0;int samples=0,good=0,clipped=0;int step=Math.max(6,Math.min(w,h)/96);if((step&1)!=0)step++;
    for(int y=step;y<h-step;y+=step)for(int x=step;x<w-step;x+=step){int i=y*w+x,v=data[i]&255;if(v>=20&&v<=240)good++;if(v<6||v>249)clipped++;int gx=Math.abs((data[i+2]&255)-(data[i-2]&255)),gy=Math.abs((data[i+2*w]&255)-(data[i-2*w]&255));grad+=gx+gy;samples++;}
    if(samples==0)return 0;float exposure=clamp01(good/(float)samples)*(1.0f-0.65f*clamp01(clipped/(float)samples));float sharp=clamp01((grad/(float)samples)/38.0f);return clamp01(exposure*(0.25f+0.75f*sharp));
  }
}

static class ColorStats {float r,g,b;int samples;boolean valid(){return samples>16&&r>1&&g>1&&b>1;}}
static class ColorReference {
  final float r,g,b;final boolean valid;
  ColorReference(float r,float g,float b,boolean valid){this.r=r;this.g=g;this.b=b;this.valid=valid;}
  static ColorReference fromFrames(List<HighQualityKeyframe> frames){
    if(frames==null||frames.isEmpty())return new ColorReference(128,128,128,false);
    float[] rs=new float[frames.size()],gs=new float[frames.size()],bs=new float[frames.size()];int n=0;
    for(HighQualityKeyframe k:frames){if(k==null||k.colorData==null)continue;ColorStats st=RgbHqProcessor.rawStats(k.colorData,k.colorWidth,k.colorHeight,k.colorPixelFormat);if(!st.valid())continue;rs[n]=st.r;gs[n]=st.g;bs[n]=st.b;n++;}
    if(n==0)return new ColorReference(128,128,128,false);Arrays.sort(rs,0,n);Arrays.sort(gs,0,n);Arrays.sort(bs,0,n);int m=n/2;float r=(n&1)==1?rs[m]:(rs[m-1]+rs[m])*0.5f,g=(n&1)==1?gs[m]:(gs[m-1]+gs[m])*0.5f,b=(n&1)==1?bs[m]:(bs[m-1]+bs[m])*0.5f;return new ColorReference(r,g,b,true);
  }
}

static class RgbHqProcessor {
  static int clamp8(int v){return v<0?0:v>255?255:v;}
  static int mirror(int p,int size){if(p<0)p=-p;if(p>=size)p=2*(size-1)-p;return p<0?0:p>=size?size-1:p;}
  static int sample(byte[] b,int w,int h,int x,int y){return b[mirror(y,h)*w+mirror(x,w)]&255;}
  static int avg2(int a,int b){return(a+b+1)>>1;}static int avg4(int a,int b,int c,int d){return(a+b+c+d+2)>>2;}
  static int rgbAt(byte[] b,int w,int h,int x,int y){
    boolean yo=(y&1)!=0,xo=(x&1)!=0;int c=sample(b,w,h,x,y),r=0,g=0,bl=0;
    if(!yo&&xo){r=c;int lh=sample(b,w,h,x-1,y),rh=sample(b,w,h,x+1,y),uv=sample(b,w,h,x,y-1),dv=sample(b,w,h,x,y+1);g=Math.abs(lh-rh)<=Math.abs(uv-dv)?avg2(lh,rh):avg2(uv,dv);bl=avg4(sample(b,w,h,x-1,y-1),sample(b,w,h,x+1,y-1),sample(b,w,h,x-1,y+1),sample(b,w,h,x+1,y+1));}
    else if(yo&&!xo){bl=c;int lh=sample(b,w,h,x-1,y),rh=sample(b,w,h,x+1,y),uv=sample(b,w,h,x,y-1),dv=sample(b,w,h,x,y+1);g=Math.abs(lh-rh)<=Math.abs(uv-dv)?avg2(lh,rh):avg2(uv,dv);r=avg4(sample(b,w,h,x-1,y-1),sample(b,w,h,x+1,y-1),sample(b,w,h,x-1,y+1),sample(b,w,h,x+1,y+1));}
    else if(!yo){g=c;r=avg2(sample(b,w,h,x-1,y),sample(b,w,h,x+1,y));bl=avg2(sample(b,w,h,x,y-1),sample(b,w,h,x,y+1));}
    else{g=c;r=avg2(sample(b,w,h,x,y-1),sample(b,w,h,x,y+1));bl=avg2(sample(b,w,h,x-1,y),sample(b,w,h,x+1,y));}
    return 0xff000000|(r<<16)|(g<<8)|bl;
  }
  static boolean decodeBayerGrbg(byte[] b,int w,int h,int[] out){
    if(b==null||out==null||b.length!=w*h||out.length<w*h)return false;
    for(int y=0;y<h;y++)for(int x=0;x<w;x++)out[y*w+x]=rgbAt(b,w,h,x,y);
    return true;
  }
  static byte[] bayerGrbgToNv12(byte[] b,int w,int h){
    if(b==null||w<=0||h<=0||(w&1)!=0||(h&1)!=0||b.length!=w*h)return null;
    int count=w*h;byte[] out=new byte[count*3/2];
    for(int y=0;y<h;y+=2)for(int x=0;x<w;x+=2){
      int c0=rgbAt(b,w,h,x,y),c1=rgbAt(b,w,h,x+1,y),c2=rgbAt(b,w,h,x,y+1),c3=rgbAt(b,w,h,x+1,y+1);
      int r0=(c0>>16)&255,g0=(c0>>8)&255,b0=c0&255,r1=(c1>>16)&255,g1=(c1>>8)&255,b1=c1&255;
      int r2=(c2>>16)&255,g2=(c2>>8)&255,b2=c2&255,r3=(c3>>16)&255,g3=(c3>>8)&255,b3=c3&255;
      out[y*w+x]=(byte)clamp8(((66*r0+129*g0+25*b0+128)>>8)+16);
      out[y*w+x+1]=(byte)clamp8(((66*r1+129*g1+25*b1+128)>>8)+16);
      out[(y+1)*w+x]=(byte)clamp8(((66*r2+129*g2+25*b2+128)>>8)+16);
      out[(y+1)*w+x+1]=(byte)clamp8(((66*r3+129*g3+25*b3+128)>>8)+16);
      int r=(r0+r1+r2+r3+2)>>2,g=(g0+g1+g2+g3+2)>>2,bl=(b0+b1+b2+b3+2)>>2;
      int u=((-38*r-74*g+112*bl+128)>>8)+128,v=((112*r-94*g-18*bl+128)>>8)+128,uv=count+(y/2)*w+x;
      out[uv]=(byte)clamp8(u);out[uv+1]=(byte)clamp8(v);
    }
    return out;
  }
  static ColorStats rawStats(byte[] data,int w,int h,int fmt){
    ColorStats st=new ColorStats();if(data==null||w<=0||h<=0)return st;long sr=0,sg=0,sb=0;int n=0,step=Math.max(8,Math.min(w,h)/64);if((step&1)!=0)step++;
    if(fmt==4&&data.length==w*h){for(int y=4;y<h-4;y+=step)for(int x=4;x<w-4;x+=step){int r,g,b;if((y&1)==0){r=sample(data,w,h,x|1,y);b=sample(data,w,h,x&~1,y+1);g=avg2(sample(data,w,h,x&~1,y),sample(data,w,h,x|1,y+1));}else{r=sample(data,w,h,x|1,y-1);b=sample(data,w,h,x&~1,y);g=avg2(sample(data,w,h,x|1,y),sample(data,w,h,x&~1,y-1));}if(r<5||g<5||b<5||r>250||g>250||b>250)continue;sr+=r;sg+=g;sb+=b;n++;}}
    else if(fmt==1&&data.length==w*h*3/2){int ySize=w*h;for(int y=2;y<h-2;y+=step)for(int x=2;x<w-2;x+=step){int yy=data[y*w+x]&255,uv=ySize+(y/2)*w+(x&~1),u=(data[uv]&255)-128,v=(data[uv+1]&255)-128,c=Math.max(0,yy-16),r=clamp8((298*c+409*v+128)>>8),g=clamp8((298*c-100*u-208*v+128)>>8),b=clamp8((298*c+516*u+128)>>8);if(r<5||g<5||b<5||r>250||g>250||b>250)continue;sr+=r;sg+=g;sb+=b;n++;}}
    st.samples=n;if(n>0){st.r=sr/(float)n;st.g=sg/(float)n;st.b=sb/(float)n;}return st;
  }
  static ColorStats decodedStats(int[] pixels){ColorStats st=new ColorStats();if(pixels==null)return st;long sr=0,sg=0,sb=0;int n=0,step=Math.max(1,pixels.length/8192);for(int i=0;i<pixels.length;i+=step){int c=pixels[i],r=(c>>16)&255,g=(c>>8)&255,b=c&255;if(r<5||g<5||b<5||r>250||g>250||b>250)continue;sr+=r;sg+=g;sb+=b;n++;}st.samples=n;if(n>0){st.r=sr/(float)n;st.g=sg/(float)n;st.b=sb/(float)n;}return st;}
  static void normalize(int[] pixels,ColorReference ref,AppConfig cfg){if(pixels==null||ref==null||!ref.valid)return;ColorStats cur=decodedStats(pixels);if(!cur.valid())return;float gr=Math.max(cfg.rgbPhotometricGainMin,Math.min(cfg.rgbPhotometricGainMax,ref.r/cur.r)),gg=Math.max(cfg.rgbPhotometricGainMin,Math.min(cfg.rgbPhotometricGainMax,ref.g/cur.g)),gb=Math.max(cfg.rgbPhotometricGainMin,Math.min(cfg.rgbPhotometricGainMax,ref.b/cur.b));float mean=(gr+gg+gb)/3.0f;gr=0.78f*gr+0.22f*mean;gg=0.78f*gg+0.22f*mean;gb=0.78f*gb+0.22f*mean;for(int i=0;i<pixels.length;i++){int c=pixels[i],r=clamp8(Math.round(((c>>16)&255)*gr)),g=clamp8(Math.round(((c>>8)&255)*gg)),b=clamp8(Math.round((c&255)*gb));pixels[i]=0xff000000|(r<<16)|(g<<8)|b;}}
  static void sharpen(int[] pixels,int w,int h,float amount){if(pixels==null||w<3||h<3||amount<=0)return;int[] prev=new int[w],cur=new int[w],next=new int[w];System.arraycopy(pixels,0,prev,0,w);System.arraycopy(pixels,0,cur,0,w);System.arraycopy(pixels,w,next,0,w);for(int y=1;y<h-1;y++){if(y>1){int[] tmp=prev;prev=cur;cur=next;next=tmp;System.arraycopy(pixels,(y+1)*w,next,0,w);}for(int x=1;x<w-1;x++){int c=cur[x],l=cur[x-1],r=cur[x+1],u=prev[x],d=next[x];int rr=sharpenChannel((c>>16)&255,(l>>16)&255,(r>>16)&255,(u>>16)&255,(d>>16)&255,amount),gg=sharpenChannel((c>>8)&255,(l>>8)&255,(r>>8)&255,(u>>8)&255,(d>>8)&255,amount),bb=sharpenChannel(c&255,l&255,r&255,u&255,d&255,amount);pixels[y*w+x]=0xff000000|(rr<<16)|(gg<<8)|bb;}}}
  static int sharpenChannel(int c,int l,int r,int u,int d,float amount){float blur=(4*c+l+r+u+d)/8.0f;return clamp8(Math.round(c+amount*(c-blur)));}
}

// ===== SynKinect Studio / 3D Scanner / HighQualityReconstruction.pde =====
class HighQualityKeyframe {
  final DepthFrame depth;
  final byte[] colorData;final int colorWidth,colorHeight,colorPixelFormat;final float colorQuality;
  final long rgbFrameNumber,rgbTimestampUs,rawSkewUs,residualUs;
  final RigidTransform initialPose;
  final float targetDepthM,bandM,sweepDeg;

  HighQualityKeyframe(RgbdFramePair pair,RawRgbFrame preferredColor,RigidTransform pose,float targetDepthM,float bandM,float sweepDeg,AppConfig cfg){
    this.depth=copyDepth(pair.depth);
    RawRgbFrame color=preferredColor!=null&&preferredColor.quality>=cfg.rgbHqMinimumFrameQuality?preferredColor:pair.rgb;
    boolean usable=color!=null&&color.data!=null&&color.quality>=cfg.rgbHqMinimumFrameQuality;
    this.colorData=usable?Arrays.copyOf(color.data,color.data.length):null;
    this.colorWidth=usable?color.width:0;this.colorHeight=usable?color.height:0;this.colorPixelFormat=usable?color.pixelFormat:0;this.colorQuality=usable?color.quality:0;
    this.rgbFrameNumber=usable?color.frameNumber:0;
    this.rgbTimestampUs=usable?color.timestampUs:0;
    this.rawSkewUs=usable?Math.abs(color.timestampUs-pair.depth.timestampUs):pair.rawSkewUs;this.residualUs=this.rawSkewUs;
    this.initialPose=new RigidTransform();this.initialPose.set(pose);
    this.targetDepthM=targetDepthM;this.bandM=bandM;this.sweepDeg=sweepDeg;
  }

  DepthFrame copyDepth(DepthFrame src){
    DepthFrame d=new DepthFrame();d.frameId=src.frameId;d.width=src.width;d.height=src.height;d.stride=src.stride;d.pixelFormat=src.pixelFormat;
    d.frameNumber=src.frameNumber;d.timestampUs=src.timestampUs;d.depth=Arrays.copyOf(src.depth,src.depth.length);d.validCount=src.validCount;d.plausibleCount=src.plausibleCount;
    d.deviceCalibrated=src.deviceCalibrated;d.transportRecovered=src.transportRecovered;
    MotionSample m=new MotionSample();if(src.motion!=null){m.flags=src.motion.flags;m.accelX=src.motion.accelX;m.accelY=src.motion.accelY;m.accelZ=src.motion.accelZ;m.tiltTenths=src.motion.tiltTenths;m.timestampMs=src.motion.timestampMs;}d.motion=m;return d;
  }

  long estimatedBytes(){return (long)depth.depth.length*2L+(colorData==null?0:colorData.length)+192L;}
}

class HighQualityScanArchive {
  final AppConfig cfg;
  final ArrayList<HighQualityKeyframe> frames=new ArrayList<HighQualityKeyframe>();
  HighQualityScanArchive(AppConfig cfg){this.cfg=cfg;}
  synchronized void clear(){frames.clear();}
  synchronized int size(){return frames.size();}
  synchronized long estimatedBytes(){long n=0;for(HighQualityKeyframe f:frames)n+=f.estimatedBytes();return n;}
  synchronized ArrayList<HighQualityKeyframe> snapshot(){return new ArrayList<HighQualityKeyframe>(frames);}

  synchronized boolean offer(RgbdFramePair pair,RawRgbFrame preferredColor,RigidTransform pose,float targetDepthM,float bandM,float sweepDeg){
    if(pair==null||pair.depth==null||pose==null||frames.size()>=cfg.hqMaxKeyframes)return false;
    if(!frames.isEmpty()){
      HighQualityKeyframe last=frames.get(frames.size()-1);
      float rot=rotationDeltaDeg(last.initialPose,pose),trans=translationDelta(last.initialPose,pose);
      float sweepDelta=abs(sweepDeg-last.sweepDeg);
      if(max(rot,sweepDelta)<cfg.hqKeyframeMinRotationDeg&&trans<cfg.hqKeyframeMinTranslationM)return false;
    }
    frames.add(new HighQualityKeyframe(pair,preferredColor,pose,targetDepthM,bandM,sweepDeg,cfg));return true;
  }

  float translationDelta(RigidTransform a,RigidTransform b){float dx=a.m[3]-b.m[3],dy=a.m[7]-b.m[7],dz=a.m[11]-b.m[11];return sqrt(dx*dx+dy*dy+dz*dz);}
  float rotationDeltaDeg(RigidTransform a,RigidTransform b){
    float r00=a.m[0]*b.m[0]+a.m[4]*b.m[4]+a.m[8]*b.m[8];
    float r11=a.m[1]*b.m[1]+a.m[5]*b.m[5]+a.m[9]*b.m[9];
    float r22=a.m[2]*b.m[2]+a.m[6]*b.m[6]+a.m[10]*b.m[10];
    float c=constrain((r00+r11+r22-1.0f)*0.5f,-1.0f,1.0f);return degrees(acos(c));
  }
}

class RobustIcpResult {RigidTransform pose=new RigidTransform();float rms=Float.POSITIVE_INFINITY;int matches=0;boolean good=false;}
class RobustMatch {final PVector sourceWorld=new PVector();PVector target;float d2;}

class RobustIcpRefiner {
  final AppConfig cfg;final QuaternionFit fitter=new QuaternionFit();
  final ArrayList<RobustMatch> pool=new ArrayList<RobustMatch>(),active=new ArrayList<RobustMatch>();
  final ArrayList<PVector> src=new ArrayList<PVector>(),dst=new ArrayList<PVector>();
  RobustIcpRefiner(AppConfig cfg){this.cfg=cfg;}
  RobustMatch slot(int i){while(pool.size()<=i)pool.add(new RobustMatch());return pool.get(i);}

  RobustIcpResult refine(PointCloud current,PointCloud referenceWorld,RigidTransform initial){
    RobustIcpResult out=new RobustIcpResult();out.pose.set(initial);
    if(current==null||referenceWorld==null||current.size()<cfg.hqIcpMinimumMatches||referenceWorld.size()<cfg.hqIcpMinimumMatches)return out;
    SpatialHash hash=new SpatialHash(cfg.hqIcpMaxDistanceM,referenceWorld.size());for(PVector p:referenceWorld.points)hash.add(p);
    RigidTransform estimate=new RigidTransform();estimate.set(initial);int stride=max(1,(current.size()+cfg.hqIcpMaxSamples-1)/cfg.hqIcpMaxSamples);
    float finalRms=Float.POSITIVE_INFINITY;int finalMatches=0;
    for(int iter=0;iter<cfg.hqIcpIterations;iter++){
      active.clear();int slot=0;float[] m=estimate.m;
      float phase=cfg.hqIcpIterations<=1?1.0f:iter/(float)(cfg.hqIcpIterations-1);
      float fineDistance=max(cfg.hqVoxelSizeM*3.0f,cfg.hqIcpMaxDistanceM*0.35f);
      float searchDistance=lerp(cfg.hqIcpMaxDistanceM,fineDistance,phase);
      for(int i=0;i<current.size();i+=stride){
        PVector p=current.points.get(i);RobustMatch rm=slot(slot++);
        rm.sourceWorld.set(m[0]*p.x+m[1]*p.y+m[2]*p.z+m[3],m[4]*p.x+m[5]*p.y+m[6]*p.z+m[7],m[8]*p.x+m[9]*p.y+m[10]*p.z+m[11]);
        PVector near=hash.nearest(rm.sourceWorld,searchDistance);if(near==null)continue;
        float dx=rm.sourceWorld.x-near.x,dy=rm.sourceWorld.y-near.y,dz=rm.sourceWorld.z-near.z;rm.target=near;rm.d2=dx*dx+dy*dy+dz*dz;active.add(rm);
      }
      if(active.size()<cfg.hqIcpMinimumMatches)break;
      active.sort(new Comparator<RobustMatch>(){public int compare(RobustMatch a,RobustMatch b){return Float.compare(a.d2,b.d2);}});
      int keep=constrain(round(active.size()*cfg.hqIcpTrimFraction),cfg.hqIcpMinimumMatches,active.size());src.clear();dst.clear();double sum2=0;
      for(int i=0;i<keep;i++){RobustMatch rm=active.get(i);src.add(rm.sourceWorld);dst.add(rm.target);sum2+=rm.d2;}
      finalRms=(float)Math.sqrt(sum2/keep);finalMatches=keep;
      RigidTransform correction=fitter.fit(src,dst);estimate=correction.multiply(estimate);
      float move=sqrt(correction.m[3]*correction.m[3]+correction.m[7]*correction.m[7]+correction.m[11]*correction.m[11]);
      float angle=rotationAngle(correction);if(move<0.00005f&&angle<0.03f)break;
    }
    out.pose.set(estimate);out.rms=finalRms;out.matches=finalMatches;out.good=finalMatches>=cfg.hqIcpMinimumMatches&&finalRms<=cfg.hqIcpGoodRmsM;return out;
  }
  float rotationAngle(RigidTransform t){float c=constrain((t.m[0]+t.m[5]+t.m[10]-1.0f)*0.5f,-1,1);return degrees(acos(c));}
}

class DepthSuperResolutionStats {
  int sourceViews=0,sourceSamples=0,acceptedSplats=0,rejectedOcclusion=0,rejectedOutlier=0,outputPoints=0;
  void clear(){sourceViews=sourceSamples=acceptedSplats=rejectedOcclusion=rejectedOutlier=outputPoints=0;}
}

class MultiFrameDepthSuperResolver {
  final AppConfig cfg;final Calibration calibration;final PointCloudBuilder builder;final RgbDepthRegistration registration;
  float[] sumW,sumZ,sumZ2,frontZ;short[] distinctViews;int[] lastView,touched;int touchedCount=0,sw=0,sh=0;
  final DepthSuperResolutionStats stats=new DepthSuperResolutionStats();
  MultiFrameDepthSuperResolver(AppConfig cfg,Calibration calibration,PointCloudBuilder builder,RgbDepthRegistration registration){this.cfg=cfg;this.calibration=calibration;this.builder=builder;this.registration=registration;}

  void ensureGrid(int w,int h){
    int scale=max(1,cfg.hqDepthSrScale),nw=w*scale,nh=h*scale,n=nw*nh;if(nw==sw&&nh==sh&&sumW!=null)return;sw=nw;sh=nh;
    sumW=new float[n];sumZ=new float[n];sumZ2=new float[n];frontZ=new float[n];distinctViews=new short[n];lastView=new int[n];Arrays.fill(lastView,-1);touched=new int[max(65536,min(n,262144))];touchedCount=0;
  }
  void clearGrid(){for(int i=0;i<touchedCount;i++){int id=touched[i];sumW[id]=sumZ[id]=sumZ2[id]=frontZ[id]=0;distinctViews[id]=0;lastView[id]=-1;}touchedCount=0;stats.clear();}
  void touch(int id){if(sumW[id]!=0||distinctViews[id]!=0)return;if(touchedCount>=touched.length)touched=Arrays.copyOf(touched,max(touchedCount+1,touched.length*2));touched[touchedCount++]=id;}
  void resetCell(int id,float z,float w,int viewTag){touch(id);sumW[id]=w;sumZ[id]=z*w;sumZ2[id]=z*z*w;frontZ[id]=z;distinctViews[id]=1;lastView[id]=viewTag;stats.acceptedSplats++;}
  void addCell(int id,float z,float w,int viewTag){
    if(w<=0.0001f)return;if(sumW[id]<=0){resetCell(id,z,w,viewTag);return;}
    float front=frontZ[id];
    if(z<front-cfg.hqDepthSrOcclusionToleranceM){resetCell(id,z,w,viewTag);return;}
    if(z>front+cfg.hqDepthSrOcclusionToleranceM){stats.rejectedOcclusion++;return;}
    float mean=sumZ[id]/sumW[id];if(abs(z-mean)>cfg.hqDepthSrOutlierToleranceM){stats.rejectedOutlier++;return;}
    touch(id);sumW[id]+=w;sumZ[id]+=z*w;sumZ2[id]+=z*z*w;if(z<frontZ[id])frontZ[id]=z;
    if(lastView[id]!=viewTag){distinctViews[id]=(short)min(Short.MAX_VALUE,(distinctViews[id]&0xffff)+1);lastView[id]=viewTag;}stats.acceptedSplats++;
  }
  void splat(float sx,float sy,float z,float baseWeight,int viewTag){
    int x0=floor(sx),y0=floor(sy);float fx=sx-x0,fy=sy-y0;
    for(int dy=0;dy<=1;dy++){int y=y0+dy;if(y<0||y>=sh)continue;float wy=dy==0?1-fy:fy;if(wy<=0)continue;int row=y*sw;
      for(int dx=0;dx<=1;dx++){int x=x0+dx;if(x<0||x>=sw)continue;float wx=dx==0?1-fx:fx,w=baseWeight*wx*wy;if(w>0.0001f)addCell(row+x,z,w,viewTag);}
    }
  }
  boolean poseNear(RigidTransform a,RigidTransform b){return translationDelta(a,b)<=cfg.hqDepthSrMaxTranslationM&&rotationDeltaDeg(a,b)<=cfg.hqDepthSrMaxRotationDeg;}
  float translationDelta(RigidTransform a,RigidTransform b){float dx=a.m[3]-b.m[3],dy=a.m[7]-b.m[7],dz=a.m[11]-b.m[11];return sqrt(dx*dx+dy*dy+dz*dz);}
  float rotationDeltaDeg(RigidTransform a,RigidTransform b){float r00=a.m[0]*b.m[0]+a.m[4]*b.m[4]+a.m[8]*b.m[8],r11=a.m[1]*b.m[1]+a.m[5]*b.m[5]+a.m[9]*b.m[9],r22=a.m[2]*b.m[2]+a.m[6]*b.m[6]+a.m[10]*b.m[10];return degrees(acos(constrain((r00+r11+r22-1)*0.5f,-1,1)));}

  PointCloud fuse(ArrayList<HighQualityKeyframe> frames,ArrayList<RigidTransform> poses,int anchorIndex,RgbSnapshot rgb){
    if(frames==null||poses==null||anchorIndex<0||anchorIndex>=frames.size())return new PointCloud();HighQualityKeyframe anchor=frames.get(anchorIndex);DepthFrame anchorDepth=anchor.depth;if(anchorDepth==null||anchorDepth.depth==null)return new PointCloud();
    ensureGrid(anchorDepth.width,anchorDepth.height);clearGrid();int scale=max(1,cfg.hqDepthSrScale),half=max(0,cfg.hqDepthSrWindowFrames/2);RigidTransform anchorPose=poses.get(anchorIndex),anchorInv=anchorPose.inverseRigid();
    int from=max(0,anchorIndex-half),to=min(frames.size()-1,anchorIndex+half),viewTag=0;
    for(int j=from;j<=to;j++){
      if(!poseNear(anchorPose,poses.get(j)))continue;HighQualityKeyframe k=frames.get(j);DepthFrame f=k.depth;if(f==null||f.depth==null||f.width!=anchorDepth.width||f.height!=anchorDepth.height)continue;RigidTransform rel=anchorInv.multiply(poses.get(j));float[] m=rel.m;stats.sourceViews++;int tag=++viewTag;
      for(int v=0;v<f.height;v++){int row=v*f.width;for(int u=0;u<f.width;u++){int index=row+u,raw=f.depth[index]&0xffff;if(raw==0)continue;int mm=calibration.correctedDepthMm(index,raw);float z=mm*calibration.depthScale;if(z<cfg.minDepthM||z>cfg.maxDepthM)continue;if(!Float.isNaN(k.targetDepthM)&&abs(z-k.targetDepthM)>k.bandM)continue;stats.sourceSamples++;
        float x=registration!=null?registration.pointX(index,z):(u-calibration.cx)*z/calibration.fx,y=registration!=null?registration.pointY(index,z):(v-calibration.cy)*z/calibration.fy;
        float ax=m[0]*x+m[1]*y+m[2]*z+m[3],ay=m[4]*x+m[5]*y+m[6]*z+m[7],az=m[8]*x+m[9]*y+m[10]*z+m[11];if(az<=0.05f)continue;float pu=calibration.fx*ax/az+calibration.cx,pv=calibration.fy*ay/az+calibration.cy;if(pu<-0.5f||pv<-0.5f||pu>anchorDepth.width-0.5f||pv>anchorDepth.height-0.5f)continue;
        float conf=calibration.depthConfidence(index,z),rangeWeight=1.0f/(1.0f+0.30f*z*z),baseWeight=max(0.05f,conf*rangeWeight);float sx=(pu+0.5f)*scale-0.5f,sy=(pv+0.5f)*scale-0.5f;splat(sx,sy,az,baseWeight,tag);
      }}
    }
    PointCloud out=emit(anchorDepth,rgb,scale);stats.outputPoints=out.size();return out;
  }

  PointCloud emit(DepthFrame anchorDepth,RgbSnapshot rgb,int scale){
    int eligible=0,minViews=max(1,cfg.hqDepthSrMinimumViews);for(int i=0;i<touchedCount;i++){int id=touched[i];if((distinctViews[id]&0xffff)<minViews||sumW[id]<=0)continue;float mean=sumZ[id]/sumW[id],var=max(0,sumZ2[id]/sumW[id]-mean*mean);if(sqrt(var)<=cfg.hqDepthSrOutlierToleranceM)eligible++;}
    int stride=max(1,(eligible+cfg.hqDepthSrMaxPoints-1)/cfg.hqDepthSrMaxPoints),seen=0;PointCloud out=new PointCloud(min(eligible,cfg.hqDepthSrMaxPoints)+16);if(registration!=null&&rgb!=null)registration.prepareFrame(anchorDepth,rgb);
    for(int i=0;i<touchedCount;i++){int id=touched[i],views=distinctViews[id]&0xffff;if(views<minViews||sumW[id]<=0)continue;float z=sumZ[id]/sumW[id],var=max(0,sumZ2[id]/sumW[id]-z*z),sigma=sqrt(var);if(sigma>cfg.hqDepthSrOutlierToleranceM)continue;if((seen++%stride)!=0)continue;int sx=id%sw,sy=id/sw;float u=(sx+0.5f)/scale-0.5f,v=(sy+0.5f)/scale-0.5f,x=(u-calibration.cx)*z/calibration.fx,y=(v-calibration.cy)*z/calibration.fy;float support=constrain(views/(float)max(minViews,stats.sourceViews),0.25f,1.0f),consistency=1.0f-constrain(sigma/max(0.0005f,cfg.hqDepthSrOutlierToleranceM),0,0.85f),q=constrain((0.30f+0.70f*support)*consistency,0.08f,1.0f);int color=registration!=null&&rgb!=null?registration.colorAtPoint(x,y,z):0;out.add(new PVector(x,y,z),color,q);}
    return out;
  }
}

class HighQualityReconstructor {
  final AppConfig cfg;final Calibration calibration;final PointCloudBuilder builder;final RgbDepthRegistration registration;final RobustIcpRefiner refiner;final MultiFrameDepthSuperResolver superResolver;
  int[] rgbPixels;ColorReference colorReference;DepthSuperResolutionStats lastSuperResolutionStats=null;
  HighQualityReconstructor(AppConfig cfg,Calibration calibration,PointCloudBuilder builder,RgbDepthRegistration registration){this.cfg=cfg;this.calibration=calibration;this.builder=builder;this.registration=registration;this.refiner=new RobustIcpRefiner(cfg);this.superResolver=new MultiFrameDepthSuperResolver(cfg,calibration,builder,registration);}

  Mesh3D reconstruct(ArrayList<HighQualityKeyframe> frames){
    if(frames==null||frames.size()<cfg.hqMinimumKeyframes)return null;
    studio.scannerState.hqBusy=true;studio.scannerState.hqProgress=0;
    try{
      ArrayList<RigidTransform> poses=refinePoses(frames);if(Thread.currentThread().isInterrupted())return null;
      colorReference=cfg.rgbPhotometricNormalize?ColorReference.fromFrames(frames):null;
      TSDFVolume volume=new TSDFVolume(cfg.hqVolumeSize,cfg.hqVoxelSizeM,cfg.hqTruncationM,cfg.rgbTemporalColorWeightMax);
      boolean initialized=false;ArrayList<Integer> anchors=integrationAnchors(frames.size());
      for(int ai=0;ai<anchors.size();ai++){
        int i=anchors.get(ai);HighQualityKeyframe k=frames.get(i);RgbSnapshot rgb=rgbSnapshot(k);PointCloud cloud;
        if(cfg.hqDepthSuperResolution&&cfg.hqDepthSrScale>1){cloud=superResolver.fuse(frames,poses,i,rgb);lastSuperResolutionStats=superResolver.stats;if(cloud.size()<cfg.minimumTrackingPoints)cloud=builder.buildHighQuality(k.depth,calibration,k.targetDepthM,k.bandM,rgb);}
        else cloud=builder.buildHighQuality(k.depth,calibration,k.targetDepthM,k.bandM,rgb);
        if(cloud.size()<cfg.minimumTrackingPoints)continue;
        if(!initialized){volume.resetAround(cloud.centroidTransformed(poses.get(i)));initialized=true;}
        volume.integrate(cloud,poses.get(i),1,cfg.hqDistanceWeightedTsdf);
        studio.scannerState.hqProgress=0.45f+0.45f*((ai+1)/(float)max(1,anchors.size()));
        studio.scannerState.status=studio.scannerState.i18n.format("status.hq_integrating",round(studio.scannerState.hqProgress*100));
        if(Thread.currentThread().isInterrupted())return null;
      }
      if(!initialized)return null;
      studio.scannerState.hqProgress=0.93f;studio.scannerState.status=studio.scannerState.i18n.tr("status.hq_meshing");
      Mesh3D raw=volume.extractMesh(cfg.hqMeshMinWeight);Mesh3D result=studio.scannerState.meshEditor.polishHighQuality(raw);
      studio.scannerState.hqProgress=1.0f;return result;
    }finally{studio.scannerState.hqBusy=false;}
  }


  ArrayList<Integer> integrationAnchors(int count){
    ArrayList<Integer> out=new ArrayList<Integer>();if(count<=0)return out;int stride=cfg.hqDepthSuperResolution?max(1,cfg.hqDepthSrAnchorStride):1;for(int i=0;i<count;i+=stride)out.add(i);if(out.get(out.size()-1)!=count-1)out.add(count-1);return out;
  }

  ArrayList<RigidTransform> refinePoses(ArrayList<HighQualityKeyframe> frames){
    ArrayList<RigidTransform> poses=new ArrayList<RigidTransform>(frames.size());
    PointCloud firstLocal=null,lastLocal=null;ArrayDeque<PointCloud> localMap=new ArrayDeque<PointCloud>();
    for(int i=0;i<frames.size();i++){
      HighQualityKeyframe k=frames.get(i);PointCloud current=builder.buildHighQuality(k.depth,calibration,k.targetDepthM,k.bandM,null);RigidTransform pose=new RigidTransform();pose.set(k.initialPose);
      if(i==0){firstLocal=current;}else if(!localMap.isEmpty()){
        PointCloud reference=mergeLocalMap(localMap);RobustIcpResult r=refiner.refine(current,reference,pose);if(r.good)pose.set(r.pose);
      }
      poses.add(pose);lastLocal=current;
      int perFrame=max(1000,cfg.hqIcpMaxSamples/max(1,cfg.hqLocalMapFrames));localMap.addLast(current.transformed(pose,perFrame));while(localMap.size()>cfg.hqLocalMapFrames)localMap.removeFirst();
      studio.scannerState.hqProgress=0.40f*((i+1)/(float)frames.size());studio.scannerState.status=studio.scannerState.i18n.format("status.hq_refining",round(studio.scannerState.hqProgress*100));
      if(Thread.currentThread().isInterrupted())return poses;
    }
    if(cfg.hqLoopClosure&&frames.size()>=cfg.hqMinimumKeyframes&&firstLocal!=null&&lastLocal!=null){
      float sweep=abs(frames.get(frames.size()-1).sweepDeg-frames.get(0).sweepDeg);
      if(sweep>=cfg.scanCompleteDeg*0.90f){
        PointCloud firstWorld=firstLocal.transformed(poses.get(0),cfg.hqIcpMaxSamples);RigidTransform last=poses.get(poses.size()-1);
        RobustIcpResult closure=refiner.refine(lastLocal,firstWorld,last);
        if(closure.good&&closure.rms<=cfg.hqLoopClosureMaxRmsM){RigidTransform correction=closure.pose.multiply(last.inverseRigid());applyDistributedCorrection(poses,correction);}
      }
    }
    studio.scannerState.hqProgress=0.42f;return poses;
  }

  PointCloud mergeLocalMap(ArrayDeque<PointCloud> window){
    int total=0;for(PointCloud c:window)total+=c.size();PointCloud out=new PointCloud(total);for(PointCloud c:window)for(int i=0;i<c.size();i++)out.add(c.points.get(i),c.colorAt(i));return out;
  }

  void applyDistributedCorrection(ArrayList<RigidTransform> poses,RigidTransform correction){
    int n=poses.size();if(n<2)return;for(int i=1;i<n;i++){float a=i/(float)(n-1);RigidTransform f=fractional(correction,a);poses.set(i,f.multiply(poses.get(i)));}
  }

  RigidTransform fractional(RigidTransform t,float alpha){
    alpha=constrain(alpha,0,1);float trace=t.m[0]+t.m[5]+t.m[10],qw,qx,qy,qz;
    if(trace>0){float s=sqrt(trace+1.0f)*2.0f;qw=0.25f*s;qx=(t.m[9]-t.m[6])/s;qy=(t.m[2]-t.m[8])/s;qz=(t.m[4]-t.m[1])/s;}
    else if(t.m[0]>t.m[5]&&t.m[0]>t.m[10]){float s=sqrt(1.0f+t.m[0]-t.m[5]-t.m[10])*2.0f;qw=(t.m[9]-t.m[6])/s;qx=0.25f*s;qy=(t.m[1]+t.m[4])/s;qz=(t.m[2]+t.m[8])/s;}
    else if(t.m[5]>t.m[10]){float s=sqrt(1.0f+t.m[5]-t.m[0]-t.m[10])*2.0f;qw=(t.m[2]-t.m[8])/s;qx=(t.m[1]+t.m[4])/s;qy=0.25f*s;qz=(t.m[6]+t.m[9])/s;}
    else{float s=sqrt(1.0f+t.m[10]-t.m[0]-t.m[5])*2.0f;qw=(t.m[4]-t.m[1])/s;qx=(t.m[2]+t.m[8])/s;qy=(t.m[6]+t.m[9])/s;qz=0.25f*s;}
    if(qw<0){qw=-qw;qx=-qx;qy=-qy;qz=-qz;}float angle=2.0f*acos(constrain(qw,-1,1)),sinHalf=sqrt(max(0,1-qw*qw));float ax=1,ay=0,az=0;if(sinHalf>1e-6f){ax=qx/sinHalf;ay=qy/sinHalf;az=qz/sinHalf;}
    float h=angle*alpha*0.5f,w=cos(h),ss=sin(h),x=ax*ss,y=ay*ss,z=az*ss;RigidTransform r=new RigidTransform();
    r.m[0]=1-2*y*y-2*z*z;r.m[1]=2*x*y-2*z*w;r.m[2]=2*x*z+2*y*w;
    r.m[4]=2*x*y+2*z*w;r.m[5]=1-2*x*x-2*z*z;r.m[6]=2*y*z-2*x*w;
    r.m[8]=2*x*z-2*y*w;r.m[9]=2*y*z+2*x*w;r.m[10]=1-2*x*x-2*y*y;
    r.m[3]=t.m[3]*alpha;r.m[7]=t.m[7]*alpha;r.m[11]=t.m[11]*alpha;return r;
  }

  RgbSnapshot rgbSnapshot(HighQualityKeyframe k){
    if(k.colorData==null||k.colorWidth<=0||k.colorHeight<=0)return null;int count=k.colorWidth*k.colorHeight;if(rgbPixels==null||rgbPixels.length!=count)rgbPixels=new int[count];
    boolean ok=k.colorPixelFormat==studio.services.scannerProtocol.PIXEL_BAYER_GRBG8?RgbHqProcessor.decodeBayerGrbg(k.colorData,k.colorWidth,k.colorHeight,rgbPixels):decodeNv12(k.colorData,k.colorWidth,k.colorHeight,rgbPixels);
    if(!ok)return null;if(cfg.rgbPhotometricNormalize)RgbHqProcessor.normalize(rgbPixels,colorReference,cfg);if(cfg.rgbHqSharpenAmount>0)RgbHqProcessor.sharpen(rgbPixels,k.colorWidth,k.colorHeight,cfg.rgbHqSharpenAmount);
    float tolerance=k.colorPixelFormat==studio.services.scannerProtocol.PIXEL_BAYER_GRBG8?cfg.rgbHqMaxSyncSkewMs:cfg.rgbMaxSyncSkewMs;
    return new RgbSnapshot(rgbPixels,k.colorWidth,k.colorHeight,null,k.rgbFrameNumber,k.rgbTimestampUs,System.currentTimeMillis(),k.residualUs/1000.0f,k.rawSkewUs/1000.0f,tolerance,k.colorQuality);
  }
  boolean decodeNv12(byte[] data,int w,int h,int[] out){
    if(data==null||data.length!=w*h*3/2||out==null||out.length<w*h)return false;int ySize=w*h;
    for(int y=0;y<h;y++){int row=y*w,uvRow=ySize+(y/2)*w;for(int x=0;x<w;x++){int yi=data[row+x]&255,uv=uvRow+(x&~1),u=(data[uv]&255)-128,v=(data[uv+1]&255)-128,c=max(0,yi-16),rr=(298*c+409*v+128)>>8,gg=(298*c-100*u-208*v+128)>>8,bb=(298*c+516*u+128)>>8;out[row+x]=0xff000000|(constrain(rr,0,255)<<16)|(constrain(gg,0,255)<<8)|constrain(bb,0,255);}}return true;
  }
}

// ===== SynKinect Studio / 3D Scanner / TSDFVolume.pde =====
class TSDFVolume {
  int n;float voxelSize,truncation;int temporalColorWeightMax;short[] tsdf;byte[] weight;int[] rgb;byte[] rgbWeight;int[] touched=new int[65536];int touchedCount=0;
  PVector origin=new PVector(),center=new PVector();int minX,minY,minZ,maxX,maxY,maxZ;
  TSDFVolume(int n,float voxelSize,float truncation,int temporalColorWeightMax){this.n=n;this.voxelSize=voxelSize;this.truncation=truncation;this.temporalColorWeightMax=max(1,temporalColorWeightMax);int count=n*n*n;tsdf=new short[count];weight=new byte[count];rgb=new int[count];rgbWeight=new byte[count];resetBounds();}
  void resetBounds(){minX=minY=minZ=n;maxX=maxY=maxZ=-1;}
  void clear(){for(int i=0;i<touchedCount;i++){int id=touched[i];weight[id]=0;rgbWeight[id]=0;tsdf[id]=0;rgb[id]=0;}touchedCount=0;resetBounds();}
  void markTouched(int id){if((weight[id]&255)!=0||(rgbWeight[id]&255)!=0)return;if(touchedCount>=touched.length)touched=Arrays.copyOf(touched,max(touchedCount+1,touched.length*2));touched[touchedCount++]=id;}
  void resetAround(PVector c){clear();center.set(c);float half=n*voxelSize*0.5f;origin.set(c.x-half,c.y-half,c.z-half);}
  int idx(int x,int y,int z){return x+y*n+z*n*n;}boolean inside(int x,int y,int z){return x>=0&&y>=0&&z>=0&&x<n&&y<n&&z<n;}
  void integrate(PointCloud cloud,RigidTransform pose,int pointStep){integrate(cloud,pose,pointStep,false);}
  void integrate(PointCloud cloud,RigidTransform pose,int pointStep,boolean distanceWeighted){
    float[] m=pose.m;float camX=m[3],camY=m[7],camZ=m[11];int stride=max(1,pointStep);
    for(int i=0;i<cloud.size();i+=stride){
      PVector source=cloud.points.get(i);float surfX=m[0]*source.x+m[1]*source.y+m[2]*source.z+m[3],surfY=m[4]*source.x+m[5]*source.y+m[6]*source.z+m[7],surfZ=m[8]*source.x+m[9]*source.y+m[10]*source.z+m[11];int surfaceColor=cloud.colorAt(i);
      float dx=surfX-camX,dy=surfY-camY,dz=surfZ-camZ,dist=sqrt(dx*dx+dy*dy+dz*dz);if(dist<0.05f)continue;float inv=1.0f/dist,rayX=dx*inv,rayY=dy*inv,rayZ=dz*inv,from=max(0.05f,dist-truncation),to=dist+truncation;
      int sampleWeight=distanceWeighted?depthSampleWeight(dist,cloud.confidenceAt(i)):1;
      for(float t=from;t<=to;t+=voxelSize){float px=camX+rayX*t,py=camY+rayY*t,pz=camZ+rayZ*t;int x=floor((px-origin.x)/voxelSize),y=floor((py-origin.y)/voxelSize),z=floor((pz-origin.z)/voxelSize);if(!inside(x,y,z))continue;float v=constrain((dist-t)/truncation,-1,1);int id=idx(x,y,z),w=weight[id]&255;markTouched(id);int accepted=min(sampleWeight,255-w);if(accepted<=0)continue;int nw=w+accepted;float old=w==0?0:tsdf[id]/32767.0f,blended=(old*w+v*accepted)/nw;tsdf[id]=(short)constrain(round(blended*32767.0f),-32767,32767);weight[id]=(byte)nw;minX=min(minX,x);minY=min(minY,y);minZ=min(minZ,z);maxX=max(maxX,x);maxY=max(maxY,y);maxZ=max(maxZ,z);}
      if(((surfaceColor>>>24)&255)!=0)integrateSurfaceColor(surfX,surfY,surfZ,surfaceColor);
    }
  }
  int depthSampleWeight(float depthM){return depthSampleWeight(depthM,1.0f);}
  int depthSampleWeight(float depthM,float confidence){
    // Range-dependent structured-light noise is combined with the empirical
    // per-pixel confidence learned during flat-wall calibration.
    float z=max(0.35f,depthM),z2=z*z,z4=z2*z2,base=4.0f/max(0.35f,z4);return constrain(round(base*constrain(confidence,0.20f,1.0f)),1,8);
  }
  void integrateSurfaceColor(float px,float py,float pz,int colorValue){int x=round((px-origin.x)/voxelSize),y=round((py-origin.y)/voxelSize),z=round((pz-origin.z)/voxelSize);if(!inside(x,y,z))return;int id=idx(x,y,z),w=rgbWeight[id]&255,confidence=(colorValue>>>24)&255,sampleWeight=constrain(round((confidence/255.0f)*temporalColorWeightMax),1,temporalColorWeightMax),accepted=min(sampleWeight,255-w);if(accepted<=0)return;markTouched(id);int nw=w+accepted,old=rgb[id],or=(old>>16)&255,og=(old>>8)&255,ob=old&255,nr=(colorValue>>16)&255,ng=(colorValue>>8)&255,nb=colorValue&255;int r=(or*w+nr*accepted)/nw,g=(og*w+ng*accepted)/nw,b=(ob*w+nb*accepted)/nw;rgb[id]=0xff000000|(r<<16)|(g<<8)|b;rgbWeight[id]=(byte)nw;}
  float value(int x,int y,int z){int id=idx(x,y,z);return(weight[id]&255)==0?1.0f:tsdf[id]/32767.0f;}int w(int x,int y,int z){return weight[idx(x,y,z)]&255;}PVector pos(int x,int y,int z){return new PVector(origin.x+x*voxelSize,origin.y+y*voxelSize,origin.z+z*voxelSize);}
  int sampleColor(PVector p){int cx=round((p.x-origin.x)/voxelSize),cy=round((p.y-origin.y)/voxelSize),cz=round((p.z-origin.z)/voxelSize),best=0,bestWeight=0;for(int dz=-1;dz<=1;dz++)for(int dy=-1;dy<=1;dy++)for(int dx=-1;dx<=1;dx++){int x=cx+dx,y=cy+dy,z=cz+dz;if(!inside(x,y,z))continue;int id=idx(x,y,z),cw=rgbWeight[id]&255;if(cw>bestWeight){bestWeight=cw;best=rgb[id];}}return best;}
  Mesh3D extractMesh(int minWeight){Mesh3D out=new Mesh3D();if(maxX<0)return out;int x0=max(0,minX-1),y0=max(0,minY-1),z0=max(0,minZ-1),x1=min(n-2,maxX+1),y1=min(n-2,maxY+1),z1=min(n-2,maxZ+1);int[][] corners={{0,0,0},{1,0,0},{1,1,0},{0,1,0},{0,0,1},{1,0,1},{1,1,1},{0,1,1}},tets={{0,5,1,6},{0,1,2,6},{0,2,3,6},{0,3,7,6},{0,7,4,6},{0,4,5,6}};PVector[] p=new PVector[8];float[] v=new float[8];int[] ww=new int[8];for(int i=0;i<8;i++)p[i]=new PVector();
    for(int z=z0;z<=z1;z++)for(int y=y0;y<=y1;y++)for(int x=x0;x<=x1;x++){boolean ok=false;for(int c=0;c<8;c++){int xx=x+corners[c][0],yy=y+corners[c][1],zz=z+corners[c][2];p[c].set(origin.x+xx*voxelSize,origin.y+yy*voxelSize,origin.z+zz*voxelSize);v[c]=value(xx,yy,zz);ww[c]=w(xx,yy,zz);if(ww[c]>=minWeight)ok=true;}if(!ok)continue;for(int[] t:tets)polygonizeTet(out,p,v,ww,t,minWeight);}
    out.recalculateNormals();return out;
  }
  PVector interp(PVector a,PVector b,float va,float vb){float d=va-vb,t=abs(d)<1e-7f?0.5f:constrain(va/d,0,1);return new PVector(lerp(a.x,b.x,t),lerp(a.y,b.y,t),lerp(a.z,b.z,t));}
  void polygonizeTet(Mesh3D out,PVector[] p,float[] v,int[] ww,int[] t,int minWeight){for(int i=0;i<4;i++)if(ww[t[i]]<minWeight)return;int[] inside=new int[4],outside=new int[4];int ni=0,no=0;for(int i=0;i<4;i++){if(v[t[i]]<0)inside[ni++]=t[i];else outside[no++]=t[i];}if(ni==0||ni==4)return;if(ni==1||ni==3){boolean invert=ni==3;int a=invert?outside[0]:inside[0];int[] others=new int[3];if(invert){others[0]=inside[0];others[1]=inside[1];others[2]=inside[2];}else{others[0]=outside[0];others[1]=outside[1];others[2]=outside[2];}PVector p0=interp(p[a],p[others[0]],v[a],v[others[0]]),p1=interp(p[a],p[others[1]],v[a],v[others[1]]),p2=interp(p[a],p[others[2]],v[a],v[others[2]]);if(invert)out.addTriangle(p0,p2,p1,sampleColor(p0),sampleColor(p2),sampleColor(p1));else out.addTriangle(p0,p1,p2,sampleColor(p0),sampleColor(p1),sampleColor(p2));}else{int a=inside[0],b=inside[1],c=outside[0],d=outside[1];PVector ac=interp(p[a],p[c],v[a],v[c]),ad=interp(p[a],p[d],v[a],v[d]),bc=interp(p[b],p[c],v[b],v[c]),bd=interp(p[b],p[d],v[b],v[d]);out.addTriangle(ac,bc,ad,sampleColor(ac),sampleColor(bc),sampleColor(ad));out.addTriangle(ad,bc,bd,sampleColor(ad),sampleColor(bc),sampleColor(bd));}}
}

// ===== SynKinect Studio / 3D Scanner / UI.pde =====
class ScannerUI {
  final int ACTION_START=0, ACTION_PAUSE=1, ACTION_RESET=2, ACTION_MESH=3;
  final int ACTION_STL=4, ACTION_OBJ=5, ACTION_PLY=6, ACTION_CLEAN=7, ACTION_SMOOTH=8, ACTION_CENTER=9, ACTION_UNDO=10, ACTION_CALIBRATE=11;
  final int BUTTON_NORMAL=0, BUTTON_PRIMARY=1, BUTTON_QUIET=2;

 final ArrayList<UiButton> buttons = new ArrayList<UiButton>();
 final ArrayList<UiActionGroup> groups = new ArrayList<UiActionGroup>();
  float previewX, previewY, previewW, previewH;

  ScannerUI() {
    UiActionGroup capture = group("group.capture");
    capture.add(button("button.start", ACTION_START, BUTTON_PRIMARY));
    capture.add(button("button.pause", ACTION_PAUSE, BUTTON_NORMAL));
    capture.add(button("button.reset", ACTION_RESET, BUTTON_QUIET));
    capture.add(button("button.calibrate", ACTION_CALIBRATE, BUTTON_NORMAL));

    UiActionGroup meshGroup = group("group.mesh");
    meshGroup.add(button("button.mesh", ACTION_MESH, BUTTON_PRIMARY));
    meshGroup.add(button("button.clean", ACTION_CLEAN, BUTTON_NORMAL));
    meshGroup.add(button("button.smooth", ACTION_SMOOTH, BUTTON_NORMAL));
    meshGroup.add(button("button.center", ACTION_CENTER, BUTTON_NORMAL));
    meshGroup.add(button("button.undo", ACTION_UNDO, BUTTON_QUIET));

    UiActionGroup exportGroup = group("group.export");
    exportGroup.add(button("button.stl", ACTION_STL, BUTTON_NORMAL));
    exportGroup.add(button("button.obj", ACTION_OBJ, BUTTON_NORMAL));
    exportGroup.add(button("button.ply", ACTION_PLY, BUTTON_NORMAL));

  }

  UiActionGroup group(String key) { UiActionGroup g=new UiActionGroup(key); groups.add(g); return g; }
  UiButton button(String key,int action,int style) { UiButton b=new UiButton(key,action,style); buttons.add(b); return b; }

  void draw() {
    drawHeader();
    float m=studio.services.uiTheme.MARGIN, gap=studio.services.uiTheme.GAP;
    float top=studio.services.uiTheme.HEADER_H+studio.services.uiTheme.GAP;
    float toolbarY=studio.contentHeight-studio.services.uiTheme.TOOLBAR_H-studio.services.uiTheme.MARGIN;
    float bodyH=max(80, toolbarY-top-studio.services.uiTheme.GAP);
    float sideW=constrain(width*0.285f,210,min(studio.services.uiTheme.SIDEBAR_W,max(220,width*.43f)));
    float mainX=m+sideW+gap, mainW=max(180,width-mainX-m);

    float rgbH=max(34,(bodyH-gap)*0.5f);
    drawRgbCard(m,top,sideW,rgbH);
    drawDepthCard(m,top+rgbH+gap,sideW,max(34,bodyH-rgbH-gap));
    drawReconstructionCard(mainX,top,mainW,bodyH);
    drawToolbar(m,toolbarY,width-2*m,studio.services.uiTheme.TOOLBAR_H);
  }

  void drawHeader() {
    noStroke(); fill(studio.services.uiTheme.BG); rect(0,0,width,studio.services.uiTheme.HEADER_H);
    fill(studio.services.uiTheme.ACCENT_SOFT); rect(0,studio.services.uiTheme.HEADER_H-2,width,2);
    textAlign(studio.scannerState.i18n.startAlign(),CENTER); uiText(studio.services.uiTheme.FONT_TITLE,true); fill(studio.services.uiTheme.TEXT);
    float tx=studio.scannerState.i18n.rtl?width-studio.services.uiTheme.MARGIN:studio.services.uiTheme.MARGIN;
    String headerTitle=studio.scannerState.i18n.tr("app.title");fitCurrentTextSize(headerTitle,studio.services.uiTheme.FONT_TITLE,10,max(80,width-330),studio.services.uiTheme.HEADER_H-12);text(ellipsizeToWidth(headerTitle,max(80,width-330)),tx,studio.services.uiTheme.HEADER_H*0.5f);

    float x=width-studio.services.uiTheme.MARGIN-18;
    boolean depth=studio.scannerState.source!=null&&studio.scannerState.source.depthConnected;
    boolean rgb=studio.scannerState.source!=null&&studio.scannerState.source.colorConnected;
    boolean port=studio.scannerState.source!=null&&studio.scannerState.source.portReady;
    drawStateDot(x,33,"D",depth); x-=42;
    drawStateDot(x,33,"R",rgb); x-=42;
    drawStateDot(x,33,"P",port);
    textAlign(LEFT,BASELINE);
  }

  void drawStateDot(float x,float y,String label,boolean active) {
    noStroke(); fill(active?studio.services.uiTheme.ACCENT:studio.services.uiTheme.BORDER); ellipse(x,y,8,8);
    fill(studio.services.uiTheme.TEXT_MUTED); textAlign(CENTER,CENTER); uiText(studio.services.uiTheme.FONT_TINY,true); text(label,x+14,y); textAlign(LEFT,BASELINE);
  }

  void drawRgbCard(float x,float y,float w,float h) {
    card(x,y,w,h); cardTitle(x,y,w,studio.scannerState.i18n.tr("panel.rgb"));
    float px=x+10, py=y+studio.services.uiTheme.CARD_TITLE_H, pw=w-20, ph=max(80,h-studio.services.uiTheme.CARD_TITLE_H-42);
    previewSurface(px,py,pw,ph);
    if(studio.scannerState.colorPreview!=null) imageFit(studio.scannerState.colorPreview,px,py,pw,ph); else drawWaiting(px,py,pw,ph,studio.scannerState.i18n.tr("waiting.rgb"));
    boolean rgb=studio.scannerState.source!=null&&studio.scannerState.source.colorConnected;
    drawCompactFooter(x,y,w,h,studio.scannerState.i18n.tr("chip.rgb"),rgb,rgbFooterValue());
  }

  String rgbFooterValue(){
    String frames=studio.scannerState.source==null?"0":String.valueOf(studio.scannerState.source.colorFrames);
    if(studio.scannerState.source!=null)frames+="  ·  pairs "+studio.scannerState.source.queuedRgbdPairs()+"/"+studio.scannerState.config.rgbdQueueFrames;
    if(Float.isNaN(studio.scannerState.latestRgbDepthSkewMs))return frames;
    String value=frames+"  ·  "+studio.scannerState.i18n.tr("chip.sync")+" "+nf(studio.scannerState.latestRgbDepthSkewMs,1,1)+" ms";
    if(studio.scannerState.rgbRegistration!=null&&(abs(studio.scannerState.rgbRegistration.autoOffsetX)>0.05f||abs(studio.scannerState.rgbRegistration.autoOffsetY)>0.05f))
      value+="  ·  Δxy "+nf(studio.scannerState.rgbRegistration.autoOffsetX,1,1)+","+nf(studio.scannerState.rgbRegistration.autoOffsetY,1,1);
    return value;
  }

  void drawDepthCard(float x,float y,float w,float h) {
    card(x,y,w,h); cardTitle(x,y,w,studio.scannerState.i18n.tr("panel.depth"));
    float footerH=64;
    float px=x+10,py=y+studio.services.uiTheme.CARD_TITLE_H,pw=w-20,ph=max(90,h-studio.services.uiTheme.CARD_TITLE_H-footerH-8);
    previewSurface(px,py,pw,ph);
    if(studio.scannerState.depthPreview!=null) imageFit(studio.scannerState.depthPreview,px,py,pw,ph); else drawWaiting(px,py,pw,ph,studio.scannerState.i18n.tr("waiting.depth"));

    boolean depthOk=studio.scannerState.source!=null&&studio.scannerState.source.depthConnected;
    boolean metric=studio.scannerState.latestDepth!=null&&studio.scannerState.latestDepth.deviceCalibrated;
    float fy=py+ph+9;
    miniState(x+10,fy,76,studio.scannerState.i18n.tr("chip.depth"),depthOk);
    miniState(x+92,fy,92,studio.scannerState.i18n.tr("chip.metric"),metric);
    boolean profile=studio.scannerState.calibration!=null&&studio.scannerState.calibration.hasDepthCorrection();
    miniState(x+190,fy,102,studio.scannerState.i18n.tr("chip.profile"),profile);

    String value="—";
    if(studio.scannerState.latestDepthDiagnostics!=null&&studio.scannerState.latestDepthDiagnostics.plausiblePixels>0){
      value=nf(studio.scannerState.latestDepthDiagnostics.medianMm/1000.0f,1,2)+" m  ·  "+nf(studio.scannerState.latestDepthDiagnostics.plausibleRatio*100.0f,1,1)+"%";
      if(studio.scannerState.source!=null)value+="  ·  q "+studio.scannerState.source.queuedRgbdPairs()+"/"+studio.scannerState.config.rgbdQueueFrames+" → "+reconstructionQueuedFrames()+"/"+studio.scannerState.config.reconstructionQueueFrames;
    }
    fill(studio.services.uiTheme.TEXT_MUTED); uiText(studio.services.uiTheme.FONT_SMALL,false); textAlign(studio.scannerState.i18n.startAlign(),CENTER);
    fitCurrentTextSize(value,studio.services.uiTheme.FONT_SMALL,7,w-20,24);text(ellipsizeToWidth(value,w-20),studio.scannerState.i18n.rtl?x+w-10:x+10,y+h-16); textAlign(LEFT,BASELINE);
  }

  void drawCompactFooter(float x,float y,float w,float h,String label,boolean active,String value) {
    float cy=y+h-20;
    noStroke(); fill(active?studio.services.uiTheme.ACCENT:studio.services.uiTheme.BORDER); ellipse(x+16,cy,7,7);
    fill(studio.services.uiTheme.TEXT_MUTED); uiText(studio.services.uiTheme.FONT_SMALL,false); textAlign(LEFT,CENTER);String footer=label+"  "+value;fitCurrentTextSize(footer,studio.services.uiTheme.FONT_SMALL,7,w-41,24);text(ellipsizeToWidth(footer,w-41),x+27,cy); textAlign(LEFT,BASELINE);
  }

  void miniState(float x,float y,float w,String label,boolean active) {
    noStroke(); fill(studio.services.uiTheme.SURFACE_ALT); rect(x,y,w,24,7);
    fill(active?studio.services.uiTheme.ACCENT:studio.services.uiTheme.TEXT_MUTED); ellipse(x+11,y+12,6,6);
    fill(studio.services.uiTheme.TEXT_MUTED); uiText(studio.services.uiTheme.FONT_TINY,false); textAlign(LEFT,CENTER);fitCurrentTextSize(label,studio.services.uiTheme.FONT_TINY,7,w-26,20);text(ellipsizeToWidth(label,w-26),x+20,y+12); textAlign(LEFT,BASELINE);
  }

  void drawReconstructionCard(float x,float y,float w,float h) {
    card(x,y,w,h); cardTitle(x,y,w,studio.scannerState.i18n.tr("panel.reconstruction"));
    float statsH=128;
    previewX=x+10; previewY=y+studio.services.uiTheme.CARD_TITLE_H; previewW=w-20; previewH=max(220,h-studio.services.uiTheme.CARD_TITLE_H-statsH-10);
    previewSurface(previewX,previewY,previewW,previewH);
    draw3DPreview(previewX,previewY,previewW,previewH);
    drawPreviewOverlay(previewX,previewY,previewW,previewH);
    drawStatusArea(x+10,previewY+previewH+8,w-20,statsH);
  }

  void drawPreviewOverlay(float x,float y,float w,float h) {
    boolean complete=studio.scannerState.uiScanComplete;
    String scanState=complete?studio.scannerState.i18n.tr("scan.complete"):(studio.scannerState.scanActive?(studio.scannerState.scanPaused?studio.scannerState.i18n.tr("scan.paused"):studio.scannerState.i18n.tr("scan.active")):studio.scannerState.i18n.tr("scan.idle"));
    drawChip(x+w-132,y+10,122,28,scanState,studio.scannerState.scanActive&&!studio.scannerState.scanPaused,studio.services.uiTheme.ACCENT);
    fill(studio.services.uiTheme.TEXT_MUTED); uiText(studio.services.uiTheme.FONT_TINY,false); textAlign(LEFT,CENTER);String orbitHint=studio.scannerState.i18n.tr("hint.orbit.short");fitCurrentTextSize(orbitHint,studio.services.uiTheme.FONT_TINY,7,max(40,w-160),24);text(ellipsizeToWidth(orbitHint,max(40,w-160)),x+12,y+24); textAlign(LEFT,BASELINE);
  }

  void drawStatusArea(float x,float y,float w,float h) {
    noStroke(); fill(studio.services.uiTheme.SURFACE_ALT); rect(x,y,w,h,10);
    float progress=constrain(studio.scannerState.uiProgress,0,1);
    String targetMetric=targetValue(),icpMetric=icpValue();
    long integratedMetric=studio.scannerState.integratedFrames;
    float barX=x+12,barY=y+12,barW=w-24;
    fill(studio.services.uiTheme.BORDER); rect(barX,barY,barW,6,3);
    fill(studio.services.uiTheme.ACCENT); rect(barX,barY,barW*progress,6,3);

    float ty=y+34, gap=10, tw=(w-24-gap*3)/4.0f;
    metricTile(x+12,ty,tw,60,studio.scannerState.i18n.tr("label.target"),targetMetric);
    metricTile(x+12+(tw+gap),ty,tw,60,studio.scannerState.i18n.tr("label.icp"),icpMetric);
    metricTile(x+12+2*(tw+gap),ty,tw,60,studio.scannerState.i18n.tr("label.integrated"),String.valueOf(integratedMetric));
    metricTile(x+12+3*(tw+gap),ty,tw,60,studio.scannerState.i18n.tr("label.progress"),nf(progress*100,1,0)+"%");

    String sourceStatus=studio.scannerState.source==null?"":studio.scannerState.source.displayError();
    String message=sourceStatus.length()>0?sourceStatus:studio.scannerState.status;
    if(message==null||message.length()==0) message=studio.scannerState.i18n.tr("status.ready");
    fill(sourceStatus.length()>0?studio.services.uiTheme.WARN:studio.services.uiTheme.TEXT_MUTED); ellipse(x+15,y+h-15,6,6);
    fill(studio.services.uiTheme.TEXT_MUTED); uiText(studio.services.uiTheme.FONT_TINY,false); textAlign(LEFT,CENTER);fitCurrentTextSize(message,studio.services.uiTheme.FONT_TINY,7,w-42,24);text(ellipsizeToWidth(message,w-42),x+25,y+h-15); textAlign(LEFT,BASELINE);
  }

  String targetValue() {
    float depth=studio.scannerState.uiTargetDepthM;
    if(Float.isNaN(depth)) return "—";
    return nf(depth,1,2)+" m";
  }

  String icpValue() {
    float rms=studio.scannerState.uiIcpRmsMm;
    if(!studio.scannerState.uiTrackingGood||Float.isNaN(rms)) return "—";
    return nf(rms,1,1)+" mm";
  }

  void metricTile(float x,float y,float w,float h,String label,String value) {
    noStroke(); fill(studio.services.uiTheme.SURFACE_RAISED); rect(x,y,w,h,8);
    fill(studio.services.uiTheme.TEXT_MUTED); uiText(studio.services.uiTheme.FONT_TINY,true); textAlign(CENTER,CENTER);fitCurrentTextSize(label,studio.services.uiTheme.FONT_TINY,7,w-12,22);text(ellipsizeToWidth(label,w-12),x+w/2,y+15);
    fill(studio.services.uiTheme.TEXT); uiText(studio.services.uiTheme.FONT_METRIC,true);fitCurrentTextSize(value,studio.services.uiTheme.FONT_METRIC,8,w-12,26);text(ellipsizeToWidth(value,w-12),x+w/2,y+36); textAlign(LEFT,BASELINE);
  }

  void drawToolbar(float x,float y,float w,float h) {
    float[] weights={0.23f,0.36f,0.29f,0.12f};
    float gap=studio.services.uiTheme.GAP, cx=x;
    for(int i=0;i<groups.size();i++) {
      float gw=(i==groups.size()-1)?x+w-cx:w*weights[i]-gap*(groups.size()-1)/groups.size();
      drawActionPanel(groups.get(i),cx,y,gw,h);
      cx+=gw+gap;
    }
  }

  void drawActionPanel(UiActionGroup group,float x,float y,float w,float h) {
    card(x,y,w,h);
    fill(studio.services.uiTheme.TEXT_MUTED); uiText(studio.services.uiTheme.FONT_TINY,true); textAlign(LEFT,CENTER);String groupTitle=studio.scannerState.i18n.tr(group.labelKey);fitCurrentTextSize(groupTitle,studio.services.uiTheme.FONT_TINY,7,w-20,24);text(ellipsizeToWidth(groupTitle,w-20),x+10,y+17); textAlign(LEFT,BASELINE);
    float bx=x+9, by=y+31, gap=6, bh=h-40;
    int count=max(1,group.items.size()); float bw=(w-18-gap*(count-1))/count;
    for(int i=0;i<group.items.size();i++) {
      UiButton item=group.items.get(i);
      item.setBounds(bx+i*(bw+gap),by,bw,bh);
      item.draw();
    }
  }

  void card(float x,float y,float w,float h) { stroke(studio.services.uiTheme.BORDER); strokeWeight(1); fill(studio.services.uiTheme.SURFACE); rect(x,y,w,h,studio.services.uiTheme.RADIUS); noStroke(); }
  void cardTitle(float x,float y,float w,String title) {
    fill(studio.services.uiTheme.TEXT); uiText(studio.services.uiTheme.FONT_SMALL,true); textAlign(studio.scannerState.i18n.startAlign(),CENTER);
    fitCurrentTextSize(title,studio.services.uiTheme.FONT_SMALL,7,w-24,studio.services.uiTheme.CARD_TITLE_H-8);text(ellipsizeToWidth(title,w-24),studio.scannerState.i18n.rtl?x+w-12:x+12,y+studio.services.uiTheme.CARD_TITLE_H*0.5f); textAlign(LEFT,BASELINE);
  }
  void previewSurface(float x,float y,float w,float h) { noStroke(); fill(studio.services.uiTheme.PREVIEW); rect(x,y,w,h,9); }
  void drawWaiting(float x,float y,float w,float h,String message) { fill(studio.services.uiTheme.TEXT_MUTED); textAlign(CENTER,CENTER); uiText(studio.services.uiTheme.FONT_BODY,false);fitCurrentTextSize(message,studio.services.uiTheme.FONT_BODY,8,w-18,h-12);text(ellipsizeToWidth(message,w-18),x+w/2,y+h/2); textAlign(LEFT,BASELINE); }
  void imageFit(PImage img,float x,float y,float w,float h) {
    if(img==null||img.width<=0||img.height<=0)return;
    float s=min(w/img.width,h/img.height),dw=img.width*s,dh=img.height*s; image(img,x+(w-dw)/2,y+(h-dh)/2,dw,dh);
  }

  void draw3DPreview(float x,float y,float w,float h) {
    Mesh3D renderMesh=studio.scannerState.mesh;
    PointCloud ref=null;
    if(renderMesh==null||renderMesh.triangleCount()==0)ref=studio.scannerState.uiPreviewCloud;
    if(studio.scannerState.viewport3D==null)studio.scannerState.viewport3D=new Scanner3DViewport();
    studio.scannerState.viewport3D.draw(x,y,w,h,renderMesh,ref);
  }

  void drawChip(float x,float y,float w,float h,String label,boolean active,int tint) {
    noStroke(); fill(active?studio.services.uiTheme.SURFACE_RAISED:studio.services.uiTheme.SURFACE_ALT); rect(x,y,w,h,h/2);
    fill(active?tint:studio.services.uiTheme.TEXT_MUTED); textAlign(CENTER,CENTER); uiText(studio.services.uiTheme.FONT_TINY,true);fitCurrentTextSize(label,studio.services.uiTheme.FONT_TINY,7,w-10,h-6);text(ellipsizeToWidth(label,w-10),x+w/2,y+h/2); textAlign(LEFT,BASELINE);
  }

  String ellipsize(String s,int limit) { if(s==null)return ""; return s.length()<=limit?s:s.substring(0,max(0,limit-1))+"…"; }
  boolean isOver3D(float mx,float my){ return mx>=previewX&&mx<=previewX+previewW&&my>=previewY&&my<=previewY+previewH; }
  boolean handleMousePressed(float mx,float my){ for(UiButton b:buttons) if(b.hit(mx,my)&&b.enabled()){ b.fire(); return true; } return false; }
}

class Scanner3DViewport {
  PGraphics buffer=null;
  int bufferWidth=0,bufferHeight=0;
  Mesh3D cachedMesh=null;
  final ArrayList<PShape> meshChunks=new ArrayList<PShape>();
  int meshCursor=0;
  final int meshChunkTriangles=10000;

  void dispose(){buffer=null;bufferWidth=0;bufferHeight=0;cachedMesh=null;meshChunks.clear();meshCursor=0;}

  void ensureBuffer(int w,int h){
    w=max(64,w);h=max(64,h);
    if(buffer!=null&&bufferWidth==w&&bufferHeight==h)return;
    buffer=createGraphics(w,h,P3D);
    bufferWidth=w;bufferHeight=h;
    cachedMesh=null;meshChunks.clear();meshCursor=0;
  }

  void resetMeshCache(Mesh3D mesh){
    if(cachedMesh==mesh)return;
    cachedMesh=mesh;meshChunks.clear();meshCursor=0;
  }

  void buildNextMeshChunk(Mesh3D mesh){
    if(buffer==null||mesh==null||meshCursor>=mesh.triangles.size())return;
    int end=min(mesh.triangles.size(),meshCursor+meshChunkTriangles);
    PShape chunk=buffer.createShape();
    chunk.beginShape(TRIANGLES);chunk.noStroke();
    for(int i=meshCursor;i<end;i++){
      Triangle3D tri=mesh.triangles.get(i);
      chunk.normal(tri.n.x,tri.n.y,tri.n.z);
      chunk.fill(mesh.renderColor(tri.ca,studio.services.uiTheme.MESH));chunk.vertex(tri.a.x,tri.a.y,tri.a.z);
      chunk.fill(mesh.renderColor(tri.cb,studio.services.uiTheme.MESH));chunk.vertex(tri.b.x,tri.b.y,tri.b.z);
      chunk.fill(mesh.renderColor(tri.cc,studio.services.uiTheme.MESH));chunk.vertex(tri.c.x,tri.c.y,tri.c.z);
    }
    chunk.endShape();meshChunks.add(chunk);meshCursor=end;
  }

  void draw(float x,float y,float w,float h,Mesh3D renderMesh,PointCloud ref){
    int bw=max(64,round(w));int bh=max(64,round(h));
    ensureBuffer(bw,bh);resetMeshCache(renderMesh);

    PVector focusCenter=new PVector(0,0,0.75f);
    float sceneRadius=0.20f;
    if(renderMesh!=null&&renderMesh.triangleCount()>0){
      focusCenter=renderMesh.boundsCenter();sceneRadius=max(0.05f,renderMesh.boundsRadius());
    }else if(ref!=null&&ref.points!=null&&!ref.points.isEmpty()){
      float minX=Float.POSITIVE_INFINITY,minY=Float.POSITIVE_INFINITY,minZ=Float.POSITIVE_INFINITY;
      float maxX=Float.NEGATIVE_INFINITY,maxY=Float.NEGATIVE_INFINITY,maxZ=Float.NEGATIVE_INFINITY;
      for(PVector point:ref.points){
        if(point==null)continue;
        minX=min(minX,point.x);minY=min(minY,point.y);minZ=min(minZ,point.z);
        maxX=max(maxX,point.x);maxY=max(maxY,point.y);maxZ=max(maxZ,point.z);
      }
      if(minX<Float.POSITIVE_INFINITY){
        focusCenter.set((minX+maxX)*0.5f,(minY+maxY)*0.5f,(minZ+maxZ)*0.5f);
        sceneRadius=max(0.05f,dist(minX,minY,minZ,maxX,maxY,maxZ)*0.5f);
      }
    }

    float viewScale=max(1.0f,min(bw,bh)*0.42f/max(sceneRadius,0.02f))*studio.scannerState.previewZoom;
    float worldStroke=1.0f/max(1.0f,viewScale);
    float axisLen=max(sceneRadius*1.05f,0.08f);

    buffer.beginDraw();
    buffer.background(studio.services.uiTheme.PREVIEW);
    buffer.hint(ENABLE_DEPTH_TEST);
    buffer.ortho(-bw*0.5f,bw*0.5f,-bh*0.5f,bh*0.5f,-10000,10000);
    buffer.translate(bw*0.5f,bh*0.5f,0);
    buffer.ambientLight(92,92,100);
    buffer.directionalLight(224,224,224,-0.4f,0.6f,-1.0f);
    buffer.directionalLight(112,126,150,0.5f,-0.3f,-0.2f);
    buffer.scale(viewScale);
    buffer.rotateX(studio.scannerState.previewPitch);
    // Sensor-facing view: Kinect points extend along +Z. Processing's default
    // camera observes from +Z, which shows the cloud from the back and mirrors
    // left/right relative to the RGB image. Rotate 180° first so the 3D viewport
    // has the same left/right orientation as the physical scene seen by Kinect.
    buffer.rotateY(PI + studio.scannerState.previewYaw);
    buffer.translate(-focusCenter.x,-focusCenter.y,-focusCenter.z);

    drawGrid(focusCenter,sceneRadius,worldStroke);
    drawAxes(focusCenter,axisLen,worldStroke);

    buffer.stroke(studio.services.uiTheme.GRID);buffer.strokeWeight(worldStroke);buffer.noFill();
    buffer.pushMatrix();buffer.translate(focusCenter.x,focusCenter.y,focusCenter.z);
    buffer.box(sceneRadius*2.1f,sceneRadius*2.1f,sceneRadius*2.1f);buffer.popMatrix();

    if(renderMesh!=null&&renderMesh.triangleCount()>0){
      if(meshCursor<renderMesh.triangles.size())buildNextMeshChunk(renderMesh);
      for(PShape chunk:meshChunks)buffer.shape(chunk);
    }else if(ref!=null&&ref.points!=null){
      buffer.stroke(studio.services.uiTheme.ACCENT);buffer.strokeWeight(worldStroke*2.0f);buffer.beginShape(POINTS);
      for(PVector point:ref.points)if(point!=null)buffer.vertex(point.x,point.y,point.z);
      buffer.endShape();
    }
    buffer.noLights();buffer.hint(DISABLE_DEPTH_TEST);buffer.endDraw();

    // The 3D environment is an off-screen PGraphics instance. Rendering it as
    // one image guarantees that geometry cannot escape the reconstruction card
    // and cannot change the main Studio camera/projection used by other tabs.
    image(buffer,x,y,w,h);
  }

  void drawGrid(PVector center,float radius,float strokeWorld){
    float size=max(radius*1.6f,0.18f);int lines=10;float step=(size*2.0f)/lines;
    buffer.stroke(studio.services.uiTheme.BORDER);buffer.strokeWeight(strokeWorld);
    for(int i=0;i<=lines;i++){
      float d=-size+i*step;
      buffer.line(center.x-size,center.y,center.z+d,center.x+size,center.y,center.z+d);
      buffer.line(center.x+d,center.y,center.z-size,center.x+d,center.y,center.z+size);
    }
  }

  void drawAxes(PVector center,float axisLen,float strokeWorld){
    buffer.strokeWeight(strokeWorld*1.7f);
    buffer.stroke(220,92,92);buffer.line(center.x,center.y,center.z,center.x+axisLen,center.y,center.z);
    buffer.stroke(92,220,140);buffer.line(center.x,center.y,center.z,center.x,center.y-axisLen,center.z);
    buffer.stroke(92,150,232);buffer.line(center.x,center.y,center.z,center.x,center.y,center.z+axisLen);
  }
}

class UiActionGroup {
 final String labelKey; final ArrayList<UiButton> items=new ArrayList<UiButton>();
  UiActionGroup(String key){labelKey=key;}
  void add(UiButton button){items.add(button);}
}

class UiButton {
  float x,y,w,h; final String labelKey; final int action,style;
  UiButton(String labelKey,int action,int style){this.labelKey=labelKey;this.action=action;this.style=style;}
  void setBounds(float x,float y,float w,float h){this.x=x;this.y=y;this.w=w;this.h=h;}
  String label(){ if(action==studio.scannerState.ui.ACTION_PAUSE&&studio.scannerState.scanActive&&studio.scannerState.scanPaused)return studio.scannerState.i18n.tr("button.resume");if(action==studio.scannerState.ui.ACTION_CALIBRATE&&studio.scannerState.calibrationSession!=null&&studio.scannerState.calibrationSession.active)return studio.scannerState.i18n.tr("button.calibrate.cancel"); return studio.scannerState.i18n.tr(labelKey); }
  boolean enabled(){
    if(studio.scannerState.resetBusy)return false;
    if(studio.scannerState.meshBusy&&(action==studio.scannerState.ui.ACTION_START||action==studio.scannerState.ui.ACTION_RESET||action==studio.scannerState.ui.ACTION_MESH||action==studio.scannerState.ui.ACTION_CLEAN||action==studio.scannerState.ui.ACTION_SMOOTH||action==studio.scannerState.ui.ACTION_CENTER||action==studio.scannerState.ui.ACTION_UNDO||action==studio.scannerState.ui.ACTION_STL||action==studio.scannerState.ui.ACTION_OBJ||action==studio.scannerState.ui.ACTION_PLY||action==studio.scannerState.ui.ACTION_CALIBRATE))return false;
    if(action==studio.scannerState.ui.ACTION_PAUSE)return studio.scannerState.scanActive;
    if(action==studio.scannerState.ui.ACTION_CALIBRATE)return !studio.scannerState.scanActive&&studio.scannerState.latestDepth!=null;
    if(action==studio.scannerState.ui.ACTION_MESH)return studio.scannerState.volumeInitialized;
    if(action==studio.scannerState.ui.ACTION_CLEAN||action==studio.scannerState.ui.ACTION_SMOOTH||action==studio.scannerState.ui.ACTION_CENTER)return studio.scannerState.mesh!=null&&studio.scannerState.mesh.triangleCount()>0;
    if(action==studio.scannerState.ui.ACTION_UNDO)return studio.scannerState.meshUndo!=null;
    if(action==studio.scannerState.ui.ACTION_STL||action==studio.scannerState.ui.ACTION_OBJ||action==studio.scannerState.ui.ACTION_PLY)return studio.scannerState.volumeInitialized||(studio.scannerState.mesh!=null&&studio.scannerState.mesh.triangleCount()>0);
    return true;
  }
  void draw(){
    boolean en=enabled(),hot=en&&hit(studio.contentMouseX(),studio.contentMouseY());
    int base=style==studio.scannerState.ui.BUTTON_PRIMARY?studio.services.uiTheme.SURFACE_RAISED:studio.services.uiTheme.SURFACE_ALT;
    if(style==studio.scannerState.ui.BUTTON_QUIET)base=studio.services.uiTheme.SURFACE;
    stroke(hot?studio.services.uiTheme.ACCENT:studio.services.uiTheme.BORDER); strokeWeight(1); fill(en?(hot?studio.services.uiTheme.SURFACE_RAISED:base):studio.services.uiTheme.BG); rect(x,y,w,h,8); noStroke();
    fill(en?(style==studio.scannerState.ui.BUTTON_PRIMARY?studio.services.uiTheme.TEXT:studio.services.uiTheme.TEXT_MUTED):studio.services.uiTheme.BORDER); textAlign(CENTER,CENTER); uiText(studio.services.uiTheme.FONT_SMALL,true);String value=label();fitCurrentTextSize(value,studio.services.uiTheme.FONT_SMALL,7,w-12,h-8);text(ellipsizeToWidth(value,w-12),x+w/2,y+h/2); textAlign(LEFT,BASELINE);
  }
  boolean hit(float mx,float my){return mx>=x&&mx<=x+w&&my>=y&&my<=y+h;}
  void fire(){dispatchUiAction(action);}
}


