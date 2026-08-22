class I18n {
  final ArrayList<String> supported = new ArrayList<String>();
  final HashMap<String, Properties> catalogs = new HashMap<String, Properties>();
  String fallbackLanguage = "";
  String language = "";
  boolean rtl = false;

  I18n(String configuredLanguage) {
    discoverCatalogs();
    language = resolveLocale(configuredLanguage);
    refreshDirection();
  }

  void discoverCatalogs() {
    File directory = new File(dataPath("i18n_4"));
    File[] files = directory.listFiles();
    if (files == null) return;
    ArrayList<File> catalogFiles = new ArrayList<File>();
    for (File file : files) {
      if (file.isFile() && file.getName().toLowerCase(Locale.ROOT).endsWith(".properties")) catalogFiles.add(file);
    }
    Collections.sort(catalogFiles, new Comparator<File>() {
      public int compare(File a, File b) { return a.getName().compareToIgnoreCase(b.getName()); }
    });
    for (File file : catalogFiles) {
      Properties catalog = loadCatalog(file);
      String fileName = file.getName();
      String inferred = fileName.substring(0, fileName.length() - ".properties".length());
      String locale = catalog.getProperty("meta.locale", inferred).trim();
      if (locale.length() == 0 || catalogs.containsKey(locale)) continue;
      supported.add(locale);
      catalogs.put(locale, catalog);
      if ("true".equalsIgnoreCase(catalog.getProperty("meta.default", "false"))) fallbackLanguage = locale;
    }
    if (fallbackLanguage.length() == 0 && supported.size() > 0) fallbackLanguage = supported.get(0);
  }

  Properties loadCatalog(File file) {
    Properties p = new Properties();
    Reader reader = null;
    try {
      reader = new InputStreamReader(new FileInputStream(file), "UTF-8");
      p.load(reader);
    } catch (Exception e) {
      println("i18n:" + file.getName() + ":" + safeMessage(e));
    } finally {
      if (reader != null) try { reader.close(); } catch (IOException ignored) {}
    }
    return p;
  }

  String resolveLocale(String requested) {
    if (supported.size() == 0) return "";
    String value = requested == null ? "auto" : requested.trim();
    if (value.length() == 0 || value.equalsIgnoreCase("auto")) value = Locale.getDefault().toLanguageTag();
    for (String locale : supported) if (locale.equalsIgnoreCase(value)) return locale;
    String prefix = value.toLowerCase(Locale.ROOT).split("[-_]")[0];
    for (String locale : supported) if (locale.toLowerCase(Locale.ROOT).split("[-_]")[0].equals(prefix)) return locale;
    return fallbackLanguage;
  }

  void refreshDirection() { rtl = "rtl".equalsIgnoreCase(raw("meta.direction", "ltr")); }

  String raw(String key, String fallback) {
    Properties active = catalogs.get(language);
    String value = active == null ? null : active.getProperty(key);
    if (value == null && fallbackLanguage.length() > 0) {
      Properties base = catalogs.get(fallbackLanguage);
      value = base == null ? null : base.getProperty(key);
    }
    return value == null ? fallback : value;
  }

  String tr(String key) { return raw(key, key); }

  String format(String key, Object... args) {
    try { return String.format(Locale.ROOT, tr(key), args); }
    catch (Exception e) { return tr(key); }
  }

  void toggle() {
    if (supported.size() <= 1) return;
    int index = supported.indexOf(language);
    language = supported.get((index + 1 + supported.size()) % supported.size());
    refreshDirection();
  }

  String shortLanguage() {
    String compact = raw("meta.short", language);
    return compact == null || compact.trim().length() == 0 ? language : compact.trim();
  }
  int startAlign() { return rtl ? RIGHT : LEFT; }
  int endAlign() { return rtl ? LEFT : RIGHT; }

  String safeMessage(Exception e) {
    String m=e.getMessage(); return (m==null||m.length()==0)?e.getClass().getSimpleName():m;
  }
}

class UiTheme {
  // Shared panel policy: high-contrast dark surfaces with a restrained blue
  // status accent. Geometry and typography remain centralized here.
  static final int WINDOW_WIDTH = 1600;
  static final int WINDOW_HEIGHT = 980;
  static final int BG = 0xFF11151A;
  static final int SURFACE = 0xFF181E25;
  static final int SURFACE_ALT = 0xFF202832;
  static final int SURFACE_RAISED = 0xFF293440;
  static final int BORDER = 0xFF35414D;
  static final int TEXT = 0xFFF4F7FA;
  static final int TEXT_MUTED = 0xFFAAB6C2;
  static final int ACCENT = 0xFF68A9E8;
  static final int ACCENT_SOFT = 0xFF203A52;
  static final int GOOD = 0xFF7CC7A0;
  static final int WARN = 0xFFE4B86B;
  static final int BAD = 0xFFE17D7D;
  static final int GRID = 0xFF35404A;
  static final int PREVIEW = 0xFF0B0F13;
  static final int MESH = 0xFFD6E5F3;
  static final int RADIUS = 14;
  static final int MARGIN = 20;
  static final int GAP = 14;
  static final int HEADER_H = 68;
  static final int TOOLBAR_H = 122;
  static final int SIDEBAR_W = 430;
  static final int CARD_TITLE_H = 44;

  // Semantic type scale. No scanner panel should contain literal textSize values.
  static final int FONT_TINY = 12;
  static final int FONT_SMALL = 14;
  static final int FONT_BODY = 15;
  static final int FONT_METRIC = 19;
  static final int FONT_TITLE = 27;
}

void initializeScannerTypography(){
  String regular=resolveInstalledFont(config.uiFontFamily,config.uiFontFallback);
  String heading=resolveInstalledFont(config.uiHeadingFontFamily,regular);
  scannerFontRegular=createFont(regular,UiTheme.FONT_BODY,true);
  scannerFontHeading=createFont(heading,UiTheme.FONT_TITLE,true);
  textFont(scannerFontRegular);
  textLeading(UiTheme.FONT_BODY*1.28f);
}

String resolveInstalledFont(String preferred,String fallback){
  String[] installed=PFont.list();
  String hit=findFontIgnoreCase(installed,preferred);
  if(hit!=null)return hit;
  hit=findFontIgnoreCase(installed,fallback);
  return hit==null?"SansSerif":hit;
}

String findFontIgnoreCase(String[] installed,String wanted){
  if(wanted==null||wanted.trim().length()==0||installed==null)return null;
  String key=wanted.trim();
  for(String candidate:installed)if(candidate.equalsIgnoreCase(key))return candidate;
  return null;
}

void uiText(float size,boolean heading){
  PFont font=heading?scannerFontHeading:scannerFontRegular;
  if(font!=null)textFont(font);
  textSize(size);
}
