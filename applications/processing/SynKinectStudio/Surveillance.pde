// ===== SynKinect Studio / Surveillance V1.0 =====
// Multi-Kinect surveillance is intentionally independent from the Studio's selected
// camera. Each discovered camera owns exactly ONE video stream at a time: RGB in
// normal light or IR in darkness. Surveillance NEVER subscribes to Depth. Motion is
// computed from temporal luma differences in the active RGB/IR image, so arming
// surveillance cannot claim endpoint 0x82 or keep the depth projector alive.

class SurveillanceModuleState {
  SurveillanceConfig config;
  SurveillanceI18n i18n;
  SurveillanceUI ui;
  final Object cameraLock=new Object();
  final Object eventLock=new Object();
  final LinkedHashMap<String,SurveillanceCamera> cameras=new LinkedHashMap<String,SurveillanceCamera>();
  volatile boolean armed=false,recording=false,recordStarting=false,supervisorRun=false;
  volatile long eventGeneration=0,lastMotionMs=0,lastRegistryGeneration=-1;
  volatile float motionScore=0;
  volatile String status="";
  SurveillanceEventSession eventSession;
  Thread supervisor;
}

void setupSurveillanceModule(){
  SurveillanceModuleState s=studio.surveillanceState;
  s.config=new SurveillanceConfig();s.config.load(new File(dataPath("surveillance.properties")));
  s.i18n=new SurveillanceI18n(studio.currentLanguage());initializeSurveillanceTypography();
  s.ui=new SurveillanceUI();s.status=s.i18n.tr("status.disarmed");
  syncSurveillanceDevices();startSurveillanceSupervisor();
}

void activateSurveillanceRuntime(){startSurveillanceSupervisor();syncSurveillanceDevices();startSurveillanceCameras();setSurveillanceForeground(true);}
void deactivateSurveillanceRuntime(){
  SurveillanceModuleState s=studio.surveillanceState;
  setSurveillanceForeground(false);
  // A tab never keeps ownership of Kinect video after it is left. This avoids
  // RGB/IR arbitration from a hidden Surveillance module blocking Scanner or Interactivity.
  if(s.recording||s.recordStarting)requestStopMotionRecording(false);
  s.armed=false;
  s.status=s.i18n.tr("status.disarmed");
  requestStopSurveillanceCameras(false);
  requestStopSurveillanceSupervisor();
}

void drawSurveillanceModule(){
  background(studio.services.surveillanceTheme.BG);
  syncSurveillanceDevices();
  studio.surveillanceState.ui.draw();
}

void startSurveillanceSupervisor(){
  SurveillanceModuleState s=studio.surveillanceState;if(s.supervisorRun)return;s.supervisorRun=true;
  s.supervisor=studio.services.workers.start("Surveillance-Supervisor",new Runnable(){public void run(){
    while(studio.surveillanceState.supervisorRun){
      serviceRecordingTimeout();serviceRecordingHealth();
      try{Thread.sleep(200);}catch(InterruptedException e){if(!studio.surveillanceState.supervisorRun)return;Thread.currentThread().interrupt();return;}
    }
  }});
}

