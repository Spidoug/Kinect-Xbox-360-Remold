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
    return update(samples,SurveillanceProtocol.MODE_IR,cfg.motionIrDelta);
  }

  float detectRgb(int[] pixels,int w,int h){
    int step=cfg.motionSampleStep;int count=((w+step-1)/step)*((h+step-1)/step);int[] samples=new int[count];int n=0;
    for(int y=0;y<h;y+=step)for(int x=0;x<w;x+=step){int c=pixels[y*w+x];int r=(c>>16)&255,g=(c>>8)&255,bb=c&255;samples[n++]=(77*r+150*g+29*bb)>>8;}
    return update(samples,SurveillanceProtocol.MODE_RGB,cfg.motionRgbDelta);
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
