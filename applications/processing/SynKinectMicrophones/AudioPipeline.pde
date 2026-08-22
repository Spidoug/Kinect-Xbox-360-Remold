class AudioPipeline {
  final WavRecorder recorder;
  final LiveMonitor monitor;
  final RecordedWavPlayer player;
  final SpeakerSelfTest selfTest;

  AudioPipeline(MicrophoneConfig cfg){
    recorder=new WavRecorder();
    monitor=new LiveMonitor(cfg);
    player=new RecordedWavPlayer(cfg);
    selfTest=new SpeakerSelfTest(cfg);
  }

  void accept(MicrophoneFrame frame){recorder.accept(frame);monitor.accept(frame);}
  void stop(){recorder.stop();monitor.stop();player.stop();selfTest.stop();}
}

class WavRecorder {
  final int blockAlign=MicrophoneProtocol.CHANNELS*MicrophoneProtocol.BYTES_PER_SAMPLE;
  final int byteRate=MicrophoneProtocol.SAMPLE_RATE*blockAlign;
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
      ByteBuffer data=ByteBuffer.allocate(MicrophoneProtocol.PAYLOAD_BYTES).order(ByteOrder.LITTLE_ENDIAN);
      for(int sample=0;sample<MicrophoneProtocol.SAMPLES;sample++)
        for(int mic=0;mic<MicrophoneProtocol.CHANNELS;mic++)
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
    writeLE16(file,1);writeLE16(file,MicrophoneProtocol.CHANNELS);writeLE32(file,MicrophoneProtocol.SAMPLE_RATE);writeLE32(file,byteRate);
    writeLE16(file,blockAlign);writeLE16(file,MicrophoneProtocol.BYTES_PER_SAMPLE*8);file.writeBytes("data");dataSizeOffset=file.getFilePointer();writeLE32(file,0);dataBytes=0;
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
  final Object lock=new Object();
  final ArrayDeque<byte[]> queue=new ArrayDeque<byte[]>();
  volatile boolean running=false;
  volatile String stateKey="monitor.idle";
  volatile String detail="";
  volatile float automaticGain=1.0f;
  volatile int dominantMic=-1;
  Thread worker; SourceDataLine line;

  LiveMonitor(MicrophoneConfig cfg){this.cfg=cfg;}
  boolean isRunning(){return running;}
  String state(){return stateKey;}
  String detail(){return detail;}

  void start(){
    synchronized(lock){if(running)return;running=true;stateKey="monitor.starting";detail="";dominantMic=-1;automaticGain=1.0f;queue.clear();}
    worker=new Thread(new Runnable(){public void run(){playbackLoop();}},"SynKinectMicrophones-Monitor");worker.setDaemon(true);worker.start();
  }

