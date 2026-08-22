class AcousticScanFrame {
  long frameNumber;
  float rms,azimuthDeg,confidence,peakScore;
  float[] directional=new float[181];
  float[] occupancy=new float[181];
}

class AcousticEngine {
  static final int FFT=512,BINS=181;
  final AcousticConfig cfg;
  final int[][] pairs={{0,1},{0,2},{0,3},{1,2},{1,3},{2,3}};
  final float[][] spectrumRe=new float[4][FFT],spectrumIm=new float[4][FFT];
  final float[][] pairCorr=new float[6][FFT];
  final float[] occupancy=new float[BINS];

  AcousticEngine(AcousticConfig cfg){this.cfg=cfg;}
  void reset(){Arrays.fill(occupancy,0);}

  AcousticScanFrame process(AcousticAudioFrame frame){
    AcousticScanFrame out=new AcousticScanFrame();out.frameNumber=frame.frameNumber;float rmsAccum=0;
    for(int ch=0;ch<4;ch++)rmsAccum+=prepare(frame.samples[ch],spectrumRe[ch],spectrumIm[ch]);
    out.rms=sqrt(rmsAccum/(4.0f*AcousticProtocol.SAMPLES));
    buildCorrelations();
    float minScore=Float.MAX_VALUE,maxScore=-Float.MAX_VALUE;int peak=0;
    for(int bin=0;bin<BINS;bin++){
      float deg=-90+bin,s=(float)Math.sin(Math.toRadians(deg)),score=0;
      for(int p=0;p<pairs.length;p++){
        int a=pairs[p][0],b=pairs[p][1];float dx=cfg.microphoneXM[b]-cfg.microphoneXM[a];float lag=dx*s*AcousticProtocol.SAMPLE_RATE/cfg.soundSpeedMps;
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
    out.azimuthDeg=refined;out.peakScore=out.directional[peak];out.confidence=constrain(out.peakScore-second,0,1);return out;
  }

  float prepare(int[] samples,float[] re,float[] im){
    Arrays.fill(re,0);Arrays.fill(im,0);double mean=0;for(int v:samples)mean+=v;mean/=samples.length;float e=0;
    for(int i=0;i<samples.length;i++){float x=(float)(((double)samples[i]-mean)/2147483648.0);float w=0.5f-0.5f*(float)Math.cos(2*Math.PI*i/(samples.length-1));float v=x*w;re[i]=v;e+=v*v;}
    fft(re,im,false);return e;
  }
  void buildCorrelations(){
    for(int p=0;p<pairs.length;p++){int a=pairs[p][0],b=pairs[p][1];float[] re=new float[FFT],im=new float[FFT];
      for(int k=0;k<FFT;k++){float ar=spectrumRe[a][k],ai=spectrumIm[a][k],br=spectrumRe[b][k],bi=spectrumIm[b][k];float cr=ar*br+ai*bi,ci=ai*br-ar*bi,mag=sqrt(cr*cr+ci*ci)+1e-12f;re[k]=cr/mag;im[k]=ci/mag;}
      fft(re,im,true);arrayCopy(re,pairCorr[p]);
    }
  }
  float corrAt(float[] corr,float lag){float w=lag;while(w<0)w+=FFT;while(w>=FFT)w-=FFT;int i0=(int)Math.floor(w),i1=(i0+1)%FFT;float f=w-i0;return corr[i0]*(1-f)+corr[i1]*f;}
  void fft(float[] re,float[] im,boolean inverse){
    int n=re.length,j=0;for(int i=1;i<n;i++){int bit=n>>1;for(;((j&bit)!=0);bit>>=1)j^=bit;j^=bit;if(i<j){float t=re[i];re[i]=re[j];re[j]=t;t=im[i];im[i]=im[j];im[j]=t;}}
    for(int len=2;len<=n;len<<=1){double ang=(inverse?2:-2)*Math.PI/len;float wr0=(float)Math.cos(ang),wi0=(float)Math.sin(ang);for(int i=0;i<n;i+=len){float wr=1,wi=0;for(int k=0;k<len/2;k++){int q=i+k+len/2;float vr=re[q]*wr-im[q]*wi,vi=re[q]*wi+im[q]*wr,ur=re[i+k],ui=im[i+k];re[i+k]=ur+vr;im[i+k]=ui+vi;re[q]=ur-vr;im[q]=ui-vi;float nr=wr*wr0-wi*wi0;wi=wr*wi0+wi*wr0;wr=nr;}}}
    if(inverse)for(int i=0;i<n;i++){re[i]/=n;im[i]/=n;}
  }
}
