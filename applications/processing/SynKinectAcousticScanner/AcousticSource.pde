class AcousticSource {
  final AcousticConfig cfg;
  final Object frameLock=new Object(),pipeLock=new Object();
  volatile boolean running=false,connected=false;
  volatile String stateKey="source.starting",detail="";
  volatile long frameCount=0,connectedSinceMs=0,lastFrameArrivalMs=0,connectionEpoch=0,reconnectKicks=0,lastReconnectKickMs=0;
  volatile String connectedPipe="";
  volatile LocalTransport activePipe;
  Thread worker;AcousticAudioFrame latest;

  AcousticSource(AcousticConfig cfg){this.cfg=cfg;}
  void start(){if(running)return;running=true;worker=new Thread(new Runnable(){public void run(){loop();}},"SynKinectAcousticScanner-Port");worker.setDaemon(true);worker.start();}
  void stop(){running=false;closeActivePipe();Thread t=worker;worker=null;if(t!=null){t.interrupt();try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}}connected=false;}
  AcousticAudioFrame snapshot(){synchronized(frameLock){return latest;}}
  String displayStateKey(){
    if(!connected)return stateKey;long now=System.currentTimeMillis();long anchor=lastFrameArrivalMs>0?lastFrameArrivalMs:connectedSinceMs;
    if(anchor>0&&now-anchor>cfg.connectionStaleMs){requestReconnect("stale-session");return "source.reconnecting";}
    if(anchor>0&&now-anchor>cfg.noFrameWarningMs)return lastFrameArrivalMs>0?"source.stale":"source.no_frames";
    return stateKey;
  }
  void requestReconnect(String why){if(!running)return;long now=System.currentTimeMillis();if(now-lastReconnectKickMs<Math.max(100,cfg.reconnectMs))return;lastReconnectKickMs=now;reconnectKicks++;stateKey="source.reconnecting";detail=why;closeActivePipe();}
  void setActivePipe(LocalTransport p){synchronized(pipeLock){activePipe=p;}}
  void clearActivePipe(LocalTransport p){synchronized(pipeLock){if(activePipe==p)activePipe=null;}}
  void closeActivePipe(){LocalTransport p;synchronized(pipeLock){p=activePipe;activePipe=null;}closePipe(p);}
  void closePipe(LocalTransport p){if(p==null)return;try{p.close();}catch(IOException e){if(running)detail=safeMessage(e);}}

  void loop(){
    while(running){LocalTransport pipe=null;
      try{
        connected=false;stateKey="source.connecting";detail="";lastFrameArrivalMs=0;
        pipe=openBestPipe();setActivePipe(pipe);subscribe(pipe);
        connected=true;connectedSinceMs=System.currentTimeMillis();connectionEpoch++;stateKey="source.streaming";
        long last=-1;byte[] hb=new byte[AcousticProtocol.HEADER_BYTES],payload=new byte[AcousticProtocol.PAYLOAD_BYTES];
        while(running){
          pipe.readFully(hb);ByteBuffer h=ByteBuffer.wrap(hb).order(ByteOrder.LITTLE_ENDIAN);
          int magic=h.getInt(),version=h.getInt(),rate=h.getInt(),channels=h.getInt(),format=h.getInt(),samples=h.getInt(),bytes=h.getInt(),mask=h.getInt();long number=h.getLong(),tick=h.getLong();
          if(magic!=AcousticProtocol.FRAME_MAGIC||version!=AcousticProtocol.VERSION||rate!=AcousticProtocol.SAMPLE_RATE||channels!=AcousticProtocol.CHANNELS||format!=AcousticProtocol.SAMPLE_FORMAT_S32LE||samples!=AcousticProtocol.SAMPLES||bytes!=AcousticProtocol.PAYLOAD_BYTES)throw new IOException("protocol-frame");
          if(mask==0||(mask&~AcousticProtocol.VALID_CHANNEL_MASK)!=0)throw new IOException("protocol-channel-mask");
          if(last>=0&&number<=last)throw new IOException("protocol-order");last=number;
          pipe.readFully(payload);AcousticAudioFrame frame=decode(payload,number,tick,mask);synchronized(frameLock){latest=frame;}frameCount++;lastFrameArrivalMs=System.currentTimeMillis();
        }
      }catch(IOException e){connected=false;if(running){stateKey="source.reconnecting";detail=safeMessage(e);}}
      finally{clearActivePipe(pipe);closePipe(pipe);}
      if(running)try{Thread.sleep(cfg.reconnectMs);}catch(InterruptedException e){if(!running)return;Thread.currentThread().interrupt();return;}
    }
  }

  LocalTransport openPipeWithRetry(String pipeName,String socketName)throws IOException{
    IOException last=null;
    for(int attempt=1;attempt<=cfg.pipeOpenAttempts&&running;attempt++){
      try{return LocalTransport.open(pipeName,socketName);}
      catch(IOException e){
        last=e;
        if(attempt<cfg.pipeOpenAttempts){
          try{Thread.sleep(cfg.pipeOpenRetryMs);}
          catch(InterruptedException interrupted){Thread.currentThread().interrupt();throw new IOException("pipe-open interrupted",interrupted);}
        }
      }
    }
    throw last==null?new IOException("acoustic pipe unavailable"):last;
  }

  LocalTransport openBestPipe()throws IOException{
    IOException dedicatedError=null;
    try{LocalTransport pipe=openPipeWithRetry(AcousticProtocol.PIPE,AcousticProtocol.SOCKET);connectedPipe=AcousticProtocol.PIPE;return pipe;}
    catch(IOException e){dedicatedError=e;}
    if(cfg.allowMonitorPipeFallback){
      try{LocalTransport pipe=openPipeWithRetry(AcousticProtocol.FALLBACK_PIPE,AcousticProtocol.FALLBACK_SOCKET);connectedPipe=AcousticProtocol.FALLBACK_PIPE;detail="fallback-monitor-pipe";return pipe;}
      catch(IOException fallback){throw new IOException("acoustic pipe unavailable; fallback unavailable: "+safeMessage(fallback),dedicatedError);}
    }
    throw dedicatedError==null?new IOException("acoustic pipe unavailable"):dedicatedError;
  }
  void subscribe(LocalTransport pipe)throws IOException{
    ByteBuffer q=ByteBuffer.allocate(AcousticProtocol.REQUEST_BYTES).order(ByteOrder.LITTLE_ENDIAN);q.putInt(AcousticProtocol.MAGIC);q.putInt(AcousticProtocol.VERSION);q.putInt(AcousticProtocol.CMD_SUBSCRIBE);q.putInt(0);pipe.write(q.array());
    byte[] rb=new byte[AcousticProtocol.REPLY_BYTES];pipe.readFully(rb);ByteBuffer r=ByteBuffer.wrap(rb).order(ByteOrder.LITTLE_ENDIAN);int magic=r.getInt(),version=r.getInt(),result=r.getInt(),rate=r.getInt(),channels=r.getInt(),format=r.getInt(),maxPayload=r.getInt(),caps=r.getInt();
    if(magic!=AcousticProtocol.MAGIC||version!=AcousticProtocol.VERSION||result<0||rate!=AcousticProtocol.SAMPLE_RATE||channels!=AcousticProtocol.CHANNELS||format!=AcousticProtocol.SAMPLE_FORMAT_S32LE||maxPayload<AcousticProtocol.PAYLOAD_BYTES||(caps&AcousticProtocol.REQUIRED_CAPABILITIES)!=AcousticProtocol.REQUIRED_CAPABILITIES)throw new IOException("protocol-subscribe");
  }
  AcousticAudioFrame decode(byte[] payload,long number,long tick,int mask){
    AcousticAudioFrame f=new AcousticAudioFrame();f.frameNumber=number;f.tickMs=tick;f.channelMask=mask;ByteBuffer b=ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN);
    for(int n=0;n<AcousticProtocol.SAMPLES;n++)for(int ch=0;ch<AcousticProtocol.CHANNELS;ch++)f.samples[ch][n]=b.getInt();
    for(int ch=0;ch<AcousticProtocol.CHANNELS;ch++){long peak=0;for(int n=0;n<AcousticProtocol.SAMPLES;n++){long v=f.samples[ch][n];long a=v==Integer.MIN_VALUE?2147483648L:Math.abs(v);if(a>peak)peak=a;}f.peak[ch]=peak/2147483648.0f;}
    return f;
  }
  String pipeModeKey(){return AcousticProtocol.FALLBACK_PIPE.equals(connectedPipe)?"source.pipe_fallback":"source.pipe_dedicated";}
  String safeMessage(Exception e){String m=e.getMessage();return m==null||m.length()==0?e.getClass().getSimpleName():m;}
}
