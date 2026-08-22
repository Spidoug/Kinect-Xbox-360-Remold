#ifndef NOMINMAX
#define NOMINMAX
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <setupapi.h>
#include <winusb.h>
#include <usb.h>
#include <sddl.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <condition_variable>
#include <deque>
#include <chrono>
#include <cmath>
#include <limits>
#include <mutex>
#include <string>
#include <thread>
#include <system_error>
#include <vector>

#include "..\..\shared\Kinect360RemoldFrameTransport.h"
#include "..\..\shared\Kinect360RemoldScannerPort.h"
#include "..\..\..\device\shared\Kinect360RemoldControlProtocol.h"

#pragma comment(lib, "setupapi.lib")
#pragma comment(lib, "winusb.lib")
#pragma comment(lib, "advapi32.lib")

namespace {
using namespace Kinect360RemoldFrameTransport;
namespace Control = Kinect360RemoldControl;
namespace ScannerPort = Kinect360RemoldScannerPort;

// Interface published by Kinect360RemoldCamera.inf for supported Kinect RGB camera PIDs.
const GUID kCameraTransportGuid = {0xe05f50e4,0x0674,0x4ecf,{0x9d,0x63,0x15,0x40,0x1b,0x83,0x7e,0x9b}};
constexpr UCHAR kVideoIn = 0x81;
constexpr UCHAR kDepthIn = 0x82;
constexpr ULONG kIsoPacketsPerTransfer = 32;
constexpr ULONG kIsoQueueDepth = 16;
constexpr ULONG kRgbRawFrameBytes = 640u * 480u;                 // medium Bayer
constexpr ULONG kIrRawFrameBytes = 640u * 488u * 10u / 8u;      // medium IR, packed 10-bit
constexpr ULONG kDepthRawFrameBytes = 640u * 480u * 11u / 8u;   // medium depth, packed 11-bit
constexpr ULONG kVideoPacketBytes = 1920u;
constexpr ULONG kDepthPacketBytes = 1760u;
constexpr uint8_t kVideoFlag = 0x80;
constexpr uint8_t kDepthFlag = 0x70;
constexpr DWORD kControlReplyDeadlineMs = 2000;
constexpr DWORD kIsoWaitMs = 1000;
constexpr int kMaxIsoTimeouts = 3;
constexpr DWORD kScannerStatePollMs = 25;
constexpr DWORD kScannerActivityHeartbeatMs = 750;

std::atomic<bool> g_run{true};
HANDLE g_stopEvent = nullptr;
SERVICE_STATUS_HANDLE g_statusHandle = nullptr;
SERVICE_STATUS g_status{};

HRESULT HrLastError() {
    DWORD e = GetLastError();
    return HRESULT_FROM_WIN32(e ? e : ERROR_GEN_FAILURE);
}

void Log(const wchar_t* text) {
    if (!text) return;
    OutputDebugStringW(text);
    OutputDebugStringW(L"\n");
    if (GetConsoleWindow()) std::fwprintf(stderr, L"%ls\n", text);
}

void LogHr(const wchar_t* what, HRESULT hr) {
    wchar_t buf[256]{};
    swprintf_s(buf, L"%ls: 0x%08X", what, static_cast<unsigned>(hr));
    Log(buf);
}

void NotifyBrokerScannerActivity() {
    if (!WaitNamedPipeW(Control::kPipeName, 0)) return;
    HANDLE pipe = CreateFileW(Control::kPipeName, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (pipe == INVALID_HANDLE_VALUE) return;
    DWORD mode = PIPE_READMODE_MESSAGE;
    (void)SetNamedPipeHandleState(pipe, &mode, nullptr, nullptr);

    Control::Request request{};
    request.command = Control::Command::CameraActivity;
    request.value = static_cast<int32_t>(Control::CameraActivitySource::Scanner3D);
    Control::Reply reply{};
    DWORD done = 0;
    (void)(WriteFile(pipe, &request, sizeof(request), &done, nullptr) && done == sizeof(request) &&
           ReadFile(pipe, &reply, sizeof(reply), &done, nullptr));
    CloseHandle(pipe);
}

bool QueryBrokerMotion(ScannerPort::MotionSample& motion) {
    motion = {};
    if (!WaitNamedPipeW(Control::kPipeName, 0)) return false;
    HANDLE pipe = CreateFileW(Control::kPipeName, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (pipe == INVALID_HANDLE_VALUE) return false;
    DWORD mode = PIPE_READMODE_MESSAGE;
    (void)SetNamedPipeHandleState(pipe, &mode, nullptr, nullptr);

    Control::Request request{};
    request.command = Control::Command::Status;
    Control::Reply reply{};
    DWORD written = 0, read = 0;
    const bool ok = WriteFile(pipe, &request, sizeof(request), &written, nullptr) &&
                    written == sizeof(request) &&
                    ReadFile(pipe, &reply, sizeof(reply), &read, nullptr) &&
                    read == sizeof(reply);
    CloseHandle(pipe);
    if (!ok || reply.magic != Control::kMagic || reply.version != Control::kVersion ||
        FAILED(static_cast<HRESULT>(reply.result)) ||
        reply.transport != Control::Transport::PhysicalMotor) return false;

    motion.flags = ScannerPort::MotionAccelerometerValid | ScannerPort::MotionTiltValid;
    motion.accelX = reply.accelX;
    motion.accelY = reply.accelY;
    motion.accelZ = reply.accelZ;
    motion.tiltTenths = reply.tiltTenths;
    motion.tickMs = GetTickCount64();
    return true;
}

const wchar_t* StreamModeName(ScannerPort::StreamMode mode) {
    switch (mode) {
        case ScannerPort::StreamMode::Rgb: return L"RGB";
        case ScannerPort::StreamMode::Infrared: return L"Infrared";
        case ScannerPort::StreamMode::Depth: return L"Depth";
        default: return L"Unknown";
    }
}

#pragma pack(push, 1)
struct CameraCommandHeader {
    uint8_t magic[2];
    uint16_t lengthWords;
    uint16_t command;
    uint16_t tag;
};
struct VideoPacketHeader {
    uint8_t magic[2];
    uint8_t pad;
    uint8_t flag;
    uint8_t unknown1;
    uint8_t sequence;
    uint8_t unknown2;
    uint8_t unknown3;
    uint32_t timestamp;
};
#pragma pack(pop)
static_assert(sizeof(CameraCommandHeader) == 8, "camera command header");
static_assert(sizeof(VideoPacketHeader) == 12, "video packet header");

class SharedFramePublisher {
public:
    ~SharedFramePublisher() { Close(); }

    HRESULT Open() {
        Close();
        PSECURITY_DESCRIPTOR sd = nullptr;
        // LocalSystem writes. LocalService (Frame Server), Administrators and
        // app-container consumers may read. The virtual camera itself only reads.
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
                L"D:P(A;;GA;;;SY)(A;;GR;;;LS)(A;;GR;;;BA)(A;;GR;;;AC)",
                SDDL_REVISION_1, &sd, nullptr)) {
            return HrLastError();
        }
        SECURITY_ATTRIBUTES sa{sizeof(sa), sd, FALSE};
        m_mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, &sa, PAGE_READWRITE,
                                       0, kMappingBytes, kMappingName);
        LocalFree(sd);
        if (!m_mapping) return HrLastError();
        m_base = MapViewOfFile(m_mapping, FILE_MAP_ALL_ACCESS, 0, 0, kMappingBytes);
        if (!m_base) {
            HRESULT hr = HrLastError();
            Close();
            return hr;
        }
        m_header = static_cast<SharedHeader*>(m_base);

        // A Frame Server reader can keep the named mapping alive while this
        // service restarts.  Mark the mapping unstable *before* reinitializing
        // it so a reader can never accept a half-reset frame just because the
        // mapping object survived the writer process.
        InterlockedExchange(&m_header->sequence, 1); // odd = writer owns state
        MemoryBarrier();
        m_header->magic = kMagic;
        m_header->version = kVersion;
        m_header->width = kWidth;
        m_header->height = kHeight;
        m_header->fourcc = kNv12Fourcc;
        m_header->stride = kWidth;
        m_header->frameBytes = kNv12Bytes;
        m_header->slotCount = kSlotCount;
        m_header->activeSlot = 0;
        m_header->online = 0;
        m_header->reserved0 = 0;
        std::memset(m_header->slot, 0, sizeof(m_header->slot));
        std::memset(SlotAddress(m_base, 0), 0, static_cast<size_t>(kNv12Bytes) * kSlotCount);
        MemoryBarrier();
        InterlockedExchange(&m_header->sequence, 2); // even = stable/offline
        return S_OK;
    }

    void SetOnline(bool online) {
        if (!m_header) return;
        InterlockedIncrement(&m_header->sequence); // odd
        InterlockedExchange(&m_header->online, online ? 1 : 0);
        MemoryBarrier();
        InterlockedIncrement(&m_header->sequence); // even
    }

