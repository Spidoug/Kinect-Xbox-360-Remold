class ScannerUI {
  static final int ACTION_START=0, ACTION_PAUSE=1, ACTION_RESET=2, ACTION_MESH=3, ACTION_PHOTOS=4;
  static final int ACTION_STL=5, ACTION_OBJ=6, ACTION_PLY=7, ACTION_CLEAN=8, ACTION_SMOOTH=9, ACTION_CENTER=10, ACTION_UNDO=11, ACTION_LANGUAGE=12;
  static final int BUTTON_NORMAL=0, BUTTON_PRIMARY=1, BUTTON_QUIET=2;

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
    exportGroup.add(button("button.photos", ACTION_PHOTOS, BUTTON_NORMAL));
    exportGroup.add(button("button.stl", ACTION_STL, BUTTON_NORMAL));
    exportGroup.add(button("button.obj", ACTION_OBJ, BUTTON_NORMAL));
    exportGroup.add(button("button.ply", ACTION_PLY, BUTTON_NORMAL));

    UiActionGroup view = group("group.view");
    view.add(button("button.language", ACTION_LANGUAGE, BUTTON_QUIET));
  }

  UiActionGroup group(String key) { UiActionGroup g=new UiActionGroup(key); groups.add(g); return g; }
  UiButton button(String key,int action,int style) { UiButton b=new UiButton(key,action,style); buttons.add(b); return b; }

  void draw() {
    drawHeader();
    float m=UiTheme.MARGIN, gap=UiTheme.GAP;
    float top=UiTheme.HEADER_H+UiTheme.GAP;
    float toolbarY=height-UiTheme.TOOLBAR_H-UiTheme.MARGIN;
    float bodyH=max(360, toolbarY-top-UiTheme.GAP);
    float sideW=min(UiTheme.SIDEBAR_W,max(330,width*0.275f));
    float mainX=m+sideW+gap, mainW=width-mainX-m;

    float rgbH=max(210,bodyH*0.43f);
    drawRgbCard(m,top,sideW,rgbH);
    drawDepthCard(m,top+rgbH+gap,sideW,bodyH-rgbH-gap);
    drawReconstructionCard(mainX,top,mainW,bodyH);
    drawToolbar(m,toolbarY,width-2*m,UiTheme.TOOLBAR_H);
  }

  void drawHeader() {
    noStroke(); fill(UiTheme.BG); rect(0,0,width,UiTheme.HEADER_H);
    fill(UiTheme.ACCENT_SOFT); rect(0,UiTheme.HEADER_H-2,width,2);
    textAlign(i18n.startAlign(),CENTER); uiText(UiTheme.FONT_TITLE,true); fill(UiTheme.TEXT);
    float tx=i18n.rtl?width-UiTheme.MARGIN:UiTheme.MARGIN;
    text(i18n.tr("app.title"),tx,UiTheme.HEADER_H*0.5f);

    float x=width-UiTheme.MARGIN-56;
    drawChip(x,18,56,30,i18n.shortLanguage(),true,UiTheme.ACCENT); x-=58;
    boolean depth=kinectSource!=null&&kinectSource.depthConnected;
    boolean rgb=kinectSource!=null&&kinectSource.colorConnected;
    boolean port=kinectSource!=null&&kinectSource.portReady;
    drawStateDot(x,33,"D",depth); x-=42;
    drawStateDot(x,33,"R",rgb); x-=42;
    drawStateDot(x,33,"P",port);
    textAlign(LEFT,BASELINE);
  }

  void drawStateDot(float x,float y,String label,boolean active) {
    noStroke(); fill(active?UiTheme.ACCENT:UiTheme.BORDER); ellipse(x,y,8,8);
    fill(UiTheme.TEXT_MUTED); textAlign(CENTER,CENTER); uiText(UiTheme.FONT_TINY,true); text(label,x+14,y); textAlign(LEFT,BASELINE);
  }

  void drawRgbCard(float x,float y,float w,float h) {
    card(x,y,w,h); cardTitle(x,y,w,i18n.tr("panel.rgb"));
    float px=x+10, py=y+UiTheme.CARD_TITLE_H, pw=w-20, ph=max(80,h-UiTheme.CARD_TITLE_H-42);
    previewSurface(px,py,pw,ph);
    if(colorPreview!=null) imageFit(colorPreview,px,py,pw,ph); else drawWaiting(px,py,pw,ph,i18n.tr("waiting.rgb"));
    boolean rgb=kinectSource!=null&&kinectSource.colorConnected;
    drawCompactFooter(x,y,w,h,i18n.tr("chip.rgb"),rgb,rgbFooterValue());
  }

  String rgbFooterValue(){
    String frames=kinectSource==null?"0":String.valueOf(kinectSource.colorFrames);
    if(Float.isNaN(latestRgbDepthSkewMs))return frames;
    String value=frames+"  ·  "+i18n.tr("chip.sync")+" "+nf(latestRgbDepthSkewMs,1,1)+" ms";
    if(rgbRegistration!=null&&(abs(rgbRegistration.autoOffsetX)>0.05f||abs(rgbRegistration.autoOffsetY)>0.05f))
      value+="  ·  Δxy "+nf(rgbRegistration.autoOffsetX,1,1)+","+nf(rgbRegistration.autoOffsetY,1,1);
    return value;
  }

  void drawDepthCard(float x,float y,float w,float h) {
    card(x,y,w,h); cardTitle(x,y,w,i18n.tr("panel.depth"));
    float footerH=64;
    float px=x+10,py=y+UiTheme.CARD_TITLE_H,pw=w-20,ph=max(90,h-UiTheme.CARD_TITLE_H-footerH-8);
    previewSurface(px,py,pw,ph);
    if(depthPreview!=null) imageFit(depthPreview,px,py,pw,ph); else drawWaiting(px,py,pw,ph,i18n.tr("waiting.depth"));

    boolean depthOk=kinectSource!=null&&kinectSource.depthConnected;
    boolean metric=latestDepth!=null&&latestDepth.deviceCalibrated;
    float fy=py+ph+9;
    miniState(x+10,fy,76,i18n.tr("chip.depth"),depthOk);
    miniState(x+92,fy,92,i18n.tr("chip.metric"),metric);
    if(latestDepth!=null&&latestDepth.transportRecovered) miniState(x+190,fy,102,i18n.tr("state.recovered"),false);

    String value="—";
    if(latestDepthDiagnostics!=null&&latestDepthDiagnostics.plausiblePixels>0)
      value=nf(latestDepthDiagnostics.medianMm/1000.0f,1,2)+" m  ·  "+nf(latestDepthDiagnostics.plausibleRatio*100.0f,1,1)+"%";
    fill(UiTheme.TEXT_MUTED); uiText(UiTheme.FONT_SMALL,false); textAlign(i18n.startAlign(),CENTER);
    text(value,i18n.rtl?x+w-10:x+10,y+h-16); textAlign(LEFT,BASELINE);
  }

  void drawCompactFooter(float x,float y,float w,float h,String label,boolean active,String value) {
    float cy=y+h-20;
    noStroke(); fill(active?UiTheme.ACCENT:UiTheme.BORDER); ellipse(x+16,cy,7,7);
    fill(UiTheme.TEXT_MUTED); uiText(UiTheme.FONT_SMALL,false); textAlign(LEFT,CENTER); text(label+"  "+value,x+27,cy); textAlign(LEFT,BASELINE);
  }

  void miniState(float x,float y,float w,String label,boolean active) {
    noStroke(); fill(UiTheme.SURFACE_ALT); rect(x,y,w,24,7);
    fill(active?UiTheme.ACCENT:UiTheme.TEXT_MUTED); ellipse(x+11,y+12,6,6);
    fill(UiTheme.TEXT_MUTED); uiText(UiTheme.FONT_TINY,false); textAlign(LEFT,CENTER); text(label,x+20,y+12); textAlign(LEFT,BASELINE);
  }

  void drawReconstructionCard(float x,float y,float w,float h) {
    card(x,y,w,h); cardTitle(x,y,w,i18n.tr("panel.reconstruction"));
    float statsH=128;
    previewX=x+10; previewY=y+UiTheme.CARD_TITLE_H; previewW=w-20; previewH=max(220,h-UiTheme.CARD_TITLE_H-statsH-10);
    previewSurface(previewX,previewY,previewW,previewH);
    draw3DPreview(previewX,previewY,previewW,previewH);
    drawPreviewOverlay(previewX,previewY,previewW,previewH);
    drawStatusArea(x+10,previewY+previewH+8,w-20,statsH);
  }

  void drawPreviewOverlay(float x,float y,float w,float h) {
    boolean complete=false; synchronized(reconstructionStateLock){ complete=scanCoverage!=null&&scanCoverage.complete; }
    String scanState=complete?i18n.tr("scan.complete"):(scanActive?(scanPaused?i18n.tr("scan.paused"):i18n.tr("scan.active")):i18n.tr("scan.idle"));
    drawChip(x+w-132,y+10,122,28,scanState,scanActive&&!scanPaused,UiTheme.ACCENT);
    fill(UiTheme.TEXT_MUTED); uiText(UiTheme.FONT_TINY,false); textAlign(LEFT,CENTER); text(i18n.tr("hint.orbit.short"),x+12,y+24); textAlign(LEFT,BASELINE);
  }

  void drawStatusArea(float x,float y,float w,float h) {
    noStroke(); fill(UiTheme.SURFACE_ALT); rect(x,y,w,h,10);
    float progress; String targetMetric,icpMetric; long integratedMetric;
    synchronized(reconstructionStateLock){
      progress=scanCoverage==null?0:constrain(scanCoverage.progress(),0,1);
      targetMetric=targetValue(); icpMetric=icpValue(); integratedMetric=integratedFrames;
    }
    float barX=x+12,barY=y+12,barW=w-24;
    fill(UiTheme.BORDER); rect(barX,barY,barW,6,3);
    fill(UiTheme.ACCENT); rect(barX,barY,barW*progress,6,3);

    float ty=y+34, gap=10, tw=(w-24-gap*3)/4.0f;
    metricTile(x+12,ty,tw,60,i18n.tr("label.target"),targetMetric);
    metricTile(x+12+(tw+gap),ty,tw,60,i18n.tr("label.icp"),icpMetric);
    metricTile(x+12+2*(tw+gap),ty,tw,60,i18n.tr("label.integrated"),String.valueOf(integratedMetric));
    metricTile(x+12+3*(tw+gap),ty,tw,60,i18n.tr("label.progress"),nf(progress*100,1,0)+"%");

    String sourceStatus=kinectSource==null?"":kinectSource.displayError();
    String message=sourceStatus.length()>0?sourceStatus:appStatus;
    if(message==null||message.length()==0) message=i18n.tr("status.ready");
    fill(sourceStatus.length()>0?UiTheme.WARN:UiTheme.TEXT_MUTED); ellipse(x+15,y+h-15,6,6);
    fill(UiTheme.TEXT_MUTED); uiText(UiTheme.FONT_TINY,false); textAlign(LEFT,CENTER); text(ellipsize(message,118),x+25,y+h-15); textAlign(LEFT,BASELINE);
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
    noStroke(); fill(UiTheme.SURFACE_RAISED); rect(x,y,w,h,8);
    fill(UiTheme.TEXT_MUTED); uiText(UiTheme.FONT_TINY,true); textAlign(CENTER,CENTER); text(label,x+w/2,y+15);
    fill(UiTheme.TEXT); uiText(UiTheme.FONT_METRIC,true); text(value,x+w/2,y+36); textAlign(LEFT,BASELINE);
  }

  void drawToolbar(float x,float y,float w,float h) {
    float[] weights={0.23f,0.36f,0.29f,0.12f};
    float gap=UiTheme.GAP, cx=x;
    for(int i=0;i<groups.size();i++) {
      float gw=(i==groups.size()-1)?x+w-cx:w*weights[i]-gap*(groups.size()-1)/groups.size();
      drawActionPanel(groups.get(i),cx,y,gw,h);
      cx+=gw+gap;
    }
  }

  void drawActionPanel(UiActionGroup group,float x,float y,float w,float h) {
    card(x,y,w,h);
    fill(UiTheme.TEXT_MUTED); uiText(UiTheme.FONT_TINY,true); textAlign(LEFT,CENTER); text(i18n.tr(group.labelKey),x+10,y+17); textAlign(LEFT,BASELINE);
    float bx=x+9, by=y+31, gap=6, bh=h-40;
    int count=max(1,group.items.size()); float bw=(w-18-gap*(count-1))/count;
    for(int i=0;i<group.items.size();i++) {
      UiButton item=group.items.get(i);
      item.setBounds(bx+i*(bw+gap),by,bw,bh);
      item.draw();
    }
  }

  void card(float x,float y,float w,float h) { stroke(UiTheme.BORDER); strokeWeight(1); fill(UiTheme.SURFACE); rect(x,y,w,h,UiTheme.RADIUS); noStroke(); }
  void cardTitle(float x,float y,float w,String title) {
    fill(UiTheme.TEXT); uiText(UiTheme.FONT_SMALL,true); textAlign(i18n.startAlign(),CENTER);
    text(title,i18n.rtl?x+w-12:x+12,y+UiTheme.CARD_TITLE_H*0.5f); textAlign(LEFT,BASELINE);
  }
  void previewSurface(float x,float y,float w,float h) { noStroke(); fill(UiTheme.PREVIEW); rect(x,y,w,h,9); }
  void drawWaiting(float x,float y,float w,float h,String message) { fill(UiTheme.TEXT_MUTED); textAlign(CENTER,CENTER); uiText(UiTheme.FONT_BODY,false); text(message,x+w/2,y+h/2); textAlign(LEFT,BASELINE); }
  void imageFit(PImage img,float x,float y,float w,float h) {
    if(img==null||img.width<=0||img.height<=0)return;
    float s=min(w/img.width,h/img.height),dw=img.width*s,dh=img.height*s; image(img,x+(w-dw)/2,y+(h-dh)/2,dw,dh);
  }

  void draw3DPreview(float x,float y,float w,float h) {
    pushMatrix(); clip((int)x,(int)y,(int)w,(int)h); translate(x+w/2,y+h/2,0); lights();
    float scalePx=max(1,min(w,h)*0.88f); scale(scalePx*previewZoom); rotateX(previewPitch); rotateY(previewYaw); translate(0,0,-0.75f);
    strokeWeight(1.0f/scalePx); stroke(UiTheme.GRID); noFill(); box(0.6f);
    // Mesh objects are immutable after publication. Rendering must never hold
    // the fusion-state lock: retained PShape chunks keep large meshes cheap.
    Mesh3D renderMesh=mesh;
    if(renderMesh!=null&&renderMesh.triangleCount()>0) renderMesh.drawMesh(UiTheme.MESH);
    else {
      PointCloud ref=null;synchronized(reconstructionStateLock){if(volumeInitialized&&tracker!=null)ref=tracker.reference;}
      if(ref!=null){stroke(UiTheme.ACCENT);strokeWeight(1.7f/scalePx);beginShape(POINTS);for(PVector p:ref.points)vertex(p.x,p.y,p.z);endShape();}
    }
    resetMatrix(); noClip(); popMatrix();
  }

  void drawChip(float x,float y,float w,float h,String label,boolean active,int tint) {
    noStroke(); fill(active?UiTheme.SURFACE_RAISED:UiTheme.SURFACE_ALT); rect(x,y,w,h,h/2);
    fill(active?tint:UiTheme.TEXT_MUTED); textAlign(CENTER,CENTER); uiText(UiTheme.FONT_TINY,true); text(label,x+w/2,y+h/2); textAlign(LEFT,BASELINE);
  }

  String ellipsize(String s,int limit) { if(s==null)return ""; return s.length()<=limit?s:s.substring(0,max(0,limit-1))+"…"; }
  boolean isOver3D(float mx,float my){ return mx>=previewX&&mx<=previewX+previewW&&my>=previewY&&my<=previewY+previewH; }
  boolean handleMousePressed(float mx,float my){ for(UiButton b:buttons) if(b.hit(mx,my)&&b.enabled()){ b.fire(); return true; } return false; }
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
  String label(){ if(action==ScannerUI.ACTION_PAUSE&&scanActive&&scanPaused)return i18n.tr("button.resume"); return i18n.tr(labelKey); }
  boolean enabled(){
    if(meshBusy&&(action==ScannerUI.ACTION_START||action==ScannerUI.ACTION_RESET||action==ScannerUI.ACTION_MESH||action==ScannerUI.ACTION_CLEAN||action==ScannerUI.ACTION_SMOOTH||action==ScannerUI.ACTION_CENTER||action==ScannerUI.ACTION_UNDO||action==ScannerUI.ACTION_STL||action==ScannerUI.ACTION_OBJ||action==ScannerUI.ACTION_PLY))return false;
    if(action==ScannerUI.ACTION_PAUSE)return scanActive;
    if(action==ScannerUI.ACTION_MESH)return volumeInitialized;
    if(action==ScannerUI.ACTION_CLEAN||action==ScannerUI.ACTION_SMOOTH||action==ScannerUI.ACTION_CENTER)return mesh!=null&&mesh.triangleCount()>0;
    if(action==ScannerUI.ACTION_UNDO)return meshUndo!=null;
    if(action==ScannerUI.ACTION_STL||action==ScannerUI.ACTION_OBJ||action==ScannerUI.ACTION_PLY)return volumeInitialized||(mesh!=null&&mesh.triangleCount()>0);
    return true;
  }
  void draw(){
    boolean en=enabled(),hot=en&&hit(mouseX,mouseY);
    int base=style==ScannerUI.BUTTON_PRIMARY?UiTheme.SURFACE_RAISED:UiTheme.SURFACE_ALT;
    if(style==ScannerUI.BUTTON_QUIET)base=UiTheme.SURFACE;
    stroke(hot?UiTheme.ACCENT:UiTheme.BORDER); strokeWeight(1); fill(en?(hot?UiTheme.SURFACE_RAISED:base):UiTheme.BG); rect(x,y,w,h,8); noStroke();
    fill(en?(style==ScannerUI.BUTTON_PRIMARY?UiTheme.TEXT:UiTheme.TEXT_MUTED):UiTheme.BORDER); textAlign(CENTER,CENTER); uiText(UiTheme.FONT_SMALL,true); text(label(),x+w/2,y+h/2); textAlign(LEFT,BASELINE);
  }
  boolean hit(float mx,float my){return mx>=x&&mx<=x+w&&my>=y&&my<=y+h;}
  void fire(){dispatchUiAction(action);}
}