void requestStopSurveillanceSupervisor(){SurveillanceModuleState s=studio.surveillanceState;s.supervisorRun=false;Thread t=s.supervisor;s.supervisor=null;if(t!=null)t.interrupt();}
void stopSurveillanceSupervisor(){SurveillanceModuleState s=studio.surveillanceState;s.supervisorRun=false;Thread t=s.supervisor;if(t!=null){t.interrupt();try{t.join(s.config==null?1800:s.config.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}}s.supervisor=null;}

void syncSurveillanceDevices(){syncSurveillanceDevices(false);}
void syncSurveillanceDevices(boolean force){
  SurveillanceModuleState s=studio.surveillanceState;if(s.config==null)return;
  studio.services.devices.refreshIfDue();long generation=studio.services.devices.generation;
  if(!force&&generation==s.lastRegistryGeneration)return;
  ArrayList<KinectDevice> found=studio.services.devices.snapshot();HashSet<String> present=new HashSet<String>();
  boolean shouldRun=studio.activeTab==STUDIO_TAB_SURVEILLANCE||s.armed||s.recording;
  ArrayList<SurveillanceCamera> toStop=new ArrayList<SurveillanceCamera>();
  ArrayList<SurveillanceCamera> toStart=new ArrayList<SurveillanceCamera>();
  ArrayList<SurveillanceCamera> active=new ArrayList<SurveillanceCamera>();
  synchronized(s.cameraLock){
    for(KinectDevice d:found){
      present.add(d.id);SurveillanceCamera c=s.cameras.get(d.id);
      if(c==null||!c.device.endpoint.equals(d.endpoint)){
        if(c!=null)toStop.add(c);
        c=new SurveillanceCamera(d,s.config);s.cameras.put(d.id,c);
      }
      if(shouldRun)toStart.add(c);
      active.add(c);
    }
    Iterator<Map.Entry<String,SurveillanceCamera>> it=s.cameras.entrySet().iterator();
    while(it.hasNext()){
      Map.Entry<String,SurveillanceCamera> e=it.next();if(present.contains(e.getKey()))continue;
      toStop.add(e.getValue());it.remove();
    }
    s.lastRegistryGeneration=generation;
  }
  // Never join transport/processor threads while cameraLock is held. Motion
  // callbacks can acquire cameraLock through event recording, so joining under
  // that lock creates a lock inversion and can freeze the Processing UI.
  for(SurveillanceCamera c:toStop)c.requestStop(false);
  for(SurveillanceCamera c:toStart)c.start();
  SurveillanceEventSession session=s.eventSession;
  if(s.recording&&session!=null)for(SurveillanceCamera c:active)session.ensureCamera(c);
}

void startSurveillanceCameras(){SurveillanceModuleState s=studio.surveillanceState;ArrayList<SurveillanceCamera> cameras;synchronized(s.cameraLock){cameras=new ArrayList<SurveillanceCamera>(s.cameras.values());}for(SurveillanceCamera c:cameras)c.start();}
void requestStopSurveillanceCameras(boolean clearRetention){SurveillanceModuleState s=studio.surveillanceState;ArrayList<SurveillanceCamera> cameras;synchronized(s.cameraLock){cameras=new ArrayList<SurveillanceCamera>(s.cameras.values());}for(SurveillanceCamera c:cameras)c.requestStop(clearRetention);}
void stopSurveillanceCameras(boolean clearRetention){SurveillanceModuleState s=studio.surveillanceState;ArrayList<SurveillanceCamera> cameras;synchronized(s.cameraLock){cameras=new ArrayList<SurveillanceCamera>(s.cameras.values());}for(SurveillanceCamera c:cameras)c.stop(clearRetention);}
void setSurveillanceForeground(boolean foreground){SurveillanceModuleState s=studio.surveillanceState;ArrayList<SurveillanceCamera> cameras;synchronized(s.cameraLock){cameras=new ArrayList<SurveillanceCamera>(s.cameras.values());}for(SurveillanceCamera c:cameras)c.setForeground(foreground);}

void onSurveillanceMotion(SurveillanceCamera camera,float score,boolean moving,boolean triggered){
  SurveillanceModuleState s=studio.surveillanceState;s.motionScore=max(s.motionScore*0.88f,score);
  if(moving)s.lastMotionMs=millis64();
  if(s.armed&&triggered&&!s.recording&&!s.recordStarting)requestStartMotionRecording();
}

void requestStartMotionRecording(){
  SurveillanceModuleState s=studio.surveillanceState;final long generation;
  synchronized(s.eventLock){
    if(s.recording||s.recordStarting)return;
    s.recordStarting=true;generation=++s.eventGeneration;
  }
  studio.services.workers.startLowPriority("Surveillance-Event-Start",new Runnable(){public void run(){startMotionRecording(generation);}});
}

void startMotionRecording(long generation){
  SurveillanceModuleState s=studio.surveillanceState;SurveillanceEventSession event=null;ArrayList<SurveillanceCamera> cameras;
  try{
    synchronized(s.cameraLock){cameras=new ArrayList<SurveillanceCamera>(s.cameras.values());}
    if(cameras.isEmpty())throw new IOException("no Kinect cameras available");
    event=new SurveillanceEventSession(s.config);event.start(cameras);
    synchronized(s.eventLock){
      if(generation!=s.eventGeneration||!s.recordStarting||studio.activeTab!=STUDIO_TAB_SURVEILLANCE){if(generation==s.eventGeneration)s.recordStarting=false;}
      else{
        s.eventSession=event;s.recording=true;s.recordStarting=false;event=null;
        s.lastMotionMs=millis64();s.status=s.i18n.format("status.recording_multi",cameras.size(),s.config.preRollSeconds);
      }
    }
  }catch(Exception e){
    synchronized(s.eventLock){if(generation==s.eventGeneration){s.recordStarting=false;s.recording=false;s.eventSession=null;s.status=s.i18n.format("status.record_failed",safeStudioMessage(e));}}
  }finally{
    if(event!=null)try{event.stop();}catch(Exception ignored){}
  }
}

void requestStopMotionRecording(boolean timeout){
  SurveillanceModuleState s=studio.surveillanceState;
  SurveillanceEventSession event;
  synchronized(s.eventLock){
    if(!s.recording&&!s.recordStarting)return;
    ++s.eventGeneration;s.recordStarting=false;s.recording=false;event=s.eventSession;s.eventSession=null;
    s.status=s.i18n.tr(timeout?"status.record_stopped_idle_multi":"status.record_stopped_manual_multi");
  }
  if(event!=null)studio.services.workers.startLowPriority("Surveillance-Event-Close",new Runnable(){public void run(){event.stop();}});
}

void submitSurveillancePacket(SurveillanceCamera camera,RetainedVideoFrame frame){
  SurveillanceModuleState s=studio.surveillanceState;if(!s.recording||frame==null)return;
  synchronized(s.eventLock){if(s.eventSession!=null)s.eventSession.submit(camera,frame);}
}

void serviceRecordingTimeout(){SurveillanceModuleState s=studio.surveillanceState;if(!s.recording)return;long now=millis64();if(now-s.lastMotionMs>=s.config.motionStopAfterMs)requestStopMotionRecording(true);}
void serviceRecordingHealth(){SurveillanceModuleState s=studio.surveillanceState;if(!s.recording)return;synchronized(s.eventLock){if(s.eventSession!=null&&s.eventSession.hasFailed()){String m=s.eventSession.failureMessage();s.recording=false;s.eventSession.stop();s.eventSession=null;s.status=s.i18n.format("status.record_runtime_failed",m.length()==0?s.i18n.tr("error.unknown"):m);}}}

void toggleArmed(){SurveillanceModuleState s=studio.surveillanceState;s.armed=!s.armed;if(s.armed){syncSurveillanceDevices();startSurveillanceCameras();s.status=s.i18n.tr("status.armed_multi");}else{if(s.recording||s.recordStarting)requestStopMotionRecording(false);s.status=s.i18n.tr("status.disarmed");if(studio.activeTab!=STUDIO_TAB_SURVEILLANCE)requestStopSurveillanceCameras(false);}}
void manualRecord(){syncSurveillanceDevices();startSurveillanceCameras();requestStartMotionRecording();}
void surveillanceMousePressed(){if(studio.surveillanceState.ui!=null)studio.surveillanceState.ui.handleMouse(studio.contentMouseX(),studio.contentMouseY());}
void surveillanceKeyPressed(){if(key=='a'||key=='A')toggleArmed();else if(key=='r'||key=='R')manualRecord();else if(key=='s'||key=='S')requestStopMotionRecording(false);}
void disposeSurveillanceModule(){SurveillanceModuleState s=studio.surveillanceState;s.armed=false;if(s.recording||s.recordStarting)requestStopMotionRecording(false);stopSurveillanceSupervisor();stopSurveillanceCameras(true);synchronized(s.cameraLock){s.cameras.clear();}}
long millis64(){return System.nanoTime()/1000000L;}

class SurveillanceCamera {
  final KinectDevice device;final SurveillanceConfig cfg;final SurveillanceSource source;final AppearanceMotionDetector detector;final VideoRetentionBuffer retention;
  volatile boolean processorRun=false;volatile long processorGeneration=0;Thread processor;
  volatile int[] latestPreviewPixels;volatile int previewWidth=0,previewHeight=0;
  volatile long latestPreviewEpochMs=0,lastRetainedEpochMs=0,framesProcessed=0;
  volatile float motionScore=0;volatile String lastError="";
  volatile boolean nightMode=false,rgbProbe=false,foreground=false;volatile float meanLuma=1.0f;int darkFrames=0,brightFrames=0,probeFrames=0,irBrightFrames=0;long lastIrProbeMs=0;
  SurveillanceCamera(KinectDevice device,SurveillanceConfig cfg){this.device=device;this.cfg=cfg;source=new SurveillanceSource(device,cfg);detector=new AppearanceMotionDetector(cfg);retention=new VideoRetentionBuffer(cfg.retentionMinutes*60000L);}
  synchronized void setForeground(boolean value){foreground=value;if(!value){rgbProbe=false;source.setInfrared(false);}else if(nightMode&&!rgbProbe){source.setInfrared(true);}}
  boolean canUseInfrared(){return foreground&&studio.activeTab==STUDIO_TAB_SURVEILLANCE;}
  synchronized void start(){if(processorRun)return;source.start();processorRun=true;final long generation=++processorGeneration;processor=studio.services.workers.start("Surveillance-"+safeToken(device.id),new Runnable(){public void run(){processLoop(generation);}});}
  synchronized void requestStop(boolean clearRetention){processorRun=false;++processorGeneration;source.requestStop();Thread t=processor;processor=null;if(t!=null)t.interrupt();detector.reset();if(clearRetention)retention.clear();}
  synchronized void stop(boolean clearRetention){processorRun=false;++processorGeneration;source.stop();Thread t=processor;if(t!=null){t.interrupt();try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}}processor=null;detector.reset();if(clearRetention)retention.clear();}
  void processLoop(long generation){
    while(processorRun&&generation==processorGeneration){SurveillanceFrame f=source.poll();if(f==null){try{Thread.sleep(4);}catch(InterruptedException e){if(!processorRun||generation!=processorGeneration)return;}continue;}
      try{processFrame(f);}catch(Exception e){lastError=safeStudioMessage(e);}
    }
  }
  void processFrame(SurveillanceFrame f)throws IOException{
    framesProcessed++;long epochMs=System.currentTimeMillis();
    EncodedSurveillanceFrame encoded=null;
    if(f.mode==studio.services.surveillanceProtocol.MODE_RGB){
      meanLuma=surveillanceMeanLuma(f.payload,f.width,f.height);
      float score=detector.detectRgb(f.payload,f.width,f.height);motionScore=score;onSurveillanceMotion(this,score,detector.moving(),detector.triggered());
      if(nightMode&&rgbProbe){
        probeFrames++;if(meanLuma>=cfg.nightExitLuma)brightFrames++;else brightFrames=0;
        if(brightFrames>=cfg.nightBrightFrames){nightMode=false;rgbProbe=false;darkFrames=0;source.setInfrared(false);}
        else if(probeFrames>=cfg.nightProbeFrames){rgbProbe=false;brightFrames=0;irBrightFrames=0;lastIrProbeMs=millis64();source.setInfrared(canUseInfrared());}
      }else if(!nightMode){
        if(meanLuma<=cfg.nightEnterLuma)darkFrames++;else darkFrames=max(0,darkFrames-1);
        if(darkFrames>=cfg.nightDarkFrames){nightMode=true;rgbProbe=false;irBrightFrames=0;lastIrProbeMs=millis64();source.setInfrared(canUseInfrared());}
      }
      encoded=encodeSurveillanceJpeg(f.payload,f.width,f.height,cfg,epochMs,device.label+(nightMode?" · RGB probe":" · RGB"));
    }else if(f.mode==studio.services.surveillanceProtocol.MODE_IR){
      meanLuma=surveillanceIrMeanLuma(f.payload,f.width,f.height,cfg.motionSampleStep);
      float score=detector.detectIr(f.payload,f.width,f.height);motionScore=score;onSurveillanceMotion(this,score,detector.moving(),detector.triggered());

      // Do not leave IR on a blind timer. Repeated timed RGB probes physically
      // reprogram endpoint 0x81 and make the emitter visibly blink. A RGB probe
      // is allowed only after stable IR evidence suggests ambient light changed,
      // and only after a cooldown.
      if(meanLuma>=cfg.nightIrProbeLuma)irBrightFrames++;else irBrightFrames=max(0,irBrightFrames-1);
      if(canUseInfrared()&&nightMode&&!rgbProbe&&
         irBrightFrames>=cfg.nightIrProbeFrames&&
         millis64()-lastIrProbeMs>=cfg.nightProbeIntervalMs){
        rgbProbe=true;probeFrames=0;brightFrames=0;irBrightFrames=0;
        source.setInfrared(false);detector.reset();
      }
      encoded=encodeSurveillanceIrJpeg(f.payload,f.width,f.height,cfg,epochMs,device.label+" · IR");
    }else return;
    long interval=Math.max(1L,1000L/Math.max(1,cfg.retentionFps));if(lastRetainedEpochMs>0&&epochMs-lastRetainedEpochMs<interval)return;lastRetainedEpochMs=epochMs;
    if(encoded==null)return;latestPreviewPixels=encoded.previewPixels;previewWidth=cfg.recordWidth;previewHeight=cfg.recordHeight;latestPreviewEpochMs=epochMs;
    RetainedVideoFrame packet=new RetainedVideoFrame(epochMs,encoded.jpeg);retention.add(packet);submitSurveillancePacket(this,packet);
  }
  String videoModeLabel(){return nightMode&&!rgbProbe?"IR":"RGB";}
  long retainedBytes(){return retention.bytes();}long retainedDurationMs(){return retention.durationMs();}
}