    void Publish(const uint8_t* nv12, size_t bytes) {
        if (!m_header || !nv12 || bytes != kNv12Bytes) return;
        InterlockedIncrement(&m_header->sequence); // single-writer seqlock: odd
        const LONG current = InterlockedCompareExchange(&m_header->activeSlot, 0, 0);
        const uint32_t next = (current == 0) ? 1u : 0u;
        std::memcpy(SlotAddress(m_base, next), nv12, kNv12Bytes);
        m_header->slot[next].frameNumber = ++m_frameNumber;
        m_header->slot[next].tickMs = GetTickCount64();
        m_header->slot[next].bytes = kNv12Bytes;
        MemoryBarrier();
        InterlockedExchange(&m_header->activeSlot, static_cast<LONG>(next));
        InterlockedExchange(&m_header->online, 1);
        MemoryBarrier();
        InterlockedIncrement(&m_header->sequence); // even
    }

private:
    HANDLE m_mapping = nullptr;
    void* m_base = nullptr;
    SharedHeader* m_header = nullptr;
    uint64_t m_frameNumber = 0;

    void Close() {
        if (m_header) SetOnline(false);
        if (m_base) UnmapViewOfFile(m_base);
        if (m_mapping) CloseHandle(m_mapping);
        m_mapping = nullptr;
        m_base = nullptr;
        m_header = nullptr;
    }
};


struct DepthCalibration {
    std::array<uint16_t, 2048> rawToMm{};
    bool valid = false;
    double constShift = 0.0;
    float dcmosEmitterDist = 0.0f;
    float referenceDistance = 0.0f;
    float referencePixelSize = 0.0f;
};

class ScannerPortServer {
public:
    ~ScannerPortServer() { Stop(); }

    HRESULT Start() {
        if (m_thread.joinable()) return S_OK;
        m_stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!m_stopEvent) return HrLastError();
        try {
            m_thread = std::thread([this] { ServerLoop(); });
            m_motionThread = std::thread([this] { MotionLoop(); });
        } catch (const std::system_error&) {
            if (m_stopEvent) SetEvent(m_stopEvent);
            if (m_thread.joinable()) m_thread.join();
            if (m_motionThread.joinable()) m_motionThread.join();
            CloseHandle(m_stopEvent);
            m_stopEvent = nullptr;
            return E_OUTOFMEMORY;
        }
        return S_OK;
    }

    void Stop() {
        {
            std::lock_guard<std::mutex> guard(m_lock);
            m_stopping = true;
            m_queue.clear();
        }
        m_streamMask.store(0, std::memory_order_release);
        if (m_stopEvent) SetEvent(m_stopEvent);
        m_cv.notify_all();
        if (m_thread.joinable()) m_thread.join();
        if (m_motionThread.joinable()) m_motionThread.join();
        if (m_stopEvent) CloseHandle(m_stopEvent);
        m_stopEvent = nullptr;
    }

    uint32_t RequestedMask() const noexcept {
        return m_streamMask.load(std::memory_order_acquire);
    }

    bool ClientActive() const noexcept { return RequestedMask() != 0; }

    bool Wants(ScannerPort::StreamMode mode) const noexcept {
        return (RequestedMask() & ScannerPort::MaskFor(mode)) != 0;
    }

    bool NeedsProjector() const noexcept {
        return (RequestedMask() & (ScannerPort::StreamInfrared | ScannerPort::StreamDepth)) != 0;
    }

    void Publish(ScannerPort::StreamMode mode, ScannerPort::PixelFormat pixelFormat,
                 const void* payload, size_t bytes, uint32_t flags = 0,
                 uint64_t captureTickMs = 0) {
        if (!payload || !bytes || !Wants(mode)) return;
        const ScannerPort::StreamMode scannerMode = mode;
        QueuedFrame next;
        next.header = ScannerPort::FrameHeader{};
        next.header.mode = scannerMode;
        next.header.pixelFormat = pixelFormat;
        next.header.payloadBytes = static_cast<uint32_t>(bytes);
        next.header.flags = flags;
        const size_t index = static_cast<size_t>(scannerMode);
        if (index >= m_frameNumbers.size()) return;
        next.header.frameNumber = ++m_frameNumbers[index];
        next.header.tickMs = captureTickMs ? captureTickMs : GetTickCount64();
        next.header.motion = CurrentMotion();
        next.payload.resize(bytes);
        std::memcpy(next.payload.data(), payload, bytes);

        {
            std::lock_guard<std::mutex> guard(m_lock);
            if (m_stopping || !Wants(mode)) return;
            // Latest-frame semantics per stream. A slow scanner never creates an
            // unbounded per-stream backlog; newer data replaces stale same-mode data.
            for (auto it = m_queue.begin(); it != m_queue.end();) {
                if (it->header.mode == scannerMode) it = m_queue.erase(it);
                else ++it;
            }
            while (m_queue.size() >= 6) m_queue.pop_front();
            m_queue.push_back(std::move(next));
        }
        m_cv.notify_all();
    }

private:
    struct QueuedFrame {
        ScannerPort::FrameHeader header{};
        std::vector<uint8_t> payload;
    };

    std::mutex m_lock;
    std::condition_variable m_cv;
    std::thread m_thread;
    std::thread m_motionThread;
    HANDLE m_stopEvent = nullptr;
    std::deque<QueuedFrame> m_queue;
    std::array<std::atomic<uint64_t>, 3> m_frameNumbers{};
    bool m_stopping = false;
    std::atomic<uint32_t> m_streamMask{0};
    std::mutex m_motionLock;
    ScannerPort::MotionSample m_motion{};

    ScannerPort::MotionSample CurrentMotion() {
        std::lock_guard<std::mutex> guard(m_motionLock);
        return m_motion;
    }

    void MotionLoop() {
        ULONGLONG lastValid = 0;
        while (!StopRequested()) {
            if (!ClientActive()) {
                {
                    std::lock_guard<std::mutex> guard(m_motionLock);
                    m_motion = {};
                }
                lastValid = 0;
                if (m_stopEvent && WaitForSingleObject(m_stopEvent, 100) == WAIT_OBJECT_0) break;
                if (!m_stopEvent) Sleep(100);
                continue;
            }

            ScannerPort::MotionSample sample{};
            if (QueryBrokerMotion(sample)) {
                {
                    std::lock_guard<std::mutex> guard(m_motionLock);
                    m_motion = sample;
                }
                lastValid = GetTickCount64();
            } else if (lastValid == 0 || GetTickCount64() - lastValid > 250) {
                std::lock_guard<std::mutex> guard(m_motionLock);
                m_motion = {};
            }
            if (m_stopEvent && WaitForSingleObject(m_stopEvent, 25) == WAIT_OBJECT_0) break;
            if (!m_stopEvent) Sleep(25);
        }
    }

    bool StopRequested() const noexcept {
        return !g_run.load() || (m_stopEvent && WaitForSingleObject(m_stopEvent, 0) == WAIT_OBJECT_0);
    }

    DWORD WaitIo(HANDLE ioEvent, DWORD timeout) const {
        HANDLE handles[3]{};
        DWORD count = 0;
        if (m_stopEvent) handles[count++] = m_stopEvent;
        if (g_stopEvent) handles[count++] = g_stopEvent;
        handles[count++] = ioEvent;
        return WaitForMultipleObjects(count, handles, FALSE, timeout);
    }

    bool TransferExact(HANDLE pipe, void* buffer, DWORD bytes, bool write, DWORD timeoutMs) {
        uint8_t* cursor = static_cast<uint8_t*>(buffer);
        DWORD total = 0;
        while (total < bytes && !StopRequested()) {
            HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
            if (!event) return false;
            OVERLAPPED ov{};
            ov.hEvent = event;
            DWORD done = 0;
            BOOL ok = write
                ? WriteFile(pipe, cursor + total, bytes - total, &done, &ov)
                : ReadFile(pipe, cursor + total, bytes - total, &done, &ov);
            if (!ok && GetLastError() == ERROR_IO_PENDING) {
                const DWORD wait = WaitIo(event, timeoutMs);
                const DWORD stopCount = (m_stopEvent ? 1u : 0u) + (g_stopEvent ? 1u : 0u);
                if (wait < WAIT_OBJECT_0 + stopCount || wait == WAIT_TIMEOUT) {
                    (void)CancelIoEx(pipe, &ov);
                    (void)GetOverlappedResult(pipe, &ov, &done, TRUE);
                    CloseHandle(event);
                    return false;
                }
                ok = GetOverlappedResult(pipe, &ov, &done, FALSE);
            }
            CloseHandle(event);
            if (!ok || done == 0) return false;
            total += done;
        }
        return total == bytes;
    }

    bool WriteFrame(HANDLE pipe, const QueuedFrame& frame) {
        if (!TransferExact(pipe, const_cast<ScannerPort::FrameHeader*>(&frame.header),
                           static_cast<DWORD>(sizeof(frame.header)), true, 2000)) return false;
        if (frame.payload.empty()) return true;
        return TransferExact(pipe, const_cast<uint8_t*>(frame.payload.data()),
                             static_cast<DWORD>(frame.payload.size()), true, 2000);
    }

    bool ClientStillConnected(HANDLE pipe) const noexcept {
        DWORD available = 0;
        if (!PeekNamedPipe(pipe, nullptr, 0, nullptr, &available, nullptr)) {
            const DWORD e = GetLastError();
            if (e == ERROR_BROKEN_PIPE || e == ERROR_PIPE_NOT_CONNECTED || e == ERROR_NO_DATA) return false;
        }

        ULONG clientPid = 0;
        if (GetNamedPipeClientProcessId(pipe, &clientPid) && clientPid != 0) {
            HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, clientPid);
            if (process) {
                const DWORD state = WaitForSingleObject(process, 0);
                CloseHandle(process);
                if (state == WAIT_OBJECT_0) return false;
            }
        }
        return true;
    }

    void ClearClient() {
        m_streamMask.store(0, std::memory_order_release);
        {
            std::lock_guard<std::mutex> guard(m_lock);
            m_queue.clear();
        }
        m_cv.notify_all();
    }

    void ServeClient(HANDLE pipe) {
        ScannerPort::Request request{};
        if (!TransferExact(pipe, &request, sizeof(request), false, 5000)) return;

        ScannerPort::Reply reply{};
        const uint32_t accepted = request.streamMask & ScannerPort::StreamSupported;
        if (request.magic != ScannerPort::kMagic || request.version != ScannerPort::kVersion ||
            request.command != ScannerPort::Command::SubscribeStreams ||
            !ScannerPort::IsValidStreamMask(request.streamMask)) {
            reply.result = static_cast<int32_t>(E_INVALIDARG);
            (void)TransferExact(pipe, &reply, sizeof(reply), true, 1000);
            return;
        }

        reply.acceptedMask = accepted;
        m_streamMask.store(accepted, std::memory_order_release);
        if (!TransferExact(pipe, &reply, sizeof(reply), true, 1000)) {
            ClearClient();
            return;
        }

        while (!StopRequested()) {
            QueuedFrame frame;
            {
                std::unique_lock<std::mutex> lock(m_lock);
                m_cv.wait_for(lock, std::chrono::milliseconds(100), [this] {
                    return m_stopping || !m_queue.empty() || RequestedMask() == 0;
                });
                if (m_stopping || StopRequested() || RequestedMask() == 0) break;
                if (!ClientStillConnected(pipe)) break;
                if (m_queue.empty()) continue;
                frame = std::move(m_queue.front());
                m_queue.pop_front();
            }
            if (!WriteFrame(pipe, frame)) break;
        }
        ClearClient();
    }

    void ServerLoop() {
        PSECURITY_DESCRIPTOR descriptor = nullptr;
        SECURITY_ATTRIBUTES security{};
        security.nLength = sizeof(security);
        if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
                L"D:P(A;;GA;;;SY)(A;;GRGW;;;BA)(A;;GRGW;;;AU)", SDDL_REVISION_1,
                &descriptor, nullptr)) {
            security.lpSecurityDescriptor = descriptor;
        }

        while (!StopRequested()) {
            HANDLE pipe = CreateNamedPipeW(
                ScannerPort::kPipeName,
                PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                1,
                static_cast<DWORD>(sizeof(ScannerPort::FrameHeader) + ScannerPort::kMaxPayloadBytes),
                static_cast<DWORD>(sizeof(ScannerPort::Request)),
                0, security.lpSecurityDescriptor ? &security : nullptr);
            if (pipe == INVALID_HANDLE_VALUE) break;

            HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
            if (!event) { CloseHandle(pipe); break; }
            OVERLAPPED ov{};
            ov.hEvent = event;
            BOOL connected = ConnectNamedPipe(pipe, &ov);
            if (!connected) {
                const DWORD e = GetLastError();
                if (e == ERROR_PIPE_CONNECTED) connected = TRUE;
                else if (e == ERROR_IO_PENDING) {
                    HANDLE waits[3]{m_stopEvent, g_stopEvent, event};
                    const DWORD wait = WaitForMultipleObjects(3, waits, FALSE, INFINITE);
                    if (wait == WAIT_OBJECT_0 + 2) {
                        DWORD ignored = 0;
                        connected = GetOverlappedResult(pipe, &ov, &ignored, FALSE);
                    } else {
                        (void)CancelIoEx(pipe, &ov);
                        DWORD ignored = 0;
                        (void)GetOverlappedResult(pipe, &ov, &ignored, TRUE);
                    }
                }
            }
            CloseHandle(event);
            if (connected && !StopRequested()) ServeClient(pipe);
            ClearClient();
            (void)CancelIoEx(pipe, nullptr);
            (void)DisconnectNamedPipe(pipe);
            CloseHandle(pipe);
        }
        if (descriptor) LocalFree(descriptor);
    }
};

