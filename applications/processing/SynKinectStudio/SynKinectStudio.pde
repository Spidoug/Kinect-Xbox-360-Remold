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

// Processing requires one PApplet host, but the Studio runtime itself is a normal
// object graph. Every controller owns its services, configuration, module states
// and lifecycle; no module depends on process-wide mutable singletons.
final StudioController studio=new StudioController(new StudioServices());
PFont studioUnicodeRegular,studioUnicodeHeading;

void initializeStudioTypography(){
  // Java logical fonts are composite fonts: the runtime can fall back to a
  // platform glyph provider for Latin, accented text, CJK and punctuation.
  // This avoids tying the UI to one Windows-only physical font.
  studioUnicodeRegular=createFont("SansSerif",17,true);
  studioUnicodeHeading=createFont("SansSerif",30,true);
  textFont(studioUnicodeRegular);
  textLeading(22);
}
void studioText(float size,boolean heading){
  PFont f=heading?studioUnicodeHeading:studioUnicodeRegular;
  if(f!=null)textFont(f);
  textSize(responsiveFontSize(size));
}

class StudioServices {
  final ConfigRules configRules=new ConfigRules();
  final StudioEndpoints endpoints=new StudioEndpoints();
  final WorkerFactory workers=new WorkerFactory();
  final ScannerProtocol scannerProtocol=new ScannerProtocol();
  final UiTheme uiTheme=new UiTheme();
  final AcousticProtocol acousticProtocol=new AcousticProtocol();
  final AcousticTheme acousticTheme=new AcousticTheme();
  final MicrophoneProtocol microphoneProtocol=new MicrophoneProtocol();
  final MicrophoneTheme microphoneTheme=new MicrophoneTheme();
  final SurveillanceProtocol surveillanceProtocol=new SurveillanceProtocol();
  final SurveillanceTheme surveillanceTheme=new SurveillanceTheme();
  final LocalTransportFactory transportFactory=new LocalTransportFactory();
  final KinectDeviceRegistry devices=new KinectDeviceRegistry();
  UnifiedI18nCatalog catalog;
  UnifiedI18nCatalog catalog(){if(catalog==null)catalog=new UnifiedI18nCatalog();return catalog;}
}

public void settings(){
  // V1 Studio uses logical pixels consistently on Windows/Linux.  High-DPI
  // displays must not silently inflate the whole Processing canvas.
  size(1280,800,P3D);
  pixelDensity(1);
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
  }catch(Exception e){println("Studio close-policy warning: "+safeStudioMessage(e));}
}


class KinectDevice {
  final String id,label,endpoint;
  KinectDevice(String id,String label,String endpoint){this.id=id;this.label=label;this.endpoint=endpoint;}
}

class KinectDeviceRegistry {
  final Object lock=new Object();
  final ArrayList<KinectDevice> devices=new ArrayList<KinectDevice>();
  volatile String selectedId="";
  volatile long generation=0,lastRefreshMs=0;
  volatile boolean refreshQueued=false;
  final long refreshIntervalMs=1000;

  File manifestFile(){
    if(System.getProperty("os.name","").toLowerCase(Locale.ROOT).contains("windows")){
      String root=System.getenv("ProgramData");
      if(root==null||root.trim().isEmpty())root="C:\\ProgramData";
      return new File(new File(root,"Kinect360Remold"),"devices.tsv");
    }
    return new File("/run/kinect360-remold/devices.tsv");
  }

