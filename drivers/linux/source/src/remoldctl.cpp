#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include "remold/protocol.hpp"
#include "remold/unix_socket.hpp"
using namespace remold;
static void usage(){std::puts("Usage: kinect360-remoldctl status | tilt <degrees> | led <off|green|red|yellow|blink-green|blink-yellow-red> | ping");}
static int led(const std::string&s){if(s=="off")return 0;if(s=="green")return 1;if(s=="red")return 2;if(s=="yellow")return 3;if(s=="blink-green")return 4;if(s=="blink-yellow-red")return 6;return -1;}
int main(int argc,char**argv){if(argc<2){usage();return 2;}control::Request q{};std::string a=argv[1];if(a=="ping")q.command=control::Command::Ping;else if(a=="status")q.command=control::Command::Status;else if(a=="tilt"&&argc==3){q.command=control::Command::Tilt;q.value=std::atoi(argv[2]);}else if(a=="led"&&argc==3){int v=led(argv[2]);if(v<0){usage();return 2;}q.command=control::Command::Led;q.value=v;}else{usage();return 2;}int fd=unixio::connect_socket(kControlSocket);if(fd<0){std::perror("broker");return 3;}control::Reply r{};if(!unixio::write_all(fd,&q,sizeof(q))||!unixio::read_exact(fd,&r,sizeof(r))){std::puts("broker I/O failed");return 4;}::close(fd);if(r.result<0){std::printf("ERROR %d (%s)\n",r.result,std::strerror(-r.result));return 5;}if(a=="status")std::printf("OK accel=%d,%d,%d tilt=%.1f state=%u\n",r.accelX,r.accelY,r.accelZ,r.tiltTenths/10.0,r.state);else std::puts("OK");return 0;}
