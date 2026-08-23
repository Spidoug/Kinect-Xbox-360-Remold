/*
 * Kinect Xbox 360 direct USB camera backend for Kinect-Xbox-360-Remold.
 *
 * Protocol behavior was cross-checked against the public OpenKinect/libfreenect
 * sources and documentation. No libfreenect source file, binary, or shared
 * library is vendored or required by this backend. See the repository THIRD-PARTY-NOTICES.md and
 * licenses/Apache-2.0-OpenKinect.txt for attribution.
 */

#include "remold/kinect_usb_camera.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <thread>
#include <utility>
#include <vector>

#include <libusb-1.0/libusb.h>

namespace remold::kinectusb {
namespace {

constexpr uint16_t kMicrosoftVid = 0x045e;
constexpr uint16_t kNuiCameraPid = 0x02ae;
constexpr uint16_t kK4wCameraPid = 0x02bf;
constexpr uint8_t kVideoEndpoint = 0x81;
constexpr uint8_t kDepthEndpoint = 0x82;
constexpr int kCameraInterface = 0;
constexpr int kTransfers = 16;
constexpr int kPacketsPerTransfer = 16;
constexpr int kVideoPacketBytes = 1920;
constexpr int kDepthPacketBytes = 1760;
constexpr int kIsoTransferPacketBytes = 1920;  // Linux libfreenect-compatible isoch transfer slot size
constexpr int kVideoPayloadBytes = kVideoPacketBytes - 12;
constexpr int kDepthPayloadBytes = kDepthPacketBytes - 12;
constexpr std::size_t kWidth = 640;
constexpr std::size_t kHeight = 480;
constexpr std::size_t kIrHeight = 488;
constexpr std::size_t kRgbRawBytes = kWidth * kHeight;
constexpr std::size_t kIrRawBytes = kWidth * kIrHeight * 10 / 8;
constexpr std::size_t kDepthRawBytes = kWidth * kHeight * 11 / 8;
constexpr uint16_t kDepthRawNoValue = 2047;
constexpr uint16_t kDepthMmMaxValue = 10000;
constexpr double kS2dConstOffset = 0.375;

uint16_t get_le16(const uint8_t* p) {
  return static_cast<uint16_t>(p[0]) | (static_cast<uint16_t>(p[1]) << 8);
}

uint32_t get_le32(const uint8_t* p) {
  return static_cast<uint32_t>(p[0]) |
         (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) |
         (static_cast<uint32_t>(p[3]) << 24);
}

void put_le16(uint8_t* p, uint16_t v) {
  p[0] = static_cast<uint8_t>(v & 0xffu);
  p[1] = static_cast<uint8_t>((v >> 8) & 0xffu);
}

float get_le_float(const uint8_t* p) {
  const uint32_t bits = get_le32(p);
  float value = 0.0f;
  static_assert(sizeof(value) == sizeof(bits));
  std::memcpy(&value, &bits, sizeof(value));
  return value;
}

struct PacketHeader {
  uint8_t magic0 = 0;
  uint8_t magic1 = 0;
  uint8_t pad = 0;
  uint8_t flag = 0;
  uint8_t unk1 = 0;
  uint8_t seq = 0;
  uint8_t unk2 = 0;
  uint8_t unk3 = 0;
  uint32_t timestamp = 0;
};

bool parse_packet_header(const uint8_t* packet, int length, PacketHeader& out) {
  if (length < 12) return false;
  out.magic0 = packet[0];
  out.magic1 = packet[1];
  out.pad = packet[2];
  out.flag = packet[3];
  out.unk1 = packet[4];
  out.seq = packet[5];
  out.unk2 = packet[6];
  out.unk3 = packet[7];
  out.timestamp = get_le32(packet + 8);
  return out.magic0 == 'R' && out.magic1 == 'B';
}

class FrameAssembler {
 public:
  using FrameCallback = std::function<void(const uint8_t*, std::size_t, uint32_t)>;

  FrameAssembler(uint8_t base_flag, std::size_t frame_bytes, std::size_t packet_payload, FrameCallback callback)
      : base_flag_(base_flag), frame_(frame_bytes), packet_payload_(packet_payload), callback_(std::move(callback)) {
    packets_per_frame_ = (frame_bytes + packet_payload - 1u) / packet_payload;
    last_packet_bytes_ = frame_bytes % packet_payload;
    if (last_packet_bytes_ == 0) last_packet_bytes_ = packet_payload;
  }

