class SurveillanceVideoFrame {
  int mode,width,height,flags;
  long frameNumber,tickMs;
  byte[] payload;
}

class SurveillanceSource {
  final SurveillanceConfig cfg;
  final SurveillanceI18n i18n;
  final Object frameLock=new Object();
  final Object pipeLock=new Object();
  final byte[] headerBytes=new byte[SurveillanceProtocol.FRAME_HEADER_BYTES];
  volatile boolean running=false,portReady=false,deviceConnected=false,videoConnected=false,depthConnected=false;
  volatile int desiredMask=SurveillanceProtocol.STREAM_IR_DEPTH,currentMask=0,negotiatedMaxPayload=0;
  volatile long lastVideoMs=0,lastDepthMs=0,lastAnyMs=0,connectedSinceMs=0;
  volatile long videoFrames=0,depthFrames=0,reconnects=0;
  volatile String lastError="";
  LocalTransport activePipe;
  Thread worker;
  SurveillanceVideoFrame pendingVideo;
  long[] lastFrameNumber={-1,-1,-1};

  SurveillanceSource(SurveillanceConfig cfg,SurveillanceI18n i18n){this.cfg=cfg;this.i18n=i18n;}

  void start(int mask){desiredMask=mask;running=true;worker=new Thread(new Runnable(){public void run(){loop();}},"SynKinectSurveillance-Port");worker.setDaemon(true);worker.start();}
  void stop(){running=false;closeActivePipe();Thread t=worker;worker=null;if(t!=null){t.interrupt();try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}}reset(true);}

  void requestStreams(int mask){
    if(mask!=SurveillanceProtocol.STREAM_IR_DEPTH&&mask!=SurveillanceProtocol.STREAM_RGB_DEPTH)return;
    if(desiredMask==mask)return;desiredMask=mask;closeActivePipe();
  }

  void updateLiveness(){
    long now=millis64();
    videoConnected=lastVideoMs>0&&now-lastVideoMs<=cfg.streamStaleMs;
    depthConnected=lastDepthMs>0&&now-lastDepthMs<=cfg.streamStaleMs;
    deviceConnected=lastAnyMs>0&&now-lastAnyMs<=cfg.connectionStaleMs;
    long anchor=lastAnyMs>0?lastAnyMs:connectedSinceMs;
    if(portReady&&anchor>0&&now-anchor>cfg.connectionStaleMs){lastError=i18n.tr("transport.stale");closeActivePipe();}
  }

  SurveillanceVideoFrame pollVideo(){synchronized(frameLock){SurveillanceVideoFrame f=pendingVideo;pendingVideo=null;return f;}}
  boolean projectorActive(){return depthConnected;}
  boolean irMode(){return currentMask==SurveillanceProtocol.STREAM_IR_DEPTH;}

  void loop(){
    while(running){
      LocalTransport pipe=null;
      try{
        reset(true);int mask=desiredMask;
        pipe=LocalTransport.open(SurveillanceProtocol.PIPE_NAME,SurveillanceProtocol.SOCKET_NAME);setActivePipe(pipe);
        subscribe(pipe,mask);connectedSinceMs=millis64();lastError="";
        while(running&&mask==desiredMask)readFrame(pipe,mask);
      }catch(Exception e){if(running){lastError=i18n.format("transport.error",safeMessage(e));reconnects++;}}
      finally{clearActivePipe(pipe);closePipe(pipe);reset(false);}
      if(running)try{Thread.sleep(cfg.reconnectMs);}catch(InterruptedException e){if(!running)return;Thread.currentThread().interrupt();return;}
    }
  }

  void subscribe(LocalTransport pipe,int mask)throws IOException{
    ByteBuffer q=ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN);
    q.putInt(SurveillanceProtocol.MAGIC).putInt(SurveillanceProtocol.VERSION).putInt(SurveillanceProtocol.CMD_SUBSCRIBE_STREAMS).putInt(mask);pipe.write(q.array());
    byte[] rb=new byte[SurveillanceProtocol.REPLY_BYTES];pipe.readFully(rb);ByteBuffer r=ByteBuffer.wrap(rb).order(ByteOrder.LITTLE_ENDIAN);
    int magic=r.getInt(),version=r.getInt(),result=r.getInt(),accepted=r.getInt(),w=r.getInt(),h=r.getInt(),caps=r.getInt(),maxPayload=r.getInt();
    if(magic!=SurveillanceProtocol.MAGIC)throw new IOException("reply/magic");
    if(version!=SurveillanceProtocol.VERSION)throw new IOException("reply/version:"+version);
    if(result<0)throw new IOException("reply/result:0x"+Integer.toHexString(result));
    if(accepted!=mask)throw new IOException("reply/mask:"+accepted+"/"+mask);
    if(w!=SurveillanceProtocol.WIDTH||h!=SurveillanceProtocol.HEIGHT)throw new IOException("reply/dimensions:"+w+"x"+h);
    if((caps&SurveillanceProtocol.REQUIRED_CAPABILITIES)!=SurveillanceProtocol.REQUIRED_CAPABILITIES)throw new IOException("reply/caps:0x"+Integer.toHexString(caps));
    if(maxPayload<SurveillanceProtocol.MAX_PAYLOAD_BYTES)throw new IOException("reply/max-payload:"+maxPayload);
    negotiatedMaxPayload=maxPayload;currentMask=mask;portReady=true;
  }

  void readFrame(LocalTransport input,int sessionMask)throws IOException{
    input.readFully(headerBytes);ByteBuffer h=ByteBuffer.wrap(headerBytes).order(ByteOrder.LITTLE_ENDIAN);
    int magic=h.getInt(),version=h.getInt(),mode=h.getInt(),w=h.getInt(),hh=h.getInt(),fmt=h.getInt(),bytes=h.getInt(),flags=h.getInt();
    long frameNo=h.getLong(),tickMs=h.getLong();
    h.getInt();h.getInt();h.getInt();h.getInt();h.getInt();h.getLong(); // motion sample belongs to bridge diagnostics, not image motion detection.
    if(magic!=SurveillanceProtocol.FRAME_MAGIC)throw new IOException("frame/magic");
    if(version!=SurveillanceProtocol.VERSION)throw new IOException("frame/version:"+version);
    if(w!=SurveillanceProtocol.WIDTH||hh!=SurveillanceProtocol.HEIGHT)throw new IOException("frame/dimensions:"+w+"x"+hh);
    int modeMask=surveillanceMaskForMode(mode);if(modeMask==0||(sessionMask&modeMask)==0)throw new IOException("frame/mode:"+mode);
    if(fmt!=surveillanceExpectedFormatForMode(mode))throw new IOException("frame/format:"+mode+"/"+fmt);
    if(bytes!=surveillanceExpectedPayloadBytesForMode(mode)||bytes>negotiatedMaxPayload)throw new IOException("frame/size:"+mode+"/"+bytes);
    if((flags&~SurveillanceProtocol.KNOWN_FRAME_FLAGS)!=0)throw new IOException("frame/flags:0x"+Integer.toHexString(flags));
    if(lastFrameNumber[mode]>=0&&frameNo<=lastFrameNumber[mode])throw new IOException("frame/order:"+mode);lastFrameNumber[mode]=frameNo;
    byte[] payload=new byte[bytes];input.readFully(payload);long now=millis64();lastAnyMs=now;deviceConnected=true;lastError="";
    if(mode==SurveillanceProtocol.MODE_DEPTH){depthFrames++;lastDepthMs=now;depthConnected=true;return;}
    SurveillanceVideoFrame f=new SurveillanceVideoFrame();f.mode=mode;f.width=w;f.height=hh;f.flags=flags;f.frameNumber=frameNo;f.tickMs=tickMs;f.payload=payload;
    synchronized(frameLock){pendingVideo=f;}videoFrames++;lastVideoMs=now;videoConnected=true;
  }

  void reset(boolean clearFrame){portReady=false;deviceConnected=false;videoConnected=false;depthConnected=false;currentMask=0;connectedSinceMs=0;lastVideoMs=0;lastDepthMs=0;lastAnyMs=0;for(int i=0;i<lastFrameNumber.length;i++)lastFrameNumber[i]=-1;if(clearFrame)synchronized(frameLock){pendingVideo=null;}}
  void setActivePipe(LocalTransport p){synchronized(pipeLock){activePipe=p;}}
  void clearActivePipe(LocalTransport p){synchronized(pipeLock){if(activePipe==p)activePipe=null;}}
  void closeActivePipe(){LocalTransport p;synchronized(pipeLock){p=activePipe;activePipe=null;}closePipe(p);}
  void closePipe(LocalTransport p){if(p!=null)try{p.close();}catch(IOException ignored){}}
}

