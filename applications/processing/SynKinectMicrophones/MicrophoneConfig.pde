class MicrophoneConfig {
  String language = "en-US";
  int uiFrameRate = 30;
  String uiFontFamily = "Segoe UI";
  String uiHeadingFontFamily = "Segoe UI Semibold";
  String uiFontFallback = "Arial";
  int workerJoinMs = 1200;
  int reconnectMs = 300;
  int pipeOpenAttempts = 4;
  int pipeOpenRetryMs = 75;
  boolean allowAcousticPipeFallback = true;
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
    if (file == null || !file.isFile()) return;
    Properties p = new Properties();
    Reader reader = null;
    try {
      reader = new InputStreamReader(new FileInputStream(file), "UTF-8");
      p.load(reader);
      language = textValue(p,"app.language",language);
      uiFrameRate = intValue(p,"ui.frameRate",uiFrameRate,10,120);
      uiFontFamily = textValue(p,"ui.font.family",uiFontFamily);
      uiHeadingFontFamily = textValue(p,"ui.font.headingFamily",uiHeadingFontFamily);
      uiFontFallback = textValue(p,"ui.font.fallback",uiFontFallback);
      workerJoinMs = intValue(p,"lifecycle.workerJoinMs",workerJoinMs,250,10000);
      reconnectMs = intValue(p,"transport.reconnectMs",reconnectMs,50,5000);
      pipeOpenAttempts = intValue(p,"transport.pipeOpenAttempts",pipeOpenAttempts,1,20);
      pipeOpenRetryMs = intValue(p,"transport.pipeOpenRetryMs",pipeOpenRetryMs,10,1000);
      allowAcousticPipeFallback = boolValue(p,"transport.allowAcousticPipeFallback",allowAcousticPipeFallback);
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
    } catch(Exception e) {
      println("microphone-config:"+safeMessage(e));
    } finally {
      if(reader!=null) try{reader.close();}catch(IOException ignored){}
    }
  }

  String textValue(Properties p,String key,String fallback){String v=p.getProperty(key);return v==null||v.trim().length()==0?fallback:v.trim();}
  boolean boolValue(Properties p,String key,boolean fallback){String v=p.getProperty(key);if(v==null)return fallback;v=v.trim();if("true".equalsIgnoreCase(v)||"1".equals(v))return true;if("false".equalsIgnoreCase(v)||"0".equals(v))return false;return fallback;}
  int intValue(Properties p,String key,int fallback,int lo,int hi){try{return constrain(Integer.parseInt(textValue(p,key,String.valueOf(fallback))),lo,hi);}catch(Exception e){return fallback;}}
  float floatValue(Properties p,String key,float fallback,float lo,float hi){try{return constrain(Float.parseFloat(textValue(p,key,String.valueOf(fallback))),lo,hi);}catch(Exception e){return fallback;}}
  String safeMessage(Exception e){String m=e.getMessage();return m==null||m.length()==0?e.getClass().getSimpleName():m;}
}
