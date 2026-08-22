class RecordedVideoFrame {
  final int[] pixels;
  final int width,height;
  final long capturedEpochMs;
  final String videoMode;

  RecordedVideoFrame(int[] pixels,int width,int height,long capturedEpochMs,String videoMode){
    this.pixels=pixels;
    this.width=width;
    this.height=height;
    this.capturedEpochMs=capturedEpochMs;
    this.videoMode=videoMode;
  }
}

class MotionAviRecorder {
  final SurveillanceConfig cfg;
  final Object latestFrameLock=new Object();
  volatile boolean active=false,lowLightFallback=false,failed=false;
  volatile float lowLightLuma=-1;
  volatile String lastVideoMode="IR",lastError="";
  volatile long sourceFramesSubmitted=0,framesWritten=0,heldFrames=0,staleFrames=0;
  Thread worker;
  MjpegAviWriter writer;
  RecordedVideoFrame latestFrame;
  File sessionDir,videoFile,partialVideoFile;
  long sessionStartedEpochMs=0,videoStartedEpochMs=0,sessionStoppedEpochMs=0,lastSubmitMs=0;

  MotionAviRecorder(SurveillanceConfig cfg){this.cfg=cfg;}

  synchronized void startSession(PImage triggerIr)throws Exception{
    if(active)return;
    File root=cfg.recordingsRoot();
    if(!root.exists()&&!root.mkdirs())throw new IOException("cannot create "+root);
    sessionStartedEpochMs=System.currentTimeMillis();
    sessionStoppedEpochMs=0;
    String stamp=new SimpleDateFormat("yyyyMMdd-HHmmss",Locale.ROOT).format(new Date(sessionStartedEpochMs));
    sessionDir=uniqueEventDirectory(root,"event-"+stamp);
    if(!sessionDir.mkdirs())throw new IOException("cannot create "+sessionDir);

    videoFile=new File(sessionDir,"surveillance-motion.avi");
    partialVideoFile=new File(sessionDir,"surveillance-motion.avi.partial");
    writer=new MjpegAviWriter(partialVideoFile,SurveillanceProtocol.WIDTH,SurveillanceProtocol.HEIGHT,cfg.recordFps,cfg.recordCheckpointFrames);
    lowLightFallback=false;
    lowLightLuma=-1;
    lastVideoMode="IR";
    lastError="";
    failed=false;
    sourceFramesSubmitted=0;
    framesWritten=0;
    heldFrames=0;
    staleFrames=0;
    lastSubmitMs=0;

    int[] seedPixels=new int[SurveillanceProtocol.WIDTH*SurveillanceProtocol.HEIGHT];
    String seedMode="WAITING";
    if(triggerIr!=null&&triggerIr.width==SurveillanceProtocol.WIDTH&&triggerIr.height==SurveillanceProtocol.HEIGHT){
      triggerIr.loadPixels();
      seedPixels=Arrays.copyOf(triggerIr.pixels,triggerIr.pixels.length);
      seedMode="IR";
      byte[] jpg=encodeJpegStamped(seedPixels,triggerIr.width,triggerIr.height,cfg.recordJpegQuality,cfg,sessionStartedEpochMs,"IR");
      writeBytes(new File(sessionDir,"trigger-ir.jpg"),jpg);
    }
    synchronized(latestFrameLock){latestFrame=new RecordedVideoFrame(seedPixels,SurveillanceProtocol.WIDTH,SurveillanceProtocol.HEIGHT,sessionStartedEpochMs,seedMode);}

    videoStartedEpochMs=System.currentTimeMillis();
    active=true;
    writeEventMetadata("recording",videoStartedEpochMs);
    worker=new Thread(new Runnable(){public void run(){recordLoop();}},"SynKinectSurveillance-Recorder");
    worker.setDaemon(true);
    worker.start();
  }

