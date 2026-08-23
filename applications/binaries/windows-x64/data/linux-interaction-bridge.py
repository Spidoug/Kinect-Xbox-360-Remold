#!/usr/bin/env python3
"""SynKinect primary-hand fluid desktop cloud for Linux/X11.

Only the primary hand is rendered. The second hand is consumed by the Studio's
gesture state machine but never creates a second visual cloud. The cloud keeps a
short trajectory history, stretches with hand velocity and elastically reforms
when movement slows.
"""
import ctypes, math, os, random, sys, threading, time

N=300
TRAIL=22
SIZE=380
HALF=SIZE/2.0
FRAME=1.0/60.0

class XArc(ctypes.Structure):
    _fields_=[('x',ctypes.c_short),('y',ctypes.c_short),('width',ctypes.c_ushort),('height',ctypes.c_ushort),('angle1',ctypes.c_short),('angle2',ctypes.c_short)]
class XColor(ctypes.Structure):
    _fields_=[('pixel',ctypes.c_ulong),('red',ctypes.c_ushort),('green',ctypes.c_ushort),('blue',ctypes.c_ushort),('flags',ctypes.c_byte),('pad',ctypes.c_byte)]
class XSetWindowAttributes(ctypes.Structure):
    _fields_=[('background_pixmap',ctypes.c_ulong),('background_pixel',ctypes.c_ulong),('border_pixmap',ctypes.c_ulong),('border_pixel',ctypes.c_ulong),('bit_gravity',ctypes.c_int),('win_gravity',ctypes.c_int),('backing_store',ctypes.c_int),('backing_planes',ctypes.c_ulong),('backing_pixel',ctypes.c_ulong),('save_under',ctypes.c_int),('event_mask',ctypes.c_long),('do_not_propagate_mask',ctypes.c_long),('override_redirect',ctypes.c_int),('colormap',ctypes.c_ulong),('cursor',ctypes.c_ulong)]
ShapeBounding=0;ShapeInput=2;ShapeSet=0;CWOverrideRedirect=1<<9

class X11:
    def __init__(self):
        self.x=ctypes.CDLL('libX11.so.6');self.ext=ctypes.CDLL('libXext.so.6')
        self.x.XOpenDisplay.argtypes=[ctypes.c_char_p];self.x.XOpenDisplay.restype=ctypes.c_void_p;self.d=self.x.XOpenDisplay(None)
        if not self.d:raise RuntimeError('DISPLAY unavailable')
        self.x.XDefaultScreen.argtypes=[ctypes.c_void_p];self.x.XDefaultScreen.restype=ctypes.c_int;self.screen=self.x.XDefaultScreen(self.d)
        self.x.XRootWindow.argtypes=[ctypes.c_void_p,ctypes.c_int];self.x.XRootWindow.restype=ctypes.c_ulong;self.root=self.x.XRootWindow(self.d,self.screen)
        self.x.XDefaultDepth.argtypes=[ctypes.c_void_p,ctypes.c_int];self.x.XDefaultDepth.restype=ctypes.c_int;self.depth=self.x.XDefaultDepth(self.d,self.screen)
        self.x.XDefaultColormap.argtypes=[ctypes.c_void_p,ctypes.c_int];self.x.XDefaultColormap.restype=ctypes.c_ulong;self.cmap=self.x.XDefaultColormap(self.d,self.screen);self._proto();self.fix=None;self.cursor_hidden=False
        try:
            self.fix=ctypes.CDLL('libXfixes.so.3');self.fix.XFixesHideCursor.argtypes=[ctypes.c_void_p,ctypes.c_ulong];self.fix.XFixesShowCursor.argtypes=[ctypes.c_void_p,ctypes.c_ulong]
        except Exception:self.fix=None
    def _proto(self):
        X=self.x
        X.XCreateSimpleWindow.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_int,ctypes.c_int,ctypes.c_uint,ctypes.c_uint,ctypes.c_uint,ctypes.c_ulong,ctypes.c_ulong];X.XCreateSimpleWindow.restype=ctypes.c_ulong
        X.XChangeWindowAttributes.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_ulong,ctypes.POINTER(XSetWindowAttributes)]
        X.XCreatePixmap.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_uint,ctypes.c_uint,ctypes.c_uint];X.XCreatePixmap.restype=ctypes.c_ulong;X.XFreePixmap.argtypes=[ctypes.c_void_p,ctypes.c_ulong]
        X.XCreateGC.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_ulong,ctypes.c_void_p];X.XCreateGC.restype=ctypes.c_void_p;X.XFreeGC.argtypes=[ctypes.c_void_p,ctypes.c_void_p]
        X.XSetForeground.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_ulong];X.XFillRectangle.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_uint,ctypes.c_uint]
        X.XFillArcs.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_void_p,ctypes.POINTER(XArc),ctypes.c_int];X.XCopyArea.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_ulong,ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_uint,ctypes.c_uint,ctypes.c_int,ctypes.c_int]
        X.XMapRaised.argtypes=[ctypes.c_void_p,ctypes.c_ulong];X.XUnmapWindow.argtypes=[ctypes.c_void_p,ctypes.c_ulong];X.XMoveWindow.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_int,ctypes.c_int];X.XRaiseWindow.argtypes=[ctypes.c_void_p,ctypes.c_ulong];X.XFlush.argtypes=[ctypes.c_void_p]
        X.XDestroyWindow.argtypes=[ctypes.c_void_p,ctypes.c_ulong];X.XAllocNamedColor.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_char_p,ctypes.POINTER(XColor),ctypes.POINTER(XColor)];X.XAllocNamedColor.restype=ctypes.c_int
        self.ext.XShapeCombineMask.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_ulong,ctypes.c_int]
    def color(self,name):
        a=XColor();b=XColor();return a.pixel if self.x.XAllocNamedColor(self.d,self.cmap,name.encode(),ctypes.byref(a),ctypes.byref(b)) else 0xffffff
    def cursor(self,hide):
        if not self.fix or hide==self.cursor_hidden:return
        try:(self.fix.XFixesHideCursor if hide else self.fix.XFixesShowCursor)(self.d,self.root);self.cursor_hidden=hide;self.x.XFlush(self.d)
        except Exception:pass

