class ExportSpace {
  PVector position(PVector p) { return new PVector(p.x, -p.y, p.z); }
  Triangle3D triangle(Triangle3D t) {
    // Y reflection changes handedness; swapping B/C preserves outward winding.
    return new Triangle3D(position(t.a), position(t.c), position(t.b), t.ca, t.cc, t.cb);
  }
}

class STLExporter {
  ExportSpace space = new ExportSpace();
  void writeBinary(Mesh3D mesh, File file) throws Exception {
    DataOutputStream out = new DataOutputStream(new BufferedOutputStream(new FileOutputStream(file)));
    try {
      byte[] header = new byte[80]; byte[] title = "SynKinect 3D Scanner".getBytes("US-ASCII");
      System.arraycopy(title,0,header,0,min(title.length,80)); out.write(header); writeLEInt(out,mesh.triangleCount());
      for(Triangle3D source:mesh.triangles){ Triangle3D t=space.triangle(source); writeVec(out,t.n); writeVec(out,t.a); writeVec(out,t.b); writeVec(out,t.c); writeLEShort(out,0); }
    } finally { out.close(); }
  }
  void writeVec(DataOutputStream out,PVector v)throws Exception{writeLEFloat(out,v.x*1000);writeLEFloat(out,v.y*1000);writeLEFloat(out,v.z*1000);}
  void writeLEFloat(DataOutputStream out,float value)throws Exception{writeLEInt(out,Float.floatToIntBits(value));}
  void writeLEInt(DataOutputStream out,int value)throws Exception{out.writeByte(value&255);out.writeByte((value>>8)&255);out.writeByte((value>>16)&255);out.writeByte((value>>24)&255);}
  void writeLEShort(DataOutputStream out,int value)throws Exception{out.writeByte(value&255);out.writeByte((value>>8)&255);}
}

class OBJExporter {
  ExportSpace space = new ExportSpace();
  void write(Mesh3D mesh,ExternalPhotoManager photos,File folder,String base)throws Exception{
    File obj=new File(folder,base+".obj"),mtl=new File(folder,base+".mtl"),texDir=new File(folder,base+"_textures");
    if(!texDir.exists()&&!texDir.mkdirs())throw new IOException("Could not create texture folder: "+texDir.getAbsolutePath());
    writeMaterials(photos,texDir,mtl); writeObject(mesh,photos,obj,mtl);
  }
  void writeMaterials(ExternalPhotoManager photos,File texDir,File mtl)throws Exception{
    PrintWriter out=new PrintWriter(new BufferedWriter(new FileWriter(mtl)));
    try{
      for(int i=0;i<photos.cameras.size();i++){
        PhotoCamera camera=photos.cameras.get(i); String ext=fileExtension(camera.file.getName()); String texName=String.format(Locale.ROOT,"photo_%03d.%s",i,ext);
        Files.copy(camera.file.toPath(),new File(texDir,texName).toPath(),StandardCopyOption.REPLACE_EXISTING);
        out.println("newmtl photo_"+i);out.println("Ka 1 1 1");out.println("Kd 1 1 1");out.println("map_Kd "+texDir.getName()+"/"+texName);out.println();
      }
      out.println("newmtl untextured");out.println("Kd 0.75 0.75 0.75");out.println();
    }finally{out.close();}
  }
  void writeObject(Mesh3D mesh,ExternalPhotoManager photos,File obj,File mtl)throws Exception{
    PrintWriter out=new PrintWriter(new BufferedWriter(new FileWriter(obj)));
    try{
      out.println("mtllib "+mtl.getName()); int vIndex=1,vtIndex=1;
      for(Triangle3D source:mesh.triangles){
        Triangle3D t=space.triangle(source);
        writeObjVertex(out,t.a,t.ca);writeObjVertex(out,t.b,t.cb);writeObjVertex(out,t.c,t.cc);
        int camIndex=photos.bestCamera(source);
        if(camIndex>=0){
          PhotoCamera camera=photos.cameras.get(camIndex); PVector ua=camera.project(source.a),ub=camera.project(source.c),uc=camera.project(source.b);
          if(ua!=null&&ub!=null&&uc!=null){
            out.println("vt "+ua.x+" "+(1-ua.y));out.println("vt "+ub.x+" "+(1-ub.y));out.println("vt "+uc.x+" "+(1-uc.y));
            out.println("usemtl photo_"+camIndex);out.println("f "+vIndex+"/"+vtIndex+" "+(vIndex+1)+"/"+(vtIndex+1)+" "+(vIndex+2)+"/"+(vtIndex+2));vtIndex+=3;
          }else{out.println("usemtl untextured");out.println("f "+vIndex+" "+(vIndex+1)+" "+(vIndex+2));}
        }else{out.println("usemtl untextured");out.println("f "+vIndex+" "+(vIndex+1)+" "+(vIndex+2));}
        vIndex+=3;
      }
    }finally{out.close();}
  }
  void writeObjVertex(PrintWriter out,PVector p,int c){float r=((c>>16)&255)/255.0f,g=((c>>8)&255)/255.0f,b=(c&255)/255.0f;out.println("v "+p.x+" "+p.y+" "+p.z+" "+r+" "+g+" "+b);}
  String fileExtension(String name){int p=name.lastIndexOf('.');return p<0?"jpg":name.substring(p+1).toLowerCase(Locale.ROOT);}
}

class PLYExporter {
  ExportSpace space = new ExportSpace();
  void write(Mesh3D mesh,File file)throws Exception{
    PrintWriter out=new PrintWriter(new BufferedWriter(new FileWriter(file)));
    try{
      int vertices=mesh.triangleCount()*3;out.println("ply");out.println("format ascii 1.0");out.println("comment SynKinect 3D Scanner");
      out.println("element vertex "+vertices);out.println("property float x");out.println("property float y");out.println("property float z");out.println("property uchar red");out.println("property uchar green");out.println("property uchar blue");
      out.println("element face "+mesh.triangleCount());out.println("property list uchar int vertex_indices");out.println("end_header");
      for(Triangle3D source:mesh.triangles){Triangle3D t=space.triangle(source);writeVertex(out,t.a,t.ca);writeVertex(out,t.b,t.cb);writeVertex(out,t.c,t.cc);}
      for(int i=0;i<mesh.triangleCount();i++){int b=i*3;out.println("3 "+b+" "+(b+1)+" "+(b+2));}
    }finally{out.close();}
  }
  void writeVertex(PrintWriter out,PVector p,int c){int r=(c>>16)&255,g=(c>>8)&255,b=c&255;out.println(p.x+" "+p.y+" "+p.z+" "+r+" "+g+" "+b);}
}