  File uniqueEventDirectory(File root,String base){
    File first=new File(root,base);
    if(!first.exists())return first;
    for(int i=2;i<10000;i++){
      File candidate=new File(root,base+"-"+String.format(Locale.ROOT,"%03d",i));
      if(!candidate.exists())return candidate;
    }
    return new File(root,base+"-"+System.currentTimeMillis());
  }

  void submit(PImage image,String mode,long epochMs){
    if(!active||image==null)return;
    long now=millis64();
    long minInterval=Math.max(1,1000L/Math.max(1,cfg.recordFps*2));
    if(now-lastSubmitMs<minInterval)return;
    lastSubmitMs=now;
    image.loadPixels();
    if(image.width!=SurveillanceProtocol.WIDTH||image.height!=SurveillanceProtocol.HEIGHT||image.pixels.length!=SurveillanceProtocol.WIDTH*SurveillanceProtocol.HEIGHT)return;
    int[] copy=Arrays.copyOf(image.pixels,image.pixels.length);
    RecordedVideoFrame frame=new RecordedVideoFrame(copy,image.width,image.height,epochMs,mode==null?"VIDEO":mode);
    synchronized(latestFrameLock){latestFrame=frame;}
    sourceFramesSubmitted++;
    lastVideoMode=frame.videoMode;
  }

  synchronized void markLowLightFallback(float luma){
    lowLightFallback=true;
    lowLightLuma=luma;
    lastVideoMode="IR_LOW_LIGHT";
    writeEventMetadata("recording",System.currentTimeMillis());
  }

  RecordedVideoFrame snapshotLatest(){
    synchronized(latestFrameLock){return latestFrame;}
  }

  void recordLoop(){
    boolean success=false;
    try{
      final long startNano=System.nanoTime();
      final long timelineEpochMs=videoStartedEpochMs>0?videoStartedEpochMs:sessionStartedEpochMs;
      long frameIndex=0;
      while(true){
        long targetEpochMs=timelineEpochMs+(frameIndex*1000L)/Math.max(1,cfg.recordFps);
        if(!active&&sessionStoppedEpochMs>0&&targetEpochMs>sessionStoppedEpochMs)break;

        long targetNano=startNano+(frameIndex*1000000000L)/Math.max(1,cfg.recordFps);
        long waitNs=targetNano-System.nanoTime();
        if(active&&waitNs>0){
          try{
            long waitMs=waitNs/1000000L;
            int waitExtraNs=(int)(waitNs%1000000L);
            Thread.sleep(waitMs,waitExtraNs);
          }catch(InterruptedException e){
            if(!active)continue;
            Thread.currentThread().interrupt();
            throw new IOException("recorder interrupted");
          }
        }

        RecordedVideoFrame frame=snapshotLatest();
        if(frame!=null&&writer!=null){
          long ageMs=Math.max(0,targetEpochMs-frame.capturedEpochMs);
          String mode=frame.videoMode;
          if(ageMs>cfg.recordFrameHoldMs){
            mode=mode+" · STALE";
            staleFrames++;
          }else if(ageMs>Math.max(100,2000/Math.max(1,cfg.recordFps))){
            heldFrames++;
          }
          byte[] jpg=encodeJpegStamped(frame.pixels,frame.width,frame.height,cfg.recordJpegQuality,cfg,targetEpochMs,mode);
          writer.addFrame(jpg);
          framesWritten++;
          lastVideoMode=frame.videoMode;
        }
        frameIndex++;
      }
      success=true;
    }catch(Exception e){
      failed=true;
      lastError=safeMessage(e);
      println("recorder:"+lastError);
    }finally{
      active=false;
      closeAndFinalizeWriter(success&&!failed);
    }
  }