  void refreshIfDue(){requestRefresh(false);}
  void requestRefresh(boolean force){
    long now=System.nanoTime()/1000000L;
    synchronized(lock){
      if(!force&&now-lastRefreshMs<refreshIntervalMs)return;
      if(refreshQueued)return;
      refreshQueued=true;lastRefreshMs=now;
    }
    studio.services.workers.startLowPriority("Device-Registry",new Runnable(){public void run(){
      try{refresh();}finally{refreshQueued=false;}
    }});
  }
  void refresh(){
    ArrayList<KinectDevice> found=new ArrayList<KinectDevice>();
    File file=manifestFile();
    if(file.isFile()){
      try{
        for(String line:Files.readAllLines(file.toPath(),java.nio.charset.StandardCharsets.UTF_8)){
          line=line.trim();if(line.isEmpty()||line.startsWith("#"))continue;String[] parts=line.split("\t",3);
          if(parts.length==3&&!parts[0].trim().isEmpty()&&!parts[2].trim().isEmpty())found.add(new KinectDevice(parts[0].trim(),parts[1].trim().isEmpty()?parts[0].trim():parts[1].trim(),parts[2].trim()));
        }
      }catch(IOException e){println("device-registry: "+safeStudioMessage(e));}
    }
    Collections.sort(found,new Comparator<KinectDevice>(){public int compare(KinectDevice a,KinectDevice b){return a.id.compareTo(b.id);}});
    synchronized(lock){
      String before=signature(devices,selectedId);devices.clear();devices.addAll(found);
      boolean selectedPresent=false;for(KinectDevice d:devices)if(d.id.equals(selectedId)){selectedPresent=true;break;}
      if(!selectedPresent)selectedId=devices.isEmpty()?"":devices.get(0).id;
      String after=signature(devices,selectedId);if(!after.equals(before))generation++;
    }
  }
  String signature(List<KinectDevice> list,String selected){StringBuilder b=new StringBuilder(selected);for(KinectDevice d:list)b.append('|').append(d.id).append('@').append(d.endpoint);return b.toString();}
  KinectDevice selected(){synchronized(lock){for(KinectDevice d:devices)if(d.id.equals(selectedId))return d;return devices.isEmpty()?null:devices.get(0);}}
  ArrayList<KinectDevice> snapshot(){synchronized(lock){return new ArrayList<KinectDevice>(devices);}}
  int count(){synchronized(lock){return devices.size();}}
  void cycle(){synchronized(lock){if(devices.isEmpty()){selectedId="";return;}int idx=0;for(int i=0;i<devices.size();i++)if(devices.get(i).id.equals(selectedId)){idx=i;break;}selectedId=devices.get((idx+1)%devices.size()).id;generation++;}}
  String selectorLabel(){synchronized(lock){if(devices.isEmpty())return "Kinect · 0";int idx=0;for(int i=0;i<devices.size();i++)if(devices.get(i).id.equals(selectedId)){idx=i;break;}return "Kinect · "+(idx+1)+"/"+devices.size();}}
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

enum ModulePhase { NEW, READY, INIT_FAILED, ACTIVATE_FAILED, RENDER_FAILED, DISPOSED }

abstract class StudioModuleBase implements StudioModule {
  final StudioController owner;
  final int moduleId;
  final String moduleTitleKey;
  volatile ModulePhase phase=ModulePhase.NEW;
  volatile String failureMessage="";
  StudioModuleBase(StudioController owner,int id,String titleKey){this.owner=owner;moduleId=id;moduleTitleKey=titleKey;}
  public int id(){return moduleId;}
  public String title(){return owner.i18n==null?moduleTitleKey:owner.i18n.tr(moduleTitleKey);}
  boolean ownsResources(){return phase==ModulePhase.READY||phase==ModulePhase.RENDER_FAILED;}
  void prepareRetry(){
    if(phase==ModulePhase.INIT_FAILED)phase=ModulePhase.NEW;
    else if(phase==ModulePhase.ACTIVATE_FAILED||phase==ModulePhase.RENDER_FAILED)phase=ModulePhase.READY;
    if(phase==ModulePhase.NEW||phase==ModulePhase.READY)failureMessage="";
  }
  void initialize(){
    if(phase!=ModulePhase.NEW)return;
    try{setupModule();phase=ModulePhase.READY;failureMessage="";}
    catch(Exception error){
      phase=ModulePhase.INIT_FAILED;failureMessage=safeStudioMessage(error);
      println("Module initialization failed ["+moduleTitleKey+"]: "+failureMessage);error.printStackTrace();
    }
  }
  void activationFailure(Exception error){phase=ModulePhase.ACTIVATE_FAILED;failureMessage=safeStudioMessage(error);}
  void renderFailure(Exception error){phase=ModulePhase.RENDER_FAILED;failureMessage=safeStudioMessage(error);}
  void markDisposed(){phase=ModulePhase.DISPOSED;}
  public void mousePressedModule(){}
  public void mouseDraggedModule(){}
  public void mouseWheelModule(processing.event.MouseEvent event){}
  public void keyPressedModule(){}
}

class ScannerStudioModule extends StudioModuleBase {
  ScannerStudioModule(StudioController owner){super(owner,STUDIO_TAB_SCANNER,"tab.scanner");}
  public void setupModule(){setupScannerModule();}
  public void activateModule(){
    ensureScannerSource();
    if(owner.scannerState.source!=null){
      // Stable hardware rule: Scanner always opens with the known-good VGA RGB +
      // Depth transport. Starting a scan never promotes the physical sensor mode.
      owner.scannerState.source.setHqColorRequested(false);
      owner.scannerState.source.start();owner.scannerState.source.clearConsumerPairs();
    }
  }
  public void deactivateModule(){
    cancelScannerReconstructionReset();
    // Strict module isolation: HQ Scanner state must never leak into a module
    // that expects canonical VGA RGB+Depth. Every tab transition releases its
    // ScannerPort subscription and the next module negotiates its own mode.
    if(owner.scannerState.scanActive){
      owner.scannerState.scanPaused=true;owner.scannerState.pauseAfterDrain=false;clearPendingScanWork();
    }
    if(owner.scannerState.source!=null){
      owner.scannerState.source.requestStop(true);
      owner.scannerState.source.setHqColorRequested(false);
    }
  }
  public void drawModule(){drawScannerModule();}
  public void mousePressedModule(){scannerMousePressed();}
  public void mouseDraggedModule(){scannerMouseDragged();}
  public void mouseWheelModule(processing.event.MouseEvent event){scannerMouseWheel(event);}
  public void keyPressedModule(){scannerKeyPressed();}
  public void disposeModule(){disposeScannerModule();}
}

class AcousticStudioModule extends StudioModuleBase {
  AcousticStudioModule(StudioController owner){super(owner,STUDIO_TAB_ACOUSTIC,"tab.acoustic");}
  public void setupModule(){setupAcousticModule();}
  public void activateModule(){
    if(owner.acousticState.output!=null)owner.acousticState.output.start();
    if(owner.acousticState.source!=null)owner.acousticState.source.start();
  }
  public void deactivateModule(){
    if(owner.acousticState.source!=null)owner.acousticState.source.requestStop();
    if(owner.acousticState.output!=null)owner.acousticState.output.requestStop();
  }
  public void drawModule(){drawAcousticModule();}
  public void mousePressedModule(){acousticMousePressed();}
  public void keyPressedModule(){acousticKeyPressed();}
  public void disposeModule(){disposeAcousticModule();}
}

class MicrophoneStudioModule extends StudioModuleBase {
  MicrophoneStudioModule(StudioController owner){super(owner,STUDIO_TAB_MICROPHONES,"tab.microphones");}
  public void setupModule(){setupMicrophoneModule();}
  public void activateModule(){if(owner.microphoneState.source!=null)owner.microphoneState.source.start();}
  public void deactivateModule(){
    if(owner.microphoneState.source!=null)owner.microphoneState.source.requestStop();
    if(owner.microphoneState.pipeline!=null){
      owner.microphoneState.pipeline.monitor.requestStop();
      owner.microphoneState.pipeline.player.requestStop();
      owner.microphoneState.pipeline.selfTest.requestStop();
      if(owner.microphoneState.pipeline.recorder.isRecording()){
        final WavRecorder recorder=owner.microphoneState.pipeline.recorder;
        owner.services.workers.startLowPriority("Microphone-Recorder-Close",new Runnable(){public void run(){recorder.stop();}});
      }
    }
  }
  public void drawModule(){drawMicrophoneModule();}
  public void mousePressedModule(){microphoneMousePressed();}
  public void keyPressedModule(){microphoneKeyPressed();}
  public void disposeModule(){disposeMicrophoneModule();}
}

class SurveillanceStudioModule extends StudioModuleBase {
  SurveillanceStudioModule(StudioController owner){super(owner,STUDIO_TAB_SURVEILLANCE,"tab.surveillance");}
  public void setupModule(){setupSurveillanceModule();}
  public void activateModule(){activateSurveillanceRuntime();}
  public void deactivateModule(){deactivateSurveillanceRuntime();}
  public void drawModule(){drawSurveillanceModule();}
  public void mousePressedModule(){surveillanceMousePressed();}
  public void keyPressedModule(){surveillanceKeyPressed();}
  public void disposeModule(){disposeSurveillanceModule();}
}

class InteractivityStudioModule extends StudioModuleBase {
  InteractivityStudioModule(StudioController owner){super(owner,STUDIO_TAB_INTERACTIVITY,"tab.interactivity");}
  public void setupModule(){setupInteractivityModule();}
  public void activateModule(){activateInteractivityModule();}
  public void deactivateModule(){requestDeactivateInteractivityModule();}
  public void drawModule(){drawInteractivityModule();}
  public void mousePressedModule(){interactivityMousePressed();}
  public void keyPressedModule(){interactivityKeyPressed();}
  public void disposeModule(){disposeInteractivityModule();}
}

class StudioController {
  final StudioServices services;
  final StudioShellConfig config;
  final StudioSystemControl systemControl=new StudioSystemControl();
  final StudioHomeSystemPanel homeSystemPanel=new StudioHomeSystemPanel();
  final ScannerModuleState scannerState=new ScannerModuleState();
  final AcousticModuleState acousticState=new AcousticModuleState();
  final MicrophoneModuleState microphoneState=new MicrophoneModuleState();
  final SurveillanceModuleState surveillanceState=new SurveillanceModuleState();
  final InteractionModuleState interactionState=new InteractionModuleState();
  final StudioModuleBase[] modules;
  StudioShellI18n i18n;
  StudioController(StudioServices services){
    this.services=services;
    config=new StudioShellConfig(services.configRules);
    modules=new StudioModuleBase[]{new ScannerStudioModule(this),new AcousticStudioModule(this),new MicrophoneStudioModule(this),new SurveillanceStudioModule(this),new InteractivityStudioModule(this)};
  }
  final Object lifecycleLock=new Object();
  final Object operationLock=new Object();
  volatile int activeTab=-1;
  volatile int desiredTab=-1;
  volatile int ownedTab=-1;
  volatile int transitionTarget=-1;
  volatile boolean ready=false;
  volatile boolean shuttingDown=false;
  volatile boolean transitioning=false;
  volatile boolean lifecycleRun=false;
  Thread lifecycleThread=null;
  int contentHeight=1;
  volatile long closeBlockedUntilMs=0;
  volatile long seenDeviceGeneration=-1;

