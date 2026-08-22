class SurveillanceUI {
  final UiRect armButton=new UiRect(),recordButton=new UiRect(),stopButton=new UiRect(),languageButton=new UiRect();

  void draw(){
    drawHeader();
    float m=SurveillanceTheme.MARGIN,g=SurveillanceTheme.GAP;
    float top=SurveillanceTheme.HEADER_H+g,bottom=height-SurveillanceTheme.FOOTER_H-m,bodyH=max(360,bottom-top-g);
    float sideW=max(330,min(430,width*0.30f)),viewW=width-2*m-g-sideW,sideX=m+viewW+g;
    drawVideoPanel(m,top,viewW,bodyH);
    drawStatusPanel(sideX,top,sideW,bodyH);
    drawButtons(m,bottom,width-2*m,SurveillanceTheme.FOOTER_H);
  }

  void drawHeader(){
    fill(SurveillanceTheme.TEXT);surveillanceText(SurveillanceTheme.FONT_TITLE,true);textAlign(i18n.startAlign(),CENTER);
    text(i18n.tr("app.title"),i18n.rtl?width-SurveillanceTheme.MARGIN:SurveillanceTheme.MARGIN,SurveillanceTheme.HEADER_H/2);
    String mode=recording?(recordingInIr?i18n.tr("badge.recording_ir"):i18n.tr("badge.recording_rgb")):(armed?i18n.tr("badge.armed"):i18n.tr("badge.disarmed"));
    float bw=190,bx=width-SurveillanceTheme.MARGIN-bw;drawChip(bx,18,bw,32,mode,recording||armed);
    textAlign(LEFT,BASELINE);
  }

  void drawVideoPanel(float x,float y,float w,float h){
    card(x,y,w,h);String panel=source!=null&&source.irMode()?i18n.tr("panel.ir"):i18n.tr("panel.rgb");cardTitle(x,y,w,panel);
    float px=x+12,py=y+SurveillanceTheme.CARD_TITLE_H,pw=w-24,ph=h-SurveillanceTheme.CARD_TITLE_H-12;preview(px,py,pw,ph);
  }

  void preview(float x,float y,float w,float h){
    noStroke();fill(SurveillanceTheme.PREVIEW);rect(x,y,w,h,10);
    if(latestView==null){fill(SurveillanceTheme.MUTED);textAlign(CENTER,CENTER);surveillanceText(SurveillanceTheme.FONT_BODY,false);text(i18n.tr("waiting.video"),x+w/2,y+h/2);textAlign(LEFT,BASELINE);drawTimestampOverlay(x,y,w,h);return;}
    float s=min(w/latestView.width,h/latestView.height);float dw=latestView.width*s,dh=latestView.height*s,ix=x+(w-dw)/2,iy=y+(h-dh)/2;image(latestView,ix,iy,dw,dh);
    if(recording){noStroke();fill(SurveillanceTheme.BAD);ellipse(ix+22,iy+22,12,12);fill(SurveillanceTheme.TEXT);surveillanceText(SurveillanceTheme.FONT_SMALL,true);text(i18n.tr("overlay.rec"),ix+36,iy+27);}
    if(recordingInIr){drawChip(ix+12,iy+42,156,28,i18n.tr("overlay.low_light_ir"),true);}
    drawTimestampOverlay(ix,iy,dw,dh);
  }

  void drawTimestampOverlay(float x,float y,float w,float h){
    if(config==null||!config.timestampEnabled)return;long epoch=lastFrameEpochMs>0?lastFrameEpochMs:System.currentTimeMillis();String stamp=formatSurveillanceTimestamp(epoch);String mode=(source!=null&&source.irMode())?"IR":"RGB";String value=mode+"  ·  "+stamp;
    surveillanceText(SurveillanceTheme.FONT_SMALL,true);float tw=textWidth(value)+20,th=32;float bx=x+w-config.timestampMargin-tw,by=y+h-config.timestampMargin-th;bx=max(x+config.timestampMargin,bx);by=max(y+config.timestampMargin,by);
    noStroke();fill(0,178);rect(bx,by,tw,th,8);fill(SurveillanceTheme.TEXT);textAlign(CENTER,CENTER);text(value,bx+tw/2,by+th/2);textAlign(LEFT,BASELINE);
  }

  void drawStatusPanel(float x,float y,float w,float h){
    card(x,y,w,h);cardTitle(x,y,w,i18n.tr("panel.status"));float px=x+14,py=y+SurveillanceTheme.CARD_TITLE_H+4,innerW=w-28,rowH=55;
    statusTile(px,py,innerW,rowH,i18n.tr("label.state"),recording?i18n.tr("state.recording"):(armed?i18n.tr("state.armed"):i18n.tr("state.disarmed")),recording||armed);py+=rowH+8;
    statusTile(px,py,innerW,rowH,i18n.tr("label.video"),source==null?"—":(source.irMode()?"IR":"RGB"),source!=null&&source.videoConnected);py+=rowH+8;
    statusTile(px,py,innerW,rowH,i18n.tr("label.ir_projector"),source!=null&&source.projectorActive()?i18n.tr("state.on"):i18n.tr("state.off"),source!=null&&source.projectorActive());py+=rowH+8;
    statusTile(px,py,innerW,rowH,i18n.tr("label.motion"),nf(motionScore*100,1,2)+"%",motionScore>=config.motionMinimumChangedRatio);py+=rowH+8;
    String luma=rgbLuminance<0?"—":nf(rgbLuminance,1,1)+" / 255";statusTile(px,py,innerW,rowH,i18n.tr("label.luminance"),luma,rgbLuminance<0||rgbLuminance>config.lowLightLumaThreshold);py+=rowH+8;
    statusTile(px,py,innerW,rowH,i18n.tr("label.frames"),source==null?"0":String.valueOf(source.videoFrames),source!=null&&source.videoFrames>0);py+=rowH+12;
    fill(SurveillanceTheme.MUTED);surveillanceText(SurveillanceTheme.FONT_TINY,true);text(i18n.tr("label.status"),px,py+12);py+=24;
    String message=source!=null&&source.lastError.length()>0?source.lastError:appStatus;fill(source!=null&&source.lastError.length()>0?SurveillanceTheme.WARN:SurveillanceTheme.TEXT);surveillanceText(SurveillanceTheme.FONT_SMALL,false);text(ellipsize(message,max(42,(int)(innerW/7))),px,py,innerW,max(54,h-(py-y)-16));
  }

  void statusTile(float x,float y,float w,float h,String label,String value,boolean active){
    noStroke();fill(SurveillanceTheme.SURFACE_ALT);rect(x,y,w,h,9);fill(active?SurveillanceTheme.ACCENT:SurveillanceTheme.MUTED);ellipse(x+13,y+15,6,6);
    fill(SurveillanceTheme.MUTED);surveillanceText(SurveillanceTheme.FONT_TINY,false);text(label,x+23,y+19);fill(SurveillanceTheme.TEXT);surveillanceText(SurveillanceTheme.FONT_METRIC,true);text(ellipsize(value,max(14,(int)(w/10))),x+11,y+h-12);
  }

  void drawButtons(float x,float y,float w,float h){
    card(x,y,w,h);float gap=10,bw=(w-gap*3-24)/4.0f,bh=h-24,bx=x+12,by=y+12;
    armButton.set(bx,by,bw,bh);recordButton.set(bx+bw+gap,by,bw,bh);stopButton.set(bx+2*(bw+gap),by,bw,bh);languageButton.set(bx+3*(bw+gap),by,bw,bh);
    button(armButton,armed?i18n.tr("button.disarm"):i18n.tr("button.arm"),true,true);button(recordButton,i18n.tr("button.record"),!recording,true);button(stopButton,i18n.tr("button.stop"),recording,false);button(languageButton,i18n.tr("button.language")+" · "+i18n.shortLanguage(),true,false);
  }

  void button(UiRect r,String label,boolean enabled,boolean primary){boolean hot=enabled&&r.hit(mouseX,mouseY);stroke(hot?SurveillanceTheme.ACCENT:SurveillanceTheme.BORDER);fill(enabled?(primary?SurveillanceTheme.SURFACE_RAISED:SurveillanceTheme.SURFACE_ALT):SurveillanceTheme.BG);rect(r.x,r.y,r.w,r.h,9);noStroke();fill(enabled?SurveillanceTheme.TEXT:SurveillanceTheme.BORDER);textAlign(CENTER,CENTER);surveillanceText(SurveillanceTheme.FONT_SMALL,true);text(label,r.x+r.w/2,r.y+r.h/2);textAlign(LEFT,BASELINE);}
  void drawChip(float x,float y,float w,float h,String label,boolean active){noStroke();fill(active?SurveillanceTheme.SURFACE_RAISED:SurveillanceTheme.SURFACE_ALT);rect(x,y,w,h,h/2);fill(active?SurveillanceTheme.ACCENT:SurveillanceTheme.MUTED);textAlign(CENTER,CENTER);surveillanceText(SurveillanceTheme.FONT_TINY,true);text(label,x+w/2,y+h/2);textAlign(LEFT,BASELINE);}
  void handleMouse(float mx,float my){if(armButton.hit(mx,my))toggleArmed();else if(recordButton.hit(mx,my)&&!recording)manualRecord();else if(stopButton.hit(mx,my)&&recording)stopMotionRecording(false);else if(languageButton.hit(mx,my))toggleLanguage();}
  void card(float x,float y,float w,float h){stroke(SurveillanceTheme.BORDER);strokeWeight(1);fill(SurveillanceTheme.SURFACE);rect(x,y,w,h,SurveillanceTheme.RADIUS);noStroke();}
  void cardTitle(float x,float y,float w,String s){fill(SurveillanceTheme.TEXT);surveillanceText(SurveillanceTheme.FONT_SMALL,true);textAlign(i18n.startAlign(),CENTER);text(s,i18n.rtl?x+w-14:x+14,y+SurveillanceTheme.CARD_TITLE_H/2);textAlign(LEFT,BASELINE);}
  String ellipsize(String s,int n){if(s==null)return "";return s.length()<=n?s:s.substring(0,max(0,n-1))+"…";}
}
class UiRect{float x,y,w,h;void set(float x,float y,float w,float h){this.x=x;this.y=y;this.w=w;this.h=h;}boolean hit(float px,float py){return px>=x&&px<=x+w&&py>=y&&py<=y+h;}}
