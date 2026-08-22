import java.io.*;
import java.nio.*;
import java.net.*;
import java.nio.channels.*;
import java.util.*;
import java.util.concurrent.*;
import java.text.SimpleDateFormat;
import javax.imageio.*;
import javax.imageio.stream.*;
import javax.imageio.plugins.jpeg.JPEGImageWriteParam;
import java.awt.image.BufferedImage;

SurveillanceConfig config;
SurveillanceI18n i18n;
SurveillanceSource source;
MotionDetector motionDetector;
MotionAviRecorder recorder;
SurveillanceUI ui;

PImage latestView;
PImage latestRgb;
PImage latestIr;
volatile String appStatus = "";
volatile boolean armed = true;
volatile boolean recording = false;
volatile long lastMotionMs = 0;
volatile float motionScore = 0;
volatile long recordingStartedMs = 0;
volatile boolean recordingInIr = false;
volatile float rgbLuminance = -1;
volatile long lastFrameEpochMs = 0;
int rgbFramesSeen = 0;
int darkRgbFrames = 0;

void settings() { size(SurveillanceTheme.WINDOW_WIDTH, SurveillanceTheme.WINDOW_HEIGHT, P2D); }

void setup() {
  config = new SurveillanceConfig();
  config.load(new File(dataPath("surveillance.properties")));
  frameRate(config.uiFrameRate);
  i18n = new SurveillanceI18n(config.language);
  initializeSurveillanceTypography();
  surface.setTitle(i18n.tr("app.title"));
  surface.setResizable(true);
  motionDetector = new MotionDetector(config);
  recorder = new MotionAviRecorder(config);
  ui = new SurveillanceUI();
  appStatus = i18n.tr("status.connecting");

  try {
    source = new SurveillanceSource(config, i18n);
    source.start(SurveillanceProtocol.STREAM_IR_DEPTH);
    appStatus = i18n.tr("status.armed_ir");
  } catch (Exception e) {
    appStatus = i18n.format("status.init_failed", safeMessage(e));
    println(appStatus);
  }
}

void draw() {
  background(SurveillanceTheme.BG);
  consumeFrames();
  serviceRecordingTimeout();
  serviceRecordingHealth();
  ui.draw();
}

void consumeFrames() {
  if (source == null) return;
  source.updateLiveness();
  SurveillanceVideoFrame f = source.pollVideo();
  if (f == null) return;
  long epochMs=System.currentTimeMillis();lastFrameEpochMs=epochMs;

  if (f.mode == SurveillanceProtocol.MODE_IR) {
    latestIr = ir16ToImage(f.payload, f.width, f.height);
    latestView = latestIr;
    motionScore = motionDetector.detectIr(f.payload, f.width, f.height);
    if(recording){
      if(latestIr!=null)recorder.submit(latestIr,recordingInIr?"IR LOW-LIGHT":"IR",epochMs);
      if(motionDetector.moving())lastMotionMs=millis64();
    }else if(armed && motionDetector.triggered()) startMotionRecording();
  } else if (f.mode == SurveillanceProtocol.MODE_RGB) {
    latestRgb = nv12ToImage(f.payload, f.width, f.height);
    latestView = latestRgb;
    motionScore = latestRgb == null ? 0 : motionDetector.detectRgb(latestRgb.pixels, latestRgb.width, latestRgb.height);
    if (recording && latestRgb != null) {
      rgbLuminance=measureRgbLuminance(latestRgb);
      recorder.submit(latestRgb,"RGB",epochMs);
      if (motionDetector.moving()) lastMotionMs = millis64();
      serviceLowLightDecision();
    }
  }
}

float measureRgbLuminance(PImage image){
  if(image==null||image.pixels==null||image.pixels.length==0)return -1;long sum=0,count=0;int step=max(1,config.lowLightSampleStep);
  for(int y=0;y<image.height;y+=step)for(int x=0;x<image.width;x+=step){int c=image.pixels[y*image.width+x];int r=(c>>16)&255,g=(c>>8)&255,b=c&255;sum+=(77*r+150*g+29*b)>>8;count++;}
  return count==0?-1:(float)sum/count;
}

