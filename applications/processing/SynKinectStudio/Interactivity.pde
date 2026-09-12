// ===== SynKinect Studio / Interactivity =====
// Interactivity owns its own RGB + metric-Depth transport instance.
// Scanner and Interactivity share calibration math, not a live connection. This keeps
// tab transitions independent: closing one module cannot stop or reconfigure another.
// The UI consumes immutable snapshots; the 3D tracker runs on its own latest-frame worker.
class InteractionModuleState {
  InteractionConfig config;
  InteractionI18n i18n;
  InteractionFrameProcessor processor;
  InteractionTracker3D tracker;
  InteractionRuntime runtime;
  KinectSource source;
  InteractionDesktopController desktop;
  InteractionOrbCloud cloud;
  InteractionUI ui;
  PImage rgbImage;
  InteractionSkeleton3D skeleton;
  long lastProcessedFrame=-1;
  volatile boolean controlEnabled=false;
  volatile String status="";
}

void setupInteractivityModule(){
  studio.interactionState.config=new InteractionConfig();studio.interactionState.config.load(new File(dataPath("interaction.properties")));
  studio.interactionState.i18n=new InteractionI18n(studio.currentLanguage());
  ensureRgbdCore();
  studio.interactionState.tracker=new InteractionTracker3D(studio.interactionState.config,studio.scannerState.config,studio.scannerState.calibration,studio.scannerState.rgbRegistration);
  studio.interactionState.processor=new InteractionFrameProcessor(studio.interactionState.config,studio.interactionState.tracker);
  studio.interactionState.desktop=new InteractionDesktopController(studio.interactionState.config);
  studio.interactionState.cloud=new InteractionOrbCloud(studio.interactionState.config);
  studio.interactionState.source=new KinectSource(studio.scannerState.config,studio.scannerState.calibration,studio.scannerState.i18n);
  studio.interactionState.source.setHqColorRequested(false);
  studio.interactionState.runtime=new InteractionRuntime(studio.interactionState.config,studio.interactionState.source,studio.interactionState.processor);
  studio.interactionState.ui=new InteractionUI();studio.interactionState.status=studio.interactionState.i18n.tr("status.ready");
}
void activateInteractivityModule(){
  studio.interactionState.lastProcessedFrame=-1;studio.interactionState.skeleton=null;studio.interactionState.rgbImage=null;
  if(studio.interactionState.tracker!=null)studio.interactionState.tracker.reset();
  // Interactivity always owns a fresh VGA RGB+Depth session.
  if(studio.interactionState.source!=null)studio.interactionState.source.setHqColorRequested(false);
  if(studio.interactionState.runtime!=null)studio.interactionState.runtime.start();
}
void requestDeactivateInteractivityModule(){
  studio.interactionState.controlEnabled=false;
  if(studio.interactionState.desktop!=null)studio.interactionState.desktop.setEnabled(false);
  if(studio.interactionState.cloud!=null)studio.interactionState.cloud.reset();
  if(studio.interactionState.runtime!=null)studio.interactionState.runtime.requestStop();
}
void deactivateInteractivityModule(){
  studio.interactionState.controlEnabled=false;
  if(studio.interactionState.desktop!=null)studio.interactionState.desktop.setEnabled(false);
  if(studio.interactionState.cloud!=null)studio.interactionState.cloud.reset();
  if(studio.interactionState.runtime!=null)studio.interactionState.runtime.stop(false);
}
void disposeInteractivityModule(){deactivateInteractivityModule();}
void drawInteractivityModule(){background(studio.services.acousticTheme.BG);serviceInteractivityFrames();if(studio.interactionState.cloud!=null)studio.interactionState.cloud.update(studio.interactionState.skeleton);if(studio.interactionState.ui!=null)studio.interactionState.ui.draw();}

// UI thread: immutable snapshots only. No transport or CV work executes here.
void serviceInteractivityFrames(){
  InteractionProcessedFrame p=studio.interactionState.processor==null?null:studio.interactionState.processor.latest();
  if(p!=null&&p.frameNumber!=studio.interactionState.lastProcessedFrame){studio.interactionState.lastProcessedFrame=p.frameNumber;studio.interactionState.skeleton=p.skeleton;applyInteractionRgbPreview(p.previewPixels);}
  if(studio.interactionState.desktop!=null){studio.interactionState.desktop.setEnabled(studio.interactionState.controlEnabled);if(studio.interactionState.controlEnabled&&studio.interactionState.skeleton!=null&&studio.interactionState.skeleton.tracked)studio.interactionState.desktop.update(studio.interactionState.skeleton);}
}
void applyInteractionRgbPreview(int[] pixels){if(pixels==null||pixels.length!=studio.services.scannerProtocol.WIDTH*studio.services.scannerProtocol.HEIGHT)return;if(studio.interactionState.rgbImage==null)studio.interactionState.rgbImage=createImage(studio.services.scannerProtocol.WIDTH,studio.services.scannerProtocol.HEIGHT,RGB);studio.interactionState.rgbImage.loadPixels();System.arraycopy(pixels,0,studio.interactionState.rgbImage.pixels,0,pixels.length);studio.interactionState.rgbImage.updatePixels();}
boolean interaction3dLive(){if(studio.interactionState.lastProcessedFrame>=0&&studio.interactionState.processor!=null&&millis64()-studio.interactionState.processor.lastPublishedMs<=studio.interactionState.config.streamStaleMs)return true;return studio.interactionState.runtime!=null&&studio.interactionState.runtime.streamsLive();}
void interactivityMousePressed(){if(studio.interactionState.ui!=null)studio.interactionState.ui.handleMouse(studio.contentMouseX(),studio.contentMouseY());}
void interactivityKeyPressed(){if(key=='e'||key=='E')toggleInteractionControl();}
void toggleInteractionControl(){if(!studio.interactionState.controlEnabled&&(studio.interactionState.desktop==null||!studio.interactionState.desktop.available())){studio.interactionState.controlEnabled=false;studio.interactionState.status=studio.interactionState.i18n.tr("status.desktop_unavailable");return;}studio.interactionState.controlEnabled=!studio.interactionState.controlEnabled;if(studio.interactionState.desktop!=null)studio.interactionState.desktop.setEnabled(studio.interactionState.controlEnabled);studio.interactionState.status=studio.interactionState.i18n.tr(studio.interactionState.controlEnabled?"status.control_on":"status.control_off");}
void cycleInteractionHand(){if(studio.interactionState.desktop!=null)studio.interactionState.desktop.cycleHand();}

class InteractionConfig {
  int workerJoinMs=2200,streamStaleMs=1800,previewHz=15;
  int minDepthMm=550,maxDepthMm=3800;
  float poseMinCoreConfidence=0.28f;
  int poseOcclusionHoldFrames=8;
  float poseFilterMinAlpha=0.18f,poseFilterMaxAlpha=0.78f,poseVelocityAlpha=0.22f,poseMaxSpeedMps=4.2f;
  int bodySampleStep=4,bodyDepthBinMm=80,bodyDepthBandMm=520,bodyContinuityMm=320,bodyMinSamples=90,bodyMinHeightPx=100,bodyHistogramCapSamples=1400;
  float bodyMaxWidthRatio=0.86f,bodyCenterBias=0.70f,bodyMinAspect=0.82f;
  int handLocalRadiusPx=22,handDepthToleranceMm=150;
  float handOpenRadiusMinPx=10.0f,handOpenRadiusMaxPx=28.0f;
  boolean mirrorX=true;String hand="right";int cursorMaxHz=60,cursorLostReleaseMs=800;float cursorDeadzonePx=1.8f,cursorFastAlpha=0.62f,cursorSlowAlpha=0.20f,cursorFastDistancePx=42;
  float volumeHalfWidthM=0.55f,volumeTopM=0.42f,volumeBottomM=0.48f,minHandForwardM=0.015f;
  float handOpenThreshold=0.62f,handCloseThreshold=0.38f;int twoHandStableMs=180,doubleClickStableMs=170,doubleClickCooldownMs=700,scrollCooldownMs=45;float scrollThresholdM=0.018f,scrollGainPerM=82.0f;
  int cloudParticles=300,cloudTrailSamples=22;float cloudRadiusPx=24,cloudSpring=42,cloudDamping=7,cloudFlow=0.24f,cloudTrailStrength=1,cloudStretchGain=0.020f,cloudMaxStretch=3;
  void load(File file){
    ConfigRules r=studio.services.configRules;Properties p=r.load(file,"interaction");
    workerJoinMs=r.integer(p,"transport.workerJoinMs",workerJoinMs,100,10000);streamStaleMs=r.integer(p,"transport.streamStaleMs",streamStaleMs,250,10000);previewHz=r.integer(p,"vision.previewHz",previewHz,1,30);minDepthMm=r.integer(p,"vision.minDepthMm",minDepthMm,300,6000);maxDepthMm=r.integer(p,"vision.maxDepthMm",maxDepthMm,minDepthMm+100,8000);
    poseMinCoreConfidence=r.decimal(p,"pose.minCoreConfidence",poseMinCoreConfidence,0.05f,0.95f);poseOcclusionHoldFrames=r.integer(p,"pose.occlusionHoldFrames",poseOcclusionHoldFrames,0,30);
    poseFilterMinAlpha=r.decimal(p,"pose.filterMinAlpha",poseFilterMinAlpha,0.03f,0.8f);poseFilterMaxAlpha=r.decimal(p,"pose.filterMaxAlpha",poseFilterMaxAlpha,poseFilterMinAlpha,1.0f);poseVelocityAlpha=r.decimal(p,"pose.velocityAlpha",poseVelocityAlpha,0.01f,0.9f);poseMaxSpeedMps=r.decimal(p,"pose.maxSpeedMps",poseMaxSpeedMps,0.5f,12.0f);
    bodySampleStep=r.integer(p,"body.sampleStep",bodySampleStep,2,8);bodyDepthBinMm=r.integer(p,"body.depthBinMm",bodyDepthBinMm,40,200);bodyDepthBandMm=r.integer(p,"body.depthBandMm",bodyDepthBandMm,180,900);bodyContinuityMm=r.integer(p,"body.continuityMm",bodyContinuityMm,80,700);bodyMinSamples=r.integer(p,"body.minSamples",bodyMinSamples,25,2000);bodyMinHeightPx=r.integer(p,"body.minHeightPx",bodyMinHeightPx,50,420);bodyHistogramCapSamples=r.integer(p,"body.histogramCapSamples",bodyHistogramCapSamples,100,10000);bodyMaxWidthRatio=r.decimal(p,"body.maxWidthRatio",bodyMaxWidthRatio,0.30f,1.0f);bodyCenterBias=r.decimal(p,"body.centerBias",bodyCenterBias,0,2.0f);bodyMinAspect=r.decimal(p,"body.minAspect",bodyMinAspect,0.35f,2.0f);
    handLocalRadiusPx=r.integer(p,"hand.localRadiusPx",handLocalRadiusPx,8,48);handDepthToleranceMm=r.integer(p,"hand.depthToleranceMm",handDepthToleranceMm,40,500);handOpenRadiusMinPx=r.decimal(p,"hand.openRadiusMinPx",handOpenRadiusMinPx,4,40);handOpenRadiusMaxPx=r.decimal(p,"hand.openRadiusMaxPx",handOpenRadiusMaxPx,handOpenRadiusMinPx+1,80);
    mirrorX=r.flag(p,"cursor.mirrorX",mirrorX);hand=r.text(p,"cursor.hand",hand).toLowerCase(Locale.ROOT);if(!"left".equals(hand)&&!"right".equals(hand))hand="right";cursorMaxHz=r.integer(p,"cursor.maxHz",cursorMaxHz,10,240);cursorLostReleaseMs=r.integer(p,"cursor.lostReleaseMs",cursorLostReleaseMs,100,5000);cursorDeadzonePx=r.decimal(p,"cursor.deadzonePx",cursorDeadzonePx,0,50);cursorFastAlpha=r.decimal(p,"cursor.fastAlpha",cursorFastAlpha,0.01f,1);cursorSlowAlpha=r.decimal(p,"cursor.slowAlpha",cursorSlowAlpha,0.01f,1);cursorFastDistancePx=r.decimal(p,"cursor.fastDistancePx",cursorFastDistancePx,1,300);volumeHalfWidthM=r.decimal(p,"cursor.volumeHalfWidthM",volumeHalfWidthM,.1f,2);volumeTopM=r.decimal(p,"cursor.volumeTopM",volumeTopM,.05f,2);volumeBottomM=r.decimal(p,"cursor.volumeBottomM",volumeBottomM,.05f,2);minHandForwardM=r.decimal(p,"cursor.minHandForwardM",minHandForwardM,-.5f,.5f);
    handOpenThreshold=r.decimal(p,"gesture.openThreshold",handOpenThreshold,.1f,.95f);handCloseThreshold=r.decimal(p,"gesture.closeThreshold",handCloseThreshold,.05f,handOpenThreshold-.02f);twoHandStableMs=r.integer(p,"gesture.twoHandStableMs",twoHandStableMs,0,3000);doubleClickStableMs=r.integer(p,"gesture.doubleClickStableMs",doubleClickStableMs,0,3000);doubleClickCooldownMs=r.integer(p,"gesture.doubleClickCooldownMs",doubleClickCooldownMs,0,5000);scrollCooldownMs=r.integer(p,"gesture.scrollCooldownMs",scrollCooldownMs,0,1000);scrollThresholdM=r.decimal(p,"gesture.scrollThresholdM",scrollThresholdM,.001f,.3f);scrollGainPerM=r.decimal(p,"gesture.scrollGainPerM",scrollGainPerM,1,500);
    cloudParticles=r.integer(p,"cloud.particles",cloudParticles,80,1200);cloudTrailSamples=r.integer(p,"cloud.trailSamples",cloudTrailSamples,6,80);cloudRadiusPx=r.decimal(p,"cloud.radiusPx",cloudRadiusPx,5,120);cloudSpring=r.decimal(p,"cloud.spring",cloudSpring,1,150);cloudDamping=r.decimal(p,"cloud.damping",cloudDamping,.1f,30);cloudFlow=r.decimal(p,"cloud.flow",cloudFlow,0,3);cloudTrailStrength=r.decimal(p,"cloud.trailStrength",cloudTrailStrength,.1f,4);cloudStretchGain=r.decimal(p,"cloud.stretchGain",cloudStretchGain,0,.2f);cloudMaxStretch=r.decimal(p,"cloud.maxStretch",cloudMaxStretch,1,12);
  }
}