  void reset() {
    synced_ = false;
    packet_index_ = 0;
    expected_seq_ = 0;
  }

  void process(const uint8_t* packet, int length) {
    PacketHeader header{};
    if (!parse_packet_header(packet, length, header)) return;

    const uint8_t sof = static_cast<uint8_t>(base_flag_ | 0x01u);
    const uint8_t mof = static_cast<uint8_t>(base_flag_ | 0x02u);
    const uint8_t eof = static_cast<uint8_t>(base_flag_ | 0x05u);

    if (!synced_) {
      if (header.flag != sof) return;
      start_frame(header.seq);
    } else if (header.seq != expected_seq_) {
      reset();
      if (header.flag != sof) return;
      start_frame(header.seq);
    }

    if (packet_index_ >= packets_per_frame_) {
      reset();
      return;
    }

    const bool first = packet_index_ == 0;
    const bool last = packet_index_ == packets_per_frame_ - 1u;
    const uint8_t expected_flag = first ? sof : (last ? eof : mof);
    if (header.flag != expected_flag) {
      reset();
      if (header.flag == sof) {
        start_frame(header.seq);
      } else {
        return;
      }
    }

    const int data_length = length - 12;
    if (data_length < 0) {
      reset();
      return;
    }
    const std::size_t expected_bytes = last ? last_packet_bytes_ : packet_payload_;
    if (static_cast<std::size_t>(data_length) > expected_bytes) {
      reset();
      return;
    }

    const std::size_t offset = packet_index_ * packet_payload_;
    std::memcpy(frame_.data() + offset, packet + 12, static_cast<std::size_t>(data_length));
    if (static_cast<std::size_t>(data_length) < expected_bytes) {
      std::memset(frame_.data() + offset + data_length, 0, expected_bytes - static_cast<std::size_t>(data_length));
    }

    ++packet_index_;
    expected_seq_ = static_cast<uint8_t>(header.seq + 1u);
    if (header.flag == eof) {
      if (packet_index_ == packets_per_frame_ && callback_) callback_(frame_.data(), frame_.size(), header.timestamp);
      reset();
    }
  }

 private:
  void start_frame(uint8_t sequence) {
    synced_ = true;
    packet_index_ = 0;
    expected_seq_ = sequence;
    std::fill(frame_.begin(), frame_.end(), 0);
  }