class SurveillanceFrame {int mode,width,height,flags;long frameNumber,tickMs;byte[] payload;}

class SurveillanceSource {
  final KinectDevice device;final SurveillanceConfig cfg;final Object frameLock=new Object(),pipeLock=new Object();
  final ArrayDeque<SurveillanceFrame> queue=new ArrayDeque<SurveillanceFrame>();
  final byte[] headerBytes=new byte[studio.services.surveillanceProtocol.FRAME_HEADER_BYTES];
  volatile boolean running=false,connected=false,infrared=false;volatile long runGeneration=0;volatile String lastError="";volatile long dropped=0,lastFrameMs=0;Thread worker;LocalTransport pipe;
  SurveillanceSource(KinectDevice device,SurveillanceConfig cfg){this.device=device;this.cfg=cfg;}
  synchronized void start(){if(running)return;running=true;final long generation=++runGeneration;worker=studio.services.workers.start("Surveillance-Port-"+safeToken(device.id),new Runnable(){public void run(){loop(generation);}});}
  void requestStop(){Thread t;synchronized(this){running=false;++runGeneration;closeActive();t=worker;worker=null;}if(t!=null)t.interrupt();connected=false;synchronized(frameLock){queue.clear();}}
  void stop(){Thread t;synchronized(this){running=false;++runGeneration;closeActive();t=worker;worker=null;}if(t!=null){t.interrupt();try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}}connected=false;synchronized(frameLock){queue.clear();}}
  SurveillanceFrame poll(){synchronized(frameLock){return queue.isEmpty()?null:queue.removeFirst();}}
  void setInfrared(boolean value){if(infrared==value)return;infrared=value;closeActive();}
  void enqueue(SurveillanceFrame f){synchronized(frameLock){if(queue.size()>=cfg.videoQueueFrames){queue.removeFirst();dropped++;}queue.addLast(f);}}
  void loop(long generation){while(running&&generation==runGeneration){LocalTransport local=null;try{local=studio.services.transportFactory.openEndpoint(device.endpoint);setActive(local);subscribe(local);connected=true;lastError="";while(running&&generation==runGeneration)readFrame(local);}catch(Exception e){if(generation==runGeneration){connected=false;if(running)lastError=safeStudioMessage(e);}}finally{clearActive(local);close(local);}if(running&&generation==runGeneration)try{Thread.sleep(cfg.reconnectMs);}catch(InterruptedException e){if(!running||generation!=runGeneration)return;Thread.currentThread().interrupt();return;}}}
  void subscribe(LocalTransport local)throws IOException{int requested=infrared?studio.services.surveillanceProtocol.STREAM_IR:studio.services.surveillanceProtocol.STREAM_RGB;ByteBuffer q=ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN);q.putInt(studio.services.surveillanceProtocol.MAGIC).putInt(studio.services.surveillanceProtocol.VERSION).putInt(studio.services.surveillanceProtocol.CMD_SUBSCRIBE_STREAMS).putInt(requested);local.write(q.array());byte[] rb=new byte[studio.services.surveillanceProtocol.REPLY_BYTES];local.readFully(rb);ByteBuffer r=ByteBuffer.wrap(rb).order(ByteOrder.LITTLE_ENDIAN);int magic=r.getInt(),version=r.getInt(),result=r.getInt(),accepted=r.getInt(),w=r.getInt(),h=r.getInt(),caps=r.getInt(),maxPayload=r.getInt();if(magic!=studio.services.surveillanceProtocol.MAGIC||version!=studio.services.surveillanceProtocol.VERSION||result<0||accepted!=requested||w!=studio.services.surveillanceProtocol.WIDTH||h!=studio.services.surveillanceProtocol.HEIGHT||maxPayload<studio.services.surveillanceProtocol.MAX_PAYLOAD_BYTES)throw new IOException("surveillance subscribe rejected");}
  void readFrame(LocalTransport local)throws IOException{
    local.readFully(headerBytes);
    ByteBuffer h=ByteBuffer.wrap(headerBytes).order(ByteOrder.LITTLE_ENDIAN);
    int magic=h.getInt(),version=h.getInt(),mode=h.getInt(),w=h.getInt(),hh=h.getInt(),fmt=h.getInt(),bytes=h.getInt(),flags=h.getInt();long frameNo=h.getLong(),tickMs=h.getLong();
    h.position(studio.services.surveillanceProtocol.FRAME_HEADER_BYTES);
    if(magic!=studio.services.surveillanceProtocol.FRAME_MAGIC||version!=studio.services.surveillanceProtocol.VERSION||w!=studio.services.surveillanceProtocol.WIDTH)throw new IOException("surveillance frame header");
    boolean rgbRaw=mode==studio.services.surveillanceProtocol.MODE_RGB&&hh==studio.services.surveillanceProtocol.HEIGHT&&fmt==studio.services.surveillanceProtocol.PIXEL_BAYER_GRBG8&&bytes==studio.services.surveillanceProtocol.RGB_RAW_BYTES;
    boolean irRaw=mode==studio.services.surveillanceProtocol.MODE_IR&&hh==studio.services.surveillanceProtocol.IR_RAW_HEIGHT&&fmt==studio.services.surveillanceProtocol.PIXEL_IR_RAW10_PACKED&&bytes==studio.services.surveillanceProtocol.IR_RAW10_BYTES;
    if(!(rgbRaw||irRaw))throw new IOException("surveillance frame format/size:"+mode+"/"+fmt+"/"+w+"x"+hh+"/"+bytes);
    byte[] payload=new byte[bytes];local.readFully(payload);
    if(rgbRaw){payload=RgbHqProcessor.bayerGrbgToNv12(payload,w,hh);if(payload==null)throw new IOException("surveillance rgb raw decode");}
    else{payload=unpackIrRaw10(payload,w,hh);hh=studio.services.surveillanceProtocol.HEIGHT;}
    SurveillanceFrame f=new SurveillanceFrame();f.mode=mode;f.width=w;f.height=hh;f.flags=flags;f.frameNumber=frameNo;f.tickMs=tickMs;f.payload=payload;lastFrameMs=millis64();enqueue(f);
  }
  byte[] unpackIrRaw10(byte[] raw,int w,int rawHeight)throws IOException{
    int expected=w*rawHeight*10/8;if(raw==null||raw.length!=expected||rawHeight<studio.services.surveillanceProtocol.HEIGHT+8)throw new IOException("surveillance ir raw decode");
    byte[] out=new byte[w*studio.services.surveillanceProtocol.HEIGHT*2];long buffer=0L;int bitsIn=0,src=0;
    int pixels=w*rawHeight;for(int i=0;i<pixels;i++){while(bitsIn<10){buffer=(buffer<<8)|(raw[src++]&0xFFL);bitsIn+=8;}bitsIn-=10;int value=(int)((buffer>>bitsIn)&0x3FFL);if(bitsIn==0)buffer=0L;else buffer&=(1L<<bitsIn)-1L;int row=i/w;if(row>=4&&row<4+studio.services.surveillanceProtocol.HEIGHT){int dst=((row-4)*w+(i%w))*2;out[dst]=(byte)value;out[dst+1]=(byte)(value>>8);}}
    return out;
  }
  void setActive(LocalTransport p){synchronized(pipeLock){pipe=p;}}void clearActive(LocalTransport p){synchronized(pipeLock){if(pipe==p)pipe=null;}}void closeActive(){LocalTransport p;synchronized(pipeLock){p=pipe;pipe=null;}close(p);}void close(LocalTransport p){if(p!=null)try{p.close();}catch(IOException ignored){}}
}