class InteractionI18n extends ModuleI18n {InteractionI18n(String requested){super("interaction",requested);}}

class InteractionVisionSnapshot {
  final RgbdFramePair pair;final RawRgbFrame rgbFrame;final DepthFrame depthFrame;final long rgbFrameNumber,depthFrameNumber,rgbTickMs,depthTickMs,sequence;final float syncResidualMs;
  InteractionVisionSnapshot(RgbdFramePair p){pair=p;rgbFrame=p.rgb;depthFrame=p.depth;rgbFrameNumber=p.rgb.frameNumber;depthFrameNumber=p.depth.frameNumber;rgbTickMs=p.rgb.timestampUs/1000L;depthTickMs=p.depth.timestampUs/1000L;sequence=p.sequence;syncResidualMs=p.residualUs/1000.0f;}long key(){return sequence;}
}
class InteractionProcessedFrame {long frameNumber=-1,tickMs=0;int[] previewPixels;InteractionSkeleton3D skeleton;}

class InteractionFrameProcessor {
  final InteractionConfig cfg;final InteractionTracker3D tracker;final Object lock=new Object();volatile boolean running=false;volatile long runGeneration=0;volatile InteractionProcessedFrame published=null;volatile long lastPublishedMs=0;long lastPreviewMs=0;Thread worker;InteractionVisionSnapshot pending=null;
  InteractionFrameProcessor(InteractionConfig cfg,InteractionTracker3D tracker){this.cfg=cfg;this.tracker=tracker;}
  void start(){synchronized(lock){if(running)return;running=true;pending=null;published=null;final long generation=++runGeneration;worker=studio.services.workers.start("Interaction-3D-Fusion",new Runnable(){public void run(){loop(generation);}});}}
  void requestStop(){Thread t;synchronized(lock){running=false;++runGeneration;pending=null;lock.notifyAll();t=worker;worker=null;}if(t!=null&&t!=Thread.currentThread())t.interrupt();}
  void stop(){Thread t;synchronized(lock){running=false;++runGeneration;pending=null;lock.notifyAll();t=worker;worker=null;}if(t!=null&&t!=Thread.currentThread()){t.interrupt();try{t.join(min(1000,cfg.workerJoinMs));}catch(InterruptedException e){Thread.currentThread().interrupt();}}}
  void submit(InteractionVisionSnapshot f){if(f==null||f.rgbFrame==null||f.rgbFrame.data==null||f.depthFrame==null)return;synchronized(lock){if(!running)return;pending=f;lock.notifyAll();}}
  InteractionProcessedFrame latest(){return published;}
  void loop(long generation){while(true){InteractionVisionSnapshot f;synchronized(lock){while(running&&generation==runGeneration&&pending==null)try{lock.wait();}catch(InterruptedException e){if(!running||generation!=runGeneration)return;}if(!running||generation!=runGeneration)return;f=pending;pending=null;}try{InteractionProcessedFrame out=new InteractionProcessedFrame();out.frameNumber=f.key();out.tickMs=Math.max(f.rgbTickMs,f.depthTickMs);out.skeleton=tracker.track(f);long now=millis64();if(lastPreviewMs==0||now-lastPreviewMs>=1000/max(1,cfg.previewHz)){out.previewPixels=rgbPreview(f.rgbFrame);lastPreviewMs=now;}if(generation==runGeneration){published=out;lastPublishedMs=now;}}catch(Exception e){if(generation==runGeneration)println("Interactivity 3D processor warning: "+safeStudioMessage(e));}}}
  int[] rgbPreview(RawRgbFrame frame){int w=studio.services.scannerProtocol.WIDTH,h=studio.services.scannerProtocol.HEIGHT;if(frame==null||frame.data==null||frame.width!=w||frame.height!=h||frame.pixelFormat!=studio.services.scannerProtocol.PIXEL_BAYER_GRBG8||frame.data.length!=w*h)return null;int[] out=new int[w*h];return RgbHqProcessor.decodeBayerGrbg(frame.data,w,h,out)?out:null;}
}

class InteractionRuntime {
  final InteractionConfig cfg;final KinectSource source;final InteractionFrameProcessor processor;final Object lock=new Object();volatile boolean running=false;volatile long runGeneration=0;volatile long lastInputMs=0;Thread connectionWorker;long lastSubmitted=-1;
  InteractionRuntime(InteractionConfig c,KinectSource s,InteractionFrameProcessor p){cfg=c;source=s;processor=p;}
  void start(){synchronized(lock){if(running)return;running=true;final long generation=++runGeneration;lastInputMs=millis64();lastSubmitted=-1;source.start();processor.start();connectionWorker=studio.services.workers.start("Interaction-RGBD",new Runnable(){public void run(){connectionLoop(generation);}});}}
  void requestStop(){Thread t;synchronized(lock){running=false;++runGeneration;t=connectionWorker;connectionWorker=null;}if(t!=null&&t!=Thread.currentThread())t.interrupt();processor.requestStop();source.requestStop(true);}
  void stop(boolean keepRgbd){Thread t;synchronized(lock){running=false;++runGeneration;t=connectionWorker;connectionWorker=null;}if(t!=null&&t!=Thread.currentThread()){t.interrupt();try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}}processor.stop();if(!keepRgbd)source.stop(true);else source.clearConsumerPairs();}
  boolean streamsLive(){source.updateLiveness();long now=millis64();return source.running&&source.colorConnected&&source.depthConnected&&source.lastPairedArrivalMs>0&&now-source.lastPairedArrivalMs<=cfg.streamStaleMs;}
  void connectionLoop(long generation){while(running&&generation==runGeneration){try{source.updateLiveness();RgbdFramePair pair=source.latestRgbdPairAfter(lastSubmitted);if(pair!=null){lastSubmitted=pair.sequence;lastInputMs=millis64();processor.submit(new InteractionVisionSnapshot(pair));}Thread.sleep(2);}catch(InterruptedException e){if(!running||generation!=runGeneration)return;Thread.currentThread().interrupt();return;}catch(Exception e){if(running&&generation==runGeneration)println("Interactivity RGBD warning: "+safeStudioMessage(e));}}}
}

