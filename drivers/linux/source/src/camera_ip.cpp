#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>
#include <arpa/inet.h>
#include <jpeglib.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include "remold/config.hpp"
#include "remold/protocol.hpp"
#include "remold/unix_socket.hpp"

using namespace remold;

namespace {
std::atomic<bool> run{true};
std::atomic<uint32_t> active_clients{0};
std::mutex demand_mutex;
std::condition_variable demand_cv;

void stop_handler(int) { run = false; }

std::string base64(const std::string& input) {
  static constexpr char alphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string output;
  int value = 0, bits = -6;
  for (unsigned char c : input) {
    value = (value << 8) + c;
    bits += 8;
    while (bits >= 0) {
      output.push_back(alphabet[(value >> bits) & 63]);
      bits -= 6;
    }
  }
  if (bits > -6) output.push_back(alphabet[((value << 8) >> (bits + 8)) & 63]);
  while (output.size() % 4) output.push_back('=');
  return output;
}

std::vector<uint8_t> jpeg_nv12(const uint8_t* pixels, int quality) {
  std::vector<uint8_t> rgb(scanner::kWidth * scanner::kHeight * 3);
  const uint8_t* y = pixels;
  const uint8_t* uv = pixels + scanner::kWidth * scanner::kHeight;
  for (uint32_t row = 0; row < scanner::kHeight; ++row) {
    for (uint32_t col = 0; col < scanner::kWidth; ++col) {
      int yy = y[row * scanner::kWidth + col] - 16;
      int u = uv[(row / 2) * scanner::kWidth + (col & ~1u)] - 128;
      int v = uv[(row / 2) * scanner::kWidth + (col & ~1u) + 1] - 128;
      yy = std::max(0, yy);
      int r = (298 * yy + 409 * v + 128) >> 8;
      int g = (298 * yy - 100 * u - 208 * v + 128) >> 8;
      int b = (298 * yy + 516 * u + 128) >> 8;
      auto clamp = [](int n) { return static_cast<uint8_t>(std::clamp(n, 0, 255)); };
      size_t q = (row * scanner::kWidth + col) * 3;
      rgb[q] = clamp(r);
      rgb[q + 1] = clamp(g);
      rgb[q + 2] = clamp(b);
    }
  }

  jpeg_compress_struct compressor{};
  jpeg_error_mgr errors{};
  compressor.err = jpeg_std_error(&errors);
  jpeg_create_compress(&compressor);
  unsigned char* output = nullptr;
  unsigned long output_size = 0;
  jpeg_mem_dest(&compressor, &output, &output_size);
  compressor.image_width = scanner::kWidth;
  compressor.image_height = scanner::kHeight;
  compressor.input_components = 3;
  compressor.in_color_space = JCS_RGB;
  jpeg_set_defaults(&compressor);
  jpeg_set_quality(&compressor, quality, TRUE);
  jpeg_start_compress(&compressor, TRUE);
  while (compressor.next_scanline < compressor.image_height) {
    JSAMPROW row = rgb.data() + compressor.next_scanline * scanner::kWidth * 3;
    jpeg_write_scanlines(&compressor, &row, 1);
  }
  jpeg_finish_compress(&compressor);
  std::vector<uint8_t> result(output, output + output_size);
  std::free(output);
  jpeg_destroy_compress(&compressor);
  return result;
}

class Frames {
 public:
  void set(std::vector<uint8_t> frame) {
    std::lock_guard<std::mutex> lock(mutex_);
    jpeg_ = std::move(frame);
    ++sequence_;
    cv_.notify_all();
  }

  uint64_t sequence() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return sequence_;
  }

  bool wait(uint64_t& last, std::vector<uint8_t>& output) {
    std::unique_lock<std::mutex> lock(mutex_);
    cv_.wait_for(lock, std::chrono::seconds(2), [&] { return !run || sequence_ != last; });
    if (!run) return false;
    if (sequence_ == last) return true;
    last = sequence_;
    output = jpeg_;
    return true;
  }

  void wake_all() { cv_.notify_all(); }

 private:
  mutable std::mutex mutex_;
  std::condition_variable cv_;
  std::vector<uint8_t> jpeg_;
  uint64_t sequence_ = 0;
} frames;

class ClientLease {
 public:
  ClientLease() {
    active_clients.fetch_add(1);
    demand_cv.notify_all();
  }
  ~ClientLease() {
    active_clients.fetch_sub(1);
    demand_cv.notify_all();
  }
  ClientLease(const ClientLease&) = delete;
  ClientLease& operator=(const ClientLease&) = delete;
};

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
    return -1;
  }
  return fd;
}

void signal_activity() {
  int fd = unixio::connect_socket(kControlSocket);
  if (fd < 0) return;
  control::Request request{};
  request.command = control::Command::CameraActivity;
  request.value = static_cast<int32_t>(control::CameraActivitySource::IpCamera);
  control::Reply reply{};
  if (unixio::write_all(fd, &request, sizeof(request)))
    (void)unixio::read_exact(fd, &reply, sizeof(reply));
  ::close(fd);
}

