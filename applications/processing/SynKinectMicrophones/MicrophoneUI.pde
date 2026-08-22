class MicrophoneUI {
  static final int ACTION_RECORD=0,ACTION_MONITOR=1,ACTION_PLAY=2,ACTION_TEST=3,ACTION_LANGUAGE=4;
  final ArrayList<MicButton> buttons=new ArrayList<MicButton>();

  MicrophoneUI(){
    buttons.add(new MicButton("button.record",ACTION_RECORD,true));
    buttons.add(new MicButton("button.monitor",ACTION_MONITOR,false));
    buttons.add(new MicButton("button.play",ACTION_PLAY,false));
    buttons.add(new MicButton("button.test",ACTION_TEST,false));
    buttons.add(new MicButton("button.language",ACTION_LANGUAGE,false));
  }

  void draw(MicrophoneFrame frame){
    drawHeader();
    float m=MicrophoneTheme.MARGIN,g=MicrophoneTheme.GAP;
    float statusY=MicrophoneTheme.HEADER_H+g;
    drawTransportPanel(m,statusY,width-2*m,MicrophoneTheme.STATUS_H);
    float controlsY=height-MicrophoneTheme.CONTROLS_H-m;
    float gridY=statusY+MicrophoneTheme.STATUS_H+g;
    float gridH=controlsY-gridY-g;
    drawMicrophoneGrid(m,gridY,width-2*m,gridH,frame);
    drawControls(m,controlsY,width-2*m,MicrophoneTheme.CONTROLS_H);
  }

  void drawHeader(){
    fill(MicrophoneTheme.BG);noStroke();rect(0,0,width,MicrophoneTheme.HEADER_H);
    fill(MicrophoneTheme.TEXT);micText(MicrophoneTheme.FONT_TITLE,true);textAlign(micI18n.startAlign(),CENTER);
    text(micI18n.tr("app.title"),micI18n.rtl?width-MicrophoneTheme.MARGIN:MicrophoneTheme.MARGIN,MicrophoneTheme.HEADER_H/2);
    drawPill(width-MicrophoneTheme.MARGIN-52,14,52,28,micI18n.shortLanguage(),true);
    textAlign(LEFT,BASELINE);
  }

  void drawTransportPanel(float x,float y,float w,float h){
    card(x,y,w,h);
    fill(MicrophoneTheme.TEXT);micText(MicrophoneTheme.FONT_SMALL,true);textAlign(LEFT,CENTER);text(micI18n.tr("panel.transport"),x+12,y+17);textAlign(LEFT,BASELINE);
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
    noStroke();fill(MicrophoneTheme.SURFACE_ALT);rect(x,y,w,h,8);
    fill(active?MicrophoneTheme.ACTIVE:MicrophoneTheme.DIM);ellipse(x+12,y+14,6,6);
    fill(MicrophoneTheme.MUTED);micText(MicrophoneTheme.FONT_TINY,false);textAlign(LEFT,CENTER);text(label,x+22,y+14);
    fill(MicrophoneTheme.TEXT);micText(MicrophoneTheme.FONT_SMALL,true);text(ellipsize(value,28),x+10,y+h-15);textAlign(LEFT,BASELINE);
  }

  void drawMicrophoneGrid(float x,float y,float w,float h,MicrophoneFrame frame){
    float gap=MicrophoneTheme.GAP,cw=(w-gap)/2.0f,ch=(h-gap)/2.0f;
    for(int mic=0;mic<MicrophoneProtocol.CHANNELS;mic++){
      int col=mic%2,row=mic/2;drawMicrophoneCard(x+col*(cw+gap),y+row*(ch+gap),cw,ch,mic,frame);
    }
  }

  void drawMicrophoneCard(float x,float y,float w,float h,int mic,MicrophoneFrame frame){
    card(x,y,w,h);boolean valid=frame!=null&&frame.channelValid(mic);float peak=valid?frame.peak[mic]:0;
    fill(valid?MicrophoneTheme.ACTIVE:MicrophoneTheme.DIM);ellipse(x+14,y+17,7,7);
    fill(MicrophoneTheme.MUTED);micText(MicrophoneTheme.FONT_SMALL,false);textAlign(LEFT,CENTER);text(micI18n.tr("label.mic")+" "+(mic+1),x+25,y+17);
    fill(MicrophoneTheme.TEXT);textAlign(RIGHT,CENTER);micText(MicrophoneTheme.FONT_SMALL,true);text(valid?nf(peak*100,1,1)+"%":"—",x+w-12,y+17);textAlign(LEFT,BASELINE);

    float meterX=x+12,meterY=y+31,meterW=w-24;fill(MicrophoneTheme.GRID);noStroke();rect(meterX,meterY,meterW,5,2.5f);fill(valid?MicrophoneTheme.ACTIVE:MicrophoneTheme.DIM);rect(meterX,meterY,meterW*constrain(peak,0,1),5,2.5f);
    float wx=x+12,wy=y+47,ww=w-24,wh=h-59;fill(MicrophoneTheme.PREVIEW);rect(wx,wy,ww,wh,8);stroke(MicrophoneTheme.GRID);line(wx,wy+wh/2,wx+ww,wy+wh/2);
    if(!valid)return;
    stroke(MicrophoneTheme.ACTIVE);noFill();beginShape();
    for(int i=0;i<MicrophoneProtocol.SAMPLES;i++){
      float sx=map(i,0,MicrophoneProtocol.SAMPLES-1,wx+4,wx+ww-4);float normalized=constrain(frame.samples[mic][i]/2147483648.0f,-1,1);float sy=wy+wh/2-normalized*wh*0.43f;vertex(sx,sy);
    }
    endShape();
  }

  void drawControls(float x,float y,float w,float h){
    float gap=MicrophoneTheme.GAP;
    float captureW=w*0.38f,playW=w*0.38f,systemW=w-captureW-playW-gap*2;
    drawActionGroup(x,y,captureW,h,micI18n.tr("panel.capture"),new int[]{ACTION_RECORD,ACTION_MONITOR});
    drawActionGroup(x+captureW+gap,y,playW,h,micI18n.tr("panel.playback"),new int[]{ACTION_PLAY,ACTION_TEST});
    drawActionGroup(x+captureW+playW+gap*2,y,systemW,h,micI18n.tr("panel.system"),new int[]{ACTION_LANGUAGE});
  }

  void drawActionGroup(float x,float y,float w,float h,String title,int[] actions){
    card(x,y,w,h);fill(MicrophoneTheme.TEXT);micText(MicrophoneTheme.FONT_TINY,true);textAlign(LEFT,CENTER);text(title,x+10,y+17);textAlign(LEFT,BASELINE);
    float bx=x+9,by=y+31,gap=7,bh=42,bw=(w-18-gap*(actions.length-1))/actions.length;
    for(int i=0;i<actions.length;i++){MicButton b=findButton(actions[i]);if(b!=null){b.setBounds(bx+i*(bw+gap),by,bw,bh);b.draw();}}
    String status=groupStatus(actions);fill(MicrophoneTheme.MUTED);micText(MicrophoneTheme.FONT_TINY,false);textAlign(LEFT,CENTER);text(ellipsize(status,max(16,(int)(w/7))),x+10,y+h-15);textAlign(LEFT,BASELINE);
  }

  String groupStatus(int[] actions){
    if(containsAction(actions,ACTION_RECORD)){
      if(audioPipeline.recorder.isRecording())return micI18n.format("status.recording",formatBytes(audioPipeline.recorder.bytes()));
      if(audioPipeline.monitor.isRunning())return micI18n.format("status.monitor",audioPipeline.monitor.dominantMic+1,nf(audioPipeline.monitor.automaticGain,1,1));
      String key=audioPipeline.recorder.state();return micI18n.tr(key);
    }
    if(containsAction(actions,ACTION_PLAY)){
      if(audioPipeline.player.isRunning())return micI18n.format("status.playback",audioPipeline.player.fileName);
      if(audioPipeline.selfTest.isRunning())return micI18n.format("status.speaker",config.speakerFrequencyHz);
      String key=!"playback.idle".equals(audioPipeline.player.state())?audioPipeline.player.state():audioPipeline.selfTest.state();
      return micI18n.tr(key);
    }
    return micI18n.tr(bridgeDiagnostics.stateKey())+" · "+bridgeDiagnostics.compactCounters();
  }

  boolean containsAction(int[] actions,int action){for(int a:actions)if(a==action)return true;return false;}
  MicButton findButton(int action){for(MicButton b:buttons)if(b.action==action)return b;return null;}
  boolean handleMousePressed(float mx,float my){for(MicButton b:buttons)if(b.hit(mx,my)){b.fire();return true;}return false;}
  void card(float x,float y,float w,float h){stroke(MicrophoneTheme.BORDER);strokeWeight(1);fill(MicrophoneTheme.SURFACE);rect(x,y,w,h,MicrophoneTheme.RADIUS);noStroke();}
  void drawPill(float x,float y,float w,float h,String textValue,boolean active){noStroke();fill(active?MicrophoneTheme.RAISED:MicrophoneTheme.SURFACE_ALT);rect(x,y,w,h,h/2);fill(active?MicrophoneTheme.TEXT:MicrophoneTheme.MUTED);textAlign(CENTER,CENTER);micText(MicrophoneTheme.FONT_TINY,true);text(textValue,x+w/2,y+h/2);textAlign(LEFT,BASELINE);}
  String formatCount(long value){if(value>=1000000)return nf(value/1000000.0f,1,1)+"M";if(value>=1000)return nf(value/1000.0f,1,1)+"k";return String.valueOf(value);}
  String formatBytes(long value){if(value>=1024L*1024L)return nf(value/(1024.0f*1024.0f),1,1)+" MB";if(value>=1024)return nf(value/1024.0f,1,1)+" KB";return value+" B";}
  String ellipsize(String s,int limit){if(s==null)return "";return s.length()<=limit?s:s.substring(0,max(0,limit-1))+"…";}
}

