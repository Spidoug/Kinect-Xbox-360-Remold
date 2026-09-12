// ===== SynKinect Studio / Microphones / Module.pde =====
class MicrophoneModuleState {
  MicrophoneConfig config;
  AcousticConfig spatialConfig;
  MicrophoneI18n i18n;
  AudioPipeline pipeline;
  MicrophoneSource source;
  BridgeDiagnostics diagnostics;
  MicrophoneUI ui;
}

void setupMicrophoneModule(){
  studio.microphoneState.config=new MicrophoneConfig();studio.microphoneState.config.load(new File(dataPath("microphones.properties")));
  studio.microphoneState.spatialConfig=new AcousticConfig();studio.microphoneState.spatialConfig.load(new File(dataPath("acoustic.properties")));
  studio.microphoneState.i18n=new MicrophoneI18n(studio.currentLanguage());
  initializeMicrophoneTypography();
  studio.microphoneState.pipeline=new AudioPipeline(studio.microphoneState.config,studio.microphoneState.spatialConfig);studio.microphoneState.diagnostics=new BridgeDiagnostics(studio.microphoneState.config);studio.microphoneState.source=new MicrophoneSource(studio.microphoneState.config,studio.microphoneState.pipeline);studio.microphoneState.ui=new MicrophoneUI();
}

void drawMicrophoneModule(){background(studio.services.microphoneTheme.BG);studio.microphoneState.diagnostics.refresh();studio.microphoneState.ui.draw(studio.microphoneState.source==null?null:studio.microphoneState.source.snapshot());}

void microphoneMousePressed(){if(studio.microphoneState.ui!=null)studio.microphoneState.ui.handleMousePressed(studio.contentMouseX(),studio.contentMouseY());}
void microphoneKeyPressed(){
  if(key=='r'||key=='R')toggleRecording();
  else if(key=='m'||key=='M')toggleMonitor();
  else if(key=='p'||key=='P')togglePlayback();
  else if(key=='t'||key=='T')toggleSpeakerTest();
  else if(keyCode==LEFT)studio.microphoneState.pipeline.monitor.steerManual(studio.microphoneState.pipeline.monitor.manualAzimuthDeg-5);
  else if(keyCode==RIGHT)studio.microphoneState.pipeline.monitor.steerManual(studio.microphoneState.pipeline.monitor.manualAzimuthDeg+5);
}

void dispatchMicrophoneAction(int action){
  if(action==studio.microphoneState.ui.ACTION_RECORD)toggleRecording();
  else if(action==studio.microphoneState.ui.ACTION_MONITOR)toggleMonitor();
  else if(action==studio.microphoneState.ui.ACTION_PLAY)togglePlayback();
  else if(action==studio.microphoneState.ui.ACTION_TEST)toggleSpeakerTest();
  else if(action==studio.microphoneState.ui.ACTION_AUTO)studio.microphoneState.pipeline.monitor.setAutomatic(true);
  else if(action==studio.microphoneState.ui.ACTION_MANUAL)studio.microphoneState.pipeline.monitor.setAutomatic(false);
}

void toggleRecording(){
  if(studio.microphoneState.pipeline.recorder.isRecording()){studio.microphoneState.pipeline.recorder.stop();return;}
  File directory=new File(sketchPath(studio.microphoneState.config.recordingsDirectory));
  if(!directory.exists()&&!directory.mkdirs()){studio.microphoneState.pipeline.recorder.setError("mkdir");return;}
  String stamp=new SimpleDateFormat("yyyyMMdd-HHmmss",Locale.ROOT).format(new Date());
  studio.microphoneState.pipeline.recorder.start(new File(directory,studio.microphoneState.config.recordingPrefix+"-"+stamp+"-4ch-s32.wav"));
}

void toggleMonitor(){
  if(studio.microphoneState.pipeline.monitor.isRunning())studio.microphoneState.pipeline.monitor.requestStop();
  else{studio.microphoneState.pipeline.player.requestStop();studio.microphoneState.pipeline.selfTest.requestStop();studio.microphoneState.pipeline.monitor.start();}
}

void togglePlayback(){
  if(studio.microphoneState.pipeline.player.isRunning()){studio.microphoneState.pipeline.player.requestStop();return;}
  File last=studio.microphoneState.pipeline.recorder.lastFile();
  if(last==null||!last.isFile()||last.length()<=44){studio.microphoneState.pipeline.player.noFile();return;}
  studio.microphoneState.pipeline.monitor.requestStop();studio.microphoneState.pipeline.selfTest.requestStop();studio.microphoneState.pipeline.player.start(last);
}

void toggleSpeakerTest(){
  if(studio.microphoneState.pipeline.selfTest.isRunning())studio.microphoneState.pipeline.selfTest.requestStop();
  else{studio.microphoneState.pipeline.monitor.requestStop();studio.microphoneState.pipeline.player.requestStop();studio.microphoneState.pipeline.selfTest.start();}
}

void disposeMicrophoneModule(){if(studio.microphoneState.source!=null)studio.microphoneState.source.stop();if(studio.microphoneState.pipeline!=null)studio.microphoneState.pipeline.stop();}


// ===== SynKinect Studio / Microphones / AudioPipeline.pde =====
class AudioPipeline {
 final WavRecorder recorder;
 final LiveMonitor monitor;
 final RecordedWavPlayer player;
 final SpeakerSelfTest selfTest;

  AudioPipeline(MicrophoneConfig cfg,AcousticConfig spatialCfg){
    recorder=new WavRecorder();
    monitor=new LiveMonitor(cfg,spatialCfg);
    player=new RecordedWavPlayer(cfg);
    selfTest=new SpeakerSelfTest(cfg);
  }

  void accept(MicrophoneFrame frame){recorder.accept(frame);monitor.accept(frame);}
  void stop(){recorder.stop();monitor.stop();player.stop();selfTest.stop();}
}

class WavRecorder {
 final int blockAlign=studio.services.microphoneProtocol.CHANNELS*studio.services.microphoneProtocol.BYTES_PER_SAMPLE;
 final int byteRate=studio.services.microphoneProtocol.SAMPLE_RATE*blockAlign;
  RandomAccessFile output;
  long dataBytes=0,lastDataBytes=0,dataSizeOffset=0;
  String currentPath="";
  String stateKey="record.idle";
  String detail="";

  synchronized boolean isRecording(){return output!=null;}
  synchronized String state(){return stateKey;}
  synchronized String detail(){return detail;}
  synchronized long bytes(){return output!=null?dataBytes:lastDataBytes;}
  synchronized File lastFile(){return currentPath.length()==0?null:new File(currentPath);}

  synchronized void start(File path){
    stop(); detail=""; stateKey="record.idle";
    if(path==null){setError("null-path");return;}
    try{
      output=new RandomAccessFile(path,"rw"); output.setLength(0); currentPath=path.getAbsolutePath(); lastDataBytes=0;
      writeHeader(output); stateKey="record.active";
    }catch(IOException e){closeWithoutHeader();setError(safeMessage(e));}
  }

  synchronized void accept(MicrophoneFrame frame){
    if(output==null||frame==null)return;
    try{
      ByteBuffer data=ByteBuffer.allocate(studio.services.microphoneProtocol.PAYLOAD_BYTES).order(ByteOrder.LITTLE_ENDIAN);
      for(int sample=0;sample<studio.services.microphoneProtocol.SAMPLES;sample++)
        for(int mic=0;mic<studio.services.microphoneProtocol.CHANNELS;mic++)
          data.putInt(frame.channelValid(mic)?frame.samples[mic][sample]:0);
      output.write(data.array()); dataBytes+=data.capacity();
    }catch(IOException e){closeWithoutHeader();setError(safeMessage(e));}
  }