struct Rgb { int r; int g; int b; };

inline int Clamp8(int v) { return std::clamp(v, 0, 255); }

Rgb DemosaicAt(const uint8_t* bayer, int x, int y) {
    auto at = [&](int sx, int sy) -> int {
        sx = std::clamp(sx, 0, 639);
        sy = std::clamp(sy, 0, 479);
        return bayer[sy * 640 + sx];
    };
    const bool yOdd = (y & 1) != 0;
    const bool xOdd = (x & 1) != 0;
    Rgb p{};
    if (!yOdd && !xOdd) { // G R / B G : green on red row
        p.g = at(x,y);
        p.r = (at(x-1,y) + at(x+1,y)) / 2;
        p.b = (at(x,y-1) + at(x,y+1)) / 2;
    } else if (!yOdd && xOdd) { // red
        p.r = at(x,y);
        p.g = (at(x-1,y) + at(x+1,y) + at(x,y-1) + at(x,y+1)) / 4;
        p.b = (at(x-1,y-1) + at(x+1,y-1) + at(x-1,y+1) + at(x+1,y+1)) / 4;
    } else if (yOdd && !xOdd) { // blue
        p.b = at(x,y);
        p.g = (at(x-1,y) + at(x+1,y) + at(x,y-1) + at(x,y+1)) / 4;
        p.r = (at(x-1,y-1) + at(x+1,y-1) + at(x-1,y+1) + at(x+1,y+1)) / 4;
    } else { // green on blue row
        p.g = at(x,y);
        p.r = (at(x,y-1) + at(x,y+1)) / 2;
        p.b = (at(x-1,y) + at(x+1,y)) / 2;
    }
    return p;
}

inline uint8_t RgbToY(const Rgb& p) {
    return static_cast<uint8_t>(Clamp8(((66 * p.r + 129 * p.g + 25 * p.b + 128) >> 8) + 16));
}

void BayerToNv12(const uint8_t* bayer, uint8_t* nv12) {
    uint8_t* yPlane = nv12;
    uint8_t* uvPlane = nv12 + kWidth * kHeight;

    // Work in 2x2 output blocks: every Bayer location is demosaiced exactly
    // once, its luma is written immediately, and the same four RGB samples are
    // averaged for the matching NV12 chroma pair.  This keeps conversion off
    // the USB thread and also avoids a second full-frame demosaic pass.
    for (int y = 0; y < static_cast<int>(kHeight); y += 2) {
        for (int x = 0; x < static_cast<int>(kWidth); x += 2) {
            const Rgb p0 = DemosaicAt(bayer, x,     y);
            const Rgb p1 = DemosaicAt(bayer, x + 1, y);
            const Rgb p2 = DemosaicAt(bayer, x,     y + 1);
            const Rgb p3 = DemosaicAt(bayer, x + 1, y + 1);

            const size_t y0 = static_cast<size_t>(y) * kWidth + static_cast<size_t>(x);
            const size_t y1 = y0 + kWidth;
            yPlane[y0]     = RgbToY(p0);
            yPlane[y0 + 1] = RgbToY(p1);
            yPlane[y1]     = RgbToY(p2);
            yPlane[y1 + 1] = RgbToY(p3);

            const int r = (p0.r + p1.r + p2.r + p3.r) / 4;
            const int g = (p0.g + p1.g + p2.g + p3.g) / 4;
            const int b = (p0.b + p1.b + p2.b + p3.b) / 4;
            const size_t uv = static_cast<size_t>(y / 2) * kWidth + static_cast<size_t>(x);
            uvPlane[uv] = static_cast<uint8_t>(Clamp8(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128));
            uvPlane[uv + 1] = static_cast<uint8_t>(Clamp8(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128));
        }
    }
}


void UnpackBitsTo16(const uint8_t* source, uint16_t* destination, unsigned bits, size_t count) {
    const uint32_t mask = (1u << bits) - 1u;
    uint32_t buffer = 0;
    unsigned bitsIn = 0;
    while (count--) {
        while (bitsIn < bits) {
            buffer = (buffer << 8) | *source++;
            bitsIn += 8;
        }
        bitsIn -= bits;
        *destination++ = static_cast<uint16_t>((buffer >> bitsIn) & mask);
    }
}


class FrameConversionWorker {
public:
    FrameConversionWorker(SharedFramePublisher& publisher,
                          ScannerPortServer& scannerPort,
                          const DepthCalibration& depthCalibration,
                          ScannerPort::StreamMode mode,
                          size_t rawBytes)
        : m_publisher(publisher), m_scannerPort(scannerPort), m_depthCalibration(depthCalibration),
          m_mode(mode), m_rawBytes(rawBytes),
          m_rawA(rawBytes), m_rawB(rawBytes), m_work(rawBytes), m_nv12(kNv12Bytes) {}

    ~FrameConversionWorker() { Stop(); }

    HRESULT Start() {
        try {
            m_thread = std::thread([this] { Run(); });
        } catch (const std::system_error&) {
            return E_OUTOFMEMORY;
        }
        return S_OK;
    }