class Cloud:
    def __init__(self,X):
        self.X=X;xx=X.x;self.win=xx.XCreateSimpleWindow(X.d,X.root,0,0,SIZE,SIZE,0,0,0);attrs=XSetWindowAttributes();attrs.override_redirect=1;xx.XChangeWindowAttributes(X.d,self.win,CWOverrideRedirect,ctypes.byref(attrs))
        self.pix=xx.XCreatePixmap(X.d,self.win,SIZE,SIZE,X.depth);self.mask=xx.XCreatePixmap(X.d,self.win,SIZE,SIZE,1);self.empty=xx.XCreatePixmap(X.d,self.win,SIZE,SIZE,1)
        self.gc=xx.XCreateGC(X.d,self.pix,0,None);self.coregc=xx.XCreateGC(X.d,self.pix,0,None);self.maskgc=xx.XCreateGC(X.d,self.mask,0,None);self.emptygc=xx.XCreateGC(X.d,self.empty,0,None);self.copygc=xx.XCreateGC(X.d,self.win,0,None)
        self.core=X.color('#68a9e8');self.glow=X.color('#315b73');xx.XSetForeground(X.d,self.emptygc,0);xx.XFillRectangle(X.d,self.empty,self.emptygc,0,0,SIZE,SIZE);X.ext.XShapeCombineMask(X.d,self.win,ShapeInput,0,0,self.empty,ShapeSet)
        rnd=random.Random(360112);self.phase=[rnd.random()*math.tau for _ in range(N)];self.ring=[math.sqrt(rnd.random()) for _ in range(N)];self.lag=[rnd.random()**0.72 for _ in range(N)];self.band=[min(2,int(v*3)) for v in self.lag]
        self.x=[HALF]*N;self.y=[HALF]*N;self.vx=[0.0]*N;self.vy=[0.0]*N;self.hx=[0.0]*TRAIL;self.hy=[0.0]*TRAIL;self.visible=False;self.seeded=False;self.center_x=None;self.center_y=None;self.last_gx=0;self.last_gy=0;self.hvx=0;self.hvy=0
    def hide(self):
        if self.visible:self.X.x.XUnmapWindow(self.X.d,self.win);self.visible=False
        self.seeded=False
    def seed(self,gx,gy):
        self.hx=[gx]*TRAIL;self.hy=[gy]*TRAIL;self.last_gx=gx;self.last_gy=gy;self.center_x=gx;self.center_y=gy;self.seeded=True
        for i in range(N):self.x[i]=HALF;self.y[i]=HALF;self.vx[i]=self.vy[i]=0.0
    def draw(self,gx,gy,mode,energy,t,dt):
        X=self.X.x
        if not self.seeded:self.seed(gx,gy)
        rvx=(gx-self.last_gx)/dt;rvy=(gy-self.last_gy)/dt;self.last_gx=gx;self.last_gy=gy;va=1-math.exp(-10*dt);self.hvx+=(rvx-self.hvx)*va;self.hvy+=(rvy-self.hvy)*va
        self.hx=[gx]+self.hx[:-1];self.hy=[gy]+self.hy[:-1]
        a=1-math.exp(-15*dt);self.center_x+=(gx-self.center_x)*a;self.center_y+=(gy-self.center_y)*a;origin_x=self.center_x-HALF;origin_y=self.center_y-HALF
        X.XMoveWindow(self.X.d,self.win,int(round(origin_x)),int(round(origin_y)));X.XMapRaised(self.X.d,self.win) if not self.visible else X.XRaiseWindow(self.X.d,self.win);self.visible=True
        speed=math.hypot(self.hvx,self.hvy);ux=self.hvx/speed if speed>5 else 1.0;uy=self.hvy/speed if speed>5 else 0.0;pxa=-uy;pya=ux;stretch=1+min(2.0,speed*0.0020);radius=24*(0.78+0.48*max(0,min(1,energy)))
        glow=[];core=[]
        for i in range(N):
            hi=max(0,min(TRAIL-1,round(self.lag[i]*(TRAIL-1))));cx=self.hx[hi]-origin_x;cy=self.hy[hi]-origin_y;fade=1-0.42*self.lag[i];ang=self.phase[i]+t*(0.52+0.20*((i%11)/11));rr=radius*(0.18+0.82*self.ring[i])*fade
            long_axis=rr*(1+(stretch-1)*(0.35+0.65*self.lag[i]));short_axis=rr/math.sqrt(stretch);swirl=math.sin(ang*1.83+t*0.48+self.phase[i])*0.24*radius*(0.45+0.55*self.lag[i]);ll=math.cos(ang)*long_axis-swirl*0.20;lp=math.sin(ang)*short_axis+swirl
            tx=cx+ux*ll+pxa*lp;ty=cy+uy*ll+pya*lp;ax=(tx-self.x[i])*42-self.vx[i]*7;ay=(ty-self.y[i])*42-self.vy[i]*7;self.vx[i]+=ax*dt;self.vy[i]+=ay*dt;self.x[i]+=self.vx[i]*dt;self.y[i]+=self.vy[i]*dt
            d=(2.7 if self.band[i]==0 else 2.2 if self.band[i]==1 else 1.8)+(0.35 if mode>=2 else 0);gd=d*2.8;glow.append(XArc(int(self.x[i]-gd/2),int(self.y[i]-gd/2),max(1,int(gd)),max(1,int(gd)),0,360*64));core.append(XArc(int(self.x[i]-d/2),int(self.y[i]-d/2),max(1,int(d)),max(1,int(d)),0,360*64))
        ga=(XArc*N)(*glow);ca=(XArc*N)(*core);X.XSetForeground(self.X.d,self.maskgc,0);X.XFillRectangle(self.X.d,self.mask,self.maskgc,0,0,SIZE,SIZE);X.XSetForeground(self.X.d,self.maskgc,1);X.XFillArcs(self.X.d,self.mask,self.maskgc,ga,N);self.X.ext.XShapeCombineMask(self.X.d,self.win,ShapeBounding,0,0,self.mask,ShapeSet)
        X.XSetForeground(self.X.d,self.gc,0);X.XFillRectangle(self.X.d,self.pix,self.gc,0,0,SIZE,SIZE);X.XSetForeground(self.X.d,self.gc,self.glow);X.XFillArcs(self.X.d,self.pix,self.gc,ga,N);X.XSetForeground(self.X.d,self.coregc,self.core);X.XFillArcs(self.X.d,self.pix,self.coregc,ca,N);X.XCopyArea(self.X.d,self.pix,self.win,self.copygc,0,0,SIZE,SIZE,0,0)
    def close(self):
        X=self.X.x
        try:X.XUnmapWindow(self.X.d,self.win)
        except:pass
        for gc in (self.gc,self.coregc,self.maskgc,self.emptygc,self.copygc):
            try:X.XFreeGC(self.X.d,gc)
            except:pass
        for pm in (self.pix,self.mask,self.empty):
            try:X.XFreePixmap(self.X.d,pm)
            except:pass
        try:X.XDestroyWindow(self.X.d,self.win)
        except:pass

