class SurveillanceI18n {
  final ArrayList<String> supported=new ArrayList<String>();
  final HashMap<String,Properties> catalogs=new HashMap<String,Properties>();
  String fallbackLanguage="",language="";
  boolean rtl=false;
  SurveillanceI18n(String requested){discover();language=resolve(requested);refresh();}
  void discover(){File dir=new File(dataPath("i18n_3"));File[] files=dir.listFiles();if(files==null)return;Arrays.sort(files,new Comparator<File>(){public int compare(File a,File b){return a.getName().compareToIgnoreCase(b.getName());}});for(File f:files){if(!f.isFile()||!f.getName().toLowerCase(Locale.ROOT).endsWith(".properties"))continue;Properties p=load(f);String inferred=f.getName().substring(0,f.getName().length()-11);String loc=p.getProperty("meta.locale",inferred).trim();if(loc.length()==0||catalogs.containsKey(loc))continue;supported.add(loc);catalogs.put(loc,p);if("true".equalsIgnoreCase(p.getProperty("meta.default","false")))fallbackLanguage=loc;}if(fallbackLanguage.length()==0&&supported.size()>0)fallbackLanguage=supported.get(0);}
  Properties load(File f){Properties p=new Properties();Reader r=null;try{r=new InputStreamReader(new FileInputStream(f),"UTF-8");p.load(r);}catch(Exception e){println("i18n:"+f.getName()+":"+safeMessage(e));}finally{if(r!=null)try{r.close();}catch(IOException ignored){}}return p;}
  String resolve(String request){if(supported.size()==0)return "";String v=request==null?"auto":request.trim();if(v.length()==0||"auto".equalsIgnoreCase(v))v=Locale.getDefault().toLanguageTag();for(String loc:supported)if(loc.equalsIgnoreCase(v))return loc;String prefix=v.toLowerCase(Locale.ROOT).split("[-_]")[0];for(String loc:supported)if(loc.toLowerCase(Locale.ROOT).split("[-_]")[0].equals(prefix))return loc;return fallbackLanguage;}
  void refresh(){rtl="rtl".equalsIgnoreCase(raw("meta.direction","ltr"));}
  String raw(String k,String d){Properties p=catalogs.get(language);String v=p==null?null:p.getProperty(k);if(v==null&&fallbackLanguage.length()>0){Properties b=catalogs.get(fallbackLanguage);v=b==null?null:b.getProperty(k);}return v==null?d:v;}
  String tr(String k){return raw(k,k);}String format(String k,Object...a){try{return String.format(Locale.ROOT,tr(k),a);}catch(Exception e){return tr(k);}}
  void toggle(){if(supported.size()<=1)return;int i=supported.indexOf(language);language=supported.get((i+1+supported.size())%supported.size());refresh();}
  String shortLanguage(){return raw("meta.short",language);}int startAlign(){return rtl?RIGHT:LEFT;}
}

class SurveillanceTheme {
  static final int WINDOW_WIDTH=1380,WINDOW_HEIGHT=860;
  static final int BG=0xFF11151A,SURFACE=0xFF181E25,SURFACE_ALT=0xFF202832,SURFACE_RAISED=0xFF293440;
  static final int BORDER=0xFF35414D,TEXT=0xFFF4F7FA,MUTED=0xFFAAB6C2,ACCENT=0xFF68A9E8,GOOD=0xFF7CC7A0,WARN=0xFFE4B86B,BAD=0xFFE17D7D,PREVIEW=0xFF0B0F13;
  static final int MARGIN=20,GAP=14,RADIUS=14,HEADER_H=68,FOOTER_H=102,CARD_TITLE_H=44;
  static final int FONT_TINY=12,FONT_SMALL=14,FONT_BODY=15,FONT_LABEL=16,FONT_METRIC=19,FONT_TITLE=27;
}

PFont surveillanceFontRegular,surveillanceFontHeading;
void initializeSurveillanceTypography(){
  String regular=resolveSurveillanceFont(config.uiFontFamily,config.uiFontFallback);
  String heading=resolveSurveillanceFont(config.uiHeadingFontFamily,regular);
  surveillanceFontRegular=createFont(regular,SurveillanceTheme.FONT_BODY,true);
  surveillanceFontHeading=createFont(heading,SurveillanceTheme.FONT_TITLE,true);
  textFont(surveillanceFontRegular);textLeading(SurveillanceTheme.FONT_BODY*1.28f);
}
String resolveSurveillanceFont(String preferred,String fallback){String[] installed=PFont.list();String hit=findSurveillanceFont(installed,preferred);if(hit!=null)return hit;hit=findSurveillanceFont(installed,fallback);return hit==null?"SansSerif":hit;}
String findSurveillanceFont(String[] installed,String wanted){if(wanted==null||wanted.trim().length()==0||installed==null)return null;for(String candidate:installed)if(candidate.equalsIgnoreCase(wanted.trim()))return candidate;return null;}
void surveillanceText(float size,boolean heading){PFont f=heading?surveillanceFontHeading:surveillanceFontRegular;if(f!=null)textFont(f);textSize(size);}
