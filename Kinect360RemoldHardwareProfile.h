#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <cstddef>
#include <cstdint>

// Physical Kinect Xbox 360 USB profile used by every Remold user-mode transport.
// The 1414 and 1473 do NOT expose the motor/control path the same way:
//   1414: 045E:02B0 is the classic motor function and may be bound to WinUSB.
//   1473: 045E:02C2 is the parent USB hub/controller and must remain on the
//         Microsoft inbox hub driver. Motor/LED/accelerometer commands move to
//         045E:02BB/02C3&MI_00 after UAC firmware 01.02.709.00 has launched.
namespace Kinect360RemoldHardware {

inline constexpr uint16_t kVendorId = 0x045E;
inline constexpr uint16_t kMotorProductIds[] = {0x02B0};
inline constexpr uint16_t kControllerHubProductIds[] = {0x02C2};
inline constexpr uint16_t kCameraProductIds[] = {0x02AE};
inline constexpr uint16_t kAudioProductIds[] = {0x02AD};

inline constexpr uint16_t kMotorProductId = kMotorProductIds[0];
inline constexpr uint16_t kControllerHubProductId = kControllerHubProductIds[0];
inline constexpr uint16_t kCameraProductId = kCameraProductIds[0];
inline constexpr uint16_t kAudioProductId = kAudioProductIds[0];
// Microsoft UACFirmware 01.02.709.00 is shared by the supported Xbox 360
// hardware generations. Xbox sensors normally expose the 02BB composite; the
// Microsoft Kinect 1.8 driver family also recognizes 02C3. Runtime discovery
// therefore accepts both while keeping 02BB as the canonical Xbox alias.
inline constexpr uint16_t kAudioRuntimeProductIds[] = {0x02BB, 0x02C3};
inline constexpr uint16_t kAudioRuntimeProductId = kAudioRuntimeProductIds[0];
inline constexpr const wchar_t* kAudioRuntimeHardwareIds[] = {
    L"USB\\VID_045E&PID_02BB", L"USB\\VID_045E&PID_02C3"};
inline constexpr const wchar_t* kAudioRuntimeControlHardwareIds[] = {
    L"USB\\VID_045E&PID_02BB&MI_00", L"USB\\VID_045E&PID_02C3&MI_00"};
inline constexpr const wchar_t* kAudioRuntimeSecurityHardwareIds[] = {
    L"USB\\VID_045E&PID_02BB&MI_01", L"USB\\VID_045E&PID_02C3&MI_01"};
inline constexpr const wchar_t* kAudioRuntimeCaptureHardwareIds[] = {
    L"USB\\VID_045E&PID_02BB&MI_02", L"USB\\VID_045E&PID_02C3&MI_02"};
inline constexpr wchar_t kAudioRuntimeHardwareId[] = L"USB\\VID_045E&PID_02BB";
inline constexpr wchar_t kAudioRuntimeControlHardwareId[] = L"USB\\VID_045E&PID_02BB&MI_00";
inline constexpr wchar_t kAudioRuntimeSecurityHardwareId[] = L"USB\\VID_045E&PID_02BB&MI_01";
inline constexpr wchar_t kAudioRuntimeCaptureHardwareId[] = L"USB\\VID_045E&PID_02BB&MI_02";

// Classic 1414 motor transport.
inline constexpr GUID kNuiTransportGuid =
    {0x71d72413,0xe133,0x42b4,{0xa5,0xce,0x66,0xf4,0xd2,0xe3,0x8d,0xfa}};
// 1473/K4W motor-control path exposed by UAC runtime interface 0 after firmware.
// Use the interface GUID from Microsoft's Kinect Audio Array Control WinUSB
// package. This lets the broker open MI_00 whether Windows selected the
// Microsoft Kinect package or the Remold fallback package.
inline constexpr GUID kAudioControlTransportGuid =
    {0xf9dbe212,0xf689,0x4fdf,{0xa7,0x5d,0x53,0x2e,0x95,0x1f,0xbd,0x0a}};
inline constexpr GUID kCameraTransportGuid =
    {0xe05f50e4,0x0674,0x4ecf,{0x9d,0x63,0x15,0x40,0x1b,0x83,0x7e,0x9b}};
// 02AD boot transport only. Keep this separate from UAC MI_00 so AudioBridge
// never mistakes the runtime control interface for a firmware-boot device.
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

namespace AudioControl {
inline constexpr UCHAR kOutEndpoint = 0x01;
inline constexpr UCHAR kInEndpoint = 0x81;
inline constexpr uint32_t kCommandMagic = 0x06022009u;
inline constexpr uint32_t kReplyMagic = 0x0A6FE000u;
inline constexpr uint32_t kStatusCommand = 0x8032u;
inline constexpr uint32_t kTiltCommand = 0x803Bu;
inline constexpr uint32_t kLedCommand = 0x10u;
inline constexpr uint32_t kStatusReplyBytes = 0x68u;
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
