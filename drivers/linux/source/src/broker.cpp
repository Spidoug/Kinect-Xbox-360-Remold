#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <signal.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
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
enum class MotorKind { None, Classic1414, Audio1473 };
MotorKind motor_kind=MotorKind::None;
uint32_t motor_tag=0;
bool motor_primed=false;
constexpr uint16_t VID=0x045e;
constexpr uint16_t MOTOR_1414_PID=0x02b0;
constexpr uint16_t AUDIO_RUNTIME_PID=0x02bb;
constexpr uint64_t LeaseMs=2000;
constexpr unsigned char ALT_OUT=0x01;
constexpr unsigned char ALT_IN=0x81;
constexpr uint32_t ALT_MAGIC=0x06022009u;
constexpr uint32_t ALT_REPLY_MAGIC=0x0a6fe000u;
constexpr uint32_t ALT_STATUS=0x8032u;
constexpr uint32_t ALT_TILT=0x803bu;
constexpr uint32_t ALT_LED=0x10u;
constexpr int TILT_MIN=-27;
constexpr int TILT_MAX=27;
constexpr int TILT_TOLERANCE_TENTHS=15;
#pragma pack(push,1)
struct AltCommand{uint32_t magic,tag,arg1,cmd,arg2;};
struct AltReply{uint32_t magic,tag,status;};
#pragma pack(pop)
static_assert(sizeof(AltCommand)==20);
static_assert(sizeof(AltReply)==12);

void stop_handler(int){run=false;}
void close_motor(){
  if(motor){
    if(motor_kind==MotorKind::Audio1473)libusb_release_interface(motor,0);
    libusb_close(motor);motor=nullptr;
  }
  motor_kind=MotorKind::None;motor_tag=0;motor_primed=false;
}

bool ensure_motor(){
  if(motor)return true;
  motor=libusb_open_device_with_vid_pid(usb_ctx,VID,MOTOR_1414_PID);
  if(motor){motor_kind=MotorKind::Classic1414;motor_tag=0;motor_primed=true;return true;}
  // Connection detail for 1473: 02C2 remains the parent hub. After audio
  // firmware launch, control is carried by interface 0 of the 02BB runtime.
  motor=libusb_open_device_with_vid_pid(usb_ctx,VID,AUDIO_RUNTIME_PID);
  if(!motor)return false;
  libusb_set_auto_detach_kernel_driver(motor,1);
  if(libusb_claim_interface(motor,0)!=0){libusb_close(motor);motor=nullptr;return false;}
  motor_kind=MotorKind::Audio1473;motor_tag=0;motor_primed=false;return true;
}

int alt_ack(uint32_t expected){
  AltReply a{};int done=0;
  int n=libusb_bulk_transfer(motor,ALT_IN,reinterpret_cast<unsigned char*>(&a),sizeof(a),&done,750);
  if(n!=0)return n;
  if(done!=static_cast<int>(sizeof(a))||a.magic!=ALT_REPLY_MAGIC||a.status!=0)return -EIO;
  // The 1473 tag is a sequencing hint. A valid magic+status ACK remains valid
  // after re-enumeration even if firmware reports the preceding tag.
  (void)expected;
  return 0;
}

int alt_command_raw(uint32_t cmd,int32_t arg2){
  const uint32_t tag=motor_tag++;
  AltCommand q{ALT_MAGIC,tag,0,cmd,static_cast<uint32_t>(arg2)};int done=0;
  int n=libusb_bulk_transfer(motor,ALT_OUT,reinterpret_cast<unsigned char*>(&q),sizeof(q),&done,750);
  if(n!=0)return n;
  if(done!=static_cast<int>(sizeof(q)))return -EIO;
  return alt_ack(tag);
}

int prime_1473(){
  if(motor_kind!=MotorKind::Audio1473||motor_primed)return 0;
  const int n=alt_command_raw(ALT_LED,3);
  if(n==0)motor_primed=true;
  return n;
}