  // All module UI is rendered in content-local coordinates after the shell
  // translates the canvas by STUDIO_TAB_H. Pointer input must use the exact
  // inverse transform. Keeping this rule here prevents individual modules
  // from mixing window-space and content-space coordinates.
  float contentMouseX(){return mouseX;}
  float contentMouseY(){return mouseY-STUDIO_TAB_H;}
  float contentPMouseX(){return pmouseX;}
  float contentPMouseY(){return pmouseY-STUDIO_TAB_H;}

  String currentLanguage(){return studio.i18n==null?"en-US":studio.i18n.language;}
  void cycleLanguage(){
    if(studio.i18n==null)return;
    studio.i18n.toggle();
    applyLanguageToModules(studio.i18n.language);
    updateTitle();
  }
  void setLanguage(String locale){
    if(studio.i18n==null)return;
    studio.i18n.setLanguage(locale);
    applyLanguageToModules(studio.i18n.language);
    updateTitle();
  }
  void applyLanguageToModules(String locale){
    if(studio.scannerState.i18n!=null){studio.scannerState.i18n.setLanguage(locale);studio.scannerState.status=studio.scannerState.i18n.tr("status.ready");}
    if(studio.acousticState.i18n!=null)studio.acousticState.i18n.setLanguage(locale);
    if(studio.microphoneState.i18n!=null)studio.microphoneState.i18n.setLanguage(locale);
    if(studio.surveillanceState.i18n!=null){studio.surveillanceState.i18n.setLanguage(locale);studio.surveillanceState.status=studio.surveillanceState.i18n.tr(studio.surveillanceState.armed?"status.armed_multi":"status.disarmed");}
    if(studio.interactionState.i18n!=null){
      studio.interactionState.i18n.setLanguage(locale);
      studio.interactionState.status=studio.interactionState.i18n.tr(studio.interactionState.controlEnabled?"status.control_on":"status.ready");
    }
  }

  void setup(){
    contentHeight=max(1,height-STUDIO_TAB_H);
    studio.config.load(new File(dataPath("studio.properties")));
    studio.i18n=new StudioShellI18n(studio.config.language);
    studio.i18n.applyOrder(studio.config.languages);
    initializeStudioTypography();
    services.devices.requestRefresh(true);seenDeviceGeneration=-1;
    frameRate(constrain(studio.config.uiFrameRate,studio.config.uiMinFrameRate,studio.config.uiMaxFrameRate));
    ready=true;
    startLifecycle();
    // V1 starts on a presentation/home screen. No module is initialized or
    // activated until the user explicitly selects one.
    activeTab=-1;desiredTab=-1;ownedTab=-1;transitioning=false;
    updateTitle();
  }

  void draw(){
    contentHeight=max(1,height-STUDIO_TAB_H);
    services.devices.refreshIfDue();
    if(seenDeviceGeneration!=services.devices.generation){seenDeviceGeneration=services.devices.generation;onDeviceRegistryChanged();}
    StudioModuleBase active=activeTab>=0&&activeTab<modules.length?modules[activeTab]:null;

    // P3D keeps camera and model transforms in the same model-view stack.
    // Never call resetMatrix() after camera(): that erases the default camera
    // and places z=0 UI geometry on the eye plane, so only background() remains
    // visible. Restore a known 2D-friendly P3D state with camera()+perspective().
    resetStudioUiRenderer();
    pushStyle();
    pushMatrix();
    translate(0,STUDIO_TAB_H);
    if(active==null){
      drawStudioHome();
    }else{
      if(active.phase==ModulePhase.READY&&isReady(activeTab)){
        try{active.drawModule();}
        catch(Exception error){
          active.renderFailure(error);
          println("Module render failed ["+active.moduleTitleKey+"]: "+active.failureMessage);
          error.printStackTrace();
        }
      }
      if(active.phase!=ModulePhase.READY||!isReady(activeTab))drawModuleStartup(active);
    }
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
    if(studioUnicodeRegular!=null)textFont(studioUnicodeRegular);
    textLeading(responsiveFontSize(15)*1.28f);
  }

  void onDeviceRegistryChanged(){
    if(scannerState.source!=null)scannerState.source.requestReconnect("device-registry");
    if(interactionState.source!=null)interactionState.source.requestReconnect("device-registry");
    services.workers.startLowPriority("Device-Reconcile",new Runnable(){public void run(){
      refreshScannerCalibrationForSelectedDevice(true);
      if(surveillanceState.config!=null)syncSurveillanceDevices(true);
    }});
  }
  void cycleKinect(){services.devices.cycle();seenDeviceGeneration=services.devices.generation;onDeviceRegistryChanged();updateTitle();}
  KinectDevice selectedKinect(){return services.devices.selected();}

