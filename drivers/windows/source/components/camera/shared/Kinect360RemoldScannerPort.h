#pragma once
#include <cstdint>

namespace Kinect360RemoldScannerPort {
// Private local scanner transport. Source spelling is escaped C++; runtime name is \\.\pipe\Kinect360RemoldScanner.
constexpr wchar_t kPipeName[] = L"\\\\.\\pipe\\Kinect360RemoldScanner";
constexpr uint32_t kMagic = 0x43534D52u;      // "RMSC" little-endian
constexpr uint32_t kFrameMagic = 0x46534D52u; // "RMSF" little-endian
constexpr uint32_t kVersion = 1;
constexpr uint32_t kWidth = 640;
constexpr uint32_t kHeight = 480;

enum class Command : uint32_t {
    SubscribeStreams = 1,
};

enum class StreamMode : int32_t {
    Rgb = 0,
    Infrared = 1,
    Depth = 2,
};

enum StreamMask : uint32_t {
    StreamRgb = 0x00000001u,
    StreamInfrared = 0x00000002u,
    StreamDepth = 0x00000004u,
    StreamSupported = StreamRgb | StreamInfrared | StreamDepth,
};

enum Capability : uint32_t {
    CapabilityRgbDepthConcurrent = 0x00000001u,
    CapabilityExclusiveVideoMode = 0x00000002u,
    CapabilityProjectorRefCounted = 0x00000004u,
    CapabilityAccelerometer = 0x00000008u,
};

enum class PixelFormat : uint32_t {
    Nv12 = 1,       // RGB camera image encoded as NV12, 640x480
    Gray16 = 2,     // IR intensity, unsigned little-endian 10-bit values in uint16
    DepthMm16 = 3,  // metric depth, unsigned little-endian millimetres; 0 = invalid
};

constexpr uint32_t kNv12PayloadBytes = kWidth * kHeight * 3u / 2u;
constexpr uint32_t kGray16PayloadBytes = kWidth * kHeight * sizeof(uint16_t);
constexpr uint32_t kDepthPayloadBytes = kWidth * kHeight * sizeof(uint16_t);
constexpr uint32_t kMaxPayloadBytes = kDepthPayloadBytes;
constexpr uint32_t kFlagDeviceCalibrated = 0x00000001u;
constexpr uint32_t kFlagFrameRecovered = 0x00000002u; // one or more USB packet slots were reconstructed as invalid data

enum MotionFlag : uint32_t {
    MotionAccelerometerValid = 0x00000001u,
    MotionTiltValid = 0x00000002u,
};

constexpr uint32_t MaskFor(StreamMode mode) noexcept {
    return mode == StreamMode::Rgb ? StreamRgb :
           mode == StreamMode::Infrared ? StreamInfrared :
           mode == StreamMode::Depth ? StreamDepth : 0u;
}

constexpr bool IsValidStreamMask(uint32_t mask) noexcept {
    if (mask == 0 || (mask & ~StreamSupported) != 0) return false;
    // Endpoint 0x81 is one physical video engine. RGB and IR are mutually exclusive.
    return (mask & (StreamRgb | StreamInfrared)) != (StreamRgb | StreamInfrared);
}

#pragma pack(push, 1)
struct Request {
    uint32_t magic = kMagic;
    uint32_t version = kVersion;
    Command command = Command::SubscribeStreams;
    uint32_t streamMask = StreamDepth;
};

struct Reply {
    uint32_t magic = kMagic;
    uint32_t version = kVersion;
    int32_t result = 0;
    uint32_t acceptedMask = 0;
    uint32_t width = kWidth;
    uint32_t height = kHeight;
    uint32_t capabilities = CapabilityRgbDepthConcurrent | CapabilityExclusiveVideoMode |
                            CapabilityProjectorRefCounted | CapabilityAccelerometer;
    uint32_t maxPayloadBytes = kMaxPayloadBytes;
};

struct MotionSample {
    uint32_t flags = 0;
    int32_t accelX = 0;
    int32_t accelY = 0;
    int32_t accelZ = 0;
    int32_t tiltTenths = 0;
    uint64_t tickMs = 0;
};

struct FrameHeader {
    uint32_t magic = kFrameMagic;
    uint32_t version = kVersion;
    StreamMode mode = StreamMode::Depth;
    uint32_t width = kWidth;
    uint32_t height = kHeight;
    PixelFormat pixelFormat = PixelFormat::DepthMm16;
    uint32_t payloadBytes = kDepthPayloadBytes;
    uint32_t flags = 0;
    uint64_t frameNumber = 0;
    uint64_t tickMs = 0;
    MotionSample motion{};
};
#pragma pack(pop)

static_assert(sizeof(Request) == 16, "Scanner request ABI");
static_assert(sizeof(Reply) == 32, "Scanner reply ABI");
static_assert(sizeof(MotionSample) == 28, "Scanner motion ABI");
static_assert(sizeof(FrameHeader) == 76, "Scanner frame ABI");
}
