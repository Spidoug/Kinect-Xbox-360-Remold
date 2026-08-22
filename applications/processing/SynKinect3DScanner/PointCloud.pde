class PointCloudBuilder {
  AppConfig cfg;
  RgbDepthRegistration registration;
  PointCloudBuilder(AppConfig cfg,RgbDepthRegistration registration) { this.cfg = cfg; this.registration=registration; }

  PointCloud build(DepthFrame f, Calibration c, int step, float targetZ, float band, PointCloudBuildStats stats, RgbSnapshot rgb) {
    PointCloud cloud = new PointCloud();
    if (stats != null) stats.clear();
    if (f == null || f.depth == null || c == null || !c.valid) return cloud;
    if(cfg.meshColorEnabled && registration!=null) registration.prepareFrame(f,rgb);
    int safeStep = max(1, step);
    for (int v = 0; v < f.height; v += safeStep) {
      for (int u = 0; u < f.width; u += safeStep) {
        if (stats != null) stats.sourcePixels++;
        int index=v*f.width+u;
        int raw = f.depth[index] & 0xFFFF;
        if (raw == 0) continue;
        if (stats != null) stats.nonZero++;
        float z = raw * c.depthScale;
        if (z < cfg.minDepthM || z > cfg.maxDepthM) { if (stats != null) stats.rejectedRange++; continue; }
        if (stats != null) stats.inRange++;
        if (!Float.isNaN(targetZ) && abs(z - targetZ) > band) { if (stats != null) stats.rejectedBand++; continue; }
        if (cfg.pointCloudSpatialFilter && !spatiallyConsistent(f, u, v, raw, safeStep)) { if (stats != null) stats.rejectedSpatial++; continue; }
        float x = registration!=null ? registration.pointX(index,z) : (u-c.cx)*z/c.fx;
        float y = registration!=null ? registration.pointY(index,z) : (v-c.cy)*z/c.fy;
        int rgbColor = cfg.meshColorEnabled && registration!=null ? registration.colorAt(index) : 0;
        cloud.add(new PVector(x,y,z),rgbColor);
        if (stats != null) stats.accepted++;
      }
    }
    return cloud;
  }

  boolean spatiallyConsistent(DepthFrame f, int u, int v, int centerMm, int step) {
    int toleranceMm = max(1, round(cfg.pointCloudNeighborToleranceM * 1000.0f));
    int checked = 0, consistent = 0;
    int[] dx = {-step, step, 0, 0};
    int[] dy = {0, 0, -step, step};
    for (int i = 0; i < 4; i++) {
      int x = u + dx[i], y = v + dy[i];
      if (x < 0 || x >= f.width || y < 0 || y >= f.height) continue;
      int mm = f.depth[y * f.width + x] & 0xFFFF;
      if (mm == 0) continue;
      checked++;
      if (abs(mm - centerMm) <= toleranceMm) consistent++;
    }
    return checked == 0 || consistent > 0;
  }
}

class PointCloud {
  ArrayList<PVector> points = new ArrayList<PVector>();
  int[] colors = new int[4096];
  int size() { return points.size(); }
  void add(PVector p,int c){
    int index=points.size();points.add(p);
    if(index>=colors.length)colors=Arrays.copyOf(colors,max(index+1,colors.length*2));
    colors[index]=c;
  }
  int colorAt(int i){return i>=0&&i<points.size()?colors[i]:0;}

  PVector centroid() {
    PVector c = new PVector(); if (points.size() == 0) return c;
    for (PVector p : points) c.add(p); return c.div(points.size());
  }
  PVector centroidTransformed(RigidTransform t) {
    PVector c = new PVector(); if (points.size() == 0) return c;
    for (PVector p : points) c.add(t.apply(p)); return c.div(points.size());
  }
  PointCloud transformed(RigidTransform t, int maxPoints) {
    PointCloud out = new PointCloud(); int stride = max(1, points.size() / max(1, maxPoints));
    for (int i = 0; i < points.size(); i += stride) out.add(t.apply(points.get(i)),colorAt(i)); return out;
  }
}

class SpatialHash {
  float cell;
  HashMap<Long, ArrayList<PVector>> buckets = new HashMap<Long, ArrayList<PVector>>();
  SpatialHash(float cell) { this.cell = max(0.000001f, cell); }

  long key(int x,int y,int z) {
    long a=((long)x & 0x1FFFFF), b=((long)y & 0x1FFFFF), c=((long)z & 0x1FFFFF);
    return (a<<42)|(b<<21)|c;
  }
  int cellCoord(float v){ return floor(v/cell); }
  void add(PVector p) {
    long k=key(cellCoord(p.x),cellCoord(p.y),cellCoord(p.z)); ArrayList<PVector> list=buckets.get(k);
    if(list==null){ list=new ArrayList<PVector>(); buckets.put(k,list); } list.add(p);
  }

  PVector nearest(PVector p,float maxDist) {
    int cx=cellCoord(p.x), cy=cellCoord(p.y), cz=cellCoord(p.z);
    int radius=max(1, ceil(maxDist/cell));
    PVector best=null; float best2=maxDist*maxDist;
    for(int dz=-radius;dz<=radius;dz++) for(int dy=-radius;dy<=radius;dy++) for(int dx=-radius;dx<=radius;dx++) {
      ArrayList<PVector> list=buckets.get(key(cx+dx,cy+dy,cz+dz));
      if(list==null) continue;
      for(PVector q:list){ float d2=PVector.sub(p,q).magSq(); if(d2<best2){best2=d2;best=q;} }
    }
    return best;
  }
}