  float deviceButtonW(){return constrain(width*0.105f,92,150);}
  float languageButtonW(){return constrain(width*0.075f,68,108);}
  float homeButtonW(){return constrain(width*0.055f,58,82);}
  float tabsGap(){return constrain(width*0.005f,4,8);}
  float tabsMargin(){return constrain(width*0.008f,7,12);}
  float homeButtonX(){return tabsMargin();}
  float tabsStartX(){return homeButtonX()+homeButtonW()+tabsGap();}
  boolean homeButtonHit(float mx,float my){return mx>=homeButtonX()&&mx<=homeButtonX()+homeButtonW()&&my>=7&&my<=41;}
  float tabWidth(){
    float gap=tabsGap(),margin=tabsMargin(),langW=languageButtonW(),devW=deviceButtonW(),homeW=homeButtonW();
    float available=max(1,width-margin*2-homeW-langW-devW-gap*3-gap*(modules.length-1));
    return available/modules.length;
  }
  float languageButtonX(){return width-tabsMargin()-languageButtonW();}
  float deviceButtonX(){return languageButtonX()-tabsGap()-deviceButtonW();}
  boolean languageButtonHit(float mx,float my){return mx>=languageButtonX()&&mx<=languageButtonX()+languageButtonW()&&my>=7&&my<=41;}
  boolean deviceButtonHit(float mx,float my){return mx>=deviceButtonX()&&mx<=deviceButtonX()+deviceButtonW()&&my>=7&&my<=41;}

  void drawTabs(){
    noStroke();fill(0xFF0C1014);rect(0,0,width,STUDIO_TAB_H);
    float gap=tabsGap(),margin=tabsMargin(),homeW=homeButtonW();
    boolean homeActive=activeTab<0,homeHot=homeButtonHit(mouseX,mouseY);
    stroke(homeHot?0xFF68A9E8:0xFF35414D);fill(homeActive?0xFF293440:(homeHot?0xFF222B34:0xFF181E25));rect(homeButtonX(),7,homeW,34,9);noStroke();
    fill(homeActive?0xFFF4F7FA:0xFFAAB6C2);textAlign(CENTER,CENTER);studioText(12,true);String homeLabel=studio.i18n.tr("button.home");fitCurrentTextSize(homeLabel,12,7,max(10,homeW-10),28);text(ellipsizeToWidth(homeLabel,max(10,homeW-10)),homeButtonX()+homeW/2,24);
    float tabW=tabWidth(),x=tabsStartX();
    for(int i=0;i<modules.length;i++){
      boolean active=i==activeTab;
      boolean moduleReady=isReady(i);
      fill(active?0xFF293440:0xFF181E25);rect(x,7,tabW,34,9);
      fill(active?0xFFF4F7FA:0xFFAAB6C2);textAlign(CENTER,CENTER);
      studioText(14,true);fitCurrentTextSize(modules[i].title(),14,7,max(12,tabW-20),28);text(ellipsizeToWidth(modules[i].title(),max(12,tabW-20)),x+tabW/2,24);
      if(active&&!moduleReady){fill(0xFF78B7E8);ellipse(x+tabW-9,24,5,5);}
      x+=tabW+gap;
    }
    float dx=deviceButtonX(),dw=deviceButtonW();boolean dhot=deviceButtonHit(mouseX,mouseY);
    stroke(dhot?0xFF68A9E8:0xFF35414D);fill(dhot?0xFF293440:0xFF181E25);rect(dx,7,dw,34,9);noStroke();fill(services.devices.count()>0?0xFFF4F7FA:0xFF7E8994);
    String deviceLabel=services.devices.selectorLabel();textAlign(CENTER,CENTER);studioText(12,true);fitCurrentTextSize(deviceLabel,12,7,dw-12,28);text(ellipsizeToWidth(deviceLabel,dw-12),dx+dw/2,24);
    float lx=languageButtonX(),lw=languageButtonW();boolean hot=languageButtonHit(mouseX,mouseY);
    stroke(hot?0xFF68A9E8:0xFF35414D);fill(hot?0xFF293440:0xFF181E25);rect(lx,7,lw,34,9);noStroke();fill(0xFFF4F7FA);
    String lang=studio.i18n.tr("button.language")+" · "+studio.i18n.shortLanguage();textAlign(CENTER,CENTER);studioText(13,true);fitCurrentTextSize(lang,13,7,lw-12,28);text(ellipsizeToWidth(lang,lw-12),lx+lw/2,24);
    textAlign(LEFT,BASELINE);
  }

  int tabAt(float mx,float my){
    if(my<0||my>STUDIO_TAB_H||homeButtonHit(mx,my)||languageButtonHit(mx,my)||deviceButtonHit(mx,my))return -1;
    float gap=tabsGap(),tabW=tabWidth(),x=tabsStartX();
    for(int i=0;i<modules.length;i++){if(mx>=x&&mx<=x+tabW&&my>=7&&my<=41)return i;x+=tabW+gap;}
    return -1;
  }

  boolean isReady(int tab){return tab>=0&&!transitioning&&ownedTab==tab;}

  void mousePressed(){
    if(homeButtonHit(mouseX,mouseY)){goHome();return;}
    if(deviceButtonHit(mouseX,mouseY)){cycleKinect();return;}
    if(languageButtonHit(mouseX,mouseY)){cycleLanguage();return;}
    int tab=tabAt(mouseX,mouseY);
    if(tab>=0){select(tab,false);return;}
    if(activeTab<0){String action=homeSystemPanel.actionAt(contentMouseX(),contentMouseY());if(action!=null){systemControl.run(action);return;}int card=homeCardAt(contentMouseX(),contentMouseY());if(card>=0)select(card,false);return;}
    if(!isReady(activeTab))return;
    modules[activeTab].mousePressedModule();
  }
  void mouseDragged(){if(activeTab>=0&&isReady(activeTab))modules[activeTab].mouseDraggedModule();}
  void mouseWheel(processing.event.MouseEvent event){if(activeTab>=0&&isReady(activeTab))modules[activeTab].mouseWheelModule(event);}
  void keyPressed(){
    if(key=='0'){goHome();return;}
    if(key>='1'&&key<='5'){select(key-'1',false);return;}
    if(activeTab>=0&&isReady(activeTab))modules[activeTab].keyPressedModule();
  }