void feeder(int quality) {
  std::vector<uint8_t> payload(scanner::kMaxPayloadBytes);
  while (run) {
    {
      std::unique_lock<std::mutex> lock(demand_mutex);
      demand_cv.wait(lock, [] { return !run || active_clients.load() > 0; });
    }
    if (!run) break;

    int fd = subscribe_rgb();
    if (fd < 0) {
      unixio::retry_sleep(300);
      continue;
    }

    uint64_t last_activity = 0;
    while (run && active_clients.load() > 0) {
      scanner::FrameHeader header{};
      if (!unixio::read_exact(fd, &header, sizeof(header)) ||
          header.payloadBytes > payload.size() ||
          !unixio::read_exact(fd, payload.data(), header.payloadBytes)) {
        break;
      }
      if (header.mode == scanner::StreamMode::Rgb &&
          header.pixelFormat == scanner::PixelFormat::Nv12 &&
          header.payloadBytes == scanner::kNv12PayloadBytes) {
        frames.set(jpeg_nv12(payload.data(), quality));
      }
      uint64_t now = unixio::monotonic_ms();
      if (now - last_activity >= 1000) {
        signal_activity();
        last_activity = now;
      }
    }
    ::close(fd);
  }
}

bool send_all(int fd, const void* data, size_t bytes) {
  return unixio::write_all(fd, data, bytes);
}

void client(int fd, const std::string& auth) {
  std::string request;
  char buffer[2048];
  while (request.size() < 8192 && request.find("\r\n\r\n") == std::string::npos) {
    ssize_t n = ::recv(fd, buffer, sizeof(buffer), 0);
    if (n <= 0) {
      ::close(fd);
      return;
    }
    request.append(buffer, static_cast<size_t>(n));
  }

  if (request.find("Authorization: Basic " + auth) == std::string::npos) {
    const std::string response =
        "HTTP/1.1 401 Unauthorized\r\n"
        "WWW-Authenticate: Basic realm=\"Kinect360Remold\"\r\n"
        "Content-Length: 0\r\n\r\n";
    send_all(fd, response.data(), response.size());
    ::close(fd);
    return;
  }

  ClientLease lease;
  uint64_t sequence = frames.sequence();
  const bool snapshot = request.rfind("GET /snapshot.jpg", 0) == 0;
  if (snapshot) {
    std::vector<uint8_t> jpeg;
    while (run && jpeg.empty()) {
      if (!frames.wait(sequence, jpeg)) break;
    }
    if (!jpeg.empty()) {
      std::ostringstream headers;
      headers << "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: "
              << jpeg.size() << "\r\nCache-Control: no-store\r\n\r\n";
      const auto text = headers.str();
      send_all(fd, text.data(), text.size());
      send_all(fd, jpeg.data(), jpeg.size());
    }
    ::close(fd);
    return;
  }

  const std::string headers =
      "HTTP/1.1 200 OK\r\n"
      "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n"
      "Cache-Control: no-store\r\nConnection: close\r\n\r\n";
  if (!send_all(fd, headers.data(), headers.size())) {
    ::close(fd);
    return;
  }

  while (run) {
    std::vector<uint8_t> jpeg;
    if (!frames.wait(sequence, jpeg)) break;
    if (jpeg.empty()) continue;
    std::ostringstream part;
    part << "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: " << jpeg.size()
         << "\r\n\r\n";
    const auto text = part.str();
    if (!send_all(fd, text.data(), text.size()) ||
        !send_all(fd, jpeg.data(), jpeg.size()) ||
        !send_all(fd, "\r\n", 2)) {
      break;
    }
  }
  ::close(fd);
}
}  // namespace

int main() {
  std::signal(SIGINT, stop_handler);
  std::signal(SIGTERM, stop_handler);
  std::signal(SIGPIPE, SIG_IGN);

  Config config;
  if (!config.get_bool("ip.enabled", false)) return 0;
  const std::string user = config.get("ip.user", "admin");
  const std::string password = config.get("ip.password", "");
  if (password.empty()) {
    std::fprintf(stderr, "ip.password is empty; refusing insecure startup\n");
    return 2;
  }
  const int port = config.get_int("ip.port", 8088);
  const int quality = std::clamp(config.get_int("ip.jpeg_quality", 78), 30, 95);

  std::thread feed(feeder, quality);
  int server = ::socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
  int one = 1;
  ::setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_port = htons(static_cast<uint16_t>(port));
  address.sin_addr.s_addr = INADDR_ANY;
  if (::bind(server, reinterpret_cast<sockaddr*>(&address), sizeof(address)) < 0 ||
      ::listen(server, 16) < 0) {
    std::perror("ip camera");
    run = false;
    demand_cv.notify_all();
    feed.join();
    return 3;
  }

  const std::string auth = base64(user + ":" + password);
  while (run) {
    int fd = ::accept4(server, nullptr, nullptr, SOCK_CLOEXEC);
    if (fd < 0) {
      if (errno == EINTR) continue;
      break;
    }
    std::thread(client, fd, auth).detach();
  }

  ::close(server);
  run = false;
  demand_cv.notify_all();
  frames.wake_all();
  if (feed.joinable()) feed.join();
  return 0;
}
