// ===== SynKinect Studio / Acoustic Scanner / Module.pde =====
class AcousticModuleState {
  AcousticConfig config;
  AcousticI18n i18n;
  AcousticSource source;
  AcousticEngine engine;
  AcousticAutoSteerer autoSteerer;
  AcousticBeamOutput output;
  AcousticUI ui;
  volatile AcousticScanFrame scan;
  volatile boolean automaticBeam=true;
  volatile float manualAzimuthDeg=0;
  volatile float beamAzimuthDeg=0;
}

void setupAcousticModule(){
  studio.acousticState.config=new AcousticConfig();
  studio.acousticState.config.load(new File(dataPath("acoustic.properties")));
  studio.acousticState.i18n=new AcousticI18n(studio.currentLanguage());
  initializeAcousticTypography();
  studio.acousticState.engine=new AcousticEngine(studio.acousticState.config);
  studio.acousticState.autoSteerer=new AcousticAutoSteerer(studio.acousticState.config);
  studio.acousticState.output=new AcousticBeamOutput(studio.acousticState.config);
  studio.acousticState.source=new AcousticSource(studio.acousticState.config);
  studio.acousticState.ui=new AcousticUI();
}

void drawAcousticModule(){
  background(studio.services.acousticTheme.BG);
  AcousticAudioFrame frame=studio.acousticState.source==null?null:studio.acousticState.source.snapshot();
  studio.acousticState.ui.draw(frame,studio.acousticState.scan);
}

void acousticMousePressed(){if(studio.acousticState.ui!=null)studio.acousticState.ui.handleMouse(studio.contentMouseX(),studio.contentMouseY());}
void acousticKeyPressed(){
  if(key=='r'||key=='R')resetAcousticMap();
  else if(key=='a'||key=='A')studio.acousticState.automaticBeam=true;
  else if(key=='m'||key=='M')studio.acousticState.automaticBeam=false;
}
void resetAcousticMap(){if(studio.acousticState.engine!=null)studio.acousticState.engine.reset();if(studio.acousticState.autoSteerer!=null)studio.acousticState.autoSteerer.reset();studio.acousticState.scan=null;}
void disposeAcousticModule(){
  if(studio.acousticState.source!=null)studio.acousticState.source.stop();
  if(studio.acousticState.output!=null)studio.acousticState.output.stop();
}


// ===== SynKinect Studio / Acoustic Scanner / AcousticConfig.pde =====
class AcousticConfig {
  int uiFrameRate=30,workerJoinMs=1200,reconnectMs=300,pipeOpenAttempts=4,pipeOpenRetryMs=75,noFrameWarningMs=2000,connectionStaleMs=3500;
  String uiFontFamily="Segoe UI",uiHeadingFontFamily="Segoe UI Semibold",uiFontFallback="Arial";
  float soundSpeedMps=343.0f,minimumRms=0.0018f,occupancyDecay=0.94f;
  // Measured Kinect v1 channel coordinates in metres (channel 1..4).
  float[] microphoneXM={0.113f,-0.036f,-0.076f,-0.113f};
  // Voice-aware AUTO steering: only persistent, speech-like DOA candidates can move the beam.
  float voiceLowHz=100.0f,voiceHighHz=3600.0f,voiceBandMinRatio=0.56f;
  float vadSnrOnDb=10.0f,vadSnrOffDb=6.0f,vadProbability=0.70f,noiseFloorAdaptDown=0.16f,noiseFloorAdaptUp=0.006f;
  int vadAttackFrames=5,vadReleaseFrames=14;
  float autoConfidence=0.075f,autoMaxSpreadDeg=8.0f,autoDeadbandDeg=7.0f,autoMaxSlewDegPerSec=35.0f;
  int autoDwellFrames=16,autoHoldMs=1200,autoUpdateMinMs=90;
  float beamOutputGain=1.25f;
  // Spectral noise suppression after spatial beamforming.
  boolean noiseSuppress=true;float noiseOverSubtract=1.35f,noiseMinGain=0.10f,noiseAdapt=0.035f,noiseSpeechAdapt=0.0015f;
  int beamQueueFrames=10,beamLineBufferBytes=8192;
  float locateXMinM=-2.5f,locateXMaxM=2.5f,locateZMinM=0.30f,locateZMaxM=4.0f;
  int locateXSteps=51,locateZSteps=38;

  void load(File file){
    Properties p=studio.services.configRules.load(file,"acoustic");
      uiFrameRate=intValue(p,"ui.frameRate",uiFrameRate,10,120);
      uiFontFamily=textValue(p,"ui.font.family",uiFontFamily);
      uiHeadingFontFamily=textValue(p,"ui.font.headingFamily",uiHeadingFontFamily);
      uiFontFallback=textValue(p,"ui.font.fallback",uiFontFallback);
      workerJoinMs=intValue(p,"lifecycle.workerJoinMs",workerJoinMs,250,10000);
      reconnectMs=intValue(p,"transport.reconnectMs",reconnectMs,50,5000);
      pipeOpenAttempts=intValue(p,"transport.pipeOpenAttempts",pipeOpenAttempts,1,20);
      pipeOpenRetryMs=intValue(p,"transport.pipeOpenRetryMs",pipeOpenRetryMs,10,1000);
      noFrameWarningMs=intValue(p,"transport.noFrameWarningMs",noFrameWarningMs,250,30000);
      connectionStaleMs=intValue(p,"transport.connectionStaleMs",connectionStaleMs,500,30000);
      soundSpeedMps=floatValue(p,"scan.soundSpeedMps",soundSpeedMps,250,400);
      minimumRms=floatValue(p,"scan.minimumRms",minimumRms,0,0.5f);
      occupancyDecay=floatValue(p,"scan.occupancyDecay",occupancyDecay,0,0.9999f);
      voiceLowHz=floatValue(p,"voice.lowHz",voiceLowHz,40,500);
      voiceHighHz=floatValue(p,"voice.highHz",voiceHighHz,1000,7500);
      voiceBandMinRatio=floatValue(p,"voice.bandMinRatio",voiceBandMinRatio,0.10f,0.95f);
      vadSnrOnDb=floatValue(p,"voice.snrOnDb",vadSnrOnDb,0,40);
      vadSnrOffDb=floatValue(p,"voice.snrOffDb",vadSnrOffDb,0,vadSnrOnDb);
      vadProbability=floatValue(p,"voice.probability",vadProbability,0.10f,0.99f);
      vadAttackFrames=intValue(p,"voice.attackFrames",vadAttackFrames,1,60);
      vadReleaseFrames=intValue(p,"voice.releaseFrames",vadReleaseFrames,1,120);
      noiseFloorAdaptDown=floatValue(p,"voice.noiseAdaptDown",noiseFloorAdaptDown,0.001f,1);
      noiseFloorAdaptUp=floatValue(p,"voice.noiseAdaptUp",noiseFloorAdaptUp,0.0001f,0.2f);
      autoConfidence=floatValue(p,"beam.autoConfidence",autoConfidence,0,1);
      autoMaxSpreadDeg=floatValue(p,"beam.autoMaxSpreadDeg",autoMaxSpreadDeg,2,45);
      autoDeadbandDeg=floatValue(p,"beam.autoDeadbandDeg",autoDeadbandDeg,0,30);
      autoMaxSlewDegPerSec=floatValue(p,"beam.autoMaxSlewDegPerSec",autoMaxSlewDegPerSec,5,180);
      autoDwellFrames=intValue(p,"beam.autoDwellFrames",autoDwellFrames,2,120);
      autoHoldMs=intValue(p,"beam.autoHoldMs",autoHoldMs,0,5000);
      autoUpdateMinMs=intValue(p,"beam.autoUpdateMinMs",autoUpdateMinMs,10,1000);
      beamOutputGain=floatValue(p,"beam.outputGain",beamOutputGain,0.1f,8.0f);
      noiseSuppress=boolValue(p,"noise.enabled",noiseSuppress);
      noiseOverSubtract=floatValue(p,"noise.overSubtract",noiseOverSubtract,0.2f,4.0f);
      noiseMinGain=floatValue(p,"noise.minGain",noiseMinGain,0.0f,1.0f);
      noiseAdapt=floatValue(p,"noise.adapt",noiseAdapt,0.0001f,0.5f);
      noiseSpeechAdapt=floatValue(p,"noise.speechAdapt",noiseSpeechAdapt,0.00001f,0.05f);
      beamQueueFrames=intValue(p,"beam.queueFrames",beamQueueFrames,2,64);
      beamLineBufferBytes=intValue(p,"beam.lineBufferBytes",beamLineBufferBytes,512,131072);
      locateXMinM=floatValue(p,"locate.xMinM",locateXMinM,-10,0);
      locateXMaxM=floatValue(p,"locate.xMaxM",locateXMaxM,0,10);
      locateZMinM=floatValue(p,"locate.zMinM",locateZMinM,0.1f,10);
      locateZMaxM=floatValue(p,"locate.zMaxM",locateZMaxM,locateZMinM,15);
      locateXSteps=intValue(p,"locate.xSteps",locateXSteps,11,121);
      locateZSteps=intValue(p,"locate.zSteps",locateZSteps,8,100);
      float[] parsed=floatList(p.getProperty("geometry.microphoneXM"),4);
      if(parsed!=null)microphoneXM=parsed;
  }
  float[] floatList(String value,int count){return studio.services.configRules.decimalList(value,count);}
  String textValue(Properties p,String k,String f){return studio.services.configRules.text(p,k,f);}
  int intValue(Properties p,String k,int f,int lo,int hi){return studio.services.configRules.integer(p,k,f,lo,hi);}
  boolean boolValue(Properties p,String k,boolean f){return studio.services.configRules.flag(p,k,f);}
  float floatValue(Properties p,String k,float f,float lo,float hi){return studio.services.configRules.decimal(p,k,f,lo,hi);}
}