  void escapePressed(){
    // ESC is a cancel/release key only. It never closes the Studio.
    if(studio.interactionState.desktop!=null)studio.interactionState.desktop.releaseDrag();
  }

  boolean surveillanceCloseGuardActive(){return studio.surveillanceState.armed||studio.surveillanceState.recording||studio.surveillanceState.recordStarting;}
  boolean rejectExitRequest(){
    if(shuttingDown)return false;
    if(!surveillanceCloseGuardActive())return false;
    closeBlockedUntilMs=millis64()+2800;
    return true;
  }

  void drawCloseGuardNotice(){
    String msg=studio.i18n==null?"Surveillance is armed. Disarm it before closing.":studio.i18n.tr("status.close_blocked_armed");
    float h=34,w=min(max(280,textWidth(msg)+34),max(280,width-40)),x=(width-w)/2,y=STUDIO_TAB_H+10;
    noStroke();fill(0xEE302A24);rect(x,y,w,h,9);stroke(0xFFE4B86B);noFill();rect(x,y,w,h,9);noStroke();
    fill(0xFFF4F7FA);textAlign(CENTER,CENTER);textSize(responsiveFontSize(12));fitCurrentTextSize(msg,12,8,w-24,h-8);text(ellipsizeToWidth(msg,w-24),x+w/2,y+h/2);textAlign(LEFT,BASELINE);
  }

  void goHome(){
    activeTab=-1;
    synchronized(lifecycleLock){desiredTab=-1;transitioning=ownedTab>=0;lifecycleLock.notifyAll();}
    updateTitle();
  }

  void select(int next,boolean initial){
    next=constrain(next,0,modules.length-1);
    if(!initial&&next==activeTab&&desiredTab==next&&modules[next].phase==ModulePhase.READY)return;
    activeTab=next;
    modules[next].prepareRetry();
    synchronized(lifecycleLock){
      desiredTab=next;
      transitioning=ownedTab!=next;
      lifecycleLock.notifyAll();
    }
    updateTitle();
  }

  void updateTitle(){if(ready)surface.setTitle(activeTab<0?"SynKinect Studio":"SynKinect Studio — "+modules[activeTab].title());}

  void startLifecycle(){
    synchronized(lifecycleLock){if(lifecycleRun)return;lifecycleRun=true;}
    lifecycleThread=services.workers.start("Lifecycle",new Runnable(){public void run(){lifecycleLoop();}});
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
          if(next>=0){
            StudioModuleBase target=modules[next];
            target.initialize();
            if(target.phase==ModulePhase.READY){
              try{
                target.activateModule();
                ownedTab=next;
              }catch(Exception activationError){
                target.activationFailure(activationError);
                ownedTab=-1;
                try{target.deactivateModule();}catch(Exception cleanupError){println("Module activation cleanup warning ["+target.moduleTitleKey+"]: "+safeStudioMessage(cleanupError));}
                synchronized(lifecycleLock){if(desiredTab==next)desiredTab=-1;}
                println("Module activation failed ["+target.moduleTitleKey+"]: "+target.failureMessage);
                activationError.printStackTrace();
              }
            }else{
              ownedTab=-1;
              synchronized(lifecycleLock){if(desiredTab==next)desiredTab=-1;}
            }
          }else{
            ownedTab=-1;
          }
          transitionTarget=-1;
        }catch(Exception e){
          ownedTab=-1;
          synchronized(lifecycleLock){if(desiredTab==next)desiredTab=-1;}
          println("Studio tab transition warning: "+safeStudioMessage(e));e.printStackTrace();
        }
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
        try{if(modules[i].ownsResources())modules[i].disposeModule();}catch(Exception ignored){}finally{modules[i].markDisposed();}
      }
    }
  }
}



float homeContentWidth(){return min(width-48,1160);}
int homeModuleCols(){return width<700?1:(width<980?2:3);}
float homeModuleGap(){return max(8,14*studioUiScale());}
float homeModuleStartY(){return max(138,166*studioUiScale());}
float homeModuleCardH(){return constrain(86*studioUiScale(),62,92);}
float homeModuleCardW(){int cols=homeModuleCols();return (homeContentWidth()-homeModuleGap()*(cols-1))/cols;}
float homeModuleEndY(){int rows=(studio.modules.length+homeModuleCols()-1)/homeModuleCols();return homeModuleStartY()+rows*homeModuleCardH()+max(0,rows-1)*homeModuleGap();}

void drawStudioHome(){
  background(0xFF10151B);float cw=homeContentWidth(),cx=(width-cw)/2;
  fill(0xFFF4F7FA);textAlign(CENTER,TOP);textSize(responsiveFontSize(30));text("SynKinect Studio",width/2,42);
  fill(0xFF8FA2B4);studioText(15,false);String homeSub=studio.i18n.tr("home.subtitle");fitCurrentTextSize(homeSub,15,8,width-48,26);text(ellipsizeToWidth(homeSub,width-48),width/2,86);
  fill(0xFFAAB6C2);studioText(13,false);String homeDesc=studio.i18n.tr("home.description");fitCurrentTextSize(homeDesc,13,7,width-64,24);text(ellipsizeToWidth(homeDesc,width-64),width/2,114);
  int cols=homeModuleCols();float gap=homeModuleGap(),cardW=homeModuleCardW(),cardH=homeModuleCardH(),startY=homeModuleStartY();
  for(int i=0;i<studio.modules.length;i++){
    int row=i/cols,col=i%cols;float x=cx+col*(cardW+gap),y=startY+row*(cardH+gap);boolean hot=mouseX>=x&&mouseX<=x+cardW&&studio.contentMouseY()>=y&&studio.contentMouseY()<=y+cardH;
    stroke(hot?0xFF68A9E8:0xFF2D3945);fill(hot?0xFF1F2A34:0xFF171E25);rect(x,y,cardW,cardH,12);noStroke();fill(0xFFF4F7FA);textAlign(LEFT,TOP);studioText(16,true);String cardTitle=studio.modules[i].title();fitCurrentTextSize(cardTitle,16,8,cardW-32,24);text(ellipsizeToWidth(cardTitle,cardW-32),x+16,y+14);fill(0xFF91A0AE);studioText(11,false);text(homeModuleDescription(i),x+16,y+42,cardW-32,max(22,cardH-48));
  }
  float panelY=homeModuleEndY()+max(12,18*studioUiScale());studio.homeSystemPanel.draw(cx,panelY,cw,max(110,studio.contentHeight-panelY-34));
  fill(0xFF778897);textAlign(CENTER,TOP);textSize(responsiveFontSize(10));text(studio.i18n.tr("home.shortcuts"),width/2,studio.contentHeight-24);textAlign(LEFT,BASELINE);
}
String homeModuleDescription(int i){
  if(i==STUDIO_TAB_SCANNER)return studio.i18n.tr("home.scanner");if(i==STUDIO_TAB_ACOUSTIC)return studio.i18n.tr("home.acoustic");if(i==STUDIO_TAB_MICROPHONES)return studio.i18n.tr("home.microphones");if(i==STUDIO_TAB_SURVEILLANCE)return studio.i18n.tr("home.surveillance");return studio.i18n.tr("home.interactivity");
}
int homeCardAt(float mx,float my){float cw=homeContentWidth(),cx=(width-cw)/2;int cols=homeModuleCols();float gap=homeModuleGap(),cardW=homeModuleCardW(),cardH=homeModuleCardH(),startY=homeModuleStartY();for(int i=0;i<studio.modules.length;i++){int row=i/cols,col=i%cols;float x=cx+col*(cardW+gap),y=startY+row*(cardH+gap);if(mx>=x&&mx<=x+cardW&&my>=y&&my<=y+cardH)return i;}return -1;}

