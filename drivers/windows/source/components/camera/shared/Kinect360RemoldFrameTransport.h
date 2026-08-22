#pragma once
#include <windows.h>
#include <cstdint>

namespace Kinect360RemoldFrameTransport {
constexpr wchar_t kMappingName[] = L"Global\\Kinect360RemoldFrame";
constexpr uint32_t kMagic = 0x3143564Bu; // "KVC1"
constexpr uint32_t kVersion = 1;
constexpr uint32_t kWidth = 640;
constexpr uint32_t kHeight = 480;
constexpr uint32_t kNv12Fourcc = 0x3231564Eu; // NV12
constexpr uint32_t kNv12Bytes = kWidth * kHeight * 3u / 2u;
constexpr uint32_t kHeaderBytes = 4096;
constexpr uint32_t kSlotCount = 2;
constexpr uint32_t kMappingBytes = kHeaderBytes + kNv12Bytes * kSlotCount;

struct FrameSlotMeta {
    uint64_t frameNumber;
    uint64_t tickMs;
    uint32_t bytes;
    uint32_t reserved;
};

struct SharedHeader {
    uint32_t magic;
    uint32_t version;
    uint32_t width;
    uint32_t height;
    uint32_t fourcc;
    uint32_t stride;
    uint32_t frameBytes;
    uint32_t slotCount;
    volatile LONG sequence;   // odd while writer mutates, even when stable
    volatile LONG activeSlot;
    volatile LONG online;
    LONG reserved0;
    FrameSlotMeta slot[kSlotCount];
};

static_assert(sizeof(SharedHeader) <= kHeaderBytes, "Shared header must fit reserved page");

inline uint8_t* SlotAddress(void* base, uint32_t slot) noexcept {
    return static_cast<uint8_t*>(base) + kHeaderBytes + static_cast<size_t>(slot) * kNv12Bytes;
}
inline const uint8_t* SlotAddress(const void* base, uint32_t slot) noexcept {
    return static_cast<const uint8_t*>(base) + kHeaderBytes + static_cast<size_t>(slot) * kNv12Bytes;
}
}
