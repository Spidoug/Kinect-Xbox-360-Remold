class AcousticUI {
  float resetX,resetY,resetW=126,langX,langY,langW=72,buttonH=38;

  void draw(AcousticAudioFrame frame,AcousticScanFrame scan){drawHeader();drawStatus(frame,scan);drawBody(frame,scan);}

  void drawHeader(){
    fill(AcousticTheme.TEXT);acousticText(AcousticTheme.FONT_TITLE,true);textAlign(LEFT,CENTER);
    text(acousticI18n.tr("app.title"),AcousticTheme.MARGIN,AcousticTheme.HEADER_H/2);textAlign(LEFT,BASELINE);
    langX=width-AcousticTheme.MARGIN-langW;langY=15;
    resetX=langX-AcousticTheme.GAP-resetW;resetY=15;
    button(resetX,resetY,resetW,buttonH,acousticI18n.tr("button.reset"),false);
    button(langX,langY,langW,buttonH,acousticI18n.shortLanguage(),false);
  }

  void drawStatus(AcousticAudioFrame frame,AcousticScanFrame scan){
    float x=AcousticTheme.MARGIN,y=AcousticTheme.HEADER_H+AcousticTheme.GAP,w=width-2*AcousticTheme.MARGIN,h=112;card(x,y,w,h);cardTitle(x,y,w,acousticI18n.tr("panel.status"));
    String state=acousticSource==null?"source.starting":acousticSource.displayStateKey();String transport=acousticI18n.tr(state);if(acousticSource!=null&&acousticSource.connected)transport+=" · "+acousticI18n.tr(acousticSource.pipeModeKey());
    float ix=x+12,iy=y+AcousticTheme.CARD_TITLE_H,innerW=w-24,g=10,tw=(innerW-g*4)/5.0f,th=h-AcousticTheme.CARD_TITLE_H-12;
    metric(ix,iy,tw,th,acousticI18n.tr("label.transport"),transport,acousticSource!=null&&acousticSource.connected);
    metric(ix+(tw+g),iy,tw,th,acousticI18n.tr("label.frames"),String.valueOf(acousticSource==null?0:acousticSource.frameCount),true);
    metric(ix+2*(tw+g),iy,tw,th,acousticI18n.tr("label.azimuth"),scan==null?"—":nf(scan.azimuthDeg,1,1)+"°",scan!=null);
    metric(ix+3*(tw+g),iy,tw,th,acousticI18n.tr("label.confidence"),scan==null?"—":nf(scan.confidence*100,1,1)+"%",scan!=null);
    metric(ix+4*(tw+g),iy,tw,th,acousticI18n.tr("label.mode"),acousticI18n.tr("mode.passive"),true);
  }

  void drawBody(AcousticAudioFrame frame,AcousticScanFrame scan){
    float x=AcousticTheme.MARGIN,y=AcousticTheme.HEADER_H+AcousticTheme.GAP+112+AcousticTheme.GAP,w=width-2*AcousticTheme.MARGIN,h=height-y-AcousticTheme.MARGIN;
    float rightW=max(330,w*0.30f),leftW=w-rightW-AcousticTheme.GAP;
    drawRadar(x,y,leftW,h,scan);
    drawMicLevels(x+leftW+AcousticTheme.GAP,y,rightW,h,frame);
  }

  void drawRadar(float x,float y,float w,float h,AcousticScanFrame scan){
    card(x,y,w,h);cardTitle(x,y,w,acousticI18n.tr("panel.radar"));
    float cx=x+w/2,cy=y+h-48,maxR=min(w*0.44f,(h-AcousticTheme.CARD_TITLE_H-40)*0.94f);stroke(AcousticTheme.GRID);noFill();
    for(int r=1;r<=4;r++)arc(cx,cy,maxR*r/2,maxR*r/2,PI,TWO_PI);
    for(int a=-90;a<=90;a+=30){float t=radians(a);line(cx,cy,cx+maxR*sin(t),cy-maxR*cos(t));}
    fill(AcousticTheme.MUTED);acousticText(AcousticTheme.FONT_TINY,false);textAlign(CENTER,CENTER);
    for(int a=-90;a<=90;a+=30){float t=radians(a);text(a+"°",cx+(maxR+18)*sin(t),cy-(maxR+18)*cos(t));}
    if(scan!=null){
      noStroke();fill(AcousticTheme.ACTIVE,42);beginShape();vertex(cx,cy);
      for(int i=0;i<scan.occupancy.length;i++){float t=radians(-90+i),r=maxR*(0.18f+0.82f*constrain(scan.occupancy[i]*5,0,1));vertex(cx+r*sin(t),cy-r*cos(t));}
      vertex(cx,cy);endShape(CLOSE);float t=radians(scan.azimuthDeg);stroke(AcousticTheme.ACTIVE);strokeWeight(2);line(cx,cy,cx+maxR*sin(t),cy-maxR*cos(t));noStroke();fill(AcousticTheme.TEXT);ellipse(cx+maxR*0.82f*sin(t),cy-maxR*0.82f*cos(t),10,10);
    }
    fill(AcousticTheme.MUTED);textAlign(LEFT,TOP);acousticText(AcousticTheme.FONT_SMALL,false);text(acousticI18n.tr("radar.note"),x+14,y+AcousticTheme.CARD_TITLE_H+8);textAlign(LEFT,BASELINE);
    String status=scan==null?acousticI18n.tr("status.waiting"):acousticI18n.format("status.scan",scan.azimuthDeg,scan.rms,scan.confidence*100);
    fill(AcousticTheme.MUTED);acousticText(AcousticTheme.FONT_SMALL,false);text(ellipsize(status,max(40,(int)(w/7))),x+14,y+h-18);
  }

  void drawMicLevels(float x,float y,float w,float h,AcousticAudioFrame frame){
    card(x,y,w,h);cardTitle(x,y,w,acousticI18n.tr("panel.microphones"));float top=y+AcousticTheme.CARD_TITLE_H+12,rowH=max(52,(h-AcousticTheme.CARD_TITLE_H-24)/4.0f);
    for(int ch=0;ch<4;ch++){
      float yy=top+ch*rowH,peak=frame==null?0:frame.peak[ch];
      fill(AcousticTheme.MUTED);acousticText(AcousticTheme.FONT_SMALL,false);text(acousticI18n.format("label.mic",ch+1),x+16,yy+14);
      fill(AcousticTheme.TEXT);textAlign(RIGHT,BASELINE);text(nf(peak*100,1,1)+"%",x+w-16,yy+14);textAlign(LEFT,BASELINE);
      float bx=x+16,by=yy+24,bw=w-32;fill(AcousticTheme.GRID);rect(bx,by,bw,9,4.5f);fill(AcousticTheme.ACTIVE);rect(bx,by,bw*constrain(peak,0,1),9,4.5f);
    }
  }

  void card(float x,float y,float w,float h){stroke(AcousticTheme.BORDER);strokeWeight(1);fill(AcousticTheme.SURFACE);rect(x,y,w,h,AcousticTheme.RADIUS);noStroke();}
  void cardTitle(float x,float y,float w,String title){fill(AcousticTheme.TEXT);acousticText(AcousticTheme.FONT_SMALL,true);textAlign(LEFT,CENTER);text(title,x+14,y+AcousticTheme.CARD_TITLE_H/2);textAlign(LEFT,BASELINE);}
  void metric(float x,float y,float w,float h,String label,String value,boolean active){fill(AcousticTheme.SURFACE2);rect(x,y,w,h,9);fill(active?AcousticTheme.ACTIVE:AcousticTheme.MUTED);ellipse(x+12,y+15,6,6);fill(AcousticTheme.MUTED);acousticText(AcousticTheme.FONT_TINY,false);text(label,x+22,y+19);fill(AcousticTheme.TEXT);acousticText(AcousticTheme.FONT_SMALL,true);text(ellipsize(value,max(12,(int)(w/8))),x+10,y+h-13);}
  void button(float x,float y,float w,float h,String label,boolean primary){boolean hot=mouseX>=x&&mouseX<=x+w&&mouseY>=y&&mouseY<=y+h;stroke(hot?AcousticTheme.ACTIVE:AcousticTheme.BORDER);fill(primary?AcousticTheme.RAISED:AcousticTheme.SURFACE2);rect(x,y,w,h,9);noStroke();fill(primary?AcousticTheme.TEXT:(hot?AcousticTheme.TEXT:AcousticTheme.MUTED));textAlign(CENTER,CENTER);acousticText(AcousticTheme.FONT_SMALL,true);text(label,x+w/2,y+h/2);textAlign(LEFT,BASELINE);}
  void handleMouse(float mx,float my){if(hit(mx,my,resetX,resetY,resetW,buttonH))resetAcousticMap();else if(hit(mx,my,langX,langY,langW,buttonH))toggleAcousticLanguage();}
  boolean hit(float mx,float my,float x,float y,float w,float h){return mx>=x&&mx<=x+w&&my>=y&&my<=y+h;}
  String ellipsize(String s,int n){if(s==null)return "";return s.length()<=n?s:s.substring(0,max(0,n-1))+"…";}
}
