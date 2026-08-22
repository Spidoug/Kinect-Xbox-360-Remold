import java.io.*;
import java.nio.*;
import java.net.*;
import java.nio.channels.*;
import java.util.*;

AcousticConfig acousticConfig;
AcousticI18n acousticI18n;
AcousticSource acousticSource;
AcousticEngine acousticEngine;
AcousticUI acousticUi;
AcousticScanFrame acousticScan;
long lastProcessedFrame=-1;

void settings(){size(AcousticTheme.WINDOW_W,AcousticTheme.WINDOW_H,P2D);}

void setup(){
  acousticConfig=new AcousticConfig();
  acousticConfig.load(new File(dataPath("acoustic.properties")));
  frameRate(acousticConfig.uiFrameRate);
  acousticI18n=new AcousticI18n(acousticConfig.language);
  surface.setTitle(acousticI18n.tr("app.title"));
  initializeAcousticTypography();
  surface.setResizable(true);
  acousticEngine=new AcousticEngine(acousticConfig);
  acousticSource=new AcousticSource(acousticConfig);
  acousticUi=new AcousticUI();
  acousticSource.start();
}

void draw(){
  background(AcousticTheme.BG);
  AcousticAudioFrame frame=acousticSource==null?null:acousticSource.snapshot();
  if(frame!=null&&frame.frameNumber!=lastProcessedFrame){
    lastProcessedFrame=frame.frameNumber;
    acousticScan=acousticEngine.process(frame);
  }
  acousticUi.draw(frame,acousticScan);
}

void mousePressed(){if(acousticUi!=null)acousticUi.handleMouse(mouseX,mouseY);}
void keyPressed(){
  if(key=='r'||key=='R')resetAcousticMap();
  else if(key=='g'||key=='G')toggleAcousticLanguage();
}
void resetAcousticMap(){if(acousticEngine!=null)acousticEngine.reset();acousticScan=null;}
void toggleAcousticLanguage(){acousticI18n.toggle();surface.setTitle(acousticI18n.tr("app.title"));}
void dispose(){if(acousticSource!=null)acousticSource.stop();}