float surveillanceIrMeanLuma(byte[] gray16,int w,int h,int step){
  if(gray16==null||w<=0||h<=0||gray16.length<w*h*2)return 0;
  long sum=0;int count=0;int stride=max(2,step);
  for(int y=stride/2;y<h;y+=stride)for(int x=stride/2;x<w;x+=stride){
    int i=(y*w+x)*2;
    int raw=(gray16[i]&0xff)|((gray16[i+1]&0xff)<<8);
    // IR transport is nominally 10-bit. Clamp so malformed/high flag bits can
    // never make the day/night state machine oscillate.
    int value=min(1023,raw&0x03ff);
    sum+=value;count++;
  }
  return count==0?0:constrain(sum/(count*1023.0f),0,1);
}

class AppearanceMotionDetector {
  final SurveillanceConfig cfg;float[] previous;int previousMode=-1,warmup=0,consecutive=0;boolean moving=false,triggered=false;
  AppearanceMotionDetector(SurveillanceConfig cfg){this.cfg=cfg;reset();}
  void reset(){previous=null;previousMode=-1;warmup=cfg.motionWarmupFrames;consecutive=0;moving=false;triggered=false;}
  float detectRgb(byte[] nv12,int w,int h){return detect(nv12,w,h,studio.services.surveillanceProtocol.MODE_RGB);}
  float detectIr(byte[] gray16,int w,int h){return detect(gray16,w,h,studio.services.surveillanceProtocol.MODE_IR);}
  float detect(byte[] payload,int w,int h,int mode){
    int step=max(2,cfg.motionSampleStep),cols=(w+step-1)/step,rows=(h+step-1)/step,count=cols*rows;
    if(previous==null||previous.length!=count||previousMode!=mode){previous=new float[count];Arrays.fill(previous,Float.NaN);previousMode=mode;warmup=cfg.motionWarmupFrames;consecutive=0;moving=false;triggered=false;}
    ByteBuffer ir=mode==studio.services.surveillanceProtocol.MODE_IR?ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN):null;
    int changed=0,valid=0,n=0;
    for(int y=0;y<h;y+=step)for(int x=0;x<w;x+=step){
      float current;
      if(mode==studio.services.surveillanceProtocol.MODE_RGB)current=(payload[y*w+x]&255)/255.0f;
      else{int raw=ir.getShort((y*w+x)*2)&0xffff;current=sqrt(constrain(raw/1023.0f,0,1));}
      float old=previous[n];if(!Float.isNaN(old)){valid++;if(abs(current-old)>=cfg.motionLumaDelta)changed++;}previous[n++]=current;
    }
    float score=valid==0?0:changed/(float)valid;
    if(warmup>0){warmup--;moving=false;triggered=false;consecutive=0;return score;}
    moving=valid>=cfg.motionMinimumValidSamples&&score>=cfg.motionMinimumChangedRatio;
    if(moving){consecutive++;triggered=consecutive>=cfg.motionArmFrames;}else{consecutive=0;triggered=false;}
    return score;
  }
  boolean moving(){return moving;}boolean triggered(){return triggered;}
}

class RetainedVideoFrame {final long epochMs;final byte[] jpeg;RetainedVideoFrame(long epochMs,byte[] jpeg){this.epochMs=epochMs;this.jpeg=jpeg;}}
class VideoRetentionBuffer {
  final Object lock=new Object();final ArrayDeque<RetainedVideoFrame> frames=new ArrayDeque<RetainedVideoFrame>();final long retentionMs;long bytes=0;
  VideoRetentionBuffer(long retentionMs){this.retentionMs=Math.max(1000L,retentionMs);}
  void add(RetainedVideoFrame f){synchronized(lock){frames.addLast(f);bytes+=f.jpeg.length;long cutoff=f.epochMs-retentionMs;while(!frames.isEmpty()&&frames.peekFirst().epochMs<cutoff){bytes-=frames.removeFirst().jpeg.length;}}}
  ArrayList<RetainedVideoFrame> since(long cutoff){synchronized(lock){ArrayList<RetainedVideoFrame> out=new ArrayList<RetainedVideoFrame>();for(RetainedVideoFrame f:frames)if(f.epochMs>=cutoff)out.add(f);return out;}}
  long bytes(){synchronized(lock){return bytes;}}long durationMs(){synchronized(lock){return frames.size()<2?0:frames.peekLast().epochMs-frames.peekFirst().epochMs;}}int size(){synchronized(lock){return frames.size();}}void clear(){synchronized(lock){frames.clear();bytes=0;}}
}

class EncodedSurveillanceFrame {
  final byte[] jpeg;
  final int[] previewPixels;
  EncodedSurveillanceFrame(byte[] jpeg,int[] pixels){this.jpeg=jpeg;this.previewPixels=pixels;}
}

EncodedSurveillanceFrame encodeSurveillanceJpeg(byte[] nv12,int sw,int sh,SurveillanceConfig cfg,long epochMs,String cameraLabel)throws IOException{
  if(nv12==null||nv12.length!=sw*sh*3/2)return null;
  int tw=cfg.recordWidth,th=cfg.recordHeight;
  int[] pixels=new int[tw*th];
  int ySize=sw*sh;
  for(int y=0;y<th;y++){
    int sy=y*sh/th;
    for(int x=0;x<tw;x++){
      int sx=x*sw/tw;
      int yi=nv12[sy*sw+sx]&255;
      int uv=ySize+(sy/2)*sw+(sx&~1);
      int u=(nv12[uv]&255)-128,v=(nv12[uv+1]&255)-128,c=max(0,yi-16);
      int r=(298*c+409*v+128)>>8,g=(298*c-100*u-208*v+128)>>8,b=(298*c+516*u+128)>>8;
      pixels[y*tw+x]=0xFF000000|(constrain(r,0,255)<<16)|(constrain(g,0,255)<<8)|constrain(b,0,255);
    }
  }
  return encodeSurveillancePixels(pixels,tw,th,cfg,epochMs,cameraLabel);
}

float surveillanceMeanLuma(byte[] nv12,int w,int h){
  if(nv12==null||nv12.length<w*h)return 1;
  long sum=0;int step=8,count=0;
  for(int y=0;y<h;y+=step)for(int x=0;x<w;x+=step){sum+=nv12[y*w+x]&255;count++;}
  return count==0?1:(sum/(float)count)/255.0f;
}

EncodedSurveillanceFrame encodeSurveillanceIrJpeg(byte[] gray16,int sw,int sh,SurveillanceConfig cfg,long epochMs,String cameraLabel)throws IOException{
  if(gray16==null||gray16.length!=sw*sh*2)return null;
  int tw=cfg.recordWidth,th=cfg.recordHeight;
  int[] pixels=new int[tw*th];
  ByteBuffer src=ByteBuffer.wrap(gray16).order(ByteOrder.LITTLE_ENDIAN);
  for(int y=0;y<th;y++){
    int sy=y*sh/th;
    for(int x=0;x<tw;x++){
      int sx=x*sw/tw;
      int raw=src.getShort((sy*sw+sx)*2)&0xffff;
      float norm=constrain(raw/1023.0f,0,1);
      int v=constrain((int)(sqrt(norm)*255.0f),0,255);
      pixels[y*tw+x]=0xFF000000|(v<<16)|(v<<8)|v;
    }
  }
  return encodeSurveillancePixels(pixels,tw,th,cfg,epochMs,cameraLabel);
}

String fitSurveillanceOverlayText(String value,java.awt.FontMetrics fm,int maxWidth){
  String text=value==null?"":value;
  if(fm.stringWidth(text)<=maxWidth)return text;
  final String suffix="…";
  int keep=text.codePointCount(0,text.length());
  while(keep>1){
    keep--;
    int end=text.offsetByCodePoints(0,keep);
    String candidate=text.substring(0,end)+suffix;
    if(fm.stringWidth(candidate)<=maxWidth)return candidate;
  }
  return suffix;
}

