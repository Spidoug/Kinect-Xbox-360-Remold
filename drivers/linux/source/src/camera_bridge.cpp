#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <csignal>
#include <signal.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

#include "remold/kinect_usb_camera.hpp"
#include "remold/protocol.hpp"
#include "remold/unix_socket.hpp"

using namespace remold;

namespace {
std::atomic<bool> run{true};
void stop_handler(int) { run = false; }

struct Frame {
  uint64_t seq = 0;
  uint64_t tick = 0;
  bool calibrated = false;
  std::vector<uint8_t> data;
};

class CameraHub {
 public:
  CameraHub() = default;

  ~CameraHub() { shutdown(); }

  void start() { worker_ = std::thread([this] { loop(); }); }

  void shutdown() {
    run = false;
    cv_.notify_all();
    if (worker_.joinable()) worker_.join();
    close_device();
  }

  int acquire(uint32_t mask) {
    if (!scanner::valid_mask(mask)) return -EINVAL;
    std::unique_lock<std::mutex> lock(dev_mu_);
    if (!online_) return -ENODEV;
    if ((mask & scanner::StreamRgb) && ir_users_ > 0) return -EBUSY;
    if ((mask & scanner::StreamInfrared) && rgb_users_ > 0) return -EBUSY;

    if (mask & scanner::StreamRgb) ++rgb_users_;
    if (mask & scanner::StreamInfrared) ++ir_users_;
    if (mask & scanner::StreamDepth) ++depth_users_;

    const int rc = apply_locked();
    if (rc < 0) {
      if (mask & scanner::StreamRgb) --rgb_users_;
      if (mask & scanner::StreamInfrared) --ir_users_;
      if (mask & scanner::StreamDepth) --depth_users_;
    }
    return rc;
  }

  void release(uint32_t mask) {
    std::lock_guard<std::mutex> lock(dev_mu_);
    if (mask & scanner::StreamRgb) rgb_users_ = std::max(0, rgb_users_ - 1);
    if (mask & scanner::StreamInfrared) ir_users_ = std::max(0, ir_users_ - 1);
    if (mask & scanner::StreamDepth) depth_users_ = std::max(0, depth_users_ - 1);
    (void)apply_locked();
    clear_inactive_queues_locked();
  }

  bool wait_next(uint32_t mask, uint64_t& rgb_seq, uint64_t& ir_seq, uint64_t& depth_seq,
                 scanner::FrameHeader& header, std::vector<uint8_t>& output) {
    std::unique_lock<std::mutex> lock(frame_mu_);
    cv_.wait_for(lock, std::chrono::milliseconds(1000), [&] {
      return !run || !online_.load() ||
             ((mask & scanner::StreamRgb) && has_after(rgb_queue_, rgb_seq)) ||
             ((mask & scanner::StreamInfrared) && has_after(ir_queue_, ir_seq)) ||
             ((mask & scanner::StreamDepth) && has_after(depth_queue_, depth_seq));
    });
    if (!run || !online_) return false;

    const Frame* chosen = nullptr;
    scanner::StreamMode chosen_mode = scanner::StreamMode::Depth;
    scanner::PixelFormat chosen_format = scanner::PixelFormat::DepthMm16;
    auto consider = [&](const std::deque<Frame>& queue, uint64_t seen, scanner::StreamMode mode, scanner::PixelFormat format) {
      const Frame* candidate = next_after(queue, seen);
      if (candidate && (!chosen || candidate->tick < chosen->tick ||
          (candidate->tick == chosen->tick && mode == scanner::StreamMode::Depth))) {
        chosen = candidate; chosen_mode = mode; chosen_format = format;
      }
    };
    if (mask & scanner::StreamRgb) consider(rgb_queue_, rgb_seq, scanner::StreamMode::Rgb, scanner::PixelFormat::Nv12);
    if (mask & scanner::StreamInfrared) consider(ir_queue_, ir_seq, scanner::StreamMode::Infrared, scanner::PixelFormat::Gray16);
    if (mask & scanner::StreamDepth) consider(depth_queue_, depth_seq, scanner::StreamMode::Depth, scanner::PixelFormat::DepthMm16);
    if (!chosen) return true;

    header = {};
    header.mode = chosen_mode; header.pixelFormat = chosen_format;
    header.payloadBytes = static_cast<uint32_t>(chosen->data.size());
    if (chosen_mode == scanner::StreamMode::Depth && chosen->calibrated) header.flags |= scanner::kFlagDeviceCalibrated;
    header.frameNumber = chosen->seq; header.tickMs = chosen->tick; output = chosen->data;
    if (chosen_mode == scanner::StreamMode::Rgb) rgb_seq = chosen->seq;
    else if (chosen_mode == scanner::StreamMode::Infrared) ir_seq = chosen->seq;
    else depth_seq = chosen->seq;
    return true;
  }

