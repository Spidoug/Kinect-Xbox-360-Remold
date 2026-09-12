#pragma once
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace remold::rawsensor {
inline uint8_t sample(const uint8_t* bayer,int width,int height,int x,int y){
  x=std::clamp(x,0,width-1);y=std::clamp(y,0,height-1);
  return bayer[static_cast<std::size_t>(y)*width+x];
}
inline uint8_t avg2(uint8_t a,uint8_t b){return static_cast<uint8_t>((unsigned(a)+b+1u)/2u);}
inline uint8_t avg4(uint8_t a,uint8_t b,uint8_t c,uint8_t d){return static_cast<uint8_t>((unsigned(a)+b+c+d+2u)/4u);}
inline void grbg_pixel(const uint8_t* bayer,int width,int height,int x,int y,uint8_t& r,uint8_t& g,uint8_t& b){
  const bool yo=(y&1)!=0,xo=(x&1)!=0;const uint8_t c=sample(bayer,width,height,x,y);
  if(!yo&&xo){r=c;g=avg4(sample(bayer,width,height,x-1,y),sample(bayer,width,height,x+1,y),sample(bayer,width,height,x,y-1),sample(bayer,width,height,x,y+1));b=avg4(sample(bayer,width,height,x-1,y-1),sample(bayer,width,height,x+1,y-1),sample(bayer,width,height,x-1,y+1),sample(bayer,width,height,x+1,y+1));}
  else if(yo&&!xo){b=c;g=avg4(sample(bayer,width,height,x-1,y),sample(bayer,width,height,x+1,y),sample(bayer,width,height,x,y-1),sample(bayer,width,height,x,y+1));r=avg4(sample(bayer,width,height,x-1,y-1),sample(bayer,width,height,x+1,y-1),sample(bayer,width,height,x-1,y+1),sample(bayer,width,height,x+1,y+1));}
  else if(!yo){g=c;r=avg2(sample(bayer,width,height,x-1,y),sample(bayer,width,height,x+1,y));b=avg2(sample(bayer,width,height,x,y-1),sample(bayer,width,height,x,y+1));}
  else{g=c;r=avg2(sample(bayer,width,height,x,y-1),sample(bayer,width,height,x,y+1));b=avg2(sample(bayer,width,height,x-1,y),sample(bayer,width,height,x+1,y));}
}
inline void bayer_grbg_to_rgb24(const uint8_t* bayer,int width,int height,std::vector<uint8_t>& rgb){
  rgb.resize(static_cast<std::size_t>(width)*height*3u);
  for(int y=0;y<height;++y)for(int x=0;x<width;++x){uint8_t r,g,b;grbg_pixel(bayer,width,height,x,y,r,g,b);const std::size_t p=(static_cast<std::size_t>(y)*width+x)*3u;rgb[p]=r;rgb[p+1]=g;rgb[p+2]=b;}
}
inline uint8_t clamp8(int v){return static_cast<uint8_t>(std::clamp(v,0,255));}
inline void rgb24_to_yuyv(const uint8_t* rgb,int width,int height,std::vector<uint8_t>& yuyv){
  yuyv.resize(static_cast<std::size_t>(width)*height*2u);
  for(int y=0;y<height;++y)for(int x=0;x<width;x+=2){
    const std::size_t a=(static_cast<std::size_t>(y)*width+x)*3u,b=a+3u,o=(static_cast<std::size_t>(y)*width+x)*2u;
    const int r0=rgb[a],g0=rgb[a+1],b0=rgb[a+2],r1=rgb[b],g1=rgb[b+1],b1=rgb[b+2];
    const int y0=((66*r0+129*g0+25*b0+128)>>8)+16,y1=((66*r1+129*g1+25*b1+128)>>8)+16;
    const int r=(r0+r1)/2,g=(g0+g1)/2,bl=(b0+b1)/2;
    yuyv[o]=clamp8(y0);yuyv[o+1]=clamp8(((-38*r-74*g+112*bl+128)>>8)+128);yuyv[o+2]=clamp8(y1);yuyv[o+3]=clamp8(((112*r-94*g-18*bl+128)>>8)+128);
  }
}
} // namespace remold::rawsensor