class InteractionJoint3D {
  final String name;PVector image=new PVector(),world=new PVector();float confidence=0;int state=0; // 0 lost, 1 inferred, 2 tracked
  InteractionJoint3D(String n){name=n;}InteractionJoint3D set(PVector uv,PVector xyz,float q,int s){if(uv!=null)image.set(uv);if(xyz!=null)world.set(xyz);confidence=q;state=s;return this;}boolean tracked(){return state>0&&confidence>0;}
}
class InteractionFinger3D {final String name;InteractionJoint3D base,tip;float confidence=0;InteractionFinger3D(String n){name=n;base=new InteractionJoint3D(n+"_base");tip=new InteractionJoint3D(n+"_tip");}}
class InteractionHandPose3D {boolean tracked=false;InteractionJoint3D wrist=new InteractionJoint3D("wrist"),palm=new InteractionJoint3D("palm");InteractionFinger3D[] fingers={new InteractionFinger3D("thumb"),new InteractionFinger3D("index"),new InteractionFinger3D("middle"),new InteractionFinger3D("ring"),new InteractionFinger3D("pinky")};int fingerCount=0;float palmRadiusPx=0,openness=0.5f,grabStrength=0.5f,pinchStrength=0,confidence=0;}
class InteractionSkeleton3D {
  boolean tracked=false;float confidence=0,torsoConfidence=0;String reason="searching";int minX,minY,maxX,maxY,samples=0;float meanDepthM=0,faceWidthPx=0,faceHeightPx=0;
  boolean clippedTop=false,clippedBottom=false;
  InteractionJoint3D head=new InteractionJoint3D("head"),neck=new InteractionJoint3D("neck"),chest=new InteractionJoint3D("chest"),spine=new InteractionJoint3D("spine");
  InteractionJoint3D leftShoulder=new InteractionJoint3D("left_shoulder"),rightShoulder=new InteractionJoint3D("right_shoulder"),leftElbow=new InteractionJoint3D("left_elbow"),rightElbow=new InteractionJoint3D("right_elbow"),leftWrist=new InteractionJoint3D("left_wrist"),rightWrist=new InteractionJoint3D("right_wrist"),leftHand=new InteractionJoint3D("left_hand"),rightHand=new InteractionJoint3D("right_hand");
  InteractionJoint3D pelvis=new InteractionJoint3D("pelvis"),leftHip=new InteractionJoint3D("left_hip"),rightHip=new InteractionJoint3D("right_hip"),leftKnee=new InteractionJoint3D("left_knee"),rightKnee=new InteractionJoint3D("right_knee"),leftAnkle=new InteractionJoint3D("left_ankle"),rightAnkle=new InteractionJoint3D("right_ankle"),leftFoot=new InteractionJoint3D("left_foot"),rightFoot=new InteractionJoint3D("right_foot");
  InteractionHandPose3D leftPose=new InteractionHandPose3D(),rightPose=new InteractionHandPose3D();float leftOpenness=0.5f,rightOpenness=0.5f;float lowerBodyConfidence=0;
  boolean faceTracked(){return head.tracked();}
  boolean torsoTracked(){return chest.tracked()&&leftShoulder.tracked()&&rightShoulder.tracked()&&(neck.tracked()||spine.tracked());}
  boolean leftArmTracked(){return leftShoulder.tracked()&&leftElbow.tracked()&&leftHand.tracked();}
  boolean rightArmTracked(){return rightShoulder.tracked()&&rightElbow.tracked()&&rightHand.tracked();}
  boolean pelvisTracked(){return pelvis.tracked()&&leftHip.tracked()&&rightHip.tracked();}
  boolean leftLegTracked(){return leftHip.tracked()&&leftKnee.tracked()&&leftAnkle.tracked();}
  boolean rightLegTracked(){return rightHip.tracked()&&rightKnee.tracked()&&rightAnkle.tracked();}
  boolean fullBodyTracked(){return torsoTracked()&&leftLegTracked()&&rightLegTracked();}
  boolean leftHandTracked(){return leftHand.tracked();}boolean rightHandTracked(){return rightHand.tracked();}
  PVector bodyCenterImage(){return chest.image;}
  InteractionJoint3D activeHand(String mode){if("left".equals(mode)&&leftHandTracked())return leftHand;if("right".equals(mode)&&rightHandTracked())return rightHand;if(rightHandTracked())return rightHand;if(leftHandTracked())return leftHand;return null;}
}
class InteractionCalibration3D {
  final AppConfig sharedCfg;final Calibration sharedCalibration;final RgbDepthRegistration sharedRegistration;
  InteractionCalibration3D(AppConfig c,Calibration cal,RgbDepthRegistration reg){sharedCfg=c;sharedCalibration=cal;sharedRegistration=reg;}
  PVector deproject(int u,int v,int mm){int uu=constrain(u,0,studio.services.scannerProtocol.WIDTH-1),vv=constrain(v,0,studio.services.scannerProtocol.HEIGHT-1),i=vv*studio.services.scannerProtocol.WIDTH+uu;float z=mm*sharedCalibration.depthScale;return new PVector(sharedRegistration.pointX(i,z),sharedRegistration.pointY(i,z),z);}
  PVector projectRgb(int u,int v,int mm){int uu=constrain(u,0,studio.services.scannerProtocol.WIDTH-1),vv=constrain(v,0,studio.services.scannerProtocol.HEIGHT-1),i=vv*studio.services.scannerProtocol.WIDTH+uu;float z=mm*sharedCalibration.depthScale;RgbProjection q=new RgbProjection();sharedRegistration.project(i,z,q,0,0);return q.valid?new PVector(q.u,q.v):null;}
  PVector projectDepth(PVector world){if(world==null||world.z<=0.001f)return null;return new PVector(sharedCalibration.fx*world.x/world.z+sharedCalibration.cx,sharedCalibration.fy*world.y/world.z+sharedCalibration.cy);}
  PVector projectWorldRgb(PVector world){PVector d=projectDepth(world);if(d==null)return null;int mm=round(world.z/max(1e-9f,sharedCalibration.depthScale));return projectRgb(round(d.x),round(d.y),mm);}
}

class InteractionBodyPoint {
  float x,y,confidence;boolean valid;
  InteractionBodyPoint(){}
  InteractionBodyPoint(float x,float y,float q){this.x=x;this.y=y;confidence=q;valid=true;}
}

// SynKinect Body V1 is an in-house, dependency-free pose engine.  It follows the
// same depth-first principle that made Kinect v1 practical: isolate a person in
// metric depth, derive a stable articulated hypothesis from the silhouette and
// body proportions, then lift every joint into calibrated 3D.  No neural runtime,
// downloaded model, Kinect SDK skeleton API or external CV library is involved.
class SynKinectBodyMask {
  final int width,height,step,gridW,gridH;final boolean[] mask;final int[] mm;
  int minGX=0,maxGX=0,minGY=0,maxGY=0,samples=0,seedDepthMm=0;float confidence=0,centerX=0,centerY=0;
  SynKinectBodyMask(int w,int h,int s){width=w;height=h;step=s;gridW=(w+s-1)/s;gridH=(h+s-1)/s;mask=new boolean[gridW*gridH];mm=new int[gridW*gridH];}
  int px(int gx){return constrain(gx*step+step/2,0,width-1);}int py(int gy){return constrain(gy*step+step/2,0,height-1);}
}

class SynKinectBodyEstimator {
  final InteractionConfig cfg;SynKinectBodyEstimator(InteractionConfig c){cfg=c;}
  SynKinectBodyMask segment(DepthFrame depth){
    int w=studio.services.scannerProtocol.WIDTH,h=studio.services.scannerProtocol.HEIGHT,step=max(2,cfg.bodySampleStep);
    if(depth==null||depth.depth==null||depth.depth.length<w*h)return null;
    SynKinectBodyMask out=new SynKinectBodyMask(w,h,step);
    int bins=max(1,(cfg.maxDepthMm-cfg.minDepthMm+cfg.bodyDepthBinMm-1)/cfg.bodyDepthBinMm);int[] hist=new int[bins],central=new int[bins];
    for(int gy=0;gy<out.gridH;gy++)for(int gx=0;gx<out.gridW;gx++){
      int x=out.px(gx),y=out.py(gy),mm=depth.depth[y*w+x]&0xffff,idx=gy*out.gridW+gx;out.mm[idx]=mm;
      if(mm<cfg.minDepthMm||mm>cfg.maxDepthMm)continue;int b=constrain((mm-cfg.minDepthMm)/cfg.bodyDepthBinMm,0,bins-1);hist[b]++;
      if(x>=w*.16f&&x<=w*.84f&&y>=h*.06f&&y<=h*.96f)central[b]++;
    }
    int bestBin=-1;double bestScore=-1;
    for(int b=0;b<bins;b++){
      if(hist[b]<max(16,cfg.bodyMinSamples/3))continue;double z=(cfg.minDepthMm+(b+.5)*cfg.bodyDepthBinMm)/1000.0;double centerRatio=central[b]/(double)max(1,hist[b]);double capped=min(hist[b],cfg.bodyHistogramCapSamples);double score=capped*(1.0+cfg.bodyCenterBias*centerRatio)/(z*z);
      if(score>bestScore){bestScore=score;bestBin=b;}
    }
    if(bestBin<0)return null;out.seedDepthMm=cfg.minDepthMm+bestBin*cfg.bodyDepthBinMm+cfg.bodyDepthBinMm/2;
    boolean[] candidate=new boolean[out.mask.length];
    for(int i=0;i<candidate.length;i++){int mm=out.mm[i];candidate[i]=mm>=cfg.minDepthMm&&mm<=cfg.maxDepthMm&&abs(mm-out.seedDepthMm)<=cfg.bodyDepthBandMm;}
    int[] labels=new int[candidate.length];Arrays.fill(labels,-1);int component=0,bestId=-1,bestCount=0;double bestComponentScore=-1;int[] queue=new int[candidate.length];
    for(int seed=0;seed<candidate.length;seed++){
      if(!candidate[seed]||labels[seed]>=0)continue;int qh=0,qt=0;queue[qt++]=seed;labels[seed]=component;int count=0,minGX=out.gridW,minGY=out.gridH,maxGX=-1,maxGY=-1;long sumX=0,sumY=0,sumD=0;int centerCount=0;
      while(qh<qt){int at=queue[qh++],gx=at%out.gridW,gy=at/out.gridW,dm=out.mm[at];count++;minGX=min(minGX,gx);maxGX=max(maxGX,gx);minGY=min(minGY,gy);maxGY=max(maxGY,gy);sumX+=out.px(gx);sumY+=out.py(gy);sumD+=dm;if(out.px(gx)>=w*.20f&&out.px(gx)<=w*.80f)centerCount++;
        for(int oy=-1;oy<=1;oy++)for(int ox=-1;ox<=1;ox++){if(ox==0&&oy==0)continue;int nx=gx+ox,ny=gy+oy;if(nx<0||ny<0||nx>=out.gridW||ny>=out.gridH)continue;int ni=ny*out.gridW+nx;if(!candidate[ni]||labels[ni]>=0)continue;int nd=out.mm[ni];if(abs(nd-dm)>cfg.bodyContinuityMm)continue;labels[ni]=component;queue[qt++]=ni;}
      }
      int bw=(maxGX-minGX+1)*step,bh=(maxGY-minGY+1)*step;float aspect=bh/(float)max(1,bw),widthRatio=bw/(float)w,centerRatio=centerCount/(float)max(1,count),meanDepth=(float)(sumD/(double)max(1,count));
      if(count>=cfg.bodyMinSamples&&bh>=cfg.bodyMinHeightPx&&widthRatio<=cfg.bodyMaxWidthRatio&&aspect>=cfg.bodyMinAspect){double score=count*(.70+.60*centerRatio)*(1.0+min(1.5f,aspect)*.20)/(max(.55f,meanDepth/1000.0f));if(score>bestComponentScore){bestComponentScore=score;bestId=component;bestCount=count;out.minGX=minGX;out.maxGX=maxGX;out.minGY=minGY;out.maxGY=maxGY;out.centerX=sumX/(float)count;out.centerY=sumY/(float)count;}}
      component++;
    }
    if(bestId<0)return null;for(int i=0;i<labels.length;i++)out.mask[i]=labels[i]==bestId;out.samples=bestCount;
    int bh=(out.maxGY-out.minGY+1)*step,bw=(out.maxGX-out.minGX+1)*step;float sizeScore=constrain(bestCount/(float)max(cfg.bodyMinSamples*4,1),0,1),shape=constrain((bh/(float)max(1,bw)-cfg.bodyMinAspect)/1.4f+.45f,.25f,1);out.confidence=constrain(.38f+.40f*sizeScore+.22f*shape,0,1);return out;
  }
}