// ===== SynKinect Studio / Acoustic Scanner / AcousticDsp.pde =====
class AcousticScanFrame {
  long frameNumber,tickMs;
  float rms,azimuthDeg,confidence,peakScore,positionXM=Float.NaN,positionZM=Float.NaN,positionScore=0;
  float noiseFloorRms=0,snrDb=0,voiceBandRatio=0,voiceProbability=0;boolean speech=false,autoEligible=false;
  float[] directional=new float[181];
  float[] occupancy=new float[181];
}

class AcousticAutoSteerer {
  final AcousticConfig cfg;final float[] angleHistory=new float[96],weightHistory=new float[96];int historyCount=0,historyHead=0;
  long lastVoiceMs=0,lastUpdateMs=0;float lockedAngle=0;boolean locked=false;
  AcousticAutoSteerer(AcousticConfig c){cfg=c;}
  void reset(){historyCount=historyHead=0;lastVoiceMs=lastUpdateMs=0;locked=false;lockedAngle=0;}
  float update(AcousticScanFrame scan,float current,long now){
    if(scan==null)return current;long clock=scan.tickMs>0?scan.tickMs:(scan.frameNumber>0?scan.frameNumber*16L:now);
    if(scan.autoEligible){lastVoiceMs=clock;push(scan.azimuthDeg,max(0.005f,scan.voiceProbability*max(.02f,scan.confidence)));}
    else{if(lastVoiceMs>0&&clock-lastVoiceMs>cfg.autoHoldMs){historyCount=0;locked=false;}return current;}
    RobustCluster cluster=bestCluster();
    if(cluster==null||cluster.count<cfg.autoDwellFrames||cluster.inlierFraction<.62f||cluster.spread>cfg.autoMaxSpreadDeg)return current;
    lockedAngle=cluster.mean;locked=true;
    long elapsed=lastUpdateMs==0?cfg.autoUpdateMinMs:clock-lastUpdateMs;if(elapsed<cfg.autoUpdateMinMs)return current;
    lastUpdateMs=clock;
    float delta=lockedAngle-current;if(abs(delta)<=cfg.autoDeadbandDeg)return current;
    float maxStep=cfg.autoMaxSlewDegPerSec*constrain(elapsed/1000.0f,.010f,.25f);
    return constrain(current+constrain(delta,-maxStep,maxStep),-90,90);
  }
  void push(float angle,float weight){int cap=min(angleHistory.length,max(cfg.autoDwellFrames*4,32));angleHistory[historyHead]=angle;weightHistory[historyHead]=weight;historyHead=(historyHead+1)%cap;if(historyCount<cap)historyCount++;}
  RobustCluster bestCluster(){if(historyCount==0)return null;int cap=min(angleHistory.length,max(cfg.autoDwellFrames*4,32));float radius=max(cfg.autoMaxSpreadDeg*1.8f,10.0f),total=0;for(int i=0;i<historyCount;i++){int q=(historyHead-1-i+cap)%cap;total+=max(.001f,weightHistory[q]);}
    RobustCluster best=null;for(int c=0;c<historyCount;c++){int cq=(historyHead-1-c+cap)%cap;float center=angleHistory[cq],sw=0,sx=0;int count=0;for(int i=0;i<historyCount;i++){int q=(historyHead-1-i+cap)%cap,dummy=0;float d=abs(angleHistory[q]-center);if(d>radius)continue;float w=max(.001f,weightHistory[q]);sw+=w;sx+=angleHistory[q]*w;count++;}if(count<cfg.autoDwellFrames||sw<=0)continue;float mean=sx/sw,var=0;for(int i=0;i<historyCount;i++){int q=(historyHead-1-i+cap)%cap;float d=angleHistory[q]-mean;if(abs(d)>radius)continue;float w=max(.001f,weightHistory[q]);var+=d*d*w;}float spread=sqrt(var/sw),fraction=sw/max(.001f,total);if(best==null||sw>best.weight)best=new RobustCluster(mean,spread,fraction,sw,count);}
    return best;
  }
  class RobustCluster {final float mean,spread,inlierFraction,weight;final int count;RobustCluster(float m,float s,float f,float w,int c){mean=m;spread=s;inlierFraction=f;weight=w;count=c;}}
}