  uint8_t base_flag_;
  std::vector<uint8_t> frame_;
  std::size_t packet_payload_;
  std::size_t packets_per_frame_ = 0;
  std::size_t last_packet_bytes_ = 0;
  bool synced_ = false;
  uint8_t expected_seq_ = 0;
  std::size_t packet_index_ = 0;
  FrameCallback callback_;
};

void unpack_10bit(const uint8_t* source, uint16_t* destination, std::size_t pixels) {
  uint32_t buffer = 0;
  int bits_in = 0;
  while (pixels-- != 0) {
    while (bits_in < 10) {
      buffer = (buffer << 8) | *source++;
      bits_in += 8;
    }
    bits_in -= 10;
    *destination++ = static_cast<uint16_t>((buffer >> bits_in) & 0x03ffu);
  }
}

void unpack_11bit(const uint8_t* raw, uint16_t* frame, std::size_t pixels) {
  while (pixels >= 8) {
    const uint8_t r0 = raw[0], r1 = raw[1], r2 = raw[2], r3 = raw[3], r4 = raw[4], r5 = raw[5];
    const uint8_t r6 = raw[6], r7 = raw[7], r8 = raw[8], r9 = raw[9], r10 = raw[10];
    frame[0] = static_cast<uint16_t>((r0 << 3) | (r1 >> 5));
    frame[1] = static_cast<uint16_t>(((r1 << 6) | (r2 >> 2)) & 0x07ffu);
    frame[2] = static_cast<uint16_t>(((r2 << 9) | (r3 << 1) | (r4 >> 7)) & 0x07ffu);
    frame[3] = static_cast<uint16_t>(((r4 << 4) | (r5 >> 4)) & 0x07ffu);
    frame[4] = static_cast<uint16_t>(((r5 << 7) | (r6 >> 1)) & 0x07ffu);
    frame[5] = static_cast<uint16_t>(((r6 << 10) | (r7 << 2) | (r8 >> 6)) & 0x07ffu);
    frame[6] = static_cast<uint16_t>(((r8 << 5) | (r9 >> 3)) & 0x07ffu);
    frame[7] = static_cast<uint16_t>(((r9 << 8) | r10) & 0x07ffu);
    raw += 11;
    frame += 8;
    pixels -= 8;
  }
}

uint8_t sample_bayer(const uint8_t* bayer, int x, int y) {
  // Reflect one-pixel border reads instead of clamping them. Reflection preserves
  // Bayer parity, so an edge lookup never substitutes G for an expected R/B sample.
  if (x < 0) x = -x;
  if (x >= static_cast<int>(kWidth)) x = 2 * (static_cast<int>(kWidth) - 1) - x;
  if (y < 0) y = -y;
  if (y >= static_cast<int>(kHeight)) y = 2 * (static_cast<int>(kHeight) - 1) - y;
  return bayer[static_cast<std::size_t>(y) * kWidth + static_cast<std::size_t>(x)];
}

uint8_t average4(uint8_t a, uint8_t b, uint8_t c, uint8_t d) {
  return static_cast<uint8_t>((static_cast<unsigned>(a) + b + c + d + 2u) / 4u);
}

uint8_t average2(uint8_t a, uint8_t b) {
  return static_cast<uint8_t>((static_cast<unsigned>(a) + b + 1u) / 2u);
}

void bayer_to_rgb(const uint8_t* bayer, uint8_t* rgb) {
  for (int y = 0; y < static_cast<int>(kHeight); ++y) {
    for (int x = 0; x < static_cast<int>(kWidth); ++x) {
      const bool y_odd = (y & 1) != 0;
      const bool x_odd = (x & 1) != 0;
      const uint8_t center = sample_bayer(bayer, x, y);
      uint8_t r = 0, g = 0, b = 0;

      if (!y_odd && x_odd) {  // R site, Bayer pattern G R / B G
        r = center;
        g = average4(sample_bayer(bayer, x - 1, y), sample_bayer(bayer, x + 1, y),
                     sample_bayer(bayer, x, y - 1), sample_bayer(bayer, x, y + 1));
        b = average4(sample_bayer(bayer, x - 1, y - 1), sample_bayer(bayer, x + 1, y - 1),
                     sample_bayer(bayer, x - 1, y + 1), sample_bayer(bayer, x + 1, y + 1));
      } else if (y_odd && !x_odd) {  // B site
        b = center;
        g = average4(sample_bayer(bayer, x - 1, y), sample_bayer(bayer, x + 1, y),
                     sample_bayer(bayer, x, y - 1), sample_bayer(bayer, x, y + 1));
        r = average4(sample_bayer(bayer, x - 1, y - 1), sample_bayer(bayer, x + 1, y - 1),
                     sample_bayer(bayer, x - 1, y + 1), sample_bayer(bayer, x + 1, y + 1));
      } else if (!y_odd) {  // G with R horizontal / B vertical
        g = center;
        r = average2(sample_bayer(bayer, x - 1, y), sample_bayer(bayer, x + 1, y));
        b = average2(sample_bayer(bayer, x, y - 1), sample_bayer(bayer, x, y + 1));
      } else {  // G with R vertical / B horizontal
        g = center;
        r = average2(sample_bayer(bayer, x, y - 1), sample_bayer(bayer, x, y + 1));
        b = average2(sample_bayer(bayer, x - 1, y), sample_bayer(bayer, x + 1, y));
      }

      const std::size_t p = (static_cast<std::size_t>(y) * kWidth + static_cast<std::size_t>(x)) * 3u;
      rgb[p] = r;
      rgb[p + 1] = g;
      rgb[p + 2] = b;
    }
  }
}

}  // namespace

class Camera::Impl {
 public:
  Impl()
      : rgb_assembler_(0x80, kRgbRawBytes, kVideoPayloadBytes,
            [this](const uint8_t* frame, std::size_t bytes, uint32_t timestamp) { on_video_frame(frame, bytes, timestamp); }),
        ir_assembler_(0x80, kIrRawBytes, kVideoPayloadBytes,
            [this](const uint8_t* frame, std::size_t bytes, uint32_t timestamp) { on_video_frame(frame, bytes, timestamp); }),
        depth_assembler_(0x70, kDepthRawBytes, kDepthPayloadBytes,
            [this](const uint8_t* frame, std::size_t bytes, uint32_t timestamp) { on_depth_frame(frame, bytes, timestamp); }) {
    rgb_buffer_.resize(kWidth * kHeight * 3u);
    ir_buffer_.resize(kWidth * kIrHeight);
    depth_raw_buffer_.resize(kWidth * kHeight);
    depth_mm_buffer_.resize(kWidth * kHeight);
  }