class InteractionJointFilterState {PVector world=new PVector(),velocity=new PVector(),image=new PVector();long tickMs=0;int missing=0;boolean initialized=false;}
class InteractionPoseFilter {
  final InteractionConfig cfg;final HashMap<String,InteractionJointFilterState> states=new HashMap<String,InteractionJointFilterState>();
  InteractionPoseFilter(InteractionConfig c){cfg=c;}void reset(){states.clear();}
  InteractionJoint3D[] joints(InteractionSkeleton3D s){return new InteractionJoint3D[]{s.head,s.neck,s.chest,s.spine,s.pelvis,s.leftShoulder,s.rightShoulder,s.leftElbow,s.rightElbow,s.leftWrist,s.rightWrist,s.leftHand,s.rightHand,s.leftHip,s.rightHip,s.leftKnee,s.rightKnee,s.leftAnkle,s.rightAnkle,s.leftFoot,s.rightFoot};}
  void apply(InteractionSkeleton3D s,long tickMs,InteractionCalibration3D cal){for(InteractionJoint3D j:joints(s))filter(j,tickMs,cal);}
  void filter(InteractionJoint3D j,long tickMs,InteractionCalibration3D cal){if(j==null)return;InteractionJointFilterState st=states.get(j.name);if(st==null){st=new InteractionJointFilterState();states.put(j.name,st);}if(j.tracked()&&j.world.z>0){if(!st.initialized){st.world.set(j.world);st.image.set(clampUv(j.image));st.tickMs=tickMs;st.initialized=true;st.missing=0;j.image.set(st.image);return;}float dt=constrain((tickMs-st.tickMs)/1000.0f,.008f,.12f);PVector predicted=PVector.add(st.world,PVector.mult(st.velocity,dt));float residual=PVector.dist(predicted,j.world),motion=constrain(residual/.10f,0,1),alpha=lerp(cfg.poseFilterMinAlpha,cfg.poseFilterMaxAlpha,max(j.confidence,motion*.8f));PVector filtered=PVector.lerp(predicted,j.world,alpha);PVector vel=PVector.sub(filtered,st.world);vel.div(dt);if(vel.mag()>cfg.poseMaxSpeedMps)vel.mult(cfg.poseMaxSpeedMps/vel.mag());st.velocity=PVector.lerp(st.velocity,vel,cfg.poseVelocityAlpha);st.world.set(filtered);PVector uv=cal.projectWorldRgb(filtered);st.image.set(clampUv(uv!=null?uv:j.image));st.tickMs=tickMs;st.missing=0;j.world.set(st.world);j.image.set(st.image);}else if(st.initialized&&st.missing<cfg.poseOcclusionHoldFrames){st.missing++;float dt=constrain((tickMs-st.tickMs)/1000.0f,.008f,.12f);PVector predicted=PVector.add(st.world,PVector.mult(st.velocity,dt));PVector uv=cal.projectWorldRgb(predicted);if(uv!=null&&inside(uv)){st.world.set(predicted);st.image.set(clampUv(uv));st.tickMs=tickMs;j.world.set(st.world);j.image.set(st.image);j.confidence=max(.08f,.36f*(1-st.missing/(float)(cfg.poseOcclusionHoldFrames+1)));j.state=1;}}else st.missing++;}
  boolean inside(PVector p){return p.x>=0&&p.x<studio.services.scannerProtocol.WIDTH&&p.y>=0&&p.y<studio.services.scannerProtocol.HEIGHT;}
  PVector clampUv(PVector p){if(p==null)return new PVector();return new PVector(constrain(p.x,0,studio.services.scannerProtocol.WIDTH-1),constrain(p.y,0,studio.services.scannerProtocol.HEIGHT-1));}
}

class InteractionHandAnalyzer {
  final InteractionConfig cfg;final InteractionCalibration3D cal;InteractionHandAnalyzer(InteractionConfig c,InteractionCalibration3D calibration){cfg=c;cal=calibration;}
  InteractionHandPose3D analyze(InteractionJoint3D hand,InteractionJoint3D elbow,DepthFrame depth){InteractionHandPose3D p=new InteractionHandPose3D();if(hand==null||!hand.tracked()||hand.world.z<=0||depth==null||depth.depth==null)return p;PVector dp=cal.projectDepth(hand.world);if(dp==null)return p;p.tracked=true;p.wrist=copy("wrist",hand);p.palm=copy("palm",hand);p.confidence=hand.confidence;int w=studio.services.scannerProtocol.WIDTH,h=studio.services.scannerProtocol.HEIGHT,cx=round(dp.x),cy=round(dp.y),center=depthAt(depth,cx,cy);if(center<=0){p.openness=.5f;p.grabStrength=.5f;return p;}float maxR=0;int count=0,r=cfg.handLocalRadiusPx;for(int y=max(0,cy-r);y<=min(h-1,cy+r);y+=2)for(int x=max(0,cx-r);x<=min(w-1,cx+r);x+=2){int d=depthAt(depth,x,y);if(d>0&&abs(d-center)<=cfg.handDepthToleranceMm){float rr=dist(cx,cy,x,y);if(rr>maxR)maxR=rr;count++;}}p.palmRadiusPx=maxR;p.openness=constrain(map(maxR,cfg.handOpenRadiusMinPx,cfg.handOpenRadiusMaxPx,0,1),0,1);p.grabStrength=1-p.openness;p.fingerCount=round(p.openness*5);return p;}
  int depthAt(DepthFrame d,int x,int y){if(x<0||y<0||x>=studio.services.scannerProtocol.WIDTH||y>=studio.services.scannerProtocol.HEIGHT)return 0;return d.depth[y*studio.services.scannerProtocol.WIDTH+x]&0xffff;}
  InteractionJoint3D copy(String name,InteractionJoint3D src){return new InteractionJoint3D(name).set(src.image.copy(),src.world.copy(),src.confidence,src.state);}
}

