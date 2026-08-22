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
    int count = ScannerProtocol.WIDTH * ScannerProtocol.HEIGHT;
    rayX = new float[count]; rayY = new float[count];
    for (int v=0; v<ScannerProtocol.HEIGHT; v++) for (int u=0; u<ScannerProtocol.WIDTH; u++) {
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
      int i=v*ScannerProtocol.WIDTH+u; rayX[i]=x; rayY[i]=y;
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
    long skewUs=Math.abs(frame.timestampUs-rgb.timestampUs);
    lastSyncSkewMs=skewUs/1000.0f;
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
