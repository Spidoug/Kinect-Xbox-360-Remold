class Triangle3D {
  PVector a,b,c,n;
  int ca,cb,cc;
  Triangle3D(PVector a,PVector b,PVector c){this(a,b,c,0,0,0);}
  Triangle3D(PVector a,PVector b,PVector c,int ca,int cb,int cc){this.a=a;this.b=b;this.c=c;this.ca=ca;this.cb=cb;this.cc=cc;recalc();}
  void recalc(){ n=PVector.sub(b,a).cross(PVector.sub(c,a)); if(n.magSq()>1e-12f)n.normalize(); }
  PVector center(){ return new PVector((a.x+b.x+c.x)/3,(a.y+b.y+c.y)/3,(a.z+b.z+c.z)/3); }
}

class Mesh3D {
  ArrayList<Triangle3D> triangles=new ArrayList<Triangle3D>();
  ArrayList<PShape> renderChunks=new ArrayList<PShape>();
  int renderCursor=0;
  boolean renderCacheComplete=false;
  final int renderChunkTriangles=12000;

  void clear(){triangles.clear();invalidateRenderCache();}
  int triangleCount(){return triangles.size();}
  void addTriangle(PVector a,PVector b,PVector c){addTriangle(a,b,c,0,0,0);}
  void addTriangle(PVector a,PVector b,PVector c,int ca,int cb,int cc){
    if(PVector.sub(b,a).cross(PVector.sub(c,a)).magSq()>1e-12f) triangles.add(new Triangle3D(a,b,c,ca,cb,cc));
  }
  void recalculateNormals(){for(Triangle3D t:triangles)t.recalc();invalidateRenderCache();}
  void invalidateRenderCache(){renderChunks.clear();renderCursor=0;renderCacheComplete=triangles.size()==0;}

  Mesh3D deepCopy(){
    Mesh3D copy=new Mesh3D();
    for(Triangle3D t:triangles) copy.addTriangle(t.a.copy(),t.b.copy(),t.c.copy(),t.ca,t.cb,t.cc);
    return copy;
  }

  PVector boundsCenter(){
    if(triangles.size()==0) return new PVector();
    float minX=Float.POSITIVE_INFINITY,minY=Float.POSITIVE_INFINITY,minZ=Float.POSITIVE_INFINITY;
    float maxX=Float.NEGATIVE_INFINITY,maxY=Float.NEGATIVE_INFINITY,maxZ=Float.NEGATIVE_INFINITY;
    for(Triangle3D t:triangles){
      PVector[] v={t.a,t.b,t.c};
      for(PVector p:v){ minX=min(minX,p.x); minY=min(minY,p.y); minZ=min(minZ,p.z); maxX=max(maxX,p.x); maxY=max(maxY,p.y); maxZ=max(maxZ,p.z); }
    }
    return new PVector((minX+maxX)*0.5f,(minY+maxY)*0.5f,(minZ+maxZ)*0.5f);
  }

  int renderColor(int c,int fallback){ return ((c>>>24)&255)==0 ? fallback : c; }

  void buildNextRenderChunk(int fallbackShade){
    if(renderCacheComplete)return;
    int end=min(triangles.size(),renderCursor+renderChunkTriangles);
    if(end<=renderCursor){renderCacheComplete=true;return;}
    PShape chunk=createShape();
    chunk.beginShape(TRIANGLES);chunk.noStroke();
    for(int i=renderCursor;i<end;i++){
      Triangle3D t=triangles.get(i);
      chunk.normal(t.n.x,t.n.y,t.n.z);
      chunk.fill(renderColor(t.ca,fallbackShade));chunk.vertex(t.a.x,t.a.y,t.a.z);
      chunk.fill(renderColor(t.cb,fallbackShade));chunk.vertex(t.b.x,t.b.y,t.b.z);
      chunk.fill(renderColor(t.cc,fallbackShade));chunk.vertex(t.c.x,t.c.y,t.c.z);
    }
    chunk.endShape();renderChunks.add(chunk);renderCursor=end;renderCacheComplete=renderCursor>=triangles.size();
  }

  void drawMesh(int shade){
    if(triangles.size()==0)return;
    // Retained PShape chunks are compiled incrementally on the render thread.
    // Heavy mesh extraction/polish runs elsewhere; after this cache is warm no
    // triangle list is rebuilt every frame.
    if(!renderCacheComplete)buildNextRenderChunk(shade);
    for(PShape chunk:renderChunks)shape(chunk);
  }
}
