class MicrophoneSource {
  final MicrophoneConfig cfg;
  final AudioPipeline pipeline;
  final Object lock=new Object();
  volatile boolean running=false,connected=false;
  volatile long frameCount=0,payloadBytesReceived=0,connectedSinceMs=0,lastFrameArrivalMs=0,connectionEpoch=0,reconnectKicks=0,lastReconnectKickMs=0;
  volatile String stateKey="source.starting",detail="",connectedPipe="";
  volatile LocalTransport activePipe;
  final Object pipeLock=new Object();
  Thread worker;MicrophoneFrame latest;

  MicrophoneSource(MicrophoneConfig cfg,AudioPipeline pipeline){this.cfg=cfg;this.pipeline=pipeline;}

  void start(){if(running)return;running=true;worker=new Thread(new Runnable(){public void run(){loop();}},"SynKinectMicrophones-Port");worker.setDaemon(true);worker.start();}
  void stop(){
    running=false;closeActivePipe();Thread t=worker;worker=null;
    if(t!=null){t.interrupt();try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}}
    synchronized(pipeLock){activePipe=null;}connected=false;
  }
  MicrophoneFrame snapshot(){synchronized(lock){return latest;}}
  String displayStateKey(){
    if(!connected)return stateKey;
    long now=System.currentTimeMillis();
    long anchor=lastFrameArrivalMs>0?lastFrameArrivalMs:connectedSinceMs;
    if(anchor>0&&now-anchor>cfg.connectionStaleMs){requestReconnect("stale-session");return "source.reconnecting";}
    if(anchor>0&&now-anchor>cfg.noFrameWarningMs)return lastFrameArrivalMs>0?"source.stale":"source.no_frames";
    return stateKey;
  }

  void setActivePipe(LocalTransport pipe){synchronized(pipeLock){activePipe=pipe;}}
  void clearActivePipe(LocalTransport pipe){synchronized(pipeLock){if(activePipe==pipe)activePipe=null;}}
  void closeActivePipe(){LocalTransport pipe;synchronized(pipeLock){pipe=activePipe;activePipe=null;}closePipe(pipe);}
  void requestReconnect(String reason){
    if(!running)return;long now=System.currentTimeMillis();if(now-lastReconnectKickMs<Math.max(100,cfg.reconnectMs))return;
    lastReconnectKickMs=now;reconnectKicks++;stateKey="source.reconnecting";detail=reason;closeActivePipe();
  }

  void loop(){
    while(running){
      LocalTransport pipe=null;
      try{
        connected=false;stateKey="source.connecting";detail="";lastFrameArrivalMs=0;
        pipe=openBestPipe();setActivePipe(pipe);subscribe(pipe);
        connected=true;connectedSinceMs=System.currentTimeMillis();connectionEpoch++;stateKey="source.streaming";
        long lastFrame=-1;byte[] headerBytes=new byte[MicrophoneProtocol.HEADER_BYTES];byte[] payload=new byte[MicrophoneProtocol.PAYLOAD_BYTES];
        while(running){
          pipe.readFully(headerBytes);ByteBuffer h=ByteBuffer.wrap(headerBytes).order(ByteOrder.LITTLE_ENDIAN);
          int magic=h.getInt(),version=h.getInt(),sampleRate=h.getInt(),channels=h.getInt(),sampleFormat=h.getInt(),samplesPerChannel=h.getInt(),payloadBytes=h.getInt(),channelMask=h.getInt();
          long frameNumber=h.getLong(),tickMs=h.getLong();
          validateFrameHeader(magic,version,sampleRate,channels,sampleFormat,samplesPerChannel,payloadBytes,channelMask,frameNumber,lastFrame);lastFrame=frameNumber;
          pipe.readFully(payload);payloadBytesReceived+=payload.length;
          MicrophoneFrame frame=decodeFrame(payload,frameNumber,tickMs,channelMask);
          synchronized(lock){latest=frame;}frameCount++;lastFrameArrivalMs=System.currentTimeMillis();pipeline.accept(frame);
        }
      }catch(IOException e){connected=false;if(running){stateKey="source.reconnecting";detail=safeMessage(e);}}
      finally{clearActivePipe(pipe);closePipe(pipe);}
      if(running)try{Thread.sleep(cfg.reconnectMs);}catch(InterruptedException e){if(!running)return;Thread.currentThread().interrupt();return;}
    }
  }

  void validateFrameHeader(int magic,int version,int rate,int channels,int format,int samples,int payloadBytes,int mask,long frameNumber,long lastFrame)throws IOException{
    if(magic!=MicrophoneProtocol.FRAME_MAGIC||version!=MicrophoneProtocol.VERSION)throw new IOException("protocol-frame");
    if(rate!=MicrophoneProtocol.SAMPLE_RATE||channels!=MicrophoneProtocol.CHANNELS||format!=MicrophoneProtocol.SAMPLE_FORMAT_S32LE||samples!=MicrophoneProtocol.SAMPLES||payloadBytes!=MicrophoneProtocol.PAYLOAD_BYTES)throw new IOException("protocol-format");
    if((mask&~MicrophoneProtocol.VALID_CHANNEL_MASK)!=0||mask==0)throw new IOException("protocol-channel-mask");
    if(lastFrame>=0&&frameNumber<=lastFrame)throw new IOException("protocol-frame-order");
  }

  MicrophoneFrame decodeFrame(byte[] payload,long frameNumber,long tickMs,int channelMask){
    ByteBuffer pcm=ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN);MicrophoneFrame frame=new MicrophoneFrame();frame.frameNumber=frameNumber;frame.tickMs=tickMs;frame.channelMask=channelMask;
    for(int sample=0;sample<MicrophoneProtocol.SAMPLES;sample++)for(int mic=0;mic<MicrophoneProtocol.CHANNELS;mic++)frame.samples[mic][sample]=pcm.getInt();
    for(int mic=0;mic<MicrophoneProtocol.CHANNELS;mic++){
      long peak=0;for(int sample=0;sample<MicrophoneProtocol.SAMPLES;sample++){long value=frame.samples[mic][sample];long magnitude=value==Integer.MIN_VALUE?2147483648L:Math.abs(value);if(magnitude>peak)peak=magnitude;}
      frame.peak[mic]=peak/2147483648.0f;
    }
    return frame;
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
    throw last==null?new IOException("audio pipe unavailable"):last;
  }

  LocalTransport openBestPipe()throws IOException{
    IOException primaryError=null;
    try{LocalTransport pipe=openPipeWithRetry(MicrophoneProtocol.PIPE,MicrophoneProtocol.SOCKET);connectedPipe=MicrophoneProtocol.PIPE;return pipe;}
    catch(IOException e){primaryError=e;}
    if(cfg.allowAcousticPipeFallback){
      try{LocalTransport pipe=openPipeWithRetry(MicrophoneProtocol.FALLBACK_PIPE,MicrophoneProtocol.FALLBACK_SOCKET);connectedPipe=MicrophoneProtocol.FALLBACK_PIPE;detail="fallback-acoustic-pipe";return pipe;}
      catch(IOException fallback){throw new IOException("audio pipes unavailable: "+safeMessage(primaryError)+" / "+safeMessage(fallback));}
    }
    throw primaryError==null?new IOException("audio pipe unavailable"):primaryError;
  }

  String pipeModeKey(){return MicrophoneProtocol.FALLBACK_PIPE.equals(connectedPipe)?"source.pipe_fallback":"source.pipe_primary";}

  void subscribe(LocalTransport pipe)throws IOException{
    ByteBuffer request=ByteBuffer.allocate(MicrophoneProtocol.REQUEST_BYTES).order(ByteOrder.LITTLE_ENDIAN);
    request.putInt(MicrophoneProtocol.MAGIC);request.putInt(MicrophoneProtocol.VERSION);request.putInt(MicrophoneProtocol.CMD_SUBSCRIBE);request.putInt(0);pipe.write(request.array());
    byte[] bytes=new byte[MicrophoneProtocol.REPLY_BYTES];pipe.readFully(bytes);ByteBuffer r=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
    int magic=r.getInt(),version=r.getInt(),result=r.getInt(),rate=r.getInt(),channels=r.getInt(),format=r.getInt(),maxPayload=r.getInt(),capabilities=r.getInt();
    if(magic!=MicrophoneProtocol.MAGIC||version!=MicrophoneProtocol.VERSION||result<0)throw new IOException("protocol-subscribe");
    if(rate!=MicrophoneProtocol.SAMPLE_RATE||channels!=MicrophoneProtocol.CHANNELS||format!=MicrophoneProtocol.SAMPLE_FORMAT_S32LE||maxPayload<MicrophoneProtocol.PAYLOAD_BYTES)throw new IOException("protocol-bridge-format");
    if((capabilities&MicrophoneProtocol.REQUIRED_CAPABILITIES)!=MicrophoneProtocol.REQUIRED_CAPABILITIES)throw new IOException("protocol-capabilities");
  }

  void closePipe(LocalTransport pipe){if(pipe==null)return;try{pipe.close();}catch(IOException e){if(running)detail=safeMessage(e);}}
  String safeMessage(Exception e){String m=e.getMessage();return m==null||m.length()==0?e.getClass().getSimpleName():m;}
}