class StudioHomeSystemPanel {
  final String[] actions={"Install","Status","OpenCamera","Tilt","StartupTilt","IpStatus","IpReset","IpToggle","OpenStudio","Uninstall"};
  final UiRect[] buttons=new UiRect[actions.length];
  StudioHomeSystemPanel(){for(int i=0;i<buttons.length;i++)buttons[i]=new UiRect();}
  String label(String action){return studio.i18n.tr("system."+action.toLowerCase(Locale.ROOT));}
  void draw(float x,float y,float w,float availableH){
    fill(0xFFE7EDF3);textAlign(LEFT,TOP);studioText(15,true);text(studio.i18n.tr("system.title"),x,y);fill(0xFF8999A8);studioText(11,false);text(ellipsizeToWidth(studio.i18n.tr("system.description"),w),x,y+24);
    int cols=w>=940?5:(w>=620?3:2),rows=(actions.length+cols-1)/cols;float gap=max(6,9*studioUiScale()),top=y+48,bh=constrain((availableH-72-gap*(rows-1))/max(1,rows),28,40),bw=(w-gap*(cols-1))/cols;
    for(int i=0;i<actions.length;i++){int row=i/cols,col=i%cols;float bx=x+col*(bw+gap),by=top+row*(bh+gap);buttons[i].set(bx,by,bw,bh);boolean enabled=studio.systemControl.available(),hot=enabled&&buttons[i].hit(studio.contentMouseX(),studio.contentMouseY());stroke(hot?0xFF68A9E8:0xFF35414D);fill(enabled?(hot?0xFF263542:0xFF1A232B):0xFF14191E);rect(bx,by,bw,bh,8);noStroke();fill(enabled?0xFFE9F0F5:0xFF59636D);textAlign(CENTER,CENTER);studioText(11,true);String text=label(actions[i]);fitCurrentTextSize(text,11,7,bw-10,bh-6);text(ellipsizeToWidth(text,bw-10),bx+bw/2,by+bh/2);}
    fill(studio.systemControl.lastOk?0xFF7CC7A0:0xFFE4B86B);studioText(10,false);textAlign(LEFT,TOP);String state=studio.systemControl.message();text(ellipsizeToWidth(state,w),x,min(studio.contentHeight-42,top+rows*(bh+gap)+3));textAlign(LEFT,BASELINE);
  }
  String actionAt(float mx,float my){if(!studio.systemControl.available())return null;for(int i=0;i<buttons.length;i++)if(buttons[i].hit(mx,my))return actions[i];return null;}
}

class StudioSystemControl {
  volatile String lastMessage="";volatile boolean lastOk=true;volatile boolean controlResolved=false;volatile File controlScript=null;
  boolean supported(){return studio.services.transportFactory.isWindows()||studio.services.transportFactory.isLinux();}
  boolean available(){return supported()&&findControlScript()!=null;}
  String message(){if(lastMessage!=null&&lastMessage.length()>0)return lastMessage;if(!supported())return studio.i18n.tr("system.unsupported");if(findControlScript()==null)return studio.i18n.tr("system.not_found");return studio.i18n.tr("system.ready");}
  synchronized File findControlScript(){
    if(controlResolved)return controlScript;
    String[] rel=studio.services.transportFactory.isWindows()
      ?new String[]{"../../../drivers/windows/binaries/system/Kinect.ps1","../../../drivers/windows/source/install/Kinect.ps1","drivers/windows/binaries/system/Kinect.ps1","drivers/windows/source/install/Kinect.ps1","../../drivers/windows/source/install/Kinect.ps1"}
      :new String[]{"../../../drivers/linux/KINECT.sh","drivers/linux/KINECT.sh","../../drivers/linux/KINECT.sh"};
    for(String r:rel){try{File f=new File(sketchPath(r)).getCanonicalFile();if(f.isFile()){controlScript=f;break;}}catch(IOException ignored){}}
    controlResolved=true;return controlScript;
  }
  String psLiteral(String value){return "'"+(value==null?"":value.replace("'","''"))+"'";}
  String shQuote(String value){return "'"+(value==null?"":value.replace("'","'\\''"))+"'";}
  boolean commandAvailable(String name){
    String path=System.getenv("PATH");if(path==null||path.length()==0)return false;
    for(String dir:path.split(File.pathSeparator)){if(dir==null||dir.length()==0)continue;File f=new File(dir,name);if(f.isFile()&&f.canExecute())return true;}
    return false;
  }
  ProcessBuilder linuxTerminal(String command)throws IOException{
    if(commandAvailable("x-terminal-emulator"))return new ProcessBuilder("x-terminal-emulator","-e","bash","-lc",command);
    if(commandAvailable("gnome-terminal"))return new ProcessBuilder("gnome-terminal","--","bash","-lc",command);
    if(commandAvailable("konsole"))return new ProcessBuilder("konsole","-e","bash","-lc",command);
    if(commandAvailable("mate-terminal"))return new ProcessBuilder("mate-terminal","--","bash","-lc",command);
    if(commandAvailable("xterm"))return new ProcessBuilder("xterm","-e","bash","-lc",command);
    throw new IOException("No supported Linux terminal emulator was found (x-terminal-emulator, gnome-terminal, konsole, mate-terminal or xterm).");
  }
  void run(final String action){
    File script=findControlScript();if(!supported()){lastOk=false;lastMessage=studio.i18n.tr("system.unsupported");return;}if(script==null){lastOk=false;lastMessage=studio.i18n.tr("system.not_found");return;}
    lastOk=true;lastMessage=studio.i18n.format("system.started",studio.i18n.tr("system."+action.toLowerCase(Locale.ROOT)));final File target=script;
    studio.services.workers.startLowPriority("System-Control-"+action,new Runnable(){public void run(){try{
      if(studio.services.transportFactory.isWindows()){
        // Important: Studio never asks for elevation. Kinect.ps1 runs as the
        // ordinary user and raises UAC only for the selected machine-changing
        // operation (Install/Uninstall/IP service changes).
        String childArgs="@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',"+psLiteral(target.getAbsolutePath())+",'-Action',"+psLiteral(action)+")";
        String command="$a="+childArgs+"; Start-Process -FilePath 'powershell.exe' -ArgumentList $a";
        new ProcessBuilder("powershell.exe","-NoLogo","-NoProfile","-ExecutionPolicy","Bypass","-Command",command).directory(target.getParentFile()).start();
      }else{
        // Linux is identical in principle: the control panel is unprivileged;
        // sudo/pkexec is requested inside KINECT.sh only for system mutations.
        String command="REMOLD_GUI=1 bash "+shQuote(target.getAbsolutePath())+" --action "+shQuote(action)+"; rc=$?; printf '\\n'; read -r -p 'Press Enter to close: ' _ || true; exit $rc";
        linuxTerminal(command).directory(target.getParentFile()).start();
      }
    }catch(Exception e){lastOk=false;lastMessage=studio.i18n.format("system.failed",safeStudioMessage(e));}}});
  }
}