  synchronized void stop(){
    if(output==null)return;
    RandomAccessFile file=output; output=null; String closeError="";
    try{
      lastDataBytes=dataBytes; long fileBytes=44L+dataBytes;
      file.seek(4); writeLE32(file,fileBytes-8L); file.seek(dataSizeOffset); writeLE32(file,dataBytes);
      file.getFD().sync();
    }catch(IOException e){closeError=safeMessage(e);}
    finally{try{file.close();}catch(IOException e){if(closeError.length()==0)closeError=safeMessage(e);}dataBytes=0;dataSizeOffset=0;}
    if(closeError.length()>0)setError(closeError); else stateKey=lastDataBytes>0?"record.saved":"record.empty";
  }

  synchronized void setError(String message){stateKey="record.error";detail=message==null?"unknown":message;}

  void writeHeader(RandomAccessFile file)throws IOException{
    file.writeBytes("RIFF");writeLE32(file,0);file.writeBytes("WAVE");file.writeBytes("fmt ");writeLE32(file,16);
    writeLE16(file,1);writeLE16(file,studio.services.microphoneProtocol.CHANNELS);writeLE32(file,studio.services.microphoneProtocol.SAMPLE_RATE);writeLE32(file,byteRate);
    writeLE16(file,blockAlign);writeLE16(file,studio.services.microphoneProtocol.BYTES_PER_SAMPLE*8);file.writeBytes("data");dataSizeOffset=file.getFilePointer();writeLE32(file,0);dataBytes=0;
  }

  void closeWithoutHeader(){
    RandomAccessFile file=output;output=null;if(file!=null)try{file.close();}catch(IOException ignored){}dataBytes=0;dataSizeOffset=0;
  }
  void writeLE16(RandomAccessFile file,long value)throws IOException{file.write((int)(value&0xff));file.write((int)((value>>>8)&0xff));}
  void writeLE32(RandomAccessFile file,long value)throws IOException{file.write((int)(value&0xff));file.write((int)((value>>>8)&0xff));file.write((int)((value>>>16)&0xff));file.write((int)((value>>>24)&0xff));}
  String safeMessage(Exception e){String m=e.getMessage();return m==null||m.length()==0?e.getClass().getSimpleName():m;}
}

class LiveMonitor {
 final MicrophoneConfig cfg;
 final AcousticConfig spatialCfg;
 final AcousticEngine spatialEngine;
 final AcousticAutoSteerer autoSteerer;
 final Object lock=new Object();
 final ArrayDeque<byte[]> queue=new ArrayDeque<byte[]>();
  volatile boolean running=false;
  volatile long runGeneration=0;
  volatile String stateKey="monitor.idle";
  volatile String detail="";
  volatile boolean automaticBeam=true;
  volatile float manualAzimuthDeg=0;
  volatile float beamAzimuthDeg=0;
  volatile AcousticScanFrame latestScan=null;
  Thread worker; SourceDataLine line;

  LiveMonitor(MicrophoneConfig cfg,AcousticConfig spatialCfg){
    this.cfg=cfg;this.spatialCfg=spatialCfg;this.spatialEngine=new AcousticEngine(spatialCfg);this.autoSteerer=new AcousticAutoSteerer(spatialCfg);
  }
  boolean isRunning(){return running;}
  String state(){return stateKey;}
  String detail(){return detail;}
  void setAutomatic(boolean value){automaticBeam=value;if(value)autoSteerer.reset();}
  void steerManual(float degrees){automaticBeam=false;manualAzimuthDeg=constrain(degrees,-90,90);beamAzimuthDeg=manualAzimuthDeg;}

  void start(){
    synchronized(lock){if(running)return;running=true;stateKey="monitor.starting";detail="";queue.clear();final long generation=++runGeneration;worker=studio.services.workers.start("Microphones-SpatialMonitor",new Runnable(){public void run(){playbackLoop(generation);}});}
  }

  void requestStop(){Thread t;synchronized(lock){running=false;++runGeneration;queue.clear();lock.notifyAll();t=worker;worker=null;}closeLine();if(t!=null&&t!=Thread.currentThread())t.interrupt();if(!"monitor.error".equals(stateKey))stateKey="monitor.idle";}
  void stop(){
    Thread t;synchronized(lock){running=false;++runGeneration;queue.clear();lock.notifyAll();t=worker;worker=null;}
    closeLine();
    if(t!=null&&t!=Thread.currentThread())try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}
    if(!"monitor.error".equals(stateKey))stateKey="monitor.idle";
  }

  void accept(MicrophoneFrame frame){
    if(frame==null)return;

    // Microphones and Acoustic Scanner intentionally instantiate the same
    // GCC-PHAT/TDOA + delay-and-sum pipeline over independent raw-bus clients.
    AcousticScanFrame scan=spatialEngine.process(frame);latestScan=scan;
    float target=manualAzimuthDeg;
    if(automaticBeam)target=autoSteerer.update(scan,beamAzimuthDeg,System.currentTimeMillis());
    beamAzimuthDeg=constrain(target,-90,90);

    if(!running)return;
    short[] beam=spatialEngine.beamform(frame,beamAzimuthDeg);
    ByteBuffer pcm=ByteBuffer.allocate(beam.length*2).order(ByteOrder.LITTLE_ENDIAN);
    for(short v:beam)pcm.putShort(v);
    synchronized(lock){
      if(!running)return;
      while(queue.size()>=cfg.monitorQueueFrames)queue.removeFirst();
      queue.addLast(pcm.array());lock.notifyAll();
    }
  }

  void playbackLoop(long generation){
    SourceDataLine local=null;
    try{
      AudioFormat format=new AudioFormat((float)studio.services.microphoneProtocol.SAMPLE_RATE,16,1,true,false);
      local=(SourceDataLine)AudioSystem.getLine(new DataLine.Info(SourceDataLine.class,format));
      local.open(format,cfg.monitorLineBufferBytes);local.start();
      synchronized(lock){if(generation==runGeneration)line=local;}
      if(generation==runGeneration)stateKey="monitor.live";
      while(running&&generation==runGeneration){
        byte[] block=null;
        synchronized(lock){
          while(running&&generation==runGeneration&&queue.isEmpty())try{lock.wait(250);}catch(InterruptedException e){if(!running||generation!=runGeneration)return;Thread.currentThread().interrupt();return;}
          if(!queue.isEmpty())block=queue.removeFirst();
        }
        if(block!=null)local.write(block,0,block.length);
      }
    }catch(Exception e){if(generation==runGeneration){detail=safeMessage(e);stateKey="monitor.error";running=false;}}
    finally{closeLine(local);synchronized(lock){if(generation==runGeneration)queue.clear();}}
  }

  void closeLine(){SourceDataLine current;synchronized(lock){current=line;line=null;}closeLine(current);}
  void closeLine(SourceDataLine current){if(current==null)return;synchronized(lock){if(line==current)line=null;}try{if(current.isRunning())current.stop();}catch(Exception ignored){}try{current.flush();}catch(Exception ignored){}try{current.close();}catch(Exception ignored){}}
  String safeMessage(Exception e){String v=e.getMessage();return v==null||v.length()==0?e.getClass().getSimpleName():v;}
}

class RecordedWavPlayer {
 final MicrophoneConfig cfg;
  volatile boolean running=false;
  volatile long runGeneration=0;
  volatile String stateKey="playback.idle";
  volatile String detail="";
  volatile String fileName="";
  Thread worker; SourceDataLine line;

  RecordedWavPlayer(MicrophoneConfig cfg){this.cfg=cfg;}
  boolean isRunning(){return running;}
  String state(){return stateKey;}
  String detail(){return detail;}