class VoiceNoiseSuppressor {
  final AcousticConfig cfg;final int N=512,H=256;final float[] prev=new float[H],re=new float[N],im=new float[N],noise=new float[N/2+1],gain=new float[N/2+1],ola=new float[N];boolean initialized=false;
  VoiceNoiseSuppressor(AcousticConfig c){cfg=c;Arrays.fill(gain,1.0f);}
  void reset(){Arrays.fill(prev,0);Arrays.fill(noise,0);Arrays.fill(gain,1);Arrays.fill(ola,0);initialized=false;}
  short[] process(short[] input,AcousticScanFrame scan,AcousticEngine fftOwner){if(!cfg.noiseSuppress||input==null||input.length!=H)return input;boolean firstBlock=!initialized;
    for(int i=0;i<N;i++){float x=i<H?prev[i]:input[i-H]/32768.0f;float w=sqrt(max(0,0.5f-0.5f*(float)Math.cos(2*Math.PI*i/(N-1))));re[i]=x*w;im[i]=0;}for(int i=0;i<H;i++)prev[i]=input[i]/32768.0f;fftOwner.fft(re,im,false);
    float adapt=(scan!=null&&scan.speech)?cfg.noiseSpeechAdapt:cfg.noiseAdapt;
    for(int k=0;k<=N/2;k++){float p=re[k]*re[k]+im[k]*im[k]+1e-12f;if(!initialized)noise[k]=p;else noise[k]=noise[k]*(1-adapt)+p*adapt;float raw=(p-cfg.noiseOverSubtract*noise[k])/p;float g=sqrt(constrain(raw,cfg.noiseMinGain*cfg.noiseMinGain,1));gain[k]=.72f*gain[k]+.28f*g;re[k]*=gain[k];im[k]*=gain[k];if(k>0&&k<N/2){int mirror=N-k;re[mirror]*=gain[k];im[mirror]*=gain[k];}}initialized=true;if(firstBlock){Arrays.fill(ola,0);return input;}fftOwner.fft(re,im,true);short[] out=new short[H];
    for(int i=0;i<N;i++){float w=sqrt(max(0,0.5f-0.5f*(float)Math.cos(2*Math.PI*i/(N-1))));ola[i]+=re[i]*w;}float gate=(scan!=null&&scan.voiceProbability<.22f&&scan.snrDb<cfg.vadSnrOffDb)?.28f:1.0f;for(int i=0;i<H;i++){float v=constrain(ola[i]*gate,-1,1);out[i]=(short)Math.round(v*32767);ola[i]=ola[i+H];ola[i+H]=0;}return out;}
}

class AcousticEngine {
  final int FFT=512,BINS=181;
 final AcousticConfig cfg;
 final int[][] pairs={{0,1},{0,2},{0,3},{1,2},{1,3},{2,3}};
 final float[][] spectrumRe=new float[4][FFT],spectrumIm=new float[4][FFT];
 final float[][] pairCorr=new float[6][FFT];
 final float[] corrRe=new float[FFT],corrIm=new float[FFT];
 final float[] occupancy=new float[BINS];
 final VoiceNoiseSuppressor suppressor;float noiseFloorRms=0.0015f;AcousticScanFrame lastScan=null;
 int voiceAttackCount=0,voiceReleaseCount=0;boolean voiceLatched=false;

  AcousticEngine(AcousticConfig cfg){this.cfg=cfg;suppressor=new VoiceNoiseSuppressor(cfg);}
  void reset(){Arrays.fill(occupancy,0);noiseFloorRms=0.0015f;lastScan=null;suppressor.reset();}

  AcousticScanFrame process(SpatialAudioFrame frame){
    AcousticScanFrame out=new AcousticScanFrame();out.frameNumber=frame.frameNumber;out.tickMs=frame.tickMs;float rmsAccum=0;
    for(int ch=0;ch<4;ch++)rmsAccum+=prepare(frame.samples[ch],spectrumRe[ch],spectrumIm[ch]);
    out.rms=sqrt(rmsAccum/(4.0f*SpatialAudioFrame.SAMPLES));
    buildCorrelations();
    float minScore=Float.MAX_VALUE,maxScore=-Float.MAX_VALUE;int peak=0;
    for(int bin=0;bin<BINS;bin++){
      float deg=-90+bin,s=(float)Math.sin(Math.toRadians(deg)),score=0;
      for(int p=0;p<pairs.length;p++){
        int a=pairs[p][0],b=pairs[p][1];float dx=cfg.microphoneXM[b]-cfg.microphoneXM[a];float lag=dx*s*16000/cfg.soundSpeedMps;
        score+=corrAt(pairCorr[p],lag);
      }
      out.directional[bin]=score;if(score<minScore)minScore=score;if(score>maxScore){maxScore=score;peak=bin;}
    }
    float span=maxScore-minScore,second=0;
    for(int bin=0;bin<BINS;bin++){
      float normalized=span>1e-9f?(out.directional[bin]-minScore)/span:0;out.directional[bin]=normalized;
      if(bin+3<peak||bin>peak+3)second=max(second,normalized);
      float injection=out.rms>=cfg.minimumRms?normalized*constrain(out.rms*8.0f,0,1):0;
      occupancy[bin]=cfg.occupancyDecay*occupancy[bin]+(1-cfg.occupancyDecay)*injection;out.occupancy[bin]=occupancy[bin];
    }
    float refined=-90+peak;if(peak>0&&peak+1<BINS){float y0=out.directional[peak-1],y1=out.directional[peak],y2=out.directional[peak+1],d=y0-2*y1+y2;if(abs(d)>1e-6f)refined+=constrain(0.5f*(y0-y2)/d,-0.5f,0.5f);}
    out.azimuthDeg=refined;out.peakScore=out.directional[peak];out.confidence=constrain(out.peakScore-second,0,1);
    evaluateVoice(out);locateNearField(out);
    // Range from a linear four-microphone array is only an approximate display aid.
    // AUTO steering is therefore gated by speech evidence + angular confidence, not by the coarse x/z estimate.
    out.autoEligible=out.speech&&out.confidence>=cfg.autoConfidence*.25f;lastScan=out;
    return out;
  }

  void evaluateVoice(AcousticScanFrame out){
    double total=0,voice=0;int nyquist=FFT/2;for(int k=1;k<nyquist;k++){float hz=k*16000.0f/FFT;double p=0;for(int ch=0;ch<4;ch++)p+=spectrumRe[ch][k]*spectrumRe[ch][k]+spectrumIm[ch][k]*spectrumIm[ch][k];total+=p;if(hz>=cfg.voiceLowHz&&hz<=cfg.voiceHighHz)voice+=p;}
    out.voiceBandRatio=(float)(voice/Math.max(1e-12,total));
    float rawNoise=max(1e-6f,noiseFloorRms),snr=20.0f*(float)Math.log10(max(1e-6f,out.rms)/rawNoise);out.snrDb=snr;out.noiseFloorRms=noiseFloorRms;
    float snrScore=smooth01(cfg.vadSnrOffDb,cfg.vadSnrOnDb+5,snr),bandScore=smooth01(cfg.voiceBandMinRatio-.12f,cfg.voiceBandMinRatio+.18f,out.voiceBandRatio),energyScore=smooth01(cfg.minimumRms,cfg.minimumRms*3.5f,out.rms),doaScore=smooth01(cfg.autoConfidence*.45f,max(cfg.autoConfidence+.10f,.24f),out.confidence);
    out.voiceProbability=constrain(.40f*snrScore+.31f*bandScore+.17f*energyScore+.12f*doaScore,0,1);
    boolean strongVoice=out.rms>=cfg.minimumRms&&out.snrDb>=cfg.vadSnrOnDb&&out.voiceBandRatio>=cfg.voiceBandMinRatio&&out.voiceProbability>=cfg.vadProbability;
    boolean sustainVoice=out.rms>=cfg.minimumRms*.80f&&out.snrDb>=cfg.vadSnrOffDb&&out.voiceBandRatio>=cfg.voiceBandMinRatio*.88f&&out.voiceProbability>=cfg.vadProbability*.78f;
    if(!voiceLatched){if(strongVoice){voiceAttackCount++;if(voiceAttackCount>=cfg.vadAttackFrames){voiceLatched=true;voiceReleaseCount=0;}}else voiceAttackCount=0;}
    else{if(sustainVoice)voiceReleaseCount=0;else if(++voiceReleaseCount>=cfg.vadReleaseFrames){voiceLatched=false;voiceAttackCount=0;voiceReleaseCount=0;}}
    out.speech=voiceLatched;
    float a=out.rms<noiseFloorRms?cfg.noiseFloorAdaptDown:(out.speech?cfg.noiseSpeechAdapt:cfg.noiseFloorAdaptUp);noiseFloorRms=constrain(lerp(noiseFloorRms,max(1e-6f,out.rms),a),1e-6f,.10f);out.noiseFloorRms=noiseFloorRms;
  }
  float smooth01(float lo,float hi,float v){if(hi<=lo)return v>=hi?1:0;float t=constrain((v-lo)/(hi-lo),0,1);return t*t*(3-2*t);}

