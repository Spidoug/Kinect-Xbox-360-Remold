#pragma once
#include <cstdint>

namespace remold {
inline constexpr const char* kRuntimeDir = "/run/kinect360-remold";
inline constexpr const char* kControlSocket = "/run/kinect360-remold/control.sock";
inline constexpr const char* kDeviceManifest = "/run/kinect360-remold/devices.tsv";
inline constexpr const char* kAudioSocket = "/run/kinect360-remold/audio.sock";
inline constexpr const char* kAudioStatus = "/run/kinect360-remold/audio-bridge-status.txt";
inline constexpr const char* kConfigPath = "/etc/kinect360-remold/remold.conf";
inline constexpr const char* kFirmwarePath = "/usr/share/kinect360-remold/UACFirmware";

namespace control {
inline constexpr uint32_t kMagic = 0x54434D52u;
// Same model-neutral logical control ABI as the Windows broker.
inline constexpr uint32_t kVersion = 1;
enum class Command : uint32_t { Ping=0, Status=1, Tilt=2, Led=3, PrepareCamera=4 };
enum class Transport : uint32_t { None=0, PhysicalMotor=1 };
enum class LedMode : int32_t { Off=0, Green=1, Red=2, Yellow=3, BlinkGreen=4, BlinkYellowRed=6 };
#pragma pack(push,1)
struct Request { uint32_t magic=kMagic, version=kVersion; Command command=Command::Ping; int32_t value=0; };
struct Reply {
  uint32_t magic=kMagic, version=kVersion; int32_t result=0; Transport transport=Transport::None;
  int32_t accelX=0, accelY=0, accelZ=0, tiltTenths=0; uint32_t state=0;
};
#pragma pack(pop)
static_assert(sizeof(Request)==16); static_assert(sizeof(Reply)==36);
}

namespace scanner {
inline constexpr uint32_t kMagic=0x43534D52u, kFrameMagic=0x46534D52u, kVersion=1, kWidth=640, kHeight=480;
inline constexpr uint32_t kRgbHqWidth=1280, kRgbHqHeight=1024, kIrRawHeight=488;
enum class Command:uint32_t { SubscribeStreams=1 };
enum class StreamMode:int32_t { Rgb=0, Infrared=1, Depth=2, RgbHighQuality=3 };
enum StreamMask:uint32_t { StreamRgb=1, StreamInfrared=2, StreamDepth=4, StreamRgbHighQuality=8, StreamSupported=15 };
enum Capability:uint32_t { CapabilityRgbDepthConcurrent=1, CapabilityExclusiveVideoMode=2, CapabilityProjectorRefCounted=4, CapabilityAccelerometer=8, CapabilityRgbHighQuality=16, CapabilityRawSensorFrames=64 };
enum class PixelFormat:uint32_t { BayerGrbg8=4, IrRaw10Packed=5, DepthRaw11Packed=6 };
inline constexpr uint32_t kRgbRawPayloadBytes=kWidth*kHeight, kIrRaw10PayloadBytes=kWidth*kIrRawHeight*10u/8u,
  kDepthRaw11PackedPayloadBytes=kWidth*kHeight*11u/8u, kRgbHqPayloadBytes=kRgbHqWidth*kRgbHqHeight,
  kMaxPayloadBytes=kRgbHqPayloadBytes;
inline constexpr uint32_t kFlagFrameRecovered=1;
#pragma pack(push,1)
struct Request { uint32_t magic=kMagic, version=kVersion; Command command=Command::SubscribeStreams; uint32_t streamMask=StreamDepth; };
struct Reply { uint32_t magic=kMagic, version=kVersion; int32_t result=0; uint32_t acceptedMask=0, width=kWidth, height=kHeight,
  capabilities=CapabilityRgbDepthConcurrent|CapabilityExclusiveVideoMode|CapabilityProjectorRefCounted|CapabilityRgbHighQuality|CapabilityRawSensorFrames, maxPayloadBytes=kMaxPayloadBytes;
  uint32_t depthCalibrationValid=0; double depthConstShift=0.0, depthEmitterDistance=0.0, depthReferenceDistance=0.0, depthReferencePixelSize=0.0; };
struct MotionSample { uint32_t flags=0; int32_t accelX=0,accelY=0,accelZ=0,tiltTenths=0; uint64_t tickMs=0; };
struct FrameHeader { uint32_t magic=kFrameMagic,version=kVersion; StreamMode mode=StreamMode::Depth; uint32_t width=kWidth,height=kHeight;
  PixelFormat pixelFormat=PixelFormat::DepthRaw11Packed; uint32_t payloadBytes=kDepthRaw11PackedPayloadBytes,flags=0; uint64_t frameNumber=0,tickMs=0; MotionSample motion{}; };
#pragma pack(pop)
static_assert(sizeof(Request)==16); static_assert(sizeof(Reply)==68); static_assert(sizeof(MotionSample)==28); static_assert(sizeof(FrameHeader)==76);
inline bool valid_mask(uint32_t m){
  if(!m || (m&~StreamSupported)) return false;
  const bool wants_ir=(m&StreamInfrared)!=0;
  const bool wants_color=(m&(StreamRgb|StreamRgbHighQuality))!=0;
  return !(wants_ir&&wants_color);
}
}

namespace audio {
inline constexpr uint32_t kMagic=0x414D4D52u,kFrameMagic=0x464D4D52u,kVersion=1,kSampleRate=16000,kChannels=4,kSamples=256,kBytesPerSample=4,kPayloadBytes=kChannels*kSamples*kBytesPerSample;
enum class Command:uint32_t { SubscribeMicrophones=1 };
enum class SampleFormat:uint32_t { PcmS32Le=1 };
enum Capability:uint32_t { CapabilityPhysicalMicrophoneArray=1, CapabilityChannelValidityMask=2 };
#pragma pack(push,1)
struct Request { uint32_t magic=kMagic,version=kVersion; Command command=Command::SubscribeMicrophones; uint32_t reserved=0; };
struct Reply { uint32_t magic=kMagic,version=kVersion; int32_t result=0; uint32_t sampleRate=kSampleRate,channels=kChannels; SampleFormat sampleFormat=SampleFormat::PcmS32Le;
  uint32_t maxPayloadBytes=kPayloadBytes,capabilities=CapabilityPhysicalMicrophoneArray|CapabilityChannelValidityMask; };
struct FrameHeader { uint32_t magic=kFrameMagic,version=kVersion,sampleRate=kSampleRate,channels=kChannels; SampleFormat sampleFormat=SampleFormat::PcmS32Le;
  uint32_t samplesPerChannel=kSamples,payloadBytes=kPayloadBytes,channelMask=0; uint64_t frameNumber=0,tickMs=0; };
#pragma pack(pop)
static_assert(sizeof(Request)==16); static_assert(sizeof(Reply)==32); static_assert(sizeof(FrameHeader)==48);
}
}