  void noFile(){stateKey="playback.no_file";detail="";}
  void start(final File file){
    requestStop();if(file==null||!file.isFile()){noFile();return;}running=true;stateKey="playback.starting";detail="";fileName=file.getName();final long generation=++runGeneration;
    worker=studio.services.workers.start("Microphones-WavPlayback",new Runnable(){public void run(){playback(file,generation);}});
  }
  void requestStop(){running=false;++runGeneration;closeLine();Thread t=worker;worker=null;if(t!=null&&t!=Thread.currentThread())t.interrupt();if(!"playback.error".equals(stateKey)&&!"playback.no_file".equals(stateKey))stateKey="playback.idle";}
  void stop(){
    running=false;++runGeneration;closeLine();Thread t=worker;worker=null;if(t!=null&&t!=Thread.currentThread()){t.interrupt();try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}}
    if(!"playback.error".equals(stateKey)&&!"playback.no_file".equals(stateKey))stateKey="playback.idle";
  }

  void playback(File file,long generation){
    RandomAccessFile input=null;SourceDataLine local=null;
    try{
      input=new RandomAccessFile(file,"r");WavDataRegion region=findDataRegion(input);input.seek(region.offset);
      AudioFormat format=new AudioFormat((float)studio.services.microphoneProtocol.SAMPLE_RATE,16,1,true,false);
      local=(SourceDataLine)AudioSystem.getLine(new DataLine.Info(SourceDataLine.class,format));local.open(format,cfg.playbackLineBufferBytes);local.start();
      if(generation!=runGeneration){closeLine(local);return;}line=local;stateKey="playback.live";
      byte[] raw=new byte[studio.services.microphoneProtocol.PAYLOAD_BYTES];long remaining=region.bytes;
      while(running&&generation==runGeneration&&remaining>0){
        int wanted=(int)Math.min(raw.length,remaining);int n=input.read(raw,0,wanted);if(n<0)break;remaining-=n;
        int frameBytes=studio.services.microphoneProtocol.CHANNELS*studio.services.microphoneProtocol.BYTES_PER_SAMPLE;int frames=n/frameBytes;if(frames<=0)continue;
        ByteBuffer src=ByteBuffer.wrap(raw,0,frames*frameBytes).order(ByteOrder.LITTLE_ENDIAN);
        int[][] channel=new int[studio.services.microphoneProtocol.CHANNELS][frames];long[] peaks=new long[studio.services.microphoneProtocol.CHANNELS];
        for(int i=0;i<frames;i++)for(int ch=0;ch<studio.services.microphoneProtocol.CHANNELS;ch++){int v=src.getInt();channel[ch][i]=v;long mag=v==Integer.MIN_VALUE?2147483648L:Math.abs((long)v);if(mag>peaks[ch])peaks[ch]=mag;}
        int selected=0;for(int ch=1;ch<studio.services.microphoneProtocol.CHANNELS;ch++)if(peaks[ch]>peaks[selected])selected=ch;
        float gain=constrain((cfg.monitorTargetPeak*2147483647.0f)/Math.max(1L,peaks[selected]),1.0f,cfg.monitorMaxGain);
        ByteBuffer out=ByteBuffer.allocate(frames*2).order(ByteOrder.LITTLE_ENDIAN);
        for(int v:channel[selected]){long amp=(long)(v*gain);amp=Math.max(Integer.MIN_VALUE,Math.min(Integer.MAX_VALUE,amp));out.putShort((short)constrain((int)(amp>>16),-32768,32767));}
        local.write(out.array(),0,out.position());
      }
      if(running&&generation==runGeneration)stateKey="playback.finished";
    }catch(Exception e){if(generation==runGeneration){stateKey="playback.error";detail=safeMessage(e);}}
    finally{if(generation==runGeneration)running=false;if(input!=null)try{input.close();}catch(IOException ignored){}closeLine(local);}
  }

  WavDataRegion findDataRegion(RandomAccessFile file)throws IOException{
    if(file.length()<12)throw new IOException("wav-header");
    byte[] head=new byte[12];file.readFully(head);
    if(head[0]!='R'||head[1]!='I'||head[2]!='F'||head[3]!='F'||head[8]!='W'||head[9]!='A'||head[10]!='V'||head[11]!='E')throw new IOException("wav-signature");
    boolean formatOk=false;long dataOffset=-1,dataBytes=0;
    while(file.getFilePointer()+8<=file.length()){
      byte[] id=new byte[4];file.readFully(id);long size=readLE32(file);long next=file.getFilePointer()+size+(size&1L);
      String chunk=new String(id,"US-ASCII");
      if("fmt ".equals(chunk)){
        if(size<16)throw new IOException("wav-fmt");byte[] fmt=new byte[16];file.readFully(fmt);ByteBuffer b=ByteBuffer.wrap(fmt).order(ByteOrder.LITTLE_ENDIAN);
        int tag=b.getShort()&0xffff,channels=b.getShort()&0xffff,rate=b.getInt();b.getInt();b.getShort();int bits=b.getShort()&0xffff;
        formatOk=tag==1&&channels==studio.services.microphoneProtocol.CHANNELS&&rate==studio.services.microphoneProtocol.SAMPLE_RATE&&bits==32;
      }else if("data".equals(chunk)){dataOffset=file.getFilePointer();dataBytes=Math.min(size,file.length()-dataOffset);}
      file.seek(Math.min(next,file.length()));if(formatOk&&dataOffset>=0)break;
    }
    if(!formatOk||dataOffset<0||dataBytes<=0)throw new IOException("wav-format");return new WavDataRegion(dataOffset,dataBytes);
  }
  long readLE32(RandomAccessFile f)throws IOException{return (f.readUnsignedByte())|(long)f.readUnsignedByte()<<8|(long)f.readUnsignedByte()<<16|(long)f.readUnsignedByte()<<24;}
  void closeLine(){SourceDataLine current=line;line=null;closeLine(current);}
  void closeLine(SourceDataLine current){if(current==null)return;if(line==current)line=null;try{if(current.isRunning())current.stop();}catch(Exception ignored){}try{current.flush();}catch(Exception ignored){}try{current.close();}catch(Exception ignored){}}
  String safeMessage(Exception e){String m=e.getMessage();return m==null||m.length()==0?e.getClass().getSimpleName():m;}
}

class WavDataRegion { final long offset,bytes; WavDataRegion(long offset,long bytes){this.offset=offset;this.bytes=bytes;} }

class SpeakerSelfTest {
 final MicrophoneConfig cfg;
  volatile boolean running=false;
  volatile long runGeneration=0;
  volatile String stateKey="speaker.idle";
  volatile String detail="";
  Thread worker;SourceDataLine line;
  SpeakerSelfTest(MicrophoneConfig cfg){this.cfg=cfg;}
  boolean isRunning(){return running;}
  String state(){return stateKey;}
  String detail(){return detail;}

  void start(){if(running)return;running=true;stateKey="speaker.starting";detail="";final long generation=++runGeneration;worker=studio.services.workers.start("Microphones-SpeakerTest",new Runnable(){public void run(){playTone(generation);}});}
  void requestStop(){running=false;++runGeneration;closeLine();Thread t=worker;worker=null;if(t!=null&&t!=Thread.currentThread())t.interrupt();if(!"speaker.error".equals(stateKey))stateKey="speaker.idle";}
  void stop(){running=false;++runGeneration;closeLine();Thread t=worker;worker=null;if(t!=null&&t!=Thread.currentThread()){t.interrupt();try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}}if(!"speaker.error".equals(stateKey))stateKey="speaker.idle";}
  void playTone(long generation){
    SourceDataLine local=null;
    try{
      int rate=studio.services.microphoneProtocol.SAMPLE_RATE;AudioFormat format=new AudioFormat((float)rate,16,1,true,false);
      local=(SourceDataLine)AudioSystem.getLine(new DataLine.Info(SourceDataLine.class,format));local.open(format,cfg.speakerLineBufferBytes);local.start();
      if(generation!=runGeneration){closeLine(local);return;}line=local;
      int samples=max(1,rate*cfg.speakerDurationMs/1000);ByteBuffer tone=ByteBuffer.allocate(samples*2).order(ByteOrder.LITTLE_ENDIAN);
      for(int i=0;i<samples;i++){double edge=Math.min(i, samples-1-i);double envelope=Math.min(1.0,edge/Math.max(1.0,cfg.speakerFadeSamples));short value=(short)(Math.sin(2.0*Math.PI*cfg.speakerFrequencyHz*i/rate)*cfg.speakerAmplitude*envelope);tone.putShort(value);}
      stateKey="speaker.live";local.write(tone.array(),0,tone.position());if(running&&generation==runGeneration)local.drain();if(generation==runGeneration)stateKey="speaker.done";
    }catch(Exception e){if(generation==runGeneration){stateKey="speaker.error";detail=safeMessage(e);}}
    finally{if(generation==runGeneration)running=false;closeLine(local);}
  }
  void closeLine(){SourceDataLine current=line;line=null;closeLine(current);}
  void closeLine(SourceDataLine current){if(current==null)return;if(line==current)line=null;try{current.stop();}catch(Exception ignored){}try{current.flush();}catch(Exception ignored){}try{current.close();}catch(Exception ignored){}}
  String safeMessage(Exception e){String m=e.getMessage();return m==null||m.length()==0?e.getClass().getSimpleName():m;}
}