  void locateNearField(AcousticScanFrame out){
    if(out.rms<cfg.minimumRms)return;
    float best=-Float.MAX_VALUE,bestX=Float.NaN,bestZ=Float.NaN;
    int xs=max(2,cfg.locateXSteps),zs=max(2,cfg.locateZSteps);
    for(int iz=0;iz<zs;iz++){
      float z=lerp(cfg.locateZMinM,cfg.locateZMaxM,iz/(float)(zs-1));
      for(int ix=0;ix<xs;ix++){
        float x=lerp(cfg.locateXMinM,cfg.locateXMaxM,ix/(float)(xs-1));
        float score=0;
        for(int p=0;p<pairs.length;p++){
          int a=pairs[p][0],b=pairs[p][1];
          float da=sqrt((x-cfg.microphoneXM[a])*(x-cfg.microphoneXM[a])+z*z);
          float db=sqrt((x-cfg.microphoneXM[b])*(x-cfg.microphoneXM[b])+z*z);
          // GCC-PHAT lag convention used by the far-field scan above.
          float lag=-(db-da)*16000/cfg.soundSpeedMps;
          score+=corrAt(pairCorr[p],lag);
        }
        if(score>best){best=score;bestX=x;bestZ=z;}
      }
    }
    if(Float.isFinite(bestX)&&Float.isFinite(bestZ)){out.positionXM=bestX;out.positionZM=bestZ;out.positionScore=best;}
  }

  short[] beamform(SpatialAudioFrame frame,float azimuthDeg){
    int n=SpatialAudioFrame.SAMPLES;short[] out=new short[n];
    float center=0;for(float x:cfg.microphoneXM)center+=x;center/=cfg.microphoneXM.length;
    float steer=(float)Math.sin(Math.toRadians(constrain(azimuthDeg,-90,90)));
    for(int i=0;i<n;i++){
      double sum=0;int valid=0;
      for(int ch=0;ch<4;ch++){
        if(!frame.valid(ch))continue;
        float shift=(cfg.microphoneXM[ch]-center)*steer*16000/cfg.soundSpeedMps;
        sum+=sampleLinear(frame.samples[ch],i-shift)/2147483648.0;valid++;
      }
      double v=valid==0?0:(sum/valid)*cfg.beamOutputGain;
      v=Math.max(-1.0,Math.min(1.0,v));out[i]=(short)Math.round(v*32767.0);
    }
    return suppressor.process(out,lastScan,this);
  }
  float sampleLinear(int[] data,float index){
    int i0=(int)Math.floor(index);float f=index-i0;if(i0<0||i0>=data.length)return 0;int i1=i0+1;
    float a=data[i0],b=i1<data.length?data[i1]:a;return a+(b-a)*f;
  }

  float prepare(int[] samples,float[] re,float[] im){
    Arrays.fill(re,0);Arrays.fill(im,0);double mean=0;for(int v:samples)mean+=v;mean/=samples.length;float e=0;
    for(int i=0;i<samples.length;i++){float x=(float)(((double)samples[i]-mean)/2147483648.0);float w=0.5f-0.5f*(float)Math.cos(2*Math.PI*i/(samples.length-1));float v=x*w;re[i]=v;e+=v*v;}
    fft(re,im,false);return e;
  }
  void buildCorrelations(){
    for(int p=0;p<pairs.length;p++){int a=pairs[p][0],b=pairs[p][1];
      for(int k=0;k<FFT;k++){float ar=spectrumRe[a][k],ai=spectrumIm[a][k],br=spectrumRe[b][k],bi=spectrumIm[b][k],cr=ar*br+ai*bi,ci=ai*br-ar*bi,mag=sqrt(cr*cr+ci*ci)+1e-12f;corrRe[k]=cr/mag;corrIm[k]=ci/mag;}
      fft(corrRe,corrIm,true);arrayCopy(corrRe,pairCorr[p]);
    }
  }
  float corrAt(float[] corr,float lag){float w=lag;while(w<0)w+=FFT;while(w>=FFT)w-=FFT;int i0=(int)Math.floor(w),i1=(i0+1)%FFT;float f=w-i0;return corr[i0]*(1-f)+corr[i1]*f;}
  void fft(float[] re,float[] im,boolean inverse){
    int n=re.length,j=0;for(int i=1;i<n;i++){int bit=n>>1;for(;((j&bit)!=0);bit>>=1)j^=bit;j^=bit;if(i<j){float t=re[i];re[i]=re[j];re[j]=t;t=im[i];im[i]=im[j];im[j]=t;}}
    for(int len=2;len<=n;len<<=1){double ang=(inverse?2:-2)*Math.PI/len;float wr0=(float)Math.cos(ang),wi0=(float)Math.sin(ang);for(int i=0;i<n;i+=len){float wr=1,wi=0;for(int k=0;k<len/2;k++){int q=i+k+len/2;float vr=re[q]*wr-im[q]*wi,vi=re[q]*wi+im[q]*wr,ur=re[i+k],ui=im[i+k];re[i+k]=ur+vr;im[i+k]=ui+vi;re[q]=ur-vr;im[q]=ui-vi;float nr=wr*wr0-wi*wi0;wi=wr*wi0+wi*wr0;wr=nr;}}}
    if(inverse)for(int i=0;i<n;i++){re[i]/=n;im[i]/=n;}
  }
}


// ===== SynKinect Studio / Acoustic Scanner / AcousticLocalization.pde =====
class AcousticI18n extends ModuleI18n {
  AcousticI18n(String requested){super("acoustic",requested);}
}