    void Submit(const std::vector<uint8_t>& raw, uint64_t captureTickMs) {
        if (raw.size() != m_rawBytes) return;
        {
            std::lock_guard<std::mutex> guard(m_lock);
            // Latest-frame semantics: overwrite the pending slot instead of
            // letting a slow CPU conversion build an unbounded queue.
            std::vector<uint8_t>& target = m_writeA ? m_rawA : m_rawB;
            std::memcpy(target.data(), raw.data(), m_rawBytes);
            if (m_writeA) m_captureTickA = captureTickMs; else m_captureTickB = captureTickMs;
            m_pendingA = m_writeA;
            m_writeA = !m_writeA;
            m_hasPending = true;
        }
        m_cv.notify_one();
    }

    void Stop() {
        {
            std::lock_guard<std::mutex> guard(m_lock);
            m_stopping = true;
        }
        m_cv.notify_all();
        if (m_thread.joinable()) m_thread.join();
    }

private:
    SharedFramePublisher& m_publisher;
    ScannerPortServer& m_scannerPort;
    DepthCalibration m_depthCalibration;
    ScannerPort::StreamMode m_mode;
    size_t m_rawBytes;
    std::mutex m_lock;
    std::condition_variable m_cv;
    std::thread m_thread;
    std::vector<uint8_t> m_rawA;
    std::vector<uint8_t> m_rawB;
    std::vector<uint8_t> m_work;
    std::vector<uint8_t> m_nv12;
    std::vector<uint16_t> m_unpacked;
    std::vector<uint16_t> m_metric;
    uint64_t m_captureTickA = 0;
    uint64_t m_captureTickB = 0;
    uint64_t m_workCaptureTickMs = 0;
    bool m_writeA = true;
    bool m_pendingA = true;
    bool m_hasPending = false;
    bool m_stopping = false;

    void Run() {
        for (;;) {
            {
                std::unique_lock<std::mutex> lock(m_lock);
                m_cv.wait(lock, [this] { return m_stopping || m_hasPending; });
                if (m_stopping) break;
                const std::vector<uint8_t>& source = m_pendingA ? m_rawA : m_rawB;
                std::memcpy(m_work.data(), source.data(), m_rawBytes);
                m_workCaptureTickMs = m_pendingA ? m_captureTickA : m_captureTickB;
                m_hasPending = false;
            }

            switch (m_mode) {
                case ScannerPort::StreamMode::Rgb: {
                    // virtual camera is permanently RGB-only. The scanner can also
                    // request RGB through its private port and receives the same NV12 frame.
                    BayerToNv12(m_work.data(), m_nv12.data());
                    m_publisher.Publish(m_nv12.data(), m_nv12.size());
                    m_scannerPort.Publish(m_mode, ScannerPort::PixelFormat::Nv12,
                                          m_nv12.data(), m_nv12.size(), 0u, m_workCaptureTickMs);
                    break;
                }
                case ScannerPort::StreamMode::Infrared: {
                    // Scanner-only path. Do not spend CPU generating an NV12 preview
                    // for Media Foundation: virtual camera must never expose IR.
                    constexpr size_t kIrPixels = 640u * 488u;
                    constexpr size_t kOutPixels = 640u * 480u;
                    if (m_unpacked.size() != kIrPixels) m_unpacked.resize(kIrPixels);
                    UnpackBitsTo16(m_work.data(), m_unpacked.data(), 10, m_unpacked.size());
                    if (m_metric.size() != kOutPixels) m_metric.resize(kOutPixels);
                    for (size_t y = 0; y < 480u; ++y) {
                        std::memcpy(m_metric.data() + y * 640u,
                                    m_unpacked.data() + (y + 4u) * 640u,
                                    640u * sizeof(uint16_t));
                    }
                    m_scannerPort.Publish(m_mode, ScannerPort::PixelFormat::Gray16,
                                          m_metric.data(), m_metric.size() * sizeof(uint16_t), 0u, m_workCaptureTickMs);
                    break;
                }
                case ScannerPort::StreamMode::Depth:
                    // Scanner-only metric path. Avoid depth pseudocolour/NV12 completely:
                    // unpack once, LUT to millimetres, publish. This is intentionally
                    // independent of the Windows virtual camera and removes its CPU cost.
                    if (m_unpacked.size() != static_cast<size_t>(kWidth) * kHeight)
                        m_unpacked.resize(static_cast<size_t>(kWidth) * kHeight);
                    UnpackBitsTo16(m_work.data(), m_unpacked.data(), 11, m_unpacked.size());
                    if (m_metric.size() != m_unpacked.size()) m_metric.resize(m_unpacked.size());
                    if (m_depthCalibration.valid) {
                        for (size_t i = 0; i < m_unpacked.size(); ++i) {
                            const uint16_t raw = m_unpacked[i];
                            m_metric[i] = raw < m_depthCalibration.rawToMm.size()
                                ? m_depthCalibration.rawToMm[raw] : 0;
                        }
                    } else {
                        std::fill(m_metric.begin(), m_metric.end(), uint16_t{0});
                    }
                    m_scannerPort.Publish(m_mode, ScannerPort::PixelFormat::DepthMm16,
                                          m_metric.data(), m_metric.size() * sizeof(uint16_t),
                                          m_depthCalibration.valid ? ScannerPort::kFlagDeviceCalibrated : 0u,
                                          m_workCaptureTickMs);
                    break;
                default:
                    continue;
            }
            // If Submit() arrived during conversion, m_hasPending is true and
            // the next loop iteration consumes only the newest complete frame.
        }
    }
};

class FrameAssembler {
public:
    FrameAssembler(size_t frameBytes, ULONG packetBytes, uint8_t streamFlag)
        : m_raw(frameBytes),
          m_packetDataBytes(packetBytes > sizeof(VideoPacketHeader)
              ? packetBytes - static_cast<ULONG>(sizeof(VideoPacketHeader)) : 0),
          m_streamFlag(streamFlag) {
        if (m_packetDataBytes) {
            m_packetsPerFrame = static_cast<ULONG>((frameBytes + m_packetDataBytes - 1) / m_packetDataBytes);
            m_lastPacketDataBytes = static_cast<ULONG>(frameBytes -
                static_cast<size_t>(m_packetsPerFrame - 1u) * m_packetDataBytes);
        }
    }

    bool IsValid() const noexcept {
        return !m_raw.empty() && m_packetDataBytes && m_packetsPerFrame && m_lastPacketDataBytes;
    }

    void Reset() noexcept { ResetSync(); }

    bool Push(const uint8_t* packet, ULONG length, std::vector<uint8_t>& completed,
              uint64_t& captureTickMs) {
        if (!IsValid() || !packet || length < sizeof(VideoPacketHeader)) return false;
        VideoPacketHeader h{};
        std::memcpy(&h, packet, sizeof(h));
        if (h.magic[0] != 'R' || h.magic[1] != 'B') return false;
        const uint8_t sof = m_streamFlag | 1;
        const uint8_t mof = m_streamFlag | 2;
        const uint8_t eof = m_streamFlag | 5;

        if (h.flag == sof) {
            m_synced = true;
            m_offset = 0;
            m_packetIndex = 0;
            m_expectedSequence = h.sequence;
            // Timestamp at USB start-of-frame, before RGB demosaic/depth conversion.
            // Both physical endpoints share this host monotonic clock, so pairing
            // is no longer biased by different conversion costs.
            m_captureTickMs = GetTickCount64();
        } else if (!m_synced) {
            return false;
        }
        if (h.sequence != m_expectedSequence) {
            ResetSync();
            return false;
        }

        const bool first = (m_packetIndex == 0);
        const bool last = (m_packetIndex == m_packetsPerFrame - 1u);
        const uint8_t expectedFlag = first ? sof : (last ? eof : mof);
        if (h.flag != expectedFlag) {
            ResetSync();
            return false;
        }

        const ULONG payload = length - static_cast<ULONG>(sizeof(VideoPacketHeader));
        const ULONG expectedPayload = last ? m_lastPacketDataBytes : m_packetDataBytes;
        if (payload != expectedPayload || m_offset + payload > m_raw.size()) {
            ResetSync();
            return false;
        }

        std::memcpy(m_raw.data() + m_offset, packet + sizeof(VideoPacketHeader), payload);
        m_offset += payload;
        ++m_packetIndex;
        m_expectedSequence = static_cast<uint8_t>(h.sequence + 1);

        if (last) {
            const bool complete = (m_packetIndex == m_packetsPerFrame && m_offset == m_raw.size());
            const uint64_t completedCaptureTickMs = m_captureTickMs;
            ResetSync();
            if (complete) {
                completed.assign(m_raw.begin(), m_raw.end());
                captureTickMs = completedCaptureTickMs;
                return true;
            }
        }
        return false;
    }

private:
    std::vector<uint8_t> m_raw;
    ULONG m_packetDataBytes = 0;
    ULONG m_packetsPerFrame = 0;
    ULONG m_lastPacketDataBytes = 0;
    uint8_t m_streamFlag = 0;
    size_t m_offset = 0;
    ULONG m_packetIndex = 0;
    uint8_t m_expectedSequence = 0;
    bool m_synced = false;
    uint64_t m_captureTickMs = 0;

