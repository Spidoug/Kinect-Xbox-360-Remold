class AcousticI18n {
  final ArrayList<String> supported=new ArrayList<String>();final HashMap<String,Properties> catalogs=new HashMap<String,Properties>();String fallback="",language="";
  AcousticI18n(String requested){discover();language=resolve(requested);}
  void discover(){File d=new File(dataPath("i18n_1"));File[] fs=d.listFiles();if(fs==null)return;Arrays.sort(fs,new Comparator<File>(){public int compare(File a,File b){return a.getName().compareToIgnoreCase(b.getName());}});for(File f:fs)if(f.isFile()&&f.getName().endsWith(".properties")){Properties p=load(f);String id=p.getProperty("meta.locale",f.getName().replace(".properties","")).trim();if(id.length()==0||catalogs.containsKey(id))continue;supported.add(id);catalogs.put(id,p);if("true".equalsIgnoreCase(p.getProperty("meta.default","false")))fallback=id;}if(fallback.length()==0&&supported.size()>0)fallback=supported.get(0);}
  Properties load(File f){Properties p=new Properties();Reader r=null;try{r=new InputStreamReader(new FileInputStream(f),"UTF-8");p.load(r);}catch(Exception e){println("acoustic-i18n:"+e);}finally{if(r!=null)try{r.close();}catch(IOException ignored){}}return p;}
  String resolve(String requested){if(supported.size()==0)return "";String v=requested==null?"auto":requested.trim();if(v.length()==0||v.equalsIgnoreCase("auto"))v=Locale.getDefault().toLanguageTag();for(String id:supported)if(id.equalsIgnoreCase(v))return id;String prefix=v.toLowerCase(Locale.ROOT).split("[-_]")[0];for(String id:supported)if(id.toLowerCase(Locale.ROOT).split("[-_]")[0].equals(prefix))return id;return fallback;}
  String tr(String key){Properties p=catalogs.get(language);String v=p==null?null:p.getProperty(key);if(v==null){Properties b=catalogs.get(fallback);v=b==null?null:b.getProperty(key);}return v==null?key:v;}
  String format(String key,Object...args){try{return String.format(Locale.ROOT,tr(key),args);}catch(Exception e){return tr(key);}}
  void toggle(){if(supported.size()<2)return;int i=supported.indexOf(language);language=supported.get((i+1+supported.size())%supported.size());}
  String shortLanguage(){Properties p=catalogs.get(language);String v=p==null?null:p.getProperty("meta.short");return v==null?language:v;}
}

class AcousticTheme {
  static final int WINDOW_W=1380,WINDOW_H=900;
  static final int BG=0xFF11151A,SURFACE=0xFF181E25,SURFACE2=0xFF202832,RAISED=0xFF293440;
  static final int BORDER=0xFF35414D,TEXT=0xFFF4F7FA,MUTED=0xFFAAB6C2,GRID=0xFF35404A,ACTIVE=0xFF68A9E8,GOOD=0xFF7CC7A0,WARN=0xFFE4B86B;
  static final int MARGIN=20,GAP=14,HEADER_H=68,RADIUS=14,CARD_TITLE_H=44;
  static final int FONT_TINY=12,FONT_SMALL=14,FONT_BODY=15,FONT_LABEL=16,FONT_METRIC=19,FONT_TITLE=27;
}

PFont acousticFontRegular,acousticFontHeading;
void initializeAcousticTypography(){
  String regular=resolveAcousticFont(acousticConfig.uiFontFamily,acousticConfig.uiFontFallback);
  String heading=resolveAcousticFont(acousticConfig.uiHeadingFontFamily,regular);
  acousticFontRegular=createFont(regular,AcousticTheme.FONT_BODY,true);
  acousticFontHeading=createFont(heading,AcousticTheme.FONT_TITLE,true);
  textFont(acousticFontRegular);textLeading(AcousticTheme.FONT_BODY*1.28f);
}
String resolveAcousticFont(String preferred,String fallback){String[] installed=PFont.list();String hit=findAcousticFont(installed,preferred);if(hit!=null)return hit;hit=findAcousticFont(installed,fallback);return hit==null?"SansSerif":hit;}
String findAcousticFont(String[] installed,String wanted){if(wanted==null||wanted.trim().length()==0||installed==null)return null;for(String candidate:installed)if(candidate.equalsIgnoreCase(wanted.trim()))return candidate;return null;}
void acousticText(float size,boolean heading){PFont f=heading?acousticFontHeading:acousticFontRegular;if(f!=null)textFont(f);textSize(size);}
