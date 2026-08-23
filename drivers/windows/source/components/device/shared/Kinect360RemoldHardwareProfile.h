#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <cstddef>
#include <cstdint>

// Physical Kinect Xbox 360 USB profile used by every Remold user-mode transport.
// Keep VID/PID, interface GUIDs, endpoints and transfer geometry here so the
// audio, camera, motor/broker and diagnostics cannot silently drift apart.
namespace Kinect360RemoldHardware {

inline constexpr uint16_t kVendorId = 0x045E;
inline constexpr uint16_t kMotorProductId = 0x02B0;
inline constexpr uint16_t kCameraProductId = 0x02AE;
inline constexpr uint16_t kAudioProductId = 0x02AD;

inline constexpr GUID kNuiTransportGuid =
    {0x71d72413,0xe133,0x42b4,{0xa5,0xce,0x66,0xf4,0xd2,0xe3,0x8d,0xfa}};
inline constexpr GUID kCameraTransportGuid =
    {0xe05f50e4,0x0674,0x4ecf,{0x9d,0x63,0x15,0x40,0x1b,0x83,0x7e,0x9b}};
inline constexpr GUID kAudioTransportGuid =
    {0x67965f38,0x6818,0x4a56,{0xb5,0x3e,0x8d,0xf9,0x2f,0x2e,0xeb,0xde}};

namespace Audio {
inline constexpr UCHAR kBootOutEndpoint = 0x01;
inline constexpr UCHAR kBootInEndpoint = 0x81;
inline constexpr uint32_t kBootCommandMagic = 0x06022009u;
inline constexpr uint32_t kBootStatusMagic = 0x0A6FE000u;
inline constexpr uint32_t kBootWriteCommand = 0x03u;
inline constexpr uint32_t kBootLaunchCommand = 0x04u;
inline constexpr uint32_t kFirmwarePageBytes = 16u * 1024u;
inline constexpr uint32_t kFirmwareChunkBytes = 512u;
inline constexpr size_t kPortQueueFrames = 32;
}

namespace Camera {
inline constexpr UCHAR kVideoInEndpoint = 0x81;
inline constexpr UCHAR kDepthInEndpoint = 0x82;
inline constexpr ULONG kIrRawHeight = 488;
inline constexpr ULONG kIrPackedBitsPerPixel = 10;
inline constexpr ULONG kDepthPackedBitsPerPixel = 11;
inline constexpr size_t kRawDepthCodeCount = size_t{1} << kDepthPackedBitsPerPixel;
inline constexpr uint16_t kRawDepthInvalidCode = static_cast<uint16_t>(kRawDepthCodeCount - 1u);
inline constexpr ULONG kIsoPacketsPerTransfer = 32;
inline constexpr size_t kIsoQueueDepth = 16;
inline constexpr ULONG kVideoPacketBytes = 1920;
inline constexpr ULONG kDepthPacketBytes = 1760;
inline constexpr DWORD kIsoWaitMs = 1000;
inline constexpr int kMaxIsoTimeouts = 3;
}

} // namespace Kinect360RemoldHardware