 private:
  static constexpr std::size_t kFrameQueueDepth = 48;
  bool has_after(const std::deque<Frame>& queue, uint64_t seq) const { return !queue.empty() && queue.back().seq > seq; }
  const Frame* next_after(const std::deque<Frame>& queue, uint64_t seq) const {
    for (const auto& frame : queue) if (frame.seq > seq) return &frame;
    return nullptr;
  }
  void push_frame(std::deque<Frame>& queue, Frame&& frame) {
    queue.push_back(std::move(frame));
    while (queue.size() > kFrameQueueDepth) queue.pop_front();
    cv_.notify_all();
  }
  void clear_inactive_queues_locked() {
    std::lock_guard<std::mutex> lock(frame_mu_);
    if (rgb_users_ == 0) rgb_queue_.clear();
    if (ir_users_ == 0) ir_queue_.clear();
    if (depth_users_ == 0) depth_queue_.clear();
    cv_.notify_all();
  }
  void clear_all_queues_locked() {
    std::lock_guard<std::mutex> lock(frame_mu_);
    rgb_queue_.clear(); ir_queue_.clear(); depth_queue_.clear();
    cv_.notify_all();
  }
  static uint8_t clamp8(int value) {
    return static_cast<uint8_t>(value < 0 ? 0 : value > 255 ? 255 : value);
  }