void drawSurveillanceTimestampOverlay(BufferedImage image,SurveillanceConfig cfg,long epochMs,String cameraLabel){
  if(image==null)return;
  Graphics2D g=image.createGraphics();
  try{
    g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING,RenderingHints.VALUE_TEXT_ANTIALIAS_ON);
    g.setRenderingHint(RenderingHints.KEY_RENDERING,RenderingHints.VALUE_RENDER_QUALITY);
    int tw=image.getWidth(),th=image.getHeight();
    int margin=max(4,cfg.timestampMargin);
    int pad=max(6,tw/96);
    int maxBoxWidth=max(40,tw-margin*2);
    int fontSize=max(10,tw/32);
    java.awt.Font font=new java.awt.Font(cfg.uiFontFamily,java.awt.Font.BOLD,fontSize);
    g.setFont(font);
    java.awt.FontMetrics fm=g.getFontMetrics();

    // Date/time is mandatory evidence and is never sacrificed to a long camera name.
    String dateTime=formatSurveillanceTimestamp(epochMs);
    int textLimit=max(16,maxBoxWidth-pad*2);
    while(fontSize>8&&fm.stringWidth(dateTime)>textLimit){
      fontSize--;
      font=new java.awt.Font(cfg.uiFontFamily,java.awt.Font.BOLD,fontSize);
      g.setFont(font);
      fm=g.getFontMetrics();
    }
    String camera=fitSurveillanceOverlayText(cameraLabel,fm,textLimit);
    int textWidth=max(fm.stringWidth(dateTime),fm.stringWidth(camera));
    int lines=(camera==null||camera.length()==0)?1:2;
    int lineGap=max(1,fontSize/8);
    int bw=min(maxBoxWidth,textWidth+pad*2);
    int bh=pad*2+fm.getHeight()*lines+lineGap*(lines-1);
    int x=max(margin,tw-margin-bw);
    int y=max(margin,th-margin-bh);

    g.setColor(new java.awt.Color(0,0,0,190));
    g.fillRoundRect(x,y,bw,bh,max(8,fontSize/2),max(8,fontSize/2));
    g.setColor(java.awt.Color.WHITE);
    int baseline=y+pad+fm.getAscent();
    g.drawString(dateTime,x+pad,baseline);
    if(lines==2)g.drawString(camera,x+pad,baseline+fm.getHeight()+lineGap);
  }finally{
    g.dispose();
  }
}

EncodedSurveillanceFrame encodeSurveillancePixels(int[] pixels,int tw,int th,SurveillanceConfig cfg,long epochMs,String cameraLabel)throws IOException{
  BufferedImage image=new BufferedImage(tw,th,BufferedImage.TYPE_INT_RGB);
  image.setRGB(0,0,tw,th,pixels,0,tw);

  // Surveillance v1 always burns date/time into the evidence frame. The exact same
  // stamped pixels feed the live preview, retention ring and internal MJPEG AVI recording.
  drawSurveillanceTimestampOverlay(image,cfg,epochMs,cameraLabel);

  int[] stampedPixels=new int[tw*th];
  image.getRGB(0,0,tw,th,stampedPixels,0,tw);

  int targetBytes=max(4096,cfg.recordTargetFrameKb*1024);
  float quality=cfg.retentionJpegQuality;byte[] jpeg=null;
  // Adaptive per-frame budget: preserve quality on simple scenes, then step it
  // down only when texture/noise would otherwise make event files balloon.
  // At the default 10 KiB/frame and 5 fps the nominal budget is ~2.9 MiB/min.
  while(true){jpeg=encodeSurveillanceJpegImage(image,quality);if(jpeg.length<=targetBytes||quality<=cfg.retentionJpegMinQuality+.001f)break;quality=max(cfg.retentionJpegMinQuality,quality-.05f);}
  return new EncodedSurveillanceFrame(jpeg,stampedPixels);
}

byte[] encodeSurveillanceJpegImage(BufferedImage image,float quality)throws IOException{
  ByteArrayOutputStream out=new ByteArrayOutputStream(max(8192,image.getWidth()*image.getHeight()/8));Iterator<ImageWriter> writers=ImageIO.getImageWritersByFormatName("jpeg");if(!writers.hasNext())throw new IOException("JPEG writer unavailable");ImageWriter writer=writers.next();ImageOutputStream ios=ImageIO.createImageOutputStream(out);try{writer.setOutput(ios);JPEGImageWriteParam p=new JPEGImageWriteParam(Locale.ROOT);p.setCompressionMode(JPEGImageWriteParam.MODE_EXPLICIT);p.setCompressionQuality(constrain(quality,.1f,.95f));writer.write(null,new IIOImage(image,null,null),p);ios.flush();return out.toByteArray();}finally{try{ios.close();}catch(Exception ignored){}writer.dispose();}
}

class SurveillanceEventSession {
  final SurveillanceConfig cfg;final LinkedHashMap<String,CameraEventRecorder> recorders=new LinkedHashMap<String,CameraEventRecorder>();final Object lock=new Object();File sessionDir;volatile boolean failed=false;volatile String lastError="";long startedEpochMs;
  SurveillanceEventSession(SurveillanceConfig cfg){this.cfg=cfg;}
  void start(List<SurveillanceCamera> cameras)throws IOException{File root=cfg.recordingsRoot();if(!root.exists()&&!root.mkdirs())throw new IOException("cannot create "+root);startedEpochMs=System.currentTimeMillis();String stamp=new SimpleDateFormat("yyyyMMdd-HHmmss",Locale.ROOT).format(new Date(startedEpochMs));sessionDir=uniqueEventDirectory(root,"event-"+stamp);if(!sessionDir.mkdirs())throw new IOException("cannot create "+sessionDir);for(SurveillanceCamera c:cameras)ensureCamera(c);writeMetadata("recording");}
  void ensureCamera(SurveillanceCamera camera){if(camera==null||sessionDir==null)return;synchronized(lock){if(recorders.containsKey(camera.device.id))return;try{ArrayList<RetainedVideoFrame> pre=camera.retention.since(System.currentTimeMillis()-cfg.preRollSeconds*1000L);CameraEventRecorder r=new CameraEventRecorder(camera.device,cfg,new File(sessionDir,"kinect-"+safeToken(camera.device.id)+".avi"),pre);recorders.put(camera.device.id,r);r.start();}catch(Exception e){failed=true;lastError=safeStudioMessage(e);}}}
  void submit(SurveillanceCamera camera,RetainedVideoFrame frame){synchronized(lock){CameraEventRecorder r=recorders.get(camera.device.id);if(r!=null)r.submit(frame);}}
  void stop(){ArrayList<CameraEventRecorder> copy;synchronized(lock){copy=new ArrayList<CameraEventRecorder>(recorders.values());}for(CameraEventRecorder r:copy){r.stop();if(r.failed){failed=true;if(lastError.length()==0)lastError=r.lastError;}}writeMetadata(failed?"failed":"complete");}
  boolean hasFailed(){if(failed)return true;synchronized(lock){for(CameraEventRecorder r:recorders.values())if(r.failed)return true;}return false;}
  String failureMessage(){if(lastError.length()>0)return lastError;synchronized(lock){for(CameraEventRecorder r:recorders.values())if(r.failed)return r.lastError;}return "";}
  void writeMetadata(String state){if(sessionDir==null)return;Properties p=new Properties();p.setProperty("state",state);p.setProperty("started.epochMs",String.valueOf(startedEpochMs));p.setProperty("updated.epochMs",String.valueOf(System.currentTimeMillis()));p.setProperty("preRoll.seconds",String.valueOf(cfg.preRollSeconds));p.setProperty("retention.minutes",String.valueOf(cfg.retentionMinutes));p.setProperty("video.codec","Motion JPEG (MJPEG) / AVI 1.0");p.setProperty("video.encoder","SynKinect internal Java AVI writer");p.setProperty("video.targetFrameKB",String.valueOf(cfg.recordTargetFrameKb));p.setProperty("video.maxJpegQuality",String.valueOf(cfg.retentionJpegQuality));p.setProperty("video.minJpegQuality",String.valueOf(cfg.retentionJpegMinQuality));p.setProperty("video.input","JPEG retention ring");p.setProperty("video.timestamp","burned-in");p.setProperty("video.timestamp.format",cfg.timestampFormat);p.setProperty("video.timestamp.timezone",TimeZone.getDefault().getID());synchronized(lock){p.setProperty("cameras",String.valueOf(recorders.size()));int i=0;for(CameraEventRecorder r:recorders.values()){p.setProperty("camera."+i+".id",r.device.id);p.setProperty("camera."+i+".label",r.device.label);p.setProperty("camera."+i+".file",r.output.getName());i++;}}try(Writer out=new OutputStreamWriter(new FileOutputStream(new File(sessionDir,"event.properties")),java.nio.charset.StandardCharsets.UTF_8)){p.store(out,"SynKinect Surveillance V1 multi-camera event");}catch(IOException e){println("event-meta: "+safeStudioMessage(e));}}
}