void serviceLowLightDecision(){
  if(!recording||recordingInIr||!config.lowLightFallbackEnabled||rgbLuminance<0)return;
  rgbFramesSeen++;if(rgbLuminance<=config.lowLightLumaThreshold)darkRgbFrames++;else darkRgbFrames=0;
  if(rgbFramesSeen>=config.lowLightWarmupFrames&&darkRgbFrames>=config.lowLightDarkFrames)fallbackRecordingToIr();
}

void fallbackRecordingToIr(){
  if(!recording||recordingInIr)return;recordingInIr=true;motionDetector.reset();if(recorder!=null)recorder.markLowLightFallback(rgbLuminance);if(source!=null)source.requestStreams(SurveillanceProtocol.STREAM_IR_DEPTH);appStatus=i18n.format("status.recording_ir_low_light",rgbLuminance);
}


void startMotionRecording() {
  if (recording || recorder == null) return;
  try {
    recorder.startSession(latestIr);
    recording = true;
    recordingInIr=false;rgbFramesSeen=0;darkRgbFrames=0;rgbLuminance=-1;
    recordingStartedMs = millis64();
    lastMotionMs = recordingStartedMs;
    motionDetector.reset();
    source.requestStreams(SurveillanceProtocol.STREAM_RGB_DEPTH);
    appStatus = i18n.tr("status.recording_rgb");
  } catch (Exception e) {
    appStatus = i18n.format("status.record_failed", safeMessage(e));
    recording = false;
  }
}

void stopMotionRecording(boolean timeout) {
  if (!recording) return;
  recording = false;
  recordingInIr=false;rgbFramesSeen=0;darkRgbFrames=0;rgbLuminance=-1;
  if (recorder != null) recorder.stopSession();
  motionDetector.reset();
  if (source != null) source.requestStreams(SurveillanceProtocol.STREAM_IR_DEPTH);
  appStatus = i18n.tr(timeout ? "status.record_stopped_idle" : "status.record_stopped_manual");
}

void serviceRecordingTimeout() {
  if (!recording) return;
  long now = millis64();
  if (now - lastMotionMs >= config.motionStopAfterMs) stopMotionRecording(true);
}


void serviceRecordingHealth() {
  if (!recording || recorder == null || !recorder.hasFailed()) return;
  String message = recorder.failureMessage();
  recording = false;
  recordingInIr = false;
  rgbFramesSeen = 0;
  darkRgbFrames = 0;
  rgbLuminance = -1;
  recorder.stopSession();
  motionDetector.reset();
  if (source != null) source.requestStreams(SurveillanceProtocol.STREAM_IR_DEPTH);
  appStatus = i18n.format("status.record_runtime_failed", message.length()==0?"unknown error":message);
}

void toggleArmed() {
  armed = !armed;
  if (!armed && recording) stopMotionRecording(false);
  appStatus = i18n.tr(armed ? "status.armed_ir" : "status.disarmed");
}

void manualRecord() {
  if (!recording) startMotionRecording();
}

void toggleLanguage() {
  i18n.toggle();
  surface.setTitle(i18n.tr("app.title"));
}

void mousePressed() { ui.handleMouse(mouseX, mouseY); }
void keyPressed() {
  if (key == 'a' || key == 'A') toggleArmed();
  else if (key == 'r' || key == 'R') manualRecord();
  else if (key == 's' || key == 'S') stopMotionRecording(false);
  else if (key == 'l' || key == 'L') toggleLanguage();
}

void exit() {
  if (recording) stopMotionRecording(false);
  if (recorder != null) recorder.shutdown();
  if (source != null) source.stop();
  super.exit();
}

String formatSurveillanceTimestamp(long epochMs){
  try{return new SimpleDateFormat(config==null?"yyyy-MM-dd HH:mm:ss":config.timestampFormat,Locale.ROOT).format(new Date(epochMs));}
  catch(Exception e){return new SimpleDateFormat("yyyy-MM-dd HH:mm:ss",Locale.ROOT).format(new Date(epochMs));}
}
long millis64() { return System.nanoTime() / 1000000L; }
String safeMessage(Exception e) { String m=e.getMessage(); return (m==null||m.length()==0)?e.getClass().getSimpleName():m; }