class AcousticTheme {
  final int BG=0xFF11151A,SURFACE=0xFF181E25,SURFACE2=0xFF202832,RAISED=0xFF293440;
  final int BORDER=0xFF35414D,TEXT=0xFFF4F7FA,MUTED=0xFFAAB6C2,GRID=0xFF35404A,ACTIVE=0xFF68A9E8,GOOD=0xFF7CC7A0,WARN=0xFFE4B86B;
  final int MARGIN=20,GAP=14,HEADER_H=68,RADIUS=14,CARD_TITLE_H=44;
  final int FONT_TINY=12,FONT_SMALL=14,FONT_BODY=15,FONT_LABEL=16,FONT_METRIC=19,FONT_TITLE=27;
}

PFont acousticFontRegular,acousticFontHeading;
void initializeAcousticTypography(){
  String regular="SansSerif";
  String heading="SansSerif";
  acousticFontRegular=createFont(regular,studio.services.acousticTheme.FONT_BODY,true);
  acousticFontHeading=createFont(heading,studio.services.acousticTheme.FONT_TITLE,true);
  textFont(acousticFontRegular);textLeading(studio.services.acousticTheme.FONT_BODY*1.28f);
}
String resolveAcousticFont(String preferred,String fallback){String[] installed=PFont.list();String hit=findAcousticFont(installed,preferred);if(hit!=null)return hit;hit=findAcousticFont(installed,fallback);return hit==null?"SansSerif":hit;}
String findAcousticFont(String[] installed,String wanted){if(wanted==null||wanted.trim().length()==0||installed==null)return null;for(String candidate:installed)if(candidate.equalsIgnoreCase(wanted.trim()))return candidate;return null;}
void acousticText(float size,boolean heading){PFont f=heading?acousticFontHeading:acousticFontRegular;if(f!=null)textFont(f);textSize(responsiveFontSize(size));}


// ===== SynKinect Studio / Acoustic Scanner / AcousticProtocol.pde =====
class AcousticProtocol {
  final int MAGIC=0x414D4D52;
  final int FRAME_MAGIC=0x464D4D52;
  final int VERSION=1;
  final int CMD_SUBSCRIBE=1;
  final int SAMPLE_RATE=16000;
  final int CHANNELS=4;
  final int SAMPLES=256;
  final int SAMPLE_FORMAT_S32LE=1;
  final int BYTES_PER_SAMPLE=4;
  final int PAYLOAD_BYTES=CHANNELS*SAMPLES*BYTES_PER_SAMPLE;
  final int REQUEST_BYTES=16;
  final int REPLY_BYTES=32;
  final int HEADER_BYTES=48;
  final int REQUIRED_CAPABILITIES=0x3;
  final int VALID_CHANNEL_MASK=(1<<CHANNELS)-1;
}

class SpatialAudioFrame {
  static final int CHANNELS=4;
  static final int SAMPLES=256;
  long frameNumber,tickMs;
  int channelMask;
  int[][] samples=new int[CHANNELS][SAMPLES];
  float[] peak=new float[CHANNELS];
  boolean valid(int channel){return channel>=0&&channel<CHANNELS&&(channelMask&(1<<channel))!=0;}
}

class AcousticAudioFrame extends SpatialAudioFrame {
}


// ===== SynKinect Studio / Acoustic Scanner / AcousticSource.pde =====
class AcousticSource {
 final AcousticConfig cfg;
 final Object frameLock=new Object(),pipeLock=new Object();
  volatile boolean running=false,connected=false;
  volatile long runGeneration=0;
  volatile String stateKey="source.starting",detail="";
  volatile long frameCount=0,connectedSinceMs=0,lastFrameArrivalMs=0,connectionEpoch=0,reconnectKicks=0,lastReconnectKickMs=0;
  volatile String connectedPipe="";
  volatile LocalTransport activePipe;
  Thread worker;AcousticAudioFrame latest;