class InteractionTracker3D {
  final InteractionConfig cfg;final AppConfig sharedCfg;final InteractionCalibration3D cal;final SynKinectBodyEstimator estimator;final InteractionPoseFilter poseFilter;final InteractionHandAnalyzer handAnalyzer;InteractionSkeleton3D previous;volatile int candidateCount=0,selectedSamples=0;volatile String lastReason="searching";
  InteractionTracker3D(InteractionConfig c,AppConfig sc,Calibration calibration,RgbDepthRegistration registration){cfg=c;sharedCfg=sc;cal=new InteractionCalibration3D(sc,calibration,registration);estimator=new SynKinectBodyEstimator(c);poseFilter=new InteractionPoseFilter(c);handAnalyzer=new InteractionHandAnalyzer(c,cal);}
  void reset(){previous=null;poseFilter.reset();lastReason="searching";candidateCount=selectedSamples=0;}
  InteractionSkeleton3D track(InteractionVisionSnapshot f){
    InteractionSkeleton3D s=new InteractionSkeleton3D();if(f==null||f.depthFrame==null||f.depthFrame.depth==null){lastReason=s.reason="no_rgbd";return s;}SynKinectBodyMask body=estimator.segment(f.depthFrame);if(body==null){lastReason=s.reason="no_person";return s;}candidateCount=1;selectedSamples=body.samples;s.samples=body.samples;
    int top=centralTop(body),bottom=body.py(body.maxGY),left=body.px(body.minGX),right=body.px(body.maxGX),height=max(1,bottom-top);if(height<cfg.bodyMinHeightPx){lastReason=s.reason="no_person";return s;}
    float centerX=centerAt(body,round(top+height*.46f),max(8,height/16));if(Float.isNaN(centerX))centerX=body.centerX;float torsoWidth=torsoWidth(body,top,height,centerX);if(torsoWidth<22){lastReason=s.reason="low_confidence";return s;}
    float q=body.confidence,headY=top+height*.075f,neckY=top+height*.195f,shoulderY=top+height*.245f,chestY=top+height*.34f,spineY=top+height*.445f,pelvisY=top+height*.56f,kneeY=top+height*.755f,ankleY=top+height*.915f,footY=top+height*.975f;
    float neckX=centerAt(body,round(neckY),max(6,height/40));if(Float.isNaN(neckX))neckX=centerX;float pelvisX=centerAt(body,round(pelvisY),max(8,height/36));if(Float.isNaN(pelvisX))pelvisX=centerX;
    float shoulderHalf=constrain(torsoWidth*.50f,14,studio.services.scannerProtocol.WIDTH*.22f),hipHalf=constrain(torsoWidth*.30f,10,studio.services.scannerProtocol.WIDTH*.16f);
    InteractionBodyPoint head=pointNear(body,centerAtOr(body,round(headY),max(5,height/45),centerX),headY,max(10,height/18),q);
    InteractionBodyPoint neck=pointNear(body,neckX,neckY,max(8,height/24),q),chest=pointNear(body,centerAtOr(body,round(chestY),max(8,height/38),centerX),chestY,max(8,height/25),q),spine=pointNear(body,centerAtOr(body,round(spineY),max(8,height/34),centerX),spineY,max(8,height/24),q),pelvis=pointNear(body,pelvisX,pelvisY,max(10,height/24),q);
    InteractionBodyPoint ls=pointNear(body,neckX-shoulderHalf,shoulderY,max(12,round(torsoWidth*.30f)),q),rs=pointNear(body,neckX+shoulderHalf,shoulderY,max(12,round(torsoWidth*.30f)),q);
    InteractionBodyPoint lh=pointNear(body,pelvisX-hipHalf,pelvisY,max(10,round(torsoWidth*.22f)),q),rh=pointNear(body,pelvisX+hipHalf,pelvisY,max(10,round(torsoWidth*.22f)),q);
    InteractionBodyPoint lhand=armEndpoint(body,ls,-1,pelvisY,torsoWidth,q),rhand=armEndpoint(body,rs,1,pelvisY,torsoWidth,q);
    InteractionBodyPoint lel=betweenOnMask(body,ls,lhand,.52f,max(14,round(torsoWidth*.35f)),q*.94f),rel=betweenOnMask(body,rs,rhand,.52f,max(14,round(torsoWidth*.35f)),q*.94f);
    InteractionBodyPoint lw=betweenOnMask(body,ls,lhand,.86f,max(10,round(torsoWidth*.25f)),q*.92f),rw=betweenOnMask(body,rs,rhand,.86f,max(10,round(torsoWidth*.25f)),q*.92f);
    InteractionBodyPoint lk=legPoint(body,-1,kneeY,pelvisX,torsoWidth,q),rk=legPoint(body,1,kneeY,pelvisX,torsoWidth,q),la=legPoint(body,-1,ankleY,pelvisX,torsoWidth,q),ra=legPoint(body,1,ankleY,pelvisX,torsoWidth,q),lf=legPoint(body,-1,footY,pelvisX,torsoWidth,q*.92f),rf=legPoint(body,1,footY,pelvisX,torsoWidth,q*.92f);
    s.head=joint("head",head,f.depthFrame);s.neck=joint("neck",neck,f.depthFrame);s.chest=joint("chest",chest,f.depthFrame);s.spine=joint("spine",spine,f.depthFrame);s.pelvis=joint("pelvis",pelvis,f.depthFrame);s.leftShoulder=joint("left_shoulder",ls,f.depthFrame);s.rightShoulder=joint("right_shoulder",rs,f.depthFrame);s.leftElbow=joint("left_elbow",lel,f.depthFrame);s.rightElbow=joint("right_elbow",rel,f.depthFrame);s.leftWrist=joint("left_wrist",lw,f.depthFrame);s.rightWrist=joint("right_wrist",rw,f.depthFrame);s.leftHand=joint("left_hand",lhand,f.depthFrame);s.rightHand=joint("right_hand",rhand,f.depthFrame);s.leftHip=joint("left_hip",lh,f.depthFrame);s.rightHip=joint("right_hip",rh,f.depthFrame);s.leftKnee=joint("left_knee",lk,f.depthFrame);s.rightKnee=joint("right_knee",rk,f.depthFrame);s.leftAnkle=joint("left_ankle",la,f.depthFrame);s.rightAnkle=joint("right_ankle",ra,f.depthFrame);s.leftFoot=joint("left_foot",lf,f.depthFrame);s.rightFoot=joint("right_foot",rf,f.depthFrame);
    poseFilter.apply(s,Math.max(f.rgbTickMs,f.depthTickMs),cal);clampSkeleton(s);s.leftPose=handAnalyzer.analyze(s.leftHand,s.leftElbow,f.depthFrame);s.rightPose=handAnalyzer.analyze(s.rightHand,s.rightElbow,f.depthFrame);s.leftOpenness=s.leftPose.openness;s.rightOpenness=s.rightPose.openness;
    s.torsoConfidence=avgTracked(new InteractionJoint3D[]{s.leftShoulder,s.rightShoulder,s.neck,s.chest,s.pelvis,s.leftHip,s.rightHip});s.lowerBodyConfidence=avgTracked(new InteractionJoint3D[]{s.leftHip,s.rightHip,s.leftKnee,s.rightKnee,s.leftAnkle,s.rightAnkle});float jointQ=avgTracked(allJoints(s));s.confidence=constrain(.58f*body.confidence+.42f*jointQ,0,1);s.tracked=s.torsoConfidence>=cfg.poseMinCoreConfidence&&s.confidence>=cfg.poseMinCoreConfidence*.92f;s.reason=s.tracked?"tracked":"low_confidence";lastReason=s.reason;
    if(s.tracked){deriveBounds(s);s.meanDepthM=meanDepth(s);s.faceWidthPx=constrain(torsoWidth*.34f,18,120);s.faceHeightPx=s.faceWidthPx*1.22f;previous=s;}return s;
  }
  int centralTop(SynKinectBodyMask b){float mid=(b.px(b.minGX)+b.px(b.maxGX))*.5f,half=max(18,(b.px(b.maxGX)-b.px(b.minGX))*.22f);for(int gy=b.minGY;gy<=b.maxGY;gy++)for(int gx=b.minGX;gx<=b.maxGX;gx++){int i=gy*b.gridW+gx;if(b.mask[i]&&abs(b.px(gx)-mid)<=half)return b.py(gy);}return b.py(b.minGY);}
  float centerAtOr(SynKinectBodyMask b,int y,int band,float fallback){float v=centerAt(b,y,band);return Float.isNaN(v)?fallback:v;}
  float centerAt(SynKinectBodyMask b,int y,int band){long sum=0;int n=0;for(int gy=b.minGY;gy<=b.maxGY;gy++){int py=b.py(gy);if(abs(py-y)>band)continue;for(int gx=b.minGX;gx<=b.maxGX;gx++){int i=gy*b.gridW+gx;if(b.mask[i]){sum+=b.px(gx);n++;}}}return n==0?Float.NaN:sum/(float)n;}
  float torsoWidth(SynKinectBodyMask b,int top,int height,float center){ArrayList<Integer> widths=new ArrayList<Integer>();for(int y=round(top+height*.28f);y<=round(top+height*.54f);y+=max(4,b.step)){int[] span=rowSpan(b,y,max(3,b.step));if(span[2]>=2)widths.add(span[1]-span[0]+b.step);}if(widths.isEmpty())return max(20,(b.px(b.maxGX)-b.px(b.minGX))*.36f);Collections.sort(widths);int idx=constrain(round((widths.size()-1)*.38f),0,widths.size()-1);return widths.get(idx);}
  int[] rowSpan(SynKinectBodyMask b,int y,int band){int lo=b.width,hi=-1,n=0;for(int gy=b.minGY;gy<=b.maxGY;gy++){if(abs(b.py(gy)-y)>band)continue;for(int gx=b.minGX;gx<=b.maxGX;gx++){int i=gy*b.gridW+gx;if(!b.mask[i])continue;int x=b.px(gx);lo=min(lo,x);hi=max(hi,x);n++;}}return new int[]{lo,hi,n};}
  InteractionBodyPoint pointNear(SynKinectBodyMask b,float x,float y,int radius,float q){int best=-1;float bestD=Float.MAX_VALUE;int rg=max(1,(radius+b.step-1)/b.step);int cg=constrain(round(x/b.step),0,b.gridW-1),cy=constrain(round(y/b.step),0,b.gridH-1);for(int gy=max(b.minGY,cy-rg);gy<=min(b.maxGY,cy+rg);gy++)for(int gx=max(b.minGX,cg-rg);gx<=min(b.maxGX,cg+rg);gx++){int i=gy*b.gridW+gx;if(!b.mask[i])continue;float dx=b.px(gx)-x,dy=b.py(gy)-y,d=dx*dx+dy*dy;if(d<bestD){bestD=d;best=i;}}if(best<0)return new InteractionBodyPoint();return new InteractionBodyPoint(b.px(best%b.gridW),b.py(best/b.gridW),q);}
  InteractionBodyPoint armEndpoint(SynKinectBodyMask b,InteractionBodyPoint shoulder,int side,float pelvisY,float torsoWidth,float q){if(shoulder==null||!shoulder.valid)return new InteractionBodyPoint();int best=-1;float bestScore=-1,center=b.centerX;for(int gy=b.minGY;gy<=b.maxGY;gy++){float y=b.py(gy);if(y<shoulder.y-torsoWidth*.65f||y>pelvisY+torsoWidth*.18f)continue;for(int gx=b.minGX;gx<=b.maxGX;gx++){int i=gy*b.gridW+gx;if(!b.mask[i])continue;float x=b.px(gx);if(side<0&&x>center-torsoWidth*.20f)continue;if(side>0&&x<center+torsoWidth*.20f)continue;float dx=x-shoulder.x,dy=y-shoulder.y,dist2=dx*dx+dy*dy;if(dist2<torsoWidth*torsoWidth*.10f)continue;float outward=side<0?max(0,shoulder.x-x):max(0,x-shoulder.x),score=dist2+outward*outward*.55f;if(score>bestScore){bestScore=score;best=i;}}}if(best<0)return pointNear(b,shoulder.x+side*torsoWidth*.18f,shoulder.y+torsoWidth*.70f,max(16,round(torsoWidth*.45f)),q*.60f);return new InteractionBodyPoint(b.px(best%b.gridW),b.py(best/b.gridW),q*.96f);}
  InteractionBodyPoint betweenOnMask(SynKinectBodyMask b,InteractionBodyPoint a,InteractionBodyPoint z,float t,int radius,float q){if(a==null||z==null||!a.valid||!z.valid)return new InteractionBodyPoint();return pointNear(b,lerp(a.x,z.x,t),lerp(a.y,z.y,t),radius,q);}
  InteractionBodyPoint legPoint(SynKinectBodyMask b,int side,float y,float center,float torsoWidth,float q){int band=max(8,round((b.py(b.maxGY)-b.py(b.minGY))*.035f));double sx=0,sy=0;int n=0;for(int gy=b.minGY;gy<=b.maxGY;gy++){if(abs(b.py(gy)-y)>band)continue;for(int gx=b.minGX;gx<=b.maxGX;gx++){int i=gy*b.gridW+gx;if(!b.mask[i])continue;float x=b.px(gx);if(side<0&&x>center-torsoWidth*.035f)continue;if(side>0&&x<center+torsoWidth*.035f)continue;sx+=x;sy+=b.py(gy);n++;}}if(n==0)return pointNear(b,center+side*torsoWidth*.22f,y,max(18,round(torsoWidth*.45f)),q*.55f);return new InteractionBodyPoint((float)(sx/n),(float)(sy/n),q);}
  InteractionJoint3D joint(String name,InteractionBodyPoint p,DepthFrame depth){InteractionJoint3D j=new InteractionJoint3D(name);if(p==null||!p.valid)return j;int[] m=nearestDepth(depth,round(p.x),round(p.y),10);if(m[2]<=0)return j;PVector image=cal.projectRgb(m[0],m[1],m[2]);if(image==null)image=new PVector(m[0],m[1]);return j.set(image,cal.deproject(m[0],m[1],m[2]),p.confidence,2);}
  int[] nearestDepth(DepthFrame depth,int cx,int cy,int radius){int w=studio.services.scannerProtocol.WIDTH,h=studio.services.scannerProtocol.HEIGHT,bx=-1,by=-1,bm=0;float bd=Float.MAX_VALUE;for(int r=0;r<=radius;r+=2)for(int y=max(0,cy-r);y<=min(h-1,cy+r);y++)for(int x=max(0,cx-r);x<=min(w-1,cx+r);x++){if(r>0&&x>cx-r&&x<cx+r&&y>cy-r&&y<cy+r)continue;int mm=depth.depth[y*w+x]&0xffff;if(mm<cfg.minDepthMm||mm>cfg.maxDepthMm)continue;float d=(x-cx)*(x-cx)+(y-cy)*(y-cy);if(d<bd){bd=d;bx=x;by=y;bm=mm;}}return new int[]{bx,by,bm};}
  void clampSkeleton(InteractionSkeleton3D s){for(InteractionJoint3D j:allJoints(s))if(j!=null&&j.tracked()){j.image.x=constrain(j.image.x,0,studio.services.scannerProtocol.WIDTH-1);j.image.y=constrain(j.image.y,0,studio.services.scannerProtocol.HEIGHT-1);}}
  InteractionJoint3D[] allJoints(InteractionSkeleton3D s){return new InteractionJoint3D[]{s.head,s.neck,s.chest,s.spine,s.pelvis,s.leftShoulder,s.rightShoulder,s.leftElbow,s.rightElbow,s.leftWrist,s.rightWrist,s.leftHand,s.rightHand,s.leftHip,s.rightHip,s.leftKnee,s.rightKnee,s.leftAnkle,s.rightAnkle,s.leftFoot,s.rightFoot};}
  float avgTracked(InteractionJoint3D[] js){float sum=0;int n=0;for(InteractionJoint3D j:js)if(j!=null&&j.tracked()){sum+=j.confidence;n++;}return n==0?0:sum/n;}
  void deriveBounds(InteractionSkeleton3D s){int minX=studio.services.scannerProtocol.WIDTH-1,minY=studio.services.scannerProtocol.HEIGHT-1,maxX=0,maxY=0;for(InteractionJoint3D j:allJoints(s))if(j.tracked()){minX=min(minX,round(j.image.x));maxX=max(maxX,round(j.image.x));minY=min(minY,round(j.image.y));maxY=max(maxY,round(j.image.y));}s.minX=max(0,minX);s.maxX=min(studio.services.scannerProtocol.WIDTH-1,maxX);s.minY=max(0,minY);s.maxY=min(studio.services.scannerProtocol.HEIGHT-1,maxY);s.clippedTop=s.minY<=1;s.clippedBottom=s.maxY>=studio.services.scannerProtocol.HEIGHT-2;}
  float meanDepth(InteractionSkeleton3D s){float sum=0;int n=0;for(InteractionJoint3D j:allJoints(s))if(j.tracked()&&j.world.z>0){sum+=j.world.z;n++;}return n==0?0:sum/n;}
  int countTracked(InteractionSkeleton3D s){int n=0;for(InteractionJoint3D j:allJoints(s))if(j.tracked())n++;return n;}
}

