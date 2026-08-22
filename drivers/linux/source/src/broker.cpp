#include <algorithm>
#include <atomic>
#include <cerrno>
#include <csignal>
#include <signal.h>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <thread>
#include <grp.h>
#include <libusb-1.0/libusb.h>
#include "remold/protocol.hpp"
#include "remold/unix_socket.hpp"

using namespace remold;
namespace {
std::atomic<bool> run{true};
std::mutex usb_mu;
libusb_context* usb_ctx=nullptr;
libusb_device_handle* motor=nullptr;
std::atomic<uint64_t> activity[3]{};
constexpr uint16_t VID=0x045e, PID=0x02b0;
constexpr uint64_t LeaseMs=2000;
void stop_handler(int){run=false;}
void close_motor(){if(motor){libusb_close(motor);motor=nullptr;}}
bool ensure_motor(){
  if(motor) return true;
  motor=libusb_open_device_with_vid_pid(usb_ctx,VID,PID);
  return motor!=nullptr;
}
int32_t usb_status(control::Reply& r){
  std::lock_guard<std::mutex> g(usb_mu); if(!ensure_motor())return -ENODEV;
  unsigned char b[10]{};int n=libusb_control_transfer(motor,0xC0,0x32,0,0,b,sizeof(b),1000);
  if(n!=10){close_motor();return n<0?n:-EIO;}
  r.accelX=static_cast<int16_t>((b[2]<<8)|b[3]);r.accelY=static_cast<int16_t>((b[4]<<8)|b[5]);r.accelZ=static_cast<int16_t>((b[6]<<8)|b[7]);
  r.tiltTenths=static_cast<int8_t>(b[8])*5;r.state=b[9];r.transport=control::Transport::PhysicalMotor;return 0;
}
int32_t set_tilt(int deg,control::Reply& r){
  deg=std::clamp(deg,-27,27);std::lock_guard<std::mutex> g(usb_mu);if(!ensure_motor())return -ENODEV;
  int16_t half=static_cast<int16_t>(deg*2);int n=libusb_control_transfer(motor,0x40,0x31,static_cast<uint16_t>(half),0,nullptr,0,1000);
  if(n<0){close_motor();return n;} r.tiltTenths=deg*10;r.transport=control::Transport::PhysicalMotor;return 0;
}
int32_t set_led(int mode,control::Reply& r){
  if(!(mode==0||mode==1||mode==2||mode==3||mode==4||mode==6))return -EINVAL;
  std::lock_guard<std::mutex> g(usb_mu);if(!ensure_motor())return -ENODEV;
  int n=libusb_control_transfer(motor,0x40,0x06,static_cast<uint16_t>(mode),0,nullptr,0,1000);
  if(n<0){close_motor();return n;}r.transport=control::Transport::PhysicalMotor;return 0;
}
uint32_t mask(){uint64_t now=unixio::monotonic_ms();uint32_t m=0;for(int i=0;i<3;i++){auto t=activity[i].load();if(t&&now-t<=LeaseMs)m|=(1u<<i);}return m;}
void client(int fd){
  control::Request q{};control::Reply r{};
  if(!unixio::read_exact(fd,&q,sizeof(q))||q.magic!=control::kMagic||q.version!=control::kVersion){::close(fd);return;}
  switch(q.command){
    case control::Command::Ping:r.result=0;break;
    case control::Command::Status:r.result=usb_status(r);break;
    case control::Command::Tilt:r.result=set_tilt(q.value,r);break;
    case control::Command::Led:r.result=set_led(q.value,r);break;
    case control::Command::CameraActivity:{int i=q.value-1;if(i<0||i>=3)r.result=-EINVAL;else{activity[i]=unixio::monotonic_ms();r.result=0;}break;}
    default:r.result=-EINVAL;break;
  }
  r.cameraActivityMask=mask();unixio::write_all(fd,&r,sizeof(r));::close(fd);
}
}
int main(){
  struct sigaction action{};
  action.sa_handler=stop_handler;
  sigemptyset(&action.sa_mask);
  action.sa_flags=0;  // do not restart accept(2); systemd stop must exit promptly
  sigaction(SIGINT,&action,nullptr);sigaction(SIGTERM,&action,nullptr);std::signal(SIGPIPE,SIG_IGN);
  if(libusb_init(&usb_ctx)!=0)return 2;
  int s=unixio::server_socket(kControlSocket,0660);
  if(s<0){std::perror("control socket");libusb_exit(usb_ctx);return 3;}
  if(auto* gr=getgrnam("video")) ::chown(kControlSocket,0,gr->gr_gid);
  while(run){int c=::accept4(s,nullptr,nullptr,SOCK_CLOEXEC);if(c<0){if(errno==EINTR)continue;if(!run)break;unixio::retry_sleep();continue;}std::thread(client,c).detach();}
  ::close(s);::unlink(kControlSocket);{std::lock_guard<std::mutex> g(usb_mu);close_motor();}libusb_exit(usb_ctx);return 0;
}