  AcousticSource(AcousticConfig cfg){this.cfg=cfg;}
  synchronized void start(){if(running)return;running=true;final long generation=++runGeneration;worker=studio.services.workers.start("Acoustic-Port",new Runnable(){public void run(){loop(generation);}});}
  void requestStop(){Thread t;synchronized(this){running=false;++runGeneration;closeActivePipe();t=worker;worker=null;}if(t!=null)t.interrupt();connected=false;}
  void stop(){Thread t;synchronized(this){running=false;++runGeneration;closeActivePipe();t=worker;worker=null;}if(t!=null){t.interrupt();try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}}connected=false;}
  AcousticAudioFrame snapshot(){synchronized(frameLock){return latest;}}
  String displayStateKey(){
    if(!connected)return stateKey;long now=System.currentTimeMillis();
    if(lastFrameArrivalMs>0&&now-lastFrameArrivalMs>cfg.connectionStaleMs){requestReconnect("stale-session");return "source.reconnecting";}
    long anchor=lastFrameArrivalMs>0?lastFrameArrivalMs:connectedSinceMs;
    if(anchor>0&&now-anchor>cfg.noFrameWarningMs)return lastFrameArrivalMs>0?"source.stale":"source.no_frames";
    return stateKey;
  }
  void requestReconnect(String why){if(!running)return;long now=System.currentTimeMillis();if(now-lastReconnectKickMs<Math.max(100,cfg.reconnectMs))return;lastReconnectKickMs=now;reconnectKicks++;stateKey="source.reconnecting";detail=why;studio.services.workers.start("Acoustic-Reconnect",new Runnable(){public void run(){closeActivePipe();}});}
  void setActivePipe(LocalTransport p){synchronized(pipeLock){activePipe=p;}}
  void clearActivePipe(LocalTransport p){synchronized(pipeLock){if(activePipe==p)activePipe=null;}}
  void closeActivePipe(){LocalTransport p;synchronized(pipeLock){p=activePipe;activePipe=null;}closePipe(p);}
  void closePipe(LocalTransport p){if(p==null)return;try{p.close();}catch(IOException e){if(running)detail=safeMessage(e);}}

  void loop(long generation){
    while(running&&generation==runGeneration){LocalTransport pipe=null;
      try{
        connected=false;stateKey="source.connecting";detail="";lastFrameArrivalMs=0;
        pipe=openBestPipe();setActivePipe(pipe);subscribe(pipe);
        connected=true;connectedSinceMs=System.currentTimeMillis();connectionEpoch++;stateKey="source.streaming";
        long last=-1;byte[] hb=new byte[studio.services.acousticProtocol.HEADER_BYTES],payload=new byte[studio.services.acousticProtocol.PAYLOAD_BYTES];
        while(running&&generation==runGeneration){
          pipe.readFully(hb);ByteBuffer h=ByteBuffer.wrap(hb).order(ByteOrder.LITTLE_ENDIAN);
          int magic=h.getInt(),version=h.getInt(),rate=h.getInt(),channels=h.getInt(),format=h.getInt(),samples=h.getInt(),bytes=h.getInt(),mask=h.getInt();long number=h.getLong(),tick=h.getLong();
          if(magic!=studio.services.acousticProtocol.FRAME_MAGIC||version!=studio.services.acousticProtocol.VERSION||rate!=16000||channels!=studio.services.acousticProtocol.CHANNELS||format!=studio.services.acousticProtocol.SAMPLE_FORMAT_S32LE||samples!=SpatialAudioFrame.SAMPLES||bytes!=studio.services.acousticProtocol.PAYLOAD_BYTES)throw new IOException("protocol-frame");
          if(mask==0||(mask&~studio.services.acousticProtocol.VALID_CHANNEL_MASK)!=0)throw new IOException("protocol-channel-mask");
          if(last>=0&&number<=last)throw new IOException("protocol-order");last=number;
          pipe.readFully(payload);AcousticAudioFrame frame=decode(payload,number,tick,mask);synchronized(frameLock){latest=frame;}frameCount++;lastFrameArrivalMs=System.currentTimeMillis();
          AcousticScanFrame scan=studio.acousticState.engine.process(frame);studio.acousticState.scan=scan;
          float target=studio.acousticState.manualAzimuthDeg;
          if(studio.acousticState.automaticBeam&&studio.acousticState.autoSteerer!=null)target=studio.acousticState.autoSteerer.update(scan,studio.acousticState.beamAzimuthDeg,System.currentTimeMillis());
          studio.acousticState.beamAzimuthDeg=constrain(target,-90,90);
          if(studio.acousticState.output!=null)studio.acousticState.output.offer(studio.acousticState.engine.beamform(frame,studio.acousticState.beamAzimuthDeg));
        }
      }catch(IOException e){if(generation==runGeneration){connected=false;if(running){stateKey="source.reconnecting";detail=safeMessage(e);}}}
      finally{clearActivePipe(pipe);closePipe(pipe);}
      if(running&&generation==runGeneration)try{Thread.sleep(cfg.reconnectMs);}catch(InterruptedException e){if(!running||generation!=runGeneration)return;Thread.currentThread().interrupt();return;}
    }
  }

  LocalTransport openPipeWithRetry(String pipeName,String socketName)throws IOException{
    IOException last=null;
    for(int attempt=1;attempt<=cfg.pipeOpenAttempts&&running;attempt++){
      try{return studio.services.transportFactory.open(pipeName,socketName);}
      catch(IOException e){
        last=e;
        if(attempt<cfg.pipeOpenAttempts){
          try{Thread.sleep(cfg.pipeOpenRetryMs);}
          catch(InterruptedException interrupted){Thread.currentThread().interrupt();throw new IOException("pipe-open interrupted",interrupted);}
        }
      }
    }
    throw last==null?new IOException("raw audio bus unavailable"):last;
  }

  LocalTransport openBestPipe()throws IOException{LocalTransport pipe=openPipeWithRetry(studio.services.endpoints.audio.windowsPath,studio.services.endpoints.audio.linuxPath);connectedPipe=studio.services.endpoints.audio.label;return pipe;}
  void subscribe(LocalTransport pipe)throws IOException{
    ByteBuffer q=ByteBuffer.allocate(studio.services.acousticProtocol.REQUEST_BYTES).order(ByteOrder.LITTLE_ENDIAN);q.putInt(studio.services.acousticProtocol.MAGIC);q.putInt(studio.services.acousticProtocol.VERSION);q.putInt(studio.services.acousticProtocol.CMD_SUBSCRIBE);q.putInt(0);pipe.write(q.array());
    byte[] rb=new byte[studio.services.acousticProtocol.REPLY_BYTES];pipe.readFully(rb);ByteBuffer r=ByteBuffer.wrap(rb).order(ByteOrder.LITTLE_ENDIAN);int magic=r.getInt(),version=r.getInt(),result=r.getInt(),rate=r.getInt(),channels=r.getInt(),format=r.getInt(),maxPayload=r.getInt(),caps=r.getInt();
    if(magic!=studio.services.acousticProtocol.MAGIC||version!=studio.services.acousticProtocol.VERSION||result<0||rate!=16000||channels!=studio.services.acousticProtocol.CHANNELS||format!=studio.services.acousticProtocol.SAMPLE_FORMAT_S32LE||maxPayload<studio.services.acousticProtocol.PAYLOAD_BYTES||(caps&studio.services.acousticProtocol.REQUIRED_CAPABILITIES)!=studio.services.acousticProtocol.REQUIRED_CAPABILITIES)throw new IOException("protocol-subscribe");
  }
  AcousticAudioFrame decode(byte[] payload,long number,long tick,int mask){
    AcousticAudioFrame f=new AcousticAudioFrame();f.frameNumber=number;f.tickMs=tick;f.channelMask=mask;ByteBuffer b=ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN);
    for(int n=0;n<SpatialAudioFrame.SAMPLES;n++)for(int ch=0;ch<studio.services.acousticProtocol.CHANNELS;ch++)f.samples[ch][n]=b.getInt();
    for(int ch=0;ch<studio.services.acousticProtocol.CHANNELS;ch++){long peak=0;for(int n=0;n<SpatialAudioFrame.SAMPLES;n++){long v=f.samples[ch][n];long a=v==Integer.MIN_VALUE?2147483648L:Math.abs(v);if(a>peak)peak=a;}f.peak[ch]=peak/2147483648.0f;}
    return f;
  }
  String pipeModeKey(){return "source.pipe_dedicated";}
  String safeMessage(Exception e){String m=e.getMessage();return m==null||m.length()==0?e.getClass().getSimpleName():m;}
}


// ===== SynKinect Studio / Acoustic Scanner / Beamformed Windows output =====
class AcousticBeamOutput {
  final AcousticConfig cfg;final Object lock=new Object();final ArrayDeque<short[]> queue=new ArrayDeque<short[]>();
  volatile boolean running=false;volatile long runGeneration=0;volatile String stateKey="output.idle",detail="";volatile long dropped=0,frames=0;Thread worker;SourceDataLine line;
  AcousticBeamOutput(AcousticConfig cfg){this.cfg=cfg;}
  synchronized void start(){if(running)return;running=true;stateKey="output.starting";final long generation=++runGeneration;worker=studio.services.workers.start("Acoustic-BeamOutput",new Runnable(){public void run(){loop(generation);}});}
  void offer(short[] pcm){if(!running||pcm==null)return;synchronized(lock){while(queue.size()>=cfg.beamQueueFrames){queue.removeFirst();dropped++;}queue.addLast(pcm);lock.notifyAll();}}
  void requestStop(){Thread t;running=false;++runGeneration;synchronized(lock){queue.clear();lock.notifyAll();}closeLine();t=worker;worker=null;if(t!=null&&t!=Thread.currentThread())t.interrupt();if(!"output.error".equals(stateKey))stateKey="output.idle";}
  void stop(){running=false;++runGeneration;synchronized(lock){lock.notifyAll();}closeLine();Thread t=worker;worker=null;if(t!=null&&t!=Thread.currentThread()){t.interrupt();try{t.join(cfg.workerJoinMs);}catch(InterruptedException e){Thread.currentThread().interrupt();}}synchronized(lock){queue.clear();}if(!"output.error".equals(stateKey))stateKey="output.idle";}
  void loop(long generation){
    SourceDataLine local=null;
    try{
      AudioFormat fmt=new AudioFormat((float)16000,16,1,true,false);
      local=(SourceDataLine)AudioSystem.getLine(new DataLine.Info(SourceDataLine.class,fmt));
      local.open(fmt,cfg.beamLineBufferBytes);local.start();
      synchronized(lock){if(generation==runGeneration)line=local;}
      if(generation==runGeneration)stateKey="output.live";
      while(running&&generation==runGeneration){
        short[] block=null;
        synchronized(lock){
          while(running&&generation==runGeneration&&queue.isEmpty())try{lock.wait(100);}catch(InterruptedException e){if(!running||generation!=runGeneration)return;}
          if(!queue.isEmpty())block=queue.removeFirst();
        }
        if(block==null)continue;
        ByteBuffer b=ByteBuffer.allocate(block.length*2).order(ByteOrder.LITTLE_ENDIAN);for(short v:block)b.putShort(v);
        local.write(b.array(),0,b.position());frames++;
      }
    }catch(Exception e){if(generation==runGeneration){detail=safeStudioMessage(e);stateKey="output.error";}}
    finally{if(generation==runGeneration)running=false;closeLine(local);}
  }
  void closeLine(){SourceDataLine current;synchronized(lock){current=line;line=null;}closeLine(current);}
  void closeLine(SourceDataLine current){if(current==null)return;synchronized(lock){if(line==current)line=null;}try{current.stop();}catch(Exception ignored){}try{current.flush();}catch(Exception ignored){}try{current.close();}catch(Exception ignored){}}
}