  void stopSession(){
    Thread t;
    synchronized(this){
      if(!active&&worker==null){
        if(sessionDir!=null)writeEventMetadata(failed?"error":"complete",sessionStoppedEpochMs>0?sessionStoppedEpochMs:System.currentTimeMillis());
        return;
      }
      sessionStoppedEpochMs=System.currentTimeMillis();
      active=false;
      t=worker;
    }
    if(t!=null&&t!=Thread.currentThread()){
      try{
        t.join(Math.max(5000L,cfg.workerJoinMs*4L));
        if(t.isAlive()){
          t.interrupt();
          t.join(Math.max(1000L,cfg.workerJoinMs));
        }
      }catch(InterruptedException e){Thread.currentThread().interrupt();}
    }
    synchronized(this){if(worker==t)worker=null;}
    if(sessionDir!=null)writeEventMetadata(failed?"error":"complete",sessionStoppedEpochMs>0?sessionStoppedEpochMs:System.currentTimeMillis());
  }

  synchronized void closeAndFinalizeWriter(boolean success){
    MjpegAviWriter current=writer;
    writer=null;
    if(current!=null){
      try{current.close();}
      catch(Exception e){failed=true;lastError=safeMessage(e);println("avi-close:"+lastError);success=false;}
    }
    if(success&&partialVideoFile!=null&&partialVideoFile.isFile()){
      if(videoFile.exists()&&!videoFile.delete()){failed=true;lastError="cannot replace "+videoFile.getName();return;}
      if(!partialVideoFile.renameTo(videoFile)){failed=true;lastError="cannot finalize "+videoFile.getName();}
    }
  }

  boolean hasFailed(){return failed;}
  String failureMessage(){return lastError==null?"":lastError;}
  void shutdown(){stopSession();}

  void writeBytes(File file,byte[] data)throws IOException{
    FileOutputStream out=new FileOutputStream(file);
    try{out.write(data);out.getFD().sync();}
    finally{out.close();}
  }

  void writeEventMetadata(String state,long epochMs){
    if(sessionDir==null)return;
    Properties p=new Properties();
    p.setProperty("state",state);
    p.setProperty("started.epochMs",String.valueOf(sessionStartedEpochMs));
    p.setProperty("updated.epochMs",String.valueOf(epochMs));
    p.setProperty("video.started.epochMs",String.valueOf(videoStartedEpochMs));
    p.setProperty("started.local",formatSurveillanceTimestamp(sessionStartedEpochMs));
    p.setProperty("updated.local",formatSurveillanceTimestamp(epochMs));
    if(videoStartedEpochMs>0)p.setProperty("video.started.local",formatSurveillanceTimestamp(videoStartedEpochMs));
    p.setProperty("video.mode",lastVideoMode);
    p.setProperty("video.fps",String.valueOf(cfg.recordFps));
    p.setProperty("video.framesWritten",String.valueOf(framesWritten));
    p.setProperty("video.sourceFramesSubmitted",String.valueOf(sourceFramesSubmitted));
    p.setProperty("video.heldFrames",String.valueOf(heldFrames));
    p.setProperty("video.staleFrames",String.valueOf(staleFrames));
    p.setProperty("video.timeline","constant-frame-rate");
    p.setProperty("lowLight.fallback",String.valueOf(lowLightFallback));
    if(lowLightLuma>=0)p.setProperty("lowLight.rgbLuma",String.format(Locale.ROOT,"%.2f",lowLightLuma));
    if(videoFile!=null)p.setProperty("video",videoFile.getName());
    if(partialVideoFile!=null&&partialVideoFile.exists())p.setProperty("video.partial",partialVideoFile.getName());
    if(lastError!=null&&lastError.length()>0)p.setProperty("error",lastError);
    Writer out=null;
    try{
      out=new OutputStreamWriter(new FileOutputStream(new File(sessionDir,"event.properties")),"UTF-8");
      p.store(out,"SynKinect Surveillance event");
    }catch(Exception e){println("event-meta:"+safeMessage(e));}
    finally{if(out!=null)try{out.close();}catch(IOException ignored){}}
  }
}

