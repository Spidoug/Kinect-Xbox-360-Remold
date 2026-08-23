#include <atomic>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include "remold/config.hpp"
#include "remold/protocol.hpp"
#include "remold/unix_socket.hpp"

using namespace remold;

namespace {
std::atomic<bool> run{true};
void stop_handler(int) { run = false; }

constexpr uint32_t kClientUsageEvent = V4L2_EVENT_PRIVATE_START + 0x08E00000u + 1u;

int xioctl(int fd, unsigned long request, void* arg) {
  int rc;
  do rc = ::ioctl(fd, request, arg); while (rc < 0 && errno == EINTR);
  return rc;
}

bool write_frame(int fd, const uint8_t* data, size_t size) {
  size_t done = 0;
  while (done < size) {
    ssize_t n = ::write(fd, data + done, size - done);
    if (n < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    if (n == 0) return false;
    done += static_cast<size_t>(n);
  }
  return true;
}

int open_v4l2(const std::string& device) {
  int fd = ::open(device.c_str(), O_WRONLY | O_CLOEXEC | O_NONBLOCK);
  if (fd < 0) return -1;

  v4l2_format format{};
  format.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
  format.fmt.pix.width = scanner::kWidth;
  format.fmt.pix.height = scanner::kHeight;
  format.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
  format.fmt.pix.field = V4L2_FIELD_NONE;
  format.fmt.pix.bytesperline = scanner::kWidth * 2;
  format.fmt.pix.sizeimage = scanner::kWidth * scanner::kHeight * 2;
  if (xioctl(fd, VIDIOC_S_FMT, &format) < 0) {
    ::close(fd);
    return -1;
  }

  // Keep the v4l2loopback endpoint advertised as a CAPTURE device without
  // holding Kinect RGB. The first neutral frame starts the OUTPUT side only.
  std::vector<uint8_t> black(scanner::kWidth * scanner::kHeight * 2, 0x80);
  for (size_t i = 0; i < black.size(); i += 4) {
    black[i] = 16;
    black[i + 1] = 128;
    black[i + 2] = 16;
    black[i + 3] = 128;
  }
  bool primed = false;
  for (int attempt = 0; attempt < 20 && !primed; ++attempt) {
    if (write_frame(fd, black.data(), black.size())) {
      primed = true;
      break;
    }
    if (errno != EAGAIN && errno != EWOULDBLOCK) {
      ::close(fd);
      return -1;
    }
    unixio::retry_sleep(25);
  }
  if (!primed) {
    errno = EAGAIN;
    ::close(fd);
    return -1;
  }
  return fd;
}

bool subscribe_client_events(int fd) {
  v4l2_event_subscription sub{};
  sub.type = kClientUsageEvent;
  sub.flags = V4L2_EVENT_SUB_FL_SEND_INITIAL;
  return xioctl(fd, VIDIOC_SUBSCRIBE_EVENT, &sub) == 0;
}

bool dequeue_client_state(int fd, bool& active) {
  v4l2_event event{};
  if (xioctl(fd, VIDIOC_DQEVENT, &event) < 0) return false;
  if (event.type != kClientUsageEvent) return false;
  uint32_t count = 0;
  static_assert(sizeof(count) <= sizeof(event.u.data));
  std::memcpy(&count, event.u.data, sizeof(count));
  active = count != 0;
  return true;
}

int subscribe_rgb() {
  int fd = unixio::connect_socket(kScannerSocket);
  if (fd < 0) return -1;
  scanner::Request request{};
  request.streamMask = scanner::StreamRgb;
  scanner::Reply reply{};
  if (!unixio::write_all(fd, &request, sizeof(request)) ||
      !unixio::read_exact(fd, &reply, sizeof(reply)) || reply.result < 0 ||
      reply.acceptedMask != request.streamMask) {
    ::close(fd);
    errno = EBUSY;
    return -1;
  }
  return fd;
}

void signal_activity() {
  int fd = unixio::connect_socket(kControlSocket);
  if (fd < 0) return;
  control::Request request{};
  request.command = control::Command::CameraActivity;
  request.value = static_cast<int32_t>(control::CameraActivitySource::VirtualCamera);
  control::Reply reply{};
  if (unixio::write_all(fd, &request, sizeof(request)))
    (void)unixio::read_exact(fd, &reply, sizeof(reply));
  ::close(fd);
}

void nv12_to_yuyv(const uint8_t* src, uint8_t* dst) {
  const uint8_t* y = src;
  const uint8_t* uv = src + scanner::kWidth * scanner::kHeight;
  for (uint32_t row = 0; row < scanner::kHeight; ++row) {
    for (uint32_t col = 0; col < scanner::kWidth; col += 2) {
      const size_t yp = row * scanner::kWidth + col;
      const size_t up = (row / 2) * scanner::kWidth + col;
      const size_t op = (row * scanner::kWidth + col) * 2;
      dst[op] = y[yp];
      dst[op + 1] = uv[up];
      dst[op + 2] = y[yp + 1];
      dst[op + 3] = uv[up + 1];
    }
  }
}
}  // namespace

int main() {
  std::signal(SIGINT, stop_handler);
  std::signal(SIGTERM, stop_handler);
  std::signal(SIGPIPE, SIG_IGN);

  Config config;
  const std::string device = config.get("v4l2.device", "/dev/video42");
  std::vector<uint8_t> payload(scanner::kMaxPayloadBytes);
  std::vector<uint8_t> yuyv(scanner::kWidth * scanner::kHeight * 2);

  while (run) {
    int out = open_v4l2(device);
    if (out < 0) {
      std::perror("v4l2");
      unixio::retry_sleep(1000);
      continue;
    }

    const bool event_supported = subscribe_client_events(out);
    if (!event_supported) {
      std::fprintf(stderr, "v4l2: V1 requires V4L2_EVENT_CTRL client activity support\n");
      ::close(out);
      unixio::retry_sleep(1000);
      continue;
    }
    bool client_active = false;
    int scanner_fd = -1;
    uint64_t last_activity = 0;

    while (run) {
      if (client_active && scanner_fd < 0) {
        scanner_fd = subscribe_rgb();
        if (scanner_fd < 0) unixio::retry_sleep(300);
      } else if (!client_active && scanner_fd >= 0) {
        ::close(scanner_fd);
        scanner_fd = -1;
      }

      pollfd pfd[2]{};
      pfd[0].fd = out;
      pfd[0].events = POLLPRI;
      pfd[1].fd = scanner_fd;
      pfd[1].events = scanner_fd >= 0 ? POLLIN : 0;
      int rc = ::poll(pfd, 2, 500);
      if (rc < 0) {
        if (errno == EINTR) continue;
        break;
      }

      if (pfd[0].revents & POLLPRI) {
        bool state = client_active;
        while (dequeue_client_state(out, state)) client_active = state;
      }

      if (client_active) {
        const uint64_t now = unixio::monotonic_ms();
        if (now - last_activity >= 1000) {
          signal_activity();
          last_activity = now;
        }
      }

      if (scanner_fd >= 0 && (pfd[1].revents & (POLLERR | POLLHUP | POLLNVAL))) {
        ::close(scanner_fd);
        scanner_fd = -1;
        continue;
      }
      if (scanner_fd < 0 || !(pfd[1].revents & POLLIN)) continue;

      scanner::FrameHeader header{};
      if (!unixio::read_exact(scanner_fd, &header, sizeof(header)) ||
          header.payloadBytes > payload.size() ||
          !unixio::read_exact(scanner_fd, payload.data(), header.payloadBytes)) {
        ::close(scanner_fd);
        scanner_fd = -1;
        continue;
      }
      if (header.mode != scanner::StreamMode::Rgb ||
          header.pixelFormat != scanner::PixelFormat::Nv12 ||
          header.payloadBytes != scanner::kNv12PayloadBytes) {
        continue;
      }

      nv12_to_yuyv(payload.data(), yuyv.data());
      if (!write_frame(out, yuyv.data(), yuyv.size()) && errno != EAGAIN) break;
    }

    if (scanner_fd >= 0) ::close(scanner_fd);
    ::close(out);
    unixio::retry_sleep(500);
  }
  return 0;
}