// ===== SynKinect Studio / Acoustic Scanner / AcousticUI.pde =====
class AcousticUI {
  float resetX,resetY,resetW=104,buttonH=36,autoX,manualX,modeW=104;
  float radarCx,radarCy,radarR,radarX,radarY,radarW,radarH;

  float statusHeight(){return width<900?174:112;}
  void draw(AcousticAudioFrame frame,AcousticScanFrame scan){drawHeader();drawStatus(frame,scan);drawBody(frame,scan);}

  void drawHeader(){
    fill(studio.services.acousticTheme.TEXT);acousticText(studio.services.acousticTheme.FONT_TITLE,true);textAlign(LEFT,CENTER);
    float controls=resetW+modeW*2+24;String headerTitle=studio.acousticState.i18n.tr("app.title");fitCurrentTextSize(headerTitle,studio.services.acousticTheme.FONT_TITLE,10,max(80,width-controls-50),studio.services.acousticTheme.HEADER_H-12);text(ellipsizeToWidth(headerTitle,max(80,width-controls-50)),studio.services.acousticTheme.MARGIN,studio.services.acousticTheme.HEADER_H/2);textAlign(LEFT,BASELINE);
    resetX=width-studio.services.acousticTheme.MARGIN-resetW;resetY=15;manualX=resetX-8-modeW;autoX=manualX-8-modeW;
    button(autoX,resetY,modeW,buttonH,studio.acousticState.i18n.tr("button.auto"),studio.acousticState.automaticBeam);
    button(manualX,resetY,modeW,buttonH,studio.acousticState.i18n.tr("button.manual"),!studio.acousticState.automaticBeam);
    button(resetX,resetY,resetW,buttonH,studio.acousticState.i18n.tr("button.reset"),false);
  }

  void drawStatus(AcousticAudioFrame frame,AcousticScanFrame scan){
    float x=studio.services.acousticTheme.MARGIN,y=studio.services.acousticTheme.HEADER_H+studio.services.acousticTheme.GAP,w=width-2*studio.services.acousticTheme.MARGIN,h=statusHeight();card(x,y,w,h);cardTitle(x,y,w,studio.acousticState.i18n.tr("panel.status"));
    String state=studio.acousticState.source==null?"source.starting":studio.acousticState.source.displayStateKey(),transport=studio.acousticState.i18n.tr(state);
    String pos=scan==null||!Float.isFinite(scan.positionXM)?"—":nf(scan.positionXM,1,2)+" / "+nf(scan.positionZM,1,2)+" m";
    String voice=scan==null?"—":(scan.speech?studio.acousticState.i18n.format("voice.detected",scan.voiceProbability*100,scan.snrDb):studio.acousticState.i18n.format("voice.noise",scan.voiceProbability*100,scan.snrDb));
    String[] labels={studio.acousticState.i18n.tr("label.transport"),studio.acousticState.i18n.tr("label.frames"),studio.acousticState.i18n.tr("label.azimuth"),studio.acousticState.i18n.tr("label.position"),studio.acousticState.i18n.tr("label.beam"),studio.acousticState.i18n.tr("label.voice")};
    String[] values={transport,String.valueOf(studio.acousticState.source==null?0:studio.acousticState.source.frameCount),scan==null?"—":nf(scan.azimuthDeg,1,1)+"°",pos,nf(studio.acousticState.beamAzimuthDeg,1,1)+"°",voice};
    boolean[] active={studio.acousticState.source!=null&&studio.acousticState.source.connected,true,scan!=null,scan!=null&&Float.isFinite(scan.positionXM),true,scan!=null&&scan.speech};
    int cols=w<850?3:6,rows=(labels.length+cols-1)/cols;float ix=x+12,iy=y+studio.services.acousticTheme.CARD_TITLE_H,innerW=w-24,g=8,tw=(innerW-g*(cols-1))/cols,th=(h-studio.services.acousticTheme.CARD_TITLE_H-12-g*(rows-1))/rows;
    for(int i=0;i<labels.length;i++){int col=i%cols,row=i/cols;metric(ix+col*(tw+g),iy+row*(th+g),tw,th,labels[i],values[i],active[i]);}
  }

  void drawBody(AcousticAudioFrame frame,AcousticScanFrame scan){float x=studio.services.acousticTheme.MARGIN,y=studio.services.acousticTheme.HEADER_H+studio.services.acousticTheme.GAP+statusHeight()+studio.services.acousticTheme.GAP,w=width-2*studio.services.acousticTheme.MARGIN,h=max(120,studio.contentHeight-y-studio.services.acousticTheme.MARGIN);if(w>=820){float rightW=constrain(w*0.30f,240,min(360,w*.45f)),leftW=max(160,w-rightW-studio.services.acousticTheme.GAP);drawRadar(x,y,leftW,h,scan);drawMicLevels(x+leftW+studio.services.acousticTheme.GAP,y,rightW,h,frame);}else{float topH=max(70,(h-studio.services.acousticTheme.GAP)*.60f),bottomH=max(55,h-topH-studio.services.acousticTheme.GAP);if(topH+bottomH+studio.services.acousticTheme.GAP>h){float k=h/max(1,topH+bottomH+studio.services.acousticTheme.GAP);topH*=k;bottomH*=k;}drawRadar(x,y,w,topH,scan);drawMicLevels(x,y+topH+studio.services.acousticTheme.GAP,w,bottomH,frame);}}