  ~Impl() { close(); }

  int open(RgbCallback rgb_cb, IrCallback ir_cb, DepthCallback depth_cb) {
    close();
    rgb_cb_ = std::move(rgb_cb);
    ir_cb_ = std::move(ir_cb);
    depth_cb_ = std::move(depth_cb);
    device_dead_.store(false);

    int rc = libusb_init(&ctx_);
    if (rc < 0) return rc;

    libusb_device** devices = nullptr;
    const ssize_t count = libusb_get_device_list(ctx_, &devices);
    if (count < 0) {
      rc = static_cast<int>(count);
      close();
      return rc;
    }

    libusb_device* selected = nullptr;
    libusb_device_descriptor selected_desc{};
    for (ssize_t i = 0; i < count; ++i) {
      libusb_device_descriptor desc{};
      if (libusb_get_device_descriptor(devices[i], &desc) != 0) continue;
      if (desc.idVendor == kMicrosoftVid && (desc.idProduct == kNuiCameraPid || desc.idProduct == kK4wCameraPid)) {
        selected = devices[i];
        selected_desc = desc;
        break;
      }
    }

    if (selected == nullptr) {
      libusb_free_device_list(devices, 1);
      close();
      return LIBUSB_ERROR_NO_DEVICE;
    }

    rc = libusb_open(selected, &handle_);
    libusb_free_device_list(devices, 1);
    if (rc < 0 || handle_ == nullptr) {
      close();
      return rc < 0 ? rc : LIBUSB_ERROR_OTHER;
    }

    camera_pid_ = selected_desc.idProduct;
    zero_plane_reply_bytes_ = (selected_desc.idProduct == kK4wCameraPid || selected_desc.bcdDevice != 267) ? 334 : 322;
    (void)libusb_set_auto_detach_kernel_driver(handle_, 1);
    rc = libusb_claim_interface(handle_, kCameraInterface);
    if (rc < 0) {
      close();
      return rc;
    }
    claimed_ = true;

    if (camera_pid_ == kK4wCameraPid) {
      rc = libusb_set_interface_alt_setting(handle_, kCameraInterface, 1);
      if (rc < 0) {
        close();
        return rc;
      }
    }

    depth_calibrated_ = fetch_depth_calibration();
    online_.store(true);
    return 0;
  }

  void close() {
    if (handle_ != nullptr) {
      if (video_running_) (void)stop_video();
      if (depth_running_) (void)stop_depth();
      if (claimed_) (void)libusb_release_interface(handle_, kCameraInterface);
      libusb_close(handle_);
    }
    handle_ = nullptr;
    claimed_ = false;
    camera_pid_ = 0;
    camera_tag_ = 0;
    video_running_ = false;
    depth_running_ = false;
    depth_calibrated_ = false;
    online_.store(false);
    device_dead_.store(false);
    if (ctx_ != nullptr) libusb_exit(ctx_);
    ctx_ = nullptr;
  }

  int start_video(VideoMode mode) {
    if (handle_ == nullptr) return LIBUSB_ERROR_NO_DEVICE;
    if (video_running_) {
      if (video_mode_ == mode) return 0;
      const int rc = stop_video();
      if (rc < 0) return rc;
    }

    video_mode_ = mode;
    rgb_assembler_.reset();
    ir_assembler_.reset();
    const int iso_rc = start_iso(video_stream_, kVideoEndpoint, kIsoTransferPacketBytes,
                                  [this](const uint8_t* p, int n) {
                                    if (video_mode_ == VideoMode::Rgb) rgb_assembler_.process(p, n);
                                    else ir_assembler_.process(p, n);
                                  });
    if (iso_rc < 0) return iso_rc;

    int rc = write_register(0x05, 0x00);  // reset shared RGB/IR stream
    if (mode == VideoMode::Rgb) {
      if (rc >= 0) rc = write_register(0x0c, 0x00);
      if (rc >= 0) rc = write_register(0x0d, 0x01);
      if (rc >= 0) rc = write_register(0x0e, 0x1e);
      if (rc >= 0) rc = write_register(0x05, 0x01);
      if (rc >= 0) rc = write_register(0x47, 0x00);
    } else {
      if (rc >= 0) rc = write_register(0x19, 0x00);
      if (rc >= 0) rc = write_register(0x1a, 0x01);
      if (rc >= 0) rc = write_register(0x1b, 0x1e);
      if (rc >= 0) rc = write_register(0x105, 0x00);
      if (rc >= 0) rc = write_register(0x05, 0x03);
      if (rc >= 0) rc = write_register(0x48, 0x00);
    }

    if (rc < 0) {
      (void)write_register(0x05, 0x00);
      stop_iso(video_stream_);
      return rc;
    }
    video_running_ = true;
    return 0;
  }

