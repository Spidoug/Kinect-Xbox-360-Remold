#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>

namespace remold::kinectusb {

enum class VideoMode { Rgb, Infrared };

class Camera {
 public:
  using RgbCallback = std::function<void(const uint8_t* rgb, std::size_t bytes, uint32_t timestamp)>;
  using IrCallback = std::function<void(const uint16_t* ir, std::size_t pixels, uint32_t timestamp)>;
  using DepthCallback = std::function<void(const uint16_t* depth_mm, std::size_t pixels, uint32_t timestamp, bool calibrated)>;

  Camera();
  ~Camera();
  Camera(const Camera&) = delete;
  Camera& operator=(const Camera&) = delete;

  int open(RgbCallback rgb_cb, IrCallback ir_cb, DepthCallback depth_cb);
  void close();

  int start_video(VideoMode mode);
  int stop_video();
  int start_depth();
  int stop_depth();
  int process_events(int timeout_ms);

  bool online() const;
  bool depth_calibrated() const;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace remold::kinectusb
