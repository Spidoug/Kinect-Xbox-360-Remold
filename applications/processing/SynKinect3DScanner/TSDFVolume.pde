class TSDFVolume {
  int n;
  float voxelSize, truncation;
  int temporalColorWeightMax;
  short[] tsdf;
  byte[] weight;
  int[] rgb;
  byte[] rgbWeight;
  PVector origin = new PVector();
  PVector center = new PVector();
  int minX,minY,minZ,maxX,maxY,maxZ;

  TSDFVolume(int n,float voxelSize,float truncation,int temporalColorWeightMax){
    this.n=n; this.voxelSize=voxelSize; this.truncation=truncation; this.temporalColorWeightMax=max(1,temporalColorWeightMax);
    tsdf=new short[n*n*n]; weight=new byte[n*n*n]; rgb=new int[n*n*n]; rgbWeight=new byte[n*n*n]; clear();
  }

  void clear(){
    Arrays.fill(tsdf,(short)32767); Arrays.fill(weight,(byte)0); Arrays.fill(rgb,0); Arrays.fill(rgbWeight,(byte)0);
    minX=minY=minZ=n; maxX=maxY=maxZ=-1;
  }

  void resetAround(PVector c){
    clear(); center.set(c);
    float half=n*voxelSize*0.5f;
    origin.set(c.x-half,c.y-half,c.z-half);
  }

  int idx(int x,int y,int z){ return x + y*n + z*n*n; }
  boolean inside(int x,int y,int z){ return x>=0&&y>=0&&z>=0&&x<n&&y<n&&z<n; }

  void integrate(PointCloud cloud,RigidTransform pose,int pointStep){
    PVector cam=pose.translation();
    int stride=max(1,pointStep);
    for(int i=0;i<cloud.size();i+=stride){
      PVector surf=pose.apply(cloud.points.get(i)); int surfaceColor=cloud.colorAt(i);
      PVector ray=PVector.sub(surf,cam); float dist=ray.mag(); if(dist<0.05f) continue; ray.div(dist);
      float from=max(0.05f,dist-truncation), to=dist+truncation;
      for(float t=from;t<=to;t+=voxelSize){
        PVector p=PVector.add(cam,PVector.mult(ray,t));
        int x=floor((p.x-origin.x)/voxelSize), y=floor((p.y-origin.y)/voxelSize), z=floor((p.z-origin.z)/voxelSize);
        if(!inside(x,y,z)) continue;
        float v=constrain((dist-t)/truncation,-1,1);
        int id=idx(x,y,z); int w=weight[id]&255; int nw=min(255,w+1);
        float old=tsdf[id]/32767.0f;
        float blended=(old*w+v)/nw;
        tsdf[id]=(short)constrain(round(blended*32767.0f),-32767,32767); weight[id]=(byte)nw;
        minX=min(minX,x); minY=min(minY,y); minZ=min(minZ,z); maxX=max(maxX,x); maxY=max(maxY,y); maxZ=max(maxZ,z);
      }
      if(((surfaceColor>>>24)&255)!=0) integrateSurfaceColor(surf,surfaceColor);
    }
  }

  void integrateSurfaceColor(PVector p,int colorValue){
    int x=round((p.x-origin.x)/voxelSize),y=round((p.y-origin.y)/voxelSize),z=round((p.z-origin.z)/voxelSize);
    if(!inside(x,y,z))return;
    int id=idx(x,y,z),w=rgbWeight[id]&255;
    // Alpha carries registration/exposure confidence. Repeated synchronized,
    // well-exposed views therefore add more texture evidence over time while
    // dark, saturated or poorly synchronized frames cannot dominate the mesh.
    int confidence=(colorValue>>>24)&255;
    int sampleWeight=constrain(round((confidence/255.0f)*temporalColorWeightMax),1,temporalColorWeightMax);
    int accepted=min(sampleWeight,255-w);if(accepted<=0)return;int nw=w+accepted;
    int old=rgb[id],or=(old>>16)&255,og=(old>>8)&255,ob=old&255,nr=(colorValue>>16)&255,ng=(colorValue>>8)&255,nb=colorValue&255;
    int r=(or*w+nr*accepted)/nw,g=(og*w+ng*accepted)/nw,b=(ob*w+nb*accepted)/nw;rgb[id]=0xFF000000|(r<<16)|(g<<8)|b;rgbWeight[id]=(byte)nw;
  }

  float value(int x,int y,int z){ return tsdf[idx(x,y,z)]/32767.0f; }
  int w(int x,int y,int z){ return weight[idx(x,y,z)]&255; }
  PVector pos(int x,int y,int z){ return new PVector(origin.x+x*voxelSize,origin.y+y*voxelSize,origin.z+z*voxelSize); }

  int sampleColor(PVector p){
    int cx=round((p.x-origin.x)/voxelSize),cy=round((p.y-origin.y)/voxelSize),cz=round((p.z-origin.z)/voxelSize);
    int best=0,bestWeight=0;
    for(int dz=-1;dz<=1;dz++)for(int dy=-1;dy<=1;dy++)for(int dx=-1;dx<=1;dx++){
      int x=cx+dx,y=cy+dy,z=cz+dz;if(!inside(x,y,z))continue;int id=idx(x,y,z),cw=rgbWeight[id]&255;if(cw>bestWeight){bestWeight=cw;best=rgb[id];}
    }
    return best;
  }

  Mesh3D extractMesh(int minWeight){
    Mesh3D out=new Mesh3D();
    if(maxX<0) return out;
    int x0=max(0,minX-1),y0=max(0,minY-1),z0=max(0,minZ-1);
    int x1=min(n-2,maxX+1),y1=min(n-2,maxY+1),z1=min(n-2,maxZ+1);
    int[][] corners={{0,0,0},{1,0,0},{1,1,0},{0,1,0},{0,0,1},{1,0,1},{1,1,1},{0,1,1}};
    int[][] tets={{0,5,1,6},{0,1,2,6},{0,2,3,6},{0,3,7,6},{0,7,4,6},{0,4,5,6}};
    for(int z=z0;z<=z1;z++) for(int y=y0;y<=y1;y++) for(int x=x0;x<=x1;x++){
      PVector[] p=new PVector[8]; float[] v=new float[8]; int[] ww=new int[8]; boolean ok=false;
      for(int c=0;c<8;c++){
        int xx=x+corners[c][0],yy=y+corners[c][1],zz=z+corners[c][2];
        p[c]=pos(xx,yy,zz); v[c]=value(xx,yy,zz); ww[c]=w(xx,yy,zz); if(ww[c]>=minWeight) ok=true;
      }
      if(!ok) continue;
      for(int[] t:tets) polygonizeTet(out,p,v,ww,t,minWeight);
    }
    out.recalculateNormals();
    return out;
  }

  PVector interp(PVector a,PVector b,float va,float vb){
    float d=va-vb; float t=abs(d)<1e-7f?0.5f:va/d; t=constrain(t,0,1); return PVector.lerp(a,b,t);
  }

  void polygonizeTet(Mesh3D out,PVector[] p,float[] v,int[] ww,int[] t,int minWeight){
    for(int i=0;i<4;i++) if(ww[t[i]]<minWeight) return;
    int[] inside=new int[4], outside=new int[4]; int ni=0,no=0;
    for(int i=0;i<4;i++){ if(v[t[i]]<0) inside[ni++]=t[i]; else outside[no++]=t[i]; }
    if(ni==0||ni==4) return;
    if(ni==1||ni==3){
      boolean invert=ni==3; int a=invert?outside[0]:inside[0]; int[] others=new int[3];
      if(invert){others[0]=inside[0];others[1]=inside[1];others[2]=inside[2];}
      else {others[0]=outside[0];others[1]=outside[1];others[2]=outside[2];}
      PVector p0=interp(p[a],p[others[0]],v[a],v[others[0]]);
      PVector p1=interp(p[a],p[others[1]],v[a],v[others[1]]);
      PVector p2=interp(p[a],p[others[2]],v[a],v[others[2]]);
      if(invert) out.addTriangle(p0,p2,p1,sampleColor(p0),sampleColor(p2),sampleColor(p1)); else out.addTriangle(p0,p1,p2,sampleColor(p0),sampleColor(p1),sampleColor(p2));
    } else {
      int a=inside[0],b=inside[1],c=outside[0],d=outside[1];
      PVector ac=interp(p[a],p[c],v[a],v[c]), ad=interp(p[a],p[d],v[a],v[d]);
      PVector bc=interp(p[b],p[c],v[b],v[c]), bd=interp(p[b],p[d],v[b],v[d]);
      out.addTriangle(ac,bc,ad,sampleColor(ac),sampleColor(bc),sampleColor(ad)); out.addTriangle(ad,bc,bd,sampleColor(ad),sampleColor(bc),sampleColor(bd));
    }
  }
}
