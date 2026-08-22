class ScanCoverageTracker {
  final AppConfig cfg;
  PVector gravityReference = null;
  PVector previousHeading = null;
  float directionProbeDeg = 0;
  int direction = 0;
  float sweepDeg = 0;
  float imuDeviationDeg = 0;
  boolean imuStable = true;
  boolean objectDetected = false;
  boolean complete = false;

  ScanCoverageTracker(AppConfig cfg){ this.cfg=cfg; }

  void reset(){
    gravityReference=null; previousHeading=null; directionProbeDeg=0; direction=0;
    sweepDeg=0; imuDeviationDeg=0; imuStable=true; objectDetected=false; complete=false;
  }

  void updateDetection(boolean detected){ objectDetected=detected; }

  void update(RigidTransform pose, MotionSample motion){
    updateImu(motion);
    if(pose==null || complete) return;
    PVector axis = gravityReference==null ? new PVector(0,1,0) : gravityReference.copy();
    if(axis.magSq()<1e-8f) axis.set(0,1,0);
    axis.normalize();

    PVector heading=pose.rotate(new PVector(0,0,1));
    heading.sub(PVector.mult(axis,heading.dot(axis)));
    if(heading.magSq()<1e-8f) return;
    heading.normalize();
    if(previousHeading==null){ previousHeading=heading; return; }

    float dot=constrain(previousHeading.dot(heading),-1.0f,1.0f);
    float signed=degrees(atan2(axis.dot(previousHeading.cross(heading)),dot));
    previousHeading=heading;
    if(abs(signed)<cfg.scanRotationDeadbandDeg || abs(signed)>cfg.scanRotationMaxStepDeg) return;

    if(direction==0){
      directionProbeDeg+=signed;
      if(abs(directionProbeDeg)>=cfg.scanDirectionLockDeg){
        direction=directionProbeDeg>=0?1:-1;
        sweepDeg=abs(directionProbeDeg);
      }
    }else{
      sweepDeg=max(0,sweepDeg+direction*signed);
    }
    if(sweepDeg>=cfg.scanCompleteDeg){ sweepDeg=min(cfg.scanFullTurnDeg,sweepDeg); complete=true; }
  }

  void updateImu(MotionSample motion){
    if(motion==null || !motion.gravityReliable()){ imuStable=true; imuDeviationDeg=0; return; }
    PVector g=motion.gravityUnit();
    if(g==null) return;
    if(gravityReference==null){ gravityReference=g.copy(); imuStable=true; imuDeviationDeg=0; return; }
    float c=constrain(gravityReference.dot(g),-1.0f,1.0f);
    imuDeviationDeg=degrees(acos(c));
    imuStable=imuDeviationDeg<=cfg.scanMaxSensorTiltDriftDeg;
  }

  float progress(){ return complete ? 1.0f : constrain(sweepDeg/max(1.0f,cfg.scanFullTurnDeg),0,1); }
}
