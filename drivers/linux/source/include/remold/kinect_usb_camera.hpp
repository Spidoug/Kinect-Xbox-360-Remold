#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace remold::kinectusb {

enum class VideoMode { Rgb, RgbHighQuality, Infrared };

struct DeviceInfo {
  uint8_t bus = 0;
  std::vector<uint8_t> ports;
  uint16_t product_id = 0;
  std::string id;
  std::string label;
};

struct DepthCalibrationInfo {
  bool valid = false;
  double const_shift = 0.0;
  double emitter_distance = 0.0;
  double reference_distance = 0.0;
  double reference_pixel_size = 0.0;
};

std::vector<DeviceInfo> enumerate();

class Camera {
 public:
  using RgbCallback = std::function<void(const uint8_t* bayer, std::size_t bytes, uint32_t timestamp)>;
  using HqRgbCallback = std::function<void(const uint8_t* bayer, std::size_t bytes, uint32_t timestamp)>;
  using IrCallback = std::function<void(const uint8_t* packed10, std::size_t bytes, uint32_t timestamp)>;
  using DepthCallback = std::function<void(const uint8_t* packed11, std::size_t bytes, uint32_t timestamp)>;

  Camera();
  ~Camera();
  Camera(const Camera&) = delete;
  Camera& operator=(const Camera&) = delete;

  int open(const DeviceInfo& device, RgbCallback rgb_cb, HqRgbCallback hq_rgb_cb, IrCallback ir_cb, DepthCallback depth_cb);
  void close();

  int start_video(VideoMode mode);
  int stop_video();
  int start_depth();
  int stop_depth();
  int process_events(int timeout_ms);

  bool online() const;
  bool depth_calibrated() const;
  DepthCalibrationInfo depth_calibration() const;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace remold::kinectusb
