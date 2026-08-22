class RawRgbFrame {
  final byte[] nv12; final long frameNumber,timestampUs;
  RawRgbFrame(byte[] nv12,long frameNumber,long timestampUs){this.nv12=nv12;this.frameNumber=frameNumber;this.timestampUs=timestampUs;}
}

class KinectSource {
  AppConfig config;
  Calibration calibration;
  I18n i18n;

  volatile boolean portReady = false, deviceConnected = false, depthConnected = false, colorConnected = false;
  volatile boolean metricDepthCalibrated = false, running = false;
  volatile boolean lastDepthRecovered = false;
  volatile int acceptedStreams = 0, capabilities = 0, negotiatedMaxPayload = 0;
  volatile String lastTransportError = "", depthWarning = "";
  volatile long depthFrames = 0, colorFrames = 0;
  volatile long lastDepthArrivalMs = 0, lastColorArrivalMs = 0, lastAnyArrivalMs = 0;
  volatile long connectedSinceMs = 0, connectionEpoch = 0, reconnectKicks = 0, lastReconnectKickMs = 0;
  volatile MotionSample latestMotion = new MotionSample();

  Thread worker = null;
  volatile LocalTransport activeScannerPipe = null;
  final Object pipeLock = new Object();
  final Object frameLock = new Object();
  DepthFrame pendingDepth = null;
  RawRgbFrame pendingRgb = null;
  final byte[] frameHeaderBuffer = new byte[ScannerProtocol.FRAME_HEADER_BYTES];
  final long[] lastFrameNumber = new long[]{-1L, -1L, -1L};

  KinectSource(AppConfig config, Calibration calibration, I18n i18n) {
    this.config = config; this.calibration = calibration; this.i18n = i18n;
  }

  void start() {
    if (running) return;
    resetConnectionState(true);
    running = true;
    worker = new Thread(new Runnable(){ public void run(){ streamWorkerLoop(); }}, "SynKinect3DScanner-Port");
    worker.setDaemon(true); worker.start();
  }

