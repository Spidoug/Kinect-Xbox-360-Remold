#pragma once
#include <cstdint>

namespace Kinect360RemoldControl {
constexpr wchar_t kPipeName[] = L"\\\\.\\pipe\\Kinect360RemoldControl";
constexpr uint32_t kMagic = 0x54434D52u; // "RMCT"
constexpr uint32_t kVersion = 1;

enum class Command : uint32_t {
    Ping = 0,
    Status = 1,
    Tilt = 2,
    Led = 3,
    CameraActivity = 4,
};

enum class CameraActivitySource : int32_t {
    VirtualCamera = 1,
    Scanner3D = 2,
    IpCamera = 3,
};

enum class Transport : uint32_t {
    None = 0,
    PhysicalMotor = 1,
};

enum class LedMode : int32_t {
    Off = 0,
    Green = 1,
    Red = 2,
    Yellow = 3,
    BlinkGreen = 4,
    BlinkYellowRed = 6,
};

#pragma pack(push, 1)
struct Request {
    uint32_t magic = kMagic;
    uint32_t version = kVersion;
    Command command = Command::Ping;
    int32_t value = 0;
};

struct Reply {
    uint32_t magic = kMagic;
    uint32_t version = kVersion;
    int32_t result = 0; // HRESULT
    Transport transport = Transport::None;
    int32_t accelX = 0;
    int32_t accelY = 0;
    int32_t accelZ = 0;
    int32_t tiltTenths = 0;
    uint32_t state = 0;
    uint32_t cameraActivityMask = 0; // bit0: virtual camera; bit1: Scanner3D; bit2: authenticated IP camera client
};
#pragma pack(pop)

static_assert(sizeof(Request) == 16, "Control request ABI");
static_assert(sizeof(Reply) == 40, "Control reply ABI");
} // namespace Kinect360RemoldControl
