$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$code = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.Threading;
using System.Windows.Forms;

public static class SynKinectCloudBridge {
    static CloudForm form;
    static Thread ui;
    public static void Start() {
        if (ui != null) return;
        ui = new Thread(() => {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            form = new CloudForm();
            Application.Run(form);
        });
        ui.IsBackground = true;
        ui.SetApartmentState(ApartmentState.STA);
        ui.Start();
        for (int i=0;i<100 && form==null;i++) Thread.Sleep(10);
    }
    public static void Cloud(float x1,float y1,float x2,float y2,int hands,int mode,float energy) { if(form!=null) form.SetTarget(x1,y1,hands,mode,energy); }
    public static void Hide() { if(form!=null) form.SetTarget(0,0,0,0,0); }
    public static void Stop() { if(form!=null) form.StopSafe(); }

    sealed class CloudForm : Form {
        const int N=300, TRAIL=22;
        readonly float[] x=new float[N],y=new float[N],vx=new float[N],vy=new float[N],phase=new float[N],ring=new float[N],lag=new float[N];
        readonly int[] band=new int[N];
        readonly float[] hx=new float[TRAIL],hy=new float[TRAIL];
        readonly Random rnd=new Random(360112);
        readonly object gate=new object();
        float targetX,targetY,energy; int hands,mode; bool cursorHidden=false,seeded=false; DateTime last=DateTime.UtcNow;
        float lastTargetX,lastTargetY,handVx,handVy;
        readonly System.Windows.Forms.Timer timer;
        public CloudForm() {
            var vs=SystemInformation.VirtualScreen;
            StartPosition=FormStartPosition.Manual; Bounds=vs; FormBorderStyle=FormBorderStyle.None; ShowInTaskbar=false; TopMost=true; BackColor=Color.Magenta; TransparencyKey=Color.Magenta;
            DoubleBuffered=true; AutoScaleMode=AutoScaleMode.None;
            for(int i=0;i<N;i++){phase[i]=(float)(rnd.NextDouble()*Math.PI*2);ring[i]=(float)Math.Sqrt(rnd.NextDouble());lag[i]=(float)Math.Pow(rnd.NextDouble(),0.72);band[i]=Math.Min(2,(int)(lag[i]*3));x[i]=Width/2;y[i]=Height/2;}
            timer=new System.Windows.Forms.Timer(); timer.Interval=16; timer.Tick+=(s,e)=>TickCloud(); timer.Start();
        }
        protected override CreateParams CreateParams { get { var cp=base.CreateParams; cp.ExStyle |= 0x00080000|0x00000020|0x00000080|0x08000000; return cp; } }
        protected override bool ShowWithoutActivation { get { return true; } }
        public void SetTarget(float ax,float ay,int h,int m,float en){lock(gate){targetX=ax-SystemInformation.VirtualScreen.Left;targetY=ay-SystemInformation.VirtualScreen.Top;hands=h;mode=m;energy=en;} }
        void Seed(float ax,float ay){for(int k=0;k<TRAIL;k++){hx[k]=ax;hy[k]=ay;}for(int i=0;i<N;i++){x[i]=ax;y[i]=ay;vx[i]=vy[i]=0;}lastTargetX=ax;lastTargetY=ay;seeded=true;}
        void Push(float ax,float ay){for(int k=TRAIL-1;k>0;k--){hx[k]=hx[k-1];hy[k]=hy[k-1];}hx[0]=ax;hy[0]=ay;}
        void TickCloud(){
            var now=DateTime.UtcNow; float dt=(float)(now-last).TotalSeconds; last=now; if(dt<0.004f)dt=0.004f;if(dt>0.04f)dt=0.04f;
            float ax,ay,en; int h,m; lock(gate){ax=targetX;ay=targetY;h=hands;m=mode;en=energy;}
            if(m>=2 && !cursorHidden){Cursor.Hide();cursorHidden=true;} else if(m<2 && cursorHidden){Cursor.Show();cursorHidden=false;}
            if(h<=0){seeded=false;Invalidate();return;}
            if(!seeded)Seed(ax,ay);
            float rvx=(ax-lastTargetX)/dt,rvy=(ay-lastTargetY)/dt;lastTargetX=ax;lastTargetY=ay;float va=1f-(float)Math.Exp(-10f*dt);handVx+=(rvx-handVx)*va;handVy+=(rvy-handVy)*va;Push(ax,ay);
            float speed=(float)Math.Sqrt(handVx*handVx+handVy*handVy),ux=speed>5?handVx/speed:1f,uy=speed>5?handVy/speed:0f,pxa=-uy,pya=ux;
            float stretch=1f+Math.Min(2f,speed*0.0020f),radius=24f*(0.78f+0.48f*Math.Max(0f,Math.Min(1f,en))),t=(float)(Environment.TickCount64*0.001);
            for(int i=0;i<N;i++){
                int hi=Math.Max(0,Math.Min(TRAIL-1,(int)Math.Round(lag[i]*(TRAIL-1))));float cx=hx[hi],cy=hy[hi],fade=1f-0.42f*lag[i],a=phase[i]+t*(0.52f+0.20f*((i%11)/11f));float rr=radius*(0.18f+0.82f*ring[i])*fade;
                float longAxis=rr*(1f+(stretch-1f)*(0.35f+0.65f*lag[i])),shortAxis=rr/(float)Math.Sqrt(stretch),swirl=(float)Math.Sin(a*1.83+t*0.48+phase[i])*0.24f*radius*(0.45f+0.55f*lag[i]);
                float localLong=(float)Math.Cos(a)*longAxis-swirl*0.20f,localPerp=(float)Math.Sin(a)*shortAxis+swirl,tx=cx+ux*localLong+pxa*localPerp,ty=cy+uy*localLong+pya*localPerp;
                float ddx=tx-x[i],ddy=ty-y[i];vx[i]+=(ddx*42f-vx[i]*7f)*dt;vy[i]+=(ddy*42f-vy[i]*7f)*dt;x[i]+=vx[i]*dt;y[i]+=vy[i]*dt;
            }
            Invalidate();
        }
        protected override void OnPaint(PaintEventArgs e){base.OnPaint(e);int h,m;lock(gate){h=hands;m=mode;}if(h<=0||!seeded)return;e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;
            Color[] core={Color.FromArgb(228,104,169,232),Color.FromArgb(156,104,169,232),Color.FromArgb(82,104,169,232)};
            Color[] glow={Color.FromArgb(56,104,169,232),Color.FromArgb(38,104,169,232),Color.FromArgb(20,104,169,232)};
            for(int b=2;b>=0;b--)using(var gb=new SolidBrush(glow[b]))using(var cb=new SolidBrush(core[b])){for(int i=0;i<N;i++){if(band[i]!=b)continue;float d=(b==0?2.7f:b==1?2.2f:1.8f)+(m>=2?0.35f:0);e.Graphics.FillEllipse(gb,x[i]-d*1.45f,y[i]-d*1.45f,d*2.9f,d*2.9f);e.Graphics.FillEllipse(cb,x[i]-d/2,y[i]-d/2,d,d);}}
        }
        public void StopSafe(){try{if(InvokeRequired){BeginInvoke(new Action(StopSafe));return;}timer.Stop();if(cursorHidden){Cursor.Show();cursorHidden=false;}Close();}catch{} }
        protected override void Dispose(bool disposing){if(cursorHidden){try{Cursor.Show();}catch{}cursorHidden=false;}base.Dispose(disposing);}
    }
}
'@
Add-Type -TypeDefinition $code -ReferencedAssemblies System.Windows.Forms,System.Drawing
[SynKinectCloudBridge]::Start()
try {
  while (($line = [Console]::In.ReadLine()) -ne $null) {
    if ($line -eq 'STOP') { break }
    if ($line -eq 'HIDE') { [SynKinectCloudBridge]::Hide(); continue }
    if ($line.StartsWith('CLOUD|')) {
      $p=$line.Split('|')
      if ($p.Length -ge 8) {
        $ci=[Globalization.CultureInfo]::InvariantCulture
        [SynKinectCloudBridge]::Cloud([single]::Parse($p[1],$ci),[single]::Parse($p[2],$ci),[single]::Parse($p[3],$ci),[single]::Parse($p[4],$ci),[int]$p[5],[int]$p[6],[single]::Parse($p[7],$ci))
      }
    }
  }
} finally { [SynKinectCloudBridge]::Stop() }
