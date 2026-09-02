#pragma once
#include <cstdint>

namespace Kinect360RemoldAudioPort {
// V1 raw four-microphone transport. Processing connects directly to this local
// pipe. The standard Remold package does not install a custom Windows audio kernel endpoint.
constexpr wchar_t kPipeName[] = L"\\\\.\\pipe\\Kinect360RemoldAudio";
constexpr wchar_t kDiagnosticsDirectory[] = L"Kinect360Remold";
constexpr wchar_t kDiagnosticsFileName[] = L"audio-bridge-status.txt";
constexpr uint32_t kMagic = 0x414D4D52u;      // "RMMA" little-endian
constexpr uint32_t kFrameMagic = 0x464D4D52u; // "RMMF" little-endian
constexpr uint32_t kVersion = 1;
constexpr uint32_t kSampleRate = 16000;
constexpr uint32_t kChannels = 4;
constexpr uint32_t kSamplesPerChannel = 256;
constexpr uint32_t kBytesPerSample = sizeof(int32_t);
constexpr uint32_t kPayloadBytes = kChannels * kSamplesPerChannel * kBytesPerSample;

enum class Command : uint32_t {
    SubscribeMicrophones = 1,
};

enum class SampleFormat : uint32_t {
    PcmS32Le = 1,
};

enum Capability : uint32_t {
    CapabilityPhysicalMicrophoneArray = 0x00000001u,
    CapabilityChannelValidityMask = 0x00000002u,
};

#pragma pack(push, 1)
struct Request {
    uint32_t magic = kMagic;
    uint32_t version = kVersion;
    Command command = Command::SubscribeMicrophones;
    uint32_t reserved = 0;
};

struct Reply {
    uint32_t magic = kMagic;
    uint32_t version = kVersion;
    int32_t result = 0;
    uint32_t sampleRate = kSampleRate;
    uint32_t channels = kChannels;
    SampleFormat sampleFormat = SampleFormat::PcmS32Le;
    uint32_t maxPayloadBytes = kPayloadBytes;
    // Raw four-channel capture is the complete V1 audio contract.
    uint32_t capabilities = CapabilityPhysicalMicrophoneArray |
                            CapabilityChannelValidityMask;
};

struct FrameHeader {
    uint32_t magic = kFrameMagic;
    uint32_t version = kVersion;
    uint32_t sampleRate = kSampleRate;
    uint32_t channels = kChannels;
    SampleFormat sampleFormat = SampleFormat::PcmS32Le;
    uint32_t samplesPerChannel = kSamplesPerChannel;
    uint32_t payloadBytes = kPayloadBytes;
    uint32_t channelMask = 0; // bit0..bit3: complete physical microphones in this window
    uint64_t frameNumber = 0;
    uint64_t tickMs = 0;
};
#pragma pack(pop)

static_assert(sizeof(Request) == 16, "Audio request ABI");
static_assert(sizeof(Reply) == 32, "Audio reply ABI");
static_assert(sizeof(FrameHeader) == 48, "Audio frame ABI");
} // namespace Kinect360RemoldAudioPort