  void stop(){
    synchronized(lock){running=false;queue.clear();lock.notifyAll();}
    closeLine(); Thread t=worker;worker=null;
    if(t!=null&&t!=Thread.currentThread())try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}
    if(!"monitor.error".equals(stateKey))stateKey="monitor.idle";
  }

  void accept(MicrophoneFrame frame){
    if(!running||frame==null)return;
    int selected=-1;float selectedPeak=-1;
    for(int mic=0;mic<MicrophoneProtocol.CHANNELS;mic++)if(frame.channelValid(mic)&&frame.peak[mic]>selectedPeak){selectedPeak=frame.peak[mic];selected=mic;}
    if(selected<0)return; dominantMic=selected;
    long framePeak=1;
    for(int sample=0;sample<MicrophoneProtocol.SAMPLES;sample++){
      int v=frame.samples[selected][sample];long mag=v==Integer.MIN_VALUE?2147483648L:Math.abs((long)v);if(mag>framePeak)framePeak=mag;
    }
    float wanted=constrain((cfg.monitorTargetPeak*2147483647.0f)/framePeak,1.0f,cfg.monitorMaxGain);
    automaticGain=automaticGain*(1.0f-cfg.monitorGainSmoothing)+wanted*cfg.monitorGainSmoothing;
    ByteBuffer pcm=ByteBuffer.allocate(MicrophoneProtocol.SAMPLES*2).order(ByteOrder.LITTLE_ENDIAN);
    for(int sample=0;sample<MicrophoneProtocol.SAMPLES;sample++){
      long amplified=(long)(frame.samples[selected][sample]*automaticGain);
      amplified=Math.max(Integer.MIN_VALUE,Math.min(Integer.MAX_VALUE,amplified));
      pcm.putShort((short)constrain((int)(amplified>>16),-32768,32767));
    }
    synchronized(lock){if(!running)return;while(queue.size()>=cfg.monitorQueueFrames)queue.removeFirst();queue.addLast(pcm.array());lock.notifyAll();}
  }

  void playbackLoop(){
    try{
      AudioFormat format=new AudioFormat((float)MicrophoneProtocol.SAMPLE_RATE,16,1,true,false);
      line=(SourceDataLine)AudioSystem.getLine(new DataLine.Info(SourceDataLine.class,format));line.open(format,cfg.monitorLineBufferBytes);line.start();stateKey="monitor.live";
      while(running){
        byte[] block=null;synchronized(lock){while(running&&queue.isEmpty())try{lock.wait(250);}catch(InterruptedException e){Thread.currentThread().interrupt();running=false;}if(!queue.isEmpty())block=queue.removeFirst();}
        if(block!=null&&line!=null)line.write(block,0,block.length);
      }
    }catch(Exception e){detail=safeMessage(e);stateKey="monitor.error";running=false;}
    finally{closeLine();synchronized(lock){queue.clear();}}
  }

  void closeLine(){SourceDataLine current=line;line=null;if(current!=null){try{if(current.isRunning())current.stop();}catch(Exception ignored){}current.close();}}
  String safeMessage(Exception e){String m=e.getMessage();return m==null||m.length()==0?e.getClass().getSimpleName():m;}
}

class RecordedWavPlayer {
  final MicrophoneConfig cfg;
  volatile boolean running=false;
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
    stop();if(file==null||!file.isFile()){noFile();return;}running=true;stateKey="playback.starting";detail="";fileName=file.getName();
    worker=new Thread(new Runnable(){public void run(){playback(file);}},"SynKinectMicrophones-WavPlayback");worker.setDaemon(true);worker.start();
  }
  void stop(){
    running=false;closeLine();Thread t=worker;worker=null;if(t!=null&&t!=Thread.currentThread())try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}
    if(!"playback.error".equals(stateKey)&&!"playback.no_file".equals(stateKey))stateKey="playback.idle";
  }

  void playback(File file){
    RandomAccessFile input=null;
    try{
      input=new RandomAccessFile(file,"r");WavDataRegion region=findDataRegion(input);input.seek(region.offset);
      AudioFormat format=new AudioFormat((float)MicrophoneProtocol.SAMPLE_RATE,16,1,true,false);
      line=(SourceDataLine)AudioSystem.getLine(new DataLine.Info(SourceDataLine.class,format));line.open(format,cfg.playbackLineBufferBytes);line.start();stateKey="playback.live";
      byte[] raw=new byte[MicrophoneProtocol.PAYLOAD_BYTES];long remaining=region.bytes;
      while(running&&remaining>0){
        int wanted=(int)Math.min(raw.length,remaining);int n=input.read(raw,0,wanted);if(n<0)break;remaining-=n;
        int frameBytes=MicrophoneProtocol.CHANNELS*MicrophoneProtocol.BYTES_PER_SAMPLE;int frames=n/frameBytes;if(frames<=0)continue;
        ByteBuffer src=ByteBuffer.wrap(raw,0,frames*frameBytes).order(ByteOrder.LITTLE_ENDIAN);
        int[][] channel=new int[MicrophoneProtocol.CHANNELS][frames];long[] peaks=new long[MicrophoneProtocol.CHANNELS];
        for(int i=0;i<frames;i++)for(int ch=0;ch<MicrophoneProtocol.CHANNELS;ch++){int v=src.getInt();channel[ch][i]=v;long mag=v==Integer.MIN_VALUE?2147483648L:Math.abs((long)v);if(mag>peaks[ch])peaks[ch]=mag;}
        int selected=0;for(int ch=1;ch<MicrophoneProtocol.CHANNELS;ch++)if(peaks[ch]>peaks[selected])selected=ch;
        float gain=constrain((cfg.monitorTargetPeak*2147483647.0f)/Math.max(1L,peaks[selected]),1.0f,cfg.monitorMaxGain);
        ByteBuffer out=ByteBuffer.allocate(frames*2).order(ByteOrder.LITTLE_ENDIAN);
        for(int v:channel[selected]){long amp=(long)(v*gain);amp=Math.max(Integer.MIN_VALUE,Math.min(Integer.MAX_VALUE,amp));out.putShort((short)constrain((int)(amp>>16),-32768,32767));}
        if(line!=null)line.write(out.array(),0,out.position());
      }
      if(running)stateKey="playback.finished";
    }catch(Exception e){stateKey="playback.error";detail=safeMessage(e);}
    finally{running=false;if(input!=null)try{input.close();}catch(IOException ignored){}closeLine();}
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
        formatOk=tag==1&&channels==MicrophoneProtocol.CHANNELS&&rate==MicrophoneProtocol.SAMPLE_RATE&&bits==32;
      }else if("data".equals(chunk)){dataOffset=file.getFilePointer();dataBytes=Math.min(size,file.length()-dataOffset);}
      file.seek(Math.min(next,file.length()));if(formatOk&&dataOffset>=0)break;
    }
    if(!formatOk||dataOffset<0||dataBytes<=0)throw new IOException("wav-format");return new WavDataRegion(dataOffset,dataBytes);
  }
  long readLE32(RandomAccessFile f)throws IOException{return (f.readUnsignedByte())|(long)f.readUnsignedByte()<<8|(long)f.readUnsignedByte()<<16|(long)f.readUnsignedByte()<<24;}
  void closeLine(){SourceDataLine current=line;line=null;if(current!=null){try{if(current.isRunning())current.stop();}catch(Exception ignored){}current.close();}}
  String safeMessage(Exception e){String m=e.getMessage();return m==null||m.length()==0?e.getClass().getSimpleName():m;}
}

