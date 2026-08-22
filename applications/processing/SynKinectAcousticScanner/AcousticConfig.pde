class AcousticConfig {
  String language="en-US";
  int uiFrameRate=30,workerJoinMs=1200,reconnectMs=300,pipeOpenAttempts=4,pipeOpenRetryMs=75,noFrameWarningMs=2000,connectionStaleMs=3500;
  String uiFontFamily="Segoe UI",uiHeadingFontFamily="Segoe UI Semibold",uiFontFallback="Arial";
  boolean allowMonitorPipeFallback=true;
  float soundSpeedMps=343.0f,minimumRms=0.0025f,occupancyDecay=0.92f;
  float[] microphoneXM={-0.113f,0.036f,0.076f,0.113f};

  void load(File file){
    if(file==null||!file.isFile())return;
    Properties p=new Properties();Reader r=null;
    try{
      r=new InputStreamReader(new FileInputStream(file),"UTF-8");p.load(r);
      language=textValue(p,"app.language",language);
      uiFrameRate=intValue(p,"ui.frameRate",uiFrameRate,10,120);
      uiFontFamily=textValue(p,"ui.font.family",uiFontFamily);
      uiHeadingFontFamily=textValue(p,"ui.font.headingFamily",uiHeadingFontFamily);
      uiFontFallback=textValue(p,"ui.font.fallback",uiFontFallback);
      workerJoinMs=intValue(p,"lifecycle.workerJoinMs",workerJoinMs,250,10000);
      reconnectMs=intValue(p,"transport.reconnectMs",reconnectMs,50,5000);
      pipeOpenAttempts=intValue(p,"transport.pipeOpenAttempts",pipeOpenAttempts,1,20);
      pipeOpenRetryMs=intValue(p,"transport.pipeOpenRetryMs",pipeOpenRetryMs,10,1000);
      noFrameWarningMs=intValue(p,"transport.noFrameWarningMs",noFrameWarningMs,250,30000);
      connectionStaleMs=intValue(p,"transport.connectionStaleMs",connectionStaleMs,500,30000);
      allowMonitorPipeFallback=boolValue(p,"transport.allowMonitorPipeFallback",allowMonitorPipeFallback);
      soundSpeedMps=floatValue(p,"scan.soundSpeedMps",soundSpeedMps,250,400);
      minimumRms=floatValue(p,"scan.minimumRms",minimumRms,0,0.5f);
      occupancyDecay=floatValue(p,"scan.occupancyDecay",occupancyDecay,0,0.9999f);
      float[] parsed=floatList(p.getProperty("geometry.microphoneXM"),4);
      if(parsed!=null)microphoneXM=parsed;
    }catch(Exception e){println("acoustic-config:"+safeMessage(e));}
    finally{if(r!=null)try{r.close();}catch(IOException ignored){}}
  }
  float[] floatList(String value,int count){
    if(value==null)return null;String[] parts=value.split(",");if(parts.length!=count)return null;float[] out=new float[count];
    try{for(int i=0;i<count;i++)out[i]=Float.parseFloat(parts[i].trim());return out;}catch(Exception e){return null;}
  }
  String textValue(Properties p,String k,String f){String v=p.getProperty(k);return v==null||v.trim().length()==0?f:v.trim();}
  int intValue(Properties p,String k,int f,int lo,int hi){try{return Math.max(lo,Math.min(hi,Integer.parseInt(textValue(p,k,String.valueOf(f)))));}catch(Exception e){return f;}}
  boolean boolValue(Properties p,String k,boolean f){String v=p.getProperty(k);if(v==null)return f;v=v.trim();if("true".equalsIgnoreCase(v)||"1".equals(v))return true;if("false".equalsIgnoreCase(v)||"0".equals(v))return false;return f;}
  float floatValue(Properties p,String k,float f,float lo,float hi){try{return Math.max(lo,Math.min(hi,Float.parseFloat(textValue(p,k,String.valueOf(f)))));}catch(Exception e){return f;}}
  String safeMessage(Exception e){String m=e.getMessage();return m==null||m.length()==0?e.getClass().getSimpleName():m;}
}