int status_1414(control::Reply& r){
  unsigned char b[10]{};
  int n=libusb_control_transfer(motor,0xC0,0x32,0,0,b,sizeof(b),1000);
  if(n!=10)return n<0?n:-EIO;
  r.accelX=static_cast<int16_t>((b[2]<<8)|b[3]);
  r.accelY=static_cast<int16_t>((b[4]<<8)|b[5]);
  r.accelZ=static_cast<int16_t>((b[6]<<8)|b[7]);
  r.tiltTenths=static_cast<int8_t>(b[8])*5;
  r.state=b[9];
  return 0;
}

int status_1473(control::Reply& r){
  int n=prime_1473();if(n!=0)return n;
  const uint32_t tag=motor_tag++;
  AltCommand q{ALT_MAGIC,tag,0x68,ALT_STATUS,0};unsigned char buf[256]{};int done=0;
  n=libusb_bulk_transfer(motor,ALT_OUT,reinterpret_cast<unsigned char*>(&q),16,&done,750);
  if(n!=0||done!=16)return n!=0?n:-EIO;
  n=libusb_bulk_transfer(motor,ALT_IN,buf,sizeof(buf),&done,750);
  if(n!=0||done!=0x68)return n!=0?n:-EIO;
  int32_t v[4]{};std::memcpy(v,buf+16,sizeof(v));
  r.accelX=static_cast<int16_t>(v[0]);r.accelY=static_cast<int16_t>(v[1]);r.accelZ=static_cast<int16_t>(v[2]);
  r.tiltTenths=v[3]*10;r.state=0;
  return alt_ack(tag);
}

int issue_tilt_1414(int deg){
  const int16_t half=static_cast<int16_t>(deg*2);
  const int n=libusb_control_transfer(motor,0x40,0x31,static_cast<uint16_t>(half),0,nullptr,0,1000);
  return n<0?n:0;
}
int issue_tilt_1473(int deg){int n=prime_1473();return n!=0?n:alt_command_raw(ALT_TILT,deg);}
int set_led_1414(int mode){const int n=libusb_control_transfer(motor,0x40,0x06,static_cast<uint16_t>(mode),0,nullptr,0,1000);return n<0?n:0;}
int set_led_1473(int mode){
  int alt=3;if(mode==0)alt=1;else if(mode==4)alt=2;else if(mode==2)alt=4;else if(mode==1||mode==3)alt=3;
  const int n=alt_command_raw(ALT_LED,alt);if(n==0)motor_primed=true;return n;
}

struct ControlOps{
  int(*status)(control::Reply&);
  int(*issue_tilt)(int);
  int(*set_led)(int);
};
const ControlOps* ops_for(MotorKind kind){
  static const ControlOps k1414{status_1414,issue_tilt_1414,set_led_1414};
  static const ControlOps k1473{status_1473,issue_tilt_1473,set_led_1473};
  if(kind==MotorKind::Classic1414)return &k1414;
  if(kind==MotorKind::Audio1473)return &k1473;
  return nullptr;
}

int read_status_locked(control::Reply& r){
  const ControlOps* ops=ops_for(motor_kind);if(!ops)return -ENODEV;
  const int n=ops->status(r);if(n==0)r.transport=control::Transport::PhysicalMotor;return n;
}

