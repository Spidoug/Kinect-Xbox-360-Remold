class MotionSample {
  static final int FLAG_ACCEL_VALID = 1;
  static final int FLAG_TILT_VALID = 2;
  static final float COUNTS_PER_G = 819.0f;
  static final float GRAVITY_MPS2 = 9.80665f;

  int flags = 0;
  int accelX = 0, accelY = 0, accelZ = 0;
  int tiltTenths = 0;
  long timestampMs = 0;

  boolean accelValid(){ return (flags & FLAG_ACCEL_VALID) != 0; }
  boolean tiltValid(){ return (flags & FLAG_TILT_VALID) != 0; }

  PVector accelerationMps2(){
    float k = GRAVITY_MPS2 / COUNTS_PER_G;
    return new PVector(accelX * k, accelY * k, accelZ * k);
  }

  PVector gravityUnit(){
    if (!accelValid()) return null;
    PVector g = new PVector(accelX, accelY, accelZ);
    float m = g.mag();
    if (m < 1e-4f) return null;
    g.div(m);
    return g;
  }

  boolean gravityReliable(){
    if (!accelValid()) return false;
    float counts = sqrt((float)accelX * accelX + (float)accelY * accelY + (float)accelZ * accelZ);
    return counts > COUNTS_PER_G * 0.72f && counts < COUNTS_PER_G * 1.28f;
  }
}

class Calibration {
  volatile boolean valid = false;
  int depthWidth = ScannerProtocol.WIDTH;
  int depthHeight = ScannerProtocol.HEIGHT;
  float fx, fy, cx, cy, depthScale;


  void configure(AppConfig cfg) {
    if (cfg == null) { valid = false; return; }
    depthWidth = ScannerProtocol.WIDTH;
    depthHeight = ScannerProtocol.HEIGHT;
    fx = cfg.depthFx; fy = cfg.depthFy; cx = cfg.depthCx; cy = cfg.depthCy; depthScale = cfg.depthScale;
    valid = fx > 0 && fy > 0 && depthScale > 0;
  }
}

class DepthFrame {
  int frameId, width, height, stride, pixelFormat;
  long frameNumber, timestampUs;
  short[] depth; // unsigned millimetres; 0 means invalid / missing packet data
  int validCount = 0;
  int plausibleCount = 0;
  boolean deviceCalibrated = false;
  boolean transportRecovered = false;
  MotionSample motion = new MotionSample();

  int validPixelCount() { return validCount; }
}