class CameraEventRecorder {
  final KinectDevice device;final SurveillanceConfig cfg;final File output,partial;final ArrayList<RetainedVideoFrame> preRoll;final ArrayBlockingQueue<RetainedVideoFrame> queue;volatile boolean active=false,failed=false;volatile String lastError="";Thread worker;MjpegAviWriter writer;long lastEpoch=0,dropped=0;
  CameraEventRecorder(KinectDevice device,SurveillanceConfig cfg,File output,List<RetainedVideoFrame> pre){this.device=device;this.cfg=cfg;this.output=output;this.partial=new File(output.getParentFile(),output.getName().replace(".avi",".partial.avi"));this.preRoll=new ArrayList<RetainedVideoFrame>(pre);this.queue=new ArrayBlockingQueue<RetainedVideoFrame>(max(24,cfg.recordFps*cfg.recordQueueSeconds));}
  void start()throws IOException{writer=new MjpegAviWriter(partial,cfg.recordWidth,cfg.recordHeight,cfg.recordFps);active=true;worker=studio.services.workers.start("Surveillance-MJPEG-"+safeToken(device.id),new Runnable(){public void run(){loop();}});}
  void submit(RetainedVideoFrame f){if(!active||f==null)return;if(!queue.offer(f)){queue.poll();dropped++;queue.offer(f);}}
  void loop(){boolean ok=false;try{for(RetainedVideoFrame f:preRoll)write(f);preRoll.clear();while(active||!queue.isEmpty()){RetainedVideoFrame f=queue.poll(200,TimeUnit.MILLISECONDS);if(f!=null)write(f);}ok=true;}catch(Exception e){failed=true;lastError=safeStudioMessage(e);}finally{active=false;if(writer!=null){try{writer.close();}catch(Exception e){failed=true;if(lastError.length()==0)lastError=safeStudioMessage(e);}}if(!failed&&ok&&partial.isFile()){try{Files.move(partial.toPath(),output.toPath(),StandardCopyOption.REPLACE_EXISTING);}catch(IOException e){failed=true;lastError=safeStudioMessage(e);}}}}
  void write(RetainedVideoFrame f)throws IOException{if(f==null||f.epochMs<=lastEpoch)return;writer.addJpeg(f.jpeg);lastEpoch=f.epochMs;}
  void stop(){active=false;Thread t=worker;if(t!=null){try{t.join(cfg.workerJoinMs*4L);}catch(InterruptedException e){Thread.currentThread().interrupt();}if(t.isAlive()){t.interrupt();try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}}}worker=null;}
}

class AviIndexEntry {final long offset;final int size;AviIndexEntry(long o,int s){offset=o;size=s;}}

// Minimal standards-based AVI 1.0 writer.  Every retained JPEG becomes one MJPEG
// keyframe, so no external executable, JNI codec or platform media framework is
// required.  Header/index fields are patched on close and the resulting AVI is
// structured as a conventional indexed MJPEG stream for standard AVI readers.
class MjpegAviWriter implements Closeable {
  final RandomAccessFile out;final int width,height,fps;final ArrayList<AviIndexEntry> index=new ArrayList<AviIndexEntry>();
  long riffSizePos,avihFramesPos,avihMaxBytesPos,strhFramesPos,moviSizePos,moviListStart;int maxFrameBytes=0;long payloadBytes=0;boolean closed=false;
  MjpegAviWriter(File target,int width,int height,int fps)throws IOException{this.width=max(2,width);this.height=max(2,height);this.fps=max(1,fps);out=new RandomAccessFile(target,"rw");out.setLength(0);writeHeader();}
  void writeHeader()throws IOException{
    fourcc("RIFF");riffSizePos=out.getFilePointer();le32(0);fourcc("AVI ");
    long hdrl=beginList("hdrl");
    fourcc("avih");le32(56);le32(1000000/fps);avihMaxBytesPos=out.getFilePointer();le32(0);le32(0);le32(0x10);avihFramesPos=out.getFilePointer();le32(0);le32(0);le32(1);le32(0);le32(width);le32(height);le32(0);le32(0);le32(0);le32(0);
    long strl=beginList("strl");
    fourcc("strh");le32(56);fourcc("vids");fourcc("MJPG");le32(0);le16(0);le16(0);le32(0);le32(1);le32(fps);le32(0);strhFramesPos=out.getFilePointer();le32(0);le32(0);le32(-1);le32(0);le16(0);le16(0);le16(width);le16(height);
    fourcc("strf");le32(40);le32(40);le32(width);le32(height);le16(1);le16(24);fourcc("MJPG");le32(width*height*3);le32(0);le32(0);le32(0);le32(0);
    endList(strl);
    endList(hdrl);
    fourcc("LIST");moviSizePos=out.getFilePointer();le32(0);moviListStart=out.getFilePointer();fourcc("movi");
  }
  synchronized void addJpeg(byte[] jpeg)throws IOException{if(closed)throw new EOFException("AVI recorder closed");if(jpeg==null||jpeg.length<4)return;long pos=out.getFilePointer();fourcc("00dc");le32(jpeg.length);out.write(jpeg);if((jpeg.length&1)!=0)out.write(0);index.add(new AviIndexEntry(pos,jpeg.length));maxFrameBytes=max(maxFrameBytes,jpeg.length);payloadBytes+=jpeg.length;}
  public synchronized void close()throws IOException{if(closed)return;closed=true;IOException problem=null;try{
      long moviEnd=out.getFilePointer();patch32(moviSizePos,moviEnd-(moviSizePos+4));fourcc("idx1");le32(index.size()*16);for(AviIndexEntry e:index){fourcc("00dc");le32(0x10);le32(e.offset-moviListStart);le32(e.size);}long end=out.getFilePointer();patch32(avihFramesPos,index.size());patch32(strhFramesPos,index.size());long bytesPerSecond=index.isEmpty()?0:Math.max(maxFrameBytes,(payloadBytes*fps)/Math.max(1,index.size()));patch32(avihMaxBytesPos,bytesPerSecond);patch32(riffSizePos,end-8);out.getFD().sync();
    }catch(IOException e){problem=e;}finally{try{out.close();}catch(IOException e){if(problem==null)problem=e;}}if(problem!=null)throw problem;}
  long beginList(String type)throws IOException{fourcc("LIST");long sizePos=out.getFilePointer();le32(0);fourcc(type);return sizePos;}
  void endList(long sizePos)throws IOException{long end=out.getFilePointer();patch32(sizePos,end-(sizePos+4));}
  void patch32(long pos,long value)throws IOException{long cur=out.getFilePointer();out.seek(pos);le32(value);out.seek(cur);}
  void fourcc(String s)throws IOException{if(s==null||s.length()!=4)throw new IOException("invalid FOURCC");out.writeByte(s.charAt(0));out.writeByte(s.charAt(1));out.writeByte(s.charAt(2));out.writeByte(s.charAt(3));}
  void le16(long v)throws IOException{out.writeByte((int)(v&255));out.writeByte((int)((v>>>8)&255));}
  void le32(long v)throws IOException{out.writeByte((int)(v&255));out.writeByte((int)((v>>>8)&255));out.writeByte((int)((v>>>16)&255));out.writeByte((int)((v>>>24)&255));}
}