class MicButton {
  float x,y,w,h;final String labelKey;final int action;final boolean primary;
  MicButton(String key,int action,boolean primary){labelKey=key;this.action=action;this.primary=primary;}
  void setBounds(float x,float y,float w,float h){this.x=x;this.y=y;this.w=w;this.h=h;}
  boolean active(){return action==MicrophoneUI.ACTION_RECORD?audioPipeline.recorder.isRecording():action==MicrophoneUI.ACTION_MONITOR?audioPipeline.monitor.isRunning():action==MicrophoneUI.ACTION_PLAY?audioPipeline.player.isRunning():action==MicrophoneUI.ACTION_TEST?audioPipeline.selfTest.isRunning():false;}
  String label(){if(active()&&action!=MicrophoneUI.ACTION_LANGUAGE)return micI18n.tr("button.stop");return micI18n.tr(labelKey);}
  void draw(){boolean hot=hit(mouseX,mouseY),on=active();stroke(hot?MicrophoneTheme.ACTIVE:MicrophoneTheme.BORDER);fill(on||primary?MicrophoneTheme.RAISED:MicrophoneTheme.SURFACE_ALT);rect(x,y,w,h,8);noStroke();fill(on||hot?MicrophoneTheme.TEXT:MicrophoneTheme.MUTED);textAlign(CENTER,CENTER);micText(MicrophoneTheme.FONT_SMALL,true);text(label(),x+w/2,y+h/2);textAlign(LEFT,BASELINE);}
  boolean hit(float mx,float my){return mx>=x&&mx<=x+w&&my>=y&&my<=y+h;}
  void fire(){dispatchMicrophoneAction(action);}
}
