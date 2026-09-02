#pragma once
#include <cerrno>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <thread>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

namespace remold::unixio {
inline uint64_t monotonic_ms(){
  using namespace std::chrono; return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}
inline void close_fd(int& fd){ if(fd>=0){::close(fd);fd=-1;} }
inline bool read_exact(int fd, void* data, size_t bytes){
  auto* p=static_cast<unsigned char*>(data); size_t done=0;
  while(done<bytes){ ssize_t n=::recv(fd,p+done,bytes-done,0); if(n==0)return false; if(n<0){if(errno==EINTR)continue;return false;} done+=static_cast<size_t>(n);} return true;
}
inline bool write_all(int fd,const void* data,size_t bytes){
  const auto* p=static_cast<const unsigned char*>(data); size_t done=0;
  while(done<bytes){ ssize_t n=::send(fd,p+done,bytes-done,MSG_NOSIGNAL); if(n<0){if(errno==EINTR)continue;return false;} done+=static_cast<size_t>(n);} return true;
}
inline int server_socket(const std::string& path, mode_t mode=0666, int backlog=16){
  std::filesystem::create_directories(std::filesystem::path(path).parent_path());
  ::unlink(path.c_str()); int fd=::socket(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0); if(fd<0)return -1;
  sockaddr_un a{}; a.sun_family=AF_UNIX; if(path.size()>=sizeof(a.sun_path)){errno=ENAMETOOLONG;close_fd(fd);return -1;}
  std::strncpy(a.sun_path,path.c_str(),sizeof(a.sun_path)-1);
  if(::bind(fd,reinterpret_cast<sockaddr*>(&a),sizeof(a))<0){close_fd(fd);return -1;}
  ::chmod(path.c_str(),mode); if(::listen(fd,backlog)<0){close_fd(fd);return -1;} return fd;
}
inline int connect_socket(const std::string& path){
  int fd=::socket(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0); if(fd<0)return -1;
  sockaddr_un a{};a.sun_family=AF_UNIX;if(path.size()>=sizeof(a.sun_path)){errno=ENAMETOOLONG;close_fd(fd);return -1;}
  std::strncpy(a.sun_path,path.c_str(),sizeof(a.sun_path)-1);
  if(::connect(fd,reinterpret_cast<sockaddr*>(&a),sizeof(a))<0){close_fd(fd);return -1;} return fd;
}
inline void retry_sleep(int ms=500){std::this_thread::sleep_for(std::chrono::milliseconds(ms));}
}