class SurveillanceConfig {
  int uiFrameRate=30;String uiFontFamily="Segoe UI",uiHeadingFontFamily="Segoe UI Semibold",uiFontFallback="Arial";int workerJoinMs=1800,reconnectMs=250,videoQueueFrames=48;
  int motionSampleStep=8,motionMinimumValidSamples=400,motionArmFrames=3,motionWarmupFrames=10;float motionLumaDelta=0.08f,motionMinimumChangedRatio=0.025f;long motionStopAfterMs=60000;
  String timestampFormat="yyyy-MM-dd HH:mm:ss";int timestampMargin=14;
  float nightEnterLuma=0.18f,nightExitLuma=0.30f,nightIrProbeLuma=0.78f;int nightDarkFrames=12,nightBrightFrames=4,nightProbeFrames=6,nightIrProbeFrames=45;long nightProbeIntervalMs=30000;
  int retentionMinutes=10,preRollSeconds=60,retentionFps=5;float retentionJpegQuality=0.40f,retentionJpegMinQuality=0.20f;
  int recordFps=5,recordWidth=320,recordHeight=240,recordQueueSeconds=30,recordTargetFrameKb=10;String recordDirectory="recordings";
  void load(File file){Properties p=studio.services.configRules.load(file,"surveillance");uiFrameRate=intValue(p,"ui.frameRate",uiFrameRate,10,60);uiFontFamily=textValue(p,"ui.font.family",uiFontFamily);uiHeadingFontFamily=textValue(p,"ui.font.headingFamily",uiHeadingFontFamily);uiFontFallback=textValue(p,"ui.font.fallback",uiFontFallback);workerJoinMs=intValue(p,"lifecycle.workerJoinMs",workerJoinMs,250,10000);reconnectMs=intValue(p,"transport.reconnectMs",reconnectMs,50,5000);videoQueueFrames=intValue(p,"transport.videoQueueFrames",videoQueueFrames,8,240);motionSampleStep=intValue(p,"motion.sampleStep",motionSampleStep,2,32);motionLumaDelta=floatValue(p,"motion.lumaDelta",motionLumaDelta,0.005f,0.80f);motionMinimumValidSamples=intValue(p,"motion.minimumValidSamples",motionMinimumValidSamples,20,10000);motionMinimumChangedRatio=floatValue(p,"motion.minimumChangedRatio",motionMinimumChangedRatio,0.001f,0.95f);motionArmFrames=intValue(p,"motion.armFrames",motionArmFrames,1,30);motionWarmupFrames=intValue(p,"motion.warmupFrames",motionWarmupFrames,0,120);motionStopAfterMs=longValue(p,"motion.stopAfterMs",motionStopAfterMs,1000,3600000);timestampFormat=textValue(p,"overlay.timestamp.format",timestampFormat);timestampMargin=intValue(p,"overlay.timestamp.margin",timestampMargin,4,64);nightEnterLuma=floatValue(p,"night.enterLuma",nightEnterLuma,0.02f,0.8f);nightExitLuma=floatValue(p,"night.exitLuma",nightExitLuma,nightEnterLuma,0.95f);nightDarkFrames=intValue(p,"night.darkFrames",nightDarkFrames,2,120);nightBrightFrames=intValue(p,"night.brightFrames",nightBrightFrames,1,60);nightProbeFrames=intValue(p,"night.probeFrames",nightProbeFrames,2,60);nightIrProbeLuma=floatValue(p,"night.irProbeLuma",nightIrProbeLuma,0.20f,0.98f);nightIrProbeFrames=intValue(p,"night.irProbeFrames",nightIrProbeFrames,5,300);nightProbeIntervalMs=longValue(p,"night.probeIntervalMs",nightProbeIntervalMs,5000,300000);retentionMinutes=intValue(p,"retention.minutes",retentionMinutes,1,60);preRollSeconds=intValue(p,"retention.preRollSeconds",preRollSeconds,1,retentionMinutes*60);recordFps=intValue(p,"record.fps",recordFps,1,30);retentionFps=intValue(p,"retention.fps",retentionFps,1,recordFps);retentionJpegQuality=floatValue(p,"retention.jpegQuality",retentionJpegQuality,0.2f,0.95f);retentionJpegMinQuality=floatValue(p,"retention.jpegMinQuality",retentionJpegMinQuality,0.1f,retentionJpegQuality);recordWidth=evenValue(p,"record.width",recordWidth,160,640);recordHeight=evenValue(p,"record.height",recordHeight,120,480);recordQueueSeconds=intValue(p,"record.queueSeconds",recordQueueSeconds,5,120);recordTargetFrameKb=intValue(p,"record.targetFrameKB",recordTargetFrameKb,4,96);recordDirectory=textValue(p,"record.directory",recordDirectory);}
  File recordingsRoot(){File f=new File(recordDirectory);return f.isAbsolute()?f:new File(sketchPath(recordDirectory));}
  String textValue(Properties p,String k,String d){return studio.services.configRules.text(p,k,d);}boolean boolValue(Properties p,String k,boolean d){return studio.services.configRules.flag(p,k,d);}int intValue(Properties p,String k,int d,int lo,int hi){return studio.services.configRules.integer(p,k,d,lo,hi);}int evenValue(Properties p,String k,int d,int lo,int hi){return studio.services.configRules.even(p,k,d,lo,hi);}long longValue(Properties p,String k,long d,long lo,long hi){return studio.services.configRules.longNumber(p,k,d,lo,hi);}float floatValue(Properties p,String k,float d,float lo,float hi){return studio.services.configRules.decimal(p,k,d,lo,hi);}
}

class SurveillanceProtocol {
  final int MAGIC=0x43534D52,FRAME_MAGIC=0x46534D52,VERSION=1,CMD_SUBSCRIBE_STREAMS=1;
  final int WIDTH=640,HEIGHT=480,IR_RAW_HEIGHT=488,MODE_RGB=0,MODE_IR=1,STREAM_RGB=1,STREAM_IR=2;
  final int PIXEL_BAYER_GRBG8=4,PIXEL_IR_RAW10_PACKED=5;
  final int RGB_RAW_BYTES=WIDTH*HEIGHT,IR_RAW10_BYTES=WIDTH*IR_RAW_HEIGHT*10/8;
  final int MAX_PAYLOAD_BYTES=max(RGB_RAW_BYTES,IR_RAW10_BYTES),REPLY_BYTES=68,FRAME_HEADER_BYTES=76;
}

class SurveillanceI18n extends ModuleI18n {SurveillanceI18n(String requested){super("surveillance",requested);}}
class SurveillanceTheme {final int BG=0xFF11151A,SURFACE=0xFF181E25,SURFACE_ALT=0xFF202832,SURFACE_RAISED=0xFF293440,BORDER=0xFF35414D,TEXT=0xFFF4F7FA,MUTED=0xFFAAB6C2,ACCENT=0xFF68A9E8,GOOD=0xFF7CC7A0,WARN=0xFFE4B86B,BAD=0xFFE17D7D,PREVIEW=0xFF0B0F13;final int MARGIN=20,GAP=14,RADIUS=14,FONT_TINY=12,FONT_SMALL=14,FONT_BODY=15,FONT_METRIC=19,FONT_TITLE=27;}
PFont surveillanceFontRegular,surveillanceFontHeading;
void initializeSurveillanceTypography(){String regular="SansSerif",heading="SansSerif";surveillanceFontRegular=createFont(regular,studio.services.surveillanceTheme.FONT_BODY,true);surveillanceFontHeading=createFont(heading,studio.services.surveillanceTheme.FONT_TITLE,true);}
String resolveSurveillanceFont(String preferred,String fallback){String[] installed=PFont.list();String hit=findSurveillanceFont(installed,preferred);if(hit!=null)return hit;hit=findSurveillanceFont(installed,fallback);return hit==null?"SansSerif":hit;}String findSurveillanceFont(String[] installed,String wanted){if(wanted==null||wanted.trim().isEmpty()||installed==null)return null;for(String c:installed)if(c.equalsIgnoreCase(wanted.trim()))return c;return null;}void surveillanceText(float size,boolean heading){PFont f=heading?surveillanceFontHeading:surveillanceFontRegular;if(f!=null)textFont(f);textSize(responsiveFontSize(size));}
String formatSurveillanceTimestamp(long epochMs){try{return new SimpleDateFormat(studio.surveillanceState.config.timestampFormat,Locale.ROOT).format(new Date(epochMs));}catch(Exception e){return new SimpleDateFormat("yyyy-MM-dd HH:mm:ss",Locale.ROOT).format(new Date(epochMs));}}
File uniqueEventDirectory(File root,String base){File f=new File(root,base);for(int i=2;f.exists();i++)f=new File(root,base+"-"+i);return f;}
String safeToken(String value){String s=value==null?"kinect":value.replaceAll("[^A-Za-z0-9._-]+","-");while(s.startsWith("-"))s=s.substring(1);return s.isEmpty()?"kinect":s;}