void drawModuleStartup(StudioModuleBase module){
  background(0xFF10151B);
  fill(0xFFF4F7FA);textAlign(CENTER,CENTER);textSize(responsiveFontSize(22));
  String title=module.title();
  fitCurrentTextSize(title,22,9,width-48,36);text(ellipsizeToWidth(title,width-48),width*0.5f,max(80,(height-STUDIO_TAB_H)*0.42f));
  fill(0xFFAAB6C2);textSize(responsiveFontSize(14));
  String message=(module.phase==ModulePhase.INIT_FAILED||module.phase==ModulePhase.ACTIVATE_FAILED)
    ? studio.i18n.format("startup.failed",module.failureMessage)
    : module.phase==ModulePhase.RENDER_FAILED
      ? studio.i18n.format("startup.render_failed",module.failureMessage)
      : studio.i18n.tr("startup.loading");
  fitCurrentTextSize(message,14,7,width-48,30);text(ellipsizeToWidth(message,width-48),width*0.5f,max(120,(height-STUDIO_TAB_H)*0.42f+42));
  textAlign(LEFT,BASELINE);
}

String safeStudioMessage(Throwable e){String m=e==null?null:e.getMessage();return m==null||m.length()==0?(e==null?"unknown":e.getClass().getSimpleName()):m;}

// One parsing policy for every Studio module. Invalid or missing values always
// resolve to the caller-provided default and bounded values are clamped here.
// File I/O errors are reported once here instead of being reimplemented by each module.
class ConfigRules {
  Properties load(File file,String scope){
    Properties p=new Properties();
    if(file==null||!file.isFile())return p;
    try(InputStream in=new FileInputStream(file);Reader reader=new InputStreamReader(in,java.nio.charset.StandardCharsets.UTF_8)){p.load(reader);}
    catch(IOException e){println(scope+"-config: "+safeStudioMessage(e));}
    return p;
  }
  String text(Properties p,String key,String fallback){String v=p==null?null:p.getProperty(key);return v==null||v.trim().isEmpty()?fallback:v.trim();}
  boolean flag(Properties p,String key,boolean fallback){
    String v=text(p,key,"");if(v.isEmpty())return fallback;
    if("true".equalsIgnoreCase(v)||"1".equals(v)||"yes".equalsIgnoreCase(v)||"on".equalsIgnoreCase(v))return true;
    if("false".equalsIgnoreCase(v)||"0".equals(v)||"no".equalsIgnoreCase(v)||"off".equalsIgnoreCase(v))return false;
    return fallback;
  }
  int integer(Properties p,String key,int fallback){try{return Integer.parseInt(text(p,key,String.valueOf(fallback)));}catch(NumberFormatException e){return fallback;}}
  int integer(Properties p,String key,int fallback,int lo,int hi){return Math.max(lo,Math.min(hi,integer(p,key,fallback)));}
  long longNumber(Properties p,String key,long fallback){return longNumber(text(p,key,String.valueOf(fallback)),fallback);}
  long longNumber(String value,long fallback){try{return Long.parseLong(value==null?"":value.trim());}catch(NumberFormatException e){return fallback;}}
  long longNumber(Properties p,String key,long fallback,long lo,long hi){long v=longNumber(p,key,fallback);return Math.max(lo,Math.min(hi,v));}
  float decimal(Properties p,String key,float fallback){try{return Float.parseFloat(text(p,key,String.valueOf(fallback)));}catch(NumberFormatException e){return fallback;}}
  float decimal(Properties p,String key,float fallback,float lo,float hi){return Math.max(lo,Math.min(hi,decimal(p,key,fallback)));}
  int even(Properties p,String key,int fallback,int lo,int hi){int v=integer(p,key,fallback,lo,hi);return (v&1)==0?v:Math.max(lo,v-1);}
  float[] decimalList(String value,int count){
    if(value==null)return null;String[] parts=value.split(",");if(parts.length!=count)return null;float[] out=new float[count];
    try{for(int i=0;i<count;i++)out[i]=Float.parseFloat(parts[i].trim());return out;}catch(NumberFormatException e){return null;}
  }
}