class WavDataRegion { final long offset,bytes; WavDataRegion(long offset,long bytes){this.offset=offset;this.bytes=bytes;} }

class SpeakerSelfTest {
  final MicrophoneConfig cfg;
  volatile boolean running=false;
  volatile String stateKey="speaker.idle";
  volatile String detail="";
  Thread worker;SourceDataLine line;
  SpeakerSelfTest(MicrophoneConfig cfg){this.cfg=cfg;}
  boolean isRunning(){return running;}
  String state(){return stateKey;}
  String detail(){return detail;}

  void start(){if(running)return;running=true;stateKey="speaker.starting";detail="";worker=new Thread(new Runnable(){public void run(){playTone();}},"SynKinectMicrophones-SpeakerTest");worker.setDaemon(true);worker.start();}
  void stop(){running=false;closeLine();Thread t=worker;worker=null;if(t!=null&&t!=Thread.currentThread())try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}if(!"speaker.error".equals(stateKey))stateKey="speaker.idle";}
  void playTone(){
    try{
      int rate=MicrophoneProtocol.SAMPLE_RATE;AudioFormat format=new AudioFormat((float)rate,16,1,true,false);
      line=(SourceDataLine)AudioSystem.getLine(new DataLine.Info(SourceDataLine.class,format));line.open(format,cfg.speakerLineBufferBytes);line.start();
      int samples=max(1,rate*cfg.speakerDurationMs/1000);ByteBuffer tone=ByteBuffer.allocate(samples*2).order(ByteOrder.LITTLE_ENDIAN);
      for(int i=0;i<samples;i++){double edge=Math.min(i, samples-1-i);double envelope=Math.min(1.0,edge/max(1.0,cfg.speakerFadeSamples));short value=(short)(Math.sin(2.0*Math.PI*cfg.speakerFrequencyHz*i/rate)*cfg.speakerAmplitude*envelope);tone.putShort(value);}
      stateKey="speaker.live";if(line!=null)line.write(tone.array(),0,tone.position());if(line!=null)line.drain();stateKey="speaker.done";
    }catch(Exception e){stateKey="speaker.error";detail=safeMessage(e);}
    finally{running=false;closeLine();}
  }
  void closeLine(){SourceDataLine current=line;line=null;if(current!=null){try{current.stop();}catch(Exception ignored){}current.close();}}
  String safeMessage(Exception e){String m=e.getMessage();return m==null||m.length()==0?e.getClass().getSimpleName():m;}
}