  int stop_video() {
    if (!video_running_ && !video_stream_.started) return 0;
    int rc = 0;
    if (handle_ != nullptr) rc = write_register(0x05, 0x00);
    video_running_ = false;
    stop_iso(video_stream_);
    rgb_assembler_.reset();
    ir_assembler_.reset();
    return rc;
  }

  int start_depth() {
    if (handle_ == nullptr) return LIBUSB_ERROR_NO_DEVICE;
    if (depth_running_) return 0;
    depth_assembler_.reset();
    const int iso_rc = start_iso(depth_stream_, kDepthEndpoint, kIsoTransferPacketBytes,
                                  [this](const uint8_t* p, int n) { depth_assembler_.process(p, n); });
    if (iso_rc < 0) return iso_rc;

    int rc = write_register(0x105, 0x00);
    if (rc >= 0) rc = write_register(0x06, 0x00);
    if (rc >= 0) rc = write_register(0x12, 0x03);
    if (rc >= 0) rc = write_register(0x13, 0x01);
    if (rc >= 0) rc = write_register(0x14, 0x1e);
    if (rc >= 0) rc = write_register(0x06, 0x02);
    if (rc >= 0) rc = write_register(0x17, 0x00);
    if (rc < 0) {
      (void)write_register(0x06, 0x00);
      stop_iso(depth_stream_);
      return rc;
    }
    depth_running_ = true;
    return 0;
  }

  int stop_depth() {
    if (!depth_running_ && !depth_stream_.started) return 0;
    int rc = 0;
    if (handle_ != nullptr) rc = write_register(0x06, 0x00);
    depth_running_ = false;
    stop_iso(depth_stream_);
    depth_assembler_.reset();
    return rc;
  }

  int process_events(int timeout_ms) {
    if (ctx_ == nullptr || handle_ == nullptr) return LIBUSB_ERROR_NO_DEVICE;
    timeval timeout{};
    timeout.tv_sec = timeout_ms / 1000;
    timeout.tv_usec = (timeout_ms % 1000) * 1000;
    const int rc = libusb_handle_events_timeout(ctx_, &timeout);
    if (device_dead_.load()) return LIBUSB_ERROR_NO_DEVICE;
    return rc;
  }

  bool online() const { return online_.load() && !device_dead_.load(); }
  bool depth_calibrated() const { return depth_calibrated_; }

 private:
  struct IsoStream;
  struct IsoSlot {
    Impl* owner = nullptr;
    IsoStream* stream = nullptr;
    libusb_transfer* transfer = nullptr;
    std::vector<uint8_t> buffer;
    bool active = false;
  };

  struct IsoStream {
    uint8_t endpoint = 0;
    int packet_size = 0;
    bool started = false;
    bool stopping = false;
    int active_count = 0;
    std::function<void(const uint8_t*, int)> packet_cb;
    std::vector<std::unique_ptr<IsoSlot>> slots;
  };

  static void LIBUSB_CALL iso_callback(libusb_transfer* transfer) {
    auto* slot = static_cast<IsoSlot*>(transfer->user_data);
    if (slot == nullptr || slot->owner == nullptr || slot->stream == nullptr) return;
    slot->owner->handle_iso_callback(*slot, *slot->stream, transfer);
  }

  void handle_iso_callback(IsoSlot& slot, IsoStream& stream, libusb_transfer* transfer) {
    if (transfer->status == LIBUSB_TRANSFER_NO_DEVICE) device_dead_.store(true);

    if (transfer->status == LIBUSB_TRANSFER_COMPLETED) {
      for (int i = 0; i < transfer->num_iso_packets; ++i) {
        const libusb_iso_packet_descriptor& packet = transfer->iso_packet_desc[i];
        if (packet.status != LIBUSB_TRANSFER_COMPLETED || packet.actual_length == 0) continue;
        unsigned char* data = libusb_get_iso_packet_buffer_simple(transfer, static_cast<unsigned int>(i));
        if (data != nullptr && stream.packet_cb) stream.packet_cb(data, static_cast<int>(packet.actual_length));
      }
    }

    if (!stream.stopping && !device_dead_.load()) {
      const int rc = libusb_submit_transfer(transfer);
      if (rc == 0) return;
      // Any resubmission failure leaves this isoch slot inactive. Force the
      // outer hot-plug loop to reopen the device instead of silently losing
      // slots until the stream stalls.
      device_dead_.store(true);
    }

    if (slot.active) {
      slot.active = false;
      --stream.active_count;
    }
  }