    void ResetSync() noexcept {
        m_synced = false;
        m_captureTickMs = 0;
        m_offset = 0;
        m_packetIndex = 0;
    }
};

bool CameraInterfacePresent() {
    HDEVINFO info = SetupDiGetClassDevsW(&kCameraTransportGuid, nullptr, nullptr,
                                         DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (info == INVALID_HANDLE_VALUE) return false;
    SP_DEVICE_INTERFACE_DATA iface{};
    iface.cbSize = sizeof(iface);
    const bool present = SetupDiEnumDeviceInterfaces(info, nullptr, &kCameraTransportGuid, 0, &iface) != FALSE;
    SetupDiDestroyDeviceInfoList(info);
    return present;
}

class CameraUsbTransport {
public:
    ~CameraUsbTransport() { Close(); }

    HRESULT Open() {
        Close();
        HDEVINFO info = SetupDiGetClassDevsW(&kCameraTransportGuid, nullptr, nullptr,
                                             DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (info == INVALID_HANDLE_VALUE) return HrLastError();
        HRESULT result = HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
        for (DWORD i = 0;; ++i) {
            SP_DEVICE_INTERFACE_DATA iface{};
            iface.cbSize = sizeof(iface);
            if (!SetupDiEnumDeviceInterfaces(info, nullptr, &kCameraTransportGuid, i, &iface)) {
                if (GetLastError() != ERROR_NO_MORE_ITEMS) result = HrLastError();
                break;
            }
            DWORD needed = 0;
            SetupDiGetDeviceInterfaceDetailW(info, &iface, nullptr, 0, &needed, nullptr);
            if (needed < sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W)) continue;
            std::vector<BYTE> storage(needed);
            auto* detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(storage.data());
            detail->cbSize = sizeof(*detail);
            if (!SetupDiGetDeviceInterfaceDetailW(info, &iface, detail, needed, nullptr, nullptr)) continue;
            m_file = CreateFileW(detail->DevicePath, GENERIC_READ | GENERIC_WRITE,
                                 FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
                                 FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED, nullptr);
            if (m_file == INVALID_HANDLE_VALUE) continue;
            if (!WinUsb_Initialize(m_file, &m_usb)) { Close(); continue; }
            result = FindCommonIsoPipes();
            if (SUCCEEDED(result)) {
                const HRESULT calibrationHr = FetchDepthCalibration(m_depthCalibration);
                if (FAILED(calibrationHr)) {
                    LogHr(L"Metric depth calibration query failed; scanner depth will be invalid", calibrationHr);
                    m_depthCalibration = DepthCalibration{};
                }
                break;
            }
            Close();
        }
        SetupDiDestroyDeviceInfoList(info);
        return result;
    }

    HRESULT Run(SharedFramePublisher& publisher, ScannerPortServer& scannerPort) {
        if (!m_usb || !m_video.maxBytes || !m_depth.maxBytes) return E_HANDLE;

        // virtual camera is RGB-only. Endpoint 0x81 is one exclusive video engine:
        // it runs RGB by default and switches to IR only while a scanner client explicitly
        // requests IR. Endpoint 0x82 carries Depth independently and can run concurrently
        // with the selected 0x81 mode. FaceTracker/accelerometer/tilt stay on Windows RGB.
        FrameConversionWorker rgbWorker(publisher, scannerPort, DepthCalibration{},
                                        ScannerPort::StreamMode::Rgb, kRgbRawFrameBytes);
        FrameConversionWorker irWorker(publisher, scannerPort, DepthCalibration{},
                                       ScannerPort::StreamMode::Infrared, kIrRawFrameBytes);
        FrameConversionWorker depthWorker(publisher, scannerPort, m_depthCalibration,
                                          ScannerPort::StreamMode::Depth, kDepthRawFrameBytes);
        HRESULT hr = rgbWorker.Start();
        if (FAILED(hr)) return hr;
        hr = irWorker.Start();
        if (FAILED(hr)) { rgbWorker.Stop(); return hr; }
        hr = depthWorker.Start();
        if (FAILED(hr)) { irWorker.Stop(); rgbWorker.Stop(); return hr; }

        m_sessionRun.store(true, std::memory_order_release);
        std::thread depthThread;
        try {
            depthThread = std::thread([this, &scannerPort, &depthWorker] {
                DepthLoop(scannerPort, depthWorker);
            });
        } catch (const std::system_error&) {
            m_sessionRun.store(false, std::memory_order_release);
            depthWorker.Stop(); irWorker.Stop(); rgbWorker.Stop();
            return E_OUTOFMEMORY;
        }

        hr = StreamVideo(publisher, scannerPort, rgbWorker, irWorker);
        m_sessionRun.store(false, std::memory_order_release);
        if (depthThread.joinable()) depthThread.join();

        (void)SetProjector(false);
        (void)StopVideoCapture();
        depthWorker.Stop();
        irWorker.Stop();
        rgbWorker.Stop();
        return hr;
    }

private:
    struct IsoSlot { OVERLAPPED ov{}; HANDLE event = nullptr; bool pending = false; };
    struct PipeGeometry { UCHAR pipeId = 0; ULONG maxBytes = 0; UCHAR interval = 0; };

    HANDLE m_file = INVALID_HANDLE_VALUE;
    WINUSB_INTERFACE_HANDLE m_usb = nullptr;
    PipeGeometry m_video{};
    PipeGeometry m_depth{};
    uint16_t m_tag = 0;
    std::mutex m_controlLock;
    std::atomic<bool> m_sessionRun{false};
    bool m_projectorOn = false; // guarded by m_controlLock
    DepthCalibration m_depthCalibration{};

    bool SessionRunning() const noexcept { return g_run.load() && m_sessionRun.load(std::memory_order_acquire); }

    void Close() {
        if (m_usb) {
            (void)SetProjector(false);
            WinUsb_Free(m_usb);
            m_usb = nullptr;
        }
        if (m_file != INVALID_HANDLE_VALUE) { CloseHandle(m_file); m_file = INVALID_HANDLE_VALUE; }
        m_video = PipeGeometry{};
        m_depth = PipeGeometry{};
        m_tag = 0;
        m_projectorOn = false;
        m_depthCalibration = DepthCalibration{};
    }

    static void CloseSlots(std::vector<IsoSlot>& slots) {
        for (auto& slot : slots) {
            if (slot.event) CloseHandle(slot.event);
            slot.event = nullptr;
            slot.pending = false;
        }
    }

    HRESULT FindCommonIsoPipes() {
        // Both isochronous endpoints must be available under the same alternate
        // setting so WinUSB can keep the video and Depth endpoints registered concurrently.
        for (UCHAR alt = 0; alt < 16; ++alt) {
            USB_INTERFACE_DESCRIPTOR iface{};
            if (!WinUsb_QueryInterfaceSettings(m_usb, alt, &iface)) {
                const DWORD e = GetLastError();
                if (e == ERROR_NO_MORE_ITEMS || e == ERROR_INVALID_PARAMETER) break;
                continue;
            }
            PipeGeometry video{kVideoIn, 0, 0};
            PipeGeometry depth{kDepthIn, 0, 0};
            for (UCHAR i = 0; i < iface.bNumEndpoints; ++i) {
                WINUSB_PIPE_INFORMATION_EX ex{};
                if (WinUsb_QueryPipeEx(m_usb, alt, i, &ex)) {
                    if (ex.PipeType != UsbdPipeTypeIsochronous) continue;
                    PipeGeometry* target = ex.PipeId == kVideoIn ? &video : (ex.PipeId == kDepthIn ? &depth : nullptr);
                    if (!target) continue;
                    target->maxBytes = ex.MaximumBytesPerInterval ? ex.MaximumBytesPerInterval : ex.MaximumPacketSize;
                    target->interval = ex.Interval;
                } else {
                    WINUSB_PIPE_INFORMATION basic{};
                    if (!WinUsb_QueryPipe(m_usb, alt, i, &basic) || basic.PipeType != UsbdPipeTypeIsochronous) continue;
                    PipeGeometry* target = basic.PipeId == kVideoIn ? &video : (basic.PipeId == kDepthIn ? &depth : nullptr);
                    if (!target) continue;
                    target->maxBytes = basic.MaximumPacketSize;
                    target->interval = basic.Interval;
                }
            }
            if (!video.maxBytes || !video.interval || !depth.maxBytes || !depth.interval) continue;
            if (alt != 0 && !WinUsb_SetCurrentAlternateSetting(m_usb, alt)) return HrLastError();
            m_video = video;
            m_depth = depth;
            return S_OK;
        }
        return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
    }

    static bool ComputeIsoGeometry(const PipeGeometry& pipe, ULONG& transferBytes, ULONG& packetCount) {
        if (!pipe.maxBytes || !pipe.interval || pipe.interval > 8 || (8 % pipe.interval) != 0) return false;
        const ULONG packetsPerFrame = 8 / pipe.interval;
        packetCount = kIsoPacketsPerTransfer;
        if ((packetCount % packetsPerFrame) != 0) return false;
        if (pipe.maxBytes > std::numeric_limits<ULONG>::max() / packetCount) return false;
        transferBytes = pipe.maxBytes * packetCount;
        return true;
    }

    HRESULT SendCommandUnlocked(uint16_t command, const void* payload, USHORT payloadBytes,
                                void* reply, USHORT replyCapacity, USHORT& replyBytes) {
        replyBytes = 0;
        if ((payloadBytes & 1u) || payloadBytes > 0x3F8u) return E_INVALIDARG;
        std::array<uint8_t, 0x400> out{};
        CameraCommandHeader h{{0x47,0x4d}, static_cast<uint16_t>(payloadBytes/2), command, m_tag};
        std::memcpy(out.data(), &h, sizeof(h));
        if (payloadBytes) std::memcpy(out.data()+sizeof(h), payload, payloadBytes);
        WINUSB_SETUP_PACKET setupOut{0x40,0,0,0,static_cast<USHORT>(sizeof(h)+payloadBytes)};
        ULONG sent = 0;
        if (!WinUsb_ControlTransfer(m_usb, setupOut, out.data(), setupOut.Length, &sent, nullptr)) return HrLastError();
        if (sent != setupOut.Length) return HRESULT_FROM_WIN32(ERROR_WRITE_FAULT);

        std::array<uint8_t, 0x200> in{};
        ULONG got = 0;
        const ULONGLONG deadline = GetTickCount64() + kControlReplyDeadlineMs;
        for (;;) {
            WINUSB_SETUP_PACKET setupIn{0xC0,0,0,0,static_cast<USHORT>(in.size())};
            if (!WinUsb_ControlTransfer(m_usb, setupIn, in.data(), static_cast<ULONG>(in.size()), &got, nullptr))
                return HrLastError();
            if (got != 0 && got != in.size()) break;
            if (GetTickCount64() >= deadline) return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
            Sleep(1);
        }
        if (got < sizeof(CameraCommandHeader)) return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        CameraCommandHeader rh{};
        std::memcpy(&rh, in.data(), sizeof(rh));
        if (rh.magic[0] != 0x52 || rh.magic[1] != 0x42 || rh.command != command || rh.tag != m_tag)
            return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        const ULONG dataBytes = got - sizeof(rh);
        if (rh.lengthWords != dataBytes/2 || dataBytes > replyCapacity)
            return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        if (dataBytes && reply) std::memcpy(reply, in.data()+sizeof(rh), dataBytes);
        replyBytes = static_cast<USHORT>(dataBytes);
        ++m_tag;
        return S_OK;
    }

    HRESULT WriteRegisterUnlocked(uint16_t reg, uint16_t value) {
        uint16_t cmd[2]{reg,value};
        uint16_t reply[2]{};
        USHORT bytes = 0;
        HRESULT hr = SendCommandUnlocked(0x03, cmd, sizeof(cmd), reply, sizeof(reply), bytes);
        if (FAILED(hr)) return hr;
        return bytes < sizeof(uint16_t) ? HRESULT_FROM_WIN32(ERROR_INVALID_DATA) : S_OK;
    }

    HRESULT SetProjector(bool on) {
        std::lock_guard<std::mutex> guard(m_controlLock);
        if (!m_usb) return E_HANDLE;
        if (m_projectorOn == on) return S_OK;
        const HRESULT hr = WriteRegisterUnlocked(0x06, on ? 0x02 : 0x00);
        if (SUCCEEDED(hr)) m_projectorOn = on;
        return hr;
    }

    HRESULT ConfigureVideoMode(ScannerPort::StreamMode mode) {
        if (mode != ScannerPort::StreamMode::Rgb && mode != ScannerPort::StreamMode::Infrared) return E_INVALIDARG;
        std::lock_guard<std::mutex> guard(m_controlLock);
        HRESULT hr = S_OK;
        if (mode == ScannerPort::StreamMode::Rgb) {
            hr = WriteRegisterUnlocked(0x0c, 0x00);
            if (SUCCEEDED(hr)) hr = WriteRegisterUnlocked(0x0d, 0x01);
            if (SUCCEEDED(hr)) hr = WriteRegisterUnlocked(0x0e, 0x1e);
            if (SUCCEEDED(hr)) hr = WriteRegisterUnlocked(0x05, 0x01);
            if (SUCCEEDED(hr)) hr = WriteRegisterUnlocked(0x47, 0x00);
        } else {
            hr = WriteRegisterUnlocked(0x19, 0x00);
            if (SUCCEEDED(hr)) hr = WriteRegisterUnlocked(0x1a, 0x01);
            if (SUCCEEDED(hr)) hr = WriteRegisterUnlocked(0x1b, 0x1e);
            if (SUCCEEDED(hr)) hr = WriteRegisterUnlocked(0x105, 0x00);
            if (SUCCEEDED(hr)) hr = WriteRegisterUnlocked(0x05, 0x03);
            if (SUCCEEDED(hr)) hr = WriteRegisterUnlocked(0x48, 0x00);
        }
        return hr;
    }

    HRESULT StopVideoCapture() {
        std::lock_guard<std::mutex> guard(m_controlLock);
        return m_usb ? WriteRegisterUnlocked(0x05, 0x00) : E_HANDLE;
    }

    HRESULT ConfigureDepthPath() {
        std::lock_guard<std::mutex> guard(m_controlLock);
        // Every depth endpoint session starts from a known OFF state.  The old
        // recovery path trusted m_projectorOn, so a timed-out session could leave
        // software believing the depth engine was already started and the next
        // retry would never perform a real OFF -> ON re-arm.
        HRESULT hr = WriteRegisterUnlocked(0x105, 0x00);
        if (SUCCEEDED(hr)) {
            hr = WriteRegisterUnlocked(0x06, 0x00);
            if (SUCCEEDED(hr)) m_projectorOn = false;
        }
        if (SUCCEEDED(hr)) hr = WriteRegisterUnlocked(0x12, 0x03);
        if (SUCCEEDED(hr)) hr = WriteRegisterUnlocked(0x13, 0x01);
        if (SUCCEEDED(hr)) hr = WriteRegisterUnlocked(0x14, 0x1e);
        if (SUCCEEDED(hr)) hr = WriteRegisterUnlocked(0x17, 0x00);
        return hr;
    }

    HRESULT FetchDepthCalibration(DepthCalibration& calibration) {
        std::lock_guard<std::mutex> guard(m_controlLock);
        calibration = DepthCalibration{};
        uint16_t fixedRequest[5]{};
        std::array<uint8_t, 0x200> fixedReply{};
        USHORT fixedBytes = 0;
        HRESULT hr = SendCommandUnlocked(0x04, fixedRequest, sizeof(fixedRequest),
                                         fixedReply.data(), static_cast<USHORT>(fixedReply.size()), fixedBytes);
        if (FAILED(hr)) return hr;
        if (fixedBytes < 94u + 4u * sizeof(float)) return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        float values[4]{};
        std::memcpy(values, fixedReply.data() + 94, sizeof(values));
        const float emitter = values[0];
        const float referenceDistance = values[2];
        const float referencePixelSize = values[3];
        if (!std::isfinite(emitter) || !std::isfinite(referenceDistance) || !std::isfinite(referencePixelSize) ||
            emitter <= 0.0f || referenceDistance <= 0.0f || referencePixelSize <= 0.0f)
            return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);

        uint16_t shiftRequest[5]{0x0000, 0x0000, 0x0001, 0x001e, 0x0000};
        std::array<uint8_t, 8> shiftReply{};
        USHORT shiftBytes = 0;
        hr = SendCommandUnlocked(0x16, shiftRequest, sizeof(shiftRequest),
                                 shiftReply.data(), static_cast<USHORT>(shiftReply.size()), shiftBytes);
        if (FAILED(hr)) return hr;
        if (shiftBytes < 4) return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        uint16_t shift = 0;
        std::memcpy(&shift, shiftReply.data() + 2, sizeof(shift));
        if (!shift) return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);

        calibration.constShift = static_cast<double>(shift);
        calibration.dcmosEmitterDist = emitter;
        calibration.referenceDistance = referenceDistance;
        calibration.referencePixelSize = referencePixelSize;
        calibration.rawToMm.fill(0);
        constexpr double kParameterCoefficient = 4.0;
        constexpr double kShiftScale = 10.0;
        constexpr double kS2dConstOffset = 0.375;
        for (uint32_t raw = 0; raw < 2047u; ++raw) {
            const double fixedRefX = ((static_cast<double>(raw) -
                                      (kParameterCoefficient * calibration.constShift)) /
                                     kParameterCoefficient) - kS2dConstOffset;
            const double metric = fixedRefX * static_cast<double>(referencePixelSize);
            const double denominator = static_cast<double>(emitter) - metric;
            if (std::abs(denominator) < 1e-9) continue;
            const double mm = kShiftScale * ((metric * static_cast<double>(referenceDistance) / denominator) +
                                             static_cast<double>(referenceDistance));
            if (std::isfinite(mm) && mm >= 1.0 && mm <= 10000.0)
                calibration.rawToMm[raw] = static_cast<uint16_t>(std::lround(mm));
        }
        calibration.rawToMm[2047] = 0;
        calibration.valid = true;
        return S_OK;
    }

    HRESULT StreamVideo(SharedFramePublisher& publisher,
                        ScannerPortServer& scannerPort,
                        FrameConversionWorker& rgbWorker,
                        FrameConversionWorker& irWorker) {
        ULONG transferBytes = 0, packetCount = 0;
        if (!ComputeIsoGeometry(m_video, transferBytes, packetCount)) return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        if (transferBytes > std::numeric_limits<ULONG>::max() / kIsoQueueDepth)
            return HRESULT_FROM_WIN32(ERROR_ARITHMETIC_OVERFLOW);
        const ULONG totalBytes = transferBytes * kIsoQueueDepth;
        std::vector<uint8_t> io(totalBytes);
        std::vector<USBD_ISO_PACKET_DESCRIPTOR> desc(static_cast<size_t>(packetCount) * kIsoQueueDepth);
        std::vector<IsoSlot> slots(kIsoQueueDepth);
        for (auto& slot : slots) {
            slot.event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
            if (!slot.event) { CloseSlots(slots); return HrLastError(); }
            slot.ov.hEvent = slot.event;
        }
        WINUSB_ISOCH_BUFFER_HANDLE iso = nullptr;
        if (!WinUsb_RegisterIsochBuffer(m_usb, m_video.pipeId, io.data(), totalBytes, &iso)) {
            HRESULT hr = HrLastError(); CloseSlots(slots); return hr;
        }
        auto queueRead = [&](ULONG index, BOOL continuous) -> bool {
            IsoSlot& slot = slots[index];
            auto* p = desc.data() + static_cast<size_t>(index) * packetCount;
            std::fill(p, p + packetCount, USBD_ISO_PACKET_DESCRIPTOR{});
            ResetEvent(slot.event);
            slot.ov = OVERLAPPED{}; slot.ov.hEvent = slot.event;
            BOOL ok = WinUsb_ReadIsochPipeAsap(iso, index * transferBytes, transferBytes,
                                               continuous, packetCount, p, &slot.ov);
            if (!ok && GetLastError() != ERROR_IO_PENDING) return false;
            slot.pending = true;
            return true;
        };
        HRESULT result = S_OK;
        for (ULONG i = 0; i < kIsoQueueDepth; ++i) if (!queueRead(i, i ? TRUE : FALSE)) { result = HrLastError(); break; }
        if (SUCCEEDED(result)) result = ConfigureVideoMode(ScannerPort::StreamMode::Rgb);

        FrameAssembler rgbAssembler(kRgbRawFrameBytes, kVideoPacketBytes, kVideoFlag);
        FrameAssembler irAssembler(kIrRawFrameBytes, kVideoPacketBytes, kVideoFlag);
        if (!rgbAssembler.IsValid() || !irAssembler.IsValid()) result = HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        ScannerPort::StreamMode activeMode = ScannerPort::StreamMode::Rgb;
        std::vector<uint8_t> completeRaw;
        uint64_t completeCaptureTickMs = 0;
        ULONG next = 0;
        int timeouts = 0;
        ULONGLONG lastScannerActivity = 0;

        Log(L"Kinect video endpoint 0x81 active: request-selected RGB or IR; RGB is the default virtual camera mode.");
        while (SUCCEEDED(result) && SessionRunning()) {
            const ULONGLONG now = GetTickCount64();
            if (scannerPort.ClientActive() && now - lastScannerActivity >= kScannerActivityHeartbeatMs) {
                NotifyBrokerScannerActivity(); lastScannerActivity = now;
            }

            // Scanner protocol v1 rejects RGB+IR subscriptions. The physical 0x81
            // engine therefore has exactly one requested mode at a time. When no IR
            // client exists, remain in RGB so virtual camera keeps its normal source.
            const ScannerPort::StreamMode requestedVideoMode =
                scannerPort.Wants(ScannerPort::StreamMode::Infrared)
                    ? ScannerPort::StreamMode::Infrared
                    : ScannerPort::StreamMode::Rgb;
            if (requestedVideoMode != activeMode) {
                if (requestedVideoMode == ScannerPort::StreamMode::Infrared) {
                    // IR owns the single physical video engine. Invalidate the shared RGB
                    // transport before reprogramming endpoint 0x81 so IP/virtual consumers
                    // never mistake the last RGB frame for a live source.
                    publisher.SetOnline(false);
                    result = SetProjector(true);
                    if (FAILED(result)) break;
                }
                result = ConfigureVideoMode(requestedVideoMode);
                if (FAILED(result)) break;
                activeMode = requestedVideoMode;
                rgbAssembler.Reset();
                irAssembler.Reset();
                if (activeMode == ScannerPort::StreamMode::Rgb && !scannerPort.NeedsProjector()) {
                    (void)SetProjector(false);
                }
            }

            IsoSlot& slot = slots[next];
            HANDLE waitHandles[2]{g_stopEvent, slot.event};
            const DWORD wait = WaitForMultipleObjects(2, waitHandles, FALSE, kIsoWaitMs);
            if (wait == WAIT_OBJECT_0) break;
            if (wait == WAIT_TIMEOUT) { if (++timeouts >= kMaxIsoTimeouts) result = HRESULT_FROM_WIN32(ERROR_TIMEOUT); continue; }
            timeouts = 0;
            if (wait != WAIT_OBJECT_0 + 1) { result = HrLastError(); break; }
            DWORD ignored = 0;
            if (!WinUsb_GetOverlappedResult(m_usb, &slot.ov, &ignored, FALSE)) {
                const DWORD e = GetLastError(); slot.pending = false;
                if (e == ERROR_OPERATION_ABORTED && !SessionRunning()) break;
                result = HRESULT_FROM_WIN32(e); break;
            }
            slot.pending = false;
            const size_t slotBegin = static_cast<size_t>(next) * transferBytes;
            const size_t slotEnd = slotBegin + transferBytes;
            auto* packetDesc = desc.data() + static_cast<size_t>(next) * packetCount;
            bool haveFrame = false;
            for (ULONG i = 0; i < packetCount; ++i) {
                const auto& p = packetDesc[i];
                if (p.Status != USBD_STATUS_SUCCESS || p.Length < sizeof(VideoPacketHeader)) continue;
                const size_t packetOffset = static_cast<size_t>(p.Offset), packetLength = static_cast<size_t>(p.Length);
                if (packetOffset > transferBytes || packetLength > transferBytes - packetOffset) continue;
                const size_t packetBegin = slotBegin + packetOffset;
                if (packetBegin < slotBegin || packetBegin > slotEnd || packetLength > slotEnd - packetBegin) continue;
                FrameAssembler& assembler = activeMode == ScannerPort::StreamMode::Rgb ? rgbAssembler : irAssembler;
                if (assembler.Push(io.data() + packetBegin, p.Length, completeRaw, completeCaptureTickMs)) haveFrame = true;
            }
            if (!queueRead(next, TRUE)) { result = HrLastError(); break; }
            next = (next + 1) % kIsoQueueDepth;

            if (haveFrame) {
                if (activeMode == ScannerPort::StreamMode::Rgb && completeRaw.size() == kRgbRawFrameBytes) {
                    // RGB always feeds virtual camera; ScannerPortServer publishes it only
                    // when the current client explicitly subscribed to RGB.
                    rgbWorker.Submit(completeRaw, completeCaptureTickMs);
                } else if (activeMode == ScannerPort::StreamMode::Infrared && completeRaw.size() == kIrRawFrameBytes) {
                    irWorker.Submit(completeRaw, completeCaptureTickMs);
                }
            }
        }

        WinUsb_AbortPipe(m_usb, m_video.pipeId);
        for (auto& slot : slots) if (slot.pending) {
            DWORD ignored = 0; (void)WinUsb_GetOverlappedResult(m_usb, &slot.ov, &ignored, TRUE); slot.pending = false;
        }
        if (!WinUsb_UnregisterIsochBuffer(iso) && SUCCEEDED(result)) result = HrLastError();
        CloseSlots(slots);
        return result;
    }

    void DepthLoop(ScannerPortServer& scannerPort, FrameConversionWorker& depthWorker) {
        while (SessionRunning()) {
            if (!scannerPort.NeedsProjector()) {
                (void)SetProjector(false);
                Sleep(kScannerStatePollMs);
                continue;
            }
            if (!scannerPort.Wants(ScannerPort::StreamMode::Depth)) {
                // IR alone needs illumination but does not need endpoint 0x82.
                Sleep(kScannerStatePollMs);
                continue;
            }
            const HRESULT hr = StreamDepthSession(scannerPort, depthWorker);
            if (FAILED(hr) && SessionRunning() && scannerPort.Wants(ScannerPort::StreamMode::Depth)) {
                LogHr(L"Depth endpoint recovery; forcing OFF/ON re-arm", hr);
                Sleep(50);
            }
        }
        (void)SetProjector(false);
    }

    HRESULT StreamDepthSession(ScannerPortServer& scannerPort, FrameConversionWorker& depthWorker) {
        HRESULT result = ConfigureDepthPath();
        if (FAILED(result)) return result;

        ULONG transferBytes = 0, packetCount = 0;
        if (!ComputeIsoGeometry(m_depth, transferBytes, packetCount)) return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        if (transferBytes > std::numeric_limits<ULONG>::max() / kIsoQueueDepth)
            return HRESULT_FROM_WIN32(ERROR_ARITHMETIC_OVERFLOW);
        const ULONG totalBytes = transferBytes * kIsoQueueDepth;
        std::vector<uint8_t> io(totalBytes);
        std::vector<USBD_ISO_PACKET_DESCRIPTOR> desc(static_cast<size_t>(packetCount) * kIsoQueueDepth);
        std::vector<IsoSlot> slots(kIsoQueueDepth);
        for (auto& slot : slots) {
            slot.event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
            if (!slot.event) { CloseSlots(slots); return HrLastError(); }
            slot.ov.hEvent = slot.event;
        }
        WINUSB_ISOCH_BUFFER_HANDLE iso = nullptr;
        if (!WinUsb_RegisterIsochBuffer(m_usb, m_depth.pipeId, io.data(), totalBytes, &iso)) {
            HRESULT hr = HrLastError(); CloseSlots(slots); return hr;
        }
        auto queueRead = [&](ULONG index, BOOL continuous) -> bool {
            IsoSlot& slot = slots[index];
            auto* p = desc.data() + static_cast<size_t>(index) * packetCount;
            std::fill(p, p + packetCount, USBD_ISO_PACKET_DESCRIPTOR{});
            ResetEvent(slot.event); slot.ov = OVERLAPPED{}; slot.ov.hEvent = slot.event;
            BOOL ok = WinUsb_ReadIsochPipeAsap(iso, index * transferBytes, transferBytes,
                                               continuous, packetCount, p, &slot.ov);
            if (!ok && GetLastError() != ERROR_IO_PENDING) return false;
            slot.pending = true; return true;
        };
        for (ULONG i = 0; i < kIsoQueueDepth; ++i) if (!queueRead(i, i ? TRUE : FALSE)) { result = HrLastError(); break; }
        FrameAssembler assembler(kDepthRawFrameBytes, kDepthPacketBytes, kDepthFlag);
        if (!assembler.IsValid()) result = HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        // Arm USB reads before enabling depth. This prevents the first packets
        // after register 0x06=0x02 from being lost and mirrors the proven
        // libfreenect start ordering.
        if (SUCCEEDED(result)) result = SetProjector(true);
        std::vector<uint8_t> completeRaw;
        uint64_t completeCaptureTickMs = 0;
        ULONG next = 0;
        int timeouts = 0;

        while (SUCCEEDED(result) && SessionRunning() && scannerPort.Wants(ScannerPort::StreamMode::Depth)) {
            IsoSlot& slot = slots[next];
            HANDLE waitHandles[2]{g_stopEvent, slot.event};
            const DWORD wait = WaitForMultipleObjects(2, waitHandles, FALSE, kIsoWaitMs);
            if (wait == WAIT_OBJECT_0) break;
            if (wait == WAIT_TIMEOUT) { if (++timeouts >= kMaxIsoTimeouts) result = HRESULT_FROM_WIN32(ERROR_TIMEOUT); continue; }
            timeouts = 0;
            if (wait != WAIT_OBJECT_0 + 1) { result = HrLastError(); break; }
            DWORD ignored = 0;
            if (!WinUsb_GetOverlappedResult(m_usb, &slot.ov, &ignored, FALSE)) {
                const DWORD e = GetLastError(); slot.pending = false;
                if (e == ERROR_OPERATION_ABORTED && !SessionRunning()) break;
                result = HRESULT_FROM_WIN32(e); break;
            }
            slot.pending = false;
            const size_t slotBegin = static_cast<size_t>(next) * transferBytes;
            const size_t slotEnd = slotBegin + transferBytes;
            auto* packetDesc = desc.data() + static_cast<size_t>(next) * packetCount;
            bool haveFrame = false;
            for (ULONG i = 0; i < packetCount; ++i) {
                const auto& p = packetDesc[i];
                if (p.Status != USBD_STATUS_SUCCESS || p.Length < sizeof(VideoPacketHeader)) continue;
                const size_t packetOffset = static_cast<size_t>(p.Offset), packetLength = static_cast<size_t>(p.Length);
                if (packetOffset > transferBytes || packetLength > transferBytes - packetOffset) continue;
                const size_t packetBegin = slotBegin + packetOffset;
                if (packetBegin < slotBegin || packetBegin > slotEnd || packetLength > slotEnd - packetBegin) continue;
                if (assembler.Push(io.data() + packetBegin, p.Length, completeRaw, completeCaptureTickMs)) haveFrame = true;
            }
            if (!queueRead(next, TRUE)) { result = HrLastError(); break; }
            next = (next + 1) % kIsoQueueDepth;
            if (haveFrame && completeRaw.size() == kDepthRawFrameBytes &&
                scannerPort.Wants(ScannerPort::StreamMode::Depth)) depthWorker.Submit(completeRaw, completeCaptureTickMs);
        }

        WinUsb_AbortPipe(m_usb, m_depth.pipeId);
        for (auto& slot : slots) if (slot.pending) {
            DWORD ignored = 0; (void)WinUsb_GetOverlappedResult(m_usb, &slot.ov, &ignored, TRUE); slot.pending = false;
        }
        if (!WinUsb_UnregisterIsochBuffer(iso) && SUCCEEDED(result)) result = HrLastError();
        CloseSlots(slots);

        // A failed endpoint session must be physically re-armed on the next
        // retry.  Leaving the projector latched after a timeout was the main
        // reason recovery could stay in an endless depth-wait state.
        if (FAILED(result) || !scannerPort.NeedsProjector()) (void)SetProjector(false);
        return result;
    }
};