  void rgb_to_nv12(const uint8_t* rgb, std::vector<uint8_t>& dst) {
    auto* y_plane = dst.data();
    auto* uv_plane = dst.data() + scanner::kWidth * scanner::kHeight;

    for (uint32_t y = 0; y < scanner::kHeight; ++y) {
      for (uint32_t x = 0; x < scanner::kWidth; ++x) {
        const std::size_t p = (static_cast<std::size_t>(y) * scanner::kWidth + x) * 3u;
        const int r = rgb[p], g = rgb[p + 1], b = rgb[p + 2];
        y_plane[static_cast<std::size_t>(y) * scanner::kWidth + x] =
            clamp8(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
      }
    }

    for (uint32_t y = 0; y < scanner::kHeight; y += 2) {
      for (uint32_t x = 0; x < scanner::kWidth; x += 2) {
        int sum_r = 0, sum_g = 0, sum_b = 0;
        for (uint32_t dy = 0; dy < 2; ++dy) {
          for (uint32_t dx = 0; dx < 2; ++dx) {
            const std::size_t p = (static_cast<std::size_t>(y + dy) * scanner::kWidth + x + dx) * 3u;
            sum_r += rgb[p];
            sum_g += rgb[p + 1];
            sum_b += rgb[p + 2];
          }
        }
        const int r = sum_r / 4, g = sum_g / 4, b = sum_b / 4;
        const std::size_t q = static_cast<std::size_t>(y / 2) * scanner::kWidth + x;
        uv_plane[q] = clamp8(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
        uv_plane[q + 1] = clamp8(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
      }
    }
  }

  void on_rgb(const uint8_t* data, std::size_t bytes, uint32_t) {
    if (bytes != static_cast<std::size_t>(scanner::kWidth) * scanner::kHeight * 3u) return;
    Frame next; next.data.resize(scanner::kNv12PayloadBytes); rgb_to_nv12(data, next.data);
    next.tick = unixio::monotonic_ms(); next.calibrated = false; next.seq = ++rgb_seq_counter_;
    std::lock_guard<std::mutex> lock(frame_mu_); push_frame(rgb_queue_, std::move(next));
  }

  void on_ir(const uint16_t* data, std::size_t pixels, uint32_t) {
    if (pixels < static_cast<std::size_t>(scanner::kWidth) * scanner::kHeight) return;
    Frame next; next.data.resize(scanner::kGray16PayloadBytes); std::memcpy(next.data.data(), data, scanner::kGray16PayloadBytes);
    next.tick = unixio::monotonic_ms(); next.calibrated = false; next.seq = ++ir_seq_counter_;
    std::lock_guard<std::mutex> lock(frame_mu_); push_frame(ir_queue_, std::move(next));
  }

  void on_depth(const uint16_t* data, std::size_t pixels, uint32_t, bool calibrated) {
    if (pixels < static_cast<std::size_t>(scanner::kWidth) * scanner::kHeight) return;
    Frame next; next.data.resize(scanner::kDepthPayloadBytes); std::memcpy(next.data.data(), data, scanner::kDepthPayloadBytes);
    next.tick = unixio::monotonic_ms(); next.calibrated = calibrated; next.seq = ++depth_seq_counter_;
    std::lock_guard<std::mutex> lock(frame_mu_); push_frame(depth_queue_, std::move(next));
  }

  int open_device_locked() {
    const int rc = device_.open(
        [this](const uint8_t* p, std::size_t n, uint32_t ts) { on_rgb(p, n, ts); },
        [this](const uint16_t* p, std::size_t n, uint32_t ts) { on_ir(p, n, ts); },
        [this](const uint16_t* p, std::size_t n, uint32_t ts, bool calibrated) {
          on_depth(p, n, ts, calibrated);
        });
    if (rc < 0) return rc;
    ir_mode_ = false;
    video_on_ = false;
    depth_on_ = false;
    online_ = true;
    cv_.notify_all();
    return 0;
  }

  void close_device_locked() {
    device_.close();
    video_on_ = false;
    depth_on_ = false;
    online_ = false;
    clear_all_queues_locked();
  }

  void close_device() {
    std::lock_guard<std::mutex> lock(dev_mu_);
    close_device_locked();
  }

  int apply_locked() {
    if (!online_ || !device_.online()) return -ENODEV;
    const bool want_video = (rgb_users_ + ir_users_) > 0;
    const bool want_ir = ir_users_ > 0;
    const bool want_depth = depth_users_ > 0;

    if (video_on_ && (!want_video || want_ir != ir_mode_)) {
      if (device_.stop_video() < 0) return -EIO;
      video_on_ = false;
    }
    if (want_video && !video_on_) {
      ir_mode_ = want_ir;
      if (device_.start_video(want_ir ? kinectusb::VideoMode::Infrared : kinectusb::VideoMode::Rgb) < 0) return -EIO;
      video_on_ = true;
    }
    if (depth_on_ && !want_depth) {
      if (device_.stop_depth() < 0) return -EIO;
      depth_on_ = false;
    }
    if (want_depth && !depth_on_) {
      if (device_.start_depth() < 0) return -EIO;
      depth_on_ = true;
    }
    return 0;
  }

  void loop() {
    while (run) {
      if (!online_) {
        int rc = 0;
        {
          std::lock_guard<std::mutex> lock(dev_mu_);
          rc = open_device_locked();
        }
        if (rc < 0) {
          unixio::retry_sleep(750);
          continue;
        }
      }

      int rc = 0;
      {
        std::lock_guard<std::mutex> lock(dev_mu_);
        rc = device_.process_events(200);
        if (rc < 0) close_device_locked();
      }
      if (rc < 0) unixio::retry_sleep(500);
    }
  }

  kinectusb::Camera device_;
  std::thread worker_;
  std::mutex dev_mu_;
  std::mutex frame_mu_;
  std::condition_variable cv_;
  std::atomic<bool> online_{false};
  int rgb_users_ = 0;
  int ir_users_ = 0;
  int depth_users_ = 0;
  bool video_on_ = false;
  bool depth_on_ = false;
  bool ir_mode_ = false;
  uint64_t rgb_seq_counter_ = 0, ir_seq_counter_ = 0, depth_seq_counter_ = 0;
  std::deque<Frame> rgb_queue_, ir_queue_, depth_queue_;
};

CameraHub* hub = nullptr;

void client(int fd) {
  scanner::Request request{};
  scanner::Reply reply{};
  if (!unixio::read_exact(fd, &request, sizeof(request)) || request.magic != scanner::kMagic ||
      request.version != scanner::kVersion || request.command != scanner::Command::SubscribeStreams) {
    ::close(fd);
    return;
  }

  const int rc = hub->acquire(request.streamMask);
  reply.result = rc;
  if (rc == 0) reply.acceptedMask = request.streamMask;
  unixio::write_all(fd, &reply, sizeof(reply));
  if (rc < 0) {
    ::close(fd);
    return;
  }

  uint64_t rgb_seq = 0, ir_seq = 0, depth_seq = 0;
  while (run) {
    scanner::FrameHeader header{};
    std::vector<uint8_t> data;
    if (!hub->wait_next(request.streamMask, rgb_seq, ir_seq, depth_seq, header, data)) break;
    if (header.frameNumber == 0) continue;
    if (!unixio::write_all(fd, &header, sizeof(header)) || !unixio::write_all(fd, data.data(), data.size())) break;
  }
  hub->release(request.streamMask);
  ::close(fd);
}
}  // namespace

int main() {
  struct sigaction action{};
  action.sa_handler = stop_handler;
  sigemptyset(&action.sa_mask);
  action.sa_flags = 0;  // do not restart accept(2); systemd stop must exit promptly
  sigaction(SIGINT, &action, nullptr);
  sigaction(SIGTERM, &action, nullptr);
  std::signal(SIGPIPE, SIG_IGN);

  CameraHub camera_hub;
  hub = &camera_hub;
  camera_hub.start();

  const int server = unixio::server_socket(kScannerSocket, 0666);
  if (server < 0) {
    std::perror("scanner socket");
    return 2;
  }

  while (run) {
    const int connection = ::accept4(server, nullptr, nullptr, SOCK_CLOEXEC);
    if (connection < 0) {
      if (errno == EINTR) continue;
      if (!run) break;
      unixio::retry_sleep();
      continue;
    }
    std::thread(client, connection).detach();
  }

  ::close(server);
  ::unlink(kScannerSocket);
  camera_hub.shutdown();
  return 0;
}