class State:
    def __init__(self):self.lock=threading.Lock();self.cloud=None;self.stop=False
S=State()
def reader():
    try:
        for raw in sys.stdin:
            line=raw.strip()
            with S.lock:
                if line=='STOP':S.stop=True;return
                if line=='HIDE':S.cloud=None;continue
                if line.startswith('CLOUD|'):
                    p=line.split('|')
                    if len(p)>=8:
                        try:S.cloud=(float(p[1]),float(p[2]),int(p[5]),int(p[6]),float(p[7]))
                        except:pass
    except:pass

if __name__=='__main__':
    if not os.environ.get('DISPLAY'):sys.exit(0)
    try:X=X11()
    except Exception:sys.exit(0)
    cloud=Cloud(X);threading.Thread(target=reader,daemon=True).start();last=time.monotonic()
    try:
        while True:
            with S.lock:stop=S.stop;st=S.cloud
            if stop:break
            now=time.monotonic();dt=max(0.004,min(0.04,now-last));last=now
            if st is None or st[2]<=0:cloud.hide();X.cursor(False)
            else:
                x,y,hands,mode,energy=st;cloud.draw(x,y,mode,energy,now,dt);X.cursor(mode>=2)
            X.x.XFlush(X.d);spent=time.monotonic()-now
            if spent<FRAME:time.sleep(FRAME-spent)
    finally:X.cursor(False);cloud.close();X.x.XFlush(X.d)