class AviIndexEntry {
  final long offset;
  final int size;
  AviIndexEntry(long offset,int size){this.offset=offset;this.size=size;}
}

class MjpegAviWriter {
  final RandomAccessFile out;
  final int width,height,fps,checkpointFrames;
  final ArrayList<AviIndexEntry> index=new ArrayList<AviIndexEntry>();
  long riffSizePos,totalFramesPos,streamLengthPos,moviSizePos,moviTypeStart,moviDataStart;
  boolean closed=false;

  MjpegAviWriter(File file,int width,int height,int fps,int checkpointFrames)throws IOException{
    this.width=width;
    this.height=height;
    this.fps=fps;
    this.checkpointFrames=Math.max(1,checkpointFrames);
    out=new RandomAccessFile(file,"rw");
    out.setLength(0);
    writeHeader();
  }

  void writeHeader()throws IOException{
    fourcc("RIFF");riffSizePos=out.getFilePointer();u32(0);fourcc("AVI ");
    fourcc("LIST");long hdrlSizePos=out.getFilePointer();u32(0);fourcc("hdrl");
    fourcc("avih");u32(56);u32((1000000L+Math.max(1,fps)/2)/Math.max(1,fps));u32(0);u32(0);u32(0x10);totalFramesPos=out.getFilePointer();u32(0);u32(0);u32(1);u32(width*height*3L);u32(width);u32(height);for(int i=0;i<4;i++)u32(0);
    fourcc("LIST");long strlSizePos=out.getFilePointer();u32(0);fourcc("strl");
    fourcc("strh");u32(56);fourcc("vids");fourcc("MJPG");u32(0);u16(0);u16(0);u32(0);u32(1);u32(fps);u32(0);streamLengthPos=out.getFilePointer();u32(0);u32(width*height*3L);u32(0xFFFFFFFFL);u32(0);u16(0);u16(0);u16(width);u16(height);
    fourcc("strf");u32(40);u32(40);u32(width);u32(height);u16(1);u16(24);fourcc("MJPG");u32(width*height*3L);u32(0);u32(0);u32(0);u32(0);
    long afterStrl=out.getFilePointer();
    patchU32(strlSizePos,afterStrl-(strlSizePos+4));
    patchU32(hdrlSizePos,afterStrl-(hdrlSizePos+4));
    out.seek(afterStrl);
    fourcc("LIST");moviSizePos=out.getFilePointer();u32(0);moviTypeStart=out.getFilePointer();fourcc("movi");moviDataStart=out.getFilePointer();
  }

  synchronized void addFrame(byte[] jpeg)throws IOException{
    if(closed||jpeg==null||jpeg.length==0)return;
    long chunk=out.getFilePointer();
    long rel=chunk-moviTypeStart;
    if(rel<0||rel>0xFFFFFFFFL)throw new IOException("AVI 1.0 index offset overflow");
    if(out.getFilePointer()+8L+jpeg.length+1L>0xFFFFFF00L)throw new IOException("AVI 1.0 file size limit reached");
    fourcc("00dc");u32(jpeg.length);out.write(jpeg);if((jpeg.length&1)!=0)out.write(0);
    index.add(new AviIndexEntry(rel,jpeg.length));
    if(index.size()%checkpointFrames==0)checkpoint();
  }

  synchronized void checkpoint()throws IOException{
    if(closed)return;
    long cur=out.getFilePointer();
    patchU32(moviSizePos,cur-(moviSizePos+4));
    patchU32(totalFramesPos,index.size());
    patchU32(streamLengthPos,index.size());
    patchU32(riffSizePos,cur-8);
    out.seek(cur);
    out.getFD().sync();
  }