class StudioShellConfig {
  final ConfigRules rules;
  StudioShellConfig(ConfigRules rules){this.rules=rules;}
  String language="en-US";
  String languages="";
  int uiFrameRate=30,uiMinFrameRate=24,uiMaxFrameRate=60;
  float uiFontScale=1.10f;
  void load(File file){
    Properties p=rules.load(file,"studio");
    language=rules.text(p,"app.language",language);
    languages=rules.text(p,"app.languages",languages);
    uiMinFrameRate=rules.integer(p,"ui.minFrameRate",uiMinFrameRate,1,240);
    uiMaxFrameRate=rules.integer(p,"ui.maxFrameRate",uiMaxFrameRate,uiMinFrameRate,240);
    uiFrameRate=rules.integer(p,"ui.frameRate",uiFrameRate,uiMinFrameRate,uiMaxFrameRate);
    uiFontScale=rules.decimal(p,"ui.fontScale",uiFontScale,0.90f,1.35f);
  }
}

Properties loadStudioProperties(File file){return studio.services.configRules.load(file,"studio");}

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

UnifiedI18nCatalog studioCatalog(){return studio.services.catalog();}

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
  float sx=max(1,width)/1280.0f,sy=max(1,studio.contentHeight)/752.0f;
  // A resizable desktop app must be allowed to become genuinely compact.
  // Keep the scale floor low enough that controls shrink instead of overflowing.
  return constrain(min(sx,sy),0.72f,1.12f);
}
float responsiveFontSize(float base){
  float configured=studio==null||studio.config==null?1.10f:studio.config.uiFontScale;
  return max(8.0f,base*studioUiScale()*configured);
}
void fitCurrentTextSize(String value,float preferred,float minimum,float maxWidth,float maxHeight){
  float hi=responsiveFontSize(preferred),lo=max(7.0f,responsiveFontSize(minimum));
  if(value==null)value="";
  maxWidth=max(1,maxWidth);maxHeight=max(1,maxHeight);
  textSize(hi);
  if(textWidth(value)<=maxWidth&&textAscent()+textDescent()<=maxHeight)return;
  float best=lo,left=lo,right=hi;
  for(int i=0;i<8;i++){
    float mid=(left+right)*0.5f;textSize(mid);
    if(textWidth(value)<=maxWidth&&textAscent()+textDescent()<=maxHeight){best=mid;left=mid;}else right=mid;
  }
  textSize(best);
}
String ellipsizeToWidth(String value,float maxWidth){
  if(value==null)return "";
  if(maxWidth<=0)return "";
  if(textWidth(value)<=maxWidth)return value;
  String dots="…";if(maxWidth<=textWidth(dots))return dots;
  // Work in Unicode code points so truncation never splits surrogate pairs.
  int count=value.codePointCount(0,value.length()),lo=0,hi=count,best=0;
  while(lo<=hi){
    int mid=(lo+hi)>>>1;
    int end=value.offsetByCodePoints(0,mid);
    String candidate=value.substring(0,end)+dots;
    if(textWidth(candidate)<=maxWidth){best=mid;lo=mid+1;}else hi=mid-1;
  }
  return value.substring(0,value.offsetByCodePoints(0,best))+dots;
}

PVector exportReferenceCenter(){
  if(studio.scannerState.mesh!=null&&studio.scannerState.mesh.triangleCount()>0)return studio.scannerState.mesh.boundsCenter();
  if(studio.scannerState.volumeInitialized&&studio.scannerState.volume!=null&&studio.scannerState.volume.center!=null)return studio.scannerState.volume.center.copy();
  return new PVector(0,0,0.75f);
}

ExternalPhotoManager resolveExportPhotos(File destination){
  if(destination==null)return null;
  File folder=destination.getParentFile();
  if(folder==null)folder=new File(".");
  ExternalPhotoManager embeddedPhotos=new ExternalPhotoManager(studio.scannerState.i18n);
  embeddedPhotos.importFolder(folder,exportReferenceCenter(),studio.scannerState.config);
  return embeddedPhotos.cameras.isEmpty()?null:embeddedPhotos;
}

// ===== Shared local transport =====
class TransportEndpoint {
  final String windowsPath,linuxPath,label;
  TransportEndpoint(String windowsPath,String linuxPath,String label){this.windowsPath=windowsPath;this.linuxPath=linuxPath;this.label=label;}
}

class StudioEndpoints {
  final TransportEndpoint audio=new TransportEndpoint("\\\\.\\pipe\\Kinect360RemoldAudio","/run/kinect360-remold/audio.sock","audio");
  final String linuxAudioStatus="/run/kinect360-remold/audio-bridge-status.txt";
}

class WorkerFactory {
  Thread start(String role,Runnable task){return start(role,task,Thread.NORM_PRIORITY,true);}
  Thread startLowPriority(String role,Runnable task){return start(role,task,Thread.MIN_PRIORITY,true);}
  Thread startCritical(String role,Runnable task){return start(role,task,Thread.MIN_PRIORITY,false);}
  private Thread start(String role,Runnable task,int priority,boolean daemon){
    Thread worker=new Thread(task,"SynKinectStudio-"+role);
    worker.setPriority(priority);
    worker.setDaemon(daemon);
    worker.start();
    return worker;
  }
}

class LocalTransportFactory {
  enum HostPlatform { WINDOWS, LINUX, UNSUPPORTED }
  final HostPlatform platform=detectPlatform();
  HostPlatform detectPlatform(){String os=System.getProperty("os.name","").toLowerCase(Locale.ROOT);if(os.contains("linux"))return HostPlatform.LINUX;if(os.contains("windows"))return HostPlatform.WINDOWS;return HostPlatform.UNSUPPORTED;}
  boolean isLinux(){return platform==HostPlatform.LINUX;}
  boolean isWindows(){return platform==HostPlatform.WINDOWS;}
  LocalTransport openEndpoint(String endpoint)throws IOException {return open(endpoint,endpoint);}
  LocalTransport open(String windowsPath,String linuxPath)throws IOException {
    LocalTransport t=new LocalTransport();
    try{
      if(platform==HostPlatform.LINUX){
        t.unixChannel=SocketChannel.open(StandardProtocolFamily.UNIX);
        t.unixChannel.connect(UnixDomainSocketAddress.of(linuxPath));
        t.input=Channels.newInputStream(t.unixChannel);t.output=Channels.newOutputStream(t.unixChannel);
      }else if(platform==HostPlatform.WINDOWS){t.windowsPipe=new RandomAccessFile(windowsPath,"rw");}
      else throw new IOException("Unsupported host platform: "+System.getProperty("os.name","unknown"));
      return t;
    }catch(IOException e){try{t.close();}catch(IOException ignored){}throw e;}
  }
}

class LocalTransport implements Closeable {
  RandomAccessFile windowsPipe;
  SocketChannel unixChannel;
  InputStream input;
  OutputStream output;
  volatile boolean closed=false;

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
