import java.io.*;
import java.nio.*;
import java.net.*;
import java.nio.channels.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import java.text.SimpleDateFormat;
import javax.imageio.*;
import javax.imageio.stream.*;
import javax.imageio.plugins.jpeg.JPEGImageWriteParam;
import javax.sound.sampled.*;
import java.awt.image.BufferedImage;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.Robot;
import java.awt.Rectangle;
import java.awt.GraphicsDevice;
import java.awt.GraphicsEnvironment;
import java.awt.event.InputEvent;
import java.awt.event.KeyEvent;
import java.awt.AWTException;
import com.jogamp.newt.opengl.GLWindow;
import com.jogamp.nativewindow.WindowClosingProtocol;


// ===== SynKinect Studio unified application =====
final int STUDIO_TAB_SCANNER=0;
final int STUDIO_TAB_ACOUSTIC=1;
final int STUDIO_TAB_MICROPHONES=2;
final int STUDIO_TAB_SURVEILLANCE=3;
final int STUDIO_TAB_INTERACTIVITY=4;
final int STUDIO_TAB_H=48;

// Shell-level policy belongs here instead of being duplicated by modules.
// Hardware initialization is intentionally lazy: rendering the application
// shell must never depend on a Kinect driver, pipe, socket or audio device.
final StudioShellConfig studioConfig=new StudioShellConfig();
StudioShellI18n studioI18n;
UnifiedI18nCatalog unifiedI18nCatalog;

// Processing requires these PApplet callbacks at sketch scope. Everything they
// operate is an instance owned by StudioController; module lifecycle and UI
// ownership stay inside object instances.
final StudioController studio=new StudioController();

// Instanced service/contract objects. The generated Java application keeps
// the same object model in the Windows/Linux JAR.
final ScannerProtocol scannerProtocol=new ScannerProtocol();
final UiTheme uiTheme=new UiTheme();
final AcousticProtocol acousticProtocol=new AcousticProtocol();
final AcousticTheme acousticTheme=new AcousticTheme();
final MicrophoneProtocol microphoneProtocol=new MicrophoneProtocol();
final MicrophoneTheme microphoneTheme=new MicrophoneTheme();
final SurveillanceProtocol surveillanceProtocol=new SurveillanceProtocol();
final SurveillanceTheme surveillanceTheme=new SurveillanceTheme();
final LocalTransport transportFactory=new LocalTransport();

public void settings(){
  size(1600,1028,P3D);
  smooth(4);
  try{PJOGL.setIcon(sketchPath("data/synkinect-studio-icon.png"));}catch(Exception ignored){}
}

public void setup(){
  surface.setTitle("SynKinect Studio");
  surface.setResizable(true);
  studio.setup();
  configureStudioClosePolicy();
}

public void draw(){studio.draw();}
public void mousePressed(){studio.mousePressed();}
public void mouseDragged(){studio.mouseDragged();}
public void mouseWheel(processing.event.MouseEvent event){studio.mouseWheel(event);}
public void keyPressed(){
  // Processing calls exit() automatically after keyPressed() when key is ESC.
  // Consume ESC globally so it can never terminate the Studio.
  if(key==ESC){key=0;studio.escapePressed();return;}
  studio.keyPressed();
}
public void dispose(){studio.dispose();}
public void exit(){
  // Native close requests also arrive through PApplet.exit().  Keep the
  // surveillance guard in one place so the title-bar close button cannot
  // terminate an armed/recording surveillance session.
  if(studio.rejectExitRequest())return;
  studio.dispose();
  super.exit();
}

void configureStudioClosePolicy(){
  try{
    Object nativeWindow=surface.getNative();
    if(nativeWindow instanceof GLWindow){
      ((GLWindow)nativeWindow).setDefaultCloseOperation(WindowClosingProtocol.WindowClosingMode.DO_NOTHING_ON_CLOSE);
    }
  }catch(Throwable e){println("Studio close-policy warning: "+safeStudioMessage(e));}
}

void updateStudioTitle(){studio.updateTitle();}

void applyStudioWindowIcon(){
  try{
    PImage icon=loadImage("synkinect-studio-icon.png");
    if(icon==null||icon.width<=0||icon.height<=0){
      InputStream in=getClass().getResourceAsStream("/synkinect-studio-icon.png");
      if(in!=null){
        try{BufferedImage image=ImageIO.read(in);if(image!=null)icon=new PImage(image);}finally{try{in.close();}catch(Exception ignored){}}
      }
    }
    if(icon!=null&&icon.width>0&&icon.height>0)surface.setIcon(icon);
  }catch(Exception e){println("Studio icon warning: "+safeStudioMessage(e));}
}

interface StudioModule {
  int id();
  String title();
  void setupModule();
  void activateModule();
  void deactivateModule();
  void drawModule();
  void mousePressedModule();
  void mouseDraggedModule();
  void mouseWheelModule(processing.event.MouseEvent event);
  void keyPressedModule();
  void disposeModule();
}

abstract class StudioModuleBase implements StudioModule {
  final int moduleId;
  final String moduleTitleKey;
  volatile boolean initialized=false;
  volatile boolean initializationFailed=false;
  volatile String initializationError="";
  volatile boolean renderFailed=false;
  volatile String renderError="";
  StudioModuleBase(int id,String titleKey){moduleId=id;moduleTitleKey=titleKey;}
  public int id(){return moduleId;}
  public String title(){return studioI18n==null?moduleTitleKey:studioI18n.tr(moduleTitleKey);}
  void initialize(){
    if(initialized||initializationFailed)return;
    try{setupModule();initialized=true;}
    catch(Throwable error){
      initializationFailed=true;
      initializationError=safeStudioMessage(error);
      println("Module initialization failed ["+moduleTitleKey+"]: "+initializationError);
      error.printStackTrace();
    }
  }
  public void mousePressedModule(){}
  public void mouseDraggedModule(){}
  public void mouseWheelModule(processing.event.MouseEvent event){}
  public void keyPressedModule(){}
}

class ScannerStudioModule extends StudioModuleBase {
  ScannerStudioModule(){super(STUDIO_TAB_SCANNER,"tab.scanner");}
  public void setupModule(){setupScannerModule();}
  public void activateModule(){
    ensureSharedRgbdCore();
    if(kinectSource!=null){kinectSource.start();kinectSource.clearConsumerPairs();}
  }
  public void deactivateModule(){
    // Scanner and Interactivity are two consumers of one canonical RGBD session.
    // Keep the transport alive only for a direct transition between those tabs.
    boolean keepRgbd=studio.transitionTarget==STUDIO_TAB_INTERACTIVITY;
    if(scanActive){scanPaused=true;scannerPauseAfterDrain=false;clearPendingScanWork();waitScannerReconstructionIdle();}
    if(kinectSource!=null){if(!keepRgbd)kinectSource.stop(true);else kinectSource.clearConsumerPairs();}
  }
  public void drawModule(){drawScannerModule();}
  public void mousePressedModule(){scannerMousePressed();}
  public void mouseDraggedModule(){scannerMouseDragged();}
  public void mouseWheelModule(processing.event.MouseEvent event){scannerMouseWheel(event);}
  public void keyPressedModule(){scannerKeyPressed();}
  public void disposeModule(){disposeScannerModule();}
}

class AcousticStudioModule extends StudioModuleBase {
  AcousticStudioModule(){super(STUDIO_TAB_ACOUSTIC,"tab.acoustic");}
  public void setupModule(){setupAcousticModule();}
  public void activateModule(){if(acousticSource!=null)acousticSource.start();}
  public void deactivateModule(){if(acousticSource!=null)acousticSource.stop();}
  public void drawModule(){drawAcousticModule();}
  public void mousePressedModule(){acousticMousePressed();}
  public void keyPressedModule(){acousticKeyPressed();}
  public void disposeModule(){disposeAcousticModule();}
}

class MicrophoneStudioModule extends StudioModuleBase {
  MicrophoneStudioModule(){super(STUDIO_TAB_MICROPHONES,"tab.microphones");}
  public void setupModule(){setupMicrophoneModule();}
  public void activateModule(){if(microphones!=null)microphones.start();}
  public void deactivateModule(){
    if(audioPipeline!=null){
      if(audioPipeline.recorder.isRecording())audioPipeline.recorder.stop();
      audioPipeline.monitor.stop();audioPipeline.player.stop();audioPipeline.selfTest.stop();
    }
    if(microphones!=null)microphones.stop();
  }
  public void drawModule(){drawMicrophoneModule();}
  public void mousePressedModule(){microphoneMousePressed();}
  public void keyPressedModule(){microphoneKeyPressed();}
  public void disposeModule(){disposeMicrophoneModule();}
}

class SurveillanceStudioModule extends StudioModuleBase {
  SurveillanceStudioModule(){super(STUDIO_TAB_SURVEILLANCE,"tab.surveillance");}
  public void setupModule(){setupSurveillanceModule();}
  public void activateModule(){
    prepareSurveillanceForTabEntry();
    if(survSource!=null)survSource.start(surveillanceProtocol.STREAM_IR_DEPTH);
  }
  public void deactivateModule(){
    if(survRecording)stopMotionRecording(false);
    prepareSurveillanceForTabEntry();
    if(survSource!=null)survSource.stop();
  }
  public void drawModule(){drawSurveillanceModule();}
  public void mousePressedModule(){surveillanceMousePressed();}
  public void keyPressedModule(){surveillanceKeyPressed();}
  public void disposeModule(){disposeSurveillanceModule();}
}

class InteractivityStudioModule extends StudioModuleBase {
  InteractivityStudioModule(){super(STUDIO_TAB_INTERACTIVITY,"tab.interactivity");}
  public void setupModule(){setupInteractivityModule();}
  public void activateModule(){activateInteractivityModule();}
  public void deactivateModule(){deactivateInteractivityModule();}
  public void drawModule(){drawInteractivityModule();}
  public void mousePressedModule(){interactivityMousePressed();}
  public void keyPressedModule(){interactivityKeyPressed();}
  public void disposeModule(){disposeInteractivityModule();}
}

class StudioController {
  final StudioModuleBase[] modules={
    new ScannerStudioModule(),new AcousticStudioModule(),new MicrophoneStudioModule(),new SurveillanceStudioModule(),new InteractivityStudioModule()
  };
  final Object lifecycleLock=new Object();
  final Object operationLock=new Object();
  volatile int activeTab=STUDIO_TAB_SCANNER;
  volatile int desiredTab=STUDIO_TAB_SCANNER;
  volatile int ownedTab=-1;
  volatile int transitionTarget=-1;
  volatile boolean ready=false;
  volatile boolean shuttingDown=false;
  volatile boolean transitioning=false;
  volatile boolean lifecycleRun=false;
  Thread lifecycleThread=null;
  int contentHeight=1;
  volatile long closeBlockedUntilMs=0;

  // All module UI is rendered in content-local coordinates after the shell
  // translates the canvas by STUDIO_TAB_H. Pointer input must use the exact
  // inverse transform. Keeping this rule here prevents individual modules
  // from mixing window-space and content-space coordinates.
  float contentMouseX(){return mouseX;}
  float contentMouseY(){return mouseY-STUDIO_TAB_H;}
  float contentPMouseX(){return pmouseX;}
  float contentPMouseY(){return pmouseY-STUDIO_TAB_H;}

  String currentLanguage(){return studioI18n==null?"en-US":studioI18n.language;}
  void cycleLanguage(){
    if(studioI18n==null)return;
    studioI18n.toggle();
    applyLanguageToModules(studioI18n.language);
    updateTitle();
  }
  void setLanguage(String locale){
    if(studioI18n==null)return;
    studioI18n.setLanguage(locale);
    applyLanguageToModules(studioI18n.language);
    updateTitle();
  }
  void applyLanguageToModules(String locale){
    if(i18n!=null){i18n.setLanguage(locale);appStatus=i18n.tr("status.ready");}
    if(acousticI18n!=null)acousticI18n.setLanguage(locale);
    if(micI18n!=null)micI18n.setLanguage(locale);
    if(survI18n!=null){survI18n.setLanguage(locale);survAppStatus=survI18n.tr(survArmed?"status.armed_ir":"status.disarmed");}
    if(interactionI18n!=null)interactionI18n.setLanguage(locale);
  }

  void setup(){
    contentHeight=max(1,height-STUDIO_TAB_H);
    studioConfig.load(new File(dataPath("studio.properties")));
    studioI18n=new StudioShellI18n(studioConfig.language);
    studioI18n.applyOrder(studioConfig.languages);
    frameRate(constrain(studioConfig.uiFrameRate,studioConfig.uiMinFrameRate,studioConfig.uiMaxFrameRate));
    ready=true;
    startLifecycle();
    select(constrain(studioConfig.initialTab,0,modules.length-1),true);
  }

  void draw(){
    contentHeight=max(1,height-STUDIO_TAB_H);
    StudioModuleBase active=modules[activeTab];

    // P3D keeps camera and model transforms in the same model-view stack.
    // Never call resetMatrix() after camera(): that erases the default camera
    // and places z=0 UI geometry on the eye plane, so only background() remains
    // visible. Restore a known 2D-friendly P3D state with camera()+perspective().
    resetStudioUiRenderer();
    pushStyle();
    pushMatrix();
    translate(0,STUDIO_TAB_H);
    if(active.initialized&&!active.renderFailed){
      try{active.drawModule();}
      catch(Throwable error){
        active.renderFailed=true;
        active.renderError=safeStudioMessage(error);
        println("Module render failed ["+active.moduleTitleKey+"]: "+active.renderError);
        error.printStackTrace();
      }
    }
    if(!active.initialized||active.renderFailed)drawModuleStartup(active);
    popMatrix();
    popStyle();

    // The shell owns the top navigation layer. Modules cannot leak matrix or
    // style state into it, and a module rendering failure cannot erase it.
    resetStudioUiRenderer();
    pushStyle();
    drawTabs();
    if(closeBlockedUntilMs>millis64())drawCloseGuardNotice();
    popStyle();
  }

  void resetStudioUiRenderer(){
    hint(DISABLE_DEPTH_TEST);
    camera();
    perspective();
  }

  float languageButtonW(){return constrain(width*0.085f,70,118);}
  float tabsGap(){return constrain(width*0.005f,4,8);}
  float tabsMargin(){return constrain(width*0.008f,7,12);}
  float tabWidth(){
    float gap=tabsGap(),margin=tabsMargin(),langW=languageButtonW();
    float available=max(1,width-margin*2-langW-gap-gap*(modules.length-1));
    return available/modules.length;
  }
  float languageButtonX(){return width-tabsMargin()-languageButtonW();}
  boolean languageButtonHit(float mx,float my){return mx>=languageButtonX()&&mx<=languageButtonX()+languageButtonW()&&my>=7&&my<=41;}

  void drawTabs(){
    noStroke();fill(0xFF0C1014);rect(0,0,width,STUDIO_TAB_H);
    float gap=tabsGap(),margin=tabsMargin(),tabW=tabWidth(),x=margin;
    for(int i=0;i<modules.length;i++){
      boolean active=i==activeTab;
      boolean moduleReady=isReady(i);
      fill(active?0xFF293440:0xFF181E25);rect(x,7,tabW,34,9);
      fill(active?0xFFF4F7FA:0xFFAAB6C2);textAlign(CENTER,CENTER);
      fitCurrentTextSize(modules[i].title(),14,8,max(12,tabW-20),28);text(modules[i].title(),x+tabW/2,24);
      if(active&&!moduleReady){fill(0xFF78B7E8);ellipse(x+tabW-9,24,5,5);}
      x+=tabW+gap;
    }
    float lx=languageButtonX(),lw=languageButtonW();boolean hot=languageButtonHit(mouseX,mouseY);
    stroke(hot?0xFF68A9E8:0xFF35414D);fill(hot?0xFF293440:0xFF181E25);rect(lx,7,lw,34,9);noStroke();fill(0xFFF4F7FA);
    String lang=studioI18n.tr("button.language")+" · "+studioI18n.shortLanguage();textAlign(CENTER,CENTER);fitCurrentTextSize(lang,13,8,lw-12,28);text(lang,lx+lw/2,24);
    textAlign(LEFT,BASELINE);
  }

  int tabAt(float mx,float my){
    if(my<0||my>STUDIO_TAB_H||languageButtonHit(mx,my))return -1;
    float gap=tabsGap(),margin=tabsMargin(),tabW=tabWidth(),x=margin;
    for(int i=0;i<modules.length;i++){if(mx>=x&&mx<=x+tabW&&my>=7&&my<=41)return i;x+=tabW+gap;}
    return -1;
  }

  boolean isReady(int tab){return !transitioning&&ownedTab==tab;}

  void mousePressed(){
    if(languageButtonHit(mouseX,mouseY)){cycleLanguage();return;}
    int tab=tabAt(mouseX,mouseY);
    if(tab>=0){select(tab,false);return;}
    if(!isReady(activeTab))return;
    modules[activeTab].mousePressedModule();
  }
  void mouseDragged(){if(isReady(activeTab))modules[activeTab].mouseDraggedModule();}
  void mouseWheel(processing.event.MouseEvent event){if(isReady(activeTab))modules[activeTab].mouseWheelModule(event);}
  void keyPressed(){
    if(key>='1'&&key<='5'){select(key-'1',false);return;}
    if(isReady(activeTab))modules[activeTab].keyPressedModule();
  }

  void escapePressed(){
    // ESC is a cancel/release key only. It never closes the Studio.
    if(interactionDesktop!=null)interactionDesktop.releaseDrag();
  }

  boolean surveillanceCloseGuardActive(){return survArmed||survRecording;}
  boolean rejectExitRequest(){
    if(shuttingDown)return false;
    if(!surveillanceCloseGuardActive())return false;
    closeBlockedUntilMs=millis64()+2800;
    return true;
  }

  void drawCloseGuardNotice(){
    String msg=studioI18n==null?"Surveillance is armed. Disarm it before closing.":studioI18n.tr("status.close_blocked_armed");
    float h=34,w=min(max(280,textWidth(msg)+34),max(280,width-40)),x=(width-w)/2,y=STUDIO_TAB_H+10;
    noStroke();fill(0xEE302A24);rect(x,y,w,h,9);stroke(0xFFE4B86B);noFill();rect(x,y,w,h,9);noStroke();
    fill(0xFFF4F7FA);textAlign(CENTER,CENTER);textSize(responsiveFontSize(12));fitCurrentTextSize(msg,12,8,w-24,h-8);text(ellipsizeToWidth(msg,w-24),x+w/2,y+h/2);textAlign(LEFT,BASELINE);
  }

  void select(int next,boolean initial){
    next=constrain(next,0,modules.length-1);
    if(!initial&&next==activeTab&&desiredTab==next)return;
    activeTab=next;
    if(next==STUDIO_TAB_SURVEILLANCE)prepareSurveillanceForTabEntry();
    synchronized(lifecycleLock){
      desiredTab=next;
      transitioning=ownedTab!=next;
      lifecycleLock.notifyAll();
    }
    updateTitle();
  }

  void updateTitle(){if(ready)surface.setTitle("SynKinect Studio — "+modules[activeTab].title());}

  void startLifecycle(){
    synchronized(lifecycleLock){if(lifecycleRun)return;lifecycleRun=true;}
    lifecycleThread=new Thread(new Runnable(){public void run(){lifecycleLoop();}},"SynKinectStudio-Lifecycle");
    lifecycleThread.setDaemon(true);
    lifecycleThread.start();
  }

  void lifecycleLoop(){
    while(true){
      int next;
      synchronized(lifecycleLock){
        while(lifecycleRun&&desiredTab==ownedTab){
          transitioning=false;
          try{lifecycleLock.wait();}catch(InterruptedException ignored){if(!lifecycleRun)return;}
        }
        if(!lifecycleRun)return;
        next=desiredTab;
        transitioning=true;
      }
      synchronized(operationLock){
        try{
          int previous=ownedTab;
          transitionTarget=next;
          if(previous>=0){modules[previous].deactivateModule();ownedTab=-1;}
          synchronized(lifecycleLock){if(!lifecycleRun){transitionTarget=-1;return;}next=desiredTab;transitionTarget=next;}
          StudioModuleBase target=modules[next];
          target.initialize();
          if(target.initialized){
            target.activateModule();
            ownedTab=next;
          }else ownedTab=-1;
          transitionTarget=-1;
        }catch(Throwable e){ownedTab=-1;println("Studio tab transition warning: "+safeStudioMessage(e));e.printStackTrace();}
      }
      synchronized(lifecycleLock){transitioning=ownedTab!=desiredTab;lifecycleLock.notifyAll();}
    }
  }

  void stopLifecycle(){
    Thread t;
    synchronized(lifecycleLock){
      lifecycleRun=false;transitioning=false;lifecycleLock.notifyAll();t=lifecycleThread;lifecycleThread=null;
    }
    if(t!=null&&t!=Thread.currentThread()){
      t.interrupt();
      try{t.join(2500);}catch(InterruptedException ignored){Thread.currentThread().interrupt();}
    }
  }

  void dispose(){
    if(shuttingDown)return;
    shuttingDown=true;
    stopLifecycle();
    synchronized(operationLock){
      for(int i=modules.length-1;i>=0;i--){
        try{if(modules[i].initialized)modules[i].disposeModule();}catch(Exception ignored){}
      }
    }
  }
}


void waitScannerReconstructionIdle(){
  long deadline=System.currentTimeMillis()+max(250,config==null?1500:config.workerJoinMs);
  while(reconstructionBusy&&System.currentTimeMillis()<deadline){try{Thread.sleep(2);}catch(InterruptedException e){Thread.currentThread().interrupt();break;}}
}

void prepareSurveillanceForTabEntry(){
  survArmed=false;
  motionScore=0;
  if(survMotionDetector!=null)survMotionDetector.reset();
  if(survI18n!=null)survAppStatus=survI18n.tr("status.disarmed");
}

void drawModuleStartup(StudioModuleBase module){
  background(0xFF10151B);
  fill(0xFFF4F7FA);textAlign(CENTER,CENTER);textSize(responsiveFontSize(22));
  String title=module.title();
  text(title,width*0.5f,max(80,(height-STUDIO_TAB_H)*0.42f));
  fill(0xFFAAB6C2);textSize(responsiveFontSize(14));
  String message=module.initializationFailed
    ? studioI18n.format("startup.failed",module.initializationError)
    : module.renderFailed
      ? studioI18n.format("startup.render_failed",module.renderError)
      : studioI18n.tr("startup.loading");
  text(message,width*0.5f,max(120,(height-STUDIO_TAB_H)*0.42f+42));
  textAlign(LEFT,BASELINE);
}

String safeStudioMessage(Throwable e){String m=e==null?null:e.getMessage();return m==null||m.length()==0?(e==null?"unknown":e.getClass().getSimpleName()):m;}

class StudioShellConfig {
  String language="en-US";
  String languages="";
  int initialTab=STUDIO_TAB_SCANNER;
  int uiFrameRate=30,uiMinFrameRate=24,uiMaxFrameRate=60;
  void load(File file){
    Properties p=loadStudioProperties(file);
    language=p.getProperty("app.language",language).trim();
    languages=p.getProperty("app.languages",languages).trim();
    initialTab=parseStudioInt(p,"app.initialTab",initialTab);
    uiFrameRate=parseStudioInt(p,"ui.frameRate",uiFrameRate);
    uiMinFrameRate=parseStudioInt(p,"ui.minFrameRate",uiMinFrameRate);
    uiMaxFrameRate=max(uiMinFrameRate,parseStudioInt(p,"ui.maxFrameRate",uiMaxFrameRate));
  }
}

Properties loadStudioProperties(File file){
  Properties p=new Properties();
  if(file==null||!file.isFile())return p;
  try(InputStream in=new FileInputStream(file);Reader reader=new InputStreamReader(in,"UTF-8")){p.load(reader);}
  catch(Exception e){println("studio-config:"+safeStudioMessage(e));}
  return p;
}
int parseStudioInt(Properties p,String key,int fallback){try{return Integer.parseInt(p.getProperty(key,String.valueOf(fallback)).trim());}catch(Exception ignored){return fallback;}}

class UnifiedI18nCatalog {
  final ArrayList<String> supported=new ArrayList<String>();
  final HashMap<String,Properties> catalogs=new HashMap<String,Properties>();
  String fallback="";
  UnifiedI18nCatalog(){discover();}
  void discover(){
    File dir=new File(dataPath("i18n"));File[] files=dir.listFiles();if(files==null)return;
    Arrays.sort(files,new Comparator<File>(){public int compare(File a,File b){return a.getName().compareToIgnoreCase(b.getName());}});
    for(File file:files){
      if(!file.isFile()||!file.getName().toLowerCase(Locale.ROOT).endsWith(".properties"))continue;
      Properties catalog=loadStudioProperties(file);String inferred=file.getName().substring(0,file.getName().length()-11);
      String locale=catalog.getProperty("meta.locale",inferred).trim();if(locale.length()==0||catalogs.containsKey(locale))continue;
      supported.add(locale);catalogs.put(locale,catalog);if("true".equalsIgnoreCase(catalog.getProperty("meta.default","false")))fallback=locale;
    }
    if(fallback.length()==0&&!supported.isEmpty())fallback=supported.get(0);
  }
  String resolve(String requested){
    if(supported.isEmpty())return "";String value=requested==null?"auto":requested.trim();
    if(value.length()==0||"auto".equalsIgnoreCase(value))value=Locale.getDefault().toLanguageTag();
    for(String locale:supported)if(locale.equalsIgnoreCase(value))return locale;
    String prefix=value.toLowerCase(Locale.ROOT).split("[-_]")[0];
    for(String locale:supported)if(locale.toLowerCase(Locale.ROOT).split("[-_]")[0].equals(prefix))return locale;
    return fallback;
  }
  String raw(String locale,String key,String d){
    Properties active=catalogs.get(locale);String value=active==null?null:active.getProperty(key);
    if(value==null&&fallback.length()>0){Properties base=catalogs.get(fallback);value=base==null?null:base.getProperty(key);}
    return value==null?d:value;
  }
  String meta(String locale,String key,String d){return raw(locale,key,d);}
  void applyOrder(String csv){
    if(csv==null||csv.trim().length()==0)return;ArrayList<String> ordered=new ArrayList<String>();
    for(String token:csv.split(",")){String wanted=token.trim();for(String locale:supported)if(locale.equalsIgnoreCase(wanted)&&!ordered.contains(locale))ordered.add(locale);}
    for(String locale:supported)if(!ordered.contains(locale))ordered.add(locale);supported.clear();supported.addAll(ordered);
  }
}

UnifiedI18nCatalog studioCatalog(){if(unifiedI18nCatalog==null)unifiedI18nCatalog=new UnifiedI18nCatalog();return unifiedI18nCatalog;}

class ModuleI18n {
  final String namespace;String language="";boolean rtl=false;
  ModuleI18n(String namespace,String requested){this.namespace=namespace;language=studioCatalog().resolve(requested);refreshDirection();}
  String resolve(String requested){return studioCatalog().resolve(requested);}
  void setLanguage(String locale){language=resolve(locale);refreshDirection();}
  void refreshDirection(){rtl="rtl".equalsIgnoreCase(studioCatalog().meta(language,"meta.direction","ltr"));}
  String raw(String key,String d){return studioCatalog().raw(language,namespace+"."+key,d);}
  String tr(String key){return raw(key,key);}
  String format(String key,Object...args){try{return String.format(Locale.ROOT,tr(key),args);}catch(Exception e){return tr(key);}}
  String shortLanguage(){return studioCatalog().meta(language,"meta.short",language);}
  int startAlign(){return rtl?RIGHT:LEFT;}
  String[] aliases(String action){String value=raw("command."+action+".aliases","");return value.trim().length()==0?new String[0]:value.split("\\|");}
}

class StudioShellI18n extends ModuleI18n {
  StudioShellI18n(String requested){super("studio",requested);}
  void applyOrder(String csv){studioCatalog().applyOrder(csv);language=resolve(language);}
  void toggle(){ArrayList<String> supported=studioCatalog().supported;if(supported.size()<=1)return;int i=supported.indexOf(language);language=supported.get((i+1+supported.size())%supported.size());refreshDirection();}
}


float studioUiScale(){
  float sx=max(1,width)/1600.0f,sy=max(1,studio.contentHeight)/980.0f;
  return constrain(min(sx,sy),0.56f,1.35f);
}
float responsiveFontSize(float base){return max(7.5f,base*studioUiScale());}
void fitCurrentTextSize(String value,float preferred,float minimum,float maxWidth,float maxHeight){
  float hi=responsiveFontSize(preferred),lo=max(6.5f,responsiveFontSize(minimum));
  if(value==null)value="";float size=hi;textSize(size);
  while(size>lo&&(textWidth(value)>maxWidth||textAscent()+textDescent()>maxHeight)){size=max(lo,size-0.5f);textSize(size);}
}
String ellipsizeToWidth(String value,float maxWidth){
  if(value==null)return "";if(textWidth(value)<=maxWidth)return value;String s=value;
  while(s.length()>1&&textWidth(s+"…")>maxWidth)s=s.substring(0,s.length()-1);return s+"…";
}

PVector exportReferenceCenter(){
  if(mesh!=null&&mesh.triangleCount()>0)return mesh.boundsCenter();
  if(volumeInitialized&&volume!=null&&volume.center!=null)return volume.center.copy();
  return new PVector(0,0,0.75f);
}

ExternalPhotoManager resolveExportPhotos(File destination){
  if(destination==null)return null;
  File folder=destination.getParentFile();
  if(folder==null)folder=new File(".");
  ExternalPhotoManager embeddedPhotos=new ExternalPhotoManager(i18n);
  embeddedPhotos.importFolder(folder,exportReferenceCenter(),config);
  return embeddedPhotos.cameras.isEmpty()?null:embeddedPhotos;
}

// ===== Shared local transport =====
class LocalTransport implements Closeable {
  RandomAccessFile windowsPipe;
  SocketChannel unixChannel;
  InputStream input;
  OutputStream output;
  volatile boolean closed=false;

   boolean isLinux() {
    String os=System.getProperty("os.name","").toLowerCase(Locale.ROOT);
    return os.contains("linux");
  }

   LocalTransport open(String windowsPath,String linuxPath)throws IOException {
    LocalTransport t=new LocalTransport();
    if(isLinux()) {
      t.unixChannel=SocketChannel.open(StandardProtocolFamily.UNIX);
      t.unixChannel.connect(UnixDomainSocketAddress.of(linuxPath));
      t.input=Channels.newInputStream(t.unixChannel);
      t.output=Channels.newOutputStream(t.unixChannel);
    } else {
      t.windowsPipe=new RandomAccessFile(windowsPath,"rw");
    }
    return t;
  }

  void write(byte[] data)throws IOException {
    if(closed)throw new EOFException("local transport closed");
    if(windowsPipe!=null) { windowsPipe.write(data); return; }
    if(output==null)throw new EOFException("local transport unavailable");
    output.write(data); output.flush();
  }
  void readFully(byte[] data)throws IOException {
    if(closed)throw new EOFException("local transport closed");
    if(windowsPipe!=null) { windowsPipe.readFully(data); return; }
    if(input==null)throw new EOFException("local transport unavailable");
    int offset=0;
    while(offset<data.length) {
      int n=input.read(data,offset,data.length-offset);
      if(n<0)throw new EOFException("local transport closed");
      offset+=n;
    }
  }
  public synchronized void close()throws IOException {
    if(closed)return;
    closed=true;
    IOException failure=null;
    // shutdownInput/shutdownOutput wakes a worker blocked in a Unix-domain read
    // before close(), making tab switches and application shutdown deterministic.
    if(unixChannel!=null) {
      try { unixChannel.shutdownInput(); } catch(Exception ignored) {}
      try { unixChannel.shutdownOutput(); } catch(Exception ignored) {}
      try { unixChannel.close(); } catch(IOException e) { failure=e; }
    }
    try { if(windowsPipe!=null)windowsPipe.close(); } catch(IOException e) { if(failure==null)failure=e; }
    if(failure!=null)throw failure;
  }
}


// ===== SynKinect Studio / 3D Scanner / Module.pde =====
PFont scannerFontRegular, scannerFontHeading;

AppConfig config;
I18n i18n;
KinectSource kinectSource;
Calibration calibration;
DepthAnalyzer depthAnalyzer;
DepthPreviewRenderer depthRenderer;
PointCloudBuilder pointCloudBuilder;
RgbDepthRegistration rgbRegistration;
IcpTracker tracker;
TSDFVolume volume;
Mesh3D mesh;
ScannerUI ui;
Scanner3DViewport scannerViewport3D;
STLExporter stlExporter;
OBJExporter objExporter;
PLYExporter plyExporter;
MeshEditor meshEditor;
Mesh3D meshUndo;
ScanCoverageTracker scanCoverage;
DepthTargetTracker depthTarget;
PointCloudBuildStats cloudStats;
DepthDiagnostics latestDepthDiagnostics;

PImage depthPreview;
PImage colorPreview;
DepthFrame latestDepth;
volatile RgbSnapshot latestRgbSnapshot;

class RgbSnapshot {
  final int[] pixels;final int width,height;final long capturedMs,frameNumber,timestampUs;final PImage image;final float syncResidualMs,rawSkewMs;
  RgbSnapshot(PImage image,long frameNumber,long timestampUs,long capturedMs,float syncResidualMs,float rawSkewMs){
    this.image=image;this.pixels=image==null?null:image.pixels;this.width=image==null?0:image.width;this.height=image==null?0:image.height;this.frameNumber=frameNumber;this.timestampUs=timestampUs;this.capturedMs=capturedMs;this.syncResidualMs=syncResidualMs;this.rawSkewMs=rawSkewMs;
  }
}
volatile float latestRgbDepthSkewMs = Float.NaN;
final Object reconstructionQueueLock = new Object();
final Object reconstructionStateLock = new Object();
volatile boolean reconstructionRun = false;
volatile boolean reconstructionBusy = false;
volatile boolean scannerPauseAfterDrain = false;
Thread reconstructionThread = null;
final ArrayDeque<ScanWorkItem> reconstructionQueue = new ArrayDeque<ScanWorkItem>();
volatile long reconstructionQueueOverflows = 0;

volatile boolean meshBusy=false;
Thread meshThread=null;
volatile int deferredExportPrompt=0;
volatile boolean exportBusy=false;
Thread activeExportThread=null;

volatile boolean scanActive = false;
volatile boolean scanPaused = false;
volatile boolean volumeInitialized = false;
volatile float lockedObjectDepth = Float.NaN;
volatile long integratedFrames = 0;
volatile long rejectedTrackingFrames = 0;
final int EXPORT_NONE = 0, EXPORT_STL = 1, EXPORT_OBJ = 2, EXPORT_PLY = 3;
volatile int pendingExport = EXPORT_NONE;
volatile String appStatus = "";

float previewYaw = -0.45f;
float previewPitch = 0.25f;
float previewZoom = 1.0f;

void ensureSharedRgbdCore(){
  if(config==null){config=new AppConfig();config.load(new File(dataPath("scanner.properties")));}
  if(i18n==null)i18n=new I18n(studio.currentLanguage());
  if(calibration==null){calibration=new Calibration();calibration.configure(config);}
  if(rgbRegistration==null)rgbRegistration=new RgbDepthRegistration(config,calibration);
  if(kinectSource==null)kinectSource=new KinectSource(config,calibration,i18n);
}

void setupScannerModule() {
  ensureSharedRgbdCore();
  initializeScannerTypography();
  appStatus = i18n.tr("status.connecting");

  depthAnalyzer = new DepthAnalyzer();
  depthRenderer = new DepthPreviewRenderer();
  pointCloudBuilder = new PointCloudBuilder(config, rgbRegistration);
  tracker = new IcpTracker(config);
  volume = new TSDFVolume(config.volumeSize, config.voxelSizeM, config.truncationM, config.rgbTemporalColorWeightMax);
  mesh = new Mesh3D();
  stlExporter = new STLExporter(config); objExporter = new OBJExporter(config); plyExporter = new PLYExporter(config);
  meshEditor = new MeshEditor(config);
  scanCoverage = new ScanCoverageTracker(config);
  depthTarget = new DepthTargetTracker(config, depthAnalyzer);
  cloudStats = new PointCloudBuildStats();
  ui = new ScannerUI();
  scannerViewport3D = new Scanner3DViewport();

  try {
    ensureSharedRgbdCore();
    appStatus = i18n.tr("status.worker_started");
  } catch (Exception e) {
    appStatus = i18n.format("status.init_failed", safeExceptionMessage(e));
    println(appStatus); e.printStackTrace();
  }
  startReconstructionWorker();
}

void drawScannerModule() {
  background(uiTheme.BG);
  consumeKinectFrames();
  serviceDeferredUiActions();
  ui.draw();
}

void serviceDeferredUiActions(){
  int type=deferredExportPrompt;if(type==EXPORT_NONE)return;deferredExportPrompt=EXPORT_NONE;
  pendingExport=type;selectOutput(i18n.tr("dialog.export"),"exportFileSelected",defaultExportFile(type));
}

void consumeKinectFrames() {
  if(kinectSource==null)return;kinectSource.updateLiveness();
  int drained=0;RgbdFramePair pair=null;
  while(drained<config.captureDrainFramesPerDraw){
    if(scanActive&&!scanPaused&&!reconstructionQueueHasCapacity())break;
    pair=kinectSource.pollRgbdPair();if(pair==null)break;drained++;
    latestDepth=pair.depth;latestDepthDiagnostics=depthAnalyzer.analyze(pair.depth,config);depthPreview=depthRenderer.render(pair.depth,latestDepthDiagnostics);
    RgbSnapshot rgb=kinectSource.rgbSnapshot(pair);if(rgb!=null){colorPreview=rgb.image;latestRgbSnapshot=rgb;}latestRgbDepthSkewMs=pair.residualUs/1000.0f;
    if(scanActive&&!scanPaused&&calibration.valid){
      if(!pair.depth.deviceCalibrated)appStatus=i18n.tr("status.depth_uncalibrated_frame");
      else if(!latestDepthDiagnostics.healthy(config))appStatus=i18n.format("status.depth_unhealthy",i18n.format("depth.summary",latestDepthDiagnostics.plausiblePixels,latestDepthDiagnostics.totalPixels,latestDepthDiagnostics.plausibleRatio*100.0f,latestDepthDiagnostics.p05Mm,latestDepthDiagnostics.medianMm,latestDepthDiagnostics.p95Mm));
      else if(!queueScanFrame(pair.depth,latestDepthDiagnostics,rgb))break;
    }
  }
}

void startScan() {
  if(meshBusy){appStatus=i18n.tr("status.mesh_busy");return;}
  if (kinectSource == null || latestDepth == null) { appStatus = i18n.tr("status.no_depth"); return; }
  if (!latestDepth.deviceCalibrated) { appStatus = i18n.tr("status.no_metric"); return; }
  if (latestDepthDiagnostics == null || !latestDepthDiagnostics.healthy(config)) { appStatus = i18n.tr("status.depth_sparse"); return; }
  scanActive = true; scanPaused = false; clearPendingScanWork(); resetReconstructionState();
  queueScanFrame(latestDepth, latestDepthDiagnostics, latestRgbSnapshot);
  appStatus = i18n.tr("status.scan_started");
}

void togglePause() {
  if (!scanActive) return;
  scanPaused = !scanPaused;
  if (scanPaused) clearPendingScanWork();
  appStatus = i18n.tr(scanPaused ? "status.scan_paused" : "status.scan_resumed");
}

void resetScan() {
  if(meshBusy){appStatus=i18n.tr("status.mesh_busy");return;}
  scanActive = false; scanPaused = false; clearPendingScanWork(); resetReconstructionState();
  appStatus = i18n.tr("status.scan_reset");
}

void resetReconstructionState() {
  synchronized (reconstructionStateLock) {
    integratedFrames = 0; rejectedTrackingFrames = 0; lockedObjectDepth = Float.NaN;
    depthTarget.reset(); cloudStats.clear(); tracker.reset(); volume.clear(); volumeInitialized = false;
    latestRgbDepthSkewMs=Float.NaN;
    mesh = new Mesh3D(); meshUndo = null; scanCoverage.reset();
  }
}

void buildMesh() {
  if (!volumeInitialized) { appStatus = i18n.tr("status.no_volume"); return; }
  if (meshBusy) { appStatus = i18n.tr("status.mesh_busy"); return; }
  scanPaused = true; clearPendingScanWork();
  startMeshTask("build", null);
}

void startMeshTask(final String operation, final Mesh3D source){
  if(meshBusy)return;meshBusy=true;appStatus=i18n.tr("status.mesh_processing");
  meshThread=new Thread(new Runnable(){public void run(){
    try{
      // Barrier: let any already-running fusion frame leave the state section.
      synchronized(reconstructionStateLock){}
      Mesh3D result;
      if("build".equals(operation)){
        Mesh3D raw=volume.extractMesh(config.meshMinWeight);
        result=meshEditor.polish(raw);
      }else if("clean".equals(operation))result=meshEditor.clean(source);
      else if("smooth".equals(operation))result=meshEditor.polish(source);
      else if("center".equals(operation))result=meshEditor.center(source);
      else return;
      result.recalculateNormals();
      synchronized(reconstructionStateLock){
        if(!"build".equals(operation))meshUndo=source;else meshUndo=null;
        mesh=result;
      }
      if("build".equals(operation))appStatus=i18n.format("status.mesh_built",result.triangleCount());
      else if("clean".equals(operation))appStatus=i18n.format("status.mesh_clean",source==null?0:source.triangleCount(),result.triangleCount());
      else if("smooth".equals(operation))appStatus=i18n.format("status.mesh_polished",config.meshPolishIterations);
      else appStatus=i18n.tr("status.mesh_center");
      if("build".equals(operation)&&pendingExport!=EXPORT_NONE){deferredExportPrompt=pendingExport;pendingExport=EXPORT_NONE;}
    }catch(Exception e){appStatus=i18n.format("status.mesh_failed",safeExceptionMessage(e));println(appStatus);e.printStackTrace();}
    finally{meshBusy=false;meshThread=null;}
  }},"SynKinect3D-Mesh");meshThread.setDaemon(true);meshThread.setPriority(Thread.MIN_PRIORITY);meshThread.start();
}


void requestExport(int type) {
  if(meshBusy){appStatus=i18n.tr("status.mesh_busy");return;}
  if(exportBusy){appStatus=i18n.tr("status.export_busy");return;}
  if (mesh == null || mesh.triangleCount() == 0) { pendingExport=type; buildMesh(); return; }
  pendingExport = type; selectOutput(i18n.tr("dialog.export"), "exportFileSelected",defaultExportFile(type));
}

File defaultExportFile(int type){
  String extension=type==EXPORT_STL?".stl":type==EXPORT_OBJ?".obj":".ply";
  return new File(sketchPath(config.exportBaseName+extension));
}

File exportFileWithExtension(File selected,int type){
  String extension=type==EXPORT_STL?".stl":type==EXPORT_OBJ?".obj":".ply";
  String name=selected.getName();
  if(!name.toLowerCase(Locale.ROOT).endsWith(extension))selected=new File(selected.getParentFile(),name+extension);
  return selected;
}

void exportFileSelected(File selected) {
  if (selected == null) { pendingExport = EXPORT_NONE; return; }
  final int exportType=pendingExport; pendingExport=EXPORT_NONE;
  if(exportType==EXPORT_NONE)return;
  final File destination=exportFileWithExtension(selected,exportType);
  final Mesh3D exportMesh=mesh.deepCopy();
  final String type = exportType == EXPORT_STL ? "STL" : exportType == EXPORT_OBJ ? "OBJ" : "PLY";
  final ExternalPhotoManager exportPhotos = exportType == EXPORT_OBJ ? resolveExportPhotos(destination) : null;
  exportBusy=true; appStatus=i18n.format("status.exporting",type);
  activeExportThread=new Thread(new Runnable(){public void run(){
    try {
      if (exportType == EXPORT_STL) stlExporter.writeBinary(exportMesh,destination);
      else if (exportType == EXPORT_OBJ) objExporter.write(exportMesh,exportPhotos,destination);
      else plyExporter.write(exportMesh,destination);
      appStatus = i18n.format("status.exported", type);
    } catch (Exception e) {
      appStatus = i18n.format("status.export_failed", safeExceptionMessage(e)); println(appStatus); e.printStackTrace();
    } finally { exportBusy=false; activeExportThread=null; }
  }},"SynKinect3D-Export");
  activeExportThread.setDaemon(false); activeExportThread.setPriority(Thread.MIN_PRIORITY); activeExportThread.start();
}

void cleanMesh() {
  Mesh3D source=mesh;if(source==null||source.triangleCount()==0){appStatus=i18n.tr("status.mesh_required");return;}
  if(meshBusy){appStatus=i18n.tr("status.mesh_busy");return;}startMeshTask("clean",source);
}
void smoothMesh() {
  Mesh3D source=mesh;if(source==null||source.triangleCount()==0){appStatus=i18n.tr("status.mesh_required");return;}
  if(meshBusy){appStatus=i18n.tr("status.mesh_busy");return;}startMeshTask("smooth",source);
}
void centerMesh() {
  Mesh3D source=mesh;if(source==null||source.triangleCount()==0){appStatus=i18n.tr("status.mesh_required");return;}
  if(meshBusy){appStatus=i18n.tr("status.mesh_busy");return;}startMeshTask("center",source);
}
void undoMeshEdit() {
  if(meshBusy){appStatus=i18n.tr("status.mesh_busy");return;}
  Mesh3D undo=meshUndo;if(undo==null){appStatus=i18n.tr("status.no_undo");return;}
  Mesh3D current=mesh;mesh=undo;meshUndo=current;appStatus=i18n.tr("status.undo");
}

void dispatchUiAction(int action) {
  if(action==ui.ACTION_START)startScan();
  else if(action==ui.ACTION_PAUSE)togglePause();
  else if(action==ui.ACTION_RESET)resetScan();
  else if(action==ui.ACTION_MESH)buildMesh();
  else if(action==ui.ACTION_STL)requestExport(EXPORT_STL);
  else if(action==ui.ACTION_OBJ)requestExport(EXPORT_OBJ);
  else if(action==ui.ACTION_PLY)requestExport(EXPORT_PLY);
  else if(action==ui.ACTION_CLEAN)cleanMesh();
  else if(action==ui.ACTION_SMOOTH)smoothMesh();
  else if(action==ui.ACTION_CENTER)centerMesh();
  else if(action==ui.ACTION_UNDO)undoMeshEdit();
  else println("Ignored unknown UI action: " + action);
}

void scannerMousePressed() { if (ui.handleMousePressed(studio.contentMouseX(),studio.contentMouseY())) return; }
void scannerMouseDragged() {
  if (ui.isOver3D(studio.contentMouseX(),studio.contentMouseY())) {
    previewYaw += (studio.contentMouseX()-studio.contentPMouseX())*0.008f; previewPitch += (studio.contentMouseY()-studio.contentPMouseY())*0.008f;
    previewPitch = constrain(previewPitch, -1.45f, 1.45f);
  }
}
void scannerMouseWheel(processing.event.MouseEvent event) { previewZoom *= pow(1.08f, -event.getCount()); previewZoom = constrain(previewZoom, 0.2f, 4.0f); }
void scannerKeyPressed() {
  if (key == ' ') togglePause(); if (key == 'r' || key == 'R') resetScan(); if (key == 'm' || key == 'M') buildMesh();
  if (key == 's' || key == 'S') requestExport(EXPORT_STL);
  if (key == 'o' || key == 'O') requestExport(EXPORT_OBJ); if (key == 'l' || key == 'L') requestExport(EXPORT_PLY);
  if (key == 'c' || key == 'C') cleanMesh(); if (key == 'f' || key == 'F') smoothMesh(); if (key == 'x' || key == 'X') centerMesh();
  if (key == 'u' || key == 'U') undoMeshEdit();
}
void disposeScannerModule() {
  // Stop native capture first, preserve already received frames, move pending
  // depth into reconstruction, then let the reconstruction worker drain FIFO.
  if (kinectSource != null) kinectSource.stop(false);
  flushCapturedDepthForShutdown();
  scannerPauseAfterDrain=false;
  stopReconstructionWorker();
  Thread mt=meshThread;if(mt!=null){mt.interrupt();try{mt.join(config.workerJoinMs);}catch(InterruptedException ignored){Thread.currentThread().interrupt();}}
  Thread et=activeExportThread;if(et!=null){try{et.join(config.workerJoinMs*2L);}catch(InterruptedException ignored){Thread.currentThread().interrupt();}}
  if(scannerViewport3D!=null)scannerViewport3D.dispose();
}

class ScanWorkItem {
 final DepthFrame frame; final DepthDiagnostics diagnostics; final RgbSnapshot rgb;
  ScanWorkItem(DepthFrame frame, DepthDiagnostics diagnostics,RgbSnapshot rgb) { this.frame=frame;this.diagnostics=diagnostics;this.rgb=rgb; }
}

void startReconstructionWorker() {
  if (reconstructionRun) return; reconstructionRun = true;
  reconstructionThread = new Thread(new Runnable() { public void run() { reconstructionLoop(); } }, "SynKinect3D-Reconstruction");
  reconstructionThread.setDaemon(true); reconstructionThread.start();
}
void stopReconstructionWorker() {
  reconstructionRun = false;
  synchronized (reconstructionQueueLock) { reconstructionQueueLock.notifyAll(); }
  Thread t = reconstructionThread; reconstructionThread = null;
  if (t != null) {
    // Do not interrupt first: a clean close must finish all queued fusion work.
    try { t.join(config.workerJoinMs*4L); } catch (InterruptedException ignored) { Thread.currentThread().interrupt(); }
    if(t.isAlive()){t.interrupt();try{t.join(config.workerJoinMs);}catch(InterruptedException ignored){Thread.currentThread().interrupt();}}
  }
}
boolean reconstructionQueueHasCapacity(){
  synchronized(reconstructionQueueLock){return reconstructionQueue.size()<config.reconstructionQueueFrames;}
}
int reconstructionQueuedFrames(){synchronized(reconstructionQueueLock){return reconstructionQueue.size();}}
boolean queueScanFrame(DepthFrame frame, DepthDiagnostics diagnostics,RgbSnapshot rgb) {
  if (!reconstructionRun || frame == null || diagnostics == null) return false;
  synchronized (reconstructionQueueLock) {
    if(reconstructionQueue.size()>=config.reconstructionQueueFrames){reconstructionQueueOverflows++;return false;}
    reconstructionQueue.addLast(new ScanWorkItem(frame, diagnostics, rgb)); reconstructionQueueLock.notifyAll(); return true;
  }
}
void clearPendingScanWork() { synchronized (reconstructionQueueLock) { reconstructionQueue.clear(); reconstructionQueueLock.notifyAll(); } }
void requestScannerPauseAfterDrain(){
  scannerPauseAfterDrain=true; finishScannerPauseAfterDrainIfReady();
}
void finishScannerPauseAfterDrainIfReady(){
  if(!scannerPauseAfterDrain||reconstructionBusy)return;
  synchronized(reconstructionQueueLock){
    if(scannerPauseAfterDrain&&!reconstructionBusy&&reconstructionQueue.isEmpty()){scanPaused=true;scannerPauseAfterDrain=false;reconstructionQueueLock.notifyAll();}
  }
}
void flushCapturedDepthForShutdown(){
  if(kinectSource==null||!scanActive||scanPaused)return;
  // The canonical synchronizer owns a finite RGBD pair tail after capture stops.
  while(kinectSource.queuedRgbdPairs()>0){
    int before=kinectSource.queuedRgbdPairs();consumeKinectFrames();
    if(kinectSource.queuedRgbdPairs()>=before){try{Thread.sleep(2);}catch(InterruptedException ignored){Thread.currentThread().interrupt();break;}}
  }
}
void reconstructionLoop() {
  while (true) {
    ScanWorkItem work = null;
    synchronized (reconstructionQueueLock) {
      while (reconstructionRun && reconstructionQueue.isEmpty()) {
        try { reconstructionQueueLock.wait(100); } catch (InterruptedException ignored) { if(!reconstructionRun&&reconstructionQueue.isEmpty())return; }
      }
      if (!reconstructionRun && reconstructionQueue.isEmpty()) break;
      if(!reconstructionQueue.isEmpty()){work = reconstructionQueue.removeFirst();reconstructionBusy=true;}
    }
    if (work != null) {
      try{processScanFrame(work.frame, work.diagnostics, work.rgb);}
      finally{reconstructionBusy=false;finishScannerPauseAfterDrainIfReady();synchronized(reconstructionQueueLock){reconstructionQueueLock.notifyAll();}}
    }
  }
  reconstructionBusy=false;finishScannerPauseAfterDrainIfReady();
}

void processScanFrame(DepthFrame depthFrame, DepthDiagnostics diagnostics,RgbSnapshot rgb) {
  if (!scanActive || scanPaused || depthFrame == null || diagnostics == null || !calibration.valid) return;
  if (!depthFrame.deviceCalibrated || !diagnostics.healthy(config)) return;

  synchronized (reconstructionStateLock) {
    if (!scanActive || scanPaused) return;
    scanCoverage.updateImu(depthFrame.motion);
    if (!scanCoverage.imuStable) {
      rejectedTrackingFrames++; appStatus = i18n.format("status.sensor_moved", scanCoverage.imuDeviationDeg); return;
    }

    boolean targetReady = depthTarget.update(depthFrame); lockedObjectDepth = depthTarget.depthM;
    scanCoverage.updateDetection(targetReady && !Float.isNaN(lockedObjectDepth));
    if (!targetReady || Float.isNaN(lockedObjectDepth)) { cloudStats.clear(); appStatus = i18n.tr("status.target_acquiring"); return; }

    // Tracking stays sparse for responsiveness. Once the pose is accepted, a
    // second dense cloud is built for TSDF integration. This lets longer scan
    // time contribute genuinely more spatial samples instead of repeatedly
    // integrating the same 1/18th subset of the VGA depth image.
    PointCloud trackingCloud = pointCloudBuilder.build(depthFrame, calibration, config.pointStep, lockedObjectDepth, depthTarget.bandM, cloudStats, rgb);
    if (trackingCloud.size() < config.minimumTrackingPoints) {
      scanCoverage.updateDetection(false); rejectedTrackingFrames++; appStatus = i18n.format("status.cloud_sparse", trackingCloud.size()); return;
    }
    scanCoverage.updateDetection(true);

    RigidTransform pose = tracker.track(trackingCloud, depthFrame.motion);
    if (!tracker.trackingGood) { rejectedTrackingFrames++; appStatus = i18n.format("status.icp_wait", tracker.matches); return; }

    PointCloud fusionCloud = config.integrationPointStep==config.pointStep ? trackingCloud :
      pointCloudBuilder.build(depthFrame, calibration, config.integrationPointStep, lockedObjectDepth, depthTarget.bandM, null, rgb);
    if (!volumeInitialized) { volume.resetAround(fusionCloud.centroidTransformed(pose)); volumeInitialized = true; }
    volume.integrate(fusionCloud, pose, 1); integratedFrames++; scanCoverage.update(pose, depthFrame.motion);

    if (scanCoverage.complete && config.autoPauseOnFullTurn) {
      scanPaused = true; clearPendingScanWork(); appStatus = i18n.format("status.full_turn", scanCoverage.sweepDeg);
    } else appStatus = i18n.format("status.scanning", scanCoverage.progress() * 100.0f);
  }
}

String safeExceptionMessage(Exception e) {
  String m = e.getMessage(); return (m == null || m.length() == 0) ? e.getClass().getSimpleName() : m;
}


// ===== SynKinect Studio / 3D Scanner / AppConfig.pde =====
class AppConfig {
  String language = "en-US";
  int uiFrameRate = 30;
  int workerJoinMs = 1500;
  String uiFontFamily = "Segoe UI";
  String uiHeadingFontFamily = "Segoe UI Semibold";
  String uiFontFallback = "Arial";

  int pointStep = 3;
  int integrationPointStep = 1;
  int minimumTrackingPoints = 220;

  float minDepthM = 0.20f;
  float maxDepthM = 4.50f;

  // Metric depth intrinsics are externalized so scanner geometry can be tuned
  // without changing source when a calibrated Kinect profile is available.
  float depthFx = 594.2143421192325f;
  float depthFy = 591.0405369687078f;
  float depthCx = 339.30780975300314f;
  float depthCy = 242.73913761751615f;
  float depthScale = 0.001f;

  float objectDepthBandM = 0.24f;
  float maxObjectDepthBandM = 0.48f;
  float depthTargetSmoothing = 0.18f;
  float depthTargetStableToleranceM = 0.12f;
  float depthTargetMaxJumpM = 0.38f;
  int depthTargetStableFrames = 3;
  int depthTargetLostFramesForReacquire = 6;
  int depthTargetMinSamples = 80;
  float depthTargetMinConfidence = 0.040f;
  int depthHistogramBinMm = 20;
  float depthRoiLeft = 0.24f;
  float depthRoiRight = 0.76f;
  float depthRoiTop = 0.20f;
  float depthRoiBottom = 0.80f;
  int depthRoiSampleStep = 2;
  float depthPreferredTargetWindowM = 0.30f;

  int depthMinValidPixels = 1200;
  float depthMinValidRatio = 0.004f;
  int depthPlausibleMinMm = 180;
  int depthPlausibleMaxMm = 6000;
  long streamStaleTimeoutMs = 1200;
  long connectionStaleTimeoutMs = 2500;
  int reconnectDelayMs = 250;
  int captureDrainFramesPerDraw = 8;
  int reconstructionQueueFrames = 16;

  boolean pointCloudSpatialFilter = true;
  float pointCloudNeighborToleranceM = 0.085f;

  int volumeSize = 160;
  float voxelSizeM = 0.0045f;
  float truncationM = 0.022f;
  int meshMinWeight = 2;

  int icpIterations = 7;
  int icpMinimumMatches = 50;
  float icpCellSizeM = 0.030f;
  float icpMaxDistanceM = 0.075f;
  int icpMaxSamples = 3000;
  float icpGoodRmsM = 0.045f;

  float scanFullTurnDeg = 360.0f;
  float scanCompleteDeg = 355.0f;
  float scanRotationDeadbandDeg = 0.30f;
  float scanRotationMaxStepDeg = 24.0f;
  float scanDirectionLockDeg = 5.0f;
  float scanMaxSensorTiltDriftDeg = 10.0f;
  boolean autoPauseOnFullTurn = true;

  float meshCleanupMaxEdgeM = 0.10f;
  float meshCleanupMinAreaM2 = 0.00000010f;
  float meshWeldToleranceM = 0.0015f;
  int meshSmoothIterations = 2;
  float meshSmoothLambda = 0.30f;
  int meshPolishIterations = 3;
  float meshPolishLambda = 0.34f;
  float meshPolishMu = -0.36f;
  int meshMinimumComponentTriangles = 32;
  float meshMinimumComponentRatio = 0.002f;
  boolean meshColorEnabled = true;

  // RGB/depth registration. The intrinsic/extrinsic defaults are a representative
  // Kinect v1 stereo calibration profile; every value remains externalized so a
  // per-device calibration can replace it without source changes.
  float rgbFx = 529.215081f, rgbFy = 525.563936f, rgbCx = 328.942720f, rgbCy = 267.480682f;
  float depthK1 = -0.263864f, depthK2 = 0.999668f, depthP1 = -0.000762f, depthP2 = 0.005035f, depthK3 = -1.305362f;
  float rgbK1 = 0.207966f, rgbK2 = -0.586138f, rgbP1 = 0.000722f, rgbP2 = 0.001048f, rgbK3 = 0.498570f;
  float regR00=0.9998463f, regR01=0.0012635f, regR02=-0.0174872f;
  float regR10=-0.0014779f, regR11=0.9999239f, regR12=-0.0122514f;
  float regR20=0.0174704f, regR21=0.0122753f, regR22=0.9997720f;
  float regTx=0.01998524f, regTy=-0.00074424f, regTz=-0.01091674f;
  float colorRegistrationOffsetX = 0.0f;
  float colorRegistrationOffsetY = 0.0f;
  float rgbMaxSyncSkewMs = 24.0f;
  int rgbdQueueFrames = 24;
  int rgbdSyncHistoryFrames = 12;
  float rgbdSyncMaxResidualMs = 24.0f;
  float rgbdSyncBootstrapMaxSkewMs = 180.0f;
  float rgbdSyncOffsetAlpha = 0.08f;
  boolean rgbOcclusionFilter = true;
  float rgbOcclusionToleranceM = 0.025f;
  boolean rgbAutoRefine = true;
  int rgbRefineEveryFrames = 8;
  int rgbRefineSearchPx = 4;
  int rgbRefineSampleStep = 10;
  int rgbRefineEdgeThresholdMm = 65;
  int rgbRefineMinimumEdges = 36;
  float rgbRefineAlpha = 0.12f;
  float rgbRefineMaxOffsetPx = 8.0f;
  int rgbExposureLowLuma = 24;
  int rgbExposureHighLuma = 235;
  int rgbTemporalColorWeightMax = 8;

  float defaultPhotoHorizontalFovDeg = 55.0f;
  float defaultPhotoDistanceM = 0.35f;
  float defaultPhotoPitchDeg = 0.0f;

  String exportBaseName = "SynKinectScan";
  float exportWeldToleranceM = 0.0015f;
  float exportMaxWeldToleranceM = 0.008f;
  int exportMaxTriangles = 120000;
  int exportTextureMaxSize = 2048;
  float exportJpegQuality = 0.82f;
  String photoPoseFileName = "SynKinect_photo_poses.csv";

  void load(File file) {
    if (file == null || !file.isFile()) return;
    Properties p = new Properties();
    Reader reader = null;
    try {
      reader = new InputStreamReader(new FileInputStream(file), "UTF-8");
      p.load(reader);
      language = textValue(p, "app.language", language);
      uiFrameRate = intValue(p, "ui.frameRate", uiFrameRate, 10, 120);
      workerJoinMs = intValue(p, "lifecycle.workerJoinMs", workerJoinMs, 250, 10000);
      uiFontFamily = textValue(p, "ui.font.family", uiFontFamily);
      uiHeadingFontFamily = textValue(p, "ui.font.headingFamily", uiHeadingFontFamily);
      uiFontFallback = textValue(p, "ui.font.fallback", uiFontFallback);
      pointStep = intValue(p, "cloud.previewStep", pointStep, 1, 16);
      integrationPointStep = intValue(p, "cloud.integrationStep", integrationPointStep, 1, 16);
      minimumTrackingPoints = intValue(p, "tracking.minimumPoints", minimumTrackingPoints, 50, 20000);
      minDepthM = floatValue(p, "depth.minM", minDepthM, 0.10f, 9.0f);
      maxDepthM = floatValue(p, "depth.maxM", maxDepthM, minDepthM + 0.10f, 10.0f);
      depthFx = floatValue(p, "calibration.depth.fx", depthFx, 100.0f, 2000.0f);
      depthFy = floatValue(p, "calibration.depth.fy", depthFy, 100.0f, 2000.0f);
      depthCx = floatValue(p, "calibration.depth.cx", depthCx, 0.0f, scannerProtocol.WIDTH);
      depthCy = floatValue(p, "calibration.depth.cy", depthCy, 0.0f, scannerProtocol.HEIGHT);
      depthScale = floatValue(p, "calibration.depth.scale", depthScale, 0.00001f, 0.10f);
      objectDepthBandM = floatValue(p, "target.bandM", objectDepthBandM, 0.03f, 2.0f);
      maxObjectDepthBandM = floatValue(p, "target.maxBandM", maxObjectDepthBandM, objectDepthBandM, 3.0f);
      depthTargetSmoothing = floatValue(p, "target.smoothing", depthTargetSmoothing, 0.01f, 1.0f);
      depthTargetStableToleranceM = floatValue(p, "target.stableToleranceM", depthTargetStableToleranceM, 0.01f, 1.0f);
      depthTargetMaxJumpM = floatValue(p, "target.maxJumpM", depthTargetMaxJumpM, 0.05f, 3.0f);
      depthTargetStableFrames = intValue(p, "target.stableFrames", depthTargetStableFrames, 1, 60);
      depthTargetLostFramesForReacquire = intValue(p, "target.reacquireFrames", depthTargetLostFramesForReacquire, 1, 120);
      depthTargetMinSamples = intValue(p, "target.minimumSamples", depthTargetMinSamples, 16, 50000);
      depthTargetMinConfidence = floatValue(p, "target.minimumConfidence", depthTargetMinConfidence, 0.001f, 0.80f);
      depthHistogramBinMm = intValue(p, "depth.histogramBinMm", depthHistogramBinMm, 5, 200);
      depthRoiLeft = floatValue(p, "target.roi.left", depthRoiLeft, 0.0f, 0.90f);
      depthRoiRight = floatValue(p, "target.roi.right", depthRoiRight, depthRoiLeft + 0.05f, 1.0f);
      depthRoiTop = floatValue(p, "target.roi.top", depthRoiTop, 0.0f, 0.90f);
      depthRoiBottom = floatValue(p, "target.roi.bottom", depthRoiBottom, depthRoiTop + 0.05f, 1.0f);
      depthRoiSampleStep = intValue(p, "target.roi.sampleStep", depthRoiSampleStep, 1, 8);
      depthPreferredTargetWindowM = floatValue(p, "target.preferredWindowM", depthPreferredTargetWindowM, 0.05f, 3.0f);
      depthMinValidPixels = intValue(p, "depth.minimumValidPixels", depthMinValidPixels, 1, scannerProtocol.WIDTH * scannerProtocol.HEIGHT);
      depthMinValidRatio = floatValue(p, "depth.minimumValidRatio", depthMinValidRatio, 0.0001f, 1.0f);
      depthPlausibleMinMm = intValue(p, "depth.plausibleMinMm", depthPlausibleMinMm, 1, 9999);
      depthPlausibleMaxMm = intValue(p, "depth.plausibleMaxMm", depthPlausibleMaxMm, depthPlausibleMinMm + 1, 10000);
      streamStaleTimeoutMs = longValue(p, "transport.streamStaleMs", streamStaleTimeoutMs, 100, 30000);
      connectionStaleTimeoutMs = longValue(p, "transport.connectionStaleMs", connectionStaleTimeoutMs, streamStaleTimeoutMs, 60000);
      reconnectDelayMs = intValue(p, "transport.reconnectMs", reconnectDelayMs, 50, 5000);
      rgbdQueueFrames = intValue(p,"transport.rgbdQueueFrames",rgbdQueueFrames,4,120);
      rgbdSyncHistoryFrames = intValue(p,"transport.rgbdSyncHistoryFrames",rgbdSyncHistoryFrames,4,60);
      rgbdSyncMaxResidualMs = floatValue(p,"transport.rgbdSyncMaxResidualMs",rgbdSyncMaxResidualMs,1.0f,120.0f);
      rgbdSyncBootstrapMaxSkewMs = floatValue(p,"transport.rgbdSyncBootstrapMaxSkewMs",rgbdSyncBootstrapMaxSkewMs,rgbdSyncMaxResidualMs,500.0f);
      rgbdSyncOffsetAlpha = floatValue(p,"transport.rgbdSyncOffsetAlpha",rgbdSyncOffsetAlpha,0.001f,0.50f);
      captureDrainFramesPerDraw = intValue(p, "transport.drainFramesPerDraw", captureDrainFramesPerDraw, 1, 60);
      reconstructionQueueFrames = intValue(p, "fusion.queueFrames", reconstructionQueueFrames, 2, 120);
      pointCloudSpatialFilter = boolValue(p, "cloud.spatialFilter", pointCloudSpatialFilter);
      pointCloudNeighborToleranceM = floatValue(p, "cloud.neighborToleranceM", pointCloudNeighborToleranceM, 0.005f, 1.0f);
      volumeSize = intValue(p, "fusion.volumeSize", volumeSize, 48, 384);
      voxelSizeM = floatValue(p, "fusion.voxelSizeM", voxelSizeM, 0.001f, 0.05f);
      truncationM = floatValue(p, "fusion.truncationM", truncationM, voxelSizeM, 0.20f);
      meshMinWeight = intValue(p, "mesh.minimumWeight", meshMinWeight, 1, 255);
      icpIterations = intValue(p, "tracking.icpIterations", icpIterations, 1, 50);
      icpMinimumMatches = intValue(p, "tracking.icpMinimumMatches", icpMinimumMatches, 12, 5000);
      icpCellSizeM = floatValue(p, "tracking.icpCellSizeM", icpCellSizeM, 0.002f, 0.50f);
      icpMaxDistanceM = floatValue(p, "tracking.icpMaxDistanceM", icpMaxDistanceM, 0.005f, 1.0f);
      icpMaxSamples = intValue(p, "tracking.icpMaxSamples", icpMaxSamples, 100, 50000);
      icpGoodRmsM = floatValue(p, "tracking.icpGoodRmsM", icpGoodRmsM, 0.001f, 0.50f);
      scanFullTurnDeg = floatValue(p, "scan.fullTurnDeg", scanFullTurnDeg, 90.0f, 720.0f);
      scanCompleteDeg = floatValue(p, "scan.completeDeg", scanCompleteDeg, 30.0f, scanFullTurnDeg);
      scanRotationDeadbandDeg = floatValue(p, "scan.rotationDeadbandDeg", scanRotationDeadbandDeg, 0.0f, 10.0f);
      scanRotationMaxStepDeg = floatValue(p, "scan.rotationMaxStepDeg", scanRotationMaxStepDeg, 1.0f, 90.0f);
      scanDirectionLockDeg = floatValue(p, "scan.directionLockDeg", scanDirectionLockDeg, 0.1f, 45.0f);
      scanMaxSensorTiltDriftDeg = floatValue(p, "scan.maxSensorTiltDriftDeg", scanMaxSensorTiltDriftDeg, 0.5f, 45.0f);
      autoPauseOnFullTurn = boolValue(p, "scan.autoPauseOnFullTurn", autoPauseOnFullTurn);
      meshCleanupMaxEdgeM = floatValue(p, "mesh.cleanupMaxEdgeM", meshCleanupMaxEdgeM, voxelSizeM, 2.0f);
      meshCleanupMinAreaM2 = floatValue(p, "mesh.cleanupMinAreaM2", meshCleanupMinAreaM2, 0.000000001f, 0.01f);
      meshWeldToleranceM = floatValue(p, "mesh.weldToleranceM", meshWeldToleranceM, 0.00001f, 0.05f);
      meshSmoothIterations = intValue(p, "mesh.smoothIterations", meshSmoothIterations, 0, 100);
      meshSmoothLambda = floatValue(p, "mesh.smoothLambda", meshSmoothLambda, 0.01f, 1.0f);
      meshPolishIterations = intValue(p, "mesh.polishIterations", meshPolishIterations, 0, 20);
      meshPolishLambda = floatValue(p, "mesh.polishLambda", meshPolishLambda, 0.01f, 0.95f);
      meshPolishMu = floatValue(p, "mesh.polishMu", meshPolishMu, -0.95f, -0.01f);
      meshMinimumComponentTriangles = intValue(p, "mesh.minimumComponentTriangles", meshMinimumComponentTriangles, 1, 1000000);
      meshMinimumComponentRatio = floatValue(p, "mesh.minimumComponentRatio", meshMinimumComponentRatio, 0.0f, 0.25f);
      meshColorEnabled = boolValue(p, "mesh.rgb.enabled", meshColorEnabled);
      rgbFx = floatValue(p, "calibration.rgb.fx", rgbFx, 100.0f, 2000.0f);
      rgbFy = floatValue(p, "calibration.rgb.fy", rgbFy, 100.0f, 2000.0f);
      rgbCx = floatValue(p, "calibration.rgb.cx", rgbCx, -1000.0f, 2000.0f);
      rgbCy = floatValue(p, "calibration.rgb.cy", rgbCy, -1000.0f, 2000.0f);
      depthK1=floatValue(p,"calibration.depth.k1",depthK1,-5.0f,5.0f); depthK2=floatValue(p,"calibration.depth.k2",depthK2,-5.0f,5.0f);
      depthP1=floatValue(p,"calibration.depth.p1",depthP1,-1.0f,1.0f); depthP2=floatValue(p,"calibration.depth.p2",depthP2,-1.0f,1.0f); depthK3=floatValue(p,"calibration.depth.k3",depthK3,-10.0f,10.0f);
      rgbK1=floatValue(p,"calibration.rgb.k1",rgbK1,-5.0f,5.0f); rgbK2=floatValue(p,"calibration.rgb.k2",rgbK2,-5.0f,5.0f);
      rgbP1=floatValue(p,"calibration.rgb.p1",rgbP1,-1.0f,1.0f); rgbP2=floatValue(p,"calibration.rgb.p2",rgbP2,-1.0f,1.0f); rgbK3=floatValue(p,"calibration.rgb.k3",rgbK3,-10.0f,10.0f);
      regR00=floatValue(p,"calibration.depthToRgb.r00",regR00,-2.0f,2.0f); regR01=floatValue(p,"calibration.depthToRgb.r01",regR01,-2.0f,2.0f); regR02=floatValue(p,"calibration.depthToRgb.r02",regR02,-2.0f,2.0f);
      regR10=floatValue(p,"calibration.depthToRgb.r10",regR10,-2.0f,2.0f); regR11=floatValue(p,"calibration.depthToRgb.r11",regR11,-2.0f,2.0f); regR12=floatValue(p,"calibration.depthToRgb.r12",regR12,-2.0f,2.0f);
      regR20=floatValue(p,"calibration.depthToRgb.r20",regR20,-2.0f,2.0f); regR21=floatValue(p,"calibration.depthToRgb.r21",regR21,-2.0f,2.0f); regR22=floatValue(p,"calibration.depthToRgb.r22",regR22,-2.0f,2.0f);
      regTx=floatValue(p,"calibration.depthToRgb.tx",regTx,-0.20f,0.20f); regTy=floatValue(p,"calibration.depthToRgb.ty",regTy,-0.20f,0.20f); regTz=floatValue(p,"calibration.depthToRgb.tz",regTz,-0.20f,0.20f);
      colorRegistrationOffsetX = floatValue(p, "mesh.rgb.offsetX", colorRegistrationOffsetX, -32.0f, 32.0f);
      colorRegistrationOffsetY = floatValue(p, "mesh.rgb.offsetY", colorRegistrationOffsetY, -32.0f, 32.0f);
      rgbMaxSyncSkewMs=floatValue(p,"mesh.rgb.maxSyncSkewMs",rgbMaxSyncSkewMs,1.0f,200.0f);
      rgbOcclusionFilter=boolValue(p,"mesh.rgb.occlusionFilter",rgbOcclusionFilter);
      rgbOcclusionToleranceM=floatValue(p,"mesh.rgb.occlusionToleranceM",rgbOcclusionToleranceM,0.001f,0.25f);
      rgbAutoRefine=boolValue(p,"mesh.rgb.autoRefine",rgbAutoRefine);
      rgbRefineEveryFrames=intValue(p,"mesh.rgb.refineEveryFrames",rgbRefineEveryFrames,1,120);
      rgbRefineSearchPx=intValue(p,"mesh.rgb.refineSearchPx",rgbRefineSearchPx,0,16);
      rgbRefineSampleStep=intValue(p,"mesh.rgb.refineSampleStep",rgbRefineSampleStep,2,32);
      rgbRefineEdgeThresholdMm=intValue(p,"mesh.rgb.refineEdgeThresholdMm",rgbRefineEdgeThresholdMm,5,1000);
      rgbRefineMinimumEdges=intValue(p,"mesh.rgb.refineMinimumEdges",rgbRefineMinimumEdges,8,10000);
      rgbRefineAlpha=floatValue(p,"mesh.rgb.refineAlpha",rgbRefineAlpha,0.01f,1.0f);
      rgbRefineMaxOffsetPx=floatValue(p,"mesh.rgb.refineMaxOffsetPx",rgbRefineMaxOffsetPx,0.0f,32.0f);
      rgbExposureLowLuma=intValue(p,"mesh.rgb.exposureLowLuma",rgbExposureLowLuma,1,127);
      rgbExposureHighLuma=intValue(p,"mesh.rgb.exposureHighLuma",rgbExposureHighLuma,128,254);
      rgbTemporalColorWeightMax=intValue(p,"mesh.rgb.temporalColorWeightMax",rgbTemporalColorWeightMax,1,32);
      defaultPhotoHorizontalFovDeg = floatValue(p, "photos.defaultHorizontalFovDeg", defaultPhotoHorizontalFovDeg, 10.0f, 160.0f);
      defaultPhotoDistanceM = floatValue(p, "photos.defaultDistanceM", defaultPhotoDistanceM, 0.05f, 20.0f);
      defaultPhotoPitchDeg = floatValue(p, "photos.defaultPitchDeg", defaultPhotoPitchDeg, -89.0f, 89.0f);
      exportBaseName = textValue(p, "export.baseName", exportBaseName);
      exportWeldToleranceM = floatValue(p, "export.weldToleranceM", exportWeldToleranceM, 0.00001f, 0.05f);
      exportMaxWeldToleranceM = floatValue(p, "export.maxWeldToleranceM", exportMaxWeldToleranceM, exportWeldToleranceM, 0.10f);
      exportMaxTriangles = intValue(p, "export.maxTriangles", exportMaxTriangles, 1000, 5000000);
      exportTextureMaxSize = intValue(p, "export.textureMaxSize", exportTextureMaxSize, 256, 8192);
      exportJpegQuality = floatValue(p, "export.jpegQuality", exportJpegQuality, 0.30f, 1.0f);
      photoPoseFileName = textValue(p, "photos.poseFile", photoPoseFileName);
    } catch (Exception e) {
      println("Configuration warning: " + e.getMessage());
    } finally {
      if (reader != null) try { reader.close(); } catch (IOException ignored) {}
    }
  }

  String textValue(Properties p, String key, String fallback) {
    String v = p.getProperty(key);
    return v == null || v.trim().length() == 0 ? fallback : v.trim();
  }
  boolean boolValue(Properties p, String key, boolean fallback) {
    String v = p.getProperty(key); if (v == null) return fallback;
    String value = v.trim();
    if ("true".equalsIgnoreCase(value) || "1".equals(value)) return true;
    if ("false".equalsIgnoreCase(value) || "0".equals(value)) return false;
    return fallback;
  }
  int intValue(Properties p, String key, int fallback, int lo, int hi) {
    try { return constrain(Integer.parseInt(textValue(p,key,String.valueOf(fallback))), lo, hi); }
    catch (Exception e) { return fallback; }
  }
  long longValue(Properties p, String key, long fallback, long lo, long hi) {
    try { long v=Long.parseLong(textValue(p,key,String.valueOf(fallback))); return Math.max(lo,Math.min(hi,v)); }
    catch (Exception e) { return fallback; }
  }
  float floatValue(Properties p, String key, float fallback, float lo, float hi) {
    try { return constrain(Float.parseFloat(textValue(p,key,String.valueOf(fallback))), lo, hi); }
    catch (Exception e) { return fallback; }
  }
}


// ===== SynKinect Studio / 3D Scanner / DepthDetection.pde =====
class DepthDiagnostics {
  int totalPixels = 0;
  int nonZeroPixels = 0;
  int plausiblePixels = 0;
  float plausibleRatio = 0;
  int minMm = 0, p05Mm = 0, medianMm = 0, p95Mm = 0, maxMm = 0;
  boolean recoveredTransport = false;
  boolean calibrated = false;

  boolean healthy(AppConfig cfg) {
    return calibrated && plausiblePixels >= cfg.depthMinValidPixels && plausibleRatio >= cfg.depthMinValidRatio;
  }

}

class DepthTargetEstimate {
  boolean valid = false;
  float depthM = Float.NaN;
  float confidence = 0;
  float spreadM = 0;
  int samples = 0;
}

class DepthAnalyzer {
  DepthDiagnostics analyze(DepthFrame frame, AppConfig cfg) {
    DepthDiagnostics out = new DepthDiagnostics();
    if (frame == null || frame.depth == null || frame.depth.length == 0) return out;
    out.totalPixels = frame.depth.length;
    out.calibrated = frame.deviceCalibrated;
    out.recoveredTransport = frame.transportRecovered;

    int binMm = max(1, cfg.depthHistogramBinMm);
    int bins = max(1, ((cfg.depthPlausibleMaxMm - cfg.depthPlausibleMinMm) / binMm) + 1);
    int[] hist = new int[bins];
    int minSeen = Integer.MAX_VALUE, maxSeen = 0;

    for (int i = 0; i < frame.depth.length; i++) {
      int mm = frame.depth[i] & 0xFFFF;
      if (mm == 0) continue;
      out.nonZeroPixels++;
      if (mm < cfg.depthPlausibleMinMm || mm > cfg.depthPlausibleMaxMm) continue;
      out.plausiblePixels++;
      minSeen = min(minSeen, mm);
      maxSeen = max(maxSeen, mm);
      int b = constrain((mm - cfg.depthPlausibleMinMm) / binMm, 0, bins - 1);
      hist[b]++;
    }

    out.plausibleRatio = out.totalPixels > 0 ? out.plausiblePixels / (float)out.totalPixels : 0;
    if (out.plausiblePixels > 0) {
      out.minMm = minSeen; out.maxMm = maxSeen;
      out.p05Mm = percentile(hist, out.plausiblePixels, 0.05f, cfg.depthPlausibleMinMm, binMm);
      out.medianMm = percentile(hist, out.plausiblePixels, 0.50f, cfg.depthPlausibleMinMm, binMm);
      out.p95Mm = percentile(hist, out.plausiblePixels, 0.95f, cfg.depthPlausibleMinMm, binMm);
    }
    return out;
  }

  int percentile(int[] hist, int total, float p, int baseMm, int binMm) {
    if (total <= 0) return 0;
    int target = max(1, ceil(total * p));
    int sum = 0;
    for (int i = 0; i < hist.length; i++) {
      sum += hist[i];
      if (sum >= target) return baseMm + i * binMm + binMm / 2;
    }
    return baseMm + (hist.length - 1) * binMm + binMm / 2;
  }

  DepthTargetEstimate estimateTarget(DepthFrame frame, AppConfig cfg, float preferredDepthM) {
    DepthTargetEstimate out = new DepthTargetEstimate();
    if (frame == null || frame.depth == null || frame.width <= 0 || frame.height <= 0) return out;

    int binMm = max(1, cfg.depthHistogramBinMm);
    int minMm = max(1, round(cfg.minDepthM * 1000.0f));
    int maxMm = max(minMm + binMm, round(cfg.maxDepthM * 1000.0f));
    int bins = max(1, ((maxMm - minMm) / binMm) + 1);
    int[] hist = new int[bins];

    int x0 = constrain(round(frame.width * cfg.depthRoiLeft), 0, frame.width - 1);
    int x1 = constrain(round(frame.width * cfg.depthRoiRight), x0 + 1, frame.width);
    int y0 = constrain(round(frame.height * cfg.depthRoiTop), 0, frame.height - 1);
    int y1 = constrain(round(frame.height * cfg.depthRoiBottom), y0 + 1, frame.height);
    int stride = max(1, cfg.depthRoiSampleStep);
    int samples = 0;

    for (int y = y0; y < y1; y += stride) {
      int row = y * frame.width;
      for (int x = x0; x < x1; x += stride) {
        int mm = frame.depth[row + x] & 0xFFFF;
        if (mm < minMm || mm > maxMm) continue;
        hist[constrain((mm - minMm) / binMm, 0, bins - 1)]++;
        samples++;
      }
    }
    out.samples = samples;
    if (samples < cfg.depthTargetMinSamples) return out;

    int requiredMass = max(cfg.depthTargetMinSamples, ceil(samples * cfg.depthTargetMinConfidence));
    ArrayList<Integer> peaks = new ArrayList<Integer>();
    for (int b = 0; b < bins; b++) {
      int left = b > 0 ? hist[b - 1] : -1;
      int right = b + 1 < bins ? hist[b + 1] : -1;
      if (hist[b] < left || hist[b] < right) continue;
      int mass = clusterMass(hist, b, 2);
      if (mass >= requiredMass) peaks.add(b);
    }

    int peak = -1;
    if (!peaks.isEmpty()) {
      if (!Float.isNaN(preferredDepthM)) {
        float bestDistance = Float.MAX_VALUE;
        float windowMm = cfg.depthPreferredTargetWindowM * 1000.0f;
        for (int b : peaks) {
          float centerMm = minMm + b * binMm + binMm * 0.5f;
          float distance = abs(centerMm - preferredDepthM * 1000.0f);
          if (distance <= windowMm && distance < bestDistance) { bestDistance = distance; peak = b; }
        }
      }
      // Fresh acquisition favors the nearest significant foreground cluster.
      if (peak < 0) peak = peaks.get(0);
    } else {
      int bestMass = 0;
      for (int b = 0; b < bins; b++) {
        int mass = clusterMass(hist, b, 2);
        if (mass > bestMass) { bestMass = mass; peak = b; }
      }
    }
    if (peak < 0) return out;

    int lo = max(0, peak - 2), hi = min(bins - 1, peak + 2);
    long weighted = 0; int mass = 0;
    for (int b = lo; b <= hi; b++) {
      int count = hist[b];
      weighted += (long)(minMm + b * binMm + binMm / 2) * count;
      mass += count;
    }
    if (mass <= 0) return out;
    float centerMm = weighted / (float)mass;

    float variance = 0; int spreadMass = 0;
    for (int b = max(0, peak - 8); b <= min(bins - 1, peak + 8); b++) {
      int count = hist[b];
      if (count == 0) continue;
      float mm = minMm + b * binMm + binMm / 2.0f;
      float d = mm - centerMm;
      variance += d * d * count;
      spreadMass += count;
    }

    out.confidence = mass / (float)samples;
    out.depthM = centerMm * 0.001f;
    out.spreadM = spreadMass > 0 ? sqrt(variance / spreadMass) * 0.001f : 0;
    out.valid = out.confidence >= cfg.depthTargetMinConfidence && out.depthM >= cfg.minDepthM && out.depthM <= cfg.maxDepthM;
    return out;
  }

  int clusterMass(int[] hist, int center, int radius) {
    int mass = 0;
    for (int k = max(0, center - radius); k <= min(hist.length - 1, center + radius); k++) mass += hist[k];
    return mass;
  }
}

class DepthPreviewRenderer {
  PImage render(DepthFrame frame, DepthDiagnostics d) {
    if (frame == null || frame.depth == null) return null;
    PImage img = createImage(frame.width, frame.height, RGB);
    img.loadPixels();
    int nearMm = d != null && d.p05Mm > 0 ? d.p05Mm : 500;
    int farMm = d != null && d.p95Mm > nearMm ? d.p95Mm : nearMm + 1500;
    if (farMm - nearMm < 350) {
      int mid = d != null && d.medianMm > 0 ? d.medianMm : (nearMm + farMm) / 2;
      nearMm = max(200, mid - 250); farMm = mid + 250;
    }
    int n = min(img.pixels.length, frame.depth.length);
    for (int i = 0; i < n; i++) {
      int mm = frame.depth[i] & 0xFFFF;
      if (mm == 0) { img.pixels[i] = 0xFF080B10; continue; }
      float t = constrain((mm - nearMm) / (float)max(1, farMm - nearMm), 0, 1);
      // Neutral grayscale ramp keeps depth readable without breaking the gray UI system.
      int gray = round(228 - 176 * t);
      img.pixels[i] = color(gray);
    }
    img.updatePixels();
    return img;
  }
}

class DepthTargetTracker {
  AppConfig cfg;
  DepthAnalyzer analyzer;
  float depthM = Float.NaN, bandM = 0, candidateM = Float.NaN;
  int stableFrames = 0, lostFrames = 0;
  DepthTargetEstimate latest = new DepthTargetEstimate();

  DepthTargetTracker(AppConfig cfg, DepthAnalyzer analyzer) { this.cfg = cfg; this.analyzer = analyzer; bandM = cfg.objectDepthBandM; }

  void reset() { depthM = Float.NaN; bandM = cfg.objectDepthBandM; candidateM = Float.NaN; stableFrames = 0; lostFrames = 0; latest = new DepthTargetEstimate(); }

  boolean update(DepthFrame frame) {
    latest = analyzer.estimateTarget(frame, cfg, depthM);
    if (!latest.valid || Float.isNaN(latest.depthM)) {
      lostFrames++;
      if (lostFrames >= cfg.depthTargetLostFramesForReacquire) { depthM = Float.NaN; candidateM = Float.NaN; stableFrames = 0; bandM = cfg.objectDepthBandM; return false; }
      return !Float.isNaN(depthM);
    }

    float suggestedBand = max(cfg.objectDepthBandM, latest.spreadM * 3.0f);
    bandM = constrain(lerp(bandM, suggestedBand, 0.25f), cfg.objectDepthBandM, cfg.maxObjectDepthBandM);

    if (Float.isNaN(depthM)) {
      if (Float.isNaN(candidateM) || abs(latest.depthM - candidateM) > cfg.depthTargetStableToleranceM) { candidateM = latest.depthM; stableFrames = 1; }
      else { candidateM = lerp(candidateM, latest.depthM, 0.35f); stableFrames++; }
      if (stableFrames >= cfg.depthTargetStableFrames) { depthM = candidateM; lostFrames = 0; return true; }
      return false;
    }

    if (abs(latest.depthM - depthM) <= cfg.depthTargetMaxJumpM) {
      depthM = lerp(depthM, latest.depthM, cfg.depthTargetSmoothing);
      candidateM = depthM; stableFrames = cfg.depthTargetStableFrames; lostFrames = 0; return true;
    }

    lostFrames++;
    if (Float.isNaN(candidateM) || abs(latest.depthM - candidateM) > cfg.depthTargetStableToleranceM) { candidateM = latest.depthM; stableFrames = 1; }
    else { candidateM = lerp(candidateM, latest.depthM, 0.35f); stableFrames++; }
    if (stableFrames >= cfg.depthTargetLostFramesForReacquire) { depthM = candidateM; bandM = cfg.objectDepthBandM; stableFrames = cfg.depthTargetStableFrames; lostFrames = 0; return true; }
    return false;
  }

}

class PointCloudBuildStats {
  int sourcePixels = 0, nonZero = 0, inRange = 0, accepted = 0, rejectedRange = 0, rejectedBand = 0, rejectedSpatial = 0;
  void clear() { sourcePixels = nonZero = inRange = accepted = rejectedRange = rejectedBand = rejectedSpatial = 0; }
}


// ===== SynKinect Studio / 3D Scanner / Exporters.pde =====
class ExportSpace {
  PVector position(PVector p) { return new PVector(p.x, -p.y, p.z); }
  Triangle3D triangle(Triangle3D t) {
    // Y reflection changes handedness; swapping B/C preserves outward winding.
    return new Triangle3D(position(t.a), position(t.c), position(t.b), t.ca, t.cc, t.cb);
  }
}

class VertexKey {
  final long x,y,z;
  VertexKey(PVector p,float q){x=Math.round(p.x/q);y=Math.round(p.y/q);z=Math.round(p.z/q);}
  public int hashCode(){long h=x*73856093L^y*19349663L^z*83492791L;return(int)(h^(h>>>32));}
  public boolean equals(Object o){if(!(o instanceof VertexKey))return false;VertexKey k=(VertexKey)o;return x==k.x&&y==k.y&&z==k.z;}
}
class FaceKey {
  final int a,b,c;
  FaceKey(int x,int y,int z){int[] v={x,y,z};Arrays.sort(v);a=v[0];b=v[1];c=v[2];}
  public int hashCode(){return (a*73856093)^(b*19349663)^(c*83492791);}
  public boolean equals(Object o){if(!(o instanceof FaceKey))return false;FaceKey k=(FaceKey)o;return a==k.a&&b==k.b&&c==k.c;}
}
class VertexAccum {
  float x,y,z;long r,g,b;int count;
  void add(PVector p,int colorValue){x+=p.x;y+=p.y;z+=p.z;r+=(colorValue>>16)&255;g+=(colorValue>>8)&255;b+=colorValue&255;count++;}
  PVector point(){float n=Math.max(1,count);return new PVector(x/n,y/n,z/n);}
  int colorValue(){int n=Math.max(1,count);return color((int)(r/n),(int)(g/n),(int)(b/n));}
}
class IndexedFace {
  int a,b,c;Triangle3D source;
  IndexedFace(int a,int b,int c,Triangle3D source){this.a=a;this.b=b;this.c=c;this.source=source;}
}
class IndexedMesh {
  ArrayList<PVector> vertices=new ArrayList<PVector>();
  ArrayList<Integer> colors=new ArrayList<Integer>();
  ArrayList<IndexedFace> faces=new ArrayList<IndexedFace>();
  float toleranceM;
}
class MeshCompactor {
  AppConfig cfg;ExportSpace space=new ExportSpace();
  MeshCompactor(AppConfig cfg){this.cfg=cfg;}
  IndexedMesh compact(Mesh3D source){
    float q=Math.max(0.00001f,cfg.exportWeldToleranceM);IndexedMesh best=null;
    while(true){
      IndexedMesh candidate=compactAt(source,q);best=candidate;
      if(candidate.faces.size()<=cfg.exportMaxTriangles||q>=cfg.exportMaxWeldToleranceM-0.0000001f)break;
      q=Math.min(cfg.exportMaxWeldToleranceM,q*1.35f);
    }
    return best;
  }
  IndexedMesh compactAt(Mesh3D source,float q){
    IndexedMesh out=new IndexedMesh();out.toleranceM=q;
    HashMap<VertexKey,Integer> indices=new HashMap<VertexKey,Integer>();
    ArrayList<VertexAccum> accum=new ArrayList<VertexAccum>();
    HashSet<FaceKey> seenFaces=new HashSet<FaceKey>();
    for(Triangle3D original:source.triangles){
      Triangle3D t=space.triangle(original);
      int ia=indexFor(t.a,t.ca,q,indices,accum),ib=indexFor(t.b,t.cb,q,indices,accum),ic=indexFor(t.c,t.cc,q,indices,accum);
      if(ia==ib||ib==ic||ia==ic)continue;
      FaceKey fk=new FaceKey(ia,ib,ic);if(!seenFaces.add(fk))continue;
      PVector a=accum.get(ia).point(),b=accum.get(ib).point(),c=accum.get(ic).point();
      if(PVector.sub(b,a).cross(PVector.sub(c,a)).magSq()<1e-12f)continue;
      out.faces.add(new IndexedFace(ia,ib,ic,original));
    }
    for(VertexAccum v:accum){out.vertices.add(v.point());out.colors.add(v.colorValue());}
    return out;
  }
  int indexFor(PVector p,int c,float q,HashMap<VertexKey,Integer> indices,ArrayList<VertexAccum> accum){
    VertexKey key=new VertexKey(p,q);Integer idx=indices.get(key);
    if(idx==null){idx=accum.size();indices.put(key,idx);accum.add(new VertexAccum());}
    accum.get(idx).add(p,c);return idx;
  }
}

class STLExporter {
  AppConfig cfg;MeshCompactor compactor;
  STLExporter(AppConfig cfg){this.cfg=cfg;compactor=new MeshCompactor(cfg);}
  void writeBinary(Mesh3D mesh, File file) throws Exception {
    IndexedMesh indexed=compactor.compact(mesh);
    File parent=file.getParentFile();if(parent!=null&&!parent.exists()&&!parent.mkdirs())throw new IOException("Could not create export folder");
    DataOutputStream out = new DataOutputStream(new BufferedOutputStream(new FileOutputStream(file)));
    try {
      byte[] header = new byte[80]; String text="SynKinect Studio compact STL; weld="+indexed.toleranceM+"m";byte[] title=text.getBytes("US-ASCII");
      System.arraycopy(title,0,header,0,Math.min(title.length,80)); out.write(header); writeLEInt(out,indexed.faces.size());
      for(IndexedFace f:indexed.faces){PVector a=indexed.vertices.get(f.a),b=indexed.vertices.get(f.b),c=indexed.vertices.get(f.c);PVector n=PVector.sub(b,a).cross(PVector.sub(c,a));if(n.magSq()>1e-12f)n.normalize();writeVec(out,n,false);writeVec(out,a,true);writeVec(out,b,true);writeVec(out,c,true);writeLEShort(out,0);}
    } finally { out.close(); }
  }
  void writeVec(DataOutputStream out,PVector v,boolean millimeters)throws Exception{float scale=millimeters?1000.0f:1.0f;writeLEFloat(out,v.x*scale);writeLEFloat(out,v.y*scale);writeLEFloat(out,v.z*scale);}
  void writeLEFloat(DataOutputStream out,float value)throws Exception{writeLEInt(out,Float.floatToIntBits(value));}
  void writeLEInt(DataOutputStream out,int value)throws Exception{out.writeByte(value&255);out.writeByte((value>>8)&255);out.writeByte((value>>16)&255);out.writeByte((value>>24)&255);}
  void writeLEShort(DataOutputStream out,int value)throws Exception{out.writeByte(value&255);out.writeByte((value>>8)&255);}
}

class OBJExporter {
  AppConfig cfg;MeshCompactor compactor;
  OBJExporter(AppConfig cfg){this.cfg=cfg;compactor=new MeshCompactor(cfg);}
  void write(Mesh3D mesh,ExternalPhotoManager photos,File obj)throws Exception{
    IndexedMesh indexed=compactor.compact(mesh);File folder=obj.getParentFile();if(folder==null)folder=new File(".");
    if(!folder.exists()&&!folder.mkdirs())throw new IOException("Could not create export folder: "+folder.getAbsolutePath());
    String base=stripExtension(obj.getName());boolean textured=photos!=null&&!photos.cameras.isEmpty();File mtl=new File(folder,base+".mtl"),texDir=new File(folder,base+"_textures");
    if(textured){if(!texDir.exists()&&!texDir.mkdirs())throw new IOException("Could not create texture folder: "+texDir.getAbsolutePath());writeMaterials(photos,texDir,mtl);}
    writeObject(indexed,photos,obj,textured?mtl:null);
  }
  String stripExtension(String name){int p=name.lastIndexOf('.');return p<=0?name:name.substring(0,p);}
  void writeMaterials(ExternalPhotoManager photos,File texDir,File mtl)throws Exception{
    PrintWriter out=new PrintWriter(new BufferedWriter(new FileWriter(mtl)));
    try{
      for(int i=0;i<photos.cameras.size();i++){
        PhotoCamera camera=photos.cameras.get(i);String texName=String.format(Locale.ROOT,"photo_%03d.jpg",i);File target=new File(texDir,texName);
        writeCompressedJpeg(camera.file,target,cfg.exportTextureMaxSize,cfg.exportJpegQuality);
        out.println("newmtl photo_"+i);out.println("Ka 1 1 1");out.println("Kd 1 1 1");out.println("map_Kd "+texDir.getName()+"/"+texName);out.println();
      }
      out.println("newmtl untextured");out.println("Kd 0.75 0.75 0.75");out.println();
    }finally{out.close();}
  }
  void writeCompressedJpeg(File source,File target,int maxSize,float quality)throws Exception{
    BufferedImage input=ImageIO.read(source);if(input==null)throw new IOException("Unsupported image: "+source.getName());
    int w=input.getWidth(),h=input.getHeight();float scale=Math.min(1.0f,maxSize/(float)Math.max(w,h));int nw=Math.max(1,Math.round(w*scale)),nh=Math.max(1,Math.round(h*scale));
    BufferedImage rgb=new BufferedImage(nw,nh,BufferedImage.TYPE_INT_RGB);Graphics2D g=rgb.createGraphics();
    try{g.setRenderingHint(RenderingHints.KEY_INTERPOLATION,RenderingHints.VALUE_INTERPOLATION_BILINEAR);g.drawImage(input,0,0,nw,nh,null);}finally{g.dispose();}
    Iterator<ImageWriter> writers=ImageIO.getImageWritersByFormatName("jpg");if(!writers.hasNext())throw new IOException("JPEG writer unavailable");ImageWriter writer=writers.next();
    ImageOutputStream ios=ImageIO.createImageOutputStream(target);try{writer.setOutput(ios);ImageWriteParam param=writer.getDefaultWriteParam();if(param.canWriteCompressed()){param.setCompressionMode(ImageWriteParam.MODE_EXPLICIT);param.setCompressionQuality(quality);}writer.write(null,new IIOImage(rgb,null,null),param);}finally{try{ios.close();}finally{writer.dispose();}}
  }
  void writeObject(IndexedMesh mesh,ExternalPhotoManager photos,File obj,File mtl)throws Exception{
    PrintWriter out=new PrintWriter(new BufferedWriter(new FileWriter(obj)));
    try{
      if(mtl!=null)out.println("mtllib "+mtl.getName());
      for(int i=0;i<mesh.vertices.size();i++)writeObjVertex(out,mesh.vertices.get(i),mesh.colors.get(i));
      int vtIndex=1;
      for(IndexedFace f:mesh.faces){
        int camIndex=photos==null?-1:photos.bestCamera(f.source);
        if(mtl!=null&&camIndex>=0){
          PhotoCamera camera=photos.cameras.get(camIndex);PVector ua=camera.project(f.source.a),ub=camera.project(f.source.c),uc=camera.project(f.source.b);
          if(ua!=null&&ub!=null&&uc!=null){
            out.println("vt "+ua.x+" "+(1-ua.y));out.println("vt "+ub.x+" "+(1-ub.y));out.println("vt "+uc.x+" "+(1-uc.y));out.println("usemtl photo_"+camIndex);
            out.println("f "+(f.a+1)+"/"+vtIndex+" "+(f.b+1)+"/"+(vtIndex+1)+" "+(f.c+1)+"/"+(vtIndex+2));vtIndex+=3;continue;
          }
        }
        if(mtl!=null)out.println("usemtl untextured");out.println("f "+(f.a+1)+" "+(f.b+1)+" "+(f.c+1));
      }
    }finally{out.close();}
  }
  void writeObjVertex(PrintWriter out,PVector p,int c){float r=((c>>16)&255)/255.0f,g=((c>>8)&255)/255.0f,b=(c&255)/255.0f;out.println("v "+p.x+" "+p.y+" "+p.z+" "+r+" "+g+" "+b);}
}

class PLYExporter {
  AppConfig cfg;MeshCompactor compactor;
  PLYExporter(AppConfig cfg){this.cfg=cfg;compactor=new MeshCompactor(cfg);}
  void write(Mesh3D mesh,File file)throws Exception{
    IndexedMesh indexed=compactor.compact(mesh);File parent=file.getParentFile();if(parent!=null&&!parent.exists()&&!parent.mkdirs())throw new IOException("Could not create export folder");
    BufferedOutputStream raw=new BufferedOutputStream(new FileOutputStream(file));DataOutputStream out=new DataOutputStream(raw);
    try{
      String header="ply\nformat binary_little_endian 1.0\ncomment SynKinect Studio compact indexed mesh\nelement vertex "+indexed.vertices.size()+"\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nelement face "+indexed.faces.size()+"\nproperty list uchar int vertex_indices\nend_header\n";
      out.write(header.getBytes("US-ASCII"));
      for(int i=0;i<indexed.vertices.size();i++){PVector v=indexed.vertices.get(i);int c=indexed.colors.get(i);writeLEFloat(out,v.x);writeLEFloat(out,v.y);writeLEFloat(out,v.z);out.writeByte((c>>16)&255);out.writeByte((c>>8)&255);out.writeByte(c&255);}
      for(IndexedFace f:indexed.faces){out.writeByte(3);writeLEInt(out,f.a);writeLEInt(out,f.b);writeLEInt(out,f.c);}
    }finally{out.close();}
  }
  void writeLEFloat(DataOutputStream out,float value)throws Exception{writeLEInt(out,Float.floatToIntBits(value));}
  void writeLEInt(DataOutputStream out,int value)throws Exception{out.writeByte(value&255);out.writeByte((value>>8)&255);out.writeByte((value>>16)&255);out.writeByte((value>>24)&255);}
}


// ===== SynKinect Studio / 3D Scanner / ExternalPhotos.pde =====
class PhotoCamera {
  int imageWidth,imageHeight; File file; PVector position=new PVector(),target=new PVector(); float horizontalFovRad;
  PVector forward=new PVector(),right=new PVector(),up=new PVector();
  PhotoCamera(int imageWidth,int imageHeight,File file){this.imageWidth=imageWidth;this.imageHeight=imageHeight;this.file=file;}
  void setOrbit(PVector target,float yaw,float pitch,float distance,float hfov){
    this.target.set(target);horizontalFovRad=hfov;
    position.set(target.x+distance*cos(pitch)*sin(yaw),target.y-distance*sin(pitch),target.z+distance*cos(pitch)*cos(yaw));updateBasis();
  }
  void updateBasis(){
    forward=PVector.sub(target,position).normalize();PVector worldUp=new PVector(0,-1,0);right=forward.cross(worldUp);
    if(right.magSq()<1e-8f)right=new PVector(1,0,0);right.normalize();up=right.cross(forward).normalize();
  }
  PVector project(PVector world){
    PVector rel=PVector.sub(world,position);float z=rel.dot(forward);if(z<=0.001f)return null;
    float x=rel.dot(right),y=rel.dot(up),aspect=(float)imageWidth/imageHeight,nx=x/(z*tan(horizontalFovRad*0.5f));
    float verticalFov=2*atan(tan(horizontalFovRad*0.5f)/aspect),ny=y/(z*tan(verticalFov*0.5f));
    float u=0.5f+0.5f*nx,v=0.5f-0.5f*ny;if(u<0||u>1||v<0||v>1)return null;return new PVector(u,v,z);
  }
  float score(Triangle3D t){PVector toCamera=PVector.sub(position,t.center()).normalize();float facing=t.n.dot(toCamera);if(facing<=0.05f)return-1;return project(t.a)==null||project(t.b)==null||project(t.c)==null?-1:facing;}
}

class ExternalPhotoManager {
  ArrayList<PhotoCamera> cameras=new ArrayList<PhotoCamera>(); I18n i18n; String status;
  ExternalPhotoManager(I18n i18n){this.i18n=i18n;status=i18n.tr("photos.none");}

  void importFolder(File folder,PVector target,AppConfig cfg){
    cameras.clear();File[] files=folder.listFiles();if(files==null){status=i18n.tr("photos.empty");return;}
    ArrayList<File> images=new ArrayList<File>();
    for(File f:files){String n=f.getName().toLowerCase(Locale.ROOT);if(n.endsWith(".jpg")||n.endsWith(".jpeg")||n.endsWith(".png"))images.add(f);}
    Collections.sort(images,new Comparator<File>(){public int compare(File a,File b){return a.getName().compareToIgnoreCase(b.getName());}});
    HashMap<String,float[]> saved=readPoseFile(new File(folder,cfg.photoPoseFileName)); int count=images.size();
    for(int i=0;i<count;i++){
      int[] dims=readImageSize(images.get(i));if(dims==null)continue;PhotoCamera cam=new PhotoCamera(dims[0],dims[1],images.get(i));float[] pose=saved.get(images.get(i).getName());
      if(pose!=null&&pose.length>=7){cam.position.set(pose[0],pose[1],pose[2]);cam.target.set(pose[3],pose[4],pose[5]);cam.horizontalFovRad=radians(pose[6]);cam.updateBasis();}
      else{float yaw=TWO_PI*i/max(1,count);cam.setOrbit(target,yaw,radians(cfg.defaultPhotoPitchDeg),cfg.defaultPhotoDistanceM,radians(cfg.defaultPhotoHorizontalFovDeg));}
      cameras.add(cam);
    }
    status=cameras.size()==0?i18n.tr("photos.empty"):i18n.format("photos.loaded",cameras.size());if(!cameras.isEmpty())writePoseTemplate(folder,cfg.photoPoseFileName);
  }

  int[] readImageSize(File file){
    BufferedImage image=null;try{image=ImageIO.read(file);if(image==null)return null;return new int[]{image.getWidth(),image.getHeight()};}
    catch(Exception e){println("Photo read warning: "+file.getName()+" - "+e.getMessage());return null;}finally{if(image!=null)image.flush();}
  }

  HashMap<String,float[]> readPoseFile(File file){
    HashMap<String,float[]> result=new HashMap<String,float[]>();if(!file.exists())return result;
    try{BufferedReader r=new BufferedReader(new FileReader(file));try{r.readLine();String line;while((line=r.readLine())!=null){
      ArrayList<String> p=parseCsvLine(line);if(p.size()<9)continue;try{float[] v={Float.parseFloat(p.get(2)),Float.parseFloat(p.get(3)),Float.parseFloat(p.get(4)),Float.parseFloat(p.get(5)),Float.parseFloat(p.get(6)),Float.parseFloat(p.get(7)),Float.parseFloat(p.get(8))};result.put(p.get(0),v);}catch(NumberFormatException ignored){}
    }}finally{r.close();}}catch(Exception e){println("Photo pose read warning: "+e.getMessage());}return result;
  }

  ArrayList<String> parseCsvLine(String line){
    ArrayList<String> out=new ArrayList<String>();StringBuilder field=new StringBuilder();boolean quoted=false;
    for(int i=0;i<line.length();i++){char ch=line.charAt(i);if(ch=='\"'){if(quoted&&i+1<line.length()&&line.charAt(i+1)=='\"'){field.append('\"');i++;}else quoted=!quoted;}else if(ch==','&&!quoted){out.add(field.toString());field.setLength(0);}else field.append(ch);}out.add(field.toString());return out;
  }
  String csv(String value){if(value==null)return"";return "\""+value.replace("\"","\"\"")+"\"";}

  void writePoseTemplate(File folder,String fileName){
    try{PrintWriter w=new PrintWriter(new File(folder,fileName));try{w.println("file,index,px,py,pz,targetX,targetY,targetZ,horizontalFovDeg");for(int i=0;i<cameras.size();i++){PhotoCamera c=cameras.get(i);w.println(csv(c.file.getName())+","+i+","+c.position.x+","+c.position.y+","+c.position.z+","+c.target.x+","+c.target.y+","+c.target.z+","+degrees(c.horizontalFovRad));}}finally{w.close();}}
    catch(Exception e){println("Photo pose write warning: "+e.getMessage());}
  }
  int bestCamera(Triangle3D t){int best=-1;float score=-1;for(int i=0;i<cameras.size();i++){float s=cameras.get(i).score(t);if(s>score){score=s;best=i;}}return best;}
}


// ===== SynKinect Studio / 3D Scanner / FrameTypes.pde =====
class MotionSample {
  final int FLAG_ACCEL_VALID = 1;
  final int FLAG_TILT_VALID = 2;
  final float COUNTS_PER_G = 819.0f;
  final float GRAVITY_MPS2 = 9.80665f;

  int flags = 0;
  int accelX = 0, accelY = 0, accelZ = 0;
  int tiltTenths = 0;
  long timestampMs = 0;

  boolean accelValid(){ return (flags & FLAG_ACCEL_VALID) != 0; }
  boolean tiltValid(){ return (flags & FLAG_TILT_VALID) != 0; }

  PVector accelerationMps2(){
    float k = GRAVITY_MPS2 / COUNTS_PER_G;
    return new PVector(accelX * k, accelY * k, accelZ * k);
  }

  PVector gravityUnit(){
    if (!accelValid()) return null;
    PVector g = new PVector(accelX, accelY, accelZ);
    float m = g.mag();
    if (m < 1e-4f) return null;
    g.div(m);
    return g;
  }

  boolean gravityReliable(){
    if (!accelValid()) return false;
    float counts = sqrt((float)accelX * accelX + (float)accelY * accelY + (float)accelZ * accelZ);
    return counts > COUNTS_PER_G * 0.72f && counts < COUNTS_PER_G * 1.28f;
  }
}

class Calibration {
  volatile boolean valid = false;
  int depthWidth = scannerProtocol.WIDTH;
  int depthHeight = scannerProtocol.HEIGHT;
  float fx, fy, cx, cy, depthScale;


  void configure(AppConfig cfg) {
    if (cfg == null) { valid = false; return; }
    depthWidth = scannerProtocol.WIDTH;
    depthHeight = scannerProtocol.HEIGHT;
    fx = cfg.depthFx; fy = cfg.depthFy; cx = cfg.depthCx; cy = cfg.depthCy; depthScale = cfg.depthScale;
    valid = fx > 0 && fy > 0 && depthScale > 0;
  }
}

class DepthFrame {
  int frameId, width, height, stride, pixelFormat;
  long frameNumber, timestampUs;
  short[] depth; // unsigned millimetres; 0 means invalid / missing packet data
  int validCount = 0;
  int plausibleCount = 0;
  boolean deviceCalibrated = false;
  boolean transportRecovered = false;
  MotionSample motion = new MotionSample();

  int validPixelCount() { return validCount; }
}


// ===== SynKinect Studio / 3D Scanner / IcpTracker.pde =====
class IcpTracker {
  AppConfig cfg;
  RigidTransform pose = new RigidTransform();
  PointCloud reference = null;
  boolean trackingGood = false;
  float rms = Float.POSITIVE_INFINITY;
  int matches = 0;
  PVector gravityReference = null;
  boolean motionPriorUsed = false;

  IcpTracker(AppConfig cfg){ this.cfg=cfg; }

  void reset(){ pose.setIdentity(); reference=null; trackingGood=false; rms=Float.POSITIVE_INFINITY; matches=0; gravityReference=null; motionPriorUsed=false; }

  RigidTransform track(PointCloud current, MotionSample motion) {
    if(reference==null || reference.size()<cfg.icpMinimumMatches) {
      pose.setIdentity();
      if(motion!=null && motion.gravityReliable()) gravityReference=motion.gravityUnit();
      reference=current.transformed(pose,cfg.icpMaxSamples);
      trackingGood=true; rms=0; matches=reference.size();
      return pose;
    }

    RigidTransform estimate=new RigidTransform(); estimate.set(pose);
    estimate=applyMotionPrior(estimate,motion);
    float finalRms=Float.POSITIVE_INFINITY; int finalMatches=0;

    SpatialHash hash=new SpatialHash(cfg.icpCellSizeM);
    for(PVector p:reference.points) hash.add(p);

    for(int iter=0;iter<cfg.icpIterations;iter++) {
      ArrayList<PVector> src=new ArrayList<PVector>();
      ArrayList<PVector> dst=new ArrayList<PVector>();
      int stride=max(1,current.size()/cfg.icpMaxSamples);
      float sum2=0;
      for(int i=0;i<current.size();i+=stride) {
        PVector world=estimate.apply(current.points.get(i));
        PVector near=hash.nearest(world,cfg.icpMaxDistanceM);
        if(near!=null){ src.add(world); dst.add(near); sum2+=PVector.sub(world,near).magSq(); }
      }
      if(src.size()<cfg.icpMinimumMatches) break;
      finalRms=sqrt(sum2/src.size()); finalMatches=src.size();
      RigidTransform correction=new QuaternionFit().fit(src,dst);
      estimate=correction.multiply(estimate);
    }

    rms=finalRms; matches=finalMatches;
    trackingGood = matches>=cfg.icpMinimumMatches && rms<cfg.icpGoodRmsM;
    if(trackingGood) {
      pose.set(estimate);
      reference=current.transformed(pose,cfg.icpMaxSamples);
    }
    return pose;
  }

  RigidTransform applyMotionPrior(RigidTransform estimate, MotionSample motion){
    motionPriorUsed=false;
    if(motion==null || !motion.gravityReliable()) return estimate;
    PVector g=motion.gravityUnit();
    if(g==null) return estimate;
    if(gravityReference==null){ gravityReference=g.copy(); return estimate; }

    PVector currentWorld=estimate.rotate(g);
    if(currentWorld.magSq()<1e-8f) return estimate;
    currentWorld.normalize();
    PVector target=gravityReference.copy(); target.normalize();
    RigidTransform correction=rotationBetween(currentWorld,target);
    RigidTransform corrected=correction.multiply(estimate);
    // Gravity corrects pitch/roll only. Keep ICP translation unchanged.
    corrected.m[3]=estimate.m[3]; corrected.m[7]=estimate.m[7]; corrected.m[11]=estimate.m[11];
    motionPriorUsed=true;
    return corrected;
  }

  RigidTransform rotationBetween(PVector from, PVector to){
    PVector a=from.copy(); PVector b=to.copy();
    if(a.magSq()<1e-8f || b.magSq()<1e-8f) return new RigidTransform();
    a.normalize(); b.normalize();
    float c=constrain(a.dot(b),-1.0f,1.0f);
    PVector axis=a.cross(b);
    float s=axis.mag();
    if(s<1e-6f){
      if(c>0) return new RigidTransform();
      axis=abs(a.x)<0.8f?a.cross(new PVector(1,0,0)):a.cross(new PVector(0,1,0));
      axis.normalize();
      return axisAngle(axis,PI);
    }
    axis.div(s);
    return axisAngle(axis,atan2(s,c));
  }

  RigidTransform axisAngle(PVector a,float angle){
    float x=a.x,y=a.y,z=a.z,c=cos(angle),ss=sin(angle),t=1-c;
    float[][] R={
      {t*x*x+c, t*x*y-ss*z, t*x*z+ss*y},
      {t*x*y+ss*z, t*y*y+c, t*y*z-ss*x},
      {t*x*z-ss*y, t*y*z+ss*x, t*z*z+c}
    };
    return new RigidTransform().fromRotationTranslation(R,new PVector());
  }

}


// ===== SynKinect Studio / 3D Scanner / KinectSource.pde =====
class RawRgbFrame {
 final byte[] nv12;final long frameNumber,timestampUs;RawRgbFrame(byte[] nv12,long frameNumber,long timestampUs){this.nv12=nv12;this.frameNumber=frameNumber;this.timestampUs=timestampUs;}
}
class RgbdFramePair {
  final DepthFrame depth;final RawRgbFrame rgb;final long sequence,rawSkewUs,residualUs;final float syncQuality;
  RgbdFramePair(DepthFrame d,RawRgbFrame r,long seq,long raw,long residual,float q){depth=d;rgb=r;sequence=seq;rawSkewUs=raw;residualUs=residual;syncQuality=q;}
}

class KinectSource {
  AppConfig config;
  Calibration calibration;
  I18n i18n;

  volatile boolean portReady = false, deviceConnected = false, depthConnected = false, colorConnected = false;
  volatile boolean metricDepthCalibrated = false, running = false;
  volatile boolean lastDepthRecovered = false;
  volatile int acceptedStreams = 0, capabilities = 0, negotiatedMaxPayload = 0;
  volatile String lastTransportError = "", depthWarning = "";
  volatile long depthFrames = 0, colorFrames = 0;
  volatile long depthSequenceGaps=0,colorSequenceGaps=0;
  volatile long lastDepthArrivalMs = 0, lastColorArrivalMs = 0, lastAnyArrivalMs = 0;
  volatile long connectedSinceMs = 0, connectionEpoch = 0, reconnectKicks = 0, lastReconnectKickMs = 0;
  volatile MotionSample latestMotion = new MotionSample();

  Thread worker = null;
  volatile LocalTransport activeScannerPipe = null;
 final Object pipeLock = new Object();
 final Object frameLock = new Object();
 final ArrayDeque<DepthFrame> syncDepth = new ArrayDeque<DepthFrame>();
 final ArrayDeque<RawRgbFrame> syncRgb = new ArrayDeque<RawRgbFrame>();
 final ArrayDeque<RgbdFramePair> rgbdQueue = new ArrayDeque<RgbdFramePair>();
 volatile RgbdFramePair latestRgbdPair=null;
 volatile long pairedFrames=0,droppedUnpairedDepthFrames=0,droppedUnpairedRgbFrames=0,droppedRgbdPairs=0,lastPairedArrivalMs=0;
 volatile float latestSyncResidualMs=Float.NaN,latestRawSyncSkewMs=Float.NaN;
 double syncOffsetUs=0.0;boolean syncOffsetValid=false;long pairSequence=0;
 final byte[] frameHeaderBuffer = new byte[scannerProtocol.FRAME_HEADER_BYTES];
 final long[] lastFrameNumber = new long[]{-1L, -1L, -1L};

  KinectSource(AppConfig config, Calibration calibration, I18n i18n) {
    this.config = config; this.calibration = calibration; this.i18n = i18n;
  }

  void start() {
    if (running) return;
    resetConnectionState(true); droppedUnpairedDepthFrames=0; droppedUnpairedRgbFrames=0; droppedRgbdPairs=0; pairedFrames=0; depthSequenceGaps=0; colorSequenceGaps=0;
    running = true;
    worker = new Thread(new Runnable(){ public void run(){ streamWorkerLoop(); }}, "SynKinectStudio-Scanner-Port");
    worker.setDaemon(true); worker.start();
  }

  void stop() { stop(true); }
  void stop(boolean clearPending) {
    running=false; closeActivePipe();
    Thread t=worker;
    if(t!=null){
      t.interrupt();
      try{t.join(config.workerJoinMs);}catch(InterruptedException ignored){Thread.currentThread().interrupt();}
      if(t.isAlive()){closeActivePipe();t.interrupt();try{t.join(config.workerJoinMs);}catch(InterruptedException ignored){Thread.currentThread().interrupt();}}
    }
    worker=null; synchronized(pipeLock){activeScannerPipe=null;} resetConnectionState(clearPending);
  }

  long monotonicMs() { return System.nanoTime() / 1000000L; }
  void setActivePipe(LocalTransport pipe){ synchronized(pipeLock){ activeScannerPipe=pipe; } }
  void clearActivePipe(LocalTransport pipe){ synchronized(pipeLock){ if(activeScannerPipe==pipe) activeScannerPipe=null; } }
  void closeActivePipe(){ LocalTransport pipe; synchronized(pipeLock){ pipe=activeScannerPipe; activeScannerPipe=null; } closePipe(pipe); }
  void closePipe(LocalTransport pipe){
    if(pipe==null) return;
    try { pipe.close(); } catch(IOException e) { if(running) println("Scanner pipe close warning: " + e.getMessage()); }
  }

  void resetConnectionState(boolean clearPending) {
    portReady=false; deviceConnected=false; depthConnected=false; colorConnected=false; metricDepthCalibrated=false; lastDepthRecovered=false;
    acceptedStreams=0; capabilities=0; negotiatedMaxPayload=0; depthWarning="";
    connectedSinceMs=0; lastDepthArrivalMs=0; lastColorArrivalMs=0; lastAnyArrivalMs=0;
    for(int i=0;i<lastFrameNumber.length;i++) lastFrameNumber[i]=-1L;
    synchronized(frameLock){
      // Never pair samples across a transport epoch. Preserve already-published pairs
      // only when reconnecting in place so consumers can drain them deterministically.
      syncDepth.clear();syncRgb.clear();syncOffsetUs=0;syncOffsetValid=false;latestSyncResidualMs=Float.NaN;latestRawSyncSkewMs=Float.NaN;
      if(clearPending){rgbdQueue.clear();latestRgbdPair=null;pairSequence=0;}
    }
  }

  void updateLiveness() {
    long now = monotonicMs();
    colorConnected = lastColorArrivalMs > 0 && now - lastColorArrivalMs <= config.streamStaleTimeoutMs;
    boolean depthFresh = lastDepthArrivalMs > 0 && now - lastDepthArrivalMs <= config.streamStaleTimeoutMs;
    if (!depthFresh) {
      depthConnected = false; metricDepthCalibrated = false; lastDepthRecovered = false;
      if (lastDepthArrivalMs > 0) depthWarning = i18n.tr("transport.depth_stale");
      else if (portReady && colorFrames >= 30) depthWarning = i18n.tr("transport.depth_no_frames");
    }
    deviceConnected = lastAnyArrivalMs > 0 && now - lastAnyArrivalMs <= config.connectionStaleTimeoutMs;
    // A pipe can remain open while its server-side session is no longer producing frames.
    // Force a fresh subscribe instead of leaving Processing attached to a zombie session.
    long anchor = lastAnyArrivalMs > 0 ? lastAnyArrivalMs : connectedSinceMs;
    if (portReady && anchor > 0 && now - anchor > config.connectionStaleTimeoutMs) requestReconnect("stale-session");
  }

  void requestReconnect(String reason){
    if(!running)return;
    long now=monotonicMs();
    if(now-lastReconnectKickMs<Math.max(100,config.reconnectDelayMs))return;
    lastReconnectKickMs=now; reconnectKicks++; lastTransportError=i18n.format("transport.error",reason);
    closeActivePipe();
  }

  RgbdFramePair pollRgbdPair(){synchronized(frameLock){return rgbdQueue.isEmpty()?null:rgbdQueue.removeFirst();}}
  RgbdFramePair latestRgbdPairAfter(long sequence){synchronized(frameLock){RgbdFramePair p=latestRgbdPair;return p!=null&&p.sequence>sequence?p:null;}}
  int queuedRgbdPairs(){synchronized(frameLock){return rgbdQueue.size();}}
  void clearConsumerPairs(){synchronized(frameLock){rgbdQueue.clear();}}
  RgbSnapshot rgbSnapshot(RgbdFramePair pair){if(pair==null||pair.rgb==null)return null;PImage image=nv12ToImage(pair.rgb.nv12,scannerProtocol.WIDTH,scannerProtocol.HEIGHT);return image==null?null:new RgbSnapshot(image,pair.rgb.frameNumber,pair.rgb.timestampUs,System.currentTimeMillis(),pair.residualUs/1000.0f,pair.rawSkewUs/1000.0f);}
  void offerDepth(DepthFrame f){synchronized(frameLock){syncDepth.addLast(f);trimSyncQueuesLocked();pairRgbdLocked();}}
  void offerRgb(RawRgbFrame f){synchronized(frameLock){syncRgb.addLast(f);trimSyncQueuesLocked();pairRgbdLocked();}}
  void trimSyncQueuesLocked(){while(syncDepth.size()>config.rgbdSyncHistoryFrames){syncDepth.removeFirst();droppedUnpairedDepthFrames++;}while(syncRgb.size()>config.rgbdSyncHistoryFrames){syncRgb.removeFirst();droppedUnpairedRgbFrames++;}}
  void pairRgbdLocked(){
    final long maxResidual=(long)(config.rgbdSyncMaxResidualMs*1000.0f),bootstrap=(long)(config.rgbdSyncBootstrapMaxSkewMs*1000.0f);
    while(!syncDepth.isEmpty()&&!syncRgb.isEmpty()){
      DepthFrame bestD=null;RawRgbFrame bestR=null;long bestMetric=Long.MAX_VALUE,bestDelta=0;
      for(DepthFrame d:syncDepth)for(RawRgbFrame r:syncRgb){long delta=r.timestampUs-d.timestampUs;long metric=Math.abs(delta-(syncOffsetValid?(long)Math.round(syncOffsetUs):0L));if(metric<bestMetric){bestMetric=metric;bestDelta=delta;bestD=d;bestR=r;}}
      long limit=syncOffsetValid?maxResidual:bootstrap;
      if(bestD!=null&&bestMetric<=limit){
        while(!syncDepth.isEmpty()&&syncDepth.peekFirst()!=bestD){syncDepth.removeFirst();droppedUnpairedDepthFrames++;}if(!syncDepth.isEmpty())syncDepth.removeFirst();
        while(!syncRgb.isEmpty()&&syncRgb.peekFirst()!=bestR){syncRgb.removeFirst();droppedUnpairedRgbFrames++;}if(!syncRgb.isEmpty())syncRgb.removeFirst();
        if(!syncOffsetValid){syncOffsetUs=bestDelta;syncOffsetValid=true;}else syncOffsetUs=syncOffsetUs*(1.0-config.rgbdSyncOffsetAlpha)+bestDelta*config.rgbdSyncOffsetAlpha;
        long residual=Math.abs(bestDelta-(long)Math.round(syncOffsetUs)),raw=Math.abs(bestDelta);float q=1.0f-constrain(residual/(float)Math.max(1,maxResidual),0,1);
        RgbdFramePair pair=new RgbdFramePair(bestD,bestR,++pairSequence,raw,residual,q);latestRgbdPair=pair;pairedFrames++;lastPairedArrivalMs=monotonicMs();latestSyncResidualMs=residual/1000.0f;latestRawSyncSkewMs=raw/1000.0f;
        if(rgbdQueue.size()>=config.rgbdQueueFrames){rgbdQueue.removeFirst();droppedRgbdPairs++;}rgbdQueue.addLast(pair);continue;
      }
      DepthFrame d=syncDepth.peekFirst();RawRgbFrame r=syncRgb.peekFirst();long adjusted=(r.timestampUs-d.timestampUs)-(syncOffsetValid?(long)Math.round(syncOffsetUs):0L);
      if(adjusted>limit){syncDepth.removeFirst();droppedUnpairedDepthFrames++;continue;}if(adjusted<-limit){syncRgb.removeFirst();droppedUnpairedRgbFrames++;continue;}break;
    }
  }

  void streamWorkerLoop(){
    while(running){
      LocalTransport pipe=null;
      try{
        resetConnectionState(false);
        pipe=transportFactory.open(scannerProtocol.PIPE_NAME,scannerProtocol.SOCKET_NAME); setActivePipe(pipe);
        subscribe(pipe,scannerProtocol.STREAM_SESSION);
        connectedSinceMs=monotonicMs(); connectionEpoch++; lastTransportError="";
        while(running) readFrame(pipe,scannerProtocol.STREAM_SESSION);
      } catch(Exception e) {
        resetConnectionState(false);
        if(running) lastTransportError=i18n.format("transport.error", safeMessage(e));
      } finally { clearActivePipe(pipe); closePipe(pipe); }
      if(running) try{Thread.sleep(config.reconnectDelayMs);}catch(InterruptedException ignored){if(!running)return;Thread.currentThread().interrupt(); return;}
    }
  }

  void subscribe(LocalTransport pipe,int mask)throws IOException{
    if(mask!=scannerProtocol.STREAM_SESSION) throw new IOException("protocol/stream-mask:"+mask);
    ByteBuffer req=ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN);
    req.putInt(scannerProtocol.MAGIC); req.putInt(scannerProtocol.VERSION); req.putInt(scannerProtocol.CMD_SUBSCRIBE_STREAMS); req.putInt(mask); pipe.write(req.array());

    byte[] rb=new byte[scannerProtocol.REPLY_BYTES]; pipe.readFully(rb); ByteBuffer r=ByteBuffer.wrap(rb).order(ByteOrder.LITTLE_ENDIAN);
    int magic=r.getInt(), version=r.getInt(), result=r.getInt(), accepted=r.getInt();
    int w=r.getInt(), h=r.getInt(), caps=r.getInt(), maxPayload=r.getInt();
    if(magic!=scannerProtocol.MAGIC) throw new IOException("protocol/reply-magic");
    if(version!=scannerProtocol.VERSION) throw new IOException("protocol/version:"+version);
    if(result<0) throw new IOException("protocol/subscribe:0x"+Integer.toHexString(result));
    if(accepted!=mask) throw new IOException("protocol/accepted-mask:"+accepted+"/"+mask);
    if(w!=scannerProtocol.WIDTH||h!=scannerProtocol.HEIGHT) throw new IOException("protocol/dimensions:"+w+"x"+h);
    if((caps&scannerProtocol.REQUIRED_CAPABILITIES)!=scannerProtocol.REQUIRED_CAPABILITIES) throw new IOException("protocol/capabilities:0x"+Integer.toHexString(caps));
    if(maxPayload<scannerProtocol.MAX_PAYLOAD_BYTES) throw new IOException("protocol/max-payload:"+maxPayload);
    acceptedStreams=accepted; capabilities=caps; negotiatedMaxPayload=maxPayload; portReady=true;
  }

  void readFrame(LocalTransport input,int sessionMask)throws IOException{
    input.readFully(frameHeaderBuffer);
    ByteBuffer h=ByteBuffer.wrap(frameHeaderBuffer).order(ByteOrder.LITTLE_ENDIAN);
    int magic=h.getInt(), version=h.getInt(), mode=h.getInt(), w=h.getInt(), hh=h.getInt(), fmt=h.getInt(), bytes=h.getInt(), flags=h.getInt();
    long frameNumber=h.getLong(), tickMs=h.getLong();
    MotionSample motion=new MotionSample();
    motion.flags=h.getInt(); motion.accelX=h.getInt(); motion.accelY=h.getInt(); motion.accelZ=h.getInt(); motion.tiltTenths=h.getInt(); motion.timestampMs=h.getLong();

    if(magic!=scannerProtocol.FRAME_MAGIC) throw new IOException("frame/magic");
    if(version!=scannerProtocol.VERSION) throw new IOException("frame/version:"+version);
    if(w!=scannerProtocol.WIDTH||hh!=scannerProtocol.HEIGHT) throw new IOException("frame/dimensions:"+w+"x"+hh);
    int modeMask=scannerMaskForMode(mode);
    if(modeMask==0 || (sessionMask&modeMask)==0) throw new IOException("frame/mode:"+mode);
    if(bytes<0||bytes>negotiatedMaxPayload||bytes>scannerProtocol.MAX_PAYLOAD_BYTES) throw new IOException("frame/payload:"+bytes);
    if((flags&~scannerProtocol.KNOWN_FRAME_FLAGS)!=0) throw new IOException("frame/flags:0x"+Integer.toHexString(flags));
    boolean dropOutOfOrder=lastFrameNumber[mode]>=0 && frameNumber<=lastFrameNumber[mode];
    if(lastFrameNumber[mode]>=0 && frameNumber>lastFrameNumber[mode]+1){
      long missed=frameNumber-lastFrameNumber[mode]-1;
      if(mode==scannerProtocol.MODE_DEPTH)depthSequenceGaps+=missed;else colorSequenceGaps+=missed;
    }
    if(fmt!=scannerExpectedFormatForMode(mode)) throw new IOException("frame/format:"+mode+"/"+fmt);
    if(bytes!=scannerExpectedPayloadBytesForMode(mode)) throw new IOException("frame/size:"+mode+"/"+bytes);

    byte[] payload=new byte[bytes]; input.readFully(payload);
    long arrival=monotonicMs(); lastAnyArrivalMs=arrival; deviceConnected=true;
    if(dropOutOfOrder){
      lastTransportError=i18n.format("transport.error","frame-order");
      return;
    }
    lastFrameNumber[mode]=frameNumber;
    lastTransportError="";

    if(mode==scannerProtocol.MODE_DEPTH){
      ByteBuffer p=ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN); DepthFrame f=new DepthFrame();
      f.frameId=(int)(frameNumber&0x7FFFFFFF); f.frameNumber=frameNumber; f.timestampUs=tickMs*1000L;
      f.width=scannerProtocol.WIDTH; f.height=scannerProtocol.HEIGHT; f.stride=scannerProtocol.WIDTH*2; f.pixelFormat=scannerProtocol.PIXEL_DEPTH_MM16;
      f.depth=new short[scannerProtocol.WIDTH*scannerProtocol.HEIGHT]; f.motion=motion; latestMotion=motion;
      f.deviceCalibrated=(flags&scannerProtocol.FLAG_DEVICE_CALIBRATED)!=0;
      f.transportRecovered=(flags&scannerProtocol.FLAG_FRAME_RECOVERED)!=0;
      int valid=0, plausible=0;
      for(int i=0;i<f.depth.length;i++){
        short sample=p.getShort(); f.depth[i]=sample; int mm=sample&0xFFFF;
        if(mm!=0) valid++;
        if(mm>=config.depthPlausibleMinMm && mm<=config.depthPlausibleMaxMm) plausible++;
      }
      f.validCount=valid; f.plausibleCount=plausible;
      float ratio=plausible/(float)f.depth.length;
      depthConnected=f.deviceCalibrated && plausible>=config.depthMinValidPixels && ratio>=config.depthMinValidRatio;
      metricDepthCalibrated=f.deviceCalibrated; lastDepthRecovered=f.transportRecovered;
      depthWarning = depthConnected ? "" : i18n.format(f.deviceCalibrated ? "transport.depth_sparse" : "transport.depth_uncalibrated", plausible, ratio*100.0f);
      offerDepth(f);
      depthFrames++; lastDepthArrivalMs=arrival;
    } else {
      offerRgb(new RawRgbFrame(payload,frameNumber,tickMs*1000L));
      colorConnected=true; colorFrames++; lastColorArrivalMs=arrival;
    }
  }

  PImage nv12ToImage(byte[] data,int w,int h){
    if(data==null||data.length!=w*h*3/2) return null;
    PImage img=createImage(w,h,RGB); img.loadPixels(); int ySize=w*h;
    for(int y=0;y<h;y++) for(int x=0;x<w;x++){
      int yi=data[y*w+x]&0xFF; int uv=ySize+(y/2)*w+(x&~1); int u=(data[uv]&0xFF)-128, v=(data[uv+1]&0xFF)-128;
      int c=max(0,yi-16); int rr=(298*c+409*v+128)>>8, gg=(298*c-100*u-208*v+128)>>8, bb=(298*c+516*u+128)>>8;
      img.pixels[y*w+x]=color(constrain(rr,0,255),constrain(gg,0,255),constrain(bb,0,255));
    }
    img.updatePixels(); return img;
  }

  String displayError(){
    if(lastTransportError.length()>0)return i18n.tr("transport.unavailable");
    if(droppedRgbdPairs>0)return "RGBD queue dropped "+droppedRgbdPairs+" paired frames";
    return depthWarning;
  }
  String safeMessage(Exception e){ String m=e.getMessage(); return(m==null||m.length()==0)?e.getClass().getSimpleName():m; }
}


// ===== SynKinect Studio / 3D Scanner / Localization.pde =====
class I18n extends ModuleI18n {
  I18n(String requested){super("scanner",requested);}
}


class UiTheme {
  // Shared panel policy: high-contrast dark surfaces with a restrained blue
  // status accent. Geometry and typography remain centralized here.
  final int WINDOW_WIDTH = 1600;
  final int WINDOW_HEIGHT = 980;
  final int BG = 0xFF11151A;
  final int SURFACE = 0xFF181E25;
  final int SURFACE_ALT = 0xFF202832;
  final int SURFACE_RAISED = 0xFF293440;
  final int BORDER = 0xFF35414D;
  final int TEXT = 0xFFF4F7FA;
  final int TEXT_MUTED = 0xFFAAB6C2;
  final int ACCENT = 0xFF68A9E8;
  final int ACCENT_SOFT = 0xFF203A52;
  final int GOOD = 0xFF7CC7A0;
  final int WARN = 0xFFE4B86B;
  final int BAD = 0xFFE17D7D;
  final int GRID = 0xFF35404A;
  final int PREVIEW = 0xFF0B0F13;
  final int MESH = 0xFFD6E5F3;
  final int RADIUS = 14;
  final int MARGIN = 20;
  final int GAP = 14;
  final int HEADER_H = 68;
  final int TOOLBAR_H = 122;
  final int SIDEBAR_W = 430;
  final int CARD_TITLE_H = 44;

  // Semantic type scale. No scanner panel should contain literal textSize values.
  final int FONT_TINY = 12;
  final int FONT_SMALL = 14;
  final int FONT_BODY = 15;
  final int FONT_METRIC = 19;
  final int FONT_TITLE = 27;
}

void initializeScannerTypography(){
  String regular=resolveInstalledFont(config.uiFontFamily,config.uiFontFallback);
  String heading=resolveInstalledFont(config.uiHeadingFontFamily,regular);
  scannerFontRegular=createFont(regular,uiTheme.FONT_BODY,true);
  scannerFontHeading=createFont(heading,uiTheme.FONT_TITLE,true);
  textFont(scannerFontRegular);
  textLeading(uiTheme.FONT_BODY*1.28f);
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
  textSize(responsiveFontSize(size));
}


// ===== SynKinect Studio / 3D Scanner / Math3D.pde =====
class RigidTransform {
  float[] m = new float[16];

  RigidTransform() { setIdentity(); }

  void setIdentity() {
    Arrays.fill(m, 0);
    m[0] = m[5] = m[10] = m[15] = 1;
  }

  void set(RigidTransform o) { arrayCopy(o.m, m); }
  void setArray(float[] a) { for (int i = 0; i < 16; i++) m[i] = a[i]; }

  PVector apply(PVector p) {
    return new PVector(
      m[0]*p.x + m[1]*p.y + m[2]*p.z + m[3],
      m[4]*p.x + m[5]*p.y + m[6]*p.z + m[7],
      m[8]*p.x + m[9]*p.y + m[10]*p.z + m[11]
    );
  }

  PVector rotate(PVector p) {
    return new PVector(
      m[0]*p.x + m[1]*p.y + m[2]*p.z,
      m[4]*p.x + m[5]*p.y + m[6]*p.z,
      m[8]*p.x + m[9]*p.y + m[10]*p.z
    );
  }

  PVector translation() { return new PVector(m[3], m[7], m[11]); }

  RigidTransform multiply(RigidTransform b) {
    RigidTransform r = new RigidTransform();
    for (int row = 0; row < 4; row++) {
      for (int col = 0; col < 4; col++) {
        float s = 0;
        for (int k = 0; k < 4; k++) s += m[row*4+k] * b.m[k*4+col];
        r.m[row*4+col] = s;
      }
    }
    return r;
  }

  RigidTransform fromRotationTranslation(float[][] R, PVector t) {
    RigidTransform x = new RigidTransform();
    x.m[0]=R[0][0]; x.m[1]=R[0][1]; x.m[2]=R[0][2]; x.m[3]=t.x;
    x.m[4]=R[1][0]; x.m[5]=R[1][1]; x.m[6]=R[1][2]; x.m[7]=t.y;
    x.m[8]=R[2][0]; x.m[9]=R[2][1]; x.m[10]=R[2][2]; x.m[11]=t.z;
    return x;
  }
}

class QuaternionFit {
  RigidTransform fit(ArrayList<PVector> src, ArrayList<PVector> dst) {
    int n = min(src.size(), dst.size());
    if (n < 3) return new RigidTransform();
    PVector cs = new PVector(), cd = new PVector();
    for (int i=0;i<n;i++) { cs.add(src.get(i)); cd.add(dst.get(i)); }
    cs.div(n); cd.div(n);

    float Sxx=0,Sxy=0,Sxz=0,Syx=0,Syy=0,Syz=0,Szx=0,Szy=0,Szz=0;
    for (int i=0;i<n;i++) {
      PVector a=PVector.sub(src.get(i),cs), b=PVector.sub(dst.get(i),cd);
      Sxx+=a.x*b.x; Sxy+=a.x*b.y; Sxz+=a.x*b.z;
      Syx+=a.y*b.x; Syy+=a.y*b.y; Syz+=a.y*b.z;
      Szx+=a.z*b.x; Szy+=a.z*b.y; Szz+=a.z*b.z;
    }
    float tr=Sxx+Syy+Szz;
    float[][] N={
      {tr, Syz-Szy, Szx-Sxz, Sxy-Syx},
      {Syz-Szy, Sxx-Syy-Szz, Sxy+Syx, Szx+Sxz},
      {Szx-Sxz, Sxy+Syx, -Sxx+Syy-Szz, Syz+Szy},
      {Sxy-Syx, Szx+Sxz, Syz+Szy, -Sxx-Syy+Szz}
    };
    float[] q={1,0,0,0};
    for(int it=0;it<32;it++) {
      float[] nq=new float[4];
      for(int r=0;r<4;r++) for(int c=0;c<4;c++) nq[r]+=N[r][c]*q[c];
      float norm=sqrt(nq[0]*nq[0]+nq[1]*nq[1]+nq[2]*nq[2]+nq[3]*nq[3]);
      if(norm<1e-9f) break;
      for(int k=0;k<4;k++) q[k]=nq[k]/norm;
    }
    float w=q[0],x=q[1],y=q[2],z=q[3];
    float[][] R={
      {1-2*y*y-2*z*z, 2*x*y-2*z*w, 2*x*z+2*y*w},
      {2*x*y+2*z*w, 1-2*x*x-2*z*z, 2*y*z-2*x*w},
      {2*x*z-2*y*w, 2*y*z+2*x*w, 1-2*x*x-2*y*y}
    };
    PVector rcs=new PVector(
      R[0][0]*cs.x+R[0][1]*cs.y+R[0][2]*cs.z,
      R[1][0]*cs.x+R[1][1]*cs.y+R[1][2]*cs.z,
      R[2][0]*cs.x+R[2][1]*cs.y+R[2][2]*cs.z
    );
    PVector t=PVector.sub(cd,rcs);
    return new RigidTransform().fromRotationTranslation(R,t);
  }
}


// ===== SynKinect Studio / 3D Scanner / Mesh.pde =====
class Triangle3D {
  PVector a,b,c,n;
  int ca,cb,cc;
  Triangle3D(PVector a,PVector b,PVector c){this(a,b,c,0,0,0);}
  Triangle3D(PVector a,PVector b,PVector c,int ca,int cb,int cc){this.a=a;this.b=b;this.c=c;this.ca=ca;this.cb=cb;this.cc=cc;recalc();}
  void recalc(){ n=PVector.sub(b,a).cross(PVector.sub(c,a)); if(n.magSq()>1e-12f)n.normalize(); }
  PVector center(){ return new PVector((a.x+b.x+c.x)/3,(a.y+b.y+c.y)/3,(a.z+b.z+c.z)/3); }
}

class Mesh3D {
  ArrayList<Triangle3D> triangles=new ArrayList<Triangle3D>();
  ArrayList<PShape> renderChunks=new ArrayList<PShape>();
  int renderCursor=0;
  boolean renderCacheComplete=false;
 final int renderChunkTriangles=12000;

  void clear(){triangles.clear();invalidateRenderCache();}
  int triangleCount(){return triangles.size();}
  void addTriangle(PVector a,PVector b,PVector c){addTriangle(a,b,c,0,0,0);}
  void addTriangle(PVector a,PVector b,PVector c,int ca,int cb,int cc){
    if(PVector.sub(b,a).cross(PVector.sub(c,a)).magSq()>1e-12f) triangles.add(new Triangle3D(a,b,c,ca,cb,cc));
  }
  void recalculateNormals(){for(Triangle3D t:triangles)t.recalc();invalidateRenderCache();}
  void invalidateRenderCache(){renderChunks.clear();renderCursor=0;renderCacheComplete=triangles.size()==0;}

  Mesh3D deepCopy(){
    Mesh3D copy=new Mesh3D();
    for(Triangle3D t:triangles) copy.addTriangle(t.a.copy(),t.b.copy(),t.c.copy(),t.ca,t.cb,t.cc);
    return copy;
  }

  PVector boundsCenter(){
    if(triangles.size()==0) return new PVector();
    float minX=Float.POSITIVE_INFINITY,minY=Float.POSITIVE_INFINITY,minZ=Float.POSITIVE_INFINITY;
    float maxX=Float.NEGATIVE_INFINITY,maxY=Float.NEGATIVE_INFINITY,maxZ=Float.NEGATIVE_INFINITY;
    for(Triangle3D t:triangles){
      PVector[] v={t.a,t.b,t.c};
      for(PVector p:v){ minX=min(minX,p.x); minY=min(minY,p.y); minZ=min(minZ,p.z); maxX=max(maxX,p.x); maxY=max(maxY,p.y); maxZ=max(maxZ,p.z); }
    }
    return new PVector((minX+maxX)*0.5f,(minY+maxY)*0.5f,(minZ+maxZ)*0.5f);
  }

  float boundsRadius(){
    if(triangles.size()==0) return 0.2f;
    PVector c=boundsCenter();
    float r=0.0f;
    for(Triangle3D t:triangles){
      r=max(r,max(PVector.dist(c,t.a),max(PVector.dist(c,t.b),PVector.dist(c,t.c))));
    }
    return max(r,0.01f);
  }

  int renderColor(int c,int fallback){ return ((c>>>24)&255)==0 ? fallback : c; }

  void buildNextRenderChunk(int fallbackShade){
    if(renderCacheComplete)return;
    int end=min(triangles.size(),renderCursor+renderChunkTriangles);
    if(end<=renderCursor){renderCacheComplete=true;return;}
    PShape chunk=createShape();
    chunk.beginShape(TRIANGLES);chunk.noStroke();
    for(int i=renderCursor;i<end;i++){
      Triangle3D t=triangles.get(i);
      chunk.normal(t.n.x,t.n.y,t.n.z);
      chunk.fill(renderColor(t.ca,fallbackShade));chunk.vertex(t.a.x,t.a.y,t.a.z);
      chunk.fill(renderColor(t.cb,fallbackShade));chunk.vertex(t.b.x,t.b.y,t.b.z);
      chunk.fill(renderColor(t.cc,fallbackShade));chunk.vertex(t.c.x,t.c.y,t.c.z);
    }
    chunk.endShape();renderChunks.add(chunk);renderCursor=end;renderCacheComplete=renderCursor>=triangles.size();
  }

  void drawMesh(int shade){
    if(triangles.size()==0)return;
    // Retained PShape chunks are compiled incrementally on the render thread.
    // Heavy mesh extraction/polish runs elsewhere; after this cache is warm no
    // triangle list is rebuilt every frame.
    if(!renderCacheComplete)buildNextRenderChunk(shade);
    for(PShape chunk:renderChunks)shape(chunk);
  }
}


// ===== SynKinect Studio / 3D Scanner / MeshEditing.pde =====
class MeshEditor {
 final AppConfig cfg;
  MeshEditor(AppConfig cfg){ this.cfg=cfg; }

  Mesh3D clean(Mesh3D source){
    Mesh3D filtered=new Mesh3D();
    if(source==null)return filtered;
    for(Triangle3D t:source.triangles){
      float ab=PVector.dist(t.a,t.b),bc=PVector.dist(t.b,t.c),ca=PVector.dist(t.c,t.a);
      float area=PVector.sub(t.b,t.a).cross(PVector.sub(t.c,t.a)).mag()*0.5f;
      if(area<cfg.meshCleanupMinAreaM2)continue;
      if(max(ab,max(bc,ca))>cfg.meshCleanupMaxEdgeM)continue;
      filtered.addTriangle(t.a.copy(),t.b.copy(),t.c.copy(),t.ca,t.cb,t.cc);
    }
    Mesh3D components=removeSmallComponents(filtered);
    components.recalculateNormals();return components;
  }

  Mesh3D smooth(Mesh3D source){
    if(source==null)return new Mesh3D();
    Mesh3D work=source.deepCopy();
    for(int i=0;i<cfg.meshSmoothIterations;i++)smoothPass(work,cfg.meshSmoothLambda);
    work.recalculateNormals();return work;
  }

  Mesh3D polish(Mesh3D source){
    Mesh3D work=clean(source);
    // Taubin lambda/mu smoothing removes voxel stair-stepping without the
    // strong shrinkage of repeated plain Laplacian smoothing.
    for(int i=0;i<cfg.meshPolishIterations;i++){
      smoothPass(work,cfg.meshPolishLambda);
      smoothPass(work,cfg.meshPolishMu);
    }
    work.recalculateNormals();return work;
  }

  void smoothPass(Mesh3D mesh,float factor){
    HashMap<Long,PVector> sum=new HashMap<Long,PVector>();
    HashMap<Long,Integer> count=new HashMap<Long,Integer>();
    HashMap<Long,HashSet<Long>> neighbors=new HashMap<Long,HashSet<Long>>();
    for(Triangle3D t:mesh.triangles){
      long ka=key(t.a),kb=key(t.b),kc=key(t.c);
      addVertex(sum,count,ka,t.a);addVertex(sum,count,kb,t.b);addVertex(sum,count,kc,t.c);
      connect(neighbors,ka,kb);connect(neighbors,kb,kc);connect(neighbors,kc,ka);
    }
    HashMap<Long,PVector> center=new HashMap<Long,PVector>(sum.size()*2);
    for(Long k:sum.keySet()){PVector p=sum.get(k).copy();p.div(max(1,count.get(k)));center.put(k,p);}
    HashMap<Long,PVector> moved=new HashMap<Long,PVector>(center.size()*2);
    for(Long k:center.keySet()){
      PVector base=center.get(k),avg=new PVector();int n=0;HashSet<Long> adj=neighbors.get(k);
      if(adj!=null)for(Long other:adj){PVector q=center.get(other);if(q!=null){avg.add(q);n++;}}
      if(n<2){moved.put(k,base.copy());continue;}
      avg.div(n);PVector delta=PVector.sub(avg,base);moved.put(k,PVector.add(base,PVector.mult(delta,factor)));
    }
    for(Triangle3D t:mesh.triangles){PVector a=moved.get(key(t.a)),b=moved.get(key(t.b)),c=moved.get(key(t.c));if(a!=null)t.a.set(a);if(b!=null)t.b.set(b);if(c!=null)t.c.set(c);}
  }

  Mesh3D removeSmallComponents(Mesh3D source){
    if(source==null||source.triangleCount()==0)return new Mesh3D();
    int n=source.triangleCount();
    HashMap<Long,ArrayList<Integer>> incidence=new HashMap<Long,ArrayList<Integer>>();
    for(int i=0;i<n;i++){
      Triangle3D t=source.triangles.get(i);addIncidence(incidence,key(t.a),i);addIncidence(incidence,key(t.b),i);addIncidence(incidence,key(t.c),i);
    }
    boolean[] seen=new boolean[n];ArrayList<ArrayList<Integer>> groups=new ArrayList<ArrayList<Integer>>();int largest=0;
    for(int seed=0;seed<n;seed++){
      if(seen[seed])continue;ArrayList<Integer> group=new ArrayList<Integer>();ArrayDeque<Integer> q=new ArrayDeque<Integer>();q.add(seed);seen[seed]=true;
      while(!q.isEmpty()){
        int i=q.removeFirst();group.add(i);Triangle3D t=source.triangles.get(i);long[] keys={key(t.a),key(t.b),key(t.c)};
        for(long k:keys){ArrayList<Integer> linked=incidence.get(k);if(linked==null)continue;for(Integer other:linked)if(!seen[other]){seen[other]=true;q.addLast(other);}}
      }
      groups.add(group);largest=max(largest,group.size());
    }
    int threshold=max(cfg.meshMinimumComponentTriangles,round(largest*cfg.meshMinimumComponentRatio));
    Mesh3D out=new Mesh3D();
    for(ArrayList<Integer> group:groups)if(group.size()>=threshold)for(Integer idx:group){Triangle3D t=source.triangles.get(idx);out.addTriangle(t.a.copy(),t.b.copy(),t.c.copy(),t.ca,t.cb,t.cc);}
    if(out.triangleCount()==0){
      ArrayList<Integer> best=null;for(ArrayList<Integer> group:groups)if(best==null||group.size()>best.size())best=group;
      if(best!=null)for(Integer idx:best){Triangle3D t=source.triangles.get(idx);out.addTriangle(t.a.copy(),t.b.copy(),t.c.copy(),t.ca,t.cb,t.cc);}
    }
    return out;
  }

  Mesh3D center(Mesh3D source){
    if(source==null)return new Mesh3D();
    Mesh3D out=source.deepCopy();PVector c=out.boundsCenter();
    for(Triangle3D t:out.triangles){t.a.sub(c);t.b.sub(c);t.c.sub(c);t.recalc();}out.invalidateRenderCache();return out;
  }

  long key(PVector p){
    float q=max(0.000001f,cfg.meshWeldToleranceM);long x=round(p.x/q),y=round(p.y/q),z=round(p.z/q);
    return ((x&0x1FFFFFL)<<42)|((y&0x1FFFFFL)<<21)|(z&0x1FFFFFL);
  }
  void addIncidence(HashMap<Long,ArrayList<Integer>> m,long k,int i){ArrayList<Integer> list=m.get(k);if(list==null){list=new ArrayList<Integer>();m.put(k,list);}list.add(i);}
  void addVertex(HashMap<Long,PVector> sum,HashMap<Long,Integer> count,long k,PVector p){PVector acc=sum.get(k);if(acc==null){acc=new PVector();sum.put(k,acc);count.put(k,0);}acc.add(p);count.put(k,count.get(k)+1);}
  void connect(HashMap<Long,HashSet<Long>> n,long a,long b){if(a==b)return;HashSet<Long> aa=n.get(a);if(aa==null){aa=new HashSet<Long>();n.put(a,aa);}aa.add(b);HashSet<Long> bb=n.get(b);if(bb==null){bb=new HashSet<Long>();n.put(b,bb);}bb.add(a);}
}


// ===== SynKinect Studio / 3D Scanner / PointCloud.pde =====
class PointCloudBuilder {
  AppConfig cfg;
  RgbDepthRegistration registration;
  PointCloudBuilder(AppConfig cfg,RgbDepthRegistration registration) { this.cfg = cfg; this.registration=registration; }

  PointCloud build(DepthFrame f, Calibration c, int step, float targetZ, float band, PointCloudBuildStats stats, RgbSnapshot rgb) {
    PointCloud cloud = new PointCloud();
    if (stats != null) stats.clear();
    if (f == null || f.depth == null || c == null || !c.valid) return cloud;
    if(cfg.meshColorEnabled && registration!=null) registration.prepareFrame(f,rgb);
    int safeStep = max(1, step);
    for (int v = 0; v < f.height; v += safeStep) {
      for (int u = 0; u < f.width; u += safeStep) {
        if (stats != null) stats.sourcePixels++;
        int index=v*f.width+u;
        int raw = f.depth[index] & 0xFFFF;
        if (raw == 0) continue;
        if (stats != null) stats.nonZero++;
        int filteredMm=robustDepthMm(f,u,v,raw,safeStep);
        float z = filteredMm * c.depthScale;
        if (z < cfg.minDepthM || z > cfg.maxDepthM) { if (stats != null) stats.rejectedRange++; continue; }
        if (stats != null) stats.inRange++;
        if (!Float.isNaN(targetZ) && abs(z - targetZ) > band) { if (stats != null) stats.rejectedBand++; continue; }
        if (cfg.pointCloudSpatialFilter && !spatiallyConsistent(f, u, v, filteredMm, safeStep)) { if (stats != null) stats.rejectedSpatial++; continue; }
        float x = registration!=null ? registration.pointX(index,z) : (u-c.cx)*z/c.fx;
        float y = registration!=null ? registration.pointY(index,z) : (v-c.cy)*z/c.fy;
        int rgbColor = cfg.meshColorEnabled && registration!=null ? registration.colorAt(index) : 0;
        cloud.add(new PVector(x,y,z),rgbColor);
        if (stats != null) stats.accepted++;
      }
    }
    return cloud;
  }

  int robustDepthMm(DepthFrame f,int u,int v,int centerMm,int step){
    // Edge-preserving 3x3 robust median. A single bad centre sample is replaced
    // only when a clear local surface majority exists; mixed-depth edges keep
    // their original centre value rather than being blurred across surfaces.
    int toleranceMm=max(1,round(cfg.pointCloudNeighborToleranceM*1000.0f));
    int[] neighbors=new int[8];int n=0;
    for(int dy=-step;dy<=step;dy+=step)for(int dx=-step;dx<=step;dx+=step){
      if(dx==0&&dy==0)continue;int x=u+dx,y=v+dy;if(x<0||x>=f.width||y<0||y>=f.height)continue;int mm=f.depth[y*f.width+x]&0xffff;if(mm!=0)neighbors[n++]=mm;
    }
    if(n<3)return centerMm;
    Arrays.sort(neighbors,0,n);int median=neighbors[n/2],coherent=0;for(int i=0;i<n;i++)if(abs(neighbors[i]-median)<=toleranceMm)coherent++;
    int majority=max(3,(int)Math.ceil(n*0.625));
    if(coherent<majority)return centerMm;
    if(abs(centerMm-median)>toleranceMm)return median;
    int[] values=new int[9];int m=0;values[m++]=centerMm;for(int i=0;i<n;i++)if(abs(neighbors[i]-median)<=toleranceMm)values[m++]=neighbors[i];Arrays.sort(values,0,m);return values[m/2];
  }

  boolean spatiallyConsistent(DepthFrame f, int u, int v, int centerMm, int step) {
    int toleranceMm=max(1,round(cfg.pointCloudNeighborToleranceM*1000.0f));int checked=0,consistent=0;
    for(int dy=-step;dy<=step;dy+=step)for(int dx=-step;dx<=step;dx+=step){
      if(dx==0&&dy==0)continue;int x=u+dx,y=v+dy;if(x<0||x>=f.width||y<0||y>=f.height)continue;int mm=f.depth[y*f.width+x]&0xffff;if(mm==0)continue;checked++;if(abs(mm-centerMm)<=toleranceMm)consistent++;
    }
    return checked<=2||consistent>=max(2,(int)Math.ceil(checked*0.50));
  }
}

class PointCloud {
  ArrayList<PVector> points = new ArrayList<PVector>();
  int[] colors = new int[4096];
  int size() { return points.size(); }
  void add(PVector p,int c){
    int index=points.size();points.add(p);
    if(index>=colors.length)colors=Arrays.copyOf(colors,max(index+1,colors.length*2));
    colors[index]=c;
  }
  int colorAt(int i){return i>=0&&i<points.size()?colors[i]:0;}

  PVector centroid() {
    PVector c = new PVector(); if (points.size() == 0) return c;
    for (PVector p : points) c.add(p); return c.div(points.size());
  }
  PVector centroidTransformed(RigidTransform t) {
    PVector c = new PVector(); if (points.size() == 0) return c;
    for (PVector p : points) c.add(t.apply(p)); return c.div(points.size());
  }
  PointCloud transformed(RigidTransform t, int maxPoints) {
    PointCloud out = new PointCloud(); int stride = max(1, points.size() / max(1, maxPoints));
    for (int i = 0; i < points.size(); i += stride) out.add(t.apply(points.get(i)),colorAt(i)); return out;
  }
}

class SpatialHash {
  float cell;
  HashMap<Long, ArrayList<PVector>> buckets = new HashMap<Long, ArrayList<PVector>>();
  SpatialHash(float cell) { this.cell = max(0.000001f, cell); }

  long key(int x,int y,int z) {
    long a=((long)x & 0x1FFFFF), b=((long)y & 0x1FFFFF), c=((long)z & 0x1FFFFF);
    return (a<<42)|(b<<21)|c;
  }
  int cellCoord(float v){ return floor(v/cell); }
  void add(PVector p) {
    long k=key(cellCoord(p.x),cellCoord(p.y),cellCoord(p.z)); ArrayList<PVector> list=buckets.get(k);
    if(list==null){ list=new ArrayList<PVector>(); buckets.put(k,list); } list.add(p);
  }

  PVector nearest(PVector p,float maxDist) {
    int cx=cellCoord(p.x), cy=cellCoord(p.y), cz=cellCoord(p.z);
    int radius=max(1, ceil(maxDist/cell));
    PVector best=null; float best2=maxDist*maxDist;
    for(int dz=-radius;dz<=radius;dz++) for(int dy=-radius;dy<=radius;dy++) for(int dx=-radius;dx<=radius;dx++) {
      ArrayList<PVector> list=buckets.get(key(cx+dx,cy+dy,cz+dz));
      if(list==null) continue;
      for(PVector q:list){ float d2=PVector.sub(p,q).magSq(); if(d2<best2){best2=d2;best=q;} }
    }
    return best;
  }
}


// ===== SynKinect Studio / 3D Scanner / RgbRegistration.pde =====
class RgbProjection {
  float u, v, z;
  boolean valid;
}

class RgbDepthRegistration {
 final AppConfig cfg;
 final Calibration depth;
  float[] rayX, rayY;
  int[] registeredColor;
  float[] rgbZBuffer;
  int preparedFrameId = -1;
  long preparedRgbFrameNumber = -1;
  int prepareCount = 0;
  volatile float autoOffsetX = 0.0f, autoOffsetY = 0.0f;
  volatile float lastSyncSkewMs = Float.NaN;
  volatile float lastRefineGain = 1.0f;
  volatile int lastRefineEdges = 0;

  RgbDepthRegistration(AppConfig cfg, Calibration depth) {
    this.cfg = cfg;
    this.depth = depth;
    rebuildDepthRays();
  }

  void rebuildDepthRays() {
    int count = scannerProtocol.WIDTH * scannerProtocol.HEIGHT;
    rayX = new float[count]; rayY = new float[count];
    for (int v=0; v<scannerProtocol.HEIGHT; v++) for (int u=0; u<scannerProtocol.WIDTH; u++) {
      float xd=(u-depth.cx)/depth.fx, yd=(v-depth.cy)/depth.fy;
      float x=xd, y=yd;
      // Iterative inverse Brown-Conrady distortion. Five iterations are enough
      // for Kinect-v1 VGA geometry and avoid treating distorted pixels as rays.
      for (int it=0; it<5; it++) {
        float r2=x*x+y*y, r4=r2*r2, r6=r4*r2;
        float radial=1.0f+cfg.depthK1*r2+cfg.depthK2*r4+cfg.depthK3*r6;
        if (abs(radial)<1e-6f) break;
        float dx=2.0f*cfg.depthP1*x*y+cfg.depthP2*(r2+2.0f*x*x);
        float dy=cfg.depthP1*(r2+2.0f*y*y)+2.0f*cfg.depthP2*x*y;
        x=(xd-dx)/radial; y=(yd-dy)/radial;
      }
      int i=v*scannerProtocol.WIDTH+u; rayX[i]=x; rayY[i]=y;
    }
  }

  float pointX(int index,float z){ return rayX[index]*z; }
  float pointY(int index,float z){ return rayY[index]*z; }

  void project(int index,float z,RgbProjection out,float extraX,float extraY) {
    float xd=rayX[index]*z, yd=rayY[index]*z;
    float xc=cfg.regR00*xd+cfg.regR01*yd+cfg.regR02*z+cfg.regTx;
    float yc=cfg.regR10*xd+cfg.regR11*yd+cfg.regR12*z+cfg.regTy;
    float zc=cfg.regR20*xd+cfg.regR21*yd+cfg.regR22*z+cfg.regTz;
    if (zc<=0.001f) { out.valid=false; return; }
    float x=xc/zc, y=yc/zc, r2=x*x+y*y, r4=r2*r2, r6=r4*r2;
    float radial=1.0f+cfg.rgbK1*r2+cfg.rgbK2*r4+cfg.rgbK3*r6;
    float xDist=x*radial+2.0f*cfg.rgbP1*x*y+cfg.rgbP2*(r2+2.0f*x*x);
    float yDist=y*radial+cfg.rgbP1*(r2+2.0f*y*y)+2.0f*cfg.rgbP2*x*y;
    out.u=cfg.rgbFx*xDist+cfg.rgbCx+cfg.colorRegistrationOffsetX+autoOffsetX+extraX;
    out.v=cfg.rgbFy*yDist+cfg.rgbCy+cfg.colorRegistrationOffsetY+autoOffsetY+extraY;
    out.z=zc; out.valid=true;
  }

  void prepareFrame(DepthFrame frame,RgbSnapshot rgb) {
    if (frame==null || frame.depth==null || rgb==null || rgb.pixels==null) {
      preparedFrameId=-1; preparedRgbFrameNumber=-1; return;
    }
    if (preparedFrameId==frame.frameId && preparedRgbFrameNumber==rgb.frameNumber) return;
    prepareCount++;
    lastSyncSkewMs=Float.isNaN(rgb.syncResidualMs)?Math.abs(frame.timestampUs-rgb.timestampUs)/1000.0f:rgb.syncResidualMs;
    if (lastSyncSkewMs>cfg.rgbMaxSyncSkewMs) {
      preparedFrameId=-1; preparedRgbFrameNumber=-1; return;
    }

    if (cfg.rgbAutoRefine && cfg.rgbRefineSearchPx>0 && (prepareCount%cfg.rgbRefineEveryFrames)==0)
      refineFineOffset(frame,rgb);

    int depthPixels=frame.width*frame.height;
    if (registeredColor==null || registeredColor.length!=depthPixels) registeredColor=new int[depthPixels];
    Arrays.fill(registeredColor,0);

    if (cfg.rgbOcclusionFilter) {
      int rgbPixels=rgb.width*rgb.height;
      if (rgbZBuffer==null || rgbZBuffer.length!=rgbPixels) rgbZBuffer=new float[rgbPixels];
      Arrays.fill(rgbZBuffer,Float.POSITIVE_INFINITY);
      RgbProjection q=new RgbProjection();
      for(int i=0;i<depthPixels;i++) {
        int mm=frame.depth[i]&0xFFFF; if(mm==0)continue;
        float z=mm*depth.depthScale; if(z<cfg.minDepthM||z>cfg.maxDepthM)continue;
        project(i,z,q,0,0); if(!q.valid)continue;
        int x=round(q.u),y=round(q.v); if(x<0||x>=rgb.width||y<0||y>=rgb.height)continue;
        int ri=y*rgb.width+x; if(q.z<rgbZBuffer[ri])rgbZBuffer[ri]=q.z;
      }
    }

    RgbProjection q=new RgbProjection();
    for(int i=0;i<depthPixels;i++) {
      int mm=frame.depth[i]&0xFFFF; if(mm==0)continue;
      float z=mm*depth.depthScale; if(z<cfg.minDepthM||z>cfg.maxDepthM)continue;
      project(i,z,q,0,0); if(!q.valid)continue;
      if(q.u<0.0f||q.v<0.0f||q.u>rgb.width-1.001f||q.v>rgb.height-1.001f)continue;
      if(cfg.rgbOcclusionFilter) {
        int zx=constrain(round(q.u),0,rgb.width-1),zy=constrain(round(q.v),0,rgb.height-1);
        float front=rgbZBuffer[zy*rgb.width+zx];
        if(Float.isFinite(front) && q.z>front+cfg.rgbOcclusionToleranceM)continue;
      }
      registeredColor[i]=sampleBilinearWeighted(rgb,q.u,q.v,lastSyncSkewMs);
    }
    preparedFrameId=frame.frameId; preparedRgbFrameNumber=rgb.frameNumber;
  }

  int colorAt(int index) {
    return preparedFrameId<0 || registeredColor==null || index<0 || index>=registeredColor.length ? 0 : registeredColor[index];
  }

  int sampleBilinearWeighted(RgbSnapshot rgb,float u,float v,float syncMs) {
    int x0=floor(u),y0=floor(v),x1=min(rgb.width-1,x0+1),y1=min(rgb.height-1,y0+1);
    float fx=u-x0,fy=v-y0;
    int c00=rgb.pixels[y0*rgb.width+x0],c10=rgb.pixels[y0*rgb.width+x1];
    int c01=rgb.pixels[y1*rgb.width+x0],c11=rgb.pixels[y1*rgb.width+x1];
    float r0=lerp((c00>>16)&255,(c10>>16)&255,fx),r1=lerp((c01>>16)&255,(c11>>16)&255,fx);
    float g0=lerp((c00>>8)&255,(c10>>8)&255,fx),g1=lerp((c01>>8)&255,(c11>>8)&255,fx);
    float b0=lerp(c00&255,c10&255,fx),b1=lerp(c01&255,c11&255,fx);
    int r=constrain(round(lerp(r0,r1,fy)),0,255),g=constrain(round(lerp(g0,g1,fy)),0,255),b=constrain(round(lerp(b0,b1,fy)),0,255);
    int luma=(77*r+150*g+29*b)>>8;
    float exposure=1.0f;
    if(luma<cfg.rgbExposureLowLuma) exposure=max(0.05f,luma/(float)max(1,cfg.rgbExposureLowLuma));
    else if(luma>cfg.rgbExposureHighLuma) exposure=max(0.05f,(255-luma)/(float)max(1,255-cfg.rgbExposureHighLuma));
    float sync=1.0f-constrain(syncMs/max(1.0f,cfg.rgbMaxSyncSkewMs),0.0f,1.0f);
    float quality=constrain(exposure*(0.35f+0.65f*sync),0.05f,1.0f);
    int alpha=constrain(round(quality*255.0f),1,255);
    return (alpha<<24)|(r<<16)|(g<<8)|b;
  }

  void refineFineOffset(DepthFrame frame,RgbSnapshot rgb) {
    int maxEdges=4096,count=0,step=max(2,cfg.rgbRefineSampleStep),threshold=cfg.rgbRefineEdgeThresholdMm;
    float[] ex=new float[maxEdges],ey=new float[maxEdges];
    RgbProjection q=new RgbProjection();
    for(int v=step;v<frame.height-step && count<maxEdges;v+=step) for(int u=step;u<frame.width-step && count<maxEdges;u+=step) {
      int i=v*frame.width+u,mm=frame.depth[i]&0xFFFF;if(mm==0)continue;
      int mr=frame.depth[v*frame.width+min(frame.width-1,u+step)]&0xFFFF;
      int md=frame.depth[min(frame.height-1,v+step)*frame.width+u]&0xFFFF;
      boolean edge=(mr!=0&&abs(mr-mm)>=threshold)||(md!=0&&abs(md-mm)>=threshold); if(!edge)continue;
      float z=mm*depth.depthScale;if(z<cfg.minDepthM||z>cfg.maxDepthM)continue;
      project(i,z,q,0,0);if(!q.valid||q.u<3||q.v<3||q.u>=rgb.width-3||q.v>=rgb.height-3)continue;
      ex[count]=q.u;ey[count]=q.v;count++;
    }
    lastRefineEdges=count;if(count<cfg.rgbRefineMinimumEdges){lastRefineGain=1.0f;return;}
    int search=cfg.rgbRefineSearchPx,bestDx=0,bestDy=0;double base=0,best=-1;
    for(int dy=-search;dy<=search;dy++)for(int dx=-search;dx<=search;dx++){
      double score=0;for(int i=0;i<count;i++)score+=rgbGradient(rgb,round(ex[i])+dx,round(ey[i])+dy);
      if(dx==0&&dy==0)base=score;if(score>best){best=score;bestDx=dx;bestDy=dy;}
    }
    lastRefineGain=(float)(best/Math.max(1.0,base));
    if((bestDx!=0||bestDy!=0)&&best>base*1.01){
      autoOffsetX=constrain(autoOffsetX+bestDx*cfg.rgbRefineAlpha,-cfg.rgbRefineMaxOffsetPx,cfg.rgbRefineMaxOffsetPx);
      autoOffsetY=constrain(autoOffsetY+bestDy*cfg.rgbRefineAlpha,-cfg.rgbRefineMaxOffsetPx,cfg.rgbRefineMaxOffsetPx);
    }
  }

  int rgbGradient(RgbSnapshot rgb,int x,int y){
    if(x<1||x>=rgb.width-1||y<1||y>=rgb.height-1)return 0;
    int lx=luma(rgb.pixels[y*rgb.width+x-1]),rx=luma(rgb.pixels[y*rgb.width+x+1]);
    int uy=luma(rgb.pixels[(y-1)*rgb.width+x]),dy=luma(rgb.pixels[(y+1)*rgb.width+x]);
    return abs(rx-lx)+abs(dy-uy);
  }
  int luma(int c){int r=(c>>16)&255,g=(c>>8)&255,b=c&255;return(77*r+150*g+29*b)>>8;}
}


// ===== SynKinect Studio / 3D Scanner / ScanCoverage.pde =====
class ScanCoverageTracker {
 final AppConfig cfg;
  PVector gravityReference = null;
  PVector previousHeading = null;
  float directionProbeDeg = 0;
  int direction = 0;
  float sweepDeg = 0;
  float imuDeviationDeg = 0;
  boolean imuStable = true;
  boolean objectDetected = false;
  boolean complete = false;

  ScanCoverageTracker(AppConfig cfg){ this.cfg=cfg; }

  void reset(){
    gravityReference=null; previousHeading=null; directionProbeDeg=0; direction=0;
    sweepDeg=0; imuDeviationDeg=0; imuStable=true; objectDetected=false; complete=false;
  }

  void updateDetection(boolean detected){ objectDetected=detected; }

  void update(RigidTransform pose, MotionSample motion){
    updateImu(motion);
    if(pose==null || complete) return;
    PVector axis = gravityReference==null ? new PVector(0,1,0) : gravityReference.copy();
    if(axis.magSq()<1e-8f) axis.set(0,1,0);
    axis.normalize();

    PVector heading=pose.rotate(new PVector(0,0,1));
    heading.sub(PVector.mult(axis,heading.dot(axis)));
    if(heading.magSq()<1e-8f) return;
    heading.normalize();
    if(previousHeading==null){ previousHeading=heading; return; }

    float dot=constrain(previousHeading.dot(heading),-1.0f,1.0f);
    float signed=degrees(atan2(axis.dot(previousHeading.cross(heading)),dot));
    previousHeading=heading;
    if(abs(signed)<cfg.scanRotationDeadbandDeg || abs(signed)>cfg.scanRotationMaxStepDeg) return;

    if(direction==0){
      directionProbeDeg+=signed;
      if(abs(directionProbeDeg)>=cfg.scanDirectionLockDeg){
        direction=directionProbeDeg>=0?1:-1;
        sweepDeg=abs(directionProbeDeg);
      }
    }else{
      sweepDeg=max(0,sweepDeg+direction*signed);
    }
    if(sweepDeg>=cfg.scanCompleteDeg){ sweepDeg=min(cfg.scanFullTurnDeg,sweepDeg); complete=true; }
  }

  void updateImu(MotionSample motion){
    if(motion==null || !motion.gravityReliable()){ imuStable=true; imuDeviationDeg=0; return; }
    PVector g=motion.gravityUnit();
    if(g==null) return;
    if(gravityReference==null){ gravityReference=g.copy(); imuStable=true; imuDeviationDeg=0; return; }
    float c=constrain(gravityReference.dot(g),-1.0f,1.0f);
    imuDeviationDeg=degrees(acos(c));
    imuStable=imuDeviationDeg<=cfg.scanMaxSensorTiltDriftDeg;
  }

  float progress(){ return complete ? 1.0f : constrain(sweepDeg/max(1.0f,cfg.scanFullTurnDeg),0,1); }
}


// ===== SynKinect Studio / 3D Scanner / ScannerProtocol.pde =====
class ScannerProtocol {
  final String PIPE_NAME = "\\\\.\\pipe\\Kinect360RemoldScanner";
  final String SOCKET_NAME = "/run/kinect360-remold/scanner.sock";
  final int MAGIC = 0x43534D52;
  final int FRAME_MAGIC = 0x46534D52;
  final int VERSION = 1;
  final int CMD_SUBSCRIBE_STREAMS = 1;

  final int WIDTH = 640;
  final int HEIGHT = 480;
  final int MODE_RGB = 0;
  final int MODE_DEPTH = 2;
  final int STREAM_RGB = 1;
  final int STREAM_DEPTH = 4;
  final int STREAM_SESSION = STREAM_RGB | STREAM_DEPTH;

  final int CAP_RGB_DEPTH_CONCURRENT = 1;
  final int CAP_EXCLUSIVE_VIDEO_MODE = 2;
  final int CAP_PROJECTOR_REFCOUNTED = 4;
  final int CAP_ACCELEROMETER = 8;
  final int REQUIRED_CAPABILITIES = CAP_RGB_DEPTH_CONCURRENT | CAP_EXCLUSIVE_VIDEO_MODE | CAP_PROJECTOR_REFCOUNTED;

  final int PIXEL_NV12 = 1;
  final int PIXEL_DEPTH_MM16 = 3;
  final int FLAG_DEVICE_CALIBRATED = 1;
  final int FLAG_FRAME_RECOVERED = 2;
  final int KNOWN_FRAME_FLAGS = FLAG_DEVICE_CALIBRATED | FLAG_FRAME_RECOVERED;

  final int RGB_BYTES = WIDTH * HEIGHT * 3 / 2;
  final int DEPTH_BYTES = WIDTH * HEIGHT * 2;
  final int MAX_PAYLOAD_BYTES = DEPTH_BYTES;
  final int REPLY_BYTES = 32;
  final int FRAME_HEADER_BYTES = 76;

}

// Processing merges PDE tabs into the sketch class. ScannerProtocol is therefore
// an inner type and must contain constants only; executable protocol helpers
// remain sketch methods in this same tab instead of illegal class methods.
int scannerMaskForMode(int mode) {
  return mode == scannerProtocol.MODE_RGB ? scannerProtocol.STREAM_RGB
       : mode == scannerProtocol.MODE_DEPTH ? scannerProtocol.STREAM_DEPTH : 0;
}

int scannerExpectedFormatForMode(int mode) {
  return mode == scannerProtocol.MODE_RGB ? scannerProtocol.PIXEL_NV12
       : mode == scannerProtocol.MODE_DEPTH ? scannerProtocol.PIXEL_DEPTH_MM16 : -1;
}

int scannerExpectedPayloadBytesForMode(int mode) {
  return mode == scannerProtocol.MODE_RGB ? scannerProtocol.RGB_BYTES
       : mode == scannerProtocol.MODE_DEPTH ? scannerProtocol.DEPTH_BYTES : -1;
}


// ===== SynKinect Studio / 3D Scanner / TSDFVolume.pde =====
class TSDFVolume {
  int n;
  float voxelSize, truncation;
  int temporalColorWeightMax;
  short[] tsdf;
  byte[] weight;
  int[] rgb;
  byte[] rgbWeight;
  PVector origin = new PVector();
  PVector center = new PVector();
  int minX,minY,minZ,maxX,maxY,maxZ;

  TSDFVolume(int n,float voxelSize,float truncation,int temporalColorWeightMax){
    this.n=n; this.voxelSize=voxelSize; this.truncation=truncation; this.temporalColorWeightMax=max(1,temporalColorWeightMax);
    tsdf=new short[n*n*n]; weight=new byte[n*n*n]; rgb=new int[n*n*n]; rgbWeight=new byte[n*n*n]; clear();
  }

  void clear(){
    Arrays.fill(tsdf,(short)32767); Arrays.fill(weight,(byte)0); Arrays.fill(rgb,0); Arrays.fill(rgbWeight,(byte)0);
    minX=minY=minZ=n; maxX=maxY=maxZ=-1;
  }

  void resetAround(PVector c){
    clear(); center.set(c);
    float half=n*voxelSize*0.5f;
    origin.set(c.x-half,c.y-half,c.z-half);
  }

  int idx(int x,int y,int z){ return x + y*n + z*n*n; }
  boolean inside(int x,int y,int z){ return x>=0&&y>=0&&z>=0&&x<n&&y<n&&z<n; }

  void integrate(PointCloud cloud,RigidTransform pose,int pointStep){
    PVector cam=pose.translation();
    int stride=max(1,pointStep);
    for(int i=0;i<cloud.size();i+=stride){
      PVector surf=pose.apply(cloud.points.get(i)); int surfaceColor=cloud.colorAt(i);
      PVector ray=PVector.sub(surf,cam); float dist=ray.mag(); if(dist<0.05f) continue; ray.div(dist);
      float from=max(0.05f,dist-truncation), to=dist+truncation;
      for(float t=from;t<=to;t+=voxelSize){
        PVector p=PVector.add(cam,PVector.mult(ray,t));
        int x=floor((p.x-origin.x)/voxelSize), y=floor((p.y-origin.y)/voxelSize), z=floor((p.z-origin.z)/voxelSize);
        if(!inside(x,y,z)) continue;
        float v=constrain((dist-t)/truncation,-1,1);
        int id=idx(x,y,z); int w=weight[id]&255; int nw=min(255,w+1);
        float old=tsdf[id]/32767.0f;
        float blended=(old*w+v)/nw;
        tsdf[id]=(short)constrain(round(blended*32767.0f),-32767,32767); weight[id]=(byte)nw;
        minX=min(minX,x); minY=min(minY,y); minZ=min(minZ,z); maxX=max(maxX,x); maxY=max(maxY,y); maxZ=max(maxZ,z);
      }
      if(((surfaceColor>>>24)&255)!=0) integrateSurfaceColor(surf,surfaceColor);
    }
  }

  void integrateSurfaceColor(PVector p,int colorValue){
    int x=round((p.x-origin.x)/voxelSize),y=round((p.y-origin.y)/voxelSize),z=round((p.z-origin.z)/voxelSize);
    if(!inside(x,y,z))return;
    int id=idx(x,y,z),w=rgbWeight[id]&255;
    // Alpha carries registration/exposure confidence. Repeated synchronized,
    // well-exposed views therefore add more texture evidence over time while
    // dark, saturated or poorly synchronized frames cannot dominate the mesh.
    int confidence=(colorValue>>>24)&255;
    int sampleWeight=constrain(round((confidence/255.0f)*temporalColorWeightMax),1,temporalColorWeightMax);
    int accepted=min(sampleWeight,255-w);if(accepted<=0)return;int nw=w+accepted;
    int old=rgb[id],or=(old>>16)&255,og=(old>>8)&255,ob=old&255,nr=(colorValue>>16)&255,ng=(colorValue>>8)&255,nb=colorValue&255;
    int r=(or*w+nr*accepted)/nw,g=(og*w+ng*accepted)/nw,b=(ob*w+nb*accepted)/nw;rgb[id]=0xFF000000|(r<<16)|(g<<8)|b;rgbWeight[id]=(byte)nw;
  }

  float value(int x,int y,int z){ return tsdf[idx(x,y,z)]/32767.0f; }
  int w(int x,int y,int z){ return weight[idx(x,y,z)]&255; }
  PVector pos(int x,int y,int z){ return new PVector(origin.x+x*voxelSize,origin.y+y*voxelSize,origin.z+z*voxelSize); }

  int sampleColor(PVector p){
    int cx=round((p.x-origin.x)/voxelSize),cy=round((p.y-origin.y)/voxelSize),cz=round((p.z-origin.z)/voxelSize);
    int best=0,bestWeight=0;
    for(int dz=-1;dz<=1;dz++)for(int dy=-1;dy<=1;dy++)for(int dx=-1;dx<=1;dx++){
      int x=cx+dx,y=cy+dy,z=cz+dz;if(!inside(x,y,z))continue;int id=idx(x,y,z),cw=rgbWeight[id]&255;if(cw>bestWeight){bestWeight=cw;best=rgb[id];}
    }
    return best;
  }

  Mesh3D extractMesh(int minWeight){
    Mesh3D out=new Mesh3D();
    if(maxX<0) return out;
    int x0=max(0,minX-1),y0=max(0,minY-1),z0=max(0,minZ-1);
    int x1=min(n-2,maxX+1),y1=min(n-2,maxY+1),z1=min(n-2,maxZ+1);
    int[][] corners={{0,0,0},{1,0,0},{1,1,0},{0,1,0},{0,0,1},{1,0,1},{1,1,1},{0,1,1}};
    int[][] tets={{0,5,1,6},{0,1,2,6},{0,2,3,6},{0,3,7,6},{0,7,4,6},{0,4,5,6}};
    for(int z=z0;z<=z1;z++) for(int y=y0;y<=y1;y++) for(int x=x0;x<=x1;x++){
      PVector[] p=new PVector[8]; float[] v=new float[8]; int[] ww=new int[8]; boolean ok=false;
      for(int c=0;c<8;c++){
        int xx=x+corners[c][0],yy=y+corners[c][1],zz=z+corners[c][2];
        p[c]=pos(xx,yy,zz); v[c]=value(xx,yy,zz); ww[c]=w(xx,yy,zz); if(ww[c]>=minWeight) ok=true;
      }
      if(!ok) continue;
      for(int[] t:tets) polygonizeTet(out,p,v,ww,t,minWeight);
    }
    out.recalculateNormals();
    return out;
  }

  PVector interp(PVector a,PVector b,float va,float vb){
    float d=va-vb; float t=abs(d)<1e-7f?0.5f:va/d; t=constrain(t,0,1); return PVector.lerp(a,b,t);
  }

  void polygonizeTet(Mesh3D out,PVector[] p,float[] v,int[] ww,int[] t,int minWeight){
    for(int i=0;i<4;i++) if(ww[t[i]]<minWeight) return;
    int[] inside=new int[4], outside=new int[4]; int ni=0,no=0;
    for(int i=0;i<4;i++){ if(v[t[i]]<0) inside[ni++]=t[i]; else outside[no++]=t[i]; }
    if(ni==0||ni==4) return;
    if(ni==1||ni==3){
      boolean invert=ni==3; int a=invert?outside[0]:inside[0]; int[] others=new int[3];
      if(invert){others[0]=inside[0];others[1]=inside[1];others[2]=inside[2];}
      else {others[0]=outside[0];others[1]=outside[1];others[2]=outside[2];}
      PVector p0=interp(p[a],p[others[0]],v[a],v[others[0]]);
      PVector p1=interp(p[a],p[others[1]],v[a],v[others[1]]);
      PVector p2=interp(p[a],p[others[2]],v[a],v[others[2]]);
      if(invert) out.addTriangle(p0,p2,p1,sampleColor(p0),sampleColor(p2),sampleColor(p1)); else out.addTriangle(p0,p1,p2,sampleColor(p0),sampleColor(p1),sampleColor(p2));
    } else {
      int a=inside[0],b=inside[1],c=outside[0],d=outside[1];
      PVector ac=interp(p[a],p[c],v[a],v[c]), ad=interp(p[a],p[d],v[a],v[d]);
      PVector bc=interp(p[b],p[c],v[b],v[c]), bd=interp(p[b],p[d],v[b],v[d]);
      out.addTriangle(ac,bc,ad,sampleColor(ac),sampleColor(bc),sampleColor(ad)); out.addTriangle(ad,bc,bd,sampleColor(ad),sampleColor(bc),sampleColor(bd));
    }
  }
}


// ===== SynKinect Studio / 3D Scanner / UI.pde =====
class ScannerUI {
  final int ACTION_START=0, ACTION_PAUSE=1, ACTION_RESET=2, ACTION_MESH=3;
  final int ACTION_STL=4, ACTION_OBJ=5, ACTION_PLY=6, ACTION_CLEAN=7, ACTION_SMOOTH=8, ACTION_CENTER=9, ACTION_UNDO=10;
  final int BUTTON_NORMAL=0, BUTTON_PRIMARY=1, BUTTON_QUIET=2;

 final ArrayList<UiButton> buttons = new ArrayList<UiButton>();
 final ArrayList<UiActionGroup> groups = new ArrayList<UiActionGroup>();
  float previewX, previewY, previewW, previewH;

  ScannerUI() {
    UiActionGroup capture = group("group.capture");
    capture.add(button("button.start", ACTION_START, BUTTON_PRIMARY));
    capture.add(button("button.pause", ACTION_PAUSE, BUTTON_NORMAL));
    capture.add(button("button.reset", ACTION_RESET, BUTTON_QUIET));

    UiActionGroup meshGroup = group("group.mesh");
    meshGroup.add(button("button.mesh", ACTION_MESH, BUTTON_PRIMARY));
    meshGroup.add(button("button.clean", ACTION_CLEAN, BUTTON_NORMAL));
    meshGroup.add(button("button.smooth", ACTION_SMOOTH, BUTTON_NORMAL));
    meshGroup.add(button("button.center", ACTION_CENTER, BUTTON_NORMAL));
    meshGroup.add(button("button.undo", ACTION_UNDO, BUTTON_QUIET));

    UiActionGroup exportGroup = group("group.export");
    exportGroup.add(button("button.stl", ACTION_STL, BUTTON_NORMAL));
    exportGroup.add(button("button.obj", ACTION_OBJ, BUTTON_NORMAL));
    exportGroup.add(button("button.ply", ACTION_PLY, BUTTON_NORMAL));

  }

  UiActionGroup group(String key) { UiActionGroup g=new UiActionGroup(key); groups.add(g); return g; }
  UiButton button(String key,int action,int style) { UiButton b=new UiButton(key,action,style); buttons.add(b); return b; }

  void draw() {
    drawHeader();
    float m=uiTheme.MARGIN, gap=uiTheme.GAP;
    float top=uiTheme.HEADER_H+uiTheme.GAP;
    float toolbarY=studio.contentHeight-uiTheme.TOOLBAR_H-uiTheme.MARGIN;
    float bodyH=max(360, toolbarY-top-uiTheme.GAP);
    float sideW=min(uiTheme.SIDEBAR_W,max(330,width*0.275f));
    float mainX=m+sideW+gap, mainW=width-mainX-m;

    float rgbH=max(210,bodyH*0.43f);
    drawRgbCard(m,top,sideW,rgbH);
    drawDepthCard(m,top+rgbH+gap,sideW,bodyH-rgbH-gap);
    drawReconstructionCard(mainX,top,mainW,bodyH);
    drawToolbar(m,toolbarY,width-2*m,uiTheme.TOOLBAR_H);
  }

  void drawHeader() {
    noStroke(); fill(uiTheme.BG); rect(0,0,width,uiTheme.HEADER_H);
    fill(uiTheme.ACCENT_SOFT); rect(0,uiTheme.HEADER_H-2,width,2);
    textAlign(i18n.startAlign(),CENTER); uiText(uiTheme.FONT_TITLE,true); fill(uiTheme.TEXT);
    float tx=i18n.rtl?width-uiTheme.MARGIN:uiTheme.MARGIN;
    String headerTitle=i18n.tr("app.title");fitCurrentTextSize(headerTitle,uiTheme.FONT_TITLE,10,max(80,width-330),uiTheme.HEADER_H-12);text(ellipsizeToWidth(headerTitle,max(80,width-330)),tx,uiTheme.HEADER_H*0.5f);

    float x=width-uiTheme.MARGIN-18;
    boolean depth=kinectSource!=null&&kinectSource.depthConnected;
    boolean rgb=kinectSource!=null&&kinectSource.colorConnected;
    boolean port=kinectSource!=null&&kinectSource.portReady;
    drawStateDot(x,33,"D",depth); x-=42;
    drawStateDot(x,33,"R",rgb); x-=42;
    drawStateDot(x,33,"P",port);
    textAlign(LEFT,BASELINE);
  }

  void drawStateDot(float x,float y,String label,boolean active) {
    noStroke(); fill(active?uiTheme.ACCENT:uiTheme.BORDER); ellipse(x,y,8,8);
    fill(uiTheme.TEXT_MUTED); textAlign(CENTER,CENTER); uiText(uiTheme.FONT_TINY,true); text(label,x+14,y); textAlign(LEFT,BASELINE);
  }

  void drawRgbCard(float x,float y,float w,float h) {
    card(x,y,w,h); cardTitle(x,y,w,i18n.tr("panel.rgb"));
    float px=x+10, py=y+uiTheme.CARD_TITLE_H, pw=w-20, ph=max(80,h-uiTheme.CARD_TITLE_H-42);
    previewSurface(px,py,pw,ph);
    if(colorPreview!=null) imageFit(colorPreview,px,py,pw,ph); else drawWaiting(px,py,pw,ph,i18n.tr("waiting.rgb"));
    boolean rgb=kinectSource!=null&&kinectSource.colorConnected;
    drawCompactFooter(x,y,w,h,i18n.tr("chip.rgb"),rgb,rgbFooterValue());
  }

  String rgbFooterValue(){
    String frames=kinectSource==null?"0":String.valueOf(kinectSource.colorFrames);
    if(kinectSource!=null)frames+="  ·  pairs "+kinectSource.queuedRgbdPairs()+"/"+config.rgbdQueueFrames;
    if(Float.isNaN(latestRgbDepthSkewMs))return frames;
    String value=frames+"  ·  "+i18n.tr("chip.sync")+" "+nf(latestRgbDepthSkewMs,1,1)+" ms";
    if(rgbRegistration!=null&&(abs(rgbRegistration.autoOffsetX)>0.05f||abs(rgbRegistration.autoOffsetY)>0.05f))
      value+="  ·  Δxy "+nf(rgbRegistration.autoOffsetX,1,1)+","+nf(rgbRegistration.autoOffsetY,1,1);
    return value;
  }

  void drawDepthCard(float x,float y,float w,float h) {
    card(x,y,w,h); cardTitle(x,y,w,i18n.tr("panel.depth"));
    float footerH=64;
    float px=x+10,py=y+uiTheme.CARD_TITLE_H,pw=w-20,ph=max(90,h-uiTheme.CARD_TITLE_H-footerH-8);
    previewSurface(px,py,pw,ph);
    if(depthPreview!=null) imageFit(depthPreview,px,py,pw,ph); else drawWaiting(px,py,pw,ph,i18n.tr("waiting.depth"));

    boolean depthOk=kinectSource!=null&&kinectSource.depthConnected;
    boolean metric=latestDepth!=null&&latestDepth.deviceCalibrated;
    float fy=py+ph+9;
    miniState(x+10,fy,76,i18n.tr("chip.depth"),depthOk);
    miniState(x+92,fy,92,i18n.tr("chip.metric"),metric);
    if(latestDepth!=null&&latestDepth.transportRecovered) miniState(x+190,fy,102,i18n.tr("state.recovered"),false);

    String value="—";
    if(latestDepthDiagnostics!=null&&latestDepthDiagnostics.plausiblePixels>0){
      value=nf(latestDepthDiagnostics.medianMm/1000.0f,1,2)+" m  ·  "+nf(latestDepthDiagnostics.plausibleRatio*100.0f,1,1)+"%";
      if(kinectSource!=null)value+="  ·  q "+kinectSource.queuedRgbdPairs()+"/"+config.rgbdQueueFrames+" → "+reconstructionQueuedFrames()+"/"+config.reconstructionQueueFrames;
    }
    fill(uiTheme.TEXT_MUTED); uiText(uiTheme.FONT_SMALL,false); textAlign(i18n.startAlign(),CENTER);
    fitCurrentTextSize(value,uiTheme.FONT_SMALL,7,w-20,24);text(ellipsizeToWidth(value,w-20),i18n.rtl?x+w-10:x+10,y+h-16); textAlign(LEFT,BASELINE);
  }

  void drawCompactFooter(float x,float y,float w,float h,String label,boolean active,String value) {
    float cy=y+h-20;
    noStroke(); fill(active?uiTheme.ACCENT:uiTheme.BORDER); ellipse(x+16,cy,7,7);
    fill(uiTheme.TEXT_MUTED); uiText(uiTheme.FONT_SMALL,false); textAlign(LEFT,CENTER);String footer=label+"  "+value;fitCurrentTextSize(footer,uiTheme.FONT_SMALL,7,w-41,24);text(ellipsizeToWidth(footer,w-41),x+27,cy); textAlign(LEFT,BASELINE);
  }

  void miniState(float x,float y,float w,String label,boolean active) {
    noStroke(); fill(uiTheme.SURFACE_ALT); rect(x,y,w,24,7);
    fill(active?uiTheme.ACCENT:uiTheme.TEXT_MUTED); ellipse(x+11,y+12,6,6);
    fill(uiTheme.TEXT_MUTED); uiText(uiTheme.FONT_TINY,false); textAlign(LEFT,CENTER);fitCurrentTextSize(label,uiTheme.FONT_TINY,7,w-26,20);text(ellipsizeToWidth(label,w-26),x+20,y+12); textAlign(LEFT,BASELINE);
  }

  void drawReconstructionCard(float x,float y,float w,float h) {
    card(x,y,w,h); cardTitle(x,y,w,i18n.tr("panel.reconstruction"));
    float statsH=128;
    previewX=x+10; previewY=y+uiTheme.CARD_TITLE_H; previewW=w-20; previewH=max(220,h-uiTheme.CARD_TITLE_H-statsH-10);
    previewSurface(previewX,previewY,previewW,previewH);
    draw3DPreview(previewX,previewY,previewW,previewH);
    drawPreviewOverlay(previewX,previewY,previewW,previewH);
    drawStatusArea(x+10,previewY+previewH+8,w-20,statsH);
  }

  void drawPreviewOverlay(float x,float y,float w,float h) {
    boolean complete=false; synchronized(reconstructionStateLock){ complete=scanCoverage!=null&&scanCoverage.complete; }
    String scanState=complete?i18n.tr("scan.complete"):(scanActive?(scanPaused?i18n.tr("scan.paused"):i18n.tr("scan.active")):i18n.tr("scan.idle"));
    drawChip(x+w-132,y+10,122,28,scanState,scanActive&&!scanPaused,uiTheme.ACCENT);
    fill(uiTheme.TEXT_MUTED); uiText(uiTheme.FONT_TINY,false); textAlign(LEFT,CENTER);String orbitHint=i18n.tr("hint.orbit.short");fitCurrentTextSize(orbitHint,uiTheme.FONT_TINY,7,max(40,w-160),24);text(ellipsizeToWidth(orbitHint,max(40,w-160)),x+12,y+24); textAlign(LEFT,BASELINE);
  }

  void drawStatusArea(float x,float y,float w,float h) {
    noStroke(); fill(uiTheme.SURFACE_ALT); rect(x,y,w,h,10);
    float progress; String targetMetric,icpMetric; long integratedMetric;
    synchronized(reconstructionStateLock){
      progress=scanCoverage==null?0:constrain(scanCoverage.progress(),0,1);
      targetMetric=targetValue(); icpMetric=icpValue(); integratedMetric=integratedFrames;
    }
    float barX=x+12,barY=y+12,barW=w-24;
    fill(uiTheme.BORDER); rect(barX,barY,barW,6,3);
    fill(uiTheme.ACCENT); rect(barX,barY,barW*progress,6,3);

    float ty=y+34, gap=10, tw=(w-24-gap*3)/4.0f;
    metricTile(x+12,ty,tw,60,i18n.tr("label.target"),targetMetric);
    metricTile(x+12+(tw+gap),ty,tw,60,i18n.tr("label.icp"),icpMetric);
    metricTile(x+12+2*(tw+gap),ty,tw,60,i18n.tr("label.integrated"),String.valueOf(integratedMetric));
    metricTile(x+12+3*(tw+gap),ty,tw,60,i18n.tr("label.progress"),nf(progress*100,1,0)+"%");

    String sourceStatus=kinectSource==null?"":kinectSource.displayError();
    String message=sourceStatus.length()>0?sourceStatus:appStatus;
    if(message==null||message.length()==0) message=i18n.tr("status.ready");
    fill(sourceStatus.length()>0?uiTheme.WARN:uiTheme.TEXT_MUTED); ellipse(x+15,y+h-15,6,6);
    fill(uiTheme.TEXT_MUTED); uiText(uiTheme.FONT_TINY,false); textAlign(LEFT,CENTER);fitCurrentTextSize(message,uiTheme.FONT_TINY,7,w-42,24);text(ellipsizeToWidth(message,w-42),x+25,y+h-15); textAlign(LEFT,BASELINE);
  }

  String targetValue() {
    if(depthTarget==null||Float.isNaN(depthTarget.depthM)) return "—";
    return nf(depthTarget.depthM,1,2)+" m";
  }

  String icpValue() {
    if(tracker==null||!tracker.trackingGood) return "—";
    return nf(tracker.rms*1000,1,1)+" mm";
  }

  void metricTile(float x,float y,float w,float h,String label,String value) {
    noStroke(); fill(uiTheme.SURFACE_RAISED); rect(x,y,w,h,8);
    fill(uiTheme.TEXT_MUTED); uiText(uiTheme.FONT_TINY,true); textAlign(CENTER,CENTER);fitCurrentTextSize(label,uiTheme.FONT_TINY,7,w-12,22);text(ellipsizeToWidth(label,w-12),x+w/2,y+15);
    fill(uiTheme.TEXT); uiText(uiTheme.FONT_METRIC,true);fitCurrentTextSize(value,uiTheme.FONT_METRIC,8,w-12,26);text(ellipsizeToWidth(value,w-12),x+w/2,y+36); textAlign(LEFT,BASELINE);
  }

  void drawToolbar(float x,float y,float w,float h) {
    float[] weights={0.23f,0.36f,0.29f,0.12f};
    float gap=uiTheme.GAP, cx=x;
    for(int i=0;i<groups.size();i++) {
      float gw=(i==groups.size()-1)?x+w-cx:w*weights[i]-gap*(groups.size()-1)/groups.size();
      drawActionPanel(groups.get(i),cx,y,gw,h);
      cx+=gw+gap;
    }
  }

  void drawActionPanel(UiActionGroup group,float x,float y,float w,float h) {
    card(x,y,w,h);
    fill(uiTheme.TEXT_MUTED); uiText(uiTheme.FONT_TINY,true); textAlign(LEFT,CENTER);String groupTitle=i18n.tr(group.labelKey);fitCurrentTextSize(groupTitle,uiTheme.FONT_TINY,7,w-20,24);text(ellipsizeToWidth(groupTitle,w-20),x+10,y+17); textAlign(LEFT,BASELINE);
    float bx=x+9, by=y+31, gap=6, bh=h-40;
    int count=max(1,group.items.size()); float bw=(w-18-gap*(count-1))/count;
    for(int i=0;i<group.items.size();i++) {
      UiButton item=group.items.get(i);
      item.setBounds(bx+i*(bw+gap),by,bw,bh);
      item.draw();
    }
  }

  void card(float x,float y,float w,float h) { stroke(uiTheme.BORDER); strokeWeight(1); fill(uiTheme.SURFACE); rect(x,y,w,h,uiTheme.RADIUS); noStroke(); }
  void cardTitle(float x,float y,float w,String title) {
    fill(uiTheme.TEXT); uiText(uiTheme.FONT_SMALL,true); textAlign(i18n.startAlign(),CENTER);
    fitCurrentTextSize(title,uiTheme.FONT_SMALL,8,w-24,uiTheme.CARD_TITLE_H-8);text(title,i18n.rtl?x+w-12:x+12,y+uiTheme.CARD_TITLE_H*0.5f); textAlign(LEFT,BASELINE);
  }
  void previewSurface(float x,float y,float w,float h) { noStroke(); fill(uiTheme.PREVIEW); rect(x,y,w,h,9); }
  void drawWaiting(float x,float y,float w,float h,String message) { fill(uiTheme.TEXT_MUTED); textAlign(CENTER,CENTER); uiText(uiTheme.FONT_BODY,false);fitCurrentTextSize(message,uiTheme.FONT_BODY,8,w-18,h-12);text(ellipsizeToWidth(message,w-18),x+w/2,y+h/2); textAlign(LEFT,BASELINE); }
  void imageFit(PImage img,float x,float y,float w,float h) {
    if(img==null||img.width<=0||img.height<=0)return;
    float s=min(w/img.width,h/img.height),dw=img.width*s,dh=img.height*s; image(img,x+(w-dw)/2,y+(h-dh)/2,dw,dh);
  }

  void draw3DPreview(float x,float y,float w,float h) {
    Mesh3D renderMesh=mesh;
    PointCloud ref=null;
    if(renderMesh==null||renderMesh.triangleCount()==0){
      synchronized(reconstructionStateLock){if(volumeInitialized&&tracker!=null)ref=tracker.reference;}
    }
    if(scannerViewport3D==null)scannerViewport3D=new Scanner3DViewport();
    scannerViewport3D.draw(x,y,w,h,renderMesh,ref);
  }

  void drawChip(float x,float y,float w,float h,String label,boolean active,int tint) {
    noStroke(); fill(active?uiTheme.SURFACE_RAISED:uiTheme.SURFACE_ALT); rect(x,y,w,h,h/2);
    fill(active?tint:uiTheme.TEXT_MUTED); textAlign(CENTER,CENTER); uiText(uiTheme.FONT_TINY,true);fitCurrentTextSize(label,uiTheme.FONT_TINY,7,w-10,h-6);text(ellipsizeToWidth(label,w-10),x+w/2,y+h/2); textAlign(LEFT,BASELINE);
  }

  String ellipsize(String s,int limit) { if(s==null)return ""; return s.length()<=limit?s:s.substring(0,max(0,limit-1))+"…"; }
  boolean isOver3D(float mx,float my){ return mx>=previewX&&mx<=previewX+previewW&&my>=previewY&&my<=previewY+previewH; }
  boolean handleMousePressed(float mx,float my){ for(UiButton b:buttons) if(b.hit(mx,my)&&b.enabled()){ b.fire(); return true; } return false; }
}

class Scanner3DViewport {
  PGraphics buffer=null;
  int bufferWidth=0,bufferHeight=0;
  Mesh3D cachedMesh=null;
  final ArrayList<PShape> meshChunks=new ArrayList<PShape>();
  int meshCursor=0;
  final int meshChunkTriangles=10000;

  void dispose(){buffer=null;bufferWidth=0;bufferHeight=0;cachedMesh=null;meshChunks.clear();meshCursor=0;}

  void ensureBuffer(int w,int h){
    w=max(64,w);h=max(64,h);
    if(buffer!=null&&bufferWidth==w&&bufferHeight==h)return;
    buffer=createGraphics(w,h,P3D);
    bufferWidth=w;bufferHeight=h;
    cachedMesh=null;meshChunks.clear();meshCursor=0;
  }

  void resetMeshCache(Mesh3D mesh){
    if(cachedMesh==mesh)return;
    cachedMesh=mesh;meshChunks.clear();meshCursor=0;
  }

  void buildNextMeshChunk(Mesh3D mesh){
    if(buffer==null||mesh==null||meshCursor>=mesh.triangles.size())return;
    int end=min(mesh.triangles.size(),meshCursor+meshChunkTriangles);
    PShape chunk=buffer.createShape();
    chunk.beginShape(TRIANGLES);chunk.noStroke();
    for(int i=meshCursor;i<end;i++){
      Triangle3D tri=mesh.triangles.get(i);
      chunk.normal(tri.n.x,tri.n.y,tri.n.z);
      chunk.fill(mesh.renderColor(tri.ca,uiTheme.MESH));chunk.vertex(tri.a.x,tri.a.y,tri.a.z);
      chunk.fill(mesh.renderColor(tri.cb,uiTheme.MESH));chunk.vertex(tri.b.x,tri.b.y,tri.b.z);
      chunk.fill(mesh.renderColor(tri.cc,uiTheme.MESH));chunk.vertex(tri.c.x,tri.c.y,tri.c.z);
    }
    chunk.endShape();meshChunks.add(chunk);meshCursor=end;
  }

  void draw(float x,float y,float w,float h,Mesh3D renderMesh,PointCloud ref){
    int bw=max(64,round(w));int bh=max(64,round(h));
    ensureBuffer(bw,bh);resetMeshCache(renderMesh);

    PVector focusCenter=new PVector(0,0,0.75f);
    float sceneRadius=0.20f;
    if(renderMesh!=null&&renderMesh.triangleCount()>0){
      focusCenter=renderMesh.boundsCenter();sceneRadius=max(0.05f,renderMesh.boundsRadius());
    }else if(ref!=null&&ref.points!=null&&!ref.points.isEmpty()){
      float minX=Float.POSITIVE_INFINITY,minY=Float.POSITIVE_INFINITY,minZ=Float.POSITIVE_INFINITY;
      float maxX=Float.NEGATIVE_INFINITY,maxY=Float.NEGATIVE_INFINITY,maxZ=Float.NEGATIVE_INFINITY;
      for(PVector point:ref.points){
        if(point==null)continue;
        minX=min(minX,point.x);minY=min(minY,point.y);minZ=min(minZ,point.z);
        maxX=max(maxX,point.x);maxY=max(maxY,point.y);maxZ=max(maxZ,point.z);
      }
      if(minX<Float.POSITIVE_INFINITY){
        focusCenter.set((minX+maxX)*0.5f,(minY+maxY)*0.5f,(minZ+maxZ)*0.5f);
        sceneRadius=max(0.05f,dist(minX,minY,minZ,maxX,maxY,maxZ)*0.5f);
      }
    }

    float viewScale=max(1.0f,min(bw,bh)*0.42f/max(sceneRadius,0.02f))*previewZoom;
    float worldStroke=1.0f/max(1.0f,viewScale);
    float axisLen=max(sceneRadius*1.05f,0.08f);

    buffer.beginDraw();
    buffer.background(uiTheme.PREVIEW);
    buffer.hint(ENABLE_DEPTH_TEST);
    buffer.ortho(-bw*0.5f,bw*0.5f,-bh*0.5f,bh*0.5f,-10000,10000);
    buffer.translate(bw*0.5f,bh*0.5f,0);
    buffer.ambientLight(92,92,100);
    buffer.directionalLight(224,224,224,-0.4f,0.6f,-1.0f);
    buffer.directionalLight(112,126,150,0.5f,-0.3f,-0.2f);
    buffer.scale(viewScale);
    buffer.rotateX(previewPitch);
    buffer.rotateY(previewYaw);
    buffer.translate(-focusCenter.x,-focusCenter.y,-focusCenter.z);

    drawGrid(focusCenter,sceneRadius,worldStroke);
    drawAxes(focusCenter,axisLen,worldStroke);

    buffer.stroke(uiTheme.GRID);buffer.strokeWeight(worldStroke);buffer.noFill();
    buffer.pushMatrix();buffer.translate(focusCenter.x,focusCenter.y,focusCenter.z);
    buffer.box(sceneRadius*2.1f,sceneRadius*2.1f,sceneRadius*2.1f);buffer.popMatrix();

    if(renderMesh!=null&&renderMesh.triangleCount()>0){
      if(meshCursor<renderMesh.triangles.size())buildNextMeshChunk(renderMesh);
      for(PShape chunk:meshChunks)buffer.shape(chunk);
    }else if(ref!=null&&ref.points!=null){
      buffer.stroke(uiTheme.ACCENT);buffer.strokeWeight(worldStroke*2.0f);buffer.beginShape(POINTS);
      for(PVector point:ref.points)if(point!=null)buffer.vertex(point.x,point.y,point.z);
      buffer.endShape();
    }
    buffer.noLights();buffer.hint(DISABLE_DEPTH_TEST);buffer.endDraw();

    // The 3D environment is an off-screen PGraphics instance. Rendering it as
    // one image guarantees that geometry cannot escape the reconstruction card
    // and cannot change the main Studio camera/projection used by other tabs.
    image(buffer,x,y,w,h);
  }

  void drawGrid(PVector center,float radius,float strokeWorld){
    float size=max(radius*1.6f,0.18f);int lines=10;float step=(size*2.0f)/lines;
    buffer.stroke(uiTheme.BORDER);buffer.strokeWeight(strokeWorld);
    for(int i=0;i<=lines;i++){
      float d=-size+i*step;
      buffer.line(center.x-size,center.y,center.z+d,center.x+size,center.y,center.z+d);
      buffer.line(center.x+d,center.y,center.z-size,center.x+d,center.y,center.z+size);
    }
  }

  void drawAxes(PVector center,float axisLen,float strokeWorld){
    buffer.strokeWeight(strokeWorld*1.7f);
    buffer.stroke(220,92,92);buffer.line(center.x,center.y,center.z,center.x+axisLen,center.y,center.z);
    buffer.stroke(92,220,140);buffer.line(center.x,center.y,center.z,center.x,center.y-axisLen,center.z);
    buffer.stroke(92,150,232);buffer.line(center.x,center.y,center.z,center.x,center.y,center.z+axisLen);
  }
}

class UiActionGroup {
 final String labelKey; final ArrayList<UiButton> items=new ArrayList<UiButton>();
  UiActionGroup(String key){labelKey=key;}
  void add(UiButton button){items.add(button);}
}

class UiButton {
  float x,y,w,h; final String labelKey; final int action,style;
  UiButton(String labelKey,int action,int style){this.labelKey=labelKey;this.action=action;this.style=style;}
  void setBounds(float x,float y,float w,float h){this.x=x;this.y=y;this.w=w;this.h=h;}
  String label(){ if(action==ui.ACTION_PAUSE&&scanActive&&scanPaused)return i18n.tr("button.resume"); return i18n.tr(labelKey); }
  boolean enabled(){
    if(meshBusy&&(action==ui.ACTION_START||action==ui.ACTION_RESET||action==ui.ACTION_MESH||action==ui.ACTION_CLEAN||action==ui.ACTION_SMOOTH||action==ui.ACTION_CENTER||action==ui.ACTION_UNDO||action==ui.ACTION_STL||action==ui.ACTION_OBJ||action==ui.ACTION_PLY))return false;
    if(action==ui.ACTION_PAUSE)return scanActive;
    if(action==ui.ACTION_MESH)return volumeInitialized;
    if(action==ui.ACTION_CLEAN||action==ui.ACTION_SMOOTH||action==ui.ACTION_CENTER)return mesh!=null&&mesh.triangleCount()>0;
    if(action==ui.ACTION_UNDO)return meshUndo!=null;
    if(action==ui.ACTION_STL||action==ui.ACTION_OBJ||action==ui.ACTION_PLY)return volumeInitialized||(mesh!=null&&mesh.triangleCount()>0);
    return true;
  }
  void draw(){
    boolean en=enabled(),hot=en&&hit(studio.contentMouseX(),studio.contentMouseY());
    int base=style==ui.BUTTON_PRIMARY?uiTheme.SURFACE_RAISED:uiTheme.SURFACE_ALT;
    if(style==ui.BUTTON_QUIET)base=uiTheme.SURFACE;
    stroke(hot?uiTheme.ACCENT:uiTheme.BORDER); strokeWeight(1); fill(en?(hot?uiTheme.SURFACE_RAISED:base):uiTheme.BG); rect(x,y,w,h,8); noStroke();
    fill(en?(style==ui.BUTTON_PRIMARY?uiTheme.TEXT:uiTheme.TEXT_MUTED):uiTheme.BORDER); textAlign(CENTER,CENTER); uiText(uiTheme.FONT_SMALL,true);String value=label();fitCurrentTextSize(value,uiTheme.FONT_SMALL,8,w-12,h-8);text(value,x+w/2,y+h/2); textAlign(LEFT,BASELINE);
  }
  boolean hit(float mx,float my){return mx>=x&&mx<=x+w&&my>=y&&my<=y+h;}
  void fire(){dispatchUiAction(action);}
}


// ===== SynKinect Studio / Acoustic Scanner / Module.pde =====
AcousticConfig acousticConfig;
AcousticI18n acousticI18n;
AcousticSource acousticSource;
AcousticEngine acousticEngine;
AcousticUI acousticUi;
AcousticScanFrame acousticScan;
long lastProcessedFrame=-1;

void setupAcousticModule(){
  acousticConfig=new AcousticConfig();
  acousticConfig.load(new File(dataPath("acoustic.properties")));
  acousticI18n=new AcousticI18n(studio.currentLanguage());
  initializeAcousticTypography();
  acousticEngine=new AcousticEngine(acousticConfig);
  acousticSource=new AcousticSource(acousticConfig);
  acousticUi=new AcousticUI();
}

void drawAcousticModule(){
  background(acousticTheme.BG);
  AcousticAudioFrame frame=acousticSource==null?null:acousticSource.snapshot();
  if(frame!=null&&frame.frameNumber!=lastProcessedFrame){
    lastProcessedFrame=frame.frameNumber;
    acousticScan=acousticEngine.process(frame);
  }
  acousticUi.draw(frame,acousticScan);
}

void acousticMousePressed(){if(acousticUi!=null)acousticUi.handleMouse(studio.contentMouseX(),studio.contentMouseY());}
void acousticKeyPressed(){
  if(key=='r'||key=='R')resetAcousticMap();
}
void resetAcousticMap(){if(acousticEngine!=null)acousticEngine.reset();acousticScan=null;}
void disposeAcousticModule(){if(acousticSource!=null)acousticSource.stop();}


// ===== SynKinect Studio / Acoustic Scanner / AcousticConfig.pde =====
class AcousticConfig {
  String language="en-US";
  int uiFrameRate=30,workerJoinMs=1200,reconnectMs=300,pipeOpenAttempts=4,pipeOpenRetryMs=75,noFrameWarningMs=2000,connectionStaleMs=3500;
  String uiFontFamily="Segoe UI",uiHeadingFontFamily="Segoe UI Semibold",uiFontFallback="Arial";
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


// ===== SynKinect Studio / Acoustic Scanner / AcousticDsp.pde =====
class AcousticScanFrame {
  long frameNumber;
  float rms,azimuthDeg,confidence,peakScore;
  float[] directional=new float[181];
  float[] occupancy=new float[181];
}

class AcousticEngine {
  final int FFT=512,BINS=181;
 final AcousticConfig cfg;
 final int[][] pairs={{0,1},{0,2},{0,3},{1,2},{1,3},{2,3}};
 final float[][] spectrumRe=new float[4][FFT],spectrumIm=new float[4][FFT];
 final float[][] pairCorr=new float[6][FFT];
 final float[] occupancy=new float[BINS];

  AcousticEngine(AcousticConfig cfg){this.cfg=cfg;}
  void reset(){Arrays.fill(occupancy,0);}

  AcousticScanFrame process(AcousticAudioFrame frame){
    AcousticScanFrame out=new AcousticScanFrame();out.frameNumber=frame.frameNumber;float rmsAccum=0;
    for(int ch=0;ch<4;ch++)rmsAccum+=prepare(frame.samples[ch],spectrumRe[ch],spectrumIm[ch]);
    out.rms=sqrt(rmsAccum/(4.0f*acousticProtocol.SAMPLES));
    buildCorrelations();
    float minScore=Float.MAX_VALUE,maxScore=-Float.MAX_VALUE;int peak=0;
    for(int bin=0;bin<BINS;bin++){
      float deg=-90+bin,s=(float)Math.sin(Math.toRadians(deg)),score=0;
      for(int p=0;p<pairs.length;p++){
        int a=pairs[p][0],b=pairs[p][1];float dx=cfg.microphoneXM[b]-cfg.microphoneXM[a];float lag=dx*s*acousticProtocol.SAMPLE_RATE/cfg.soundSpeedMps;
        score+=corrAt(pairCorr[p],lag);
      }
      out.directional[bin]=score;if(score<minScore)minScore=score;if(score>maxScore){maxScore=score;peak=bin;}
    }
    float span=maxScore-minScore,second=0;
    for(int bin=0;bin<BINS;bin++){
      float normalized=span>1e-9f?(out.directional[bin]-minScore)/span:0;out.directional[bin]=normalized;
      if(bin+3<peak||bin>peak+3)second=max(second,normalized);
      float injection=out.rms>=cfg.minimumRms?normalized*constrain(out.rms*8.0f,0,1):0;
      occupancy[bin]=cfg.occupancyDecay*occupancy[bin]+(1-cfg.occupancyDecay)*injection;out.occupancy[bin]=occupancy[bin];
    }
    float refined=-90+peak;if(peak>0&&peak+1<BINS){float y0=out.directional[peak-1],y1=out.directional[peak],y2=out.directional[peak+1],d=y0-2*y1+y2;if(abs(d)>1e-6f)refined+=constrain(0.5f*(y0-y2)/d,-0.5f,0.5f);}
    out.azimuthDeg=refined;out.peakScore=out.directional[peak];out.confidence=constrain(out.peakScore-second,0,1);return out;
  }

  float prepare(int[] samples,float[] re,float[] im){
    Arrays.fill(re,0);Arrays.fill(im,0);double mean=0;for(int v:samples)mean+=v;mean/=samples.length;float e=0;
    for(int i=0;i<samples.length;i++){float x=(float)(((double)samples[i]-mean)/2147483648.0);float w=0.5f-0.5f*(float)Math.cos(2*Math.PI*i/(samples.length-1));float v=x*w;re[i]=v;e+=v*v;}
    fft(re,im,false);return e;
  }
  void buildCorrelations(){
    for(int p=0;p<pairs.length;p++){int a=pairs[p][0],b=pairs[p][1];float[] re=new float[FFT],im=new float[FFT];
      for(int k=0;k<FFT;k++){float ar=spectrumRe[a][k],ai=spectrumIm[a][k],br=spectrumRe[b][k],bi=spectrumIm[b][k];float cr=ar*br+ai*bi,ci=ai*br-ar*bi,mag=sqrt(cr*cr+ci*ci)+1e-12f;re[k]=cr/mag;im[k]=ci/mag;}
      fft(re,im,true);arrayCopy(re,pairCorr[p]);
    }
  }
  float corrAt(float[] corr,float lag){float w=lag;while(w<0)w+=FFT;while(w>=FFT)w-=FFT;int i0=(int)Math.floor(w),i1=(i0+1)%FFT;float f=w-i0;return corr[i0]*(1-f)+corr[i1]*f;}
  void fft(float[] re,float[] im,boolean inverse){
    int n=re.length,j=0;for(int i=1;i<n;i++){int bit=n>>1;for(;((j&bit)!=0);bit>>=1)j^=bit;j^=bit;if(i<j){float t=re[i];re[i]=re[j];re[j]=t;t=im[i];im[i]=im[j];im[j]=t;}}
    for(int len=2;len<=n;len<<=1){double ang=(inverse?2:-2)*Math.PI/len;float wr0=(float)Math.cos(ang),wi0=(float)Math.sin(ang);for(int i=0;i<n;i+=len){float wr=1,wi=0;for(int k=0;k<len/2;k++){int q=i+k+len/2;float vr=re[q]*wr-im[q]*wi,vi=re[q]*wi+im[q]*wr,ur=re[i+k],ui=im[i+k];re[i+k]=ur+vr;im[i+k]=ui+vi;re[q]=ur-vr;im[q]=ui-vi;float nr=wr*wr0-wi*wi0;wi=wr*wi0+wi*wr0;wr=nr;}}}
    if(inverse)for(int i=0;i<n;i++){re[i]/=n;im[i]/=n;}
  }
}


// ===== SynKinect Studio / Acoustic Scanner / AcousticLocalization.pde =====
class AcousticI18n extends ModuleI18n {
  AcousticI18n(String requested){super("acoustic",requested);}
}


class AcousticTheme {
  final int WINDOW_W=1380,WINDOW_H=900;
  final int BG=0xFF11151A,SURFACE=0xFF181E25,SURFACE2=0xFF202832,RAISED=0xFF293440;
  final int BORDER=0xFF35414D,TEXT=0xFFF4F7FA,MUTED=0xFFAAB6C2,GRID=0xFF35404A,ACTIVE=0xFF68A9E8,GOOD=0xFF7CC7A0,WARN=0xFFE4B86B;
  final int MARGIN=20,GAP=14,HEADER_H=68,RADIUS=14,CARD_TITLE_H=44;
  final int FONT_TINY=12,FONT_SMALL=14,FONT_BODY=15,FONT_LABEL=16,FONT_METRIC=19,FONT_TITLE=27;
}

PFont acousticFontRegular,acousticFontHeading;
void initializeAcousticTypography(){
  String regular=resolveAcousticFont(acousticConfig.uiFontFamily,acousticConfig.uiFontFallback);
  String heading=resolveAcousticFont(acousticConfig.uiHeadingFontFamily,regular);
  acousticFontRegular=createFont(regular,acousticTheme.FONT_BODY,true);
  acousticFontHeading=createFont(heading,acousticTheme.FONT_TITLE,true);
  textFont(acousticFontRegular);textLeading(acousticTheme.FONT_BODY*1.28f);
}
String resolveAcousticFont(String preferred,String fallback){String[] installed=PFont.list();String hit=findAcousticFont(installed,preferred);if(hit!=null)return hit;hit=findAcousticFont(installed,fallback);return hit==null?"SansSerif":hit;}
String findAcousticFont(String[] installed,String wanted){if(wanted==null||wanted.trim().length()==0||installed==null)return null;for(String candidate:installed)if(candidate.equalsIgnoreCase(wanted.trim()))return candidate;return null;}
void acousticText(float size,boolean heading){PFont f=heading?acousticFontHeading:acousticFontRegular;if(f!=null)textFont(f);textSize(responsiveFontSize(size));}


// ===== SynKinect Studio / Acoustic Scanner / AcousticProtocol.pde =====
class AcousticProtocol {
  final String PIPE="\\\\.\\pipe\\Kinect360RemoldAcoustic";
  final String SOCKET="/run/kinect360-remold/acoustic.sock";
  final int MAGIC=0x414D4D52;
  final int FRAME_MAGIC=0x464D4D52;
  final int VERSION=1;
  final int CMD_SUBSCRIBE=1;
  final int SAMPLE_RATE=16000;
  final int CHANNELS=4;
  final int SAMPLES=256;
  final int SAMPLE_FORMAT_S32LE=1;
  final int BYTES_PER_SAMPLE=4;
  final int PAYLOAD_BYTES=CHANNELS*SAMPLES*BYTES_PER_SAMPLE;
  final int REQUEST_BYTES=16;
  final int REPLY_BYTES=32;
  final int HEADER_BYTES=48;
  final int REQUIRED_CAPABILITIES=0x3;
  final int VALID_CHANNEL_MASK=(1<<CHANNELS)-1;
}

class AcousticAudioFrame {
  long frameNumber,tickMs;
  int channelMask;
  int[][] samples=new int[acousticProtocol.CHANNELS][acousticProtocol.SAMPLES];
  float[] peak=new float[acousticProtocol.CHANNELS];
  boolean valid(int channel){return channel>=0&&channel<acousticProtocol.CHANNELS&&(channelMask&(1<<channel))!=0;}
}


// ===== SynKinect Studio / Acoustic Scanner / AcousticSource.pde =====
class AcousticSource {
 final AcousticConfig cfg;
 final Object frameLock=new Object(),pipeLock=new Object();
  volatile boolean running=false,connected=false;
  volatile String stateKey="source.starting",detail="";
  volatile long frameCount=0,connectedSinceMs=0,lastFrameArrivalMs=0,connectionEpoch=0,reconnectKicks=0,lastReconnectKickMs=0;
  volatile String connectedPipe="";
  volatile LocalTransport activePipe;
  Thread worker;AcousticAudioFrame latest;

  AcousticSource(AcousticConfig cfg){this.cfg=cfg;}
  void start(){if(running)return;running=true;worker=new Thread(new Runnable(){public void run(){loop();}},"SynKinectStudio-Acoustic-Port");worker.setDaemon(true);worker.start();}
  void stop(){running=false;closeActivePipe();Thread t=worker;worker=null;if(t!=null){t.interrupt();try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}}connected=false;}
  AcousticAudioFrame snapshot(){synchronized(frameLock){return latest;}}
  String displayStateKey(){
    if(!connected)return stateKey;long now=System.currentTimeMillis();long anchor=lastFrameArrivalMs>0?lastFrameArrivalMs:connectedSinceMs;
    if(anchor>0&&now-anchor>cfg.connectionStaleMs){requestReconnect("stale-session");return "source.reconnecting";}
    if(anchor>0&&now-anchor>cfg.noFrameWarningMs)return lastFrameArrivalMs>0?"source.stale":"source.no_frames";
    return stateKey;
  }
  void requestReconnect(String why){if(!running)return;long now=System.currentTimeMillis();if(now-lastReconnectKickMs<Math.max(100,cfg.reconnectMs))return;lastReconnectKickMs=now;reconnectKicks++;stateKey="source.reconnecting";detail=why;closeActivePipe();}
  void setActivePipe(LocalTransport p){synchronized(pipeLock){activePipe=p;}}
  void clearActivePipe(LocalTransport p){synchronized(pipeLock){if(activePipe==p)activePipe=null;}}
  void closeActivePipe(){LocalTransport p;synchronized(pipeLock){p=activePipe;activePipe=null;}closePipe(p);}
  void closePipe(LocalTransport p){if(p==null)return;try{p.close();}catch(IOException e){if(running)detail=safeMessage(e);}}

  void loop(){
    while(running){LocalTransport pipe=null;
      try{
        connected=false;stateKey="source.connecting";detail="";lastFrameArrivalMs=0;
        pipe=openBestPipe();setActivePipe(pipe);subscribe(pipe);
        connected=true;connectedSinceMs=System.currentTimeMillis();connectionEpoch++;stateKey="source.streaming";
        long last=-1;byte[] hb=new byte[acousticProtocol.HEADER_BYTES],payload=new byte[acousticProtocol.PAYLOAD_BYTES];
        while(running){
          pipe.readFully(hb);ByteBuffer h=ByteBuffer.wrap(hb).order(ByteOrder.LITTLE_ENDIAN);
          int magic=h.getInt(),version=h.getInt(),rate=h.getInt(),channels=h.getInt(),format=h.getInt(),samples=h.getInt(),bytes=h.getInt(),mask=h.getInt();long number=h.getLong(),tick=h.getLong();
          if(magic!=acousticProtocol.FRAME_MAGIC||version!=acousticProtocol.VERSION||rate!=acousticProtocol.SAMPLE_RATE||channels!=acousticProtocol.CHANNELS||format!=acousticProtocol.SAMPLE_FORMAT_S32LE||samples!=acousticProtocol.SAMPLES||bytes!=acousticProtocol.PAYLOAD_BYTES)throw new IOException("protocol-frame");
          if(mask==0||(mask&~acousticProtocol.VALID_CHANNEL_MASK)!=0)throw new IOException("protocol-channel-mask");
          if(last>=0&&number<=last)throw new IOException("protocol-order");last=number;
          pipe.readFully(payload);AcousticAudioFrame frame=decode(payload,number,tick,mask);synchronized(frameLock){latest=frame;}frameCount++;lastFrameArrivalMs=System.currentTimeMillis();
        }
      }catch(IOException e){connected=false;if(running){stateKey="source.reconnecting";detail=safeMessage(e);}}
      finally{clearActivePipe(pipe);closePipe(pipe);}
      if(running)try{Thread.sleep(cfg.reconnectMs);}catch(InterruptedException e){if(!running)return;Thread.currentThread().interrupt();return;}
    }
  }

  LocalTransport openPipeWithRetry(String pipeName,String socketName)throws IOException{
    IOException last=null;
    for(int attempt=1;attempt<=cfg.pipeOpenAttempts&&running;attempt++){
      try{return transportFactory.open(pipeName,socketName);}
      catch(IOException e){
        last=e;
        if(attempt<cfg.pipeOpenAttempts){
          try{Thread.sleep(cfg.pipeOpenRetryMs);}
          catch(InterruptedException interrupted){Thread.currentThread().interrupt();throw new IOException("pipe-open interrupted",interrupted);}
        }
      }
    }
    throw last==null?new IOException("acoustic pipe unavailable"):last;
  }

  LocalTransport openBestPipe()throws IOException{LocalTransport pipe=openPipeWithRetry(acousticProtocol.PIPE,acousticProtocol.SOCKET);connectedPipe=acousticProtocol.PIPE;return pipe;}
  void subscribe(LocalTransport pipe)throws IOException{
    ByteBuffer q=ByteBuffer.allocate(acousticProtocol.REQUEST_BYTES).order(ByteOrder.LITTLE_ENDIAN);q.putInt(acousticProtocol.MAGIC);q.putInt(acousticProtocol.VERSION);q.putInt(acousticProtocol.CMD_SUBSCRIBE);q.putInt(0);pipe.write(q.array());
    byte[] rb=new byte[acousticProtocol.REPLY_BYTES];pipe.readFully(rb);ByteBuffer r=ByteBuffer.wrap(rb).order(ByteOrder.LITTLE_ENDIAN);int magic=r.getInt(),version=r.getInt(),result=r.getInt(),rate=r.getInt(),channels=r.getInt(),format=r.getInt(),maxPayload=r.getInt(),caps=r.getInt();
    if(magic!=acousticProtocol.MAGIC||version!=acousticProtocol.VERSION||result<0||rate!=acousticProtocol.SAMPLE_RATE||channels!=acousticProtocol.CHANNELS||format!=acousticProtocol.SAMPLE_FORMAT_S32LE||maxPayload<acousticProtocol.PAYLOAD_BYTES||(caps&acousticProtocol.REQUIRED_CAPABILITIES)!=acousticProtocol.REQUIRED_CAPABILITIES)throw new IOException("protocol-subscribe");
  }
  AcousticAudioFrame decode(byte[] payload,long number,long tick,int mask){
    AcousticAudioFrame f=new AcousticAudioFrame();f.frameNumber=number;f.tickMs=tick;f.channelMask=mask;ByteBuffer b=ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN);
    for(int n=0;n<acousticProtocol.SAMPLES;n++)for(int ch=0;ch<acousticProtocol.CHANNELS;ch++)f.samples[ch][n]=b.getInt();
    for(int ch=0;ch<acousticProtocol.CHANNELS;ch++){long peak=0;for(int n=0;n<acousticProtocol.SAMPLES;n++){long v=f.samples[ch][n];long a=v==Integer.MIN_VALUE?2147483648L:Math.abs(v);if(a>peak)peak=a;}f.peak[ch]=peak/2147483648.0f;}
    return f;
  }
  String pipeModeKey(){return "source.pipe_dedicated";}
  String safeMessage(Exception e){String m=e.getMessage();return m==null||m.length()==0?e.getClass().getSimpleName():m;}
}


// ===== SynKinect Studio / Acoustic Scanner / AcousticUI.pde =====
class AcousticUI {
  float resetX,resetY,resetW=126,buttonH=38;

  void draw(AcousticAudioFrame frame,AcousticScanFrame scan){drawHeader();drawStatus(frame,scan);drawBody(frame,scan);}

  void drawHeader(){
    fill(acousticTheme.TEXT);acousticText(acousticTheme.FONT_TITLE,true);textAlign(LEFT,CENTER);
    String headerTitle=acousticI18n.tr("app.title");fitCurrentTextSize(headerTitle,acousticTheme.FONT_TITLE,10,max(80,width-210),acousticTheme.HEADER_H-12);text(ellipsizeToWidth(headerTitle,max(80,width-210)),acousticTheme.MARGIN,acousticTheme.HEADER_H/2);textAlign(LEFT,BASELINE);
    resetX=width-acousticTheme.MARGIN-resetW;resetY=15;
    button(resetX,resetY,resetW,buttonH,acousticI18n.tr("button.reset"),false);
  }

  void drawStatus(AcousticAudioFrame frame,AcousticScanFrame scan){
    float x=acousticTheme.MARGIN,y=acousticTheme.HEADER_H+acousticTheme.GAP,w=width-2*acousticTheme.MARGIN,h=112;card(x,y,w,h);cardTitle(x,y,w,acousticI18n.tr("panel.status"));
    String state=acousticSource==null?"source.starting":acousticSource.displayStateKey();String transport=acousticI18n.tr(state);if(acousticSource!=null&&acousticSource.connected)transport+=" · "+acousticI18n.tr(acousticSource.pipeModeKey());
    float ix=x+12,iy=y+acousticTheme.CARD_TITLE_H,innerW=w-24,g=10,tw=(innerW-g*4)/5.0f,th=h-acousticTheme.CARD_TITLE_H-12;
    metric(ix,iy,tw,th,acousticI18n.tr("label.transport"),transport,acousticSource!=null&&acousticSource.connected);
    metric(ix+(tw+g),iy,tw,th,acousticI18n.tr("label.frames"),String.valueOf(acousticSource==null?0:acousticSource.frameCount),true);
    metric(ix+2*(tw+g),iy,tw,th,acousticI18n.tr("label.azimuth"),scan==null?"—":nf(scan.azimuthDeg,1,1)+"°",scan!=null);
    metric(ix+3*(tw+g),iy,tw,th,acousticI18n.tr("label.confidence"),scan==null?"—":nf(scan.confidence*100,1,1)+"%",scan!=null);
    metric(ix+4*(tw+g),iy,tw,th,acousticI18n.tr("label.mode"),acousticI18n.tr("mode.passive"),true);
  }

  void drawBody(AcousticAudioFrame frame,AcousticScanFrame scan){
    float x=acousticTheme.MARGIN,y=acousticTheme.HEADER_H+acousticTheme.GAP+112+acousticTheme.GAP,w=width-2*acousticTheme.MARGIN,h=studio.contentHeight-y-acousticTheme.MARGIN;
    float rightW=max(330,w*0.30f),leftW=w-rightW-acousticTheme.GAP;
    drawRadar(x,y,leftW,h,scan);drawMicLevels(x+leftW+acousticTheme.GAP,y,rightW,h,frame);
  }

  void drawRadar(float x,float y,float w,float h,AcousticScanFrame scan){
    card(x,y,w,h);cardTitle(x,y,w,acousticI18n.tr("panel.radar"));
    float cx=x+w/2,cy=y+h-48,maxR=min(w*0.44f,(h-acousticTheme.CARD_TITLE_H-40)*0.94f);stroke(acousticTheme.GRID);noFill();
    for(int r=1;r<=4;r++)arc(cx,cy,maxR*r/2,maxR*r/2,PI,TWO_PI);
    for(int a=-90;a<=90;a+=30){float t=radians(a);line(cx,cy,cx+maxR*sin(t),cy-maxR*cos(t));}
    fill(acousticTheme.MUTED);acousticText(acousticTheme.FONT_TINY,false);textAlign(CENTER,CENTER);for(int a=-90;a<=90;a+=30){float t=radians(a);text(a+"°",cx+(maxR+18)*sin(t),cy-(maxR+18)*cos(t));}
    if(scan!=null){noStroke();fill(acousticTheme.ACTIVE,42);beginShape();vertex(cx,cy);for(int i=0;i<scan.occupancy.length;i++){float t=radians(-90+i),r=maxR*(0.18f+0.82f*constrain(scan.occupancy[i]*5,0,1));vertex(cx+r*sin(t),cy-r*cos(t));}vertex(cx,cy);endShape(CLOSE);float t=radians(scan.azimuthDeg);stroke(acousticTheme.ACTIVE);strokeWeight(2);line(cx,cy,cx+maxR*sin(t),cy-maxR*cos(t));noStroke();fill(acousticTheme.TEXT);ellipse(cx+maxR*0.82f*sin(t),cy-maxR*0.82f*cos(t),10,10);}
    fill(acousticTheme.MUTED);textAlign(LEFT,TOP);acousticText(acousticTheme.FONT_SMALL,false);String note=acousticI18n.tr("radar.note");fitCurrentTextSize(note,acousticTheme.FONT_SMALL,7,w-28,28);text(ellipsizeToWidth(note,w-28),x+14,y+acousticTheme.CARD_TITLE_H+8);textAlign(LEFT,BASELINE);
    String status=scan==null?acousticI18n.tr("status.waiting"):acousticI18n.format("status.scan",scan.azimuthDeg,scan.rms,scan.confidence*100);fill(acousticTheme.MUTED);acousticText(acousticTheme.FONT_SMALL,false);fitCurrentTextSize(status,acousticTheme.FONT_SMALL,7,w-28,24);text(ellipsizeToWidth(status,w-28),x+14,y+h-18);
  }

  void drawMicLevels(float x,float y,float w,float h,AcousticAudioFrame frame){
    card(x,y,w,h);cardTitle(x,y,w,acousticI18n.tr("panel.microphones"));float top=y+acousticTheme.CARD_TITLE_H+12,rowH=max(52,(h-acousticTheme.CARD_TITLE_H-24)/4.0f);
    for(int ch=0;ch<4;ch++){float yy=top+ch*rowH,peak=frame==null?0:frame.peak[ch];fill(acousticTheme.MUTED);acousticText(acousticTheme.FONT_SMALL,false);text(acousticI18n.format("label.mic",ch+1),x+16,yy+14);fill(acousticTheme.TEXT);textAlign(RIGHT,BASELINE);text(nf(peak*100,1,1)+"%",x+w-16,yy+14);textAlign(LEFT,BASELINE);float bx=x+16,by=yy+24,bw=w-32;fill(acousticTheme.GRID);rect(bx,by,bw,9,4.5f);fill(acousticTheme.ACTIVE);rect(bx,by,bw*constrain(peak,0,1),9,4.5f);}
  }

  void card(float x,float y,float w,float h){stroke(acousticTheme.BORDER);strokeWeight(1);fill(acousticTheme.SURFACE);rect(x,y,w,h,acousticTheme.RADIUS);noStroke();}
  void cardTitle(float x,float y,float w,String title){fill(acousticTheme.TEXT);acousticText(acousticTheme.FONT_SMALL,true);textAlign(LEFT,CENTER);fitCurrentTextSize(title,acousticTheme.FONT_SMALL,8,w-28,acousticTheme.CARD_TITLE_H-8);text(title,x+14,y+acousticTheme.CARD_TITLE_H/2);textAlign(LEFT,BASELINE);}
  void metric(float x,float y,float w,float h,String label,String value,boolean active){fill(acousticTheme.SURFACE2);rect(x,y,w,h,9);fill(active?acousticTheme.ACTIVE:acousticTheme.MUTED);ellipse(x+12,y+15,6,6);fill(acousticTheme.MUTED);acousticText(acousticTheme.FONT_TINY,false);fitCurrentTextSize(label,acousticTheme.FONT_TINY,7,w-30,22);text(ellipsizeToWidth(label,w-30),x+22,y+19);fill(acousticTheme.TEXT);acousticText(acousticTheme.FONT_SMALL,true);fitCurrentTextSize(value,acousticTheme.FONT_SMALL,7,w-20,24);text(ellipsizeToWidth(value,w-20),x+10,y+h-13);}
  void button(float x,float y,float w,float h,String label,boolean primary){float mx=studio.contentMouseX(),my=studio.contentMouseY();boolean hot=mx>=x&&mx<=x+w&&my>=y&&my<=y+h;stroke(hot?acousticTheme.ACTIVE:acousticTheme.BORDER);fill(primary?acousticTheme.RAISED:acousticTheme.SURFACE2);rect(x,y,w,h,9);noStroke();fill(primary?acousticTheme.TEXT:(hot?acousticTheme.TEXT:acousticTheme.MUTED));textAlign(CENTER,CENTER);acousticText(acousticTheme.FONT_SMALL,true);fitCurrentTextSize(label,acousticTheme.FONT_SMALL,8,w-12,h-8);text(label,x+w/2,y+h/2);textAlign(LEFT,BASELINE);}
  void handleMouse(float mx,float my){if(hit(mx,my,resetX,resetY,resetW,buttonH))resetAcousticMap();}
  boolean hit(float mx,float my,float x,float y,float w,float h){return mx>=x&&mx<=x+w&&my>=y&&my<=y+h;}
  String ellipsize(String s,int n){if(s==null)return "";return s.length()<=n?s:s.substring(0,max(0,n-1))+"…";}
}


// ===== SynKinect Studio / Microphones / Module.pde =====
MicrophoneConfig micConfig;
MicrophoneI18n micI18n;
AudioPipeline audioPipeline;
MicrophoneSource microphones;
BridgeDiagnostics bridgeDiagnostics;
MicrophoneUI micUi;

void setupMicrophoneModule(){
  micConfig=new MicrophoneConfig();micConfig.load(new File(dataPath("microphones.properties")));
  micI18n=new MicrophoneI18n(studio.currentLanguage());
  initializeMicrophoneTypography();
  audioPipeline=new AudioPipeline(micConfig);bridgeDiagnostics=new BridgeDiagnostics(micConfig);microphones=new MicrophoneSource(micConfig,audioPipeline);micUi=new MicrophoneUI();
}

void drawMicrophoneModule(){background(microphoneTheme.BG);bridgeDiagnostics.refresh();micUi.draw(microphones==null?null:microphones.snapshot());}

void microphoneMousePressed(){if(micUi!=null)micUi.handleMousePressed(studio.contentMouseX(),studio.contentMouseY());}
void microphoneKeyPressed(){
  if(key=='r'||key=='R')toggleRecording();
  else if(key=='m'||key=='M')toggleMonitor();
  else if(key=='p'||key=='P')togglePlayback();
  else if(key=='t'||key=='T')toggleSpeakerTest();
}

void dispatchMicrophoneAction(int action){
  if(action==micUi.ACTION_RECORD)toggleRecording();
  else if(action==micUi.ACTION_MONITOR)toggleMonitor();
  else if(action==micUi.ACTION_PLAY)togglePlayback();
  else if(action==micUi.ACTION_TEST)toggleSpeakerTest();
}

void toggleRecording(){
  if(audioPipeline.recorder.isRecording()){audioPipeline.recorder.stop();return;}
  File directory=new File(sketchPath(micConfig.recordingsDirectory));
  if(!directory.exists()&&!directory.mkdirs()){audioPipeline.recorder.setError("mkdir");return;}
  String stamp=new SimpleDateFormat("yyyyMMdd-HHmmss",Locale.ROOT).format(new Date());
  audioPipeline.recorder.start(new File(directory,micConfig.recordingPrefix+"-"+stamp+"-4ch-s32.wav"));
}

void toggleMonitor(){
  if(audioPipeline.monitor.isRunning())audioPipeline.monitor.stop();
  else{audioPipeline.player.stop();audioPipeline.selfTest.stop();audioPipeline.monitor.start();}
}

void togglePlayback(){
  if(audioPipeline.player.isRunning()){audioPipeline.player.stop();return;}
  File last=audioPipeline.recorder.lastFile();
  if(last==null||!last.isFile()||last.length()<=44){audioPipeline.player.noFile();return;}
  audioPipeline.monitor.stop();audioPipeline.selfTest.stop();audioPipeline.player.start(last);
}

void toggleSpeakerTest(){
  if(audioPipeline.selfTest.isRunning())audioPipeline.selfTest.stop();
  else{audioPipeline.monitor.stop();audioPipeline.player.stop();audioPipeline.selfTest.start();}
}

void disposeMicrophoneModule(){if(microphones!=null)microphones.stop();if(audioPipeline!=null)audioPipeline.stop();}


// ===== SynKinect Studio / Microphones / AudioPipeline.pde =====
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
 final int blockAlign=microphoneProtocol.CHANNELS*microphoneProtocol.BYTES_PER_SAMPLE;
 final int byteRate=microphoneProtocol.SAMPLE_RATE*blockAlign;
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
      ByteBuffer data=ByteBuffer.allocate(microphoneProtocol.PAYLOAD_BYTES).order(ByteOrder.LITTLE_ENDIAN);
      for(int sample=0;sample<microphoneProtocol.SAMPLES;sample++)
        for(int mic=0;mic<microphoneProtocol.CHANNELS;mic++)
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
    writeLE16(file,1);writeLE16(file,microphoneProtocol.CHANNELS);writeLE32(file,microphoneProtocol.SAMPLE_RATE);writeLE32(file,byteRate);
    writeLE16(file,blockAlign);writeLE16(file,microphoneProtocol.BYTES_PER_SAMPLE*8);file.writeBytes("data");dataSizeOffset=file.getFilePointer();writeLE32(file,0);dataBytes=0;
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
    worker=new Thread(new Runnable(){public void run(){playbackLoop();}},"SynKinectStudio-Microphones-Monitor");worker.setDaemon(true);worker.start();
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
    for(int mic=0;mic<microphoneProtocol.CHANNELS;mic++)if(frame.channelValid(mic)&&frame.peak[mic]>selectedPeak){selectedPeak=frame.peak[mic];selected=mic;}
    if(selected<0)return; dominantMic=selected;
    long framePeak=1;
    for(int sample=0;sample<microphoneProtocol.SAMPLES;sample++){
      int v=frame.samples[selected][sample];long mag=v==Integer.MIN_VALUE?2147483648L:Math.abs((long)v);if(mag>framePeak)framePeak=mag;
    }
    float wanted=constrain((cfg.monitorTargetPeak*2147483647.0f)/framePeak,1.0f,cfg.monitorMaxGain);
    automaticGain=automaticGain*(1.0f-cfg.monitorGainSmoothing)+wanted*cfg.monitorGainSmoothing;
    ByteBuffer pcm=ByteBuffer.allocate(microphoneProtocol.SAMPLES*2).order(ByteOrder.LITTLE_ENDIAN);
    for(int sample=0;sample<microphoneProtocol.SAMPLES;sample++){
      long amplified=(long)(frame.samples[selected][sample]*automaticGain);
      amplified=Math.max(Integer.MIN_VALUE,Math.min(Integer.MAX_VALUE,amplified));
      pcm.putShort((short)constrain((int)(amplified>>16),-32768,32767));
    }
    synchronized(lock){if(!running)return;while(queue.size()>=cfg.monitorQueueFrames)queue.removeFirst();queue.addLast(pcm.array());lock.notifyAll();}
  }

  void playbackLoop(){
    try{
      AudioFormat format=new AudioFormat((float)microphoneProtocol.SAMPLE_RATE,16,1,true,false);
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
    worker=new Thread(new Runnable(){public void run(){playback(file);}},"SynKinectStudio-Microphones-WavPlayback");worker.setDaemon(true);worker.start();
  }
  void stop(){
    running=false;closeLine();Thread t=worker;worker=null;if(t!=null&&t!=Thread.currentThread())try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}
    if(!"playback.error".equals(stateKey)&&!"playback.no_file".equals(stateKey))stateKey="playback.idle";
  }

  void playback(File file){
    RandomAccessFile input=null;
    try{
      input=new RandomAccessFile(file,"r");WavDataRegion region=findDataRegion(input);input.seek(region.offset);
      AudioFormat format=new AudioFormat((float)microphoneProtocol.SAMPLE_RATE,16,1,true,false);
      line=(SourceDataLine)AudioSystem.getLine(new DataLine.Info(SourceDataLine.class,format));line.open(format,cfg.playbackLineBufferBytes);line.start();stateKey="playback.live";
      byte[] raw=new byte[microphoneProtocol.PAYLOAD_BYTES];long remaining=region.bytes;
      while(running&&remaining>0){
        int wanted=(int)Math.min(raw.length,remaining);int n=input.read(raw,0,wanted);if(n<0)break;remaining-=n;
        int frameBytes=microphoneProtocol.CHANNELS*microphoneProtocol.BYTES_PER_SAMPLE;int frames=n/frameBytes;if(frames<=0)continue;
        ByteBuffer src=ByteBuffer.wrap(raw,0,frames*frameBytes).order(ByteOrder.LITTLE_ENDIAN);
        int[][] channel=new int[microphoneProtocol.CHANNELS][frames];long[] peaks=new long[microphoneProtocol.CHANNELS];
        for(int i=0;i<frames;i++)for(int ch=0;ch<microphoneProtocol.CHANNELS;ch++){int v=src.getInt();channel[ch][i]=v;long mag=v==Integer.MIN_VALUE?2147483648L:Math.abs((long)v);if(mag>peaks[ch])peaks[ch]=mag;}
        int selected=0;for(int ch=1;ch<microphoneProtocol.CHANNELS;ch++)if(peaks[ch]>peaks[selected])selected=ch;
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
        formatOk=tag==1&&channels==microphoneProtocol.CHANNELS&&rate==microphoneProtocol.SAMPLE_RATE&&bits==32;
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

  void start(){if(running)return;running=true;stateKey="speaker.starting";detail="";worker=new Thread(new Runnable(){public void run(){playTone();}},"SynKinectStudio-Microphones-SpeakerTest");worker.setDaemon(true);worker.start();}
  void stop(){running=false;closeLine();Thread t=worker;worker=null;if(t!=null&&t!=Thread.currentThread())try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}if(!"speaker.error".equals(stateKey))stateKey="speaker.idle";}
  void playTone(){
    try{
      int rate=microphoneProtocol.SAMPLE_RATE;AudioFormat format=new AudioFormat((float)rate,16,1,true,false);
      line=(SourceDataLine)AudioSystem.getLine(new DataLine.Info(SourceDataLine.class,format));line.open(format,cfg.speakerLineBufferBytes);line.start();
      int samples=max(1,rate*cfg.speakerDurationMs/1000);ByteBuffer tone=ByteBuffer.allocate(samples*2).order(ByteOrder.LITTLE_ENDIAN);
      for(int i=0;i<samples;i++){double edge=Math.min(i, samples-1-i);double envelope=Math.min(1.0,edge/Math.max(1.0,cfg.speakerFadeSamples));short value=(short)(Math.sin(2.0*Math.PI*cfg.speakerFrequencyHz*i/rate)*cfg.speakerAmplitude*envelope);tone.putShort(value);}
      stateKey="speaker.live";if(line!=null)line.write(tone.array(),0,tone.position());if(line!=null)line.drain();stateKey="speaker.done";
    }catch(Exception e){stateKey="speaker.error";detail=safeMessage(e);}
    finally{running=false;closeLine();}
  }
  void closeLine(){SourceDataLine current=line;line=null;if(current!=null){try{current.stop();}catch(Exception ignored){}current.close();}}
  String safeMessage(Exception e){String m=e.getMessage();return m==null||m.length()==0?e.getClass().getSimpleName():m;}
}


// ===== SynKinect Studio / Microphones / BridgeDiagnostics.pde =====
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
    if(transportFactory.isLinux())return new File("/run/kinect360-remold/audio-bridge-status.txt");
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
      if(captureRate()==microphoneProtocol.SAMPLE_RATE&&captureChannels()>=microphoneProtocol.CHANNELS&&published()>0)return "diag.ok";
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


// ===== SynKinect Studio / Microphones / MicrophoneConfig.pde =====
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


// ===== SynKinect Studio / Microphones / MicrophoneLocalization.pde =====
class MicrophoneI18n extends ModuleI18n {
  MicrophoneI18n(String requested){super("microphone",requested);}
}


class MicrophoneTheme {
  final int WINDOW_W=1320, WINDOW_H=900;
  final int BG=0xFF11151A, SURFACE=0xFF181E25, SURFACE_ALT=0xFF202832, RAISED=0xFF293440;
  final int BORDER=0xFF35414D, TEXT=0xFFF4F7FA, MUTED=0xFFAAB6C2, ACTIVE=0xFF68A9E8, DIM=0xFF6F7C88;
  final int GOOD=0xFF7CC7A0, WARN=0xFFE4B86B, BAD=0xFFE17D7D, PREVIEW=0xFF0B0F13, GRID=0xFF35404A;
  final int MARGIN=20, GAP=14, HEADER_H=68, STATUS_H=112, CONTROLS_H=122, RADIUS=14;
  final int FONT_TINY=12, FONT_SMALL=14, FONT_BODY=15, FONT_LABEL=16, FONT_METRIC=19, FONT_TITLE=27;
}

PFont microphoneFontRegular,microphoneFontHeading;
void initializeMicrophoneTypography(){
  String regular=resolveMicrophoneFont(micConfig.uiFontFamily,micConfig.uiFontFallback);
  String heading=resolveMicrophoneFont(micConfig.uiHeadingFontFamily,regular);
  microphoneFontRegular=createFont(regular,microphoneTheme.FONT_BODY,true);
  microphoneFontHeading=createFont(heading,microphoneTheme.FONT_TITLE,true);
  textFont(microphoneFontRegular);textLeading(microphoneTheme.FONT_BODY*1.28f);
}
String resolveMicrophoneFont(String preferred,String fallback){String[] installed=PFont.list();String hit=findMicrophoneFont(installed,preferred);if(hit!=null)return hit;hit=findMicrophoneFont(installed,fallback);return hit==null?"SansSerif":hit;}
String findMicrophoneFont(String[] installed,String wanted){if(wanted==null||wanted.trim().length()==0||installed==null)return null;for(String candidate:installed)if(candidate.equalsIgnoreCase(wanted.trim()))return candidate;return null;}
void micText(float size,boolean heading){PFont f=heading?microphoneFontHeading:microphoneFontRegular;if(f!=null)textFont(f);textSize(responsiveFontSize(size));}


// ===== SynKinect Studio / Microphones / MicrophoneProtocol.pde =====
class MicrophoneProtocol {
  final String PIPE="\\\\.\\pipe\\Kinect360RemoldAudio";
  final String SOCKET="/run/kinect360-remold/audio.sock";
  final int MAGIC=0x414D4D52;
  final int FRAME_MAGIC=0x464D4D52;
  final int VERSION=1;
  final int CMD_SUBSCRIBE=1;
  final int SAMPLE_RATE=16000;
  final int CHANNELS=4;
  final int SAMPLES=256;
  final int SAMPLE_FORMAT_S32LE=1;
  final int BYTES_PER_SAMPLE=4;
  final int PAYLOAD_BYTES=CHANNELS*SAMPLES*BYTES_PER_SAMPLE;
  final int REQUEST_BYTES=16;
  final int REPLY_BYTES=32;
  final int HEADER_BYTES=48;
  final int REQUIRED_CAPABILITIES=0x3;
  final int VALID_CHANNEL_MASK=(1<<CHANNELS)-1;
}

class MicrophoneFrame {
  long frameNumber;
  long tickMs;
  int channelMask;
  int[][] samples=new int[microphoneProtocol.CHANNELS][microphoneProtocol.SAMPLES];
  float[] peak=new float[microphoneProtocol.CHANNELS];
  boolean channelValid(int channel){return channel>=0&&channel<microphoneProtocol.CHANNELS&&(channelMask&(1<<channel))!=0;}
}


// ===== SynKinect Studio / Microphones / MicrophoneSource.pde =====
class MicrophoneSource {
 final MicrophoneConfig cfg;
 final AudioPipeline pipeline;
 final Object lock=new Object();
  volatile boolean running=false,connected=false;
  volatile long frameCount=0,payloadBytesReceived=0,connectedSinceMs=0,lastFrameArrivalMs=0,connectionEpoch=0,reconnectKicks=0,lastReconnectKickMs=0;
  volatile String stateKey="source.starting",detail="",connectedPipe="";
  volatile LocalTransport activePipe;
 final Object pipeLock=new Object();
  Thread worker;MicrophoneFrame latest;

  MicrophoneSource(MicrophoneConfig cfg,AudioPipeline pipeline){this.cfg=cfg;this.pipeline=pipeline;}

  void start(){if(running)return;running=true;worker=new Thread(new Runnable(){public void run(){loop();}},"SynKinectStudio-Microphones-Port");worker.setDaemon(true);worker.start();}
  void stop(){
    running=false;closeActivePipe();Thread t=worker;worker=null;
    if(t!=null){t.interrupt();try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}}
    synchronized(pipeLock){activePipe=null;}connected=false;
  }
  MicrophoneFrame snapshot(){synchronized(lock){return latest;}}
  String displayStateKey(){
    if(!connected)return stateKey;
    long now=System.currentTimeMillis();
    long anchor=lastFrameArrivalMs>0?lastFrameArrivalMs:connectedSinceMs;
    if(anchor>0&&now-anchor>cfg.connectionStaleMs){requestReconnect("stale-session");return "source.reconnecting";}
    if(anchor>0&&now-anchor>cfg.noFrameWarningMs)return lastFrameArrivalMs>0?"source.stale":"source.no_frames";
    return stateKey;
  }

  void setActivePipe(LocalTransport pipe){synchronized(pipeLock){activePipe=pipe;}}
  void clearActivePipe(LocalTransport pipe){synchronized(pipeLock){if(activePipe==pipe)activePipe=null;}}
  void closeActivePipe(){LocalTransport pipe;synchronized(pipeLock){pipe=activePipe;activePipe=null;}closePipe(pipe);}
  void requestReconnect(String reason){
    if(!running)return;long now=System.currentTimeMillis();if(now-lastReconnectKickMs<Math.max(100,cfg.reconnectMs))return;
    lastReconnectKickMs=now;reconnectKicks++;stateKey="source.reconnecting";detail=reason;closeActivePipe();
  }

  void loop(){
    while(running){
      LocalTransport pipe=null;
      try{
        connected=false;stateKey="source.connecting";detail="";lastFrameArrivalMs=0;
        pipe=openBestPipe();setActivePipe(pipe);subscribe(pipe);
        connected=true;connectedSinceMs=System.currentTimeMillis();connectionEpoch++;stateKey="source.streaming";
        long lastFrame=-1;byte[] headerBytes=new byte[microphoneProtocol.HEADER_BYTES];byte[] payload=new byte[microphoneProtocol.PAYLOAD_BYTES];
        while(running){
          pipe.readFully(headerBytes);ByteBuffer h=ByteBuffer.wrap(headerBytes).order(ByteOrder.LITTLE_ENDIAN);
          int magic=h.getInt(),version=h.getInt(),sampleRate=h.getInt(),channels=h.getInt(),sampleFormat=h.getInt(),samplesPerChannel=h.getInt(),payloadBytes=h.getInt(),channelMask=h.getInt();
          long frameNumber=h.getLong(),tickMs=h.getLong();
          validateFrameHeader(magic,version,sampleRate,channels,sampleFormat,samplesPerChannel,payloadBytes,channelMask,frameNumber,lastFrame);lastFrame=frameNumber;
          pipe.readFully(payload);payloadBytesReceived+=payload.length;
          MicrophoneFrame frame=decodeFrame(payload,frameNumber,tickMs,channelMask);
          synchronized(lock){latest=frame;}frameCount++;lastFrameArrivalMs=System.currentTimeMillis();pipeline.accept(frame);
        }
      }catch(IOException e){connected=false;if(running){stateKey="source.reconnecting";detail=safeMessage(e);}}
      finally{clearActivePipe(pipe);closePipe(pipe);}
      if(running)try{Thread.sleep(cfg.reconnectMs);}catch(InterruptedException e){if(!running)return;Thread.currentThread().interrupt();return;}
    }
  }

  void validateFrameHeader(int magic,int version,int rate,int channels,int format,int samples,int payloadBytes,int mask,long frameNumber,long lastFrame)throws IOException{
    if(magic!=microphoneProtocol.FRAME_MAGIC||version!=microphoneProtocol.VERSION)throw new IOException("protocol-frame");
    if(rate!=microphoneProtocol.SAMPLE_RATE||channels!=microphoneProtocol.CHANNELS||format!=microphoneProtocol.SAMPLE_FORMAT_S32LE||samples!=microphoneProtocol.SAMPLES||payloadBytes!=microphoneProtocol.PAYLOAD_BYTES)throw new IOException("protocol-format");
    if((mask&~microphoneProtocol.VALID_CHANNEL_MASK)!=0||mask==0)throw new IOException("protocol-channel-mask");
    if(lastFrame>=0&&frameNumber<=lastFrame)throw new IOException("protocol-frame-order");
  }

  MicrophoneFrame decodeFrame(byte[] payload,long frameNumber,long tickMs,int channelMask){
    ByteBuffer pcm=ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN);MicrophoneFrame frame=new MicrophoneFrame();frame.frameNumber=frameNumber;frame.tickMs=tickMs;frame.channelMask=channelMask;
    for(int sample=0;sample<microphoneProtocol.SAMPLES;sample++)for(int mic=0;mic<microphoneProtocol.CHANNELS;mic++)frame.samples[mic][sample]=pcm.getInt();
    for(int mic=0;mic<microphoneProtocol.CHANNELS;mic++){
      long peak=0;for(int sample=0;sample<microphoneProtocol.SAMPLES;sample++){long value=frame.samples[mic][sample];long magnitude=value==Integer.MIN_VALUE?2147483648L:Math.abs(value);if(magnitude>peak)peak=magnitude;}
      frame.peak[mic]=peak/2147483648.0f;
    }
    return frame;
  }

  LocalTransport openPipeWithRetry(String pipeName,String socketName)throws IOException{
    IOException last=null;
    for(int attempt=1;attempt<=cfg.pipeOpenAttempts&&running;attempt++){
      try{return transportFactory.open(pipeName,socketName);}
      catch(IOException e){
        last=e;
        if(attempt<cfg.pipeOpenAttempts){
          try{Thread.sleep(cfg.pipeOpenRetryMs);}
          catch(InterruptedException interrupted){Thread.currentThread().interrupt();throw new IOException("pipe-open interrupted",interrupted);}
        }
      }
    }
    throw last==null?new IOException("audio pipe unavailable"):last;
  }

  LocalTransport openBestPipe()throws IOException{LocalTransport pipe=openPipeWithRetry(microphoneProtocol.PIPE,microphoneProtocol.SOCKET);connectedPipe=microphoneProtocol.PIPE;return pipe;}

  String pipeModeKey(){return "source.pipe_primary";}

  void subscribe(LocalTransport pipe)throws IOException{
    ByteBuffer request=ByteBuffer.allocate(microphoneProtocol.REQUEST_BYTES).order(ByteOrder.LITTLE_ENDIAN);
    request.putInt(microphoneProtocol.MAGIC);request.putInt(microphoneProtocol.VERSION);request.putInt(microphoneProtocol.CMD_SUBSCRIBE);request.putInt(0);pipe.write(request.array());
    byte[] bytes=new byte[microphoneProtocol.REPLY_BYTES];pipe.readFully(bytes);ByteBuffer r=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
    int magic=r.getInt(),version=r.getInt(),result=r.getInt(),rate=r.getInt(),channels=r.getInt(),format=r.getInt(),maxPayload=r.getInt(),capabilities=r.getInt();
    if(magic!=microphoneProtocol.MAGIC||version!=microphoneProtocol.VERSION||result<0)throw new IOException("protocol-subscribe");
    if(rate!=microphoneProtocol.SAMPLE_RATE||channels!=microphoneProtocol.CHANNELS||format!=microphoneProtocol.SAMPLE_FORMAT_S32LE||maxPayload<microphoneProtocol.PAYLOAD_BYTES)throw new IOException("protocol-bridge-format");
    if((capabilities&microphoneProtocol.REQUIRED_CAPABILITIES)!=microphoneProtocol.REQUIRED_CAPABILITIES)throw new IOException("protocol-capabilities");
  }

  void closePipe(LocalTransport pipe){if(pipe==null)return;try{pipe.close();}catch(IOException e){if(running)detail=safeMessage(e);}}
  String safeMessage(Exception e){String m=e.getMessage();return m==null||m.length()==0?e.getClass().getSimpleName():m;}
}


// ===== SynKinect Studio / Microphones / MicrophoneUI.pde =====
class MicrophoneUI {
  final int ACTION_RECORD=0,ACTION_MONITOR=1,ACTION_PLAY=2,ACTION_TEST=3;
 final ArrayList<MicButton> buttons=new ArrayList<MicButton>();

  MicrophoneUI(){
    buttons.add(new MicButton("button.record",ACTION_RECORD,true));
    buttons.add(new MicButton("button.monitor",ACTION_MONITOR,false));
    buttons.add(new MicButton("button.play",ACTION_PLAY,false));
    buttons.add(new MicButton("button.test",ACTION_TEST,false));
  }

  void draw(MicrophoneFrame frame){
    drawHeader();
    float m=microphoneTheme.MARGIN,g=microphoneTheme.GAP;
    float statusY=microphoneTheme.HEADER_H+g;
    drawTransportPanel(m,statusY,width-2*m,microphoneTheme.STATUS_H);
    float controlsY=studio.contentHeight-microphoneTheme.CONTROLS_H-m;
    float gridY=statusY+microphoneTheme.STATUS_H+g;
    float gridH=controlsY-gridY-g;
    drawMicrophoneGrid(m,gridY,width-2*m,gridH,frame);
    drawControls(m,controlsY,width-2*m,microphoneTheme.CONTROLS_H);
  }

  void drawHeader(){
    fill(microphoneTheme.BG);noStroke();rect(0,0,width,microphoneTheme.HEADER_H);
    fill(microphoneTheme.TEXT);micText(microphoneTheme.FONT_TITLE,true);textAlign(micI18n.startAlign(),CENTER);
    String headerTitle=micI18n.tr("app.title");fitCurrentTextSize(headerTitle,microphoneTheme.FONT_TITLE,10,max(80,width-120),microphoneTheme.HEADER_H-12);text(ellipsizeToWidth(headerTitle,max(80,width-120)),micI18n.rtl?width-microphoneTheme.MARGIN:microphoneTheme.MARGIN,microphoneTheme.HEADER_H/2);
    textAlign(LEFT,BASELINE);
  }

  void drawTransportPanel(float x,float y,float w,float h){
    card(x,y,w,h);
    fill(microphoneTheme.TEXT);micText(microphoneTheme.FONT_SMALL,true);textAlign(LEFT,CENTER);String transportTitle=micI18n.tr("panel.transport");fitCurrentTextSize(transportTitle,microphoneTheme.FONT_SMALL,7,w-24,24);text(ellipsizeToWidth(transportTitle,w-24),x+12,y+17);textAlign(LEFT,BASELINE);
    float top=y+32,gap=8,tw=(w-24-gap*4)/5.0f,th=h-42;
    boolean live=microphones!=null&&microphones.connected;
    String transportState=micI18n.tr(microphones==null?"source.starting":microphones.displayStateKey());
    if(live)transportState+=" · "+micI18n.tr(microphones.pipeModeKey());
    metricTile(x+12,top,tw,th,micI18n.tr("label.transport"),transportState,live);
    metricTile(x+12+(tw+gap),top,tw,th,micI18n.tr("label.frames"),formatCount(microphones==null?0:microphones.frameCount),live);
    metricTile(x+12+2*(tw+gap),top,tw,th,micI18n.tr("label.data"),formatBytes(microphones==null?0:microphones.payloadBytesReceived),live);
    metricTile(x+12+3*(tw+gap),top,tw,th,micI18n.tr("label.runtime"),bridgeDiagnostics.formatSummary(),"diag.ok".equals(bridgeDiagnostics.stateKey()));
    String reconnects=String.valueOf(microphones==null?0:microphones.reconnectKicks);
    String code=bridgeDiagnostics.errorCode();if(code.length()>0)reconnects+=" · E"+code;
    metricTile(x+12+4*(tw+gap),top,tw,th,micI18n.tr("label.reconnects"),reconnects,bridgeDiagnostics.lastError()==0);
  }

  void metricTile(float x,float y,float w,float h,String label,String value,boolean active){
    noStroke();fill(microphoneTheme.SURFACE_ALT);rect(x,y,w,h,8);
    fill(active?microphoneTheme.ACTIVE:microphoneTheme.DIM);ellipse(x+12,y+14,6,6);
    fill(microphoneTheme.MUTED);micText(microphoneTheme.FONT_TINY,false);textAlign(LEFT,CENTER);fitCurrentTextSize(label,microphoneTheme.FONT_TINY,7,w-30,22);text(ellipsizeToWidth(label,w-30),x+22,y+14);
    fill(microphoneTheme.TEXT);micText(microphoneTheme.FONT_SMALL,true);fitCurrentTextSize(value,microphoneTheme.FONT_SMALL,7,w-20,24);text(ellipsizeToWidth(value,w-20),x+10,y+h-15);textAlign(LEFT,BASELINE);
  }

  void drawMicrophoneGrid(float x,float y,float w,float h,MicrophoneFrame frame){
    float gap=microphoneTheme.GAP,cw=(w-gap)/2.0f,ch=(h-gap)/2.0f;
    for(int mic=0;mic<microphoneProtocol.CHANNELS;mic++){
      int col=mic%2,row=mic/2;drawMicrophoneCard(x+col*(cw+gap),y+row*(ch+gap),cw,ch,mic,frame);
    }
  }

  void drawMicrophoneCard(float x,float y,float w,float h,int mic,MicrophoneFrame frame){
    card(x,y,w,h);boolean valid=frame!=null&&frame.channelValid(mic);float peak=valid?frame.peak[mic]:0;
    fill(valid?microphoneTheme.ACTIVE:microphoneTheme.DIM);ellipse(x+14,y+17,7,7);
    fill(microphoneTheme.MUTED);micText(microphoneTheme.FONT_SMALL,false);textAlign(LEFT,CENTER);String micLabel=micI18n.tr("label.mic")+" "+(mic+1);fitCurrentTextSize(micLabel,microphoneTheme.FONT_SMALL,7,max(30,w-105),24);text(ellipsizeToWidth(micLabel,max(30,w-105)),x+25,y+17);
    fill(microphoneTheme.TEXT);textAlign(RIGHT,CENTER);micText(microphoneTheme.FONT_SMALL,true);text(valid?nf(peak*100,1,1)+"%":"—",x+w-12,y+17);textAlign(LEFT,BASELINE);

    float meterX=x+12,meterY=y+31,meterW=w-24;fill(microphoneTheme.GRID);noStroke();rect(meterX,meterY,meterW,5,2.5f);fill(valid?microphoneTheme.ACTIVE:microphoneTheme.DIM);rect(meterX,meterY,meterW*constrain(peak,0,1),5,2.5f);
    float wx=x+12,wy=y+47,ww=w-24,wh=h-59;fill(microphoneTheme.PREVIEW);rect(wx,wy,ww,wh,8);stroke(microphoneTheme.GRID);line(wx,wy+wh/2,wx+ww,wy+wh/2);
    if(!valid)return;
    stroke(microphoneTheme.ACTIVE);noFill();beginShape();
    for(int i=0;i<microphoneProtocol.SAMPLES;i++){
      float sx=map(i,0,microphoneProtocol.SAMPLES-1,wx+4,wx+ww-4);float normalized=constrain(frame.samples[mic][i]/2147483648.0f,-1,1);float sy=wy+wh/2-normalized*wh*0.43f;vertex(sx,sy);
    }
    endShape();
  }

  void drawControls(float x,float y,float w,float h){
    float gap=microphoneTheme.GAP;
    float captureW=(w-gap)/2.0f,playW=w-captureW-gap;
    drawActionGroup(x,y,captureW,h,micI18n.tr("panel.capture"),new int[]{ACTION_RECORD,ACTION_MONITOR});
    drawActionGroup(x+captureW+gap,y,playW,h,micI18n.tr("panel.playback"),new int[]{ACTION_PLAY,ACTION_TEST});
  }

  void drawActionGroup(float x,float y,float w,float h,String title,int[] actions){
    card(x,y,w,h);fill(microphoneTheme.TEXT);micText(microphoneTheme.FONT_TINY,true);textAlign(LEFT,CENTER);fitCurrentTextSize(title,microphoneTheme.FONT_TINY,7,w-20,24);text(title,x+10,y+17);textAlign(LEFT,BASELINE);
    float bx=x+9,by=y+31,gap=7,bh=42,bw=(w-18-gap*(actions.length-1))/actions.length;
    for(int i=0;i<actions.length;i++){MicButton b=findButton(actions[i]);if(b!=null){b.setBounds(bx+i*(bw+gap),by,bw,bh);b.draw();}}
    String status=groupStatus(actions);fill(microphoneTheme.MUTED);micText(microphoneTheme.FONT_TINY,false);textAlign(LEFT,CENTER);fitCurrentTextSize(status,microphoneTheme.FONT_TINY,7,w-20,24);text(ellipsizeToWidth(status,w-20),x+10,y+h-15);textAlign(LEFT,BASELINE);
  }

  String groupStatus(int[] actions){
    if(containsAction(actions,ACTION_RECORD)){
      if(audioPipeline.recorder.isRecording())return micI18n.format("status.recording",formatBytes(audioPipeline.recorder.bytes()));
      if(audioPipeline.monitor.isRunning())return micI18n.format("status.monitor",audioPipeline.monitor.dominantMic+1,nf(audioPipeline.monitor.automaticGain,1,1));
      String key=audioPipeline.recorder.state();return micI18n.tr(key);
    }
    if(containsAction(actions,ACTION_PLAY)){
      if(audioPipeline.player.isRunning())return micI18n.format("status.playback",audioPipeline.player.fileName);
      if(audioPipeline.selfTest.isRunning())return micI18n.format("status.speaker",micConfig.speakerFrequencyHz);
      String key=!"playback.idle".equals(audioPipeline.player.state())?audioPipeline.player.state():audioPipeline.selfTest.state();
      return micI18n.tr(key);
    }
    return micI18n.tr(bridgeDiagnostics.stateKey())+" · "+bridgeDiagnostics.compactCounters();
  }

  boolean containsAction(int[] actions,int action){for(int a:actions)if(a==action)return true;return false;}
  MicButton findButton(int action){for(MicButton b:buttons)if(b.action==action)return b;return null;}
  boolean handleMousePressed(float mx,float my){for(MicButton b:buttons)if(b.hit(mx,my)){b.fire();return true;}return false;}
  void card(float x,float y,float w,float h){stroke(microphoneTheme.BORDER);strokeWeight(1);fill(microphoneTheme.SURFACE);rect(x,y,w,h,microphoneTheme.RADIUS);noStroke();}
  void drawPill(float x,float y,float w,float h,String textValue,boolean active){noStroke();fill(active?microphoneTheme.RAISED:microphoneTheme.SURFACE_ALT);rect(x,y,w,h,h/2);fill(active?microphoneTheme.TEXT:microphoneTheme.MUTED);textAlign(CENTER,CENTER);micText(microphoneTheme.FONT_TINY,true);fitCurrentTextSize(textValue,microphoneTheme.FONT_TINY,7,w-10,h-6);text(ellipsizeToWidth(textValue,w-10),x+w/2,y+h/2);textAlign(LEFT,BASELINE);}
  String formatCount(long value){if(value>=1000000)return nf(value/1000000.0f,1,1)+"M";if(value>=1000)return nf(value/1000.0f,1,1)+"k";return String.valueOf(value);}
  String formatBytes(long value){if(value>=1024L*1024L)return nf(value/(1024.0f*1024.0f),1,1)+" MB";if(value>=1024)return nf(value/1024.0f,1,1)+" KB";return value+" B";}
  String ellipsize(String s,int limit){if(s==null)return "";return s.length()<=limit?s:s.substring(0,max(0,limit-1))+"…";}
}

class MicButton {
  float x,y,w,h;final String labelKey;final int action;final boolean primary;
  MicButton(String key,int action,boolean primary){labelKey=key;this.action=action;this.primary=primary;}
  void setBounds(float x,float y,float w,float h){this.x=x;this.y=y;this.w=w;this.h=h;}
  boolean active(){return action==micUi.ACTION_RECORD?audioPipeline.recorder.isRecording():action==micUi.ACTION_MONITOR?audioPipeline.monitor.isRunning():action==micUi.ACTION_PLAY?audioPipeline.player.isRunning():action==micUi.ACTION_TEST?audioPipeline.selfTest.isRunning():false;}
  String label(){if(active())return micI18n.tr("button.stop");return micI18n.tr(labelKey);}
  void draw(){boolean hot=hit(studio.contentMouseX(),studio.contentMouseY()),on=active();stroke(hot?microphoneTheme.ACTIVE:microphoneTheme.BORDER);fill(on||primary?microphoneTheme.RAISED:microphoneTheme.SURFACE_ALT);rect(x,y,w,h,8);noStroke();fill(on||hot?microphoneTheme.TEXT:microphoneTheme.MUTED);textAlign(CENTER,CENTER);micText(microphoneTheme.FONT_SMALL,true);String value=label();fitCurrentTextSize(value,microphoneTheme.FONT_SMALL,8,w-12,h-8);text(value,x+w/2,y+h/2);textAlign(LEFT,BASELINE);}
  boolean hit(float mx,float my){return mx>=x&&mx<=x+w&&my>=y&&my<=y+h;}
  void fire(){dispatchMicrophoneAction(action);}
}


// ===== SynKinect Studio / Surveillance / Module.pde =====
SurveillanceConfig survConfig;
SurveillanceI18n survI18n;
SurveillanceSource survSource;
MotionDetector survMotionDetector;
MotionVideoRecorder survRecorder;
SurveillanceUI survUi;

PImage survLatestView;
PImage survLatestRgb;
PImage survLatestIr;
volatile String survAppStatus = "";
volatile boolean survArmed = false;
volatile boolean survRecording = false;
volatile long lastMotionMs = 0;
volatile float motionScore = 0;
volatile long recordingStartedMs = 0;
volatile boolean survRecordingInIr = false;
volatile float rgbLuminance = -1;
volatile long lastFrameEpochMs = 0;
int rgbFramesSeen = 0;
int darkRgbFrames = 0;

void setupSurveillanceModule() {
  survConfig = new SurveillanceConfig();
  survConfig.load(new File(dataPath("surveillance.properties")));
  survI18n = new SurveillanceI18n(studio.currentLanguage());
  initializeSurveillanceTypography();
  survMotionDetector = new MotionDetector(survConfig);
  survRecorder = new MotionVideoRecorder(survConfig);
  survUi = new SurveillanceUI();
  survAppStatus = survI18n.tr("status.connecting");

  try {
    survSource = new SurveillanceSource(survConfig, survI18n);
    survArmed = false;
    survAppStatus = survI18n.tr("status.disarmed");
  } catch (Exception e) {
    survAppStatus = survI18n.format("status.init_failed", safeMessage(e));
    println(survAppStatus);
  }
}

void drawSurveillanceModule() {
  background(surveillanceTheme.BG);
  consumeFrames();
  serviceRecordingTimeout();
  serviceRecordingHealth();
  survUi.draw();
}

void consumeFrames() {
  if (survSource == null) return;
  survSource.updateLiveness();
  int drained=0;
  SurveillanceVideoFrame f;
  while(drained<survConfig.videoDrainFramesPerDraw&&(f=survSource.pollVideo())!=null){
    processSurveillanceFrame(f);
    drained++;
  }
}

void processSurveillanceFrame(SurveillanceVideoFrame f) {
  if(f==null)return;
  long epochMs=System.currentTimeMillis();lastFrameEpochMs=epochMs;

  if (f.mode == surveillanceProtocol.MODE_IR) {
    survLatestIr = ir16ToImage(f.payload, f.width, f.height);
    survLatestView = survLatestIr;
    motionScore = survMotionDetector.detectIr(f.payload, f.width, f.height);
    if(survRecording){
      if(survLatestIr!=null)survRecorder.submit(survLatestIr,survRecordingInIr?"IR LOW-LIGHT":"IR",epochMs);
      if(survMotionDetector.moving())lastMotionMs=millis64();
    }else if(survArmed && survMotionDetector.triggered()) startMotionRecording();
  } else if (f.mode == surveillanceProtocol.MODE_RGB) {
    survLatestRgb = nv12ToImage(f.payload, f.width, f.height);
    survLatestView = survLatestRgb;
    motionScore = survLatestRgb == null ? 0 : survMotionDetector.detectRgb(survLatestRgb.pixels, survLatestRgb.width, survLatestRgb.height);
    if (survRecording && survLatestRgb != null) {
      rgbLuminance=measureRgbLuminance(survLatestRgb);
      survRecorder.submit(survLatestRgb,"RGB",epochMs);
      if (survMotionDetector.moving()) lastMotionMs = millis64();
      serviceLowLightDecision();
    }
  }
}

float measureRgbLuminance(PImage image){
  if(image==null||image.pixels==null||image.pixels.length==0)return -1;long sum=0,count=0;int step=max(1,survConfig.lowLightSampleStep);
  for(int y=0;y<image.height;y+=step)for(int x=0;x<image.width;x+=step){int c=image.pixels[y*image.width+x];int r=(c>>16)&255,g=(c>>8)&255,b=c&255;sum+=(77*r+150*g+29*b)>>8;count++;}
  return count==0?-1:(float)sum/count;
}

void serviceLowLightDecision(){
  if(!survRecording||survRecordingInIr||!survConfig.lowLightFallbackEnabled||rgbLuminance<0)return;
  rgbFramesSeen++;if(rgbLuminance<=survConfig.lowLightLumaThreshold)darkRgbFrames++;else darkRgbFrames=0;
  if(rgbFramesSeen>=survConfig.lowLightWarmupFrames&&darkRgbFrames>=survConfig.lowLightDarkFrames)fallbackRecordingToIr();
}

void fallbackRecordingToIr(){
  if(!survRecording||survRecordingInIr)return;survRecordingInIr=true;survMotionDetector.reset();if(survRecorder!=null)survRecorder.markLowLightFallback(rgbLuminance);if(survSource!=null)survSource.requestStreams(surveillanceProtocol.STREAM_IR_DEPTH);survAppStatus=survI18n.format("status.recording_ir_low_light",rgbLuminance);
}


void startMotionRecording() {
  if (survRecording || survRecorder == null) return;
  try {
    survRecorder.startSession(survLatestIr);
    survRecording = true;
    survRecordingInIr=false;rgbFramesSeen=0;darkRgbFrames=0;rgbLuminance=-1;
    recordingStartedMs = millis64();
    lastMotionMs = recordingStartedMs;
    survMotionDetector.reset();
    survSource.requestStreams(surveillanceProtocol.STREAM_RGB_DEPTH);
    survAppStatus = survI18n.tr("status.recording_rgb");
  } catch (Exception e) {
    survAppStatus = survI18n.format("status.record_failed", safeMessage(e));
    survRecording = false;
  }
}

void stopMotionRecording(boolean timeout) {
  if (!survRecording) return;
  survRecording = false;
  survRecordingInIr=false;rgbFramesSeen=0;darkRgbFrames=0;rgbLuminance=-1;
  if (survRecorder != null) survRecorder.stopSession();
  survMotionDetector.reset();
  if (survSource != null) survSource.requestStreams(surveillanceProtocol.STREAM_IR_DEPTH);
  survAppStatus = survI18n.tr(timeout ? "status.record_stopped_idle" : "status.record_stopped_manual");
}

void serviceRecordingTimeout() {
  if (!survRecording) return;
  long now = millis64();
  if (now - lastMotionMs >= survConfig.motionStopAfterMs) stopMotionRecording(true);
}


void serviceRecordingHealth() {
  if (!survRecording || survRecorder == null || !survRecorder.hasFailed()) return;
  String message = survRecorder.failureMessage();
  survRecording = false;
  survRecordingInIr = false;
  rgbFramesSeen = 0;
  darkRgbFrames = 0;
  rgbLuminance = -1;
  survRecorder.stopSession();
  survMotionDetector.reset();
  if (survSource != null) survSource.requestStreams(surveillanceProtocol.STREAM_IR_DEPTH);
  survAppStatus = survI18n.format("status.record_runtime_failed", message.length()==0?survI18n.tr("error.unknown"):message);
}

void toggleArmed() {
  survArmed = !survArmed;
  if (!survArmed && survRecording) stopMotionRecording(false);
  survAppStatus = survI18n.tr(survArmed ? "status.armed_ir" : "status.disarmed");
}

void manualRecord() {
  if (!survRecording) startMotionRecording();
}


void surveillanceMousePressed() { survUi.handleMouse(studio.contentMouseX(),studio.contentMouseY()); }
void surveillanceKeyPressed() {
  if (key == 'a' || key == 'A') toggleArmed();
  else if (key == 'r' || key == 'R') manualRecord();
  else if (key == 's' || key == 'S') stopMotionRecording(false);
}

void disposeSurveillanceModule() {
  if (survRecording) stopMotionRecording(false);
  if (survRecorder != null) survRecorder.shutdown();
  if (survSource != null) survSource.stop();
}

String formatSurveillanceTimestamp(long epochMs){
  try{return new SimpleDateFormat(survConfig==null?"yyyy-MM-dd HH:mm:ss":survConfig.timestampFormat,Locale.ROOT).format(new Date(epochMs));}
  catch(Exception e){return new SimpleDateFormat("yyyy-MM-dd HH:mm:ss",Locale.ROOT).format(new Date(epochMs));}
}
long millis64() { return System.nanoTime() / 1000000L; }
String safeMessage(Exception e) { String m=e.getMessage(); return (m==null||m.length()==0)?e.getClass().getSimpleName():m; }


// ===== SynKinect Studio / Surveillance / MotionDetection.pde =====
class MotionDetector {
 final SurveillanceConfig cfg;
  int[] previous=null;
  int previousMode=-1;
  int warmup=0;
  int consecutive=0;
  boolean isMoving=false;
  boolean isTriggered=false;
  float score=0;

  MotionDetector(SurveillanceConfig cfg){this.cfg=cfg;}
  void reset(){previous=null;previousMode=-1;warmup=cfg.motionWarmupFrames;consecutive=0;isMoving=false;isTriggered=false;score=0;}
  boolean moving(){return isMoving;}
  boolean triggered(){boolean v=isTriggered;isTriggered=false;return v;}

  float detectIr(byte[] payload,int w,int h){
    int step=cfg.motionSampleStep;int count=((w+step-1)/step)*((h+step-1)/step);int[] samples=new int[count];ByteBuffer b=ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN);int n=0;
    for(int y=0;y<h;y+=step)for(int x=0;x<w;x+=step)samples[n++]=b.getShort((y*w+x)*2)&0xFFFF;
    return update(samples,surveillanceProtocol.MODE_IR,cfg.motionIrDelta);
  }

  float detectRgb(int[] pixels,int w,int h){
    int step=cfg.motionSampleStep;int count=((w+step-1)/step)*((h+step-1)/step);int[] samples=new int[count];int n=0;
    for(int y=0;y<h;y+=step)for(int x=0;x<w;x+=step){int c=pixels[y*w+x];int r=(c>>16)&255,g=(c>>8)&255,bb=c&255;samples[n++]=(77*r+150*g+29*bb)>>8;}
    return update(samples,surveillanceProtocol.MODE_RGB,cfg.motionRgbDelta);
  }

  float update(int[] current,int mode,int threshold){
    if(previousMode!=mode||previous==null||previous.length!=current.length){previous=current;previousMode=mode;warmup=cfg.motionWarmupFrames;consecutive=0;isMoving=false;score=0;return 0;}
    int changed=0;for(int i=0;i<current.length;i++)if(abs(current[i]-previous[i])>=threshold)changed++;
    score=current.length==0?0:changed/(float)current.length;previous=current;
    if(warmup>0){warmup--;consecutive=0;isMoving=false;return score;}
    isMoving=score>=cfg.motionMinimumChangedRatio;
    if(isMoving){consecutive++;if(consecutive>=cfg.motionArmFrames)isTriggered=true;}else consecutive=0;
    return score;
  }
}


// ===== SynKinect Studio / Surveillance / Recording.pde =====
class RecordedVideoFrame {
 final int[] pixels;final int width,height;final long capturedEpochMs;final String videoMode;
 RecordedVideoFrame(int[] pixels,int width,int height,long capturedEpochMs,String videoMode){this.pixels=pixels;this.width=width;this.height=height;this.capturedEpochMs=capturedEpochMs;this.videoMode=videoMode;}
}

class MotionVideoRecorder {
 final SurveillanceConfig cfg;final Object latestFrameLock=new Object();
 volatile boolean active=false,lowLightFallback=false,failed=false;volatile float lowLightLuma=-1;volatile String lastVideoMode="IR",lastError="";volatile long sourceFramesSubmitted=0,framesWritten=0,heldFrames=0,staleFrames=0;
 Thread worker;FfmpegMp4Writer writer;RecordedVideoFrame latestFrame;File sessionDir,videoFile,partialVideoFile;long sessionStartedEpochMs=0,videoStartedEpochMs=0,sessionStoppedEpochMs=0,lastSubmitMs=0;
 MotionVideoRecorder(SurveillanceConfig cfg){this.cfg=cfg;}
 synchronized void startSession(PImage triggerIr)throws Exception{
  if(active)return;File root=cfg.recordingsRoot();if(!root.exists()&&!root.mkdirs())throw new IOException("cannot create "+root);sessionStartedEpochMs=System.currentTimeMillis();sessionStoppedEpochMs=0;String stamp=new SimpleDateFormat("yyyyMMdd-HHmmss",Locale.ROOT).format(new Date(sessionStartedEpochMs));sessionDir=uniqueEventDirectory(root,"event-"+stamp);if(!sessionDir.mkdirs())throw new IOException("cannot create "+sessionDir);
  videoFile=new File(sessionDir,"surveillance-motion.mp4");partialVideoFile=new File(sessionDir,"surveillance-motion.partial.mp4");writer=new FfmpegMp4Writer(partialVideoFile,surveillanceProtocol.WIDTH,surveillanceProtocol.HEIGHT,cfg);
  lowLightFallback=false;lowLightLuma=-1;lastVideoMode="IR";lastError="";failed=false;sourceFramesSubmitted=framesWritten=heldFrames=staleFrames=0;lastSubmitMs=0;
  int[] seedPixels=new int[surveillanceProtocol.WIDTH*surveillanceProtocol.HEIGHT];String seedMode="WAITING";if(triggerIr!=null&&triggerIr.width==surveillanceProtocol.WIDTH&&triggerIr.height==surveillanceProtocol.HEIGHT){triggerIr.loadPixels();seedPixels=Arrays.copyOf(triggerIr.pixels,triggerIr.pixels.length);seedMode="IR";byte[] jpg=encodeJpegStamped(seedPixels,triggerIr.width,triggerIr.height,0.80f,cfg,sessionStartedEpochMs,"IR");writeBytes(new File(sessionDir,"trigger-ir.jpg"),jpg);}synchronized(latestFrameLock){latestFrame=new RecordedVideoFrame(seedPixels,surveillanceProtocol.WIDTH,surveillanceProtocol.HEIGHT,sessionStartedEpochMs,seedMode);}
  videoStartedEpochMs=System.currentTimeMillis();active=true;writeEventMetadata("recording",videoStartedEpochMs);worker=new Thread(new Runnable(){public void run(){recordLoop();}},"SynKinectStudio-Surveillance-H264");worker.setDaemon(true);worker.start();
 }
 File uniqueEventDirectory(File root,String base){File first=new File(root,base);if(!first.exists())return first;for(int i=2;i<10000;i++){File candidate=new File(root,base+"-"+String.format(Locale.ROOT,"%03d",i));if(!candidate.exists())return candidate;}return new File(root,base+"-"+System.currentTimeMillis());}
 void submit(PImage image,String mode,long epochMs){if(!active||image==null)return;long now=millis64(),minInterval=Math.max(1L,1000L/Math.max(1,cfg.recordFps*2));if(now-lastSubmitMs<minInterval)return;lastSubmitMs=now;image.loadPixels();if(image.width!=surveillanceProtocol.WIDTH||image.height!=surveillanceProtocol.HEIGHT||image.pixels.length!=surveillanceProtocol.WIDTH*surveillanceProtocol.HEIGHT)return;RecordedVideoFrame frame=new RecordedVideoFrame(Arrays.copyOf(image.pixels,image.pixels.length),image.width,image.height,epochMs,mode==null?"VIDEO":mode);synchronized(latestFrameLock){latestFrame=frame;}sourceFramesSubmitted++;lastVideoMode=frame.videoMode;}
 synchronized void markLowLightFallback(float luma){lowLightFallback=true;lowLightLuma=luma;lastVideoMode="IR_LOW_LIGHT";writeEventMetadata("recording",System.currentTimeMillis());}
 RecordedVideoFrame snapshotLatest(){synchronized(latestFrameLock){return latestFrame;}}
 void recordLoop(){boolean success=false;try{final long startNano=System.nanoTime(),timelineEpochMs=videoStartedEpochMs>0?videoStartedEpochMs:sessionStartedEpochMs;long frameIndex=0;while(true){long targetEpochMs=timelineEpochMs+(frameIndex*1000L)/Math.max(1,cfg.recordFps);if(!active&&sessionStoppedEpochMs>0&&targetEpochMs>sessionStoppedEpochMs)break;long targetNano=startNano+(frameIndex*1000000000L)/Math.max(1,cfg.recordFps),waitNs=targetNano-System.nanoTime();if(active&&waitNs>0)try{Thread.sleep(waitNs/1000000L,(int)(waitNs%1000000L));}catch(InterruptedException e){if(!active)continue;Thread.currentThread().interrupt();throw new IOException("recorder interrupted");}RecordedVideoFrame frame=snapshotLatest();if(frame!=null&&writer!=null){long ageMs=Math.max(0L,targetEpochMs-frame.capturedEpochMs);String mode=frame.videoMode;if(ageMs>cfg.recordFrameHoldMs){mode=mode+" · STALE";staleFrames++;}else if(ageMs>max(100,2000/max(1,cfg.recordFps)))heldFrames++;writer.addFrame(frame.pixels,frame.width,frame.height,cfg,targetEpochMs,mode);framesWritten++;lastVideoMode=frame.videoMode;}frameIndex++;}success=true;}catch(Exception e){failed=true;lastError=safeMessage(e);println("recorder:"+lastError);}finally{active=false;closeAndFinalizeWriter(success&&!failed);}}
 void stopSession(){Thread t;synchronized(this){if(!active&&worker==null){if(sessionDir!=null)writeEventMetadata(failed?"error":"complete",sessionStoppedEpochMs>0?sessionStoppedEpochMs:System.currentTimeMillis());return;}sessionStoppedEpochMs=System.currentTimeMillis();active=false;t=worker;}if(t!=null&&t!=Thread.currentThread())try{t.join(Math.max(5000L,cfg.workerJoinMs*4L));if(t.isAlive()){t.interrupt();t.join(Math.max(1000L,(long)cfg.workerJoinMs));}}catch(InterruptedException e){Thread.currentThread().interrupt();}synchronized(this){if(worker==t)worker=null;}if(sessionDir!=null)writeEventMetadata(failed?"error":"complete",sessionStoppedEpochMs>0?sessionStoppedEpochMs:System.currentTimeMillis());}
 synchronized void closeAndFinalizeWriter(boolean success){FfmpegMp4Writer current=writer;writer=null;if(current!=null)try{current.close();}catch(Exception e){failed=true;lastError=safeMessage(e);println("mp4-close:"+lastError);success=false;}if(success&&partialVideoFile!=null&&partialVideoFile.isFile()&&partialVideoFile.length()>0){if(videoFile.exists()&&!videoFile.delete()){failed=true;lastError="cannot replace "+videoFile.getName();return;}if(!partialVideoFile.renameTo(videoFile)){failed=true;lastError="cannot finalize "+videoFile.getName();}}}
 boolean hasFailed(){return failed;}String failureMessage(){return lastError==null?"":lastError;}void shutdown(){stopSession();}
 void writeBytes(File file,byte[] data)throws IOException{FileOutputStream out=new FileOutputStream(file);try{out.write(data);out.getFD().sync();}finally{out.close();}}
 void writeEventMetadata(String state,long epochMs){if(sessionDir==null)return;Properties p=new Properties();p.setProperty("state",state);p.setProperty("started.epochMs",String.valueOf(sessionStartedEpochMs));p.setProperty("updated.epochMs",String.valueOf(epochMs));p.setProperty("video.started.epochMs",String.valueOf(videoStartedEpochMs));p.setProperty("started.local",formatSurveillanceTimestamp(sessionStartedEpochMs));p.setProperty("updated.local",formatSurveillanceTimestamp(epochMs));if(videoStartedEpochMs>0)p.setProperty("video.started.local",formatSurveillanceTimestamp(videoStartedEpochMs));p.setProperty("video.mode",lastVideoMode);p.setProperty("video.container","mp4");p.setProperty("video.codec","H.264/libx264");p.setProperty("video.fps",String.valueOf(cfg.recordFps));p.setProperty("video.outputSize",cfg.recordWidth+"x"+cfg.recordHeight);p.setProperty("video.targetBitrateKbps",String.valueOf(cfg.recordBitrateKbps));p.setProperty("video.framesWritten",String.valueOf(framesWritten));p.setProperty("video.sourceFramesSubmitted",String.valueOf(sourceFramesSubmitted));p.setProperty("video.heldFrames",String.valueOf(heldFrames));p.setProperty("video.staleFrames",String.valueOf(staleFrames));p.setProperty("video.timeline","constant-frame-rate");p.setProperty("lowLight.fallback",String.valueOf(lowLightFallback));if(lowLightLuma>=0)p.setProperty("lowLight.rgbLuma",String.format(Locale.ROOT,"%.2f",lowLightLuma));if(videoFile!=null)p.setProperty("video",videoFile.getName());if(partialVideoFile!=null&&partialVideoFile.exists())p.setProperty("video.partial",partialVideoFile.getName());if(lastError!=null&&lastError.length()>0)p.setProperty("error",lastError);Writer out=null;try{out=new OutputStreamWriter(new FileOutputStream(new File(sessionDir,"event.properties")),"UTF-8");p.store(out,"SynKinect Surveillance event");}catch(Exception e){println("event-meta:"+safeMessage(e));}finally{if(out!=null)try{out.close();}catch(IOException ignored){}}}
}

class FfmpegMp4Writer {
 final Process process;final OutputStream stdin;final File logFile;final int sourceWidth,sourceHeight;boolean closed=false;
 FfmpegMp4Writer(File target,int sourceWidth,int sourceHeight,SurveillanceConfig cfg)throws IOException{
  this.sourceWidth=sourceWidth;this.sourceHeight=sourceHeight;logFile=new File(target.getParentFile(),"ffmpeg.log");ArrayList<String> cmd=new ArrayList<String>();cmd.add(cfg.ffmpegExecutable);Collections.addAll(cmd,"-hide_banner","-loglevel","error","-y","-f","rawvideo","-pixel_format","bgr24","-video_size",sourceWidth+"x"+sourceHeight,"-framerate",String.valueOf(cfg.recordFps),"-i","pipe:0","-an","-vf","scale="+cfg.recordWidth+":"+cfg.recordHeight+":flags=area","-c:v","libx264","-preset",cfg.recordPreset,"-profile:v","main","-pix_fmt","yuv420p","-b:v",cfg.recordBitrateKbps+"k","-maxrate",cfg.recordMaxBitrateKbps+"k","-bufsize",cfg.recordBufferKbps+"k","-g",String.valueOf(max(cfg.recordFps*8,30)),"-keyint_min",String.valueOf(max(cfg.recordFps*4,15)),"-sc_threshold","0","-movflags","+faststart","-f","mp4",target.getAbsolutePath());ProcessBuilder pb=new ProcessBuilder(cmd);pb.redirectErrorStream(true);pb.redirectOutput(ProcessBuilder.Redirect.appendTo(logFile));process=pb.start();stdin=new BufferedOutputStream(process.getOutputStream(),sourceWidth*sourceHeight*3*2);try{Thread.sleep(80);}catch(InterruptedException e){Thread.currentThread().interrupt();}if(!process.isAlive())throw new IOException("ffmpeg/libx264 failed to start; see "+logFile.getAbsolutePath());
 }
 synchronized void addFrame(int[] pixels,int w,int h,SurveillanceConfig cfg,long epochMs,String mode)throws IOException{if(closed)return;if(w!=sourceWidth||h!=sourceHeight||pixels==null||pixels.length!=w*h)throw new IOException("record frame dimensions");byte[] bgr=encodeBgrStamped(pixels,w,h,cfg,epochMs,mode);stdin.write(bgr);}
 synchronized void close()throws IOException{if(closed)return;closed=true;IOException failure=null;try{stdin.flush();stdin.close();}catch(IOException e){failure=e;}try{if(!process.waitFor(18,TimeUnit.SECONDS)){process.destroy();if(!process.waitFor(3,TimeUnit.SECONDS))process.destroyForcibly();throw new IOException("ffmpeg finalize timeout");}if(process.exitValue()!=0)throw new IOException("ffmpeg exit "+process.exitValue()+"; see "+logFile.getAbsolutePath());}catch(InterruptedException e){Thread.currentThread().interrupt();if(failure==null)failure=new IOException("ffmpeg finalize interrupted",e);}catch(IOException e){if(failure==null)failure=e;}if(failure!=null)throw failure;}
}

byte[] encodeBgrStamped(int[] pixels,int w,int h,SurveillanceConfig cfg,long epochMs,String mode)throws IOException{BufferedImage image=stampedSurveillanceImage(pixels,w,h,cfg,epochMs,mode);int[] rgb=new int[w*h];image.getRGB(0,0,w,h,rgb,0,w);byte[] out=new byte[w*h*3];for(int i=0,j=0;i<rgb.length;i++){int c=rgb[i];out[j++]=(byte)(c&255);out[j++]=(byte)((c>>8)&255);out[j++]=(byte)((c>>16)&255);}return out;}
BufferedImage stampedSurveillanceImage(int[] pixels,int w,int h,SurveillanceConfig cfg,long epochMs,String mode){BufferedImage image=new BufferedImage(w,h,BufferedImage.TYPE_INT_RGB);image.setRGB(0,0,w,h,pixels,0,w);if(cfg.timestampEnabled){java.awt.Graphics2D g=image.createGraphics();try{g.setRenderingHint(java.awt.RenderingHints.KEY_TEXT_ANTIALIASING,java.awt.RenderingHints.VALUE_TEXT_ANTIALIAS_ON);String stamp=formatSurveillanceTimestamp(epochMs),label=(mode==null||mode.length()==0)?stamp:(mode+"  ·  "+stamp);java.awt.Font font=new java.awt.Font(cfg.uiFontFamily,java.awt.Font.BOLD,18);g.setFont(font);java.awt.FontMetrics fm=g.getFontMetrics();int pad=8,boxW=fm.stringWidth(label)+pad*2,boxH=fm.getHeight()+6,x=max(cfg.timestampMargin,w-cfg.timestampMargin-boxW),y=max(cfg.timestampMargin,h-cfg.timestampMargin-boxH);g.setColor(new java.awt.Color(0,0,0,178));g.fillRoundRect(x,y,boxW,boxH,8,8);g.setColor(java.awt.Color.WHITE);g.drawString(label,x+pad,y+boxH-fm.getDescent()-3);}finally{g.dispose();}}return image;}
byte[] encodeJpegStamped(int[] pixels,int w,int h,float quality,SurveillanceConfig cfg,long epochMs,String mode)throws IOException{BufferedImage image=stampedSurveillanceImage(pixels,w,h,cfg,epochMs,mode);ByteArrayOutputStream bytes=new ByteArrayOutputStream(max(16384,w*h/3));Iterator<ImageWriter> writers=ImageIO.getImageWritersByFormatName("jpeg");if(!writers.hasNext())throw new IOException("JPEG writer unavailable");ImageWriter writer=writers.next();ImageOutputStream ios=ImageIO.createImageOutputStream(bytes);try{writer.setOutput(ios);JPEGImageWriteParam p=new JPEGImageWriteParam(Locale.ROOT);p.setCompressionMode(JPEGImageWriteParam.MODE_EXPLICIT);p.setCompressionQuality(max(0.1f,min(1.0f,quality)));writer.write(null,new IIOImage(image,null,null),p);ios.flush();return bytes.toByteArray();}finally{try{ios.close();}catch(Exception ignored){}writer.dispose();}}

// ===== SynKinect Studio / Surveillance / SurveillanceConfig.pde =====
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
  int videoQueueFrames = 24;
  int videoDrainFramesPerDraw = 8;

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

  int recordFps = 10;
  int recordWidth = 512, recordHeight = 384;
  int recordBitrateKbps = 384, recordMaxBitrateKbps = 512, recordBufferKbps = 768;
  String recordPreset = "veryfast", ffmpegExecutable = "ffmpeg";
  int recordFrameHoldMs = 1800;
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
    videoQueueFrames = intValue(p,"transport.videoQueueFrames",videoQueueFrames,2,120);
    videoDrainFramesPerDraw = intValue(p,"transport.drainFramesPerDraw",videoDrainFramesPerDraw,1,32);

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
    recordWidth = evenValue(p,"record.width",recordWidth,160,640);recordHeight = evenValue(p,"record.height",recordHeight,120,480);
    recordBitrateKbps = intValue(p,"record.bitrateKbps",recordBitrateKbps,96,4000);recordMaxBitrateKbps = intValue(p,"record.maxBitrateKbps",recordMaxBitrateKbps,recordBitrateKbps,6000);recordBufferKbps = intValue(p,"record.bufferKbps",recordBufferKbps,recordMaxBitrateKbps,12000);
    recordPreset = textValue(p,"record.preset",recordPreset);ffmpegExecutable = textValue(p,"record.ffmpegExecutable",ffmpegExecutable);
    recordFrameHoldMs = intValue(p,"record.frameHoldMs",recordFrameHoldMs,100,10000);
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
  int evenValue(Properties p,String k,int d,int lo,int hi){int v=intValue(p,k,d,lo,hi);return (v&1)==0?v:v-1;}
  long longValue(Properties p,String k,long d,long lo,long hi){try{long v=Long.parseLong(textValue(p,k,String.valueOf(d)));return Math.max(lo,Math.min(hi,v));}catch(Exception e){return d;}}
  float floatValue(Properties p,String k,float d,float lo,float hi){try{return constrain(Float.parseFloat(textValue(p,k,String.valueOf(d))),lo,hi);}catch(Exception e){return d;}}
}


// ===== SynKinect Studio / Surveillance / SurveillanceLocalization.pde =====
class SurveillanceI18n extends ModuleI18n {
  SurveillanceI18n(String requested){super("surveillance",requested);}
}


class SurveillanceTheme {
  final int WINDOW_WIDTH=1380,WINDOW_HEIGHT=860;
  final int BG=0xFF11151A,SURFACE=0xFF181E25,SURFACE_ALT=0xFF202832,SURFACE_RAISED=0xFF293440;
  final int BORDER=0xFF35414D,TEXT=0xFFF4F7FA,MUTED=0xFFAAB6C2,ACCENT=0xFF68A9E8,GOOD=0xFF7CC7A0,WARN=0xFFE4B86B,BAD=0xFFE17D7D,PREVIEW=0xFF0B0F13;
  final int MARGIN=20,GAP=14,RADIUS=14,HEADER_H=68,FOOTER_H=102,CARD_TITLE_H=44;
  final int FONT_TINY=12,FONT_SMALL=14,FONT_BODY=15,FONT_LABEL=16,FONT_METRIC=19,FONT_TITLE=27;
}

PFont surveillanceFontRegular,surveillanceFontHeading;
void initializeSurveillanceTypography(){
  String regular=resolveSurveillanceFont(survConfig.uiFontFamily,survConfig.uiFontFallback);
  String heading=resolveSurveillanceFont(survConfig.uiHeadingFontFamily,regular);
  surveillanceFontRegular=createFont(regular,surveillanceTheme.FONT_BODY,true);
  surveillanceFontHeading=createFont(heading,surveillanceTheme.FONT_TITLE,true);
  textFont(surveillanceFontRegular);textLeading(surveillanceTheme.FONT_BODY*1.28f);
}
String resolveSurveillanceFont(String preferred,String fallback){String[] installed=PFont.list();String hit=findSurveillanceFont(installed,preferred);if(hit!=null)return hit;hit=findSurveillanceFont(installed,fallback);return hit==null?"SansSerif":hit;}
String findSurveillanceFont(String[] installed,String wanted){if(wanted==null||wanted.trim().length()==0||installed==null)return null;for(String candidate:installed)if(candidate.equalsIgnoreCase(wanted.trim()))return candidate;return null;}
void surveillanceText(float size,boolean heading){PFont f=heading?surveillanceFontHeading:surveillanceFontRegular;if(f!=null)textFont(f);textSize(responsiveFontSize(size));}


// ===== SynKinect Studio / Surveillance / SurveillanceProtocol.pde =====
class SurveillanceProtocol {
  final String PIPE_NAME = "\\\\.\\pipe\\Kinect360RemoldScanner";
  final String SOCKET_NAME = "/run/kinect360-remold/scanner.sock";
  final int MAGIC = 0x43534D52;
  final int FRAME_MAGIC = 0x46534D52;
  final int VERSION = 1;
  final int CMD_SUBSCRIBE_STREAMS = 1;

  final int WIDTH = 640;
  final int HEIGHT = 480;
  final int MODE_RGB = 0;
  final int MODE_IR = 1;
  final int MODE_DEPTH = 2;
  final int STREAM_RGB = 1;
  final int STREAM_IR = 2;
  final int STREAM_DEPTH = 4;
  final int STREAM_RGB_DEPTH = STREAM_RGB | STREAM_DEPTH;
  final int STREAM_IR_DEPTH = STREAM_IR | STREAM_DEPTH;

  final int CAP_RGB_DEPTH_CONCURRENT = 1;
  final int CAP_EXCLUSIVE_VIDEO_MODE = 2;
  final int CAP_PROJECTOR_REFCOUNTED = 4;
  final int REQUIRED_CAPABILITIES = CAP_EXCLUSIVE_VIDEO_MODE | CAP_PROJECTOR_REFCOUNTED;

  final int PIXEL_NV12 = 1;
  final int PIXEL_GRAY16 = 2;
  final int PIXEL_DEPTH_MM16 = 3;
  final int FLAG_DEVICE_CALIBRATED = 1;
  final int FLAG_FRAME_RECOVERED = 2;
  final int KNOWN_FRAME_FLAGS = FLAG_DEVICE_CALIBRATED | FLAG_FRAME_RECOVERED;

  final int RGB_BYTES = WIDTH * HEIGHT * 3 / 2;
  final int IR_BYTES = WIDTH * HEIGHT * 2;
  final int DEPTH_BYTES = WIDTH * HEIGHT * 2;
  final int MAX_PAYLOAD_BYTES = DEPTH_BYTES;
  final int REPLY_BYTES = 32;
  final int FRAME_HEADER_BYTES = 76;
}

int surveillanceMaskForMode(int mode) {
  return mode == surveillanceProtocol.MODE_RGB ? surveillanceProtocol.STREAM_RGB
       : mode == surveillanceProtocol.MODE_IR ? surveillanceProtocol.STREAM_IR
       : mode == surveillanceProtocol.MODE_DEPTH ? surveillanceProtocol.STREAM_DEPTH : 0;
}

int surveillanceExpectedFormatForMode(int mode) {
  return mode == surveillanceProtocol.MODE_RGB ? surveillanceProtocol.PIXEL_NV12
       : mode == surveillanceProtocol.MODE_IR ? surveillanceProtocol.PIXEL_GRAY16
       : mode == surveillanceProtocol.MODE_DEPTH ? surveillanceProtocol.PIXEL_DEPTH_MM16 : -1;
}

int surveillanceExpectedPayloadBytesForMode(int mode) {
  return mode == surveillanceProtocol.MODE_RGB ? surveillanceProtocol.RGB_BYTES
       : mode == surveillanceProtocol.MODE_IR ? surveillanceProtocol.IR_BYTES
       : mode == surveillanceProtocol.MODE_DEPTH ? surveillanceProtocol.DEPTH_BYTES : -1;
}


// ===== SynKinect Studio / Surveillance / SurveillanceSource.pde =====
class SurveillanceVideoFrame {
  int mode,width,height,flags;
  long frameNumber,tickMs;
  byte[] payload;
}

class SurveillanceSource {
 final SurveillanceConfig cfg;
 final SurveillanceI18n survI18n;
 final Object frameLock=new Object();
 final Object pipeLock=new Object();
 final byte[] headerBytes=new byte[surveillanceProtocol.FRAME_HEADER_BYTES];
  volatile boolean running=false,portReady=false,deviceConnected=false,videoConnected=false,depthConnected=false;
  volatile int desiredMask=surveillanceProtocol.STREAM_IR_DEPTH,currentMask=0,negotiatedMaxPayload=0;
  volatile long lastVideoMs=0,lastDepthMs=0,lastAnyMs=0,connectedSinceMs=0;
  volatile long videoFrames=0,depthFrames=0,reconnects=0;
  volatile String lastError="";
  LocalTransport activePipe;
  Thread worker;
  final ArrayDeque<SurveillanceVideoFrame> videoQueue=new ArrayDeque<SurveillanceVideoFrame>();
  volatile long droppedVideoFrames=0;
  long[] lastFrameNumber={-1,-1,-1};

  SurveillanceSource(SurveillanceConfig cfg,SurveillanceI18n survI18n){this.cfg=cfg;this.survI18n=survI18n;}

  synchronized void start(int mask){
    if(mask!=surveillanceProtocol.STREAM_IR_DEPTH&&mask!=surveillanceProtocol.STREAM_RGB_DEPTH)return;
    desiredMask=mask;
    if(running){requestStreams(mask);return;}
    running=true;
    worker=new Thread(new Runnable(){public void run(){loop();}},"SynKinectStudio-Surveillance-Port");
    worker.setDaemon(true);worker.start();
  }
  void stop(){
    running=false;closeActivePipe();Thread t=worker;
    if(t!=null){t.interrupt();try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}}
    if(worker==t)worker=null;reset(true);
  }

  void requestStreams(int mask){
    if(mask!=surveillanceProtocol.STREAM_IR_DEPTH&&mask!=surveillanceProtocol.STREAM_RGB_DEPTH)return;
    if(desiredMask==mask)return;desiredMask=mask;closeActivePipe();
  }

  void updateLiveness(){
    long now=millis64();
    videoConnected=lastVideoMs>0&&now-lastVideoMs<=cfg.streamStaleMs;
    depthConnected=lastDepthMs>0&&now-lastDepthMs<=cfg.streamStaleMs;
    deviceConnected=lastAnyMs>0&&now-lastAnyMs<=cfg.connectionStaleMs;
    long anchor=lastAnyMs>0?lastAnyMs:connectedSinceMs;
    if(portReady&&anchor>0&&now-anchor>cfg.connectionStaleMs){lastError=survI18n.tr("transport.stale");closeActivePipe();}
  }

  SurveillanceVideoFrame pollVideo(){synchronized(frameLock){return videoQueue.isEmpty()?null:videoQueue.removeFirst();}}
  int queuedVideoFrames(){synchronized(frameLock){return videoQueue.size();}}
  void enqueueVideo(SurveillanceVideoFrame frame){synchronized(frameLock){if(videoQueue.size()>=cfg.videoQueueFrames){videoQueue.removeFirst();droppedVideoFrames++;}videoQueue.addLast(frame);}}
  boolean projectorActive(){return depthConnected;}
  boolean irMode(){return currentMask==surveillanceProtocol.STREAM_IR_DEPTH;}

  void loop(){
    while(running){
      LocalTransport pipe=null;
      try{
        reset(true);int mask=desiredMask;
        pipe=transportFactory.open(surveillanceProtocol.PIPE_NAME,surveillanceProtocol.SOCKET_NAME);setActivePipe(pipe);
        subscribe(pipe,mask);connectedSinceMs=millis64();lastError="";
        while(running&&mask==desiredMask)readFrame(pipe,mask);
      }catch(Exception e){if(running){lastError=survI18n.format("transport.error",safeMessage(e));reconnects++;}}
      finally{clearActivePipe(pipe);closePipe(pipe);reset(false);}
      if(running)try{Thread.sleep(cfg.reconnectMs);}catch(InterruptedException e){if(!running)return;Thread.currentThread().interrupt();return;}
    }
  }

  void subscribe(LocalTransport pipe,int mask)throws IOException{
    ByteBuffer q=ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN);
    q.putInt(surveillanceProtocol.MAGIC).putInt(surveillanceProtocol.VERSION).putInt(surveillanceProtocol.CMD_SUBSCRIBE_STREAMS).putInt(mask);pipe.write(q.array());
    byte[] rb=new byte[surveillanceProtocol.REPLY_BYTES];pipe.readFully(rb);ByteBuffer r=ByteBuffer.wrap(rb).order(ByteOrder.LITTLE_ENDIAN);
    int magic=r.getInt(),version=r.getInt(),result=r.getInt(),accepted=r.getInt(),w=r.getInt(),h=r.getInt(),caps=r.getInt(),maxPayload=r.getInt();
    if(magic!=surveillanceProtocol.MAGIC)throw new IOException("reply/magic");
    if(version!=surveillanceProtocol.VERSION)throw new IOException("reply/version:"+version);
    if(result<0)throw new IOException("reply/result:0x"+Integer.toHexString(result));
    if(accepted!=mask)throw new IOException("reply/mask:"+accepted+"/"+mask);
    if(w!=surveillanceProtocol.WIDTH||h!=surveillanceProtocol.HEIGHT)throw new IOException("reply/dimensions:"+w+"x"+h);
    if((caps&surveillanceProtocol.REQUIRED_CAPABILITIES)!=surveillanceProtocol.REQUIRED_CAPABILITIES)throw new IOException("reply/caps:0x"+Integer.toHexString(caps));
    if(maxPayload<surveillanceProtocol.MAX_PAYLOAD_BYTES)throw new IOException("reply/max-payload:"+maxPayload);
    negotiatedMaxPayload=maxPayload;currentMask=mask;portReady=true;
  }

  void readFrame(LocalTransport input,int sessionMask)throws IOException{
    input.readFully(headerBytes);ByteBuffer h=ByteBuffer.wrap(headerBytes).order(ByteOrder.LITTLE_ENDIAN);
    int magic=h.getInt(),version=h.getInt(),mode=h.getInt(),w=h.getInt(),hh=h.getInt(),fmt=h.getInt(),bytes=h.getInt(),flags=h.getInt();
    long frameNo=h.getLong(),tickMs=h.getLong();
    h.getInt();h.getInt();h.getInt();h.getInt();h.getInt();h.getLong(); // motion sample belongs to bridge diagnostics, not image motion detection.
    if(magic!=surveillanceProtocol.FRAME_MAGIC)throw new IOException("frame/magic");
    if(version!=surveillanceProtocol.VERSION)throw new IOException("frame/version:"+version);
    if(w!=surveillanceProtocol.WIDTH||hh!=surveillanceProtocol.HEIGHT)throw new IOException("frame/dimensions:"+w+"x"+hh);
    int modeMask=surveillanceMaskForMode(mode);if(modeMask==0||(sessionMask&modeMask)==0)throw new IOException("frame/mode:"+mode);
    if(fmt!=surveillanceExpectedFormatForMode(mode))throw new IOException("frame/format:"+mode+"/"+fmt);
    if(bytes!=surveillanceExpectedPayloadBytesForMode(mode)||bytes>negotiatedMaxPayload)throw new IOException("frame/size:"+mode+"/"+bytes);
    if((flags&~surveillanceProtocol.KNOWN_FRAME_FLAGS)!=0)throw new IOException("frame/flags:0x"+Integer.toHexString(flags));
    if(lastFrameNumber[mode]>=0&&frameNo<=lastFrameNumber[mode])throw new IOException("frame/order:"+mode);lastFrameNumber[mode]=frameNo;
    byte[] payload=new byte[bytes];input.readFully(payload);long now=millis64();lastAnyMs=now;deviceConnected=true;lastError="";
    if(mode==surveillanceProtocol.MODE_DEPTH){depthFrames++;lastDepthMs=now;depthConnected=true;return;}
    SurveillanceVideoFrame f=new SurveillanceVideoFrame();f.mode=mode;f.width=w;f.height=hh;f.flags=flags;f.frameNumber=frameNo;f.tickMs=tickMs;f.payload=payload;
    enqueueVideo(f);videoFrames++;lastVideoMs=now;videoConnected=true;
  }

  void reset(boolean clearFrame){portReady=false;deviceConnected=false;videoConnected=false;depthConnected=false;currentMask=0;connectedSinceMs=0;lastVideoMs=0;lastDepthMs=0;lastAnyMs=0;for(int i=0;i<lastFrameNumber.length;i++)lastFrameNumber[i]=-1;if(clearFrame)synchronized(frameLock){videoQueue.clear();}}
  void setActivePipe(LocalTransport p){synchronized(pipeLock){activePipe=p;}}
  void clearActivePipe(LocalTransport p){synchronized(pipeLock){if(activePipe==p)activePipe=null;}}
  void closeActivePipe(){LocalTransport p;synchronized(pipeLock){p=activePipe;activePipe=null;}closePipe(p);}
  void closePipe(LocalTransport p){if(p!=null)try{p.close();}catch(IOException ignored){}}
}

PImage nv12ToImage(byte[] data,int w,int h){
  if(data==null||data.length!=w*h*3/2)return null;PImage img=createImage(w,h,RGB);img.loadPixels();int ySize=w*h;
  for(int y=0;y<h;y++)for(int x=0;x<w;x++){int yi=data[y*w+x]&0xFF;int uv=ySize+(y/2)*w+(x&~1);int u=(data[uv]&0xFF)-128,v=(data[uv+1]&0xFF)-128;int c=max(0,yi-16);int rr=(298*c+409*v+128)>>8,gg=(298*c-100*u-208*v+128)>>8,bb=(298*c+516*u+128)>>8;img.pixels[y*w+x]=0xFF000000|(constrain(rr,0,255)<<16)|(constrain(gg,0,255)<<8)|constrain(bb,0,255);}
  img.updatePixels();return img;
}

PImage ir16ToImage(byte[] data,int w,int h){
  if(data==null||data.length!=w*h*2)return null;PImage img=createImage(w,h,RGB);img.loadPixels();ByteBuffer b=ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN);
  int lo=1023,hi=0;int step=8;for(int y=0;y<h;y+=step)for(int x=0;x<w;x+=step){int v=b.getShort((y*w+x)*2)&0xFFFF;if(v>0){lo=min(lo,v);hi=max(hi,v);}}
  if(hi<=lo){lo=0;hi=1023;}for(int i=0;i<w*h;i++){int v=b.getShort(i*2)&0xFFFF;int g=constrain((v-lo)*255/max(1,hi-lo),0,255);img.pixels[i]=0xFF000000|(g<<16)|(g<<8)|g;}img.updatePixels();return img;
}


// ===== SynKinect Studio / Surveillance / SurveillanceUI.pde =====
class SurveillanceUI {
 final UiRect armButton=new UiRect(),recordButton=new UiRect(),stopButton=new UiRect();

  void draw(){
    drawHeader();
    float m=surveillanceTheme.MARGIN,g=surveillanceTheme.GAP;
    float top=surveillanceTheme.HEADER_H+g,bottom=studio.contentHeight-surveillanceTheme.FOOTER_H-m,bodyH=max(360,bottom-top-g);
    float sideW=max(330,min(430,width*0.30f)),viewW=width-2*m-g-sideW,sideX=m+viewW+g;
    drawVideoPanel(m,top,viewW,bodyH);
    drawStatusPanel(sideX,top,sideW,bodyH);
    drawButtons(m,bottom,width-2*m,surveillanceTheme.FOOTER_H);
  }

  void drawHeader(){
    fill(surveillanceTheme.TEXT);surveillanceText(surveillanceTheme.FONT_TITLE,true);textAlign(survI18n.startAlign(),CENTER);
    String headerTitle=survI18n.tr("app.title");fitCurrentTextSize(headerTitle,surveillanceTheme.FONT_TITLE,10,max(80,width-260),surveillanceTheme.HEADER_H-12);text(ellipsizeToWidth(headerTitle,max(80,width-260)),survI18n.rtl?width-surveillanceTheme.MARGIN:surveillanceTheme.MARGIN,surveillanceTheme.HEADER_H/2);
    String mode=survRecording?(survRecordingInIr?survI18n.tr("badge.recording_ir"):survI18n.tr("badge.recording_rgb")):(survArmed?survI18n.tr("badge.armed"):survI18n.tr("badge.disarmed"));
    float bw=190,bx=width-surveillanceTheme.MARGIN-bw;drawChip(bx,18,bw,32,mode,survRecording||survArmed);
    textAlign(LEFT,BASELINE);
  }

  void drawVideoPanel(float x,float y,float w,float h){
    card(x,y,w,h);String panel=survSource!=null&&survSource.irMode()?survI18n.tr("panel.ir"):survI18n.tr("panel.rgb");cardTitle(x,y,w,panel);
    float px=x+12,py=y+surveillanceTheme.CARD_TITLE_H,pw=w-24,ph=h-surveillanceTheme.CARD_TITLE_H-12;preview(px,py,pw,ph);
  }

  void preview(float x,float y,float w,float h){
    noStroke();fill(surveillanceTheme.PREVIEW);rect(x,y,w,h,10);
    if(survLatestView==null){fill(surveillanceTheme.MUTED);textAlign(CENTER,CENTER);surveillanceText(surveillanceTheme.FONT_BODY,false);String waiting=survI18n.tr("waiting.video");fitCurrentTextSize(waiting,surveillanceTheme.FONT_BODY,8,w-20,h-20);text(ellipsizeToWidth(waiting,w-20),x+w/2,y+h/2);textAlign(LEFT,BASELINE);drawTimestampOverlay(x,y,w,h);return;}
    float s=min(w/survLatestView.width,h/survLatestView.height);float dw=survLatestView.width*s,dh=survLatestView.height*s,ix=x+(w-dw)/2,iy=y+(h-dh)/2;image(survLatestView,ix,iy,dw,dh);
    if(survRecording){noStroke();fill(surveillanceTheme.BAD);ellipse(ix+22,iy+22,12,12);fill(surveillanceTheme.TEXT);surveillanceText(surveillanceTheme.FONT_SMALL,true);text(survI18n.tr("overlay.rec"),ix+36,iy+27);}
    if(survRecordingInIr){drawChip(ix+12,iy+42,156,28,survI18n.tr("overlay.low_light_ir"),true);}
    drawTimestampOverlay(ix,iy,dw,dh);
  }

  void drawTimestampOverlay(float x,float y,float w,float h){
    if(survConfig==null||!survConfig.timestampEnabled)return;long epoch=lastFrameEpochMs>0?lastFrameEpochMs:System.currentTimeMillis();String stamp=formatSurveillanceTimestamp(epoch);String mode=(survSource!=null&&survSource.irMode())?"IR":"RGB";String value=mode+"  ·  "+stamp;
    surveillanceText(surveillanceTheme.FONT_SMALL,true);float tw=textWidth(value)+20,th=32;float bx=x+w-survConfig.timestampMargin-tw,by=y+h-survConfig.timestampMargin-th;bx=max(x+survConfig.timestampMargin,bx);by=max(y+survConfig.timestampMargin,by);
    noStroke();fill(0,178);rect(bx,by,tw,th,8);fill(surveillanceTheme.TEXT);textAlign(CENTER,CENTER);text(value,bx+tw/2,by+th/2);textAlign(LEFT,BASELINE);
  }

  void drawStatusPanel(float x,float y,float w,float h){
    card(x,y,w,h);cardTitle(x,y,w,survI18n.tr("panel.status"));float px=x+14,py=y+surveillanceTheme.CARD_TITLE_H+4,innerW=w-28,rowH=55;
    statusTile(px,py,innerW,rowH,survI18n.tr("label.state"),survRecording?survI18n.tr("state.recording"):(survArmed?survI18n.tr("state.armed"):survI18n.tr("state.disarmed")),survRecording||survArmed);py+=rowH+8;
    statusTile(px,py,innerW,rowH,survI18n.tr("label.video"),survSource==null?"—":(survSource.irMode()?"IR":"RGB"),survSource!=null&&survSource.videoConnected);py+=rowH+8;
    statusTile(px,py,innerW,rowH,survI18n.tr("label.ir_projector"),survSource!=null&&survSource.projectorActive()?survI18n.tr("state.on"):survI18n.tr("state.off"),survSource!=null&&survSource.projectorActive());py+=rowH+8;
    statusTile(px,py,innerW,rowH,survI18n.tr("label.motion"),nf(motionScore*100,1,2)+"%",motionScore>=survConfig.motionMinimumChangedRatio);py+=rowH+8;
    String luma=rgbLuminance<0?"—":nf(rgbLuminance,1,1)+" / 255";statusTile(px,py,innerW,rowH,survI18n.tr("label.luminance"),luma,rgbLuminance<0||rgbLuminance>survConfig.lowLightLumaThreshold);py+=rowH+8;
    statusTile(px,py,innerW,rowH,survI18n.tr("label.frames"),survSource==null?"0":String.valueOf(survSource.videoFrames),survSource!=null&&survSource.videoFrames>0);py+=rowH+12;
    fill(surveillanceTheme.MUTED);surveillanceText(surveillanceTheme.FONT_TINY,true);String statusTitle=survI18n.tr("label.status");fitCurrentTextSize(statusTitle,surveillanceTheme.FONT_TINY,7,innerW,22);text(ellipsizeToWidth(statusTitle,innerW),px,py+12);py+=24;
    String message=survSource!=null&&survSource.lastError.length()>0?survI18n.tr("transport.unavailable"):survAppStatus;fill(survSource!=null&&survSource.lastError.length()>0?surveillanceTheme.WARN:surveillanceTheme.TEXT);surveillanceText(surveillanceTheme.FONT_SMALL,false);text(ellipsize(message,max(42,(int)(innerW/7))),px,py,innerW,max(54,h-(py-y)-16));
  }

  void statusTile(float x,float y,float w,float h,String label,String value,boolean active){
    noStroke();fill(surveillanceTheme.SURFACE_ALT);rect(x,y,w,h,9);fill(active?surveillanceTheme.ACCENT:surveillanceTheme.MUTED);ellipse(x+13,y+15,6,6);
    fill(surveillanceTheme.MUTED);surveillanceText(surveillanceTheme.FONT_TINY,false);fitCurrentTextSize(label,surveillanceTheme.FONT_TINY,7,w-31,22);text(ellipsizeToWidth(label,w-31),x+23,y+19);fill(surveillanceTheme.TEXT);surveillanceText(surveillanceTheme.FONT_METRIC,true);fitCurrentTextSize(value,surveillanceTheme.FONT_METRIC,7,w-22,26);text(ellipsizeToWidth(value,w-22),x+11,y+h-12);
  }

  void drawButtons(float x,float y,float w,float h){
    card(x,y,w,h);float gap=10,bw=(w-gap*2-24)/3.0f,bh=h-24,bx=x+12,by=y+12;
    armButton.set(bx,by,bw,bh);recordButton.set(bx+bw+gap,by,bw,bh);stopButton.set(bx+2*(bw+gap),by,bw,bh);
    button(armButton,survArmed?survI18n.tr("button.disarm"):survI18n.tr("button.arm"),true,true);button(recordButton,survI18n.tr("button.record"),!survRecording,true);button(stopButton,survI18n.tr("button.stop"),survRecording,false);
  }

  void button(UiRect r,String label,boolean enabled,boolean primary){boolean hot=enabled&&r.hit(studio.contentMouseX(),studio.contentMouseY());stroke(hot?surveillanceTheme.ACCENT:surveillanceTheme.BORDER);fill(enabled?(primary?surveillanceTheme.SURFACE_RAISED:surveillanceTheme.SURFACE_ALT):surveillanceTheme.BG);rect(r.x,r.y,r.w,r.h,9);noStroke();fill(enabled?surveillanceTheme.TEXT:surveillanceTheme.BORDER);textAlign(CENTER,CENTER);surveillanceText(surveillanceTheme.FONT_SMALL,true);fitCurrentTextSize(label,surveillanceTheme.FONT_SMALL,8,r.w-12,r.h-8);text(label,r.x+r.w/2,r.y+r.h/2);textAlign(LEFT,BASELINE);}
  void drawChip(float x,float y,float w,float h,String label,boolean active){noStroke();fill(active?surveillanceTheme.SURFACE_RAISED:surveillanceTheme.SURFACE_ALT);rect(x,y,w,h,h/2);fill(active?surveillanceTheme.ACCENT:surveillanceTheme.MUTED);textAlign(CENTER,CENTER);surveillanceText(surveillanceTheme.FONT_TINY,true);fitCurrentTextSize(label,surveillanceTheme.FONT_TINY,7,w-10,h-6);text(ellipsizeToWidth(label,w-10),x+w/2,y+h/2);textAlign(LEFT,BASELINE);}
  void handleMouse(float mx,float my){if(armButton.hit(mx,my))toggleArmed();else if(recordButton.hit(mx,my)&&!survRecording)manualRecord();else if(stopButton.hit(mx,my)&&survRecording)stopMotionRecording(false);}
  void card(float x,float y,float w,float h){stroke(surveillanceTheme.BORDER);strokeWeight(1);fill(surveillanceTheme.SURFACE);rect(x,y,w,h,surveillanceTheme.RADIUS);noStroke();}
  void cardTitle(float x,float y,float w,String s){fill(surveillanceTheme.TEXT);surveillanceText(surveillanceTheme.FONT_SMALL,true);textAlign(survI18n.startAlign(),CENTER);fitCurrentTextSize(s,surveillanceTheme.FONT_SMALL,8,w-28,surveillanceTheme.CARD_TITLE_H-8);text(s,survI18n.rtl?x+w-14:x+14,y+surveillanceTheme.CARD_TITLE_H/2);textAlign(LEFT,BASELINE);}
  String ellipsize(String s,int n){if(s==null)return "";return s.length()<=n?s:s.substring(0,max(0,n-1))+"…";}
}
class UiRect{float x,y,w,h;void set(float x,float y,float w,float h){this.x=x;this.y=y;this.w=w;this.h=h;}boolean hit(float px,float py){return px>=x&&px<=x+w&&py>=y&&py<=y+h;}}

// ===== SynKinect Studio / Interactivity =====
// V1 contract: Scanner and Interactivity consume one canonical RGB + metric-Depth
// acquisition/synchronization/calibration instance. IR is never used by Interactivity.
// The UI consumes immutable snapshots; the 3D tracker runs on its own latest-frame worker.
InteractionConfig interactionConfig;
InteractionI18n interactionI18n;
InteractionFrameProcessor interactionProcessor;
InteractionTracker3D interactionTracker;
InteractionRuntime interactionRuntime;
InteractionDesktopController interactionDesktop;
InteractionOrbCloud interactionCloud;
InteractionUI interactionUi;
PImage interactionRgbImage;
InteractionSkeleton3D interactionSkeleton;
long interactionLastProcessedFrame=-1;
volatile boolean interactionControlEnabled=false;
volatile String interactionStatus="";

void setupInteractivityModule(){
  interactionConfig=new InteractionConfig();interactionConfig.load(new File(dataPath("interaction.properties")));
  interactionI18n=new InteractionI18n(studio.currentLanguage());
  ensureSharedRgbdCore();
  interactionTracker=new InteractionTracker3D(interactionConfig,config,calibration,rgbRegistration);
  interactionProcessor=new InteractionFrameProcessor(interactionConfig,interactionTracker);
  interactionDesktop=new InteractionDesktopController(interactionConfig);
  interactionCloud=new InteractionOrbCloud(interactionConfig);
  interactionRuntime=new InteractionRuntime(interactionConfig,kinectSource,interactionProcessor);
  interactionUi=new InteractionUI();interactionStatus=interactionI18n.tr("status.ready");
}
void activateInteractivityModule(){interactionLastProcessedFrame=-1;interactionSkeleton=null;interactionRgbImage=null;if(interactionTracker!=null)interactionTracker.reset();if(interactionRuntime!=null)interactionRuntime.start();}
void deactivateInteractivityModule(){interactionControlEnabled=false;if(interactionDesktop!=null)interactionDesktop.setEnabled(false);if(interactionCloud!=null)interactionCloud.reset();if(interactionRuntime!=null)interactionRuntime.stop(studio.transitionTarget==STUDIO_TAB_SCANNER);}
void disposeInteractivityModule(){deactivateInteractivityModule();}
void drawInteractivityModule(){background(acousticTheme.BG);serviceInteractivityFrames();if(interactionCloud!=null)interactionCloud.update(interactionSkeleton);if(interactionUi!=null)interactionUi.draw();}

// UI thread: immutable snapshots only. No transport or CV work executes here.
void serviceInteractivityFrames(){
  InteractionProcessedFrame p=interactionProcessor==null?null:interactionProcessor.latest();
  if(p!=null&&p.frameNumber!=interactionLastProcessedFrame){interactionLastProcessedFrame=p.frameNumber;interactionSkeleton=p.skeleton;applyInteractionRgbPreview(p.previewPixels);}
  if(interactionDesktop!=null){interactionDesktop.setEnabled(interactionControlEnabled);if(interactionControlEnabled&&interactionSkeleton!=null&&interactionSkeleton.tracked)interactionDesktop.update(interactionSkeleton);}
}
void applyInteractionRgbPreview(int[] pixels){if(pixels==null||pixels.length!=scannerProtocol.WIDTH*scannerProtocol.HEIGHT)return;if(interactionRgbImage==null)interactionRgbImage=createImage(scannerProtocol.WIDTH,scannerProtocol.HEIGHT,RGB);interactionRgbImage.loadPixels();System.arraycopy(pixels,0,interactionRgbImage.pixels,0,pixels.length);interactionRgbImage.updatePixels();}
boolean interaction3dLive(){if(interactionLastProcessedFrame>=0&&interactionProcessor!=null&&millis64()-interactionProcessor.lastPublishedMs<=interactionConfig.streamStaleMs)return true;return interactionRuntime!=null&&interactionRuntime.streamsLive();}
void interactivityMousePressed(){if(interactionUi!=null)interactionUi.handleMouse(studio.contentMouseX(),studio.contentMouseY());}
void interactivityKeyPressed(){if(key=='e'||key=='E')toggleInteractionControl();}
void toggleInteractionControl(){if(!interactionControlEnabled&&(interactionDesktop==null||!interactionDesktop.available())){interactionControlEnabled=false;interactionStatus=interactionI18n.tr("status.desktop_unavailable");return;}interactionControlEnabled=!interactionControlEnabled;if(interactionDesktop!=null)interactionDesktop.setEnabled(interactionControlEnabled);interactionStatus=interactionI18n.tr(interactionControlEnabled?"status.control_on":"status.control_off");}
void cycleInteractionHand(){if(interactionDesktop!=null)interactionDesktop.cycleHand();}

class InteractionConfig {
  int workerJoinMs=2200,streamStaleMs=1800;
  int sampleStep=2,previewHz=15,minDepthMm=550,maxDepthMm=3800,minClusterSamples=90,componentDepthToleranceMm=210,minPersonWidthPx=42,minPersonHeightPx=92;
  float maxPersonFrameCoverage=0.82f,minSkeletonConfidence=0.24f,skeletonSmoothing=0.30f;
  int rgbRefineRadiusPx=12,rgbHandRefineRadiusPx=18,depthJointRadiusPx=7;float rgbEdgeWeight=0.44f;
  int handHoldFrames=3,fingerAngularBins=96,maxFingerCount=5;float handTemporalBiasPx=62,palmRadiusMinPx=9,palmRadiusMaxPx=38,fingerMinReach=1.30f,fingerMinSeparationDeg=16,handPoseSmoothing=0.34f;
  boolean mirrorX=true;String hand="right";int cursorMaxHz=60,cursorLostReleaseMs=800;float cursorDeadzonePx=1.8f,cursorFastAlpha=0.62f,cursorSlowAlpha=0.20f,cursorFastDistancePx=42;
  float volumeHalfWidthM=0.55f,volumeTopM=0.42f,volumeBottomM=0.48f,minHandForwardM=0.03f;
  float handOpenThreshold=0.62f,handCloseThreshold=0.38f,handOpennessSmoothing=0.28f;int gestureStableMs=120,gestureDragHoldMs=430,gestureReleaseMs=100,twoHandStableMs=180,doubleClickStableMs=170,doubleClickCooldownMs=700,scrollCooldownMs=45;float scrollThresholdM=0.018f,scrollGainPerM=82.0f;
  int cloudParticles=300,cloudTrailSamples=22;float cloudRadiusPx=24,cloudSpring=42,cloudDamping=7,cloudFlow=0.24f,cloudTrailStrength=1,cloudStretchGain=0.020f,cloudMaxStretch=3;boolean desktopOverlay=true;
  void load(File file){Properties p=loadStudioProperties(file);workerJoinMs=ival(p,"transport.workerJoinMs",workerJoinMs);streamStaleMs=ival(p,"transport.streamStaleMs",streamStaleMs);
    sampleStep=max(1,min(4,ival(p,"vision.sampleStep",sampleStep)));previewHz=max(1,min(30,ival(p,"vision.previewHz",previewHz)));minDepthMm=ival(p,"vision.minDepthMm",minDepthMm);maxDepthMm=ival(p,"vision.maxDepthMm",maxDepthMm);minClusterSamples=max(20,ival(p,"vision.minClusterSamples",minClusterSamples));componentDepthToleranceMm=ival(p,"vision.componentDepthToleranceMm",componentDepthToleranceMm);minPersonWidthPx=ival(p,"vision.minPersonWidthPx",minPersonWidthPx);minPersonHeightPx=ival(p,"vision.minPersonHeightPx",minPersonHeightPx);maxPersonFrameCoverage=fval(p,"vision.maxPersonFrameCoverage",maxPersonFrameCoverage);minSkeletonConfidence=fval(p,"vision.minConfidence",minSkeletonConfidence);skeletonSmoothing=fval(p,"vision.smoothing",skeletonSmoothing);
    rgbRefineRadiusPx=ival(p,"fusion.rgbRefineRadiusPx",rgbRefineRadiusPx);rgbHandRefineRadiusPx=ival(p,"fusion.rgbHandRefineRadiusPx",rgbHandRefineRadiusPx);depthJointRadiusPx=ival(p,"fusion.depthJointRadiusPx",depthJointRadiusPx);rgbEdgeWeight=fval(p,"fusion.rgbEdgeWeight",rgbEdgeWeight);
    handHoldFrames=max(0,min(8,ival(p,"hand.holdFrames",handHoldFrames)));handTemporalBiasPx=fval(p,"hand.temporalBiasPx",handTemporalBiasPx);fingerAngularBins=max(48,min(180,ival(p,"hand.fingerAngularBins",fingerAngularBins)));maxFingerCount=max(1,min(5,ival(p,"hand.maxFingerCount",maxFingerCount)));palmRadiusMinPx=fval(p,"hand.palmRadiusMinPx",palmRadiusMinPx);palmRadiusMaxPx=fval(p,"hand.palmRadiusMaxPx",palmRadiusMaxPx);fingerMinReach=fval(p,"hand.fingerMinReach",fingerMinReach);fingerMinSeparationDeg=fval(p,"hand.fingerMinSeparationDeg",fingerMinSeparationDeg);handPoseSmoothing=fval(p,"hand.poseSmoothing",handPoseSmoothing);
    mirrorX=bval(p,"cursor.mirrorX",mirrorX);hand=text(p,"cursor.hand",hand).toLowerCase(Locale.ROOT);cursorMaxHz=ival(p,"cursor.maxHz",cursorMaxHz);cursorLostReleaseMs=ival(p,"cursor.lostReleaseMs",cursorLostReleaseMs);cursorDeadzonePx=fval(p,"cursor.deadzonePx",cursorDeadzonePx);cursorSlowAlpha=fval(p,"cursor.slowAlpha",cursorSlowAlpha);cursorFastAlpha=fval(p,"cursor.fastAlpha",cursorFastAlpha);cursorFastDistancePx=fval(p,"cursor.fastDistancePx",cursorFastDistancePx);volumeHalfWidthM=fval(p,"cursor.volumeHalfWidthM",volumeHalfWidthM);volumeTopM=fval(p,"cursor.volumeTopM",volumeTopM);volumeBottomM=fval(p,"cursor.volumeBottomM",volumeBottomM);minHandForwardM=fval(p,"cursor.minHandForwardM",minHandForwardM);
    handOpenThreshold=fval(p,"gesture.openThreshold",handOpenThreshold);handCloseThreshold=fval(p,"gesture.closeThreshold",handCloseThreshold);handOpennessSmoothing=fval(p,"gesture.opennessSmoothing",handOpennessSmoothing);twoHandStableMs=ival(p,"gesture.twoHandStableMs",twoHandStableMs);doubleClickStableMs=ival(p,"gesture.doubleClickStableMs",doubleClickStableMs);doubleClickCooldownMs=ival(p,"gesture.doubleClickCooldownMs",doubleClickCooldownMs);scrollCooldownMs=ival(p,"gesture.scrollCooldownMs",scrollCooldownMs);scrollThresholdM=fval(p,"gesture.scrollThresholdM",scrollThresholdM);scrollGainPerM=fval(p,"gesture.scrollGainPerM",scrollGainPerM);
    cloudParticles=max(80,min(700,ival(p,"cloud.particles",cloudParticles)));cloudTrailSamples=max(6,min(48,ival(p,"cloud.trailSamples",cloudTrailSamples)));cloudRadiusPx=fval(p,"cloud.radiusPx",cloudRadiusPx);cloudSpring=fval(p,"cloud.spring",cloudSpring);cloudDamping=fval(p,"cloud.damping",cloudDamping);cloudFlow=fval(p,"cloud.flow",cloudFlow);cloudTrailStrength=fval(p,"cloud.trailStrength",cloudTrailStrength);cloudStretchGain=fval(p,"cloud.stretchGain",cloudStretchGain);cloudMaxStretch=fval(p,"cloud.maxStretch",cloudMaxStretch);desktopOverlay=bval(p,"cloud.desktopOverlay",desktopOverlay);}
  int ival(Properties p,String k,int d){try{return Integer.parseInt(text(p,k,String.valueOf(d)));}catch(Exception e){return d;}}float fval(Properties p,String k,float d){try{return Float.parseFloat(text(p,k,String.valueOf(d)));}catch(Exception e){return d;}}boolean bval(Properties p,String k,boolean d){String v=p.getProperty(k);return v==null?d:Boolean.parseBoolean(v.trim());}String text(Properties p,String k,String d){String v=p.getProperty(k);return v==null||v.trim().length()==0?d:v.trim();}
}
class InteractionI18n extends ModuleI18n {InteractionI18n(String requested){super("interaction",requested);}}

class InteractionVisionSnapshot {final RgbdFramePair pair;final byte[] rgbPayload;final DepthFrame depthFrame;final long rgbFrameNumber,depthFrameNumber,rgbTickMs,depthTickMs,sequence;final float syncResidualMs;InteractionVisionSnapshot(RgbdFramePair p){pair=p;rgbPayload=p.rgb.nv12;depthFrame=p.depth;rgbFrameNumber=p.rgb.frameNumber;depthFrameNumber=p.depth.frameNumber;rgbTickMs=p.rgb.timestampUs/1000L;depthTickMs=p.depth.timestampUs/1000L;sequence=p.sequence;syncResidualMs=p.residualUs/1000.0f;}long key(){return sequence;}}
class InteractionProcessedFrame {long frameNumber=-1,tickMs=0;int[] previewPixels;InteractionSkeleton3D skeleton;}

class InteractionFrameProcessor {
  final InteractionConfig cfg;final InteractionTracker3D tracker;final Object lock=new Object();volatile boolean running=false;volatile InteractionProcessedFrame published=null;volatile long lastPublishedMs=0;long lastPreviewMs=0;Thread worker;InteractionVisionSnapshot pending=null;
  InteractionFrameProcessor(InteractionConfig cfg,InteractionTracker3D tracker){this.cfg=cfg;this.tracker=tracker;}
  void start(){synchronized(lock){if(running)return;running=true;pending=null;published=null;worker=new Thread(new Runnable(){public void run(){loop();}},"SynKinectStudio-Interaction-3D-Fusion");worker.setDaemon(true);worker.start();}}
  void stop(){Thread t;synchronized(lock){running=false;pending=null;lock.notifyAll();t=worker;worker=null;}if(t!=null&&t!=Thread.currentThread()){t.interrupt();try{t.join(min(1000,cfg.workerJoinMs));}catch(InterruptedException e){Thread.currentThread().interrupt();}}}
  void submit(InteractionVisionSnapshot f){if(f==null||f.rgbPayload==null||f.depthFrame==null)return;synchronized(lock){if(!running)return;pending=f;lock.notifyAll();}}
  InteractionProcessedFrame latest(){return published;}
  void loop(){while(true){InteractionVisionSnapshot f;synchronized(lock){while(running&&pending==null)try{lock.wait();}catch(InterruptedException e){if(!running)return;}if(!running)return;f=pending;pending=null;}try{InteractionProcessedFrame out=new InteractionProcessedFrame();out.frameNumber=f.key();out.tickMs=Math.max(f.rgbTickMs,f.depthTickMs);out.skeleton=tracker.track(f);long now=millis64();if(lastPreviewMs==0||now-lastPreviewMs>=1000/max(1,cfg.previewHz)){out.previewPixels=rgbPreview(f.rgbPayload);lastPreviewMs=now;}published=out;lastPublishedMs=now;}catch(Throwable e){println("Interactivity 3D processor warning: "+safeStudioMessage(e));}}}
  int[] rgbPreview(byte[] d){int w=scannerProtocol.WIDTH,h=scannerProtocol.HEIGHT;if(d==null||d.length!=scannerProtocol.RGB_BYTES)return null;int[] out=new int[w*h];int ys=w*h;for(int y=0;y<h;y++)for(int x=0;x<w;x++){int Y=d[y*w+x]&255,uv=ys+(y/2)*w+(x&~1),U=(d[uv]&255)-128,V=(d[uv+1]&255)-128,c=max(0,Y-16),r=(298*c+409*V+128)>>8,g=(298*c-100*U-208*V+128)>>8,b=(298*c+516*U+128)>>8;out[y*w+x]=0xFF000000|(constrain(r,0,255)<<16)|(constrain(g,0,255)<<8)|constrain(b,0,255);}return out;}
}

class InteractionRuntime {
  final InteractionConfig cfg;final KinectSource source;final InteractionFrameProcessor processor;final Object lock=new Object();volatile boolean running=false;volatile long lastInputMs=0;Thread connectionWorker;long lastSubmitted=-1;
  InteractionRuntime(InteractionConfig c,KinectSource s,InteractionFrameProcessor p){cfg=c;source=s;processor=p;}
  void start(){synchronized(lock){if(running)return;running=true;lastInputMs=millis64();lastSubmitted=-1;source.start();processor.start();connectionWorker=new Thread(new Runnable(){public void run(){connectionLoop();}},"SynKinectStudio-Interaction-Shared-RGBD");connectionWorker.setDaemon(true);connectionWorker.start();}}
  void stop(boolean keepRgbd){Thread t;synchronized(lock){running=false;t=connectionWorker;connectionWorker=null;}if(t!=null&&t!=Thread.currentThread()){t.interrupt();try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}}processor.stop();if(!keepRgbd)source.stop(true);else source.clearConsumerPairs();}
  boolean streamsLive(){source.updateLiveness();long now=millis64();return source.running&&source.colorConnected&&source.depthConnected&&source.lastPairedArrivalMs>0&&now-source.lastPairedArrivalMs<=cfg.streamStaleMs;}
  void connectionLoop(){while(running){try{source.updateLiveness();RgbdFramePair pair=source.latestRgbdPairAfter(lastSubmitted);if(pair!=null){lastSubmitted=pair.sequence;lastInputMs=millis64();processor.submit(new InteractionVisionSnapshot(pair));}Thread.sleep(2);}catch(InterruptedException e){if(!running)return;Thread.currentThread().interrupt();return;}catch(Throwable e){if(running)println("Interactivity shared RGBD warning: "+safeStudioMessage(e));}}}
}

class InteractionJoint3D {
  final String name;PVector image=new PVector(),world=new PVector();float confidence=0;int state=0; // 0 lost, 1 inferred, 2 tracked
  InteractionJoint3D(String n){name=n;}InteractionJoint3D set(PVector uv,PVector xyz,float q,int s){if(uv!=null)image.set(uv);if(xyz!=null)world.set(xyz);confidence=q;state=s;return this;}boolean tracked(){return state>0&&confidence>0;}
}
class InteractionFinger3D {final String name;InteractionJoint3D base,tip;float confidence=0;InteractionFinger3D(String n){name=n;base=new InteractionJoint3D(n+"_base");tip=new InteractionJoint3D(n+"_tip");}}
class InteractionHandPose3D {boolean tracked=false;InteractionJoint3D wrist=new InteractionJoint3D("wrist"),palm=new InteractionJoint3D("palm");InteractionFinger3D[] fingers={new InteractionFinger3D("thumb"),new InteractionFinger3D("index"),new InteractionFinger3D("middle"),new InteractionFinger3D("ring"),new InteractionFinger3D("pinky")};int fingerCount=0;float palmRadiusPx=0,openness=0.5f,grabStrength=0.5f,pinchStrength=0,confidence=0;}
class InteractionSkeleton3D {
  boolean tracked=false;float confidence=0;String reason="searching";int minX,minY,maxX,maxY,samples=0;float meanDepthM=0,faceWidthPx=0,faceHeightPx=0;
  InteractionJoint3D head=new InteractionJoint3D("head"),neck=new InteractionJoint3D("neck"),chest=new InteractionJoint3D("chest"),spine=new InteractionJoint3D("spine"),pelvis=new InteractionJoint3D("pelvis");
  InteractionJoint3D leftShoulder=new InteractionJoint3D("left_shoulder"),rightShoulder=new InteractionJoint3D("right_shoulder"),leftElbow=new InteractionJoint3D("left_elbow"),rightElbow=new InteractionJoint3D("right_elbow"),leftWrist=new InteractionJoint3D("left_wrist"),rightWrist=new InteractionJoint3D("right_wrist"),leftHand=new InteractionJoint3D("left_hand"),rightHand=new InteractionJoint3D("right_hand");
  InteractionJoint3D leftHip=new InteractionJoint3D("left_hip"),rightHip=new InteractionJoint3D("right_hip"),leftKnee=new InteractionJoint3D("left_knee"),rightKnee=new InteractionJoint3D("right_knee"),leftAnkle=new InteractionJoint3D("left_ankle"),rightAnkle=new InteractionJoint3D("right_ankle"),leftFoot=new InteractionJoint3D("left_foot"),rightFoot=new InteractionJoint3D("right_foot");
  InteractionHandPose3D leftPose=new InteractionHandPose3D(),rightPose=new InteractionHandPose3D();float leftOpenness=0.5f,rightOpenness=0.5f;
  boolean faceTracked(){return head.tracked();}boolean torsoTracked(){return chest.tracked()&&pelvis.tracked();}boolean leftArmTracked(){return leftShoulder.tracked()&&leftElbow.tracked()&&leftHand.tracked();}boolean rightArmTracked(){return rightShoulder.tracked()&&rightElbow.tracked()&&rightHand.tracked();}boolean leftHandTracked(){return leftHand.tracked();}boolean rightHandTracked(){return rightHand.tracked();}
  PVector bodyCenterImage(){return chest.image;}InteractionJoint3D activeHand(String mode){if("left".equals(mode)&&leftHandTracked())return leftHand;if("right".equals(mode)&&rightHandTracked())return rightHand;if(rightHandTracked())return rightHand;if(leftHandTracked())return leftHand;return null;}
}
class InteractionComponent {int id,count,minGX=Integer.MAX_VALUE,minGY=Integer.MAX_VALUE,maxGX=-1,maxGY=-1;long sumX=0,sumY=0,sumDepth=0;float score=0;}

class InteractionCalibration3D {
  final AppConfig sharedCfg;final Calibration sharedCalibration;final RgbDepthRegistration sharedRegistration;
  InteractionCalibration3D(AppConfig c,Calibration cal,RgbDepthRegistration reg){sharedCfg=c;sharedCalibration=cal;sharedRegistration=reg;}
  PVector deproject(int u,int v,int mm){int uu=constrain(u,0,scannerProtocol.WIDTH-1),vv=constrain(v,0,scannerProtocol.HEIGHT-1),i=vv*scannerProtocol.WIDTH+uu;float z=mm*sharedCalibration.depthScale;return new PVector(sharedRegistration.pointX(i,z),sharedRegistration.pointY(i,z),z);}
  PVector projectRgb(int u,int v,int mm){int uu=constrain(u,0,scannerProtocol.WIDTH-1),vv=constrain(v,0,scannerProtocol.HEIGHT-1),i=vv*scannerProtocol.WIDTH+uu;float z=mm*sharedCalibration.depthScale;RgbProjection q=new RgbProjection();sharedRegistration.project(i,z,q,0,0);return q.valid?new PVector(q.u,q.v):null;}
}

class InteractionTracker3D {
  final InteractionConfig cfg;final AppConfig sharedCfg;final InteractionCalibration3D cal;InteractionSkeleton3D previous;int[] fullDepth,gridDepth,labels,queue;byte[] rgbY;volatile int candidateCount=0,selectedSamples=0;volatile String lastReason="searching";int leftMissing=0,rightMissing=0;
  InteractionTracker3D(InteractionConfig c,AppConfig sc,Calibration calibration,RgbDepthRegistration registration){cfg=c;sharedCfg=sc;cal=new InteractionCalibration3D(sc,calibration,registration);}void reset(){previous=null;fullDepth=null;gridDepth=null;labels=null;queue=null;rgbY=null;leftMissing=rightMissing=0;lastReason="searching";}
  InteractionSkeleton3D track(InteractionVisionSnapshot f){InteractionSkeleton3D out=new InteractionSkeleton3D();if(f==null||f.depthFrame==null||f.depthFrame.depth==null||f.rgbPayload==null){lastReason=out.reason="no_rgbd";return out;}final int w=scannerProtocol.WIDTH,h=scannerProtocol.HEIGHT,step=cfg.sampleStep,gw=(w+step-1)/step,gh=(h+step-1)/step,n=gw*gh;if(fullDepth==null||fullDepth.length!=w*h){fullDepth=new int[w*h];rgbY=new byte[w*h];}if(gridDepth==null||gridDepth.length!=n){gridDepth=new int[n];labels=new int[n];queue=new int[n];}
    for(int i=0;i<w*h;i++)fullDepth[i]=f.depthFrame.depth[i]&0xffff;System.arraycopy(f.rgbPayload,0,rgbY,0,w*h);Arrays.fill(labels,-1);for(int gy=0;gy<gh;gy++){int y=min(h-1,gy*step);for(int gx=0;gx<gw;gx++){int x=min(w-1,gx*step),d=fullDepth[y*w+x];gridDepth[gy*gw+gx]=(d>=cfg.minDepthMm&&d<=cfg.maxDepthMm)?d:0;}}
    ArrayList<InteractionComponent> comps=components(gw,gh);candidateCount=comps.size();InteractionComponent chosen=choosePerson(comps,w,h,step);if(chosen==null){selectedSamples=0;lastReason=out.reason=candidateCount==0?"no_component":"no_person";return out;}selectedSamples=chosen.count;int minX=chosen.minGX*step,maxX=min(w-1,chosen.maxGX*step),minY=chosen.minGY*step,maxY=min(h-1,chosen.maxGY*step);float bw=maxX-minX,bh=maxY-minY,cx=(minX+maxX)*0.5f;out.minX=minX;out.maxX=maxX;out.minY=minY;out.maxY=maxY;out.samples=chosen.count;out.meanDepthM=(chosen.sumDepth/(float)chosen.count)*sharedCfg.depthScale;
    PVector head2=centroidBand(chosen.id,gw,gh,step,minX,maxX,minY,minY+round(bh*0.20f),cx,bw*0.22f);if(head2==null)head2=new PVector(cx,minY+bh*0.11f);float shoulderY=minY+bh*0.27f;PVector[] sh=shoulders(chosen.id,gw,gh,step,cx,shoulderY,max(16,bw*0.23f));PVector neck2=new PVector((sh[0].x+sh[1].x)*0.5f,shoulderY-5),chest2=new PVector(cx,minY+bh*0.43f),spine2=new PVector(cx,minY+bh*0.54f),pelvis2=new PVector(cx,minY+bh*0.64f);
    PVector priorL=previous!=null&&previous.leftHandTracked()?previous.leftHand.image:null,priorR=previous!=null&&previous.rightHandTracked()?previous.rightHand.image:null;PVector lh=findHand(chosen.id,gw,gh,step,chest2,sh[0],true,minX,minY,maxX,maxY,priorL),rh=findHand(chosen.id,gw,gh,step,chest2,sh[1],false,minX,minY,maxX,maxY,priorR);if(lh==null&&priorL!=null&&leftMissing<cfg.handHoldFrames){lh=priorL.copy();leftMissing++;}else if(lh!=null)leftMissing=0;else leftMissing++;if(rh==null&&priorR!=null&&rightMissing<cfg.handHoldFrames){rh=priorR.copy();rightMissing++;}else if(rh!=null)rightMissing=0;else rightMissing++;
    PVector le=lh==null?new PVector(minX+0.12f*bw,minY+0.46f*bh):estimateElbow(chosen.id,gw,gh,step,sh[0],lh,chest2),re=rh==null?new PVector(maxX-0.12f*bw,minY+0.46f*bh):estimateElbow(chosen.id,gw,gh,step,sh[1],rh,chest2);PVector lw=lh==null?PVector.lerp(le,sh[0],0.3f):PVector.lerp(le,lh,0.72f),rw=rh==null?PVector.lerp(re,sh[1],0.3f):PVector.lerp(re,rh,0.72f);
    float hipHalf=max(12,bw*0.12f);PVector lhip=bandPoint(chosen.id,gw,gh,step,minY+bh*0.66f,cx-hipHalf,true),rhip=bandPoint(chosen.id,gw,gh,step,minY+bh*0.66f,cx+hipHalf,false);PVector lknee=lowerJoint(chosen.id,gw,gh,step,minY+bh*0.82f,lhip.x,true),rknee=lowerJoint(chosen.id,gw,gh,step,minY+bh*0.82f,rhip.x,false);PVector lankle=lowerJoint(chosen.id,gw,gh,step,minY+bh*0.95f,lknee.x,true),rankle=lowerJoint(chosen.id,gw,gh,step,minY+bh*0.95f,rknee.x,false);PVector lfoot=new PVector(max(minX,lankle.x-bw*0.035f),min(maxY,lankle.y+bh*0.025f)),rfoot=new PVector(min(maxX,rankle.x+bw*0.035f),min(maxY,rankle.y+bh*0.025f));
    out.head=makeJoint("head",head2,chosen.id,cfg.rgbRefineRadiusPx,0.82f);out.neck=makeJoint("neck",neck2,chosen.id,cfg.rgbRefineRadiusPx,0.82f);out.chest=makeJoint("chest",chest2,chosen.id,cfg.rgbRefineRadiusPx,0.90f);out.spine=makeJoint("spine",spine2,chosen.id,8,0.92f);out.pelvis=makeJoint("pelvis",pelvis2,chosen.id,8,0.92f);out.leftShoulder=makeJoint("left_shoulder",sh[0],chosen.id,cfg.rgbRefineRadiusPx,0.84f);out.rightShoulder=makeJoint("right_shoulder",sh[1],chosen.id,cfg.rgbRefineRadiusPx,0.84f);out.leftElbow=makeJoint("left_elbow",le,chosen.id,cfg.rgbRefineRadiusPx,lh==null?0.42f:0.76f);out.rightElbow=makeJoint("right_elbow",re,chosen.id,cfg.rgbRefineRadiusPx,rh==null?0.42f:0.76f);out.leftWrist=makeJoint("left_wrist",lw,chosen.id,cfg.rgbHandRefineRadiusPx,lh==null?0.35f:0.75f);out.rightWrist=makeJoint("right_wrist",rw,chosen.id,cfg.rgbHandRefineRadiusPx,rh==null?0.35f:0.75f);out.leftHand=makeJoint("left_hand",lh==null?lw:lh,chosen.id,cfg.rgbHandRefineRadiusPx,lh==null?0.30f:0.78f);out.rightHand=makeJoint("right_hand",rh==null?rw:rh,chosen.id,cfg.rgbHandRefineRadiusPx,rh==null?0.30f:0.78f);out.leftHip=makeJoint("left_hip",lhip,chosen.id,8,0.72f);out.rightHip=makeJoint("right_hip",rhip,chosen.id,8,0.72f);out.leftKnee=makeJoint("left_knee",lknee,chosen.id,8,0.64f);out.rightKnee=makeJoint("right_knee",rknee,chosen.id,8,0.64f);out.leftAnkle=makeJoint("left_ankle",lankle,chosen.id,8,0.56f);out.rightAnkle=makeJoint("right_ankle",rankle,chosen.id,8,0.56f);out.leftFoot=makeJoint("left_foot",lfoot,chosen.id,6,0.46f);out.rightFoot=makeJoint("right_foot",rfoot,chosen.id,6,0.46f);out.faceWidthPx=max(18,bw*0.20f);out.faceHeightPx=out.faceWidthPx*1.20f;
    if(out.leftHand.tracked()){out.leftPose=handPose(chosen.id,gw,gh,step,out.leftElbow,out.leftWrist,out.leftHand,true,previous==null?null:previous.leftPose);out.leftOpenness=out.leftPose.openness;}if(out.rightHand.tracked()){out.rightPose=handPose(chosen.id,gw,gh,step,out.rightElbow,out.rightWrist,out.rightHand,false,previous==null?null:previous.rightPose);out.rightOpenness=out.rightPose.openness;}
    kinematicConfidence(out);smooth(out);float joints=jointScore(out);out.confidence=constrain(0.34f*componentConfidence(chosen)+0.66f*joints,0,1);out.tracked=out.confidence>=cfg.minSkeletonConfidence&&out.chest.tracked()&&out.pelvis.tracked();out.reason=out.tracked?"tracked":"low_confidence";if(out.tracked)previous=out;lastReason=out.reason;return out;
  }
  ArrayList<InteractionComponent> components(int gw,int gh){ArrayList<InteractionComponent> out=new ArrayList<InteractionComponent>();int id=0;for(int seed=0;seed<gridDepth.length;seed++){if(gridDepth[seed]==0||labels[seed]>=0)continue;InteractionComponent c=new InteractionComponent();c.id=id++;int head=0,tail=0;queue[tail++]=seed;labels[seed]=c.id;while(head<tail){int idx=queue[head++],gx=idx%gw,gy=idx/gw,d=gridDepth[idx];c.count++;c.minGX=min(c.minGX,gx);c.maxGX=max(c.maxGX,gx);c.minGY=min(c.minGY,gy);c.maxGY=max(c.maxGY,gy);c.sumX+=gx;c.sumY+=gy;c.sumDepth+=d;if(gx>0)tail=enq(idx-1,d,c.id,tail);if(gx+1<gw)tail=enq(idx+1,d,c.id,tail);if(gy>0)tail=enq(idx-gw,d,c.id,tail);if(gy+1<gh)tail=enq(idx+gw,d,c.id,tail);}if(c.count>=cfg.minClusterSamples)out.add(c);}return out;}
  int enq(int idx,int from,int id,int tail){int d=gridDepth[idx];if(d==0||labels[idx]>=0||abs(d-from)>cfg.componentDepthToleranceMm)return tail;labels[idx]=id;queue[tail++]=idx;return tail;}
  InteractionComponent choosePerson(ArrayList<InteractionComponent> cs,int w,int h,int step){InteractionComponent best=null;float bs=-1;for(InteractionComponent c:cs){float minX=c.minGX*step,maxX=c.maxGX*step,minY=c.minGY*step,maxY=c.maxGY*step,bw=maxX-minX,bh=maxY-minY,cov=bw*bh/(w*h);if(bw<cfg.minPersonWidthPx||bh<cfg.minPersonHeightPx||cov>cfg.maxPersonFrameCoverage)continue;float cx=(c.sumX/(float)c.count)*step,cy=(c.sumY/(float)c.count)*step,center=1-constrain(abs(cx-w*.5f)/(w*.5f),0,1),height=constrain(bh/(h*.62f),.25f,1),near=1-constrain(((c.sumDepth/(float)c.count)-cfg.minDepthMm)/max(1f,cfg.maxDepthMm-cfg.minDepthMm),0,1)*.25f,cont=0;if(previous!=null&&previous.tracked){float px=(previous.minX+previous.maxX)*.5f,py=(previous.minY+previous.maxY)*.5f;cont=1-constrain(dist(cx,cy,px,py)/240f,0,1);}c.score=c.count*(.46f+.20f*center+.22f*cont+.12f*near)*height;if(c.score>bs){bs=c.score;best=c;}}return best;}
  boolean belongs(int x,int y,int id,int step,int gw,int gh){int gx=constrain(x/step,0,gw-1),gy=constrain(y/step,0,gh-1);return labels[gy*gw+gx]==id;}
  PVector centroidBand(int id,int gw,int gh,int step,int minX,int maxX,int minY,int maxY,float cx,float half){float sx=0,sy=0;int n=0;for(int y=max(0,minY);y<=min(scannerProtocol.HEIGHT-1,maxY);y+=step)for(int x=max(minX,round(cx-half));x<=min(maxX,round(cx+half));x+=step)if(belongs(x,y,id,step,gw,gh)){sx+=x;sy+=y;n++;}return n>0?new PVector(sx/n,sy/n):null;}
  PVector[] shoulders(int id,int gw,int gh,int step,float cx,float y,float fallback){float l=cx-fallback,r=cx+fallback;for(int yy=round(y-12);yy<=round(y+12);yy+=step)for(int x=0;x<scannerProtocol.WIDTH;x+=step)if(belongs(x,yy,id,step,gw,gh)){if(x<cx)l=min(l,x);else r=max(r,x);}return new PVector[]{new PVector(lerp(cx-fallback,l,.55f),y),new PVector(lerp(cx+fallback,r,.55f),y)};}
  float handScore(float x,float y,PVector body,PVector shoulder,boolean left,int minX,int minY,int maxX,int maxY,PVector prior){if(y>minY+(maxY-minY)*.93f)return -1e9f;if(left&&x>=body.x-3)return -1e9f;if(!left&&x<=body.x+3)return -1e9f;float lat=left?body.x-x:x-body.x;if(lat<max(8,(maxX-minX)*.07f))return -1e9f;float reach=dist(x,y,shoulder.x,shoulder.y),raise=max(0,body.y-y),temporal=prior==null?0:max(0,1-dist(x,y,prior.x,prior.y)/max(16,cfg.handTemporalBiasPx))*48;return reach+.90f*lat+.22f*raise+temporal;}
  PVector findHand(int id,int gw,int gh,int step,PVector body,PVector shoulder,boolean left,int minX,int minY,int maxX,int maxY,PVector prior){float best=-1e9f;PVector p=null;for(int y=minY;y<=maxY;y+=step)for(int x=minX;x<=maxX;x+=step)if(belongs(x,y,id,step,gw,gh)){float q=handScore(x,y,body,shoulder,left,minX,minY,maxX,maxY,prior);if(q>best){best=q;p=new PVector(x,y);}}return p;}
  PVector estimateElbow(int id,int gw,int gh,int step,PVector shoulder,PVector hand,PVector body){PVector axis=PVector.sub(hand,shoulder);float len=max(1,axis.mag());axis.div(len);PVector side=new PVector(-axis.y,axis.x);float sx=0,sy=0,sw=0,r=34;for(int y=constrain(floor(min(shoulder.y,hand.y)-r),0,scannerProtocol.HEIGHT-1);y<=constrain(ceil(max(shoulder.y,hand.y)+r),0,scannerProtocol.HEIGHT-1);y+=step)for(int x=constrain(floor(min(shoulder.x,hand.x)-r),0,scannerProtocol.WIDTH-1);x<=constrain(ceil(max(shoulder.x,hand.x)+r),0,scannerProtocol.WIDTH-1);x+=step)if(belongs(x,y,id,step,gw,gh)){float dx=x-shoulder.x,dy=y-shoulder.y,t=(dx*axis.x+dy*axis.y)/len,perp=abs(dx*side.x+dy*side.y);if(t<.30f||t>.72f||perp>r)continue;float q=(1-constrain(abs(t-.52f)/.22f,0,1))*(1-constrain(perp/r,0,1));sx+=x*q;sy+=y*q;sw+=q;}return sw>.01f?new PVector(sx/sw,sy/sw):PVector.lerp(shoulder,hand,.52f);}
  PVector bandPoint(int id,int gw,int gh,int step,float y,float guess,boolean left){float sx=0,sy=0,sw=0;for(int yy=round(y-10);yy<=round(y+10);yy+=step)for(int x=0;x<scannerProtocol.WIDTH;x+=step)if(belongs(x,yy,id,step,gw,gh)){if(left&&x>guess+55)continue;if(!left&&x<guess-55)continue;float q=1/(1+abs(x-guess));sx+=x*q;sy+=yy*q;sw+=q;}return sw>0?new PVector(sx/sw,sy/sw):new PVector(guess,y);}
  PVector lowerJoint(int id,int gw,int gh,int step,float y,float guess,boolean left){return bandPoint(id,gw,gh,step,y,guess,left);}
  InteractionJoint3D makeJoint(String name,PVector guess,int id,int refineRadius,float baseConf){InteractionJoint3D j=new InteractionJoint3D(name);if(guess==null)return j;PVector uv=refineRgb(guess,id,refineRadius);int mm=medianDepth(round(uv.x),round(uv.y),id,cfg.depthJointRadiusPx);if(mm<=0){int near=nearestDepth(round(uv.x),round(uv.y),id,18);if(near>0)mm=near;}if(mm<=0)return j;PVector xyz=cal.deproject(round(uv.x),round(uv.y),mm);float edge=edgeAtDepthPixel(round(uv.x),round(uv.y),mm)/255f;float q=constrain(baseConf*(.78f+.22f*edge),0,1);return j.set(uv,xyz,q,2);}
  PVector refineRgb(PVector g,int id,int radius){int w=scannerProtocol.WIDTH,h=scannerProtocol.HEIGHT,step=cfg.sampleStep,gw=(w+step-1)/step,gh=(h+step-1)/step;float best=-1;PVector out=g.copy();for(int y=max(1,round(g.y-radius));y<=min(h-2,round(g.y+radius));y+=2)for(int x=max(1,round(g.x-radius));x<=min(w-2,round(g.x+radius));x+=2){if(!belongs(x,y,id,step,gw,gh))continue;int mm=fullDepth[y*w+x];if(mm<=0)continue;float edge=edgeAtDepthPixel(x,y,mm),near=1-constrain(dist(x,y,g.x,g.y)/max(1,radius),0,1),score=cfg.rgbEdgeWeight*(edge/255f)+(1-cfg.rgbEdgeWeight)*near;if(score>best){best=score;out.set(x,y);}}return out;}
  float edgeAtDepthPixel(int x,int y,int mm){PVector q=cal.projectRgb(x,y,mm);if(q==null)return 0;int rx=round(q.x),ry=round(q.y),w=scannerProtocol.WIDTH,h=scannerProtocol.HEIGHT;if(rx<1||ry<1||rx>=w-1||ry>=h-1)return 0;int gx=abs((rgbY[ry*w+rx+1]&255)-(rgbY[ry*w+rx-1]&255)),gy=abs((rgbY[(ry+1)*w+rx]&255)-(rgbY[(ry-1)*w+rx]&255));return min(255,gx+gy);}
  int medianDepth(int x,int y,int id,int radius){int w=scannerProtocol.WIDTH,h=scannerProtocol.HEIGHT,step=cfg.sampleStep,gw=(w+step-1)/step,gh=(h+step-1)/step;int[] vals=new int[(2*radius+1)*(2*radius+1)];int n=0;for(int yy=max(0,y-radius);yy<=min(h-1,y+radius);yy++)for(int xx=max(0,x-radius);xx<=min(w-1,x+radius);xx++){if(!belongs(xx,yy,id,step,gw,gh))continue;int d=fullDepth[yy*w+xx];if(d>=cfg.minDepthMm&&d<=cfg.maxDepthMm)vals[n++]=d;}if(n==0)return 0;Arrays.sort(vals,0,n);return vals[n/2];}
  int nearestDepth(int x,int y,int id,int radius){for(int r=1;r<=radius;r+=2){int d=medianDepth(x,y,id,r);if(d>0)return d;}return 0;}
  InteractionHandPose3D handPose(int id,int gw,int gh,int step,InteractionJoint3D elbow,InteractionJoint3D wrist,InteractionJoint3D hand,boolean left,InteractionHandPose3D prior){InteractionHandPose3D p=new InteractionHandPose3D();p.wrist=wrist;PVector axis=PVector.sub(hand.image,elbow.image);float arm=max(1,axis.mag());axis.div(arm);PVector palm2=PVector.lerp(wrist.image,hand.image,.58f);p.palm=makeJoint(left?"left_palm":"right_palm",palm2,id,cfg.rgbHandRefineRadiusPx,.82f);float radius=constrain(arm*.17f,cfg.palmRadiusMinPx,cfg.palmRadiusMaxPx);p.palmRadiusPx=radius;int bins=cfg.fingerAngularBins;float[] radial=new float[bins],tx=new float[bins],ty=new float[bins];Arrays.fill(tx,Float.NaN);Arrays.fill(ty,Float.NaN);float maxR=radius*3.5f;for(int y=max(0,round(p.palm.image.y-maxR));y<=min(scannerProtocol.HEIGHT-1,round(p.palm.image.y+maxR));y+=step)for(int x=max(0,round(p.palm.image.x-maxR));x<=min(scannerProtocol.WIDTH-1,round(p.palm.image.x+maxR));x+=step)if(belongs(x,y,id,step,gw,gh)){float dx=x-p.palm.image.x,dy=y-p.palm.image.y,r=sqrt(dx*dx+dy*dy);if(r<radius*.55f||r>maxR)continue;float fwd=(x-wrist.image.x)*axis.x+(y-wrist.image.y)*axis.y;if(fwd<-radius*.1f)continue;int bi=(int)floor(((float)Math.atan2(dy,dx)+PI)/TWO_PI*bins);bi=(bi%bins+bins)%bins;if(r>radial[bi]){radial[bi]=r;tx[bi]=x;ty[bi]=y;}}
    float[] sm=new float[bins];for(int i=0;i<bins;i++){float a=0,ww=0;for(int k=-2;k<=2;k++){int q=(i+k+bins)%bins,wg=k==0?3:(abs(k)==1?2:1);a+=radial[q]*wg;ww+=wg;}sm[i]=a/ww;}ArrayList<Integer> peaks=new ArrayList<Integer>();float sep=cfg.fingerMinSeparationDeg/360f*bins;for(int slot=0;slot<cfg.maxFingerCount;slot++){int best=-1;float bs=0;for(int i=0;i<bins;i++){if(Float.isNaN(tx[i])||sm[i]<radius*cfg.fingerMinReach)continue;boolean local=sm[i]>=sm[(i-1+bins)%bins]&&sm[i]>=sm[(i+1)%bins]&&sm[i]>=sm[(i-2+bins)%bins]&&sm[i]>=sm[(i+2)%bins];if(!local)continue;boolean close=false;for(Integer q:peaks){int d=abs(i-q);d=min(d,bins-d);if(d<sep){close=true;break;}}if(close)continue;if(sm[i]>bs){bs=sm[i];best=i;}}if(best<0)break;peaks.add(best);}Collections.sort(peaks,new Comparator<Integer>(){public int compare(Integer a,Integer b){return Float.compare(tx[a],tx[b]);}});if(left)Collections.reverse(peaks);String[] names={"thumb","index","middle","ring","pinky"};int found=min(5,peaks.size());p.fingerCount=found;for(int i=0;i<found;i++){int bi=peaks.get(i);InteractionFinger3D finger=p.fingers[i];PVector tip2=new PVector(tx[bi],ty[bi]);finger.tip=makeJoint(names[i]+"_tip",tip2,id,6,.62f);PVector base2=PVector.lerp(p.palm.image,tip2,.34f);finger.base=makeJoint(names[i]+"_base",base2,id,5,.52f);finger.confidence=min(finger.tip.confidence,finger.base.confidence);}float span=0;if(found>=2){float minD=Float.MAX_VALUE;for(int i=0;i<found;i++)for(int j=i+1;j<found;j++)minD=min(minD,PVector.dist(p.fingers[i].tip.image,p.fingers[j].tip.image));span=minD/max(1,radius);}float fingerScore=found/5f;p.confidence=constrain(.45f+.35f*min(1,found/3f)+.20f*(p.palm.tracked()?1:0),0,1);p.openness=constrain(.30f+.70f*fingerScore,0,1);p.grabStrength=1-p.openness;p.pinchStrength=found>=2?constrain(map(span,1.6f,.42f,0,1),0,1)*p.confidence:0;p.tracked=p.palm.tracked();if(prior!=null&&prior.tracked){float a=cfg.handPoseSmoothing;p.openness=lerp(prior.openness,p.openness,a);p.grabStrength=1-p.openness;p.pinchStrength=lerp(prior.pinchStrength,p.pinchStrength,a);}return p;}
  void kinematicConfidence(InteractionSkeleton3D s){float sw=PVector.dist(s.leftShoulder.world,s.rightShoulder.world);if(sw<.16f||sw>.75f){s.leftShoulder.confidence*=.55f;s.rightShoulder.confidence*=.55f;}bonePenalty(s.leftShoulder,s.leftElbow,.12f,.48f);bonePenalty(s.leftElbow,s.leftWrist,.10f,.45f);bonePenalty(s.rightShoulder,s.rightElbow,.12f,.48f);bonePenalty(s.rightElbow,s.rightWrist,.10f,.45f);bonePenalty(s.leftHip,s.leftKnee,.18f,.70f);bonePenalty(s.rightHip,s.rightKnee,.18f,.70f);}
  void bonePenalty(InteractionJoint3D a,InteractionJoint3D b,float lo,float hi){if(!a.tracked()||!b.tracked())return;float d=PVector.dist(a.world,b.world);if(d<lo||d>hi){a.confidence*=.78f;b.confidence*=.60f;}}
  float componentConfidence(InteractionComponent c){return constrain(c.count/(float)max(1,cfg.minClusterSamples*8),0,1);}float jointScore(InteractionSkeleton3D s){InteractionJoint3D[] js={s.head,s.neck,s.chest,s.spine,s.pelvis,s.leftShoulder,s.rightShoulder,s.leftElbow,s.rightElbow,s.leftWrist,s.rightWrist,s.leftHand,s.rightHand,s.leftHip,s.rightHip,s.leftKnee,s.rightKnee,s.leftAnkle,s.rightAnkle};float sum=0,w=0;for(InteractionJoint3D j:js){float ww=(j==s.chest||j==s.pelvis||j==s.leftShoulder||j==s.rightShoulder)?2:1;sum+=j.confidence*ww;w+=ww;}return w>0?sum/w:0;}
  void smooth(InteractionSkeleton3D s){if(previous==null||!previous.tracked)return;InteractionJoint3D[] a={previous.head,previous.neck,previous.chest,previous.spine,previous.pelvis,previous.leftShoulder,previous.rightShoulder,previous.leftElbow,previous.rightElbow,previous.leftWrist,previous.rightWrist,previous.leftHand,previous.rightHand,previous.leftHip,previous.rightHip,previous.leftKnee,previous.rightKnee,previous.leftAnkle,previous.rightAnkle,previous.leftFoot,previous.rightFoot};InteractionJoint3D[] b={s.head,s.neck,s.chest,s.spine,s.pelvis,s.leftShoulder,s.rightShoulder,s.leftElbow,s.rightElbow,s.leftWrist,s.rightWrist,s.leftHand,s.rightHand,s.leftHip,s.rightHip,s.leftKnee,s.rightKnee,s.leftAnkle,s.rightAnkle,s.leftFoot,s.rightFoot};float k=constrain(cfg.skeletonSmoothing,.08f,.75f);for(int i=0;i<a.length;i++)if(a[i].tracked()&&b[i].tracked()){b[i].image=PVector.lerp(a[i].image,b[i].image,k);b[i].world=PVector.lerp(a[i].world,b[i].world,k);b[i].confidence=lerp(a[i].confidence,b[i].confidence,.45f);}s.leftOpenness=lerp(previous.leftOpenness,s.leftOpenness,cfg.handOpennessSmoothing);s.rightOpenness=lerp(previous.rightOpenness,s.rightOpenness,cfg.handOpennessSmoothing);}
}

class InteractionDesktopOverlayBridge {
  final InteractionConfig cfg;volatile Process process;volatile BufferedWriter writer;volatile boolean running=false,starting=false,wanted=false;
  InteractionDesktopOverlayBridge(InteractionConfig cfg){this.cfg=cfg;}
  boolean supported(){
    if(!cfg.desktopOverlay)return false;
    String os=System.getProperty("os.name","").toLowerCase(Locale.ROOT);
    return os.contains("win")||transportFactory.isLinux();
  }
  void start(){
    synchronized(this){wanted=true;if(running||starting||!supported())return;starting=true;}
    Thread t=new Thread(new Runnable(){public void run(){startBlocking();}},"SynKinectStudio-Interaction-Overlay");
    t.setDaemon(true);t.start();
  }
  void startBlocking(){
    Process p=null;BufferedWriter w=null;
    try{
      ProcessBuilder pb;
      if(transportFactory.isLinux()){
        File script=new File(dataPath("linux-interaction-bridge.py"));if(!script.isFile())throw new FileNotFoundException(script.getAbsolutePath());
        pb=new ProcessBuilder("python3",script.getAbsolutePath());
      }else{
        File script=new File(dataPath("windows-interaction-bridge.ps1"));if(!script.isFile())throw new FileNotFoundException(script.getAbsolutePath());
        String root=System.getenv("SystemRoot");String exe=root==null?"powershell.exe":new File(root,"System32\\WindowsPowerShell\\v1.0\\powershell.exe").getAbsolutePath();
        pb=new ProcessBuilder(exe,"-NoProfile","-ExecutionPolicy","Bypass","-File",script.getAbsolutePath());
      }
      pb.redirectErrorStream(true);pb.redirectOutput(ProcessBuilder.Redirect.appendTo(new File(System.getProperty("java.io.tmpdir"),"synkinect-interaction-bridge.log")));
      p=pb.start();w=new BufferedWriter(new OutputStreamWriter(p.getOutputStream(),"UTF-8"));
      synchronized(this){
        if(!wanted){try{w.write("STOP\n");w.flush();}catch(Exception ignored){}try{w.close();}catch(Exception ignored){}try{p.destroy();}catch(Exception ignored){}starting=false;return;}
        process=p;writer=w;running=true;starting=false;
      }
    }catch(Exception e){
      if(w!=null)try{w.close();}catch(Exception ignored){}
      if(p!=null)try{p.destroy();}catch(Exception ignored){}
      synchronized(this){running=false;starting=false;writer=null;process=null;}
    }
  }
  void send(String line){
    BufferedWriter w;
    synchronized(this){if(!running||writer==null){start();return;}w=writer;}
    try{w.write(line);w.newLine();w.flush();}catch(Exception e){stop();}
  }
  void cloud(PVector a,PVector b,int hands,int mode,float energy){
    if(a==null)return;float bx=b==null?a.x:b.x,by=b==null?a.y:b.y;
    send(String.format(Locale.US,"CLOUD|%.1f|%.1f|%.1f|%.1f|%d|%d|%.3f",a.x,a.y,bx,by,hands,mode,energy));
  }
  void hide(){if(running)send("HIDE");}
  void stop(){
    Process p;BufferedWriter w;
    synchronized(this){wanted=false;p=process;w=writer;process=null;writer=null;running=false;}
    if(w!=null)try{w.write("STOP\n");w.flush();}catch(Exception ignored){}
    if(w!=null)try{w.close();}catch(Exception ignored){}
    if(p!=null)try{p.destroy();}catch(Exception ignored){}
  }
}

class InteractionOrbCloud {
  final InteractionConfig cfg;final int count,trailCount;float[] x,y,vx,vy,phase,ring,lag;int[] band;float[] histX,histY;long lastMs=0;InteractionSkeleton3D skeleton;float lastHandX=Float.NaN,lastHandY=Float.NaN,handVx=0,handVy=0;
  InteractionOrbCloud(InteractionConfig cfg){
    this.cfg=cfg;count=max(80,cfg.cloudParticles);trailCount=max(6,cfg.cloudTrailSamples);x=new float[count];y=new float[count];vx=new float[count];vy=new float[count];phase=new float[count];ring=new float[count];lag=new float[count];band=new int[count];histX=new float[trailCount];histY=new float[trailCount];
    Random r=new Random(360112);for(int i=0;i<count;i++){phase[i]=r.nextFloat()*TWO_PI;ring[i]=sqrt(r.nextFloat());lag[i]=pow(r.nextFloat(),0.72f);band[i]=min(2,floor(lag[i]*3));x[i]=scannerProtocol.WIDTH*0.5f;y[i]=scannerProtocol.HEIGHT*0.5f;}
  }
  PVector primaryHand(InteractionSkeleton3D s){if(s==null)return null;if("left".equals(cfg.hand)&&s.leftHandTracked())return s.leftHand.image;if("right".equals(cfg.hand)&&s.rightHandTracked())return s.rightHand.image;if(s.rightHandTracked())return s.rightHand.image;if(s.leftHandTracked())return s.leftHand.image;return null;}
  float primaryOpen(InteractionSkeleton3D s){if(s==null)return 0.5f;if("left".equals(cfg.hand)&&s.leftHandTracked())return s.leftOpenness;if("right".equals(cfg.hand)&&s.rightHandTracked())return s.rightOpenness;if(s.rightHandTracked())return s.rightOpenness;if(s.leftHandTracked())return s.leftOpenness;return 0.5f;}
  void reset(){skeleton=null;lastMs=0;lastHandX=lastHandY=Float.NaN;handVx=handVy=0;Arrays.fill(vx,0);Arrays.fill(vy,0);}
  void seedHistory(float hx,float hy){for(int i=0;i<trailCount;i++){histX[i]=hx;histY[i]=hy;}for(int i=0;i<count;i++){x[i]=hx;y[i]=hy;vx[i]=vy[i]=0;}}
  void pushHistory(float hx,float hy){for(int i=trailCount-1;i>0;i--){histX[i]=histX[i-1];histY[i]=histY[i-1];}histX[0]=hx;histY[0]=hy;}
  void update(InteractionSkeleton3D s){
    skeleton=s;if(s==null||!s.tracked)return;PVector h=primaryHand(s);if(h==null)return;long now=millis64();float dt=lastMs==0?1.0f/60.0f:constrain((now-lastMs)/1000.0f,0.004f,0.040f);lastMs=now;float t=now*0.001f;
    if(Float.isNaN(lastHandX)){lastHandX=h.x;lastHandY=h.y;seedHistory(h.x,h.y);}float rawVx=(h.x-lastHandX)/dt,rawVy=(h.y-lastHandY)/dt;lastHandX=h.x;lastHandY=h.y;float va=1.0f-exp(-10.0f*dt);handVx=lerp(handVx,rawVx,va);handVy=lerp(handVy,rawVy,va);pushHistory(h.x,h.y);
    float speed=sqrt(handVx*handVx+handVy*handVy),ux=speed>5?handVx/speed:1,uy=speed>5?handVy/speed:0,pxAxis=-uy,pyAxis=ux;float stretch=1.0f+min(max(0,cfg.cloudMaxStretch-1.0f),speed*cfg.cloudStretchGain);float openness=primaryOpen(s),baseRadius=cfg.cloudRadiusPx*(0.78f+0.48f*openness);
    for(int i=0;i<count;i++){
      int hi=constrain(round(lag[i]*(trailCount-1)*cfg.cloudTrailStrength),0,trailCount-1);float cx=histX[hi],cy=histY[hi],tailFade=1.0f-0.42f*lag[i];float a=phase[i]+t*(0.52f+0.20f*((i%11)/11.0f));float rr=baseRadius*(0.18f+0.82f*ring[i])*tailFade;
      float longAxis=rr*(1.0f+(stretch-1.0f)*(0.35f+0.65f*lag[i])),shortAxis=rr/max(1.0f,sqrt(stretch));float swirl=sin(a*1.83f+t*0.48f+phase[i])*cfg.cloudFlow*baseRadius*(0.45f+0.55f*lag[i]);
      float localLong=cos(a)*longAxis-swirl*0.20f,localPerp=sin(a)*shortAxis+swirl;float tx=cx+ux*localLong+pxAxis*localPerp,ty=cy+uy*localLong+pyAxis*localPerp;
      float ax=(tx-x[i])*cfg.cloudSpring-vx[i]*cfg.cloudDamping,ay=(ty-y[i])*cfg.cloudSpring-vy[i]*cfg.cloudDamping;vx[i]+=ax*dt;vy[i]+=ay*dt;x[i]+=vx[i]*dt;y[i]+=vy[i]*dt;
    }
  }
  void draw(float sx,float sy){
    if(skeleton==null||!skeleton.tracked||primaryHand(skeleton)==null)return;strokeCap(ROUND);
    for(int b=2;b>=0;b--){int alpha=b==0?228:b==1?156:82;float core=b==0?2.5f:b==1?2.1f:1.7f,glow=core*2.8f;
      stroke(104,169,232,max(18,alpha/4));strokeWeight(glow*studioUiScale());beginShape(POINTS);for(int i=0;i<count;i++){if(band[i]!=b)continue;vertex(x[i]*sx,y[i]*sy);}endShape();
      stroke(104,169,232,alpha);strokeWeight(core*studioUiScale());beginShape(POINTS);for(int i=0;i<count;i++){if(band[i]!=b)continue;vertex(x[i]*sx,y[i]*sy);}endShape();
    }noStroke();
  }
}


class InteractionDesktopController {
  final InteractionConfig cfg;Robot robot;Rectangle desktopBounds;final InteractionDesktopOverlayBridge overlay;
  volatile boolean enabled=false,dragging=false,buttonDown=false,twoHandMode=false;volatile String handMode;
  float sx=Float.NaN,sy=Float.NaN;long lastMoveMs=0,lastTrackedMs=0,moveCount=0,doubleClickCount=0,dragCount=0,scrollCount=0;volatile int lastX=-1,lastY=-1;String error="";
  long twoHandsSince=0,bothClosedSince=0,lastDoubleMs=0,lastScrollMs=0;float lastScrollY=Float.NaN;boolean doubleFired=false;String interactionState="gesture.cloud_only";
  InteractionDesktopController(InteractionConfig cfg){this.cfg=cfg;handMode=cfg.hand;overlay=new InteractionDesktopOverlayBridge(cfg);try{if(GraphicsEnvironment.isHeadless())throw new AWTException("headless");robot=new Robot();robot.setAutoDelay(3);desktopBounds=desktopBounds();}catch(Exception e){error=safeStudioMessage(e);robot=null;desktopBounds=new Rectangle(0,0,1,1);}}
  Rectangle desktopBounds(){Rectangle all=null;for(GraphicsDevice gd:GraphicsEnvironment.getLocalGraphicsEnvironment().getScreenDevices()){Rectangle b=gd.getDefaultConfiguration().getBounds();all=all==null?new Rectangle(b):all.union(b);}return all==null?new Rectangle(0,0,1920,1080):all;}
  boolean available(){return robot!=null;}
  void setEnabled(boolean on){boolean next=on&&available();if(enabled==next)return;enabled=next;if(enabled)overlay.start();else{releaseDrag();resetGesture();overlay.stop();}sx=Float.NaN;sy=Float.NaN;}
  void resetGesture(){twoHandMode=false;twoHandsSince=bothClosedSince=0;lastScrollY=Float.NaN;doubleFired=false;interactionState="gesture.cloud_only";}
  void cycleHand(){handMode="right".equals(handMode)?"left":"right";}
  String handKey(){return "hand."+handMode;}
  String gestureKey(){if(!enabled)return "gesture.disabled";if(dragging)return "gesture.dragging";return interactionState;}
  boolean primaryLeft(InteractionSkeleton3D s){if(s==null)return false;if("left".equals(handMode)&&s.leftHandTracked())return true;if("right".equals(handMode)&&s.rightHandTracked())return false;if(s.rightHandTracked())return false;return s.leftHandTracked();}
  InteractionJoint3D primaryJoint(InteractionSkeleton3D s){if(s==null)return null;if(primaryLeft(s)&&s.leftHandTracked())return s.leftHand;if(!primaryLeft(s)&&s.rightHandTracked())return s.rightHand;if(s.rightHandTracked())return s.rightHand;if(s.leftHandTracked())return s.leftHand;return null;}
  InteractionJoint3D secondaryJoint(InteractionSkeleton3D s){if(s==null||!s.rightHandTracked()||!s.leftHandTracked())return null;return primaryLeft(s)?s.rightHand:s.leftHand;}
  float primaryOpen(InteractionSkeleton3D s){if(s==null)return 0.5f;return primaryLeft(s)?s.leftOpenness:(s.rightHandTracked()?s.rightOpenness:s.leftOpenness);}
  float secondaryOpen(InteractionSkeleton3D s){if(s==null||!s.rightHandTracked()||!s.leftHandTracked())return 0.5f;return primaryLeft(s)?s.rightOpenness:s.leftOpenness;}
  PVector screenPoint(InteractionSkeleton3D s,InteractionJoint3D hand){
    if(s==null||hand==null||!hand.tracked()||!s.chest.tracked()||!s.leftShoulder.tracked()||!s.rightShoulder.tracked())return null;
    PVector xAxis=PVector.sub(s.rightShoulder.world,s.leftShoulder.world);if(xAxis.mag()<0.05f)xAxis.set(1,0,0);else xAxis.normalize();PVector rel=PVector.sub(hand.world,s.chest.world);float lateral=rel.dot(xAxis),vertical=rel.y,forward=s.chest.world.z-hand.world.z;if(forward<cfg.minHandForwardM)return null;float nx=constrain((lateral+cfg.volumeHalfWidthM)/(2*cfg.volumeHalfWidthM),0,1),ny=constrain((vertical+cfg.volumeTopM)/max(.05f,cfg.volumeTopM+cfg.volumeBottomM),0,1);if(cfg.mirrorX)nx=1-nx;return new PVector(desktopBounds.x+nx*max(1,desktopBounds.width-1),desktopBounds.y+ny*max(1,desktopBounds.height-1));
  }
  void update(InteractionSkeleton3D s){
    long now=millis64();
    if(!enabled||robot==null||s==null||!s.tracked){if(enabled&&now-lastTrackedMs>cfg.cursorLostReleaseMs){releaseDrag();resetGesture();overlay.hide();}return;}
    InteractionJoint3D primary=primaryJoint(s);if(primary==null){overlay.hide();return;}lastTrackedMs=now;InteractionJoint3D secondary=secondaryJoint(s);PVector a=screenPoint(s,primary),b=screenPoint(s,secondary);
    if(a==null){overlay.hide();return;}boolean two=secondary!=null&&b!=null;
    if(!two){
      twoHandsSince=0;twoHandMode=false;releaseDrag();lastScrollY=Float.NaN;bothClosedSince=0;doubleFired=false;interactionState="gesture.cloud_only";overlay.cloud(a,null,1,1,primaryOpen(s));return;
    }
    if(twoHandsSince==0)twoHandsSince=now;if(now-twoHandsSince>=cfg.twoHandStableMs)twoHandMode=true;
    if(!twoHandMode){interactionState="gesture.two_hand_wait";overlay.cloud(a,null,1,1,primaryOpen(s));return;}
    updatePointer(a,now);float po=primaryOpen(s),so=secondaryOpen(s);boolean pOpen=po>=cfg.handOpenThreshold,sOpen=so>=cfg.handOpenThreshold,pClosed=po<=cfg.handCloseThreshold,sClosed=so<=cfg.handCloseThreshold;
    if(pClosed&&sClosed){
      releaseDrag();interactionState="gesture.double_click";if(bothClosedSince==0)bothClosedSince=now;if(!doubleFired&&now-bothClosedSince>=cfg.doubleClickStableMs&&now-lastDoubleMs>=cfg.doubleClickCooldownMs){doubleClick();doubleFired=true;lastDoubleMs=now;}
    }else{
      bothClosedSince=0;if(pOpen||sOpen)doubleFired=false;
      if(pClosed&&sOpen){interactionState="gesture.dragging";if(!buttonDown){pressPrimary();dragging=true;dragCount++;}}
      else{if(buttonDown)releaseDrag();if(pOpen&&sOpen){interactionState="gesture.scroll";updateScroll(s,now);}else interactionState="gesture.two_hand_ready";}
    }
    overlay.cloud(a,null,1,2,po);
  }
  void updatePointer(PVector target,long now){
    if(target==null||now-lastMoveMs<1000/max(1,cfg.cursorMaxHz))return;lastMoveMs=now;float tx=target.x,ty=target.y;
    if(Float.isNaN(sx)){sx=tx;sy=ty;}else{float d=dist(sx,sy,tx,ty);float speed=constrain(d/max(1,cfg.cursorFastDistancePx),0,1);float a=lerp(cfg.cursorSlowAlpha,cfg.cursorFastAlpha,speed);sx=lerp(sx,tx,a);sy=lerp(sy,ty,a);}
    int nxp=round(sx),nyp=round(sy);if(lastX>=0&&dist(lastX,lastY,nxp,nyp)<cfg.cursorDeadzonePx)return;lastX=nxp;lastY=nyp;try{robot.mouseMove(lastX,lastY);moveCount++;error="";}catch(Exception e){error=safeStudioMessage(e);}
  }
  void updateScroll(InteractionSkeleton3D s,long now){
    float avg=(s.leftHand.world.y+s.rightHand.world.y)*0.5f;if(Float.isNaN(lastScrollY)){lastScrollY=avg;return;}float delta=avg-lastScrollY;
    if(abs(delta)>=cfg.scrollThresholdM&&now-lastScrollMs>=cfg.scrollCooldownMs){int units=constrain(round(delta*cfg.scrollGainPerM),-5,5);if(units!=0){try{robot.mouseWheel(units);scrollCount+=abs(units);}catch(Exception e){error=safeStudioMessage(e);}lastScrollY=avg;lastScrollMs=now;}}else if(abs(delta)<cfg.scrollThresholdM*.35f)lastScrollY=lerp(lastScrollY,avg,.08f);
  }
  void pressPrimary(){if(!enabled||robot==null||buttonDown)return;try{robot.mousePress(InputEvent.BUTTON1_DOWN_MASK);buttonDown=true;}catch(Exception e){error=safeStudioMessage(e);}}
  void releasePrimary(){if(robot==null||!buttonDown)return;try{robot.mouseRelease(InputEvent.BUTTON1_DOWN_MASK);}catch(Exception e){error=safeStudioMessage(e);}buttonDown=false;}
  void doubleClick(){if(enabled&&robot!=null){try{robot.mousePress(InputEvent.BUTTON1_DOWN_MASK);robot.mouseRelease(InputEvent.BUTTON1_DOWN_MASK);Thread.sleep(75);robot.mousePress(InputEvent.BUTTON1_DOWN_MASK);robot.mouseRelease(InputEvent.BUTTON1_DOWN_MASK);doubleClickCount++;}catch(Exception e){error=safeStudioMessage(e);}}}
  void releaseDrag(){releasePrimary();dragging=false;}
  void key(int code){if(enabled&&robot!=null){robot.keyPress(code);robot.keyRelease(code);}}
  void chord(int modifier,int code){if(enabled&&robot!=null){robot.keyPress(modifier);robot.keyPress(code);robot.keyRelease(code);robot.keyRelease(modifier);}}
}


class InteractionUI {
  final UiRect enableButton=new UiRect(),releaseButton=new UiRect();
  void draw(){float m=20*studioUiScale(),gap=14*studioUiScale(),header=72*studioUiScale();drawHeader(m,header);float y=header+gap,w=width-2*m,h=max(180,studio.contentHeight-y-m),left=w*.72f,right=w-left-gap;drawVision(m,y,left,h);drawControl(m+left+gap,y,right,h);}
  void drawHeader(float m,float h){fill(0xFFF4F7FA);textAlign(LEFT,CENTER);textSize(responsiveFontSize(26));String title=interactionI18n.tr("app.title");fitCurrentTextSize(title,26,13,width*.58f,h-12);text(title,m,h*.43f);fill(0xFFAAB6C2);textSize(responsiveFontSize(13));String sub=interactionI18n.tr("app.subtitle");fitCurrentTextSize(sub,13,8,width*.62f,h-12);text(sub,m,h*.72f);float bw=constrain(width*.15f,138,210),bh=36*studioUiScale(),x=width-m-bw;enableButton.set(x,18*studioUiScale(),bw,bh);drawButton(enableButton,interactionI18n.tr(interactionControlEnabled?"button.disable":"button.enable"),true,interactionControlEnabled);textAlign(LEFT,BASELINE);}
  void drawVision(float x,float y,float w,float h){card(x,y,w,h);cardTitle(x,y,w,interactionI18n.tr("panel.vision"));float px=x+12,py=y+44*studioUiScale(),pw=w-24,ph=h-56*studioUiScale();fill(acousticTheme.BG);rect(px,py,pw,ph,10);if(interactionRgbImage!=null){float[] vr=imageRect(interactionRgbImage,px,py,pw,ph);pushMatrix();if(interactionConfig.mirrorX){translate(vr[0]+vr[2],vr[1]);scale(-1,1);image(interactionRgbImage,0,0,vr[2],vr[3]);}else image(interactionRgbImage,vr[0],vr[1],vr[2],vr[3]);popMatrix();drawSkeletonOverlay(vr[0],vr[1],vr[2],vr[3]);}else{fill(0xFFAAB6C2);textAlign(CENTER,CENTER);textSize(responsiveFontSize(15));text(interactionI18n.tr("waiting.rgbd"),px+pw/2,py+ph/2);textAlign(LEFT,BASELINE);}}
  float[] imageRect(PImage img,float x,float y,float w,float h){float sc=min(w/img.width,h/img.height),dw=img.width*sc,dh=img.height*sc;return new float[]{x+(w-dw)/2,y+(h-dh)/2,dw,dh};}
  void drawSkeletonOverlay(float x,float y,float w,float h){InteractionSkeleton3D s=interactionSkeleton;if(s==null||!s.tracked)return;float sx=w/scannerProtocol.WIDTH,sy=h/scannerProtocol.HEIGHT;pushMatrix();translate(x,y);if(interactionConfig.mirrorX){translate(w,0);scale(-1,1);}strokeWeight(max(1,1.6f*studioUiScale()));stroke(0xFF6E899D,190);noFill();if(s.head.tracked())ellipse(s.head.image.x*sx,s.head.image.y*sy,s.faceWidthPx*sx,s.faceHeightPx*sy);bone(s.head,s.neck,sx,sy);bone(s.neck,s.chest,sx,sy);bone(s.chest,s.spine,sx,sy);bone(s.spine,s.pelvis,sx,sy);bone(s.leftShoulder,s.rightShoulder,sx,sy);bone(s.neck,s.leftShoulder,sx,sy);bone(s.neck,s.rightShoulder,sx,sy);bone(s.leftShoulder,s.leftElbow,sx,sy);bone(s.leftElbow,s.leftWrist,sx,sy);bone(s.leftWrist,s.leftHand,sx,sy);bone(s.rightShoulder,s.rightElbow,sx,sy);bone(s.rightElbow,s.rightWrist,sx,sy);bone(s.rightWrist,s.rightHand,sx,sy);bone(s.pelvis,s.leftHip,sx,sy);bone(s.pelvis,s.rightHip,sx,sy);bone(s.leftHip,s.leftKnee,sx,sy);bone(s.leftKnee,s.leftAnkle,sx,sy);bone(s.leftAnkle,s.leftFoot,sx,sy);bone(s.rightHip,s.rightKnee,sx,sy);bone(s.rightKnee,s.rightAnkle,sx,sy);bone(s.rightAnkle,s.rightFoot,sx,sy);if(interactionCloud!=null)interactionCloud.draw(sx,sy);drawHandPose(s.leftPose,s.leftHand,s.leftOpenness,sx,sy,0xFFD8BCFF);drawHandPose(s.rightPose,s.rightHand,s.rightOpenness,sx,sy,0xFF9ED8FF);popMatrix();}
  void bone(InteractionJoint3D a,InteractionJoint3D b,float sx,float sy){if(a!=null&&b!=null&&a.tracked()&&b.tracked())line(a.image.x*sx,a.image.y*sy,b.image.x*sx,b.image.y*sy);}
  void drawHandPose(InteractionHandPose3D p,InteractionJoint3D hand,float openness,float sx,float sy,int c){if(p!=null&&p.tracked&&hand!=null&&hand.tracked()){stroke(c,190);strokeWeight(max(1,1.2f*studioUiScale()));for(int i=0;i<p.fingerCount;i++){InteractionFinger3D f=p.fingers[i];if(f.tip.tracked()){line(hand.image.x*sx,hand.image.y*sy,f.tip.image.x*sx,f.tip.image.y*sy);noStroke();fill(c,235);ellipse(f.tip.image.x*sx,f.tip.image.y*sy,5*studioUiScale(),5*studioUiScale());stroke(c,190);}}noStroke();fill(c,220);float d=(7+7*openness)*studioUiScale();ellipse(hand.image.x*sx,hand.image.y*sy,d,d);}}
  String xyz(InteractionJoint3D j){return j==null||!j.tracked()?"—":String.format(Locale.US,"%.2f / %.2f / %.2f m",j.world.x,j.world.y,j.world.z);}
  void drawControl(float x,float y,float w,float h){card(x,y,w,h);cardTitle(x,y,w,interactionI18n.tr("panel.control"));float px=x+12,py=y+48*studioUiScale(),inner=w-24,row=29*studioUiScale();String live=interaction3dLive()?interactionI18n.tr("state.live"):interactionI18n.tr("state.wait");statusRow(px,py,inner,interactionI18n.tr("label.kinect"),live);py+=row;String syncValue=kinectSource==null||Float.isNaN(kinectSource.latestSyncResidualMs)?"—":String.format(Locale.US,"%.1f ms · offset %.1f ms",kinectSource.latestSyncResidualMs,kinectSource.syncOffsetUs/1000.0);statusRow(px,py,inner,interactionI18n.tr("label.sync"),syncValue);py+=row;String sk=interactionSkeleton!=null&&interactionSkeleton.tracked?interactionI18n.format("state.tracked",interactionSkeleton.confidence*100):interactionI18n.tr("tracker."+(interactionTracker==null?"searching":interactionTracker.lastReason));statusRow(px,py,inner,interactionI18n.tr("label.skeleton"),sk);py+=row;statusRow(px,py,inner,interactionI18n.tr("label.depth"),interactionSkeleton==null?"—":String.format(Locale.US,"%.2f m",interactionSkeleton.meanDepthM));py+=row;statusRow(px,py,inner,interactionI18n.tr("label.right_hand_xyz"),interactionSkeleton==null?"—":xyz(interactionSkeleton.rightHand));py+=row;statusRow(px,py,inner,interactionI18n.tr("label.left_hand_xyz"),interactionSkeleton==null?"—":xyz(interactionSkeleton.leftHand));py+=row;String fingers=interactionSkeleton==null?"0 / 0":interactionSkeleton.leftPose.fingerCount+" / "+interactionSkeleton.rightPose.fingerCount;statusRow(px,py,inner,interactionI18n.tr("label.fingers"),fingers);py+=row;String mode=interactionDesktop==null?interactionI18n.tr("gesture.disabled"):interactionI18n.tr(interactionDesktop.gestureKey());statusRow(px,py,inner,interactionI18n.tr("label.mode"),mode);py+=row;String actions=interactionDesktop==null?"0 / 0 / 0":interactionDesktop.doubleClickCount+" / "+interactionDesktop.dragCount+" / "+interactionDesktop.scrollCount;statusRow(px,py,inner,interactionI18n.tr("label.actions"),actions);py+=row+10*studioUiScale();float bh=38*studioUiScale();releaseButton.set(px,py,inner,bh);drawButton(releaseButton,interactionI18n.tr("button.release"),interactionDesktop!=null&&interactionDesktop.buttonDown,false);py+=bh+14*studioUiScale();fill(0xFFAAB6C2);textAlign(LEFT,TOP);textSize(responsiveFontSize(12));String title=interactionI18n.tr("label.gesture_help");text(title,px,py);py+=20*studioUiScale();fill(0xFFF4F7FA);String help=interactionI18n.tr("help.two_hand");text(help,px,py,inner,max(50,y+h-py-16));textAlign(LEFT,BASELINE);}
  void statusRow(float x,float y,float w,String label,String value){fill(0xFFAAB6C2);textAlign(LEFT,CENTER);textSize(responsiveFontSize(11));fitCurrentTextSize(label,11,7,w*.43f,24*studioUiScale());text(ellipsizeToWidth(label,w*.43f),x,y+12*studioUiScale());fill(0xFFF4F7FA);textAlign(RIGHT,CENTER);fitCurrentTextSize(value,11,7,w*.55f,24*studioUiScale());text(ellipsizeToWidth(value,w*.55f),x+w,y+12*studioUiScale());textAlign(LEFT,BASELINE);}
  void handleMouse(float mx,float my){if(enableButton.hit(mx,my))toggleInteractionControl();else if(releaseButton.hit(mx,my)&&interactionDesktop!=null)interactionDesktop.releaseDrag();}
  void drawButton(UiRect r,String label,boolean enabled,boolean primary){boolean hot=enabled&&r.hit(studio.contentMouseX(),studio.contentMouseY());stroke(hot?0xFF68A9E8:0xFF35414D);fill(enabled?(primary?0xFF293440:0xFF202832):0xFF11151A);rect(r.x,r.y,r.w,r.h,9);noStroke();fill(enabled?0xFFF4F7FA:0xFF56616C);textAlign(CENTER,CENTER);textSize(responsiveFontSize(13));fitCurrentTextSize(label,13,7,r.w-12,r.h-8);text(label,r.x+r.w/2,r.y+r.h/2);textAlign(LEFT,BASELINE);}
  void card(float x,float y,float w,float h){stroke(0xFF35414D);fill(0xFF181E25);rect(x,y,w,h,14);noStroke();}void cardTitle(float x,float y,float w,String title){fill(0xFFF4F7FA);textAlign(LEFT,CENTER);textSize(responsiveFontSize(14));fitCurrentTextSize(title,14,8,w-28,36*studioUiScale());text(title,x+14,y+22*studioUiScale());textAlign(LEFT,BASELINE);}
}
