class MeshEditor {
  final AppConfig cfg;
  MeshEditor(AppConfig cfg){ this.cfg=cfg; }

  Mesh3D clean(Mesh3D source){
    Mesh3D filtered=new Mesh3D();
    if(source==null)return filtered;
    for(Triangle3D t:source.triangles){
      float ab=PVector.dist(t.a,t.b),bc=PVector.dist(t.b,t.c),ca=PVector.dist(t.c,t.a);
      float area=PVector.sub(t.b,t.a).cross(PVector.sub(t.c,t.a)).mag()*0.5f;
      if(area<cfg.meshCleanupMinAreaM2)continue;
      if(max(ab,max(bc,ca))>cfg.meshCleanupMaxEdgeM)continue;
      filtered.addTriangle(t.a.copy(),t.b.copy(),t.c.copy(),t.ca,t.cb,t.cc);
    }
    Mesh3D components=removeSmallComponents(filtered);
    components.recalculateNormals();return components;
  }

  Mesh3D smooth(Mesh3D source){
    if(source==null)return new Mesh3D();
    Mesh3D work=source.deepCopy();
    for(int i=0;i<cfg.meshSmoothIterations;i++)smoothPass(work,cfg.meshSmoothLambda);
    work.recalculateNormals();return work;
  }

  Mesh3D polish(Mesh3D source){
    Mesh3D work=clean(source);
    // Taubin lambda/mu smoothing removes voxel stair-stepping without the
    // strong shrinkage of repeated plain Laplacian smoothing.
    for(int i=0;i<cfg.meshPolishIterations;i++){
      smoothPass(work,cfg.meshPolishLambda);
      smoothPass(work,cfg.meshPolishMu);
    }
    work.recalculateNormals();return work;
  }

  void smoothPass(Mesh3D mesh,float factor){
    HashMap<Long,PVector> sum=new HashMap<Long,PVector>();
    HashMap<Long,Integer> count=new HashMap<Long,Integer>();
    HashMap<Long,HashSet<Long>> neighbors=new HashMap<Long,HashSet<Long>>();
    for(Triangle3D t:mesh.triangles){
      long ka=key(t.a),kb=key(t.b),kc=key(t.c);
      addVertex(sum,count,ka,t.a);addVertex(sum,count,kb,t.b);addVertex(sum,count,kc,t.c);
      connect(neighbors,ka,kb);connect(neighbors,kb,kc);connect(neighbors,kc,ka);
    }
    HashMap<Long,PVector> center=new HashMap<Long,PVector>(sum.size()*2);
    for(Long k:sum.keySet()){PVector p=sum.get(k).copy();p.div(max(1,count.get(k)));center.put(k,p);}
    HashMap<Long,PVector> moved=new HashMap<Long,PVector>(center.size()*2);
    for(Long k:center.keySet()){
      PVector base=center.get(k),avg=new PVector();int n=0;HashSet<Long> adj=neighbors.get(k);
      if(adj!=null)for(Long other:adj){PVector q=center.get(other);if(q!=null){avg.add(q);n++;}}
      if(n<2){moved.put(k,base.copy());continue;}
      avg.div(n);PVector delta=PVector.sub(avg,base);moved.put(k,PVector.add(base,PVector.mult(delta,factor)));
    }
    for(Triangle3D t:mesh.triangles){PVector a=moved.get(key(t.a)),b=moved.get(key(t.b)),c=moved.get(key(t.c));if(a!=null)t.a.set(a);if(b!=null)t.b.set(b);if(c!=null)t.c.set(c);}
  }

  Mesh3D removeSmallComponents(Mesh3D source){
    if(source==null||source.triangleCount()==0)return new Mesh3D();
    int n=source.triangleCount();
    HashMap<Long,ArrayList<Integer>> incidence=new HashMap<Long,ArrayList<Integer>>();
    for(int i=0;i<n;i++){
      Triangle3D t=source.triangles.get(i);addIncidence(incidence,key(t.a),i);addIncidence(incidence,key(t.b),i);addIncidence(incidence,key(t.c),i);
    }
    boolean[] seen=new boolean[n];ArrayList<ArrayList<Integer>> groups=new ArrayList<ArrayList<Integer>>();int largest=0;
    for(int seed=0;seed<n;seed++){
      if(seen[seed])continue;ArrayList<Integer> group=new ArrayList<Integer>();ArrayDeque<Integer> q=new ArrayDeque<Integer>();q.add(seed);seen[seed]=true;
      while(!q.isEmpty()){
        int i=q.removeFirst();group.add(i);Triangle3D t=source.triangles.get(i);long[] keys={key(t.a),key(t.b),key(t.c)};
        for(long k:keys){ArrayList<Integer> linked=incidence.get(k);if(linked==null)continue;for(Integer other:linked)if(!seen[other]){seen[other]=true;q.addLast(other);}}
      }
      groups.add(group);largest=max(largest,group.size());
    }
    int threshold=max(cfg.meshMinimumComponentTriangles,round(largest*cfg.meshMinimumComponentRatio));
    Mesh3D out=new Mesh3D();
    for(ArrayList<Integer> group:groups)if(group.size()>=threshold)for(Integer idx:group){Triangle3D t=source.triangles.get(idx);out.addTriangle(t.a.copy(),t.b.copy(),t.c.copy(),t.ca,t.cb,t.cc);}
    if(out.triangleCount()==0){
      ArrayList<Integer> best=null;for(ArrayList<Integer> group:groups)if(best==null||group.size()>best.size())best=group;
      if(best!=null)for(Integer idx:best){Triangle3D t=source.triangles.get(idx);out.addTriangle(t.a.copy(),t.b.copy(),t.c.copy(),t.ca,t.cb,t.cc);}
    }
    return out;
  }

  Mesh3D center(Mesh3D source){
    if(source==null)return new Mesh3D();
    Mesh3D out=source.deepCopy();PVector c=out.boundsCenter();
    for(Triangle3D t:out.triangles){t.a.sub(c);t.b.sub(c);t.c.sub(c);t.recalc();}out.invalidateRenderCache();return out;
  }

  long key(PVector p){
    float q=max(0.000001f,cfg.meshWeldToleranceM);long x=round(p.x/q),y=round(p.y/q),z=round(p.z/q);
    return ((x&0x1FFFFFL)<<42)|((y&0x1FFFFFL)<<21)|(z&0x1FFFFFL);
  }
  void addIncidence(HashMap<Long,ArrayList<Integer>> m,long k,int i){ArrayList<Integer> list=m.get(k);if(list==null){list=new ArrayList<Integer>();m.put(k,list);}list.add(i);}
  void addVertex(HashMap<Long,PVector> sum,HashMap<Long,Integer> count,long k,PVector p){PVector acc=sum.get(k);if(acc==null){acc=new PVector();sum.put(k,acc);count.put(k,0);}acc.add(p);count.put(k,count.get(k)+1);}
  void connect(HashMap<Long,HashSet<Long>> n,long a,long b){if(a==b)return;HashSet<Long> aa=n.get(a);if(aa==null){aa=new HashSet<Long>();n.put(a,aa);}aa.add(b);HashSet<Long> bb=n.get(b);if(bb==null){bb=new HashSet<Long>();n.put(b,bb);}bb.add(a);}
}