// ===== SynKinect Studio / Microphones / BridgeDiagnostics.pde =====
class BridgeDiagnostics {
 final MicrophoneConfig cfg;
 final HashMap<String,String> values=new HashMap<String,String>();
  long nextRefreshMs=0;
  volatile boolean refreshQueued=false;
  volatile boolean available=false;
  volatile String readError="";

  BridgeDiagnostics(MicrophoneConfig cfg){this.cfg=cfg;}

  void refresh(){
    long now=System.currentTimeMillis();if(now<nextRefreshMs)return;nextRefreshMs=now+cfg.diagnosticsRefreshMs;
    if(refreshQueued)return;refreshQueued=true;
    studio.services.workers.startLowPriority("Microphones-Diagnostics",new Runnable(){public void run(){try{refreshNow();}finally{refreshQueued=false;}}});
  }

  void refreshNow(){
    long now=System.currentTimeMillis();
    File statusFile=resolveStatusFile();
    if(statusFile==null||!statusFile.isFile()){available=false;readError="missing";return;}
    if(now-statusFile.lastModified()>cfg.diagnosticsStaleMs){available=false;readError="stale";return;}
    BufferedReader reader=null;
    try{
      HashMap<String,String> fresh=new HashMap<String,String>();reader=new BufferedReader(new InputStreamReader(new FileInputStream(statusFile),"UTF-8"));String line;
      while((line=reader.readLine())!=null){int eq=line.indexOf('=');if(eq>0)fresh.put(line.substring(0,eq).trim(),line.substring(eq+1).trim());}
      synchronized(values){values.clear();values.putAll(fresh);}available=true;readError="";
    }catch(IOException e){available=false;readError=safeMessage(e);}
    finally{if(reader!=null)try{reader.close();}catch(IOException ignored){}}
  }

  File resolveStatusFile(){
    if(studio.services.transportFactory.isLinux())return new File(studio.services.endpoints.linuxAudioStatus);
    String root=environmentPath("ProgramData");
    if(root==null)root=environmentPath("ALLUSERSPROFILE");
    return root==null?null:new File(new File(root,cfg.diagnosticsDirectory),cfg.diagnosticsFile);
  }

  String environmentPath(String name){String value=System.getenv(name);if(value==null)return null;value=value.trim();return value.length()==0?null:value;}
  String get(String key,String fallback){synchronized(values){String v=values.get(key);return v==null?fallback:v;}}
  long number(String key){return studio.services.configRules.longNumber(get(key,"0"),0);}
  String stage(){return get("stage","");}
  long wasapiPackets(){return number("wasapi_packets");}
  long wasapiFrames(){return number("wasapi_frames");}
  long published(){return number("published_frames");}
  long pipeClients(){return number("pipe_clients");}
  long runtimeSessions(){return number("runtime_sessions");}
  long firmwareUploads(){return number("firmware_uploads");}
  long lastError(){return number("last_error");}
  int captureRate(){return (int)number("capture_sample_rate");}
  int captureChannels(){return (int)number("capture_channels");}
  int captureBits(){return (int)number("capture_bits");}

  String stateKey(){
    if(!available)return "diag.unavailable";
    String current=stage();
    if(lastError()!=0||current.endsWith("-error"))return "diag.audio_error";
    if("uac-runtime-capturing".equals(current)){
      if(captureRate()==studio.services.microphoneProtocol.SAMPLE_RATE&&captureChannels()>=studio.services.microphoneProtocol.CHANNELS&&published()>0)return "diag.ok";
      return "diag.wait_frames";
    }
    if(current.startsWith("uac-firmware")||current.startsWith("uac-search")||current.equals("starting"))return "diag.wait";
    return "diag.wait";
  }

  String formatSummary(){
    String format=captureChannels()>0?captureChannels()+"ch / "+captureRate()+" Hz / "+captureBits()+" bit":"—";
    return format;
  }
  String compactCounters(){return "WASAPI "+wasapiPackets()+" · PCM "+published()+" · SESS "+runtimeSessions();}
  String errorCode(){long code=lastError();return code==0?"":String.valueOf(code);}
  String detail(){String d=get("detail","");if(d.length()>96)d=d.substring(0,95)+"…";return d;}
  String safeMessage(Exception e){String m=e.getMessage();return m==null||m.length()==0?e.getClass().getSimpleName():m;}
}


// ===== SynKinect Studio / Microphones / MicrophoneConfig.pde =====
class MicrophoneConfig {
  int uiFrameRate = 30;
  String uiFontFamily = "Segoe UI";
  String uiHeadingFontFamily = "Segoe UI Semibold";
  String uiFontFallback = "Arial";
  int workerJoinMs = 1200;
  int reconnectMs = 300;
  int pipeOpenAttempts = 4;
  int pipeOpenRetryMs = 75;
  int noFrameWarningMs = 2000;
  int connectionStaleMs = 3500;
  int diagnosticsRefreshMs = 500;
  int diagnosticsStaleMs = 3000;
  String diagnosticsDirectory = "Kinect360Remold";
  String diagnosticsFile = "audio-bridge-status.txt";
  String recordingsDirectory = "recordings";
  String recordingPrefix = "KinectMics";
  int monitorQueueFrames = 8;
  float monitorTargetPeak = 0.55f;
  float monitorMaxGain = 64.0f;
  float monitorGainSmoothing = 0.18f;
  int monitorLineBufferBytes = 4096;
  int playbackLineBufferBytes = 8192;
  int speakerFrequencyHz = 700;
  int speakerDurationMs = 750;
  int speakerAmplitude = 12000;
  int speakerFadeSamples = 400;
  int speakerLineBufferBytes = 4096;

  void load(File file) {
    Properties p=studio.services.configRules.load(file,"microphone");
      uiFrameRate = intValue(p,"ui.frameRate",uiFrameRate,10,120);
      uiFontFamily = textValue(p,"ui.font.family",uiFontFamily);
      uiHeadingFontFamily = textValue(p,"ui.font.headingFamily",uiHeadingFontFamily);
      uiFontFallback = textValue(p,"ui.font.fallback",uiFontFallback);
      workerJoinMs = intValue(p,"lifecycle.workerJoinMs",workerJoinMs,250,10000);
      reconnectMs = intValue(p,"transport.reconnectMs",reconnectMs,50,5000);
      pipeOpenAttempts = intValue(p,"transport.pipeOpenAttempts",pipeOpenAttempts,1,20);
      pipeOpenRetryMs = intValue(p,"transport.pipeOpenRetryMs",pipeOpenRetryMs,10,1000);
      noFrameWarningMs = intValue(p,"transport.noFrameWarningMs",noFrameWarningMs,250,30000);
      connectionStaleMs = intValue(p,"transport.connectionStaleMs",connectionStaleMs,500,30000);
      diagnosticsRefreshMs = intValue(p,"diagnostics.refreshMs",diagnosticsRefreshMs,100,5000);
      diagnosticsStaleMs = intValue(p,"diagnostics.staleMs",diagnosticsStaleMs,500,30000);
      diagnosticsDirectory = textValue(p,"diagnostics.directory",diagnosticsDirectory);
      diagnosticsFile = textValue(p,"diagnostics.file",diagnosticsFile);
      recordingsDirectory = textValue(p,"record.directory",recordingsDirectory);
      recordingPrefix = textValue(p,"record.filePrefix",recordingPrefix);
      monitorQueueFrames = intValue(p,"monitor.queueFrames",monitorQueueFrames,2,64);
      monitorTargetPeak = floatValue(p,"monitor.targetPeak",monitorTargetPeak,0.05f,0.95f);
      monitorMaxGain = floatValue(p,"monitor.maxGain",monitorMaxGain,1.0f,128.0f);
      monitorGainSmoothing = floatValue(p,"monitor.gainSmoothing",monitorGainSmoothing,0.01f,1.0f);
      monitorLineBufferBytes = intValue(p,"monitor.lineBufferBytes",monitorLineBufferBytes,512,65536);
      playbackLineBufferBytes = intValue(p,"playback.lineBufferBytes",playbackLineBufferBytes,512,131072);
      speakerFrequencyHz = intValue(p,"speaker.frequencyHz",speakerFrequencyHz,80,12000);
      speakerDurationMs = intValue(p,"speaker.durationMs",speakerDurationMs,100,5000);
      speakerAmplitude = intValue(p,"speaker.amplitude",speakerAmplitude,100,32767);
      speakerFadeSamples = intValue(p,"speaker.fadeSamples",speakerFadeSamples,1,8000);
      speakerLineBufferBytes = intValue(p,"speaker.lineBufferBytes",speakerLineBufferBytes,512,65536);
  }