class SurveillanceUI {
  final UiRect armButton=new UiRect(),recordButton=new UiRect(),stopButton=new UiRect();PImage previewImage;
  void draw(){SurveillanceModuleState s=studio.surveillanceState;float m=studio.services.surveillanceTheme.MARGIN,g=studio.services.surveillanceTheme.GAP,w=width-2*m,h=studio.contentHeight-2*m;fill(studio.services.surveillanceTheme.TEXT);surveillanceText(24,true);textAlign(LEFT,BASELINE);String title=s.i18n.tr("app.title");fitCurrentTextSize(title,24,9,w,34);text(ellipsizeToWidth(title,w),m,m+26);float top=m+42,bottom=86,avail=max(180,h-top-bottom);if(w>=860){float right=constrain(w*.30f,240,360),left=max(160,w-right-g);drawPreview(m,top,left,avail);drawStatus(m+left+g,top,right,avail);}else{float previewH=max(65,(avail-g)*.55f),statusH=max(55,avail-previewH-g);if(previewH+statusH+g>avail){float k=avail/max(1,previewH+statusH+g);previewH*=k;statusH*=k;}drawPreview(m,top,w,previewH);drawStatus(m,top+previewH+g,w,statusH);}drawButtons(m,h-bottom+g,w,bottom-g);}
  SurveillanceCamera selectedCamera(){KinectDevice selected=studio.selectedKinect();synchronized(studio.surveillanceState.cameraLock){if(selected!=null){SurveillanceCamera c=studio.surveillanceState.cameras.get(selected.id);if(c!=null)return c;}return studio.surveillanceState.cameras.isEmpty()?null:studio.surveillanceState.cameras.values().iterator().next();}}
  void drawPreview(float x,float y,float w,float h){card(x,y,w,h);SurveillanceCamera c=selectedCamera();if(c==null||c.latestPreviewPixels==null){fill(studio.services.surveillanceTheme.MUTED);surveillanceText(15,false);textAlign(CENTER,CENTER);text(studio.surveillanceState.i18n.tr("waiting.video"),x+w/2,y+h/2);return;}int pw=c.previewWidth,ph=c.previewHeight;if(previewImage==null||previewImage.width!=pw||previewImage.height!=ph)previewImage=createImage(pw,ph,RGB);previewImage.loadPixels();int[] src=c.latestPreviewPixels;if(src.length==previewImage.pixels.length)System.arraycopy(src,0,previewImage.pixels,0,src.length);previewImage.updatePixels();float pad=12,scale=min((w-pad*2)/pw,(h-pad*2)/ph),dw=pw*scale,dh=ph*scale;image(previewImage,x+(w-dw)/2,y+(h-dh)/2,dw,dh);fill(studio.services.surveillanceTheme.TEXT);surveillanceText(13,true);textAlign(LEFT,TOP);text(c.device.label,x+14,y+12);if(studio.surveillanceState.recording){fill(studio.services.surveillanceTheme.BAD);ellipse(x+w-24,y+22,10,10);}}
  void drawStatus(float x,float y,float w,float h){card(x,y,w,h);SurveillanceModuleState s=studio.surveillanceState;int count;long bytes=0,minDuration=Long.MAX_VALUE;synchronized(s.cameraLock){count=s.cameras.size();for(SurveillanceCamera c:s.cameras.values()){bytes+=c.retainedBytes();minDuration=Math.min(minDuration,c.retainedDurationMs());}}if(minDuration==Long.MAX_VALUE)minDuration=0;String[] labels={s.i18n.tr("label.state"),s.i18n.tr("label.cameras"),s.i18n.tr("label.ram"),s.i18n.tr("label.retention"),s.i18n.tr("label.preroll"),s.i18n.tr("label.motion"),s.i18n.tr("label.video_mode")};SurveillanceCamera selected=selectedCamera();String[] values={s.recording?s.i18n.tr("state.recording"):(s.armed?s.i18n.tr("state.armed"):s.i18n.tr("state.disarmed")),String.valueOf(count),formatBytes(bytes),formatDuration(minDuration)+" / "+s.config.retentionMinutes+" min",s.config.preRollSeconds+" s",nf(s.motionScore*100,1,2)+"%",selected==null?"—":selected.videoModeLabel()+" · "+nf(selected.meanLuma*100,1,0)+"%"};float statusReserve=max(32,44*studioUiScale()),step=constrain((h-statusReserve-28)/labels.length,22,42),yy=y+max(24,30*studioUiScale());for(int i=0;i<labels.length;i++){statusLine(x,w,yy,labels[i],values[i]);yy+=step;}fill(studio.services.surveillanceTheme.MUTED);surveillanceText(11,false);textAlign(LEFT,TOP);text(ellipsizeToWidth(s.status,w-28),x+14,min(y+h-22,yy+4));}
  void statusLine(float x,float w,float y,String label,String value){fill(studio.services.surveillanceTheme.MUTED);surveillanceText(12,false);textAlign(LEFT,BASELINE);text(label,x+14,y);fill(studio.services.surveillanceTheme.TEXT);surveillanceText(14,true);textAlign(RIGHT,BASELINE);text(ellipsizeToWidth(value,w*0.54f),x+w-14,y);}
  void drawButtons(float x,float y,float w,float h){card(x,y,w,h);float gap=10,bw=(w-gap*2-24)/3f,bh=h-24,bx=x+12,by=y+12;armButton.set(bx,by,bw,bh);recordButton.set(bx+bw+gap,by,bw,bh);stopButton.set(bx+2*(bw+gap),by,bw,bh);boolean busy=studio.surveillanceState.recording||studio.surveillanceState.recordStarting;button(armButton,studio.surveillanceState.armed?studio.surveillanceState.i18n.tr("button.disarm"):studio.surveillanceState.i18n.tr("button.arm"),true);button(recordButton,studio.surveillanceState.i18n.tr("button.record"),!busy);button(stopButton,studio.surveillanceState.i18n.tr("button.stop"),busy);}
  void button(UiRect r,String label,boolean enabled){boolean hot=enabled&&r.hit(studio.contentMouseX(),studio.contentMouseY());stroke(hot?studio.services.surveillanceTheme.ACCENT:studio.services.surveillanceTheme.BORDER);fill(enabled?studio.services.surveillanceTheme.SURFACE_RAISED:studio.services.surveillanceTheme.BG);rect(r.x,r.y,r.w,r.h,9);noStroke();fill(enabled?studio.services.surveillanceTheme.TEXT:studio.services.surveillanceTheme.BORDER);textAlign(CENTER,CENTER);surveillanceText(13,true);fitCurrentTextSize(label,13,7,r.w-12,r.h-8);text(ellipsizeToWidth(label,r.w-12),r.x+r.w/2,r.y+r.h/2);}
  void handleMouse(float mx,float my){boolean busy=studio.surveillanceState.recording||studio.surveillanceState.recordStarting;if(armButton.hit(mx,my))toggleArmed();else if(recordButton.hit(mx,my)&&!busy)manualRecord();else if(stopButton.hit(mx,my)&&busy)requestStopMotionRecording(false);}
  void card(float x,float y,float w,float h){stroke(studio.services.surveillanceTheme.BORDER);fill(studio.services.surveillanceTheme.SURFACE);rect(x,y,w,h,studio.services.surveillanceTheme.RADIUS);noStroke();}
  String formatBytes(long bytes){double mb=bytes/(1024.0*1024.0);return mb<1024?String.format(Locale.ROOT,"%.1f MB",mb):String.format(Locale.ROOT,"%.2f GB",mb/1024.0);}String formatDuration(long ms){long sec=Math.max(0L,ms/1000),m=sec/60,s=sec%60;return String.format(Locale.ROOT,"%02d:%02d",m,s);}
}
class UiRect{float x,y,w,h;void set(float x,float y,float w,float h){this.x=x;this.y=y;this.w=w;this.h=h;}boolean hit(float px,float py){return px>=x&&px<=x+w&&py>=y&&py<=y+h;}}
