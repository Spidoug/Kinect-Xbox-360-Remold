class RigidTransform {
  float[] m = new float[16];

  RigidTransform() { setIdentity(); }

  void setIdentity() {
    Arrays.fill(m, 0);
    m[0] = m[5] = m[10] = m[15] = 1;
  }

  void set(RigidTransform o) { arrayCopy(o.m, m); }
  void setArray(float[] a) { for (int i = 0; i < 16; i++) m[i] = a[i]; }

  PVector apply(PVector p) {
    return new PVector(
      m[0]*p.x + m[1]*p.y + m[2]*p.z + m[3],
      m[4]*p.x + m[5]*p.y + m[6]*p.z + m[7],
      m[8]*p.x + m[9]*p.y + m[10]*p.z + m[11]
    );
  }

  PVector rotate(PVector p) {
    return new PVector(
      m[0]*p.x + m[1]*p.y + m[2]*p.z,
      m[4]*p.x + m[5]*p.y + m[6]*p.z,
      m[8]*p.x + m[9]*p.y + m[10]*p.z
    );
  }

  PVector translation() { return new PVector(m[3], m[7], m[11]); }

  RigidTransform multiply(RigidTransform b) {
    RigidTransform r = new RigidTransform();
    for (int row = 0; row < 4; row++) {
      for (int col = 0; col < 4; col++) {
        float s = 0;
        for (int k = 0; k < 4; k++) s += m[row*4+k] * b.m[k*4+col];
        r.m[row*4+col] = s;
      }
    }
    return r;
  }

  RigidTransform fromRotationTranslation(float[][] R, PVector t) {
    RigidTransform x = new RigidTransform();
    x.m[0]=R[0][0]; x.m[1]=R[0][1]; x.m[2]=R[0][2]; x.m[3]=t.x;
    x.m[4]=R[1][0]; x.m[5]=R[1][1]; x.m[6]=R[1][2]; x.m[7]=t.y;
    x.m[8]=R[2][0]; x.m[9]=R[2][1]; x.m[10]=R[2][2]; x.m[11]=t.z;
    return x;
  }
}

class QuaternionFit {
  RigidTransform fit(ArrayList<PVector> src, ArrayList<PVector> dst) {
    int n = min(src.size(), dst.size());
    if (n < 3) return new RigidTransform();
    PVector cs = new PVector(), cd = new PVector();
    for (int i=0;i<n;i++) { cs.add(src.get(i)); cd.add(dst.get(i)); }
    cs.div(n); cd.div(n);

    float Sxx=0,Sxy=0,Sxz=0,Syx=0,Syy=0,Syz=0,Szx=0,Szy=0,Szz=0;
    for (int i=0;i<n;i++) {
      PVector a=PVector.sub(src.get(i),cs), b=PVector.sub(dst.get(i),cd);
      Sxx+=a.x*b.x; Sxy+=a.x*b.y; Sxz+=a.x*b.z;
      Syx+=a.y*b.x; Syy+=a.y*b.y; Syz+=a.y*b.z;
      Szx+=a.z*b.x; Szy+=a.z*b.y; Szz+=a.z*b.z;
    }
    float tr=Sxx+Syy+Szz;
    float[][] N={
      {tr, Syz-Szy, Szx-Sxz, Sxy-Syx},
      {Syz-Szy, Sxx-Syy-Szz, Sxy+Syx, Szx+Sxz},
      {Szx-Sxz, Sxy+Syx, -Sxx+Syy-Szz, Syz+Szy},
      {Sxy-Syx, Szx+Sxz, Syz+Szy, -Sxx-Syy+Szz}
    };
    float[] q={1,0,0,0};
    for(int it=0;it<32;it++) {
      float[] nq=new float[4];
      for(int r=0;r<4;r++) for(int c=0;c<4;c++) nq[r]+=N[r][c]*q[c];
      float norm=sqrt(nq[0]*nq[0]+nq[1]*nq[1]+nq[2]*nq[2]+nq[3]*nq[3]);
      if(norm<1e-9f) break;
      for(int k=0;k<4;k++) q[k]=nq[k]/norm;
    }
    float w=q[0],x=q[1],y=q[2],z=q[3];
    float[][] R={
      {1-2*y*y-2*z*z, 2*x*y-2*z*w, 2*x*z+2*y*w},
      {2*x*y+2*z*w, 1-2*x*x-2*z*z, 2*y*z-2*x*w},
      {2*x*z-2*y*w, 2*y*z+2*x*w, 1-2*x*x-2*y*y}
    };
    PVector rcs=new PVector(
      R[0][0]*cs.x+R[0][1]*cs.y+R[0][2]*cs.z,
      R[1][0]*cs.x+R[1][1]*cs.y+R[1][2]*cs.z,
      R[2][0]*cs.x+R[2][1]*cs.y+R[2][2]*cs.z
    );
    PVector t=PVector.sub(cd,rcs);
    return new RigidTransform().fromRotationTranslation(R,t);
  }
}