  String textValue(Properties p,String key,String fallback){return studio.services.configRules.text(p,key,fallback);}
  boolean boolValue(Properties p,String key,boolean fallback){return studio.services.configRules.flag(p,key,fallback);}
  int intValue(Properties p,String key,int fallback,int lo,int hi){return studio.services.configRules.integer(p,key,fallback,lo,hi);}
  float floatValue(Properties p,String key,float fallback,float lo,float hi){return studio.services.configRules.decimal(p,key,fallback,lo,hi);}
}


// ===== SynKinect Studio / Microphones / MicrophoneLocalization.pde =====
class MicrophoneI18n extends ModuleI18n {
  MicrophoneI18n(String requested){super("microphone",requested);}
}


class MicrophoneTheme {
  final int BG=0xFF11151A, SURFACE=0xFF181E25, SURFACE_ALT=0xFF202832, RAISED=0xFF293440;
  final int BORDER=0xFF35414D, TEXT=0xFFF4F7FA, MUTED=0xFFAAB6C2, ACTIVE=0xFF68A9E8, DIM=0xFF6F7C88;
  final int GOOD=0xFF7CC7A0, WARN=0xFFE4B86B, BAD=0xFFE17D7D, PREVIEW=0xFF0B0F13, GRID=0xFF35404A;
  final int MARGIN=20, GAP=14, HEADER_H=68, STATUS_H=112, CONTROLS_H=122, RADIUS=14;
  final int FONT_TINY=12, FONT_SMALL=14, FONT_BODY=15, FONT_LABEL=16, FONT_METRIC=19, FONT_TITLE=27;
}

PFont microphoneFontRegular,microphoneFontHeading;
void initializeMicrophoneTypography(){
  String regular="SansSerif";
  String heading="SansSerif";
  microphoneFontRegular=createFont(regular,studio.services.microphoneTheme.FONT_BODY,true);
  microphoneFontHeading=createFont(heading,studio.services.microphoneTheme.FONT_TITLE,true);
  textFont(microphoneFontRegular);textLeading(studio.services.microphoneTheme.FONT_BODY*1.28f);
}
String resolveMicrophoneFont(String preferred,String fallback){String[] installed=PFont.list();String hit=findMicrophoneFont(installed,preferred);if(hit!=null)return hit;hit=findMicrophoneFont(installed,fallback);return hit==null?"SansSerif":hit;}
String findMicrophoneFont(String[] installed,String wanted){if(wanted==null||wanted.trim().length()==0||installed==null)return null;for(String candidate:installed)if(candidate.equalsIgnoreCase(wanted.trim()))return candidate;return null;}
void micText(float size,boolean heading){PFont f=heading?microphoneFontHeading:microphoneFontRegular;if(f!=null)textFont(f);textSize(responsiveFontSize(size));}


// ===== SynKinect Studio / Microphones / MicrophoneProtocol.pde =====
class MicrophoneProtocol {
  final int MAGIC=0x414D4D52;
  final int FRAME_MAGIC=0x464D4D52;
  final int VERSION=1;
  final int CMD_SUBSCRIBE=1;
  final int SAMPLE_RATE=16000;
  final int CHANNELS=4;
  final int SAMPLES=256;
  final int SAMPLE_FORMAT_S32LE=1;
  final int BYTES_PER_SAMPLE=4;
  final int PAYLOAD_BYTES=CHANNELS*SAMPLES*BYTES_PER_SAMPLE;
  final int REQUEST_BYTES=16;
  final int REPLY_BYTES=32;
  final int HEADER_BYTES=48;
  final int REQUIRED_CAPABILITIES=0x3;
  final int VALID_CHANNEL_MASK=(1<<CHANNELS)-1;
}

class MicrophoneFrame extends SpatialAudioFrame {
  boolean channelValid(int channel){return valid(channel);}
}


// ===== SynKinect Studio / Microphones / MicrophoneSource.pde =====
class MicrophoneSource {
 final MicrophoneConfig cfg;
 final AudioPipeline pipeline;
 final Object lock=new Object();
  volatile boolean running=false,connected=false;
  volatile long runGeneration=0;
  volatile long frameCount=0,payloadBytesReceived=0,connectedSinceMs=0,lastFrameArrivalMs=0,connectionEpoch=0,reconnectKicks=0,lastReconnectKickMs=0;
  volatile String stateKey="source.starting",detail="",connectedPipe="";
  volatile LocalTransport activePipe;
 final Object pipeLock=new Object();
  Thread worker;MicrophoneFrame latest;

  MicrophoneSource(MicrophoneConfig cfg,AudioPipeline pipeline){this.cfg=cfg;this.pipeline=pipeline;}