  void drawRadar(float x,float y,float w,float h,AcousticScanFrame scan){
    radarX=x;radarY=y;radarW=w;radarH=h;card(x,y,w,h);cardTitle(x,y,w,studio.acousticState.i18n.tr("panel.radar"));
    float cx=x+w/2,cy=y+h-48,maxR=min(w*0.44f,(h-studio.services.acousticTheme.CARD_TITLE_H-40)*0.94f);radarCx=cx;radarCy=cy;radarR=maxR;stroke(studio.services.acousticTheme.GRID);noFill();
    for(int r=1;r<=4;r++)arc(cx,cy,maxR*r/2,maxR*r/2,PI,TWO_PI);for(int a=-90;a<=90;a+=30){float t=radians(a);line(cx,cy,cx+maxR*sin(t),cy-maxR*cos(t));}
    fill(studio.services.acousticTheme.MUTED);acousticText(studio.services.acousticTheme.FONT_TINY,false);textAlign(CENTER,CENTER);for(int a=-90;a<=90;a+=30){float t=radians(a);text(a+"°",cx+(maxR+18)*sin(t),cy-(maxR+18)*cos(t));}
    if(scan!=null){noStroke();fill(studio.services.acousticTheme.ACTIVE,42);beginShape();vertex(cx,cy);for(int i=0;i<scan.occupancy.length;i++){float t=radians(-90+i),r=maxR*(0.18f+0.82f*constrain(scan.occupancy[i]*5,0,1));vertex(cx+r*sin(t),cy-r*cos(t));}vertex(cx,cy);endShape(CLOSE);float t=radians(scan.azimuthDeg);stroke(studio.services.acousticTheme.ACTIVE);strokeWeight(2);line(cx,cy,cx+maxR*sin(t),cy-maxR*cos(t));noStroke();fill(studio.services.acousticTheme.TEXT);ellipse(cx+maxR*0.82f*sin(t),cy-maxR*0.82f*cos(t),10,10);}
    float bt=radians(studio.acousticState.beamAzimuthDeg);stroke(studio.services.acousticTheme.GOOD);strokeWeight(3);line(cx,cy,cx+maxR*0.94f*sin(bt),cy-maxR*0.94f*cos(bt));noStroke();
    fill(studio.services.acousticTheme.MUTED);textAlign(LEFT,TOP);acousticText(studio.services.acousticTheme.FONT_SMALL,false);String note=studio.acousticState.i18n.tr(studio.acousticState.automaticBeam?"radar.note_auto":"radar.note_manual");fitCurrentTextSize(note,studio.services.acousticTheme.FONT_SMALL,7,w-28,30);text(ellipsizeToWidth(note,w-28),x+14,y+studio.services.acousticTheme.CARD_TITLE_H+8);textAlign(LEFT,BASELINE);
    String status=scan==null?studio.acousticState.i18n.tr("status.waiting"):studio.acousticState.i18n.format("status.scan_voice",scan.azimuthDeg,scan.confidence*100,scan.voiceProbability*100,scan.snrDb);fill(studio.services.acousticTheme.MUTED);acousticText(studio.services.acousticTheme.FONT_SMALL,false);fitCurrentTextSize(status,studio.services.acousticTheme.FONT_SMALL,7,w-28,24);text(ellipsizeToWidth(status,w-28),x+14,y+h-18);
  }

  void drawMicLevels(float x,float y,float w,float h,AcousticAudioFrame frame){card(x,y,w,h);cardTitle(x,y,w,studio.acousticState.i18n.tr("panel.microphones"));float top=y+studio.services.acousticTheme.CARD_TITLE_H+8,rowH=max(28,(h-studio.services.acousticTheme.CARD_TITLE_H-16)/4.0f);for(int ch=0;ch<4;ch++){float yy=top+ch*rowH,peak=frame==null?0:frame.peak[ch];fill(studio.services.acousticTheme.MUTED);acousticText(studio.services.acousticTheme.FONT_SMALL,false);text(studio.acousticState.i18n.format("label.mic",ch+1),x+16,yy+14);fill(studio.services.acousticTheme.TEXT);textAlign(RIGHT,BASELINE);text(nf(peak*100,1,1)+"%",x+w-16,yy+14);textAlign(LEFT,BASELINE);float bx=x+16,by=yy+24,bw=w-32;fill(studio.services.acousticTheme.GRID);rect(bx,by,bw,9,4.5f);fill(studio.services.acousticTheme.ACTIVE);rect(bx,by,bw*constrain(peak,0,1),9,4.5f);}}
  void card(float x,float y,float w,float h){stroke(studio.services.acousticTheme.BORDER);strokeWeight(1);fill(studio.services.acousticTheme.SURFACE);rect(x,y,w,h,studio.services.acousticTheme.RADIUS);noStroke();}
  void cardTitle(float x,float y,float w,String title){fill(studio.services.acousticTheme.TEXT);acousticText(studio.services.acousticTheme.FONT_SMALL,true);textAlign(LEFT,CENTER);fitCurrentTextSize(title,studio.services.acousticTheme.FONT_SMALL,7,w-28,studio.services.acousticTheme.CARD_TITLE_H-8);text(ellipsizeToWidth(title,w-28),x+14,y+studio.services.acousticTheme.CARD_TITLE_H/2);textAlign(LEFT,BASELINE);}
  void metric(float x,float y,float w,float h,String label,String value,boolean active){fill(studio.services.acousticTheme.SURFACE2);rect(x,y,w,h,9);fill(active?studio.services.acousticTheme.ACTIVE:studio.services.acousticTheme.MUTED);ellipse(x+12,y+15,6,6);fill(studio.services.acousticTheme.MUTED);acousticText(studio.services.acousticTheme.FONT_TINY,false);fitCurrentTextSize(label,studio.services.acousticTheme.FONT_TINY,7,w-30,22);text(ellipsizeToWidth(label,w-30),x+22,y+19);fill(studio.services.acousticTheme.TEXT);acousticText(studio.services.acousticTheme.FONT_SMALL,true);fitCurrentTextSize(value,studio.services.acousticTheme.FONT_SMALL,7,w-20,24);text(ellipsizeToWidth(value,w-20),x+10,y+h-13);}
  void button(float x,float y,float w,float h,String label,boolean selected){float mx=studio.contentMouseX(),my=studio.contentMouseY();boolean hot=mx>=x&&mx<=x+w&&my>=y&&my<=y+h;stroke(selected||hot?studio.services.acousticTheme.ACTIVE:studio.services.acousticTheme.BORDER);fill(selected?studio.services.acousticTheme.RAISED:studio.services.acousticTheme.SURFACE2);rect(x,y,w,h,9);noStroke();fill(selected||hot?studio.services.acousticTheme.TEXT:studio.services.acousticTheme.MUTED);textAlign(CENTER,CENTER);acousticText(studio.services.acousticTheme.FONT_SMALL,true);fitCurrentTextSize(label,studio.services.acousticTheme.FONT_SMALL,7,w-12,h-8);text(ellipsizeToWidth(label,w-12),x+w/2,y+h/2);textAlign(LEFT,BASELINE);}
  void handleMouse(float mx,float my){if(hit(mx,my,resetX,resetY,resetW,buttonH)){resetAcousticMap();return;}if(hit(mx,my,autoX,resetY,modeW,buttonH)){studio.acousticState.automaticBeam=true;if(studio.acousticState.autoSteerer!=null)studio.acousticState.autoSteerer.reset();return;}if(hit(mx,my,manualX,resetY,modeW,buttonH)){studio.acousticState.automaticBeam=false;return;}if(!studio.acousticState.automaticBeam&&hit(mx,my,radarX,radarY,radarW,radarH)){float dx=mx-radarCx,dy=radarCy-my;if(dy>=-8){studio.acousticState.manualAzimuthDeg=constrain(degrees(atan2(dx,max(1,dy))),-90,90);studio.acousticState.beamAzimuthDeg=studio.acousticState.manualAzimuthDeg;}}}
  boolean hit(float mx,float my,float x,float y,float w,float h){return mx>=x&&mx<=x+w&&my>=y&&my<=y+h;}
}
