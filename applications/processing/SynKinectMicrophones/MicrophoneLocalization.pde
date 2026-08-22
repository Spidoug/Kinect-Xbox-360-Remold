class MicrophoneI18n {
  final ArrayList<String> supported=new ArrayList<String>();
  final HashMap<String,Properties> catalogs=new HashMap<String,Properties>();
  String fallbackLanguage="";
  String language="";
  boolean rtl=false;

  MicrophoneI18n(String requested){
    discoverCatalogs();
    language=resolve(requested); refreshDirection();
  }

  void discoverCatalogs(){
    File directory=new File(dataPath("i18n_2"));
    File[] files=directory.listFiles();
    if(files==null)return;
    ArrayList<File> catalogFiles=new ArrayList<File>();
    for(File file:files)if(file.isFile()&&file.getName().toLowerCase(Locale.ROOT).endsWith(".properties"))catalogFiles.add(file);
    Collections.sort(catalogFiles,new Comparator<File>(){public int compare(File a,File b){return a.getName().compareToIgnoreCase(b.getName());}});
    for(File file:catalogFiles){
      Properties catalog=load(file);
      String fileName=file.getName();
      String inferred=fileName.substring(0,fileName.length()-".properties".length());
      String locale=catalog.getProperty("meta.locale",inferred).trim();
      if(locale.length()==0||catalogs.containsKey(locale))continue;
      supported.add(locale);catalogs.put(locale,catalog);
      if("true".equalsIgnoreCase(catalog.getProperty("meta.default","false")))fallbackLanguage=locale;
    }
    if(fallbackLanguage.length()==0&&supported.size()>0)fallbackLanguage=supported.get(0);
  }

  Properties load(File file){
    Properties p=new Properties(); Reader reader=null;
    try{
      reader=new InputStreamReader(new FileInputStream(file),"UTF-8");
      p.load(reader);
    }catch(Exception e){println("microphone-i18n:"+file.getName()+":"+safeMessage(e));}
    finally{if(reader!=null)try{reader.close();}catch(IOException ignored){}}
    return p;
  }

  String resolve(String requested){
    if(supported.size()==0)return "";
    String value=requested==null?"auto":requested.trim();
    if(value.length()==0||value.equalsIgnoreCase("auto"))value=Locale.getDefault().toLanguageTag();
    for(String locale:supported)if(locale.equalsIgnoreCase(value))return locale;
    String prefix=value.toLowerCase(Locale.ROOT).split("[-_]")[0];
    for(String locale:supported)if(locale.toLowerCase(Locale.ROOT).split("[-_]")[0].equals(prefix))return locale;
    return fallbackLanguage;
  }

  String raw(String key,String fallback){
    Properties a=catalogs.get(language);String value=a==null?null:a.getProperty(key);
    if(value==null&&fallbackLanguage.length()>0){Properties base=catalogs.get(fallbackLanguage);value=base==null?null:base.getProperty(key);}
    return value==null?fallback:value;
  }
  String tr(String key){return raw(key,key);}
  String format(String key,Object...args){try{return String.format(Locale.ROOT,tr(key),args);}catch(Exception e){return tr(key);}}
  void toggle(){if(supported.size()<=1)return;int index=supported.indexOf(language);language=supported.get((index+1+supported.size())%supported.size());refreshDirection();}
  void refreshDirection(){rtl="rtl".equalsIgnoreCase(raw("meta.direction","ltr"));}
  String shortLanguage(){String compact=raw("meta.short",language);return compact==null||compact.trim().length()==0?language:compact.trim();}
  int startAlign(){return rtl?RIGHT:LEFT;}
  String safeMessage(Exception e){String m=e.getMessage();return m==null||m.length()==0?e.getClass().getSimpleName():m;}
}

class MicrophoneTheme {
  static final int WINDOW_W=1320, WINDOW_H=900;
  static final int BG=0xFF11151A, SURFACE=0xFF181E25, SURFACE_ALT=0xFF202832, RAISED=0xFF293440;
  static final int BORDER=0xFF35414D, TEXT=0xFFF4F7FA, MUTED=0xFFAAB6C2, ACTIVE=0xFF68A9E8, DIM=0xFF6F7C88;
  static final int GOOD=0xFF7CC7A0, WARN=0xFFE4B86B, BAD=0xFFE17D7D, PREVIEW=0xFF0B0F13, GRID=0xFF35404A;
  static final int MARGIN=20, GAP=14, HEADER_H=68, STATUS_H=112, CONTROLS_H=122, RADIUS=14;
  static final int FONT_TINY=12, FONT_SMALL=14, FONT_BODY=15, FONT_LABEL=16, FONT_METRIC=19, FONT_TITLE=27;
}

PFont microphoneFontRegular,microphoneFontHeading;
void initializeMicrophoneTypography(){
  String regular=resolveMicrophoneFont(config.uiFontFamily,config.uiFontFallback);
  String heading=resolveMicrophoneFont(config.uiHeadingFontFamily,regular);
  microphoneFontRegular=createFont(regular,MicrophoneTheme.FONT_BODY,true);
  microphoneFontHeading=createFont(heading,MicrophoneTheme.FONT_TITLE,true);
  textFont(microphoneFontRegular);textLeading(MicrophoneTheme.FONT_BODY*1.28f);
}
String resolveMicrophoneFont(String preferred,String fallback){String[] installed=PFont.list();String hit=findMicrophoneFont(installed,preferred);if(hit!=null)return hit;hit=findMicrophoneFont(installed,fallback);return hit==null?"SansSerif":hit;}
String findMicrophoneFont(String[] installed,String wanted){if(wanted==null||wanted.trim().length()==0||installed==null)return null;for(String candidate:installed)if(candidate.equalsIgnoreCase(wanted.trim()))return candidate;return null;}
void micText(float size,boolean heading){PFont f=heading?microphoneFontHeading:microphoneFontRegular;if(f!=null)textFont(f);textSize(size);}
