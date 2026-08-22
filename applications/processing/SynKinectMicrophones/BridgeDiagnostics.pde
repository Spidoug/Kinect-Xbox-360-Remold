class BridgeDiagnostics {
  final MicrophoneConfig cfg;
  final HashMap<String,String> values=new HashMap<String,String>();
  long nextRefreshMs=0;
  volatile boolean available=false;
  volatile String readError="";

  BridgeDiagnostics(MicrophoneConfig cfg){this.cfg=cfg;}

  void refresh(){
    long now=System.currentTimeMillis();if(now<nextRefreshMs)return;nextRefreshMs=now+cfg.diagnosticsRefreshMs;
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
    if(LocalTransport.isLinux())return new File("/run/kinect360-remold/audio-bridge-status.txt");
    String root=environmentPath("ProgramData");
    if(root==null)root=environmentPath("ALLUSERSPROFILE");
    return root==null?null:new File(new File(root,cfg.diagnosticsDirectory),cfg.diagnosticsFile);
  }

  String environmentPath(String name){String value=System.getenv(name);if(value==null)return null;value=value.trim();return value.length()==0?null:value;}
  String get(String key,String fallback){synchronized(values){String v=values.get(key);return v==null?fallback:v;}}
  long number(String key){try{return Long.parseLong(get(key,"0"));}catch(Exception e){return 0;}}
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
      if(captureRate()==MicrophoneProtocol.SAMPLE_RATE&&captureChannels()>=MicrophoneProtocol.CHANNELS&&published()>0)return "diag.ok";
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