  int start_iso(IsoStream& stream, uint8_t endpoint, int fallback_packet_size,
                std::function<void(const uint8_t*, int)> packet_cb) {
    if (stream.started || handle_ == nullptr) return stream.started ? LIBUSB_ERROR_BUSY : LIBUSB_ERROR_NO_DEVICE;
    stream.endpoint = endpoint;
    stream.packet_cb = std::move(packet_cb);
    stream.stopping = false;
    stream.active_count = 0;
    stream.slots.clear();

    const int negotiated = libusb_get_max_iso_packet_size(libusb_get_device(handle_), endpoint);
    int packet_size = fallback_packet_size;
    if (negotiated > packet_size) packet_size = negotiated;
    stream.packet_size = packet_size;
    stream.slots.reserve(kTransfers);

    for (int i = 0; i < kTransfers; ++i) {
      auto slot = std::make_unique<IsoSlot>();
      slot->owner = this;
      slot->stream = &stream;
      slot->buffer.resize(static_cast<std::size_t>(packet_size) * kPacketsPerTransfer);
      slot->transfer = libusb_alloc_transfer(kPacketsPerTransfer);
      if (slot->transfer == nullptr) {
        stop_iso(stream);
        return LIBUSB_ERROR_NO_MEM;
      }
      libusb_fill_iso_transfer(slot->transfer, handle_, endpoint, slot->buffer.data(),
                              static_cast<int>(slot->buffer.size()), kPacketsPerTransfer,
                              &Impl::iso_callback, slot.get(), 0);
      libusb_set_iso_packet_lengths(slot->transfer, static_cast<unsigned int>(packet_size));
      stream.slots.push_back(std::move(slot));
    }

    stream.started = true;
    for (auto& slot : stream.slots) {
      const int rc = libusb_submit_transfer(slot->transfer);
      if (rc < 0) {
        stop_iso(stream);
        return rc;
      }
      slot->active = true;
      ++stream.active_count;
    }
    return 0;
  }

  void stop_iso(IsoStream& stream) {
    if (!stream.started && stream.slots.empty()) return;
    stream.stopping = true;
    for (auto& slot : stream.slots) {
      if (!slot->active || slot->transfer == nullptr) continue;
      const int rc = libusb_cancel_transfer(slot->transfer);
      if (rc == LIBUSB_ERROR_NOT_FOUND && slot->active) {
        // libusb guarantees NOT_FOUND means this transfer is not in progress.
        slot->active = false;
        --stream.active_count;
      }
    }

    while (ctx_ != nullptr && stream.active_count > 0) {
      timeval timeout{0, 20000};
      const int rc = libusb_handle_events_timeout(ctx_, &timeout);
      if (rc < 0 && rc != LIBUSB_ERROR_INTERRUPTED) break;
    }

    for (auto& slot : stream.slots) {
      if (slot->transfer != nullptr && !slot->active) libusb_free_transfer(slot->transfer);
      slot->transfer = nullptr;
    }
    stream.slots.clear();
    stream.packet_cb = {};
    stream.started = false;
    stream.stopping = false;
    stream.active_count = 0;
  }