void ReportService(DWORD state, DWORD error = NO_ERROR, DWORD hint = 0) {
    if (!g_statusHandle) return;
    g_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    g_status.dwCurrentState = state;
    g_status.dwWin32ExitCode = error;
    g_status.dwWaitHint = hint;
    g_status.dwControlsAccepted = (state == SERVICE_RUNNING)
        ? (SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN) : 0;
    SetServiceStatus(g_statusHandle, &g_status);
}

DWORD WINAPI ServiceControl(DWORD control, DWORD, void*, void*) {
    if (control == SERVICE_CONTROL_STOP || control == SERVICE_CONTROL_SHUTDOWN) {
        ReportService(SERVICE_STOP_PENDING, NO_ERROR, 5000);
        g_run.store(false);
        if (g_stopEvent) SetEvent(g_stopEvent);
        return NO_ERROR;
    }
    return NO_ERROR;
}

int RunBridgeLoop() {
    SharedFramePublisher publisher;
    HRESULT hr = publisher.Open();
    if (FAILED(hr)) { LogHr(L"Shared frame mapping failed", hr); return 10; }
    ScannerPortServer scannerPort;
    hr = scannerPort.Start();
    if (FAILED(hr)) { LogHr(L"Scanner port failed", hr); return 11; }

    while (g_run.load()) {
        CameraUsbTransport camera;
        hr = camera.Open();
        if (FAILED(hr)) {
            publisher.SetOnline(false);
            if (!CameraInterfacePresent()) break;
            if (WaitForSingleObject(g_stopEvent, 1000) == WAIT_OBJECT_0) break;
            continue;
        }
        hr = camera.Run(publisher, scannerPort);
        publisher.SetOnline(false);
        if (!g_run.load()) break;
        if (!CameraInterfacePresent()) {
            Log(L"Physical Kinect camera removed; waiting for SCM arrival trigger.");
            break;
        }
        LogHr(L"CameraBridge transport ended while device is present; reopening both image endpoints", hr);
        if (WaitForSingleObject(g_stopEvent, 500) == WAIT_OBJECT_0) break;
    }
    publisher.SetOnline(false);
    scannerPort.Stop();
    return 0;
}

