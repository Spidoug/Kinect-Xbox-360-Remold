import java.io.*;
import java.nio.*;
import java.net.*;
import java.nio.channels.*;
import java.text.SimpleDateFormat;
import java.util.*;
import javax.sound.sampled.*;

MicrophoneConfig config;
MicrophoneI18n micI18n;
AudioPipeline audioPipeline;
MicrophoneSource microphones;
BridgeDiagnostics bridgeDiagnostics;
MicrophoneUI ui;

void settings(){size(MicrophoneTheme.WINDOW_W,MicrophoneTheme.WINDOW_H);}

void setup(){
  config=new MicrophoneConfig();config.load(new File(dataPath("microphones.properties")));
  frameRate(config.uiFrameRate);
  micI18n=new MicrophoneI18n(config.language);surface.setTitle(micI18n.tr("app.title"));
  initializeMicrophoneTypography();
  surface.setResizable(true);
  audioPipeline=new AudioPipeline(config);bridgeDiagnostics=new BridgeDiagnostics(config);microphones=new MicrophoneSource(config,audioPipeline);ui=new MicrophoneUI();microphones.start();
}

void draw(){background(MicrophoneTheme.BG);bridgeDiagnostics.refresh();ui.draw(microphones==null?null:microphones.snapshot());}

void mousePressed(){if(ui!=null)ui.handleMousePressed(mouseX,mouseY);}
void keyPressed(){
  if(key=='r'||key=='R')toggleRecording();
  else if(key=='m'||key=='M')toggleMonitor();
  else if(key=='p'||key=='P')togglePlayback();
  else if(key=='t'||key=='T')toggleSpeakerTest();
  else if(key=='g'||key=='G')toggleMicrophoneLanguage();
}

void dispatchMicrophoneAction(int action){
  switch(action){
    case MicrophoneUI.ACTION_RECORD:toggleRecording();break;
    case MicrophoneUI.ACTION_MONITOR:toggleMonitor();break;
    case MicrophoneUI.ACTION_PLAY:togglePlayback();break;
    case MicrophoneUI.ACTION_TEST:toggleSpeakerTest();break;
    case MicrophoneUI.ACTION_LANGUAGE:toggleMicrophoneLanguage();break;
  }
}

void toggleRecording(){
  if(audioPipeline.recorder.isRecording()){audioPipeline.recorder.stop();return;}
  File directory=new File(sketchPath(config.recordingsDirectory));
  if(!directory.exists()&&!directory.mkdirs()){audioPipeline.recorder.setError("mkdir");return;}
  String stamp=new SimpleDateFormat("yyyyMMdd-HHmmss",Locale.ROOT).format(new Date());
  audioPipeline.recorder.start(new File(directory,config.recordingPrefix+"-"+stamp+"-4ch-s32.wav"));
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

void toggleMicrophoneLanguage(){micI18n.toggle();surface.setTitle(micI18n.tr("app.title"));}
void dispose(){if(microphones!=null)microphones.stop();if(audioPipeline!=null)audioPipeline.stop();}
