class IcpTracker {
  AppConfig cfg;
  RigidTransform pose = new RigidTransform();
  PointCloud reference = null;
  boolean trackingGood = false;
  float rms = Float.POSITIVE_INFINITY;
  int matches = 0;
  PVector gravityReference = null;
  boolean motionPriorUsed = false;

  IcpTracker(AppConfig cfg){ this.cfg=cfg; }

  void reset(){ pose.setIdentity(); reference=null; trackingGood=false; rms=Float.POSITIVE_INFINITY; matches=0; gravityReference=null; motionPriorUsed=false; }

  RigidTransform track(PointCloud current, MotionSample motion) {
    if(reference==null || reference.size()<cfg.icpMinimumMatches) {
      pose.setIdentity();
      if(motion!=null && motion.gravityReliable()) gravityReference=motion.gravityUnit();
      reference=current.transformed(pose,cfg.icpMaxSamples);
      trackingGood=true; rms=0; matches=reference.size();
      return pose;
    }

    RigidTransform estimate=new RigidTransform(); estimate.set(pose);
    estimate=applyMotionPrior(estimate,motion);
    float finalRms=Float.POSITIVE_INFINITY; int finalMatches=0;

    SpatialHash hash=new SpatialHash(cfg.icpCellSizeM);
    for(PVector p:reference.points) hash.add(p);

    for(int iter=0;iter<cfg.icpIterations;iter++) {
      ArrayList<PVector> src=new ArrayList<PVector>();
      ArrayList<PVector> dst=new ArrayList<PVector>();
      int stride=max(1,current.size()/cfg.icpMaxSamples);
      float sum2=0;
      for(int i=0;i<current.size();i+=stride) {
        PVector world=estimate.apply(current.points.get(i));
        PVector near=hash.nearest(world,cfg.icpMaxDistanceM);
        if(near!=null){ src.add(world); dst.add(near); sum2+=PVector.sub(world,near).magSq(); }
      }
      if(src.size()<cfg.icpMinimumMatches) break;
      finalRms=sqrt(sum2/src.size()); finalMatches=src.size();
      RigidTransform correction=new QuaternionFit().fit(src,dst);
      estimate=correction.multiply(estimate);
    }

    rms=finalRms; matches=finalMatches;
    trackingGood = matches>=cfg.icpMinimumMatches && rms<cfg.icpGoodRmsM;
    if(trackingGood) {
      pose.set(estimate);
      reference=current.transformed(pose,cfg.icpMaxSamples);
    }
    return pose;
  }

  RigidTransform applyMotionPrior(RigidTransform estimate, MotionSample motion){
    motionPriorUsed=false;
    if(motion==null || !motion.gravityReliable()) return estimate;
    PVector g=motion.gravityUnit();
    if(g==null) return estimate;
    if(gravityReference==null){ gravityReference=g.copy(); return estimate; }

    PVector currentWorld=estimate.rotate(g);
    if(currentWorld.magSq()<1e-8f) return estimate;
    currentWorld.normalize();
    PVector target=gravityReference.copy(); target.normalize();
    RigidTransform correction=rotationBetween(currentWorld,target);
    RigidTransform corrected=correction.multiply(estimate);
    // Gravity corrects pitch/roll only. Keep ICP translation unchanged.
    corrected.m[3]=estimate.m[3]; corrected.m[7]=estimate.m[7]; corrected.m[11]=estimate.m[11];
    motionPriorUsed=true;
    return corrected;
  }

  RigidTransform rotationBetween(PVector from, PVector to){
    PVector a=from.copy(); PVector b=to.copy();
    if(a.magSq()<1e-8f || b.magSq()<1e-8f) return new RigidTransform();
    a.normalize(); b.normalize();
    float c=constrain(a.dot(b),-1.0f,1.0f);
    PVector axis=a.cross(b);
    float s=axis.mag();
    if(s<1e-6f){
      if(c>0) return new RigidTransform();
      axis=abs(a.x)<0.8f?a.cross(new PVector(1,0,0)):a.cross(new PVector(0,1,0));
      axis.normalize();
      return axisAngle(axis,PI);
    }
    axis.div(s);
    return axisAngle(axis,atan2(s,c));
  }

  RigidTransform axisAngle(PVector a,float angle){
    float x=a.x,y=a.y,z=a.z,c=cos(angle),ss=sin(angle),t=1-c;
    float[][] R={
      {t*x*x+c, t*x*y-ss*z, t*x*z+ss*y},
      {t*x*y+ss*z, t*y*y+c, t*y*z-ss*x},
      {t*x*z-ss*y, t*y*z+ss*x, t*z*z+c}
    };
    return new RigidTransform().fromRotationTranslation(R,new PVector());
  }

}
