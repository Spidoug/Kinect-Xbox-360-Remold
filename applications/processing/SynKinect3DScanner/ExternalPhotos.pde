class PhotoCamera {
  int imageWidth,imageHeight; File file; PVector position=new PVector(),target=new PVector(); float horizontalFovRad;
  PVector forward=new PVector(),right=new PVector(),up=new PVector();
  PhotoCamera(int imageWidth,int imageHeight,File file){this.imageWidth=imageWidth;this.imageHeight=imageHeight;this.file=file;}
  void setOrbit(PVector target,float yaw,float pitch,float distance,float hfov){
    this.target.set(target);horizontalFovRad=hfov;
    position.set(target.x+distance*cos(pitch)*sin(yaw),target.y-distance*sin(pitch),target.z+distance*cos(pitch)*cos(yaw));updateBasis();
  }
  void updateBasis(){
    forward=PVector.sub(target,position).normalize();PVector worldUp=new PVector(0,-1,0);right=forward.cross(worldUp);
    if(right.magSq()<1e-8f)right=new PVector(1,0,0);right.normalize();up=right.cross(forward).normalize();
  }
  PVector project(PVector world){
    PVector rel=PVector.sub(world,position);float z=rel.dot(forward);if(z<=0.001f)return null;
    float x=rel.dot(right),y=rel.dot(up),aspect=(float)imageWidth/imageHeight,nx=x/(z*tan(horizontalFovRad*0.5f));
    float verticalFov=2*atan(tan(horizontalFovRad*0.5f)/aspect),ny=y/(z*tan(verticalFov*0.5f));
    float u=0.5f+0.5f*nx,v=0.5f-0.5f*ny;if(u<0||u>1||v<0||v>1)return null;return new PVector(u,v,z);
  }
  float score(Triangle3D t){PVector toCamera=PVector.sub(position,t.center()).normalize();float facing=t.n.dot(toCamera);if(facing<=0.05f)return-1;return project(t.a)==null||project(t.b)==null||project(t.c)==null?-1:facing;}
}

class ExternalPhotoManager {
  ArrayList<PhotoCamera> cameras=new ArrayList<PhotoCamera>(); I18n i18n; String status;
  ExternalPhotoManager(I18n i18n){this.i18n=i18n;status=i18n.tr("photos.none");}

  void importFolder(File folder,PVector target,AppConfig cfg){
    cameras.clear();File[] files=folder.listFiles();if(files==null){status=i18n.tr("photos.empty");return;}
    ArrayList<File> images=new ArrayList<File>();
    for(File f:files){String n=f.getName().toLowerCase(Locale.ROOT);if(n.endsWith(".jpg")||n.endsWith(".jpeg")||n.endsWith(".png"))images.add(f);}
    Collections.sort(images,new Comparator<File>(){public int compare(File a,File b){return a.getName().compareToIgnoreCase(b.getName());}});
    HashMap<String,float[]> saved=readPoseFile(new File(folder,cfg.photoPoseFileName)); int count=images.size();
    for(int i=0;i<count;i++){
      int[] dims=readImageSize(images.get(i));if(dims==null)continue;PhotoCamera cam=new PhotoCamera(dims[0],dims[1],images.get(i));float[] pose=saved.get(images.get(i).getName());
      if(pose!=null&&pose.length>=7){cam.position.set(pose[0],pose[1],pose[2]);cam.target.set(pose[3],pose[4],pose[5]);cam.horizontalFovRad=radians(pose[6]);cam.updateBasis();}
      else{float yaw=TWO_PI*i/max(1,count);cam.setOrbit(target,yaw,radians(cfg.defaultPhotoPitchDeg),cfg.defaultPhotoDistanceM,radians(cfg.defaultPhotoHorizontalFovDeg));}
      cameras.add(cam);
    }
    status=cameras.size()==0?i18n.tr("photos.empty"):i18n.format("photos.loaded",cameras.size());writePoseTemplate(folder,cfg.photoPoseFileName);
  }

  int[] readImageSize(File file){
    BufferedImage image=null;try{image=ImageIO.read(file);if(image==null)return null;return new int[]{image.getWidth(),image.getHeight()};}
    catch(Exception e){println("Photo read warning: "+file.getName()+" - "+e.getMessage());return null;}finally{if(image!=null)image.flush();}
  }

  HashMap<String,float[]> readPoseFile(File file){
    HashMap<String,float[]> result=new HashMap<String,float[]>();if(!file.exists())return result;
    try{BufferedReader r=new BufferedReader(new FileReader(file));try{r.readLine();String line;while((line=r.readLine())!=null){
      ArrayList<String> p=parseCsvLine(line);if(p.size()<9)continue;try{float[] v={Float.parseFloat(p.get(2)),Float.parseFloat(p.get(3)),Float.parseFloat(p.get(4)),Float.parseFloat(p.get(5)),Float.parseFloat(p.get(6)),Float.parseFloat(p.get(7)),Float.parseFloat(p.get(8))};result.put(p.get(0),v);}catch(NumberFormatException ignored){}
    }}finally{r.close();}}catch(Exception e){println("Photo pose read warning: "+e.getMessage());}return result;
  }

  ArrayList<String> parseCsvLine(String line){
    ArrayList<String> out=new ArrayList<String>();StringBuilder field=new StringBuilder();boolean quoted=false;
    for(int i=0;i<line.length();i++){char ch=line.charAt(i);if(ch=='\"'){if(quoted&&i+1<line.length()&&line.charAt(i+1)=='\"'){field.append('\"');i++;}else quoted=!quoted;}else if(ch==','&&!quoted){out.add(field.toString());field.setLength(0);}else field.append(ch);}out.add(field.toString());return out;
  }
  String csv(String value){if(value==null)return"";return "\""+value.replace("\"","\"\"")+"\"";}

  void writePoseTemplate(File folder,String fileName){
    try{PrintWriter w=new PrintWriter(new File(folder,fileName));try{w.println("file,index,px,py,pz,targetX,targetY,targetZ,horizontalFovDeg");for(int i=0;i<cameras.size();i++){PhotoCamera c=cameras.get(i);w.println(csv(c.file.getName())+","+i+","+c.position.x+","+c.position.y+","+c.position.z+","+c.target.x+","+c.target.y+","+c.target.z+","+degrees(c.horizontalFovRad));}}finally{w.close();}}
    catch(Exception e){println("Photo pose write warning: "+e.getMessage());}
  }
  int bestCamera(Triangle3D t){int best=-1;float score=-1;for(int i=0;i<cameras.size();i++){float s=cameras.get(i).score(t);if(s>score){score=s;best=i;}}return best;}
}