  synchronized void start(){if(running)return;running=true;final long generation=++runGeneration;worker=studio.services.workers.start("Microphones-Port",new Runnable(){public void run(){loop(generation);}});}
  void requestStop(){Thread t;synchronized(this){running=false;++runGeneration;closeActivePipe();t=worker;worker=null;}if(t!=null)t.interrupt();synchronized(pipeLock){activePipe=null;}connected=false;}
  void stop(){
    Thread t;synchronized(this){running=false;++runGeneration;closeActivePipe();t=worker;worker=null;}
    if(t!=null){t.interrupt();try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}}
    synchronized(pipeLock){activePipe=null;}connected=false;
  }
  MicrophoneFrame snapshot(){synchronized(lock){return latest;}}
  String displayStateKey(){
    if(!connected)return stateKey;
    long now=System.currentTimeMillis();
    // A newly opened pipe may legitimately wait while 02AD->02BB/WASAPI finishes.
    // Reopening that pipe cannot make WASAPI start, so never churn a healthy pipe
    // before the first frame. Only a stream that *was* delivering audio and then
    // became stale is force-reconnected.
    if(lastFrameArrivalMs>0&&now-lastFrameArrivalMs>cfg.connectionStaleMs){requestReconnect("stale-session");return "source.reconnecting";}
    long anchor=lastFrameArrivalMs>0?lastFrameArrivalMs:connectedSinceMs;
    if(anchor>0&&now-anchor>cfg.noFrameWarningMs)return lastFrameArrivalMs>0?"source.stale":"source.no_frames";
    return stateKey;
  }

  void setActivePipe(LocalTransport pipe){synchronized(pipeLock){activePipe=pipe;}}
  void clearActivePipe(LocalTransport pipe){synchronized(pipeLock){if(activePipe==pipe)activePipe=null;}}
  void closeActivePipe(){LocalTransport pipe;synchronized(pipeLock){pipe=activePipe;activePipe=null;}closePipe(pipe);}
  void requestReconnect(String reason){
    if(!running)return;long now=System.currentTimeMillis();if(now-lastReconnectKickMs<Math.max(100,cfg.reconnectMs))return;
    lastReconnectKickMs=now;reconnectKicks++;stateKey="source.reconnecting";detail=reason;studio.services.workers.start("Microphones-Reconnect",new Runnable(){public void run(){closeActivePipe();}});
  }

  void loop(long generation){
    while(running&&generation==runGeneration){
      LocalTransport pipe=null;
      try{
        connected=false;stateKey="source.connecting";detail="";lastFrameArrivalMs=0;
        pipe=openBestPipe();setActivePipe(pipe);subscribe(pipe);
        connected=true;connectedSinceMs=System.currentTimeMillis();connectionEpoch++;stateKey="source.streaming";
        long lastFrame=-1;byte[] headerBytes=new byte[studio.services.microphoneProtocol.HEADER_BYTES];byte[] payload=new byte[studio.services.microphoneProtocol.PAYLOAD_BYTES];
        while(running&&generation==runGeneration){
          pipe.readFully(headerBytes);ByteBuffer h=ByteBuffer.wrap(headerBytes).order(ByteOrder.LITTLE_ENDIAN);
          int magic=h.getInt(),version=h.getInt(),sampleRate=h.getInt(),channels=h.getInt(),sampleFormat=h.getInt(),samplesPerChannel=h.getInt(),payloadBytes=h.getInt(),channelMask=h.getInt();
          long frameNumber=h.getLong(),tickMs=h.getLong();
          validateFrameHeader(magic,version,sampleRate,channels,sampleFormat,samplesPerChannel,payloadBytes,channelMask,frameNumber,lastFrame);lastFrame=frameNumber;
          pipe.readFully(payload);payloadBytesReceived+=payload.length;
          MicrophoneFrame frame=decodeFrame(payload,frameNumber,tickMs,channelMask);
          synchronized(lock){latest=frame;}frameCount++;lastFrameArrivalMs=System.currentTimeMillis();pipeline.accept(frame);
        }
      }catch(IOException e){if(generation==runGeneration){connected=false;if(running){stateKey="source.reconnecting";detail=safeMessage(e);}}}
      finally{clearActivePipe(pipe);closePipe(pipe);}
      if(running&&generation==runGeneration)try{Thread.sleep(cfg.reconnectMs);}catch(InterruptedException e){if(!running||generation!=runGeneration)return;Thread.currentThread().interrupt();return;}
    }
  }

  void validateFrameHeader(int magic,int version,int rate,int channels,int format,int samples,int payloadBytes,int mask,long frameNumber,long lastFrame)throws IOException{
    if(magic!=studio.services.microphoneProtocol.FRAME_MAGIC||version!=studio.services.microphoneProtocol.VERSION)throw new IOException("protocol-frame");
    if(rate!=studio.services.microphoneProtocol.SAMPLE_RATE||channels!=studio.services.microphoneProtocol.CHANNELS||format!=studio.services.microphoneProtocol.SAMPLE_FORMAT_S32LE||samples!=studio.services.microphoneProtocol.SAMPLES||payloadBytes!=studio.services.microphoneProtocol.PAYLOAD_BYTES)throw new IOException("protocol-format");
    if((mask&~studio.services.microphoneProtocol.VALID_CHANNEL_MASK)!=0||mask==0)throw new IOException("protocol-channel-mask");
    if(lastFrame>=0&&frameNumber<=lastFrame)throw new IOException("protocol-frame-order");
  }

  MicrophoneFrame decodeFrame(byte[] payload,long frameNumber,long tickMs,int channelMask){
    ByteBuffer pcm=ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN);MicrophoneFrame frame=new MicrophoneFrame();frame.frameNumber=frameNumber;frame.tickMs=tickMs;frame.channelMask=channelMask;
    for(int sample=0;sample<studio.services.microphoneProtocol.SAMPLES;sample++)for(int mic=0;mic<studio.services.microphoneProtocol.CHANNELS;mic++)frame.samples[mic][sample]=pcm.getInt();
    for(int mic=0;mic<studio.services.microphoneProtocol.CHANNELS;mic++){
      long peak=0;for(int sample=0;sample<studio.services.microphoneProtocol.SAMPLES;sample++){long value=frame.samples[mic][sample];long magnitude=value==Integer.MIN_VALUE?2147483648L:Math.abs(value);if(magnitude>peak)peak=magnitude;}
      frame.peak[mic]=peak/2147483648.0f;
    }
    return frame;
  }

  LocalTransport openPipeWithRetry(String pipeName,String socketName)throws IOException{
    IOException last=null;
    for(int attempt=1;attempt<=cfg.pipeOpenAttempts&&running;attempt++){
      try{return studio.services.transportFactory.open(pipeName,socketName);}
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

  LocalTransport openBestPipe()throws IOException{LocalTransport pipe=openPipeWithRetry(studio.services.endpoints.audio.windowsPath,studio.services.endpoints.audio.linuxPath);connectedPipe=studio.services.endpoints.audio.label;return pipe;}

  String pipeModeKey(){return "source.pipe_primary";}

  void subscribe(LocalTransport pipe)throws IOException{
    ByteBuffer request=ByteBuffer.allocate(studio.services.microphoneProtocol.REQUEST_BYTES).order(ByteOrder.LITTLE_ENDIAN);
    request.putInt(studio.services.microphoneProtocol.MAGIC);request.putInt(studio.services.microphoneProtocol.VERSION);request.putInt(studio.services.microphoneProtocol.CMD_SUBSCRIBE);request.putInt(0);pipe.write(request.array());
    byte[] bytes=new byte[studio.services.microphoneProtocol.REPLY_BYTES];pipe.readFully(bytes);ByteBuffer r=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
    int magic=r.getInt(),version=r.getInt(),result=r.getInt(),rate=r.getInt(),channels=r.getInt(),format=r.getInt(),maxPayload=r.getInt(),capabilities=r.getInt();
    if(magic!=studio.services.microphoneProtocol.MAGIC||version!=studio.services.microphoneProtocol.VERSION||result<0)throw new IOException("protocol-subscribe");
    if(rate!=studio.services.microphoneProtocol.SAMPLE_RATE||channels!=studio.services.microphoneProtocol.CHANNELS||format!=studio.services.microphoneProtocol.SAMPLE_FORMAT_S32LE||maxPayload<studio.services.microphoneProtocol.PAYLOAD_BYTES)throw new IOException("protocol-bridge-format");
    if((capabilities&studio.services.microphoneProtocol.REQUIRED_CAPABILITIES)!=studio.services.microphoneProtocol.REQUIRED_CAPABILITIES)throw new IOException("protocol-capabilities");
  }

  void closePipe(LocalTransport pipe){if(pipe==null)return;try{pipe.close();}catch(IOException e){if(running)detail=safeMessage(e);}}
  String safeMessage(Exception e){String m=e.getMessage();return m==null||m.length()==0?e.getClass().getSimpleName():m;}
}


// ===== SynKinect Studio / Microphones / MicrophoneUI.pde =====
class MicrophoneUI {
  final int ACTION_RECORD=0,ACTION_MONITOR=1,ACTION_PLAY=2,ACTION_TEST=3,ACTION_AUTO=4,ACTION_MANUAL=5;
 final ArrayList<MicButton> buttons=new ArrayList<MicButton>();

  MicrophoneUI(){
    buttons.add(new MicButton("button.record",ACTION_RECORD,true));
    buttons.add(new MicButton("button.monitor",ACTION_MONITOR,false));
    buttons.add(new MicButton("button.play",ACTION_PLAY,false));
    buttons.add(new MicButton("button.test",ACTION_TEST,false));
    buttons.add(new MicButton("mode.auto",ACTION_AUTO,false));
    buttons.add(new MicButton("mode.manual",ACTION_MANUAL,false));
  }

  void draw(MicrophoneFrame frame){
    drawHeader();
    float m=studio.services.microphoneTheme.MARGIN,g=studio.services.microphoneTheme.GAP,statusH=min(width<900?156:studio.services.microphoneTheme.STATUS_H,max(72,studio.contentHeight*.22f));
    float statusY=studio.services.microphoneTheme.HEADER_H+g;drawTransportPanel(m,statusY,width-2*m,statusH);
    float controlsH=constrain(studio.contentHeight*.18f,88,studio.services.microphoneTheme.CONTROLS_H),controlsY=studio.contentHeight-controlsH-m;
    float gridY=statusY+statusH+g,gridH=max(32,controlsY-gridY-g);drawMicrophoneGrid(m,gridY,width-2*m,gridH,frame);drawControls(m,controlsY,width-2*m,controlsH);
  }

  void drawHeader(){
    fill(studio.services.microphoneTheme.BG);noStroke();rect(0,0,width,studio.services.microphoneTheme.HEADER_H);
    fill(studio.services.microphoneTheme.TEXT);micText(studio.services.microphoneTheme.FONT_TITLE,true);textAlign(studio.microphoneState.i18n.startAlign(),CENTER);
    String headerTitle=studio.microphoneState.i18n.tr("app.title");fitCurrentTextSize(headerTitle,studio.services.microphoneTheme.FONT_TITLE,10,max(80,width-120),studio.services.microphoneTheme.HEADER_H-12);text(ellipsizeToWidth(headerTitle,max(80,width-120)),studio.microphoneState.i18n.rtl?width-studio.services.microphoneTheme.MARGIN:studio.services.microphoneTheme.MARGIN,studio.services.microphoneTheme.HEADER_H/2);
    textAlign(LEFT,BASELINE);
  }

  void drawTransportPanel(float x,float y,float w,float h){
    card(x,y,w,h);fill(studio.services.microphoneTheme.TEXT);micText(studio.services.microphoneTheme.FONT_SMALL,true);textAlign(LEFT,CENTER);String transportTitle=studio.microphoneState.i18n.tr("panel.transport");fitCurrentTextSize(transportTitle,studio.services.microphoneTheme.FONT_SMALL,7,w-24,24);text(ellipsizeToWidth(transportTitle,w-24),x+12,y+17);textAlign(LEFT,BASELINE);
    boolean live=studio.microphoneState.source!=null&&studio.microphoneState.source.connected;String transportState=studio.microphoneState.i18n.tr(studio.microphoneState.source==null?"source.starting":studio.microphoneState.source.displayStateKey());if(live)transportState+=" · "+studio.microphoneState.i18n.tr(studio.microphoneState.source.pipeModeKey());AcousticScanFrame spatial=studio.microphoneState.pipeline==null?null:studio.microphoneState.pipeline.monitor.latestScan;String doa=spatial==null?"—":nf(spatial.azimuthDeg,1,1)+"° / "+nf(studio.microphoneState.pipeline.monitor.beamAzimuthDeg,1,1)+"°";String reconnects=String.valueOf(studio.microphoneState.source==null?0:studio.microphoneState.source.reconnectKicks);String code=studio.microphoneState.diagnostics.errorCode();if(code.length()>0)reconnects+=" · E"+code;
    String[] labels={studio.microphoneState.i18n.tr("label.transport"),studio.microphoneState.i18n.tr("label.frames"),studio.i18n.tr("label.doa_beam"),studio.microphoneState.i18n.tr("label.runtime"),studio.microphoneState.i18n.tr("label.reconnects")};
    String[] values={transportState,formatCount(studio.microphoneState.source==null?0:studio.microphoneState.source.frameCount),doa,studio.microphoneState.diagnostics.formatSummary(),reconnects};boolean[] active={live,live,spatial!=null,"diag.ok".equals(studio.microphoneState.diagnostics.stateKey()),studio.microphoneState.diagnostics.lastError()==0};
    int cols=w<850?3:5,rows=(labels.length+cols-1)/cols;float top=y+32,gap=8,tw=(w-24-gap*(cols-1))/cols,th=(h-42-gap*(rows-1))/rows;for(int i=0;i<labels.length;i++){int col=i%cols,row=i/cols;metricTile(x+12+col*(tw+gap),top+row*(th+gap),tw,th,labels[i],values[i],active[i]);}
  }

  void metricTile(float x,float y,float w,float h,String label,String value,boolean active){
    noStroke();fill(studio.services.microphoneTheme.SURFACE_ALT);rect(x,y,w,h,8);
    fill(active?studio.services.microphoneTheme.ACTIVE:studio.services.microphoneTheme.DIM);ellipse(x+12,y+14,6,6);
    fill(studio.services.microphoneTheme.MUTED);micText(studio.services.microphoneTheme.FONT_TINY,false);textAlign(LEFT,CENTER);fitCurrentTextSize(label,studio.services.microphoneTheme.FONT_TINY,7,w-30,22);text(ellipsizeToWidth(label,w-30),x+22,y+14);
    fill(studio.services.microphoneTheme.TEXT);micText(studio.services.microphoneTheme.FONT_SMALL,true);fitCurrentTextSize(value,studio.services.microphoneTheme.FONT_SMALL,7,w-20,24);text(ellipsizeToWidth(value,w-20),x+10,y+h-15);textAlign(LEFT,BASELINE);
  }

  void drawMicrophoneGrid(float x,float y,float w,float h,MicrophoneFrame frame){
    float gap=studio.services.microphoneTheme.GAP,cw=(w-gap)/2.0f,ch=(h-gap)/2.0f;
    for(int mic=0;mic<studio.services.microphoneProtocol.CHANNELS;mic++){
      int col=mic%2,row=mic/2;drawMicrophoneCard(x+col*(cw+gap),y+row*(ch+gap),cw,ch,mic,frame);
    }
  }

  void drawMicrophoneCard(float x,float y,float w,float h,int mic,MicrophoneFrame frame){
    card(x,y,w,h);boolean valid=frame!=null&&frame.channelValid(mic);float peak=valid?frame.peak[mic]:0;
    fill(valid?studio.services.microphoneTheme.ACTIVE:studio.services.microphoneTheme.DIM);ellipse(x+14,y+17,7,7);
    fill(studio.services.microphoneTheme.MUTED);micText(studio.services.microphoneTheme.FONT_SMALL,false);textAlign(LEFT,CENTER);String micLabel=studio.microphoneState.i18n.tr("label.mic")+" "+(mic+1);fitCurrentTextSize(micLabel,studio.services.microphoneTheme.FONT_SMALL,7,max(30,w-105),24);text(ellipsizeToWidth(micLabel,max(30,w-105)),x+25,y+17);
    fill(studio.services.microphoneTheme.TEXT);textAlign(RIGHT,CENTER);micText(studio.services.microphoneTheme.FONT_SMALL,true);text(valid?nf(peak*100,1,1)+"%":"—",x+w-12,y+17);textAlign(LEFT,BASELINE);

    float meterX=x+12,meterY=y+31,meterW=w-24;fill(studio.services.microphoneTheme.GRID);noStroke();rect(meterX,meterY,meterW,5,2.5f);fill(valid?studio.services.microphoneTheme.ACTIVE:studio.services.microphoneTheme.DIM);rect(meterX,meterY,meterW*constrain(peak,0,1),5,2.5f);
    float wx=x+12,wy=y+47,ww=max(12,w-24),wh=max(14,h-59);fill(studio.services.microphoneTheme.PREVIEW);rect(wx,wy,ww,wh,8);stroke(studio.services.microphoneTheme.GRID);line(wx,wy+wh/2,wx+ww,wy+wh/2);
    if(!valid)return;
    stroke(studio.services.microphoneTheme.ACTIVE);noFill();beginShape();
    for(int i=0;i<studio.services.microphoneProtocol.SAMPLES;i++){
      float sx=map(i,0,studio.services.microphoneProtocol.SAMPLES-1,wx+4,wx+ww-4);float normalized=constrain(frame.samples[mic][i]/2147483648.0f,-1,1);float sy=wy+wh/2-normalized*wh*0.43f;vertex(sx,sy);
    }
    endShape();
  }

  void drawControls(float x,float y,float w,float h){
    float gap=studio.services.microphoneTheme.GAP;
    float captureW=(w-gap)/2.0f,playW=w-captureW-gap;
    drawActionGroup(x,y,captureW,h,studio.microphoneState.i18n.tr("panel.capture"),new int[]{ACTION_RECORD,ACTION_MONITOR,ACTION_AUTO,ACTION_MANUAL});
    drawActionGroup(x+captureW+gap,y,playW,h,studio.microphoneState.i18n.tr("panel.playback"),new int[]{ACTION_PLAY,ACTION_TEST});
  }

  void drawActionGroup(float x,float y,float w,float h,String title,int[] actions){
    card(x,y,w,h);fill(studio.services.microphoneTheme.TEXT);micText(studio.services.microphoneTheme.FONT_TINY,true);textAlign(LEFT,CENTER);fitCurrentTextSize(title,studio.services.microphoneTheme.FONT_TINY,7,w-20,24);text(ellipsizeToWidth(title,w-20),x+10,y+17);textAlign(LEFT,BASELINE);
    float bx=x+9,by=y+31,gap=7,bh=42,bw=(w-18-gap*(actions.length-1))/actions.length;
    for(int i=0;i<actions.length;i++){MicButton b=findButton(actions[i]);if(b!=null){b.setBounds(bx+i*(bw+gap),by,bw,bh);b.draw();}}
    String status=groupStatus(actions);fill(studio.services.microphoneTheme.MUTED);micText(studio.services.microphoneTheme.FONT_TINY,false);textAlign(LEFT,CENTER);fitCurrentTextSize(status,studio.services.microphoneTheme.FONT_TINY,7,w-20,24);text(ellipsizeToWidth(status,w-20),x+10,y+h-15);textAlign(LEFT,BASELINE);
  }

  String groupStatus(int[] actions){
    if(containsAction(actions,ACTION_RECORD)){
      if(studio.microphoneState.pipeline.recorder.isRecording())return studio.microphoneState.i18n.format("status.recording",formatBytes(studio.microphoneState.pipeline.recorder.bytes()));
      if(studio.microphoneState.pipeline.monitor.isRunning()){
        AcousticScanFrame scan=studio.microphoneState.pipeline.monitor.latestScan;
        String doa=scan==null?"—":nf(scan.azimuthDeg,1,1)+"°";
        String mode=studio.i18n.tr(studio.microphoneState.pipeline.monitor.automaticBeam?"mode.auto":"mode.manual");
        return "DOA "+doa+" · "+studio.i18n.tr("label.doa_beam")+" "+nf(studio.microphoneState.pipeline.monitor.beamAzimuthDeg,1,1)+"° · "+mode;
      }
      String key=studio.microphoneState.pipeline.recorder.state();return studio.microphoneState.i18n.tr(key);
    }
    if(containsAction(actions,ACTION_PLAY)){
      if(studio.microphoneState.pipeline.player.isRunning())return studio.microphoneState.i18n.format("status.playback",studio.microphoneState.pipeline.player.fileName);
      if(studio.microphoneState.pipeline.selfTest.isRunning())return studio.microphoneState.i18n.format("status.speaker",studio.microphoneState.config.speakerFrequencyHz);
      String key=!"playback.idle".equals(studio.microphoneState.pipeline.player.state())?studio.microphoneState.pipeline.player.state():studio.microphoneState.pipeline.selfTest.state();
      return studio.microphoneState.i18n.tr(key);
    }
    return studio.microphoneState.i18n.tr(studio.microphoneState.diagnostics.stateKey())+" · "+studio.microphoneState.diagnostics.compactCounters();
  }

  boolean containsAction(int[] actions,int action){for(int a:actions)if(a==action)return true;return false;}
  MicButton findButton(int action){for(MicButton b:buttons)if(b.action==action)return b;return null;}
  boolean handleMousePressed(float mx,float my){for(MicButton b:buttons)if(b.hit(mx,my)){b.fire();return true;}return false;}
  void card(float x,float y,float w,float h){stroke(studio.services.microphoneTheme.BORDER);strokeWeight(1);fill(studio.services.microphoneTheme.SURFACE);rect(x,y,w,h,studio.services.microphoneTheme.RADIUS);noStroke();}
  void drawPill(float x,float y,float w,float h,String textValue,boolean active){noStroke();fill(active?studio.services.microphoneTheme.RAISED:studio.services.microphoneTheme.SURFACE_ALT);rect(x,y,w,h,h/2);fill(active?studio.services.microphoneTheme.TEXT:studio.services.microphoneTheme.MUTED);textAlign(CENTER,CENTER);micText(studio.services.microphoneTheme.FONT_TINY,true);fitCurrentTextSize(textValue,studio.services.microphoneTheme.FONT_TINY,7,w-10,h-6);text(ellipsizeToWidth(textValue,w-10),x+w/2,y+h/2);textAlign(LEFT,BASELINE);}
  String formatCount(long value){if(value>=1000000)return nf(value/1000000.0f,1,1)+"M";if(value>=1000)return nf(value/1000.0f,1,1)+"k";return String.valueOf(value);}
  String formatBytes(long value){if(value>=1024L*1024L)return nf(value/(1024.0f*1024.0f),1,1)+" MB";if(value>=1024)return nf(value/1024.0f,1,1)+" KB";return value+" B";}
  String ellipsize(String s,int limit){if(s==null)return "";return s.length()<=limit?s:s.substring(0,max(0,limit-1))+"…";}
}

class MicButton {
  float x,y,w,h;final String labelKey;final int action;final boolean primary;
  MicButton(String key,int action,boolean primary){labelKey=key;this.action=action;this.primary=primary;}
  void setBounds(float x,float y,float w,float h){this.x=x;this.y=y;this.w=w;this.h=h;}
  boolean active(){
    if(action==studio.microphoneState.ui.ACTION_AUTO)return studio.microphoneState.pipeline.monitor.automaticBeam;
    if(action==studio.microphoneState.ui.ACTION_MANUAL)return !studio.microphoneState.pipeline.monitor.automaticBeam;
    return action==studio.microphoneState.ui.ACTION_RECORD?studio.microphoneState.pipeline.recorder.isRecording():action==studio.microphoneState.ui.ACTION_MONITOR?studio.microphoneState.pipeline.monitor.isRunning():action==studio.microphoneState.ui.ACTION_PLAY?studio.microphoneState.pipeline.player.isRunning():action==studio.microphoneState.ui.ACTION_TEST?studio.microphoneState.pipeline.selfTest.isRunning():false;
  }
  String label(){
    if(action==studio.microphoneState.ui.ACTION_AUTO||action==studio.microphoneState.ui.ACTION_MANUAL)return studio.i18n.tr(labelKey);
    if(active())return studio.microphoneState.i18n.tr("button.stop");return studio.microphoneState.i18n.tr(labelKey);
  }
  void draw(){boolean hot=hit(studio.contentMouseX(),studio.contentMouseY()),on=active();stroke(hot?studio.services.microphoneTheme.ACTIVE:studio.services.microphoneTheme.BORDER);fill(on||primary?studio.services.microphoneTheme.RAISED:studio.services.microphoneTheme.SURFACE_ALT);rect(x,y,w,h,8);noStroke();fill(on||hot?studio.services.microphoneTheme.TEXT:studio.services.microphoneTheme.MUTED);textAlign(CENTER,CENTER);micText(studio.services.microphoneTheme.FONT_SMALL,true);String value=label();fitCurrentTextSize(value,studio.services.microphoneTheme.FONT_SMALL,7,w-12,h-8);text(ellipsizeToWidth(value,w-12),x+w/2,y+h/2);textAlign(LEFT,BASELINE);}
  boolean hit(float mx,float my){return mx>=x&&mx<=x+w&&my>=y&&my<=y+h;}
  void fire(){dispatchMicrophoneAction(action);}
}