void WINAPI ServiceMain(DWORD, LPWSTR*) {
    g_statusHandle = RegisterServiceCtrlHandlerExW(L"Kinect360RemoldCameraBridge", ServiceControl, nullptr);
    if (!g_statusHandle) return;
    ReportService(SERVICE_START_PENDING, NO_ERROR, 5000);
    g_stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!g_stopEvent) { ReportService(SERVICE_STOPPED, GetLastError()); return; }
    g_run.store(true);
    ReportService(SERVICE_RUNNING);
    const int rc = RunBridgeLoop();
    ReportService(SERVICE_STOP_PENDING, NO_ERROR, 2000);
    CloseHandle(g_stopEvent); g_stopEvent = nullptr;
    ReportService(SERVICE_STOPPED, rc ? ERROR_GEN_FAILURE : NO_ERROR);
}

BOOL WINAPI ConsoleCtrl(DWORD) {
    g_run.store(false);
    if (g_stopEvent) SetEvent(g_stopEvent);
    return TRUE;
}
} // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc > 1 && _wcsicmp(argv[1], L"--console") == 0) {
        g_stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!g_stopEvent) return 2;
        SetConsoleCtrlHandler(ConsoleCtrl, TRUE);
        g_run.store(true);
        int rc = RunBridgeLoop();
        CloseHandle(g_stopEvent); g_stopEvent = nullptr;
        return rc;
    }
    SERVICE_TABLE_ENTRYW table[] = {
        {const_cast<LPWSTR>(L"Kinect360RemoldCameraBridge"), ServiceMain},
        {nullptr, nullptr}
    };
    if (!StartServiceCtrlDispatcherW(table)) return static_cast<int>(GetLastError());
    return 0;
}