  void stop() {
    running = false; closeActivePipe();
    Thread t = worker;
    if (t != null) {
      t.interrupt();
      try { t.join(config.workerJoinMs); } catch (InterruptedException ignored) { Thread.currentThread().interrupt(); }
    }
    worker = null;
    synchronized(pipeLock){ activeScannerPipe = null; }
    resetConnectionState(true);
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
    acceptedStreams=0; capabilities=0; negotiatedMaxPayload=0; depthWarning="";
    connectedSinceMs=0; lastDepthArrivalMs=0; lastColorArrivalMs=0; lastAnyArrivalMs=0;
    for(int i=0;i<lastFrameNumber.length;i++) lastFrameNumber[i]=-1L;
    if(clearPending) synchronized(frameLock){ pendingDepth=null; pendingRgb=null; }
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

  void requestReconnect(String reason){
    if(!running)return;
    long now=monotonicMs();
    if(now-lastReconnectKickMs<Math.max(100,config.reconnectDelayMs))return;
    lastReconnectKickMs=now; reconnectKicks++; lastTransportError=i18n.format("transport.error",reason);
    closeActivePipe();
  }

  DepthFrame pollDepth(){ synchronized(frameLock){ DepthFrame f=pendingDepth; pendingDepth=null; return f; } }
  RgbSnapshot pollVideoSnapshot(){
    RawRgbFrame raw; synchronized(frameLock){ raw=pendingRgb; pendingRgb=null; }
    if(raw==null)return null;
    PImage image=nv12ToImage(raw.nv12,ScannerProtocol.WIDTH,ScannerProtocol.HEIGHT);
    return image==null?null:new RgbSnapshot(image,raw.frameNumber,raw.timestampUs,System.currentTimeMillis());
  }

  void streamWorkerLoop(){
    while(running){
      LocalTransport pipe=null;
      try{
        resetConnectionState(true);
        pipe=LocalTransport.open(ScannerProtocol.PIPE_NAME,ScannerProtocol.SOCKET_NAME); setActivePipe(pipe);
        subscribe(pipe,ScannerProtocol.STREAM_SESSION);
        connectedSinceMs=monotonicMs(); connectionEpoch++; lastTransportError="";
        while(running) readFrame(pipe,ScannerProtocol.STREAM_SESSION);
      } catch(Exception e) {
        resetConnectionState(true);
        if(running) lastTransportError=i18n.format("transport.error", safeMessage(e));
      } finally { clearActivePipe(pipe); closePipe(pipe); }
      if(running) try{Thread.sleep(config.reconnectDelayMs);}catch(InterruptedException ignored){if(!running)return;Thread.currentThread().interrupt(); return;}
    }
  }

  void subscribe(LocalTransport pipe,int mask)throws IOException{
    if(mask!=ScannerProtocol.STREAM_SESSION) throw new IOException("protocol/stream-mask:"+mask);
    ByteBuffer req=ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN);
    req.putInt(ScannerProtocol.MAGIC); req.putInt(ScannerProtocol.VERSION); req.putInt(ScannerProtocol.CMD_SUBSCRIBE_STREAMS); req.putInt(mask); pipe.write(req.array());

    byte[] rb=new byte[ScannerProtocol.REPLY_BYTES]; pipe.readFully(rb); ByteBuffer r=ByteBuffer.wrap(rb).order(ByteOrder.LITTLE_ENDIAN);
    int magic=r.getInt(), version=r.getInt(), result=r.getInt(), accepted=r.getInt();
    int w=r.getInt(), h=r.getInt(), caps=r.getInt(), maxPayload=r.getInt();
    if(magic!=ScannerProtocol.MAGIC) throw new IOException("protocol/reply-magic");
    if(version!=ScannerProtocol.VERSION) throw new IOException("protocol/version:"+version);
    if(result<0) throw new IOException("protocol/subscribe:0x"+Integer.toHexString(result));
    if(accepted!=mask) throw new IOException("protocol/accepted-mask:"+accepted+"/"+mask);
    if(w!=ScannerProtocol.WIDTH||h!=ScannerProtocol.HEIGHT) throw new IOException("protocol/dimensions:"+w+"x"+h);
    if((caps&ScannerProtocol.REQUIRED_CAPABILITIES)!=ScannerProtocol.REQUIRED_CAPABILITIES) throw new IOException("protocol/capabilities:0x"+Integer.toHexString(caps));
    if(maxPayload<ScannerProtocol.MAX_PAYLOAD_BYTES) throw new IOException("protocol/max-payload:"+maxPayload);
    acceptedStreams=accepted; capabilities=caps; negotiatedMaxPayload=maxPayload; portReady=true;
  }

