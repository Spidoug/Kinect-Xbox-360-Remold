class SurveillanceConfig {
  String language = "en-US";
  int uiFrameRate = 30;
  String uiFontFamily = "Segoe UI";
  String uiHeadingFontFamily = "Segoe UI Semibold";
  String uiFontFallback = "Arial";
  int workerJoinMs = 1800;
  long streamStaleMs = 1500;
  long connectionStaleMs = 3000;
  int reconnectMs = 250;

  int motionSampleStep = 8;
  int motionIrDelta = 26;
  int motionRgbDelta = 24;
  float motionMinimumChangedRatio = 0.025f;
  int motionArmFrames = 3;
  int motionWarmupFrames = 10;
  long motionStopAfterMs = 60000;

  boolean lowLightFallbackEnabled = true;
  int lowLightLumaThreshold = 42;
  int lowLightSampleStep = 8;
  int lowLightWarmupFrames = 8;
  int lowLightDarkFrames = 6;

  boolean timestampEnabled = true;
  String timestampFormat = "yyyy-MM-dd HH:mm:ss";
  int timestampMargin = 14;

  int recordFps = 15;
  float recordJpegQuality = 0.86f;
  int recordFrameHoldMs = 1500;
  int recordCheckpointFrames = 30;
  String recordDirectory = "recordings";

  void load(File file) {
    Properties p = readProperties(file);
    if (p == null) return;
    language = textValue(p,"app.language",language);
    uiFrameRate = intValue(p,"ui.frameRate",uiFrameRate,10,60);
    uiFontFamily = textValue(p,"ui.font.family",uiFontFamily);
    uiHeadingFontFamily = textValue(p,"ui.font.headingFamily",uiHeadingFontFamily);
    uiFontFallback = textValue(p,"ui.font.fallback",uiFontFallback);
    workerJoinMs = intValue(p,"lifecycle.workerJoinMs",workerJoinMs,250,10000);
    streamStaleMs = longValue(p,"transport.streamStaleMs",streamStaleMs,100,30000);
    connectionStaleMs = longValue(p,"transport.connectionStaleMs",connectionStaleMs,streamStaleMs,60000);
    reconnectMs = intValue(p,"transport.reconnectMs",reconnectMs,50,5000);

    motionSampleStep = intValue(p,"motion.sampleStep",motionSampleStep,1,32);
    motionIrDelta = intValue(p,"motion.irDelta",motionIrDelta,1,1023);
    motionRgbDelta = intValue(p,"motion.rgbDelta",motionRgbDelta,1,255);
    motionMinimumChangedRatio = floatValue(p,"motion.minimumChangedRatio",motionMinimumChangedRatio,0.001f,0.95f);
    motionArmFrames = intValue(p,"motion.armFrames",motionArmFrames,1,30);
    motionWarmupFrames = intValue(p,"motion.warmupFrames",motionWarmupFrames,0,120);
    motionStopAfterMs = longValue(p,"motion.stopAfterMs",motionStopAfterMs,1000,3600000);

    lowLightFallbackEnabled = boolValue(p,"lowLight.enabled",lowLightFallbackEnabled);
    lowLightLumaThreshold = intValue(p,"lowLight.lumaThreshold",lowLightLumaThreshold,1,254);
    lowLightSampleStep = intValue(p,"lowLight.sampleStep",lowLightSampleStep,1,32);
    lowLightWarmupFrames = intValue(p,"lowLight.warmupFrames",lowLightWarmupFrames,1,120);
    lowLightDarkFrames = intValue(p,"lowLight.darkFrames",lowLightDarkFrames,1,60);

    timestampEnabled = boolValue(p,"overlay.timestamp.enabled",timestampEnabled);
    timestampFormat = textValue(p,"overlay.timestamp.format",timestampFormat);
    timestampMargin = intValue(p,"overlay.timestamp.margin",timestampMargin,4,64);

    recordFps = intValue(p,"record.fps",recordFps,1,30);
    recordJpegQuality = floatValue(p,"record.jpegQuality",recordJpegQuality,0.10f,1.0f);
    recordFrameHoldMs = intValue(p,"record.frameHoldMs",recordFrameHoldMs,100,10000);
    recordCheckpointFrames = intValue(p,"record.checkpointFrames",recordCheckpointFrames,1,300);
    recordDirectory = textValue(p,"record.directory",recordDirectory);

  }

  File recordingsRoot() {
    File f=new File(recordDirectory);
    return f.isAbsolute()?f:new File(sketchPath(recordDirectory));
  }

  Properties readProperties(File file) {
    if(file==null||!file.isFile()) return null;
    Properties p=new Properties(); Reader r=null;
    try { r=new InputStreamReader(new FileInputStream(file),"UTF-8"); p.load(r); return p; }
    catch(Exception e){ println("config:"+e.getMessage()); return null; }
    finally { if(r!=null) try{r.close();}catch(IOException ignored){} }
  }
  String textValue(Properties p,String k,String d){String v=p.getProperty(k);return v==null||v.trim().length()==0?d:v.trim();}
  boolean boolValue(Properties p,String k,boolean d){String v=p.getProperty(k);if(v==null)return d;v=v.trim();if("true".equalsIgnoreCase(v)||"1".equals(v))return true;if("false".equalsIgnoreCase(v)||"0".equals(v))return false;return d;}
  int intValue(Properties p,String k,int d,int lo,int hi){try{return constrain(Integer.parseInt(textValue(p,k,String.valueOf(d))),lo,hi);}catch(Exception e){return d;}}
  long longValue(Properties p,String k,long d,long lo,long hi){try{long v=Long.parseLong(textValue(p,k,String.valueOf(d)));return Math.max(lo,Math.min(hi,v));}catch(Exception e){return d;}}
  float floatValue(Properties p,String k,float d,float lo,float hi){try{return constrain(Float.parseFloat(textValue(p,k,String.valueOf(d))),lo,hi);}catch(Exception e){return d;}}
}