PImage nv12ToImage(byte[] data,int w,int h){
  if(data==null||data.length!=w*h*3/2)return null;PImage img=createImage(w,h,RGB);img.loadPixels();int ySize=w*h;
  for(int y=0;y<h;y++)for(int x=0;x<w;x++){int yi=data[y*w+x]&0xFF;int uv=ySize+(y/2)*w+(x&~1);int u=(data[uv]&0xFF)-128,v=(data[uv+1]&0xFF)-128;int c=max(0,yi-16);int rr=(298*c+409*v+128)>>8,gg=(298*c-100*u-208*v+128)>>8,bb=(298*c+516*u+128)>>8;img.pixels[y*w+x]=0xFF000000|(constrain(rr,0,255)<<16)|(constrain(gg,0,255)<<8)|constrain(bb,0,255);}
  img.updatePixels();return img;
}

PImage ir16ToImage(byte[] data,int w,int h){
  if(data==null||data.length!=w*h*2)return null;PImage img=createImage(w,h,RGB);img.loadPixels();ByteBuffer b=ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN);
  int lo=1023,hi=0;int step=8;for(int y=0;y<h;y+=step)for(int x=0;x<w;x+=step){int v=b.getShort((y*w+x)*2)&0xFFFF;if(v>0){lo=min(lo,v);hi=max(hi,v);}}
  if(hi<=lo){lo=0;hi=1023;}for(int i=0;i<w*h;i++){int v=b.getShort(i*2)&0xFFFF;int g=constrain((v-lo)*255/max(1,hi-lo),0,255);img.pixels[i]=0xFF000000|(g<<16)|(g<<8)|g;}img.updatePixels();return img;
}