  void readFrame(LocalTransport input,int sessionMask)throws IOException{
    input.readFully(frameHeaderBuffer);
    ByteBuffer h=ByteBuffer.wrap(frameHeaderBuffer).order(ByteOrder.LITTLE_ENDIAN);
    int magic=h.getInt(), version=h.getInt(), mode=h.getInt(), w=h.getInt(), hh=h.getInt(), fmt=h.getInt(), bytes=h.getInt(), flags=h.getInt();
    long frameNumber=h.getLong(), tickMs=h.getLong();
    MotionSample motion=new MotionSample();
    motion.flags=h.getInt(); motion.accelX=h.getInt(); motion.accelY=h.getInt(); motion.accelZ=h.getInt(); motion.tiltTenths=h.getInt(); motion.timestampMs=h.getLong();

    if(magic!=ScannerProtocol.FRAME_MAGIC) throw new IOException("frame/magic");
    if(version!=ScannerProtocol.VERSION) throw new IOException("frame/version:"+version);
    if(w!=ScannerProtocol.WIDTH||hh!=ScannerProtocol.HEIGHT) throw new IOException("frame/dimensions:"+w+"x"+hh);
    int modeMask=scannerMaskForMode(mode);
    if(modeMask==0 || (sessionMask&modeMask)==0) throw new IOException("frame/mode:"+mode);
    if(bytes<0||bytes>negotiatedMaxPayload||bytes>ScannerProtocol.MAX_PAYLOAD_BYTES) throw new IOException("frame/payload:"+bytes);
    if((flags&~ScannerProtocol.KNOWN_FRAME_FLAGS)!=0) throw new IOException("frame/flags:0x"+Integer.toHexString(flags));
    if(lastFrameNumber[mode]>=0 && frameNumber<=lastFrameNumber[mode]) throw new IOException("frame/order:"+mode);
    lastFrameNumber[mode]=frameNumber;
    if(fmt!=scannerExpectedFormatForMode(mode)) throw new IOException("frame/format:"+mode+"/"+fmt);
    if(bytes!=scannerExpectedPayloadBytesForMode(mode)) throw new IOException("frame/size:"+mode+"/"+bytes);

    byte[] payload=new byte[bytes]; input.readFully(payload);
    long arrival=monotonicMs(); lastAnyArrivalMs=arrival; deviceConnected=true; lastTransportError="";

    if(mode==ScannerProtocol.MODE_DEPTH){
      ByteBuffer p=ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN); DepthFrame f=new DepthFrame();
      f.frameId=(int)(frameNumber&0x7FFFFFFF); f.frameNumber=frameNumber; f.timestampUs=tickMs*1000L;
      f.width=ScannerProtocol.WIDTH; f.height=ScannerProtocol.HEIGHT; f.stride=ScannerProtocol.WIDTH*2; f.pixelFormat=ScannerProtocol.PIXEL_DEPTH_MM16;
      f.depth=new short[ScannerProtocol.WIDTH*ScannerProtocol.HEIGHT]; f.motion=motion; latestMotion=motion;
      f.deviceCalibrated=(flags&ScannerProtocol.FLAG_DEVICE_CALIBRATED)!=0;
      f.transportRecovered=(flags&ScannerProtocol.FLAG_FRAME_RECOVERED)!=0;
      int valid=0, plausible=0;
      for(int i=0;i<f.depth.length;i++){
        short sample=p.getShort(); f.depth[i]=sample; int mm=sample&0xFFFF;
        if(mm!=0) valid++;
        if(mm>=config.depthPlausibleMinMm && mm<=config.depthPlausibleMaxMm) plausible++;
      }
      f.validCount=valid; f.plausibleCount=plausible;
      float ratio=plausible/(float)f.depth.length;
      depthConnected=f.deviceCalibrated && plausible>=config.depthMinValidPixels && ratio>=config.depthMinValidRatio;
      metricDepthCalibrated=f.deviceCalibrated; lastDepthRecovered=f.transportRecovered;
      depthWarning = depthConnected ? "" : i18n.format(f.deviceCalibrated ? "transport.depth_sparse" : "transport.depth_uncalibrated", plausible, ratio*100.0f);
      synchronized(frameLock){ pendingDepth=f; }
      depthFrames++; lastDepthArrivalMs=arrival;
    } else {
      synchronized(frameLock){ pendingRgb=new RawRgbFrame(payload,frameNumber,tickMs*1000L); }
      colorConnected=true; colorFrames++; lastColorArrivalMs=arrival;
    }
  }

  PImage nv12ToImage(byte[] data,int w,int h){
    if(data==null||data.length!=w*h*3/2) return null;
    PImage img=createImage(w,h,RGB); img.loadPixels(); int ySize=w*h;
    for(int y=0;y<h;y++) for(int x=0;x<w;x++){
      int yi=data[y*w+x]&0xFF; int uv=ySize+(y/2)*w+(x&~1); int u=(data[uv]&0xFF)-128, v=(data[uv+1]&0xFF)-128;
      int c=max(0,yi-16); int rr=(298*c+409*v+128)>>8, gg=(298*c-100*u-208*v+128)>>8, bb=(298*c+516*u+128)>>8;
      img.pixels[y*w+x]=color(constrain(rr,0,255),constrain(gg,0,255),constrain(bb,0,255));
    }
    img.updatePixels(); return img;
  }

  String displayError(){ return lastTransportError.length()>0 ? lastTransportError : depthWarning; }
  String safeMessage(Exception e){ String m=e.getMessage(); return(m==null||m.length()==0)?e.getClass().getSimpleName():m; }
}