int wait_tilt_locked(int deg,control::Reply& r){
  std::this_thread::sleep_for(std::chrono::milliseconds(120));
  const int target=deg*10;
  bool got=false;int first=0,last=0;bool first_valid=false;int last_error=-ETIMEDOUT;
  for(int i=0;i<40;i++){
    control::Reply latest{};
    const int n=read_status_locked(latest);
    if(n==0){
      got=true;r=latest;last=latest.tiltTenths;
      if(!first_valid){first=last;first_valid=true;}
      if(std::abs(last-target)<=TILT_TOLERANCE_TENTHS)return 0;
    }else if(n!=-ETIMEDOUT){last_error=n;return n;}
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
  if(!got)return last_error;
  return first_valid&&std::abs(last-first)>=5?-ETIMEDOUT:-EIO;
}

template<class F>
int with_fresh_handle_retry(F&& operation,control::Reply& r){
  int last=-ENODEV;
  for(int attempt=0;attempt<2;attempt++){
    if(!ensure_motor()){last=-ENODEV;}else{
      r={};
      last=operation(*ops_for(motor_kind),r);
      if(last==0)return 0;
    }
    close_motor();
    if(attempt==0)std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }
  return last;
}

int32_t usb_status(control::Reply& r){
  std::lock_guard<std::mutex> g(usb_mu);
  return with_fresh_handle_retry([](const ControlOps& ops,control::Reply& out){
    const int n=ops.status(out);if(n==0)out.transport=control::Transport::PhysicalMotor;return n;
  },r);
}

int32_t set_tilt(int deg,control::Reply& r){
  deg=std::clamp(deg,TILT_MIN,TILT_MAX);
  std::lock_guard<std::mutex> g(usb_mu);
  return with_fresh_handle_retry([&](const ControlOps& ops,control::Reply& out){
    int n=ops.issue_tilt(deg);if(n!=0)return n;
    n=wait_tilt_locked(deg,out);if(n==0)out.transport=control::Transport::PhysicalMotor;return n;
  },r);
}

int32_t set_led(int mode,control::Reply& r){
  if(!(mode==0||mode==1||mode==2||mode==3||mode==4||mode==6))return -EINVAL;
  std::lock_guard<std::mutex> g(usb_mu);
  return with_fresh_handle_retry([&](const ControlOps& ops,control::Reply& out){
    const int n=ops.set_led(mode);if(n==0)out.transport=control::Transport::PhysicalMotor;return n;
  },r);
}
int32_t prepare_camera(control::Reply& r){
  std::lock_guard<std::mutex> g(usb_mu);
  return with_fresh_handle_retry([&](const ControlOps&,control::Reply& out){
    const int n=(motor_kind==MotorKind::Audio1473)?prime_1473():0;
    if(n==0)out.transport=control::Transport::PhysicalMotor;
    return n;
  },r);
}


void client(int fd){
  control::Request q{};control::Reply r{};
  if(!unixio::read_exact(fd,&q,sizeof(q))||q.magic!=control::kMagic||q.version!=control::kVersion){::close(fd);return;}
  switch(q.command){
    case control::Command::Ping:r.result=0;break;
    case control::Command::Status:r.result=usb_status(r);break;
    case control::Command::Tilt:r.result=set_tilt(q.value,r);break;
    case control::Command::Led:r.result=set_led(q.value,r);break;
    case control::Command::PrepareCamera:r.result=prepare_camera(r);break;
    default:r.result=-EINVAL;break;
  }
  unixio::write_all(fd,&r,sizeof(r));::close(fd);
}
}
int main(){
  struct sigaction action{};
  action.sa_handler=stop_handler;
  sigemptyset(&action.sa_mask);
  action.sa_flags=0;
  sigaction(SIGINT,&action,nullptr);sigaction(SIGTERM,&action,nullptr);std::signal(SIGPIPE,SIG_IGN);
  if(libusb_init(&usb_ctx)!=0)return 2;
  int s=unixio::server_socket(kControlSocket,0660);
  if(s<0){std::perror("control socket");libusb_exit(usb_ctx);return 3;}
  if(auto* gr=getgrnam("video")) ::chown(kControlSocket,0,gr->gr_gid);
  while(run){int c=::accept4(s,nullptr,nullptr,SOCK_CLOEXEC);if(c<0){if(errno==EINTR)continue;if(!run)break;unixio::retry_sleep();continue;}std::thread(client,c).detach();}
  ::close(s);::unlink(kControlSocket);{std::lock_guard<std::mutex> g(usb_mu);close_motor();}libusb_exit(usb_ctx);return 0;
}