  synchronized void close()throws IOException{
    if(closed)return;
    IOException failure=null;
    try{
      long moviEnd=out.getFilePointer();
      patchU32(moviSizePos,moviEnd-(moviSizePos+4));
      out.seek(moviEnd);
      long indexBytes=index.size()*16L;
      if(indexBytes>0xFFFFFFFFL)throw new IOException("AVI index too large");
      fourcc("idx1");u32(indexBytes);
      for(AviIndexEntry e:index){fourcc("00dc");u32(0x10);u32(e.offset);u32(e.size);}
      long end=out.getFilePointer();
      if(end-8>0xFFFFFFFFL)throw new IOException("AVI RIFF size overflow");
      patchU32(totalFramesPos,index.size());
      patchU32(streamLengthPos,index.size());
      patchU32(riffSizePos,end-8);
      out.seek(end);
      out.getFD().sync();
    }catch(IOException e){failure=e;}
    finally{
      closed=true;
      try{out.close();}catch(IOException e){if(failure==null)failure=e;}
    }
    if(failure!=null)throw failure;
  }

  void fourcc(String s)throws IOException{if(s.length()!=4)throw new IOException("fourcc");for(int i=0;i<4;i++)out.write((byte)s.charAt(i));}
  void u16(long v)throws IOException{out.write((int)(v&255));out.write((int)((v>>8)&255));}
  void u32(long v)throws IOException{out.write((int)(v&255));out.write((int)((v>>8)&255));out.write((int)((v>>16)&255));out.write((int)((v>>24)&255));}
  void patchU32(long pos,long value)throws IOException{long cur=out.getFilePointer();out.seek(pos);u32(value);out.seek(cur);}
}

byte[] encodeJpegStamped(int[] pixels,int w,int h,float quality,SurveillanceConfig cfg,long epochMs,String mode)throws IOException{
  BufferedImage image=new BufferedImage(w,h,BufferedImage.TYPE_INT_RGB);
  image.setRGB(0,0,w,h,pixels,0,w);
  if(cfg.timestampEnabled){
    java.awt.Graphics2D g=image.createGraphics();
    try{
      g.setRenderingHint(java.awt.RenderingHints.KEY_TEXT_ANTIALIASING,java.awt.RenderingHints.VALUE_TEXT_ANTIALIAS_ON);
      String stamp=formatSurveillanceTimestamp(epochMs);
      String label=(mode==null||mode.length()==0)?stamp:(mode+"  ·  "+stamp);
      java.awt.Font font=new java.awt.Font(cfg.uiFontFamily,java.awt.Font.BOLD,18);
      g.setFont(font);
      java.awt.FontMetrics fm=g.getFontMetrics();
      int pad=8,boxW=fm.stringWidth(label)+pad*2,boxH=fm.getHeight()+6;
      int x=Math.max(cfg.timestampMargin,w-cfg.timestampMargin-boxW),y=Math.max(cfg.timestampMargin,h-cfg.timestampMargin-boxH);
      g.setColor(new java.awt.Color(0,0,0,178));g.fillRoundRect(x,y,boxW,boxH,8,8);
      g.setColor(java.awt.Color.WHITE);g.drawString(label,x+pad,y+boxH-fm.getDescent()-3);
    }finally{g.dispose();}
  }
  ByteArrayOutputStream bytes=new ByteArrayOutputStream(Math.max(16384,w*h/3));
  Iterator<ImageWriter> writers=ImageIO.getImageWritersByFormatName("jpeg");
  if(!writers.hasNext())throw new IOException("JPEG writer unavailable");
  ImageWriter writer=writers.next();
  ImageOutputStream ios=ImageIO.createImageOutputStream(bytes);
  try{
    writer.setOutput(ios);
    JPEGImageWriteParam p=new JPEGImageWriteParam(Locale.ROOT);
    p.setCompressionMode(JPEGImageWriteParam.MODE_EXPLICIT);
    p.setCompressionQuality(Math.max(0.1f,Math.min(1.0f,quality)));
    writer.write(null,new IIOImage(image,null,null),p);
    ios.flush();
    return bytes.toByteArray();
  }finally{
    try{ios.close();}catch(Exception ignored){}
    writer.dispose();
  }
}