class InteractionOrbCloud {
  final InteractionConfig cfg;final int count,trailCount;float[] x,y,vx,vy,phase,ring,lag;int[] band;float[] histX,histY;long lastMs=0;InteractionSkeleton3D skeleton;float lastHandX=Float.NaN,lastHandY=Float.NaN,handVx=0,handVy=0;
  InteractionOrbCloud(InteractionConfig cfg){
    this.cfg=cfg;count=max(80,cfg.cloudParticles);trailCount=max(6,cfg.cloudTrailSamples);x=new float[count];y=new float[count];vx=new float[count];vy=new float[count];phase=new float[count];ring=new float[count];lag=new float[count];band=new int[count];histX=new float[trailCount];histY=new float[trailCount];
    Random r=new Random(360112);for(int i=0;i<count;i++){phase[i]=r.nextFloat()*TWO_PI;ring[i]=sqrt(r.nextFloat());lag[i]=pow(r.nextFloat(),0.72f);band[i]=min(2,floor(lag[i]*3));x[i]=studio.services.scannerProtocol.WIDTH*0.5f;y[i]=studio.services.scannerProtocol.HEIGHT*0.5f;}
  }
  PVector primaryHand(InteractionSkeleton3D s){if(s==null)return null;if("left".equals(cfg.hand)&&s.leftHandTracked())return s.leftHand.image;if("right".equals(cfg.hand)&&s.rightHandTracked())return s.rightHand.image;if(s.rightHandTracked())return s.rightHand.image;if(s.leftHandTracked())return s.leftHand.image;return null;}
  float primaryOpen(InteractionSkeleton3D s){if(s==null)return 0.5f;if("left".equals(cfg.hand)&&s.leftHandTracked())return s.leftOpenness;if("right".equals(cfg.hand)&&s.rightHandTracked())return s.rightOpenness;if(s.rightHandTracked())return s.rightOpenness;if(s.leftHandTracked())return s.leftOpenness;return 0.5f;}
  void reset(){skeleton=null;lastMs=0;lastHandX=lastHandY=Float.NaN;handVx=handVy=0;Arrays.fill(vx,0);Arrays.fill(vy,0);}
  void seedHistory(float hx,float hy){for(int i=0;i<trailCount;i++){histX[i]=hx;histY[i]=hy;}for(int i=0;i<count;i++){x[i]=hx;y[i]=hy;vx[i]=vy[i]=0;}}
  void pushHistory(float hx,float hy){for(int i=trailCount-1;i>0;i--){histX[i]=histX[i-1];histY[i]=histY[i-1];}histX[0]=hx;histY[0]=hy;}
  void update(InteractionSkeleton3D s){
    skeleton=s;if(s==null||!s.tracked)return;PVector h=primaryHand(s);if(h==null)return;long now=millis64();float dt=lastMs==0?1.0f/60.0f:constrain((now-lastMs)/1000.0f,0.004f,0.040f);lastMs=now;float t=now*0.001f;
    if(Float.isNaN(lastHandX)){lastHandX=h.x;lastHandY=h.y;seedHistory(h.x,h.y);}float rawVx=(h.x-lastHandX)/dt,rawVy=(h.y-lastHandY)/dt;lastHandX=h.x;lastHandY=h.y;float va=1.0f-exp(-10.0f*dt);handVx=lerp(handVx,rawVx,va);handVy=lerp(handVy,rawVy,va);pushHistory(h.x,h.y);
    float speed=sqrt(handVx*handVx+handVy*handVy),ux=speed>5?handVx/speed:1,uy=speed>5?handVy/speed:0,pxAxis=-uy,pyAxis=ux;float stretch=1.0f+min(max(0,cfg.cloudMaxStretch-1.0f),speed*cfg.cloudStretchGain);float openness=primaryOpen(s),baseRadius=cfg.cloudRadiusPx*(0.78f+0.48f*openness);
    for(int i=0;i<count;i++){
      int hi=constrain(round(lag[i]*(trailCount-1)*cfg.cloudTrailStrength),0,trailCount-1);float cx=histX[hi],cy=histY[hi],tailFade=1.0f-0.42f*lag[i];float a=phase[i]+t*(0.52f+0.20f*((i%11)/11.0f));float rr=baseRadius*(0.18f+0.82f*ring[i])*tailFade;
      float longAxis=rr*(1.0f+(stretch-1.0f)*(0.35f+0.65f*lag[i])),shortAxis=rr/max(1.0f,sqrt(stretch));float swirl=sin(a*1.83f+t*0.48f+phase[i])*cfg.cloudFlow*baseRadius*(0.45f+0.55f*lag[i]);
      float localLong=cos(a)*longAxis-swirl*0.20f,localPerp=sin(a)*shortAxis+swirl;float tx=cx+ux*localLong+pxAxis*localPerp,ty=cy+uy*localLong+pyAxis*localPerp;
      float ax=(tx-x[i])*cfg.cloudSpring-vx[i]*cfg.cloudDamping,ay=(ty-y[i])*cfg.cloudSpring-vy[i]*cfg.cloudDamping;vx[i]+=ax*dt;vy[i]+=ay*dt;x[i]+=vx[i]*dt;y[i]+=vy[i]*dt;
    }
  }
  void draw(float sx,float sy){
    if(skeleton==null||!skeleton.tracked||primaryHand(skeleton)==null)return;strokeCap(ROUND);
    for(int b=2;b>=0;b--){int alpha=b==0?228:b==1?156:82;float core=b==0?2.5f:b==1?2.1f:1.7f,glow=core*2.8f;
      stroke(104,169,232,max(18,alpha/4));strokeWeight(glow*studioUiScale());beginShape(POINTS);for(int i=0;i<count;i++){if(band[i]!=b)continue;vertex(x[i]*sx,y[i]*sy);}endShape();
      stroke(104,169,232,alpha);strokeWeight(core*studioUiScale());beginShape(POINTS);for(int i=0;i<count;i++){if(band[i]!=b)continue;vertex(x[i]*sx,y[i]*sy);}endShape();
    }noStroke();
  }
}