  int send_command(uint16_t command, const uint8_t* payload, std::size_t payload_bytes,
                   uint8_t* reply, std::size_t reply_capacity) {
    if (handle_ == nullptr) return LIBUSB_ERROR_NO_DEVICE;
    if ((payload_bytes & 1u) != 0 || payload_bytes > 0x3f8u) return LIBUSB_ERROR_INVALID_PARAM;

    std::array<uint8_t, 0x400> output{};
    output[0] = 0x47;
    output[1] = 0x4d;
    put_le16(output.data() + 2, static_cast<uint16_t>(payload_bytes / 2u));
    put_le16(output.data() + 4, command);
    put_le16(output.data() + 6, camera_tag_);
    if (payload_bytes != 0) std::memcpy(output.data() + 8, payload, payload_bytes);

    int rc = libusb_control_transfer(handle_, 0x40, 0, 0, 0, output.data(),
                                     static_cast<uint16_t>(payload_bytes + 8u), 1000);
    if (rc < 0) return rc;

    std::array<uint8_t, 0x200> input{};
    int actual = 0;
    for (int attempt = 0; attempt < 2000; ++attempt) {
      actual = libusb_control_transfer(handle_, 0xc0, 0, 0, 0, input.data(),
                                       static_cast<uint16_t>(input.size()), 1000);
      if (actual < 0) return actual;
      if (actual != 0) break;
      std::this_thread::sleep_for(std::chrono::microseconds(50));
    }
    if (actual == 0) return LIBUSB_ERROR_TIMEOUT;
    if (actual < 8) return LIBUSB_ERROR_IO;
    if (input[0] != 0x52 || input[1] != 0x42) return LIBUSB_ERROR_IO;
    if (get_le16(input.data() + 4) != command || get_le16(input.data() + 6) != camera_tag_) return LIBUSB_ERROR_IO;

    const int reply_bytes = actual - 8;
    if (get_le16(input.data() + 2) != static_cast<uint16_t>(reply_bytes / 2)) return LIBUSB_ERROR_IO;
    if (reply != nullptr && reply_capacity != 0) {
      std::memcpy(reply, input.data() + 8, std::min(reply_capacity, static_cast<std::size_t>(reply_bytes)));
    }
    ++camera_tag_;
    return reply_bytes;
  }

  int write_register(uint16_t reg, uint16_t value) {
    std::array<uint8_t, 4> command{};
    put_le16(command.data(), reg);
    put_le16(command.data() + 2, value);
    std::array<uint8_t, 4> reply{};
    const int rc = send_command(0x03, command.data(), command.size(), reply.data(), reply.size());
    return rc < 0 ? rc : 0;
  }

  bool fetch_depth_calibration() {
    depth_calibrated_ = false;
    std::array<uint8_t, 10> fixed_command{};
    std::array<uint8_t, 0x200> fixed_reply{};
    int rc = send_command(0x04, fixed_command.data(), fixed_command.size(), fixed_reply.data(), fixed_reply.size());
    if (rc != zero_plane_reply_bytes_ || rc < 110) return false;

    ZeroPlane zero{};
    zero.dcmos_emitter_dist = get_le_float(fixed_reply.data() + 94);
    zero.dcmos_rcmos_dist = get_le_float(fixed_reply.data() + 98);
    zero.reference_distance = get_le_float(fixed_reply.data() + 102);
    zero.reference_pixel_size = get_le_float(fixed_reply.data() + 106);
    if (!std::isfinite(zero.dcmos_emitter_dist) || !std::isfinite(zero.reference_distance) ||
        !std::isfinite(zero.reference_pixel_size) || zero.dcmos_emitter_dist <= 0.0f ||
        zero.reference_distance <= 0.0f || zero.reference_pixel_size <= 0.0f) return false;

    std::array<uint8_t, 10> shift_command{};
    put_le16(shift_command.data() + 0, 0x00);
    put_le16(shift_command.data() + 2, 0x00);
    put_le16(shift_command.data() + 4, 0x01);  // medium / VGA
    put_le16(shift_command.data() + 6, 0x1e);  // 30 fps
    put_le16(shift_command.data() + 8, 0x00);
    std::array<uint8_t, 4> shift_reply{};
    rc = send_command(0x16, shift_command.data(), shift_command.size(), shift_reply.data(), shift_reply.size());
    if (rc != 4) return false;

    zero_plane_ = zero;
    const_shift_ = static_cast<double>(get_le16(shift_reply.data() + 2));
    build_depth_table();
    return true;
  }

  void build_depth_table() {
    for (std::size_t raw = 0; raw < depth_to_mm_.size(); ++raw) {
      if (raw == kDepthRawNoValue) {
        depth_to_mm_[raw] = 0;
        continue;
      }
      const double fixed_ref_x = ((static_cast<double>(raw) - 4.0 * const_shift_) / 4.0) - kS2dConstOffset;
      const double metric = fixed_ref_x * static_cast<double>(zero_plane_.reference_pixel_size);
      const double denominator = static_cast<double>(zero_plane_.dcmos_emitter_dist) - metric;
      if (std::abs(denominator) < 1e-9) {
        depth_to_mm_[raw] = kDepthMmMaxValue;
        continue;
      }
      const double mm = 10.0 * ((metric * static_cast<double>(zero_plane_.reference_distance) / denominator) +
                                static_cast<double>(zero_plane_.reference_distance));
      if (!std::isfinite(mm) || mm <= 0.0 || mm >= static_cast<double>(kDepthMmMaxValue)) {
        depth_to_mm_[raw] = kDepthMmMaxValue;
      } else {
        depth_to_mm_[raw] = static_cast<uint16_t>(mm);
      }
    }
    depth_to_mm_[kDepthRawNoValue] = 0;
  }

