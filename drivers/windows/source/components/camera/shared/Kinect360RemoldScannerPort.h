#pragma once
#include <cstdint>

namespace Kinect360RemoldScannerPort {
// Private local scanner transport. V1 exposes one pipe per physical Kinect.
// Full endpoint: \\.\pipe\Kinect360RemoldScanner-<stable-device-id>.
constexpr wchar_t kPipePrefix[] = L"\\\\.\\pipe\\Kinect360RemoldScanner-";
constexpr uint32_t kMagic = 0x43534D52u;      // "RMSC" little-endian
constexpr uint32_t kFrameMagic = 0x46534D52u; // "RMSF" little-endian
constexpr uint32_t kVersion = 1;
constexpr uint32_t kWidth = 640;
constexpr uint32_t kHeight = 480;
constexpr uint32_t kRgbHqWidth = 1280;
constexpr uint32_t kRgbHqHeight = 1024;
constexpr uint32_t kIrRawHeight = 488;

enum class Command : uint32_t {
    SubscribeStreams = 1,
};

enum class StreamMode : int32_t {
    Rgb = 0,
    Infrared = 1,
    Depth = 2,
    RgbHighQuality = 3,
};

enum StreamMask : uint32_t {
    StreamRgb = 0x00000001u,
    StreamInfrared = 0x00000002u,
    StreamDepth = 0x00000004u,
    StreamRgbHighQuality = 0x00000008u,
    StreamSupported = StreamRgb | StreamInfrared | StreamDepth | StreamRgbHighQuality,
};

enum Capability : uint32_t {
    CapabilityRgbDepthConcurrent = 0x00000001u,
    CapabilityExclusiveVideoMode = 0x00000002u,
    CapabilityProjectorRefCounted = 0x00000004u,
    CapabilityAccelerometer = 0x00000008u,
    CapabilityRgbHighQuality = 0x00000010u,
    CapabilityRawSensorFrames = 0x00000040u,
    CapabilityPersistentIsoSession = 0x00000080u,
};

// V1 ScannerPort is sensor-native only. Any consumer that needs display or
// metric data performs conversion after transport, never inside the USB owner.
enum class PixelFormat : uint32_t {
    BayerGrbg8 = 4,       // sensor-native GRBG8, 640x480 or 1280x1024
    IrRaw10Packed = 5,    // sensor-native 640x488 packed 10-bit
    DepthRaw11Packed = 6, // sensor-native 640x480 packed 11-bit shift codes
};

constexpr uint32_t kRgbRawPayloadBytes = kWidth * kHeight;
constexpr uint32_t kIrRaw10PayloadBytes = kWidth * kIrRawHeight * 10u / 8u;
constexpr uint32_t kDepthRaw11PackedPayloadBytes = kWidth * kHeight * 11u / 8u;
constexpr uint32_t kRgbHqPayloadBytes = kRgbHqWidth * kRgbHqHeight;
constexpr uint32_t kMaxPayloadBytes = kRgbHqPayloadBytes;
constexpr uint32_t kFlagFrameRecovered = 0x00000001u; // one or more USB packet slots were reconstructed as invalid data

enum MotionFlag : uint32_t {
    MotionAccelerometerValid = 0x00000001u,
    MotionTiltValid = 0x00000002u,
};

constexpr uint32_t MaskFor(StreamMode mode) noexcept {
    return mode == StreamMode::Rgb ? StreamRgb :
           mode == StreamMode::Infrared ? StreamInfrared :
           mode == StreamMode::Depth ? StreamDepth :
           mode == StreamMode::RgbHighQuality ? StreamRgbHighQuality : 0u;
}

constexpr bool IsValidStreamMask(uint32_t mask) noexcept {
    if (mask == 0 || (mask & ~StreamSupported) != 0) return false;
    // Endpoint 0x81 is one physical video engine. IR is exclusive with either RGB mode.
    const bool wantsIr = (mask & StreamInfrared) != 0;
    const bool wantsColor = (mask & (StreamRgb | StreamRgbHighQuality)) != 0;
    return !(wantsIr && wantsColor);
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
                            CapabilityProjectorRefCounted | CapabilityAccelerometer | CapabilityRgbHighQuality | CapabilityRawSensorFrames | CapabilityPersistentIsoSession;
    uint32_t maxPayloadBytes = kMaxPayloadBytes;
    uint32_t depthCalibrationValid = 0;
    double depthConstShift = 0.0;
    double depthEmitterDistance = 0.0;
    double depthReferenceDistance = 0.0;
    double depthReferencePixelSize = 0.0;
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
    PixelFormat pixelFormat = PixelFormat::DepthRaw11Packed;
    uint32_t payloadBytes = kDepthRaw11PackedPayloadBytes;
    uint32_t flags = 0;
    uint64_t frameNumber = 0;
    uint64_t tickMs = 0;
    MotionSample motion{};
};
#pragma pack(pop)

static_assert(sizeof(Request) == 16, "Scanner request ABI");
static_assert(sizeof(Reply) == 68, "Scanner reply ABI");
static_assert(sizeof(MotionSample) == 28, "Scanner motion ABI");
static_assert(sizeof(FrameHeader) == 76, "Scanner frame ABI");
}