class InteractionDesktopController {
  final InteractionConfig cfg;Robot robot;Rectangle desktopBounds;
  volatile boolean enabled=false,dragging=false,buttonDown=false,twoHandMode=false;volatile String handMode;
  float sx=Float.NaN,sy=Float.NaN;long lastMoveMs=0,lastTrackedMs=0,moveCount=0,doubleClickCount=0,dragCount=0,scrollCount=0;volatile int lastX=-1,lastY=-1;String error="";
  long twoHandsSince=0,bothClosedSince=0,lastDoubleMs=0,lastScrollMs=0;float lastScrollY=Float.NaN;boolean doubleFired=false;String interactionState="gesture.cloud_only";
  InteractionDesktopController(InteractionConfig cfg){this.cfg=cfg;handMode=cfg.hand;try{if(GraphicsEnvironment.isHeadless())throw new AWTException("headless");robot=new Robot();robot.setAutoDelay(3);desktopBounds=desktopBounds();}catch(Exception e){error=safeStudioMessage(e);robot=null;desktopBounds=new Rectangle(0,0,1,1);}}
  Rectangle desktopBounds(){Rectangle all=null;for(GraphicsDevice gd:GraphicsEnvironment.getLocalGraphicsEnvironment().getScreenDevices()){Rectangle b=gd.getDefaultConfiguration().getBounds();all=all==null?new Rectangle(b):all.union(b);}return all==null?new Rectangle(0,0,1920,1080):all;}
  boolean available(){return robot!=null;}
  void setEnabled(boolean on){boolean next=on&&available();if(enabled==next)return;enabled=next;if(!enabled){releaseDrag();resetGesture();}sx=Float.NaN;sy=Float.NaN;}
  void resetGesture(){twoHandMode=false;twoHandsSince=bothClosedSince=0;lastScrollY=Float.NaN;doubleFired=false;interactionState="gesture.cloud_only";}
  void cycleHand(){handMode="right".equals(handMode)?"left":"right";}
  String handKey(){return "hand."+handMode;}
  String gestureKey(){if(!enabled)return "gesture.disabled";if(dragging)return "gesture.dragging";return interactionState;}
  boolean primaryLeft(InteractionSkeleton3D s){if(s==null)return false;if("left".equals(handMode)&&s.leftHandTracked())return true;if("right".equals(handMode)&&s.rightHandTracked())return false;if(s.rightHandTracked())return false;return s.leftHandTracked();}
  InteractionJoint3D primaryJoint(InteractionSkeleton3D s){if(s==null)return null;if(primaryLeft(s)&&s.leftHandTracked())return s.leftHand;if(!primaryLeft(s)&&s.rightHandTracked())return s.rightHand;if(s.rightHandTracked())return s.rightHand;if(s.leftHandTracked())return s.leftHand;return null;}
  InteractionJoint3D secondaryJoint(InteractionSkeleton3D s){if(s==null||!s.rightHandTracked()||!s.leftHandTracked())return null;return primaryLeft(s)?s.rightHand:s.leftHand;}
  float primaryOpen(InteractionSkeleton3D s){if(s==null)return 0.5f;return primaryLeft(s)?s.leftOpenness:(s.rightHandTracked()?s.rightOpenness:s.leftOpenness);}
  float secondaryOpen(InteractionSkeleton3D s){if(s==null||!s.rightHandTracked()||!s.leftHandTracked())return 0.5f;return primaryLeft(s)?s.rightOpenness:s.leftOpenness;}
  PVector screenPoint(InteractionSkeleton3D s,InteractionJoint3D hand){
    if(s==null||hand==null||!hand.tracked()||!s.chest.tracked()||!s.leftShoulder.tracked()||!s.rightShoulder.tracked())return null;
    PVector xAxis=PVector.sub(s.rightShoulder.world,s.leftShoulder.world);if(xAxis.mag()<0.05f)xAxis.set(1,0,0);else xAxis.normalize();PVector rel=PVector.sub(hand.world,s.chest.world);float lateral=rel.dot(xAxis),vertical=rel.y,forward=s.chest.world.z-hand.world.z;if(forward<cfg.minHandForwardM)return null;float nx=constrain((lateral+cfg.volumeHalfWidthM)/(2*cfg.volumeHalfWidthM),0,1),ny=constrain((vertical+cfg.volumeTopM)/max(.05f,cfg.volumeTopM+cfg.volumeBottomM),0,1);if(cfg.mirrorX)nx=1-nx;return new PVector(desktopBounds.x+nx*max(1,desktopBounds.width-1),desktopBounds.y+ny*max(1,desktopBounds.height-1));
  }
  void update(InteractionSkeleton3D s){
    long now=millis64();
    if(!enabled||robot==null||s==null||!s.tracked){if(enabled&&now-lastTrackedMs>cfg.cursorLostReleaseMs){releaseDrag();resetGesture();}return;}
    InteractionJoint3D primary=primaryJoint(s);if(primary==null){return;}lastTrackedMs=now;InteractionJoint3D secondary=secondaryJoint(s);PVector a=screenPoint(s,primary),b=screenPoint(s,secondary);
    if(a==null){return;}boolean two=secondary!=null&&b!=null;
    updatePointer(a,now);
    if(!two){
      twoHandsSince=0;twoHandMode=false;releaseDrag();lastScrollY=Float.NaN;bothClosedSince=0;doubleFired=false;interactionState="gesture.pointer";return;
    }
    if(twoHandsSince==0)twoHandsSince=now;if(now-twoHandsSince>=cfg.twoHandStableMs)twoHandMode=true;
    if(!twoHandMode){interactionState="gesture.two_hand_wait";return;}
    float po=primaryOpen(s),so=secondaryOpen(s);boolean pOpen=po>=cfg.handOpenThreshold,sOpen=so>=cfg.handOpenThreshold,pClosed=po<=cfg.handCloseThreshold,sClosed=so<=cfg.handCloseThreshold;
    if(pClosed&&sClosed){
      releaseDrag();interactionState="gesture.double_click";if(bothClosedSince==0)bothClosedSince=now;if(!doubleFired&&now-bothClosedSince>=cfg.doubleClickStableMs&&now-lastDoubleMs>=cfg.doubleClickCooldownMs){doubleClick();doubleFired=true;lastDoubleMs=now;}
    }else{
      bothClosedSince=0;if(pOpen||sOpen)doubleFired=false;
      if(pClosed&&sOpen){interactionState="gesture.dragging";if(!buttonDown){pressPrimary();dragging=true;dragCount++;}}
      else{if(buttonDown)releaseDrag();if(pOpen&&sOpen){interactionState="gesture.scroll";updateScroll(s,now);}else interactionState="gesture.two_hand_ready";}
    }
  }
  void updatePointer(PVector target,long now){
    if(target==null||now-lastMoveMs<1000/max(1,cfg.cursorMaxHz))return;lastMoveMs=now;float tx=target.x,ty=target.y;
    if(Float.isNaN(sx)){sx=tx;sy=ty;}else{float d=dist(sx,sy,tx,ty);float speed=constrain(d/max(1,cfg.cursorFastDistancePx),0,1);float a=lerp(cfg.cursorSlowAlpha,cfg.cursorFastAlpha,speed);sx=lerp(sx,tx,a);sy=lerp(sy,ty,a);}
    int nxp=round(sx),nyp=round(sy);if(lastX>=0&&dist(lastX,lastY,nxp,nyp)<cfg.cursorDeadzonePx)return;lastX=nxp;lastY=nyp;try{robot.mouseMove(lastX,lastY);moveCount++;error="";}catch(Exception e){error=safeStudioMessage(e);}
  }
  void updateScroll(InteractionSkeleton3D s,long now){
    float avg=(s.leftHand.world.y+s.rightHand.world.y)*0.5f;if(Float.isNaN(lastScrollY)){lastScrollY=avg;return;}float delta=avg-lastScrollY;
    if(abs(delta)>=cfg.scrollThresholdM&&now-lastScrollMs>=cfg.scrollCooldownMs){int units=constrain(round(delta*cfg.scrollGainPerM),-5,5);if(units!=0){try{robot.mouseWheel(units);scrollCount+=abs(units);}catch(Exception e){error=safeStudioMessage(e);}lastScrollY=avg;lastScrollMs=now;}}else if(abs(delta)<cfg.scrollThresholdM*.35f)lastScrollY=lerp(lastScrollY,avg,.08f);
  }
  void pressPrimary(){if(!enabled||robot==null||buttonDown)return;try{robot.mousePress(InputEvent.BUTTON1_DOWN_MASK);buttonDown=true;}catch(Exception e){error=safeStudioMessage(e);}}
  void releasePrimary(){if(robot==null||!buttonDown)return;try{robot.mouseRelease(InputEvent.BUTTON1_DOWN_MASK);}catch(Exception e){error=safeStudioMessage(e);}buttonDown=false;}
  void doubleClick(){if(enabled&&robot!=null){try{robot.mousePress(InputEvent.BUTTON1_DOWN_MASK);robot.mouseRelease(InputEvent.BUTTON1_DOWN_MASK);robot.mousePress(InputEvent.BUTTON1_DOWN_MASK);robot.mouseRelease(InputEvent.BUTTON1_DOWN_MASK);doubleClickCount++;}catch(Exception e){error=safeStudioMessage(e);}}}
  void releaseDrag(){releasePrimary();dragging=false;}
  void key(int code){if(enabled&&robot!=null){robot.keyPress(code);robot.keyRelease(code);}}
  void chord(int modifier,int code){if(enabled&&robot!=null){robot.keyPress(modifier);robot.keyPress(code);robot.keyRelease(code);robot.keyRelease(modifier);}}
}