  void on_video_frame(const uint8_t* frame, std::size_t bytes, uint32_t timestamp) {
    if (video_mode_ == VideoMode::Rgb) {
      if (bytes != kRgbRawBytes) return;
      bayer_to_rgb(frame, rgb_buffer_.data());
      if (rgb_cb_) rgb_cb_(rgb_buffer_.data(), rgb_buffer_.size(), timestamp);
    } else {
      if (bytes != kIrRawBytes) return;
      unpack_10bit(frame, ir_buffer_.data(), ir_buffer_.size());
      if (ir_cb_) ir_cb_(ir_buffer_.data(), kWidth * kHeight, timestamp);
    }
  }

  void on_depth_frame(const uint8_t* frame, std::size_t bytes, uint32_t timestamp) {
    if (bytes != kDepthRawBytes) return;
    unpack_11bit(frame, depth_raw_buffer_.data(), depth_raw_buffer_.size());
    if (depth_calibrated_) {
      for (std::size_t i = 0; i < depth_raw_buffer_.size(); ++i) {
        const uint16_t raw = depth_raw_buffer_[i];
        depth_mm_buffer_[i] = raw < depth_to_mm_.size() ? depth_to_mm_[raw] : 0;
      }
    } else {
      // Preserve the stream even if factory calibration cannot be read. Raw values
      // are deliberately not mislabeled as millimeters: 0 marks depth unavailable.
      std::fill(depth_mm_buffer_.begin(), depth_mm_buffer_.end(), 0);
    }
    if (depth_cb_) depth_cb_(depth_mm_buffer_.data(), depth_mm_buffer_.size(), timestamp, depth_calibrated_);
  }

  struct ZeroPlane {
    float dcmos_emitter_dist = 0.0f;
    float dcmos_rcmos_dist = 0.0f;
    float reference_distance = 0.0f;
    float reference_pixel_size = 0.0f;
  };

  libusb_context* ctx_ = nullptr;
  libusb_device_handle* handle_ = nullptr;
  bool claimed_ = false;
  uint16_t camera_pid_ = 0;
  uint16_t camera_tag_ = 0;
  int zero_plane_reply_bytes_ = 322;
  std::atomic<bool> online_{false};
  std::atomic<bool> device_dead_{false};
  bool video_running_ = false;
  bool depth_running_ = false;
  VideoMode video_mode_ = VideoMode::Rgb;
  bool depth_calibrated_ = false;
  ZeroPlane zero_plane_{};
  double const_shift_ = 0.0;
  std::array<uint16_t, 2048> depth_to_mm_{};
  IsoStream video_stream_{};
  IsoStream depth_stream_{};
  FrameAssembler rgb_assembler_;
  FrameAssembler ir_assembler_;
  FrameAssembler depth_assembler_;
  std::vector<uint8_t> rgb_buffer_;
  std::vector<uint16_t> ir_buffer_;
  std::vector<uint16_t> depth_raw_buffer_;
  std::vector<uint16_t> depth_mm_buffer_;
  RgbCallback rgb_cb_;
  IrCallback ir_cb_;
  DepthCallback depth_cb_;
};

Camera::Camera() : impl_(std::make_unique<Impl>()) {}
Camera::~Camera() = default;
int Camera::open(RgbCallback rgb_cb, IrCallback ir_cb, DepthCallback depth_cb) {
  return impl_->open(std::move(rgb_cb), std::move(ir_cb), std::move(depth_cb));
}
void Camera::close() { impl_->close(); }
int Camera::start_video(VideoMode mode) { return impl_->start_video(mode); }
int Camera::stop_video() { return impl_->stop_video(); }
int Camera::start_depth() { return impl_->start_depth(); }
int Camera::stop_depth() { return impl_->stop_depth(); }
int Camera::process_events(int timeout_ms) { return impl_->process_events(timeout_ms); }
bool Camera::online() const { return impl_->online(); }
bool Camera::depth_calibrated() const { return impl_->depth_calibrated(); }

}  // namespace remold::kinectusb