class InteractionUI {
  final UiRect enableButton=new UiRect(),releaseButton=new UiRect();
  void draw(){float m=max(10,20*studioUiScale()),gap=max(8,14*studioUiScale()),header=max(58,72*studioUiScale());drawHeader(m,header);float y=header+gap,w=max(40,width-2*m),h=max(1,studio.contentHeight-y-m);boolean wide=w>=900&&h>=430;if(wide){float left=w*.68f,right=w-left-gap;drawVision(m,y,left,h);drawControl(m+left+gap,y,right,h);}else{float visionH=max(70,(h-gap)*.56f),controlH=max(55,h-visionH-gap);if(visionH+controlH+gap>h&&h>1){float k=h/(visionH+controlH+gap);visionH*=k;controlH*=k;gap*=k;}drawVision(m,y,w,visionH);drawControl(m,y+visionH+gap,w,controlH);}}
  void drawHeader(float m,float h){
    float bw=constrain(width*.18f,96,210),bh=max(30,36*studioUiScale()),x=width-m-bw,textW=max(80,x-m-14);
    fill(0xFFF4F7FA);textAlign(LEFT,CENTER);studioText(26,true);String title=studio.interactionState.i18n.tr("app.title");fitCurrentTextSize(title,26,10,textW,h*.45f);text(ellipsizeToWidth(title,textW),m,h*.36f);
    fill(0xFFAAB6C2);studioText(13,false);String sub=studio.interactionState.i18n.tr("app.subtitle");fitCurrentTextSize(sub,13,7,textW,h*.38f);text(ellipsizeToWidth(sub,textW),m,h*.69f);
    enableButton.set(x,max(8,(h-bh)/2),bw,bh);drawButton(enableButton,studio.interactionState.i18n.tr(studio.interactionState.controlEnabled?"button.disable":"button.enable"),true,studio.interactionState.controlEnabled);textAlign(LEFT,BASELINE);
  }
  void drawVision(float x,float y,float w,float h){card(x,y,w,h);cardTitle(x,y,w,studio.interactionState.i18n.tr("panel.vision"));float px=x+12,py=y+44*studioUiScale(),pw=max(10,w-24),ph=max(10,h-56*studioUiScale());fill(studio.services.acousticTheme.BG);rect(px,py,pw,ph,10);if(studio.interactionState.rgbImage!=null){float[] vr=imageRect(studio.interactionState.rgbImage,px,py,pw,ph);pushMatrix();if(studio.interactionState.config.mirrorX){translate(vr[0]+vr[2],vr[1]);scale(-1,1);image(studio.interactionState.rgbImage,0,0,vr[2],vr[3]);}else image(studio.interactionState.rgbImage,vr[0],vr[1],vr[2],vr[3]);popMatrix();drawSkeletonOverlay(vr[0],vr[1],vr[2],vr[3]);}else{fill(0xFFAAB6C2);textAlign(CENTER,CENTER);studioText(15,false);text(ellipsizeToWidth(studio.interactionState.i18n.tr("waiting.rgbd"),pw-20),px+pw/2,py+ph/2);textAlign(LEFT,BASELINE);}}
  float[] imageRect(PImage img,float x,float y,float w,float h){float sc=min(w/img.width,h/img.height),dw=img.width*sc,dh=img.height*sc;return new float[]{x+(w-dw)/2,y+(h-dh)/2,dw,dh};}
  void drawSkeletonOverlay(float x,float y,float w,float h){
    InteractionSkeleton3D s=studio.interactionState.skeleton;if(s==null||!s.tracked)return;float sx=w/studio.services.scannerProtocol.WIDTH,sy=h/studio.services.scannerProtocol.HEIGHT;clip(x,y,w,h);pushMatrix();translate(x,y);if(studio.interactionState.config.mirrorX){translate(w,0);scale(-1,1);}
    // Articulated virtual-body style: dark cylindrical outline, bright bone core and spherical joints.
    drawBodyBones(s,sx,sy,0xFF101820,max(5.2f,7.5f*studioUiScale()));drawBodyBones(s,sx,sy,0xFF58C7F3,max(2.2f,3.6f*studioUiScale()));
    if(s.head.tracked()){noFill();stroke(0xFF101820,230);strokeWeight(max(3,5*studioUiScale()));ellipse(s.head.image.x*sx,s.head.image.y*sy,s.faceWidthPx*sx,s.faceHeightPx*sy);stroke(0xFF58C7F3,245);strokeWeight(max(1.4f,2.4f*studioUiScale()));ellipse(s.head.image.x*sx,s.head.image.y*sy,s.faceWidthPx*sx,s.faceHeightPx*sy);}
    for(InteractionJoint3D j:bodyJoints(s))jointNode(j,sx,sy);
    if(studio.interactionState.cloud!=null)studio.interactionState.cloud.draw(sx,sy);drawHandPose(s.leftPose,s.leftHand,s.leftOpenness,sx,sy,0xFFD8BCFF);drawHandPose(s.rightPose,s.rightHand,s.rightOpenness,sx,sy,0xFF9ED8FF);popMatrix();noClip();
  }
  InteractionJoint3D[] bodyJoints(InteractionSkeleton3D s){return new InteractionJoint3D[]{s.neck,s.chest,s.spine,s.pelvis,s.leftShoulder,s.rightShoulder,s.leftElbow,s.rightElbow,s.leftWrist,s.rightWrist,s.leftHand,s.rightHand,s.leftHip,s.rightHip,s.leftKnee,s.rightKnee,s.leftAnkle,s.rightAnkle,s.leftFoot,s.rightFoot};}
  void drawBodyBones(InteractionSkeleton3D s,float sx,float sy,int color,float weight){stroke(color,s.tracked?235:150);strokeWeight(weight);strokeCap(ROUND);bone(s.head,s.neck,sx,sy);bone(s.neck,s.chest,sx,sy);bone(s.chest,s.spine,sx,sy);bone(s.spine,s.pelvis,sx,sy);bone(s.leftShoulder,s.rightShoulder,sx,sy);bone(s.neck,s.leftShoulder,sx,sy);bone(s.neck,s.rightShoulder,sx,sy);bone(s.leftShoulder,s.leftElbow,sx,sy);bone(s.leftElbow,s.leftWrist,sx,sy);bone(s.leftWrist,s.leftHand,sx,sy);bone(s.rightShoulder,s.rightElbow,sx,sy);bone(s.rightElbow,s.rightWrist,sx,sy);bone(s.rightWrist,s.rightHand,sx,sy);bone(s.pelvis,s.leftHip,sx,sy);bone(s.pelvis,s.rightHip,sx,sy);bone(s.leftHip,s.rightHip,sx,sy);bone(s.leftHip,s.leftKnee,sx,sy);bone(s.leftKnee,s.leftAnkle,sx,sy);bone(s.leftAnkle,s.leftFoot,sx,sy);bone(s.rightHip,s.rightKnee,sx,sy);bone(s.rightKnee,s.rightAnkle,sx,sy);bone(s.rightAnkle,s.rightFoot,sx,sy);}
  void bone(InteractionJoint3D a,InteractionJoint3D b,float sx,float sy){if(a!=null&&b!=null&&a.tracked()&&b.tracked())line(a.image.x*sx,a.image.y*sy,b.image.x*sx,b.image.y*sy);}
  void jointNode(InteractionJoint3D j,float sx,float sy){if(j==null||!j.tracked())return;float d=(j.state==2?10:8)*studioUiScale(),alpha=j.state==2?245:150;noStroke();fill(0xFF101820,230);ellipse(j.image.x*sx,j.image.y*sy,d+5*studioUiScale(),d+5*studioUiScale());fill(j.state==2?0xFFFFB54A:0xFF9AA9B5,alpha);ellipse(j.image.x*sx,j.image.y*sy,d,d);}
  void drawHandPose(InteractionHandPose3D p,InteractionJoint3D hand,float openness,float sx,float sy,int c){if(p!=null&&p.tracked&&hand!=null&&hand.tracked()){stroke(c,190);strokeWeight(max(1,1.2f*studioUiScale()));for(int i=0;i<p.fingerCount;i++){InteractionFinger3D f=p.fingers[i];if(f.tip.tracked()){line(hand.image.x*sx,hand.image.y*sy,f.tip.image.x*sx,f.tip.image.y*sy);noStroke();fill(c,235);ellipse(f.tip.image.x*sx,f.tip.image.y*sy,5*studioUiScale(),5*studioUiScale());stroke(c,190);}}noStroke();fill(c,220);float d=(7+7*openness)*studioUiScale();ellipse(hand.image.x*sx,hand.image.y*sy,d,d);}}
  String xyz(InteractionJoint3D j){return j==null||!j.tracked()?"—":String.format(Locale.US,"%.2f / %.2f / %.2f m",j.world.x,j.world.y,j.world.z);}
  void drawControl(float x,float y,float w,float h){
    card(x,y,w,h);cardTitle(x,y,w,studio.interactionState.i18n.tr("panel.control"));float px=x+12,py=y+43*studioUiScale(),inner=max(40,w-24);boolean compact=h<390;float row=max(21,(compact?23:29)*studioUiScale());
    String live=interaction3dLive()?studio.interactionState.i18n.tr("state.live"):studio.interactionState.i18n.tr("state.wait");
    String syncValue=studio.interactionState.source==null||Float.isNaN(studio.interactionState.source.latestSyncResidualMs)?"—":studio.interactionState.i18n.format("value.sync",studio.interactionState.source.latestSyncResidualMs,studio.interactionState.source.syncOffsetUs/1000.0);
    String sk=studio.interactionState.skeleton!=null&&studio.interactionState.skeleton.tracked?studio.interactionState.i18n.format("state.tracked",studio.interactionState.skeleton.confidence*100):studio.interactionState.i18n.tr("tracker."+(studio.interactionState.tracker==null?"searching":studio.interactionState.tracker.lastReason));
    String depth=studio.interactionState.skeleton==null?"—":String.format(Locale.US,"%.2f m",studio.interactionState.skeleton.meanDepthM);
    String fingers=studio.interactionState.skeleton==null?"0 / 0":studio.interactionState.skeleton.leftPose.fingerCount+" / "+studio.interactionState.skeleton.rightPose.fingerCount;
    String mode=studio.interactionState.desktop==null?studio.interactionState.i18n.tr("gesture.disabled"):studio.interactionState.i18n.tr(studio.interactionState.desktop.gestureKey());
    String actions=studio.interactionState.desktop==null?"0 / 0 / 0":studio.interactionState.desktop.doubleClickCount+" / "+studio.interactionState.desktop.dragCount+" / "+studio.interactionState.desktop.scrollCount;
    String[] labels={studio.interactionState.i18n.tr("label.kinect"),studio.interactionState.i18n.tr("label.sync"),studio.interactionState.i18n.tr("label.skeleton"),studio.interactionState.i18n.tr("label.depth"),studio.interactionState.i18n.tr("label.right_hand_xyz"),studio.interactionState.i18n.tr("label.left_hand_xyz"),studio.interactionState.i18n.tr("label.fingers"),studio.interactionState.i18n.tr("label.mode"),studio.interactionState.i18n.tr("label.actions")};
    String[] values={live,syncValue,sk,depth,studio.interactionState.skeleton==null?"—":xyz(studio.interactionState.skeleton.rightHand),studio.interactionState.skeleton==null?"—":xyz(studio.interactionState.skeleton.leftHand),fingers,mode,actions};
    int cols=compact&&inner>470?2:1,rows=(labels.length+cols-1)/cols;float colGap=14*studioUiScale(),colW=(inner-colGap*(cols-1))/cols;
    for(int i=0;i<labels.length;i++){int col=i/rows,rowIndex=i%rows;statusRow(px+col*(colW+colGap),py+rowIndex*row,colW,labels[i],values[i]);}
    py+=rows*row+8*studioUiScale();float bh=max(30,38*studioUiScale());releaseButton.set(px,py,inner,bh);drawButton(releaseButton,studio.interactionState.i18n.tr("button.release"),studio.interactionState.desktop!=null&&studio.interactionState.desktop.buttonDown,false);py+=bh+9*studioUiScale();
    float available=y+h-py-10;if(available>30){clip(x+8,py-2,w-16,available+2);fill(0xFFAAB6C2);textAlign(LEFT,TOP);studioText(12,true);String title=studio.interactionState.i18n.tr("label.gesture_help");text(ellipsizeToWidth(title,inner),px,py);py+=18*studioUiScale();fill(0xFFF4F7FA);studioText(11,false);String help=studio.interactionState.i18n.tr("help.two_hand");text(help,px,py,inner,max(20,y+h-py-12));noClip();}textAlign(LEFT,BASELINE);
  }
  void statusRow(float x,float y,float w,String label,String value){fill(0xFFAAB6C2);textAlign(LEFT,CENTER);textSize(responsiveFontSize(11));fitCurrentTextSize(label,11,7,w*.43f,24*studioUiScale());text(ellipsizeToWidth(label,w*.43f),x,y+12*studioUiScale());fill(0xFFF4F7FA);textAlign(RIGHT,CENTER);fitCurrentTextSize(value,11,7,w*.55f,24*studioUiScale());text(ellipsizeToWidth(value,w*.55f),x+w,y+12*studioUiScale());textAlign(LEFT,BASELINE);}
  void handleMouse(float mx,float my){if(enableButton.hit(mx,my))toggleInteractionControl();else if(releaseButton.hit(mx,my)&&studio.interactionState.desktop!=null)studio.interactionState.desktop.releaseDrag();}
  void drawButton(UiRect r,String label,boolean enabled,boolean primary){boolean hot=enabled&&r.hit(studio.contentMouseX(),studio.contentMouseY());stroke(hot?0xFF68A9E8:0xFF35414D);fill(enabled?(primary?0xFF293440:0xFF202832):0xFF11151A);rect(r.x,r.y,r.w,r.h,9);noStroke();fill(enabled?0xFFF4F7FA:0xFF56616C);textAlign(CENTER,CENTER);studioText(13,true);fitCurrentTextSize(label,13,7,r.w-12,r.h-8);text(ellipsizeToWidth(label,r.w-12),r.x+r.w/2,r.y+r.h/2);textAlign(LEFT,BASELINE);}
  void card(float x,float y,float w,float h){stroke(0xFF35414D);fill(0xFF181E25);rect(x,y,w,h,14);noStroke();}void cardTitle(float x,float y,float w,String title){fill(0xFFF4F7FA);textAlign(LEFT,CENTER);studioText(14,true);fitCurrentTextSize(title,14,7,w-28,36*studioUiScale());text(ellipsizeToWidth(title,w-28),x+14,y+22*studioUiScale());textAlign(LEFT,BASELINE);}
}
