#ifndef NOMINMAX
#define NOMINMAX
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <setupapi.h>
#include <sddl.h>
#include <usb.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <mmreg.h>
#include <functiondiscoverykeys_devpkey.h>
#include <propsys.h>
#include <propvarutil.h>
#include <wrl/client.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <cwctype>
#include <deque>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <system_error>
#include <thread>
#include <vector>

#include "Kinect360RemoldAudioPort.h"
#include "Kinect360RemoldAudioFirmware.generated.h"
#include "Kinect360RemoldWinUsb.h"
#include "Kinect360RemoldHardwareProfile.h"

#pragma comment(lib, "setupapi.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "uuid.lib")
#pragma comment(lib, "propsys.lib")

namespace {
namespace AudioPort = Kinect360RemoldAudioPort;
namespace Usb = Kinect360RemoldWinUsb;
namespace Hardware = Kinect360RemoldHardware;
using Microsoft::WRL::ComPtr;

constexpr UCHAR kBootOutEndpoint = Hardware::Audio::kBootOutEndpoint;
constexpr UCHAR kBootInEndpoint = Hardware::Audio::kBootInEndpoint;
constexpr DWORD kAudioRetryMs = 500;
constexpr DWORD kPostFirmwareDelayMs = 1500;
constexpr DWORD kWasapiWaitMs = 500;
constexpr REFERENCE_TIME kWasapiBufferDuration = 1000000; // 100 ms
constexpr size_t kMaxAudioPortQueueFrames = Hardware::Audio::kPortQueueFrames;
constexpr uint32_t kUacLoadAddress = 0x00080000u;
constexpr uint32_t kUacEntryAddress = 0x00080030u;
constexpr uint32_t kUacInitialTag = 1u;
constexpr uint32_t kUacProbeBytes = 0x60u;
constexpr uint32_t kUacProbeAddress = 0x15u;

constexpr GUID kSubTypePcm = {0x00000001, 0x0000, 0x0010, {0x80,0x00,0x00,0xaa,0x00,0x38,0x9b,0x71}};
constexpr GUID kSubTypeFloat = {0x00000003, 0x0000, 0x0010, {0x80,0x00,0x00,0xaa,0x00,0x38,0x9b,0x71}};

#pragma pack(push, 1)
struct BootCommand {
    uint32_t magic;
    uint32_t tag;
    uint32_t bytes;
    uint32_t command;
    uint32_t address;
    uint32_t unknown;
};
struct BootStatus {
    uint32_t magic;
    uint32_t tag;
    uint32_t status;
};
#pragma pack(pop)
static_assert(sizeof(BootCommand) == 24, "boot command ABI");
static_assert(sizeof(BootStatus) == 12, "boot status ABI");

std::atomic<bool> gRun{true};

HRESULT HrLastError() {
    const DWORD error = GetLastError();
    return HRESULT_FROM_WIN32(error ? error : ERROR_GEN_FAILURE);
}

bool TryReadEnvironmentPath(const wchar_t* name, std::wstring& value) {
    value.clear();
    if (!name || !*name) return false;
    const DWORD required = GetEnvironmentVariableW(name, nullptr, 0);
    if (required == 0) return false;
    std::vector<wchar_t> buffer(static_cast<size_t>(required));
    const DWORD written = GetEnvironmentVariableW(name, buffer.data(), required);
    if (written == 0 || written >= required) return false;
    value.assign(buffer.data(), written);
    return !value.empty();
}

bool TryResolveCommonDataDirectory(std::wstring& directory) {
    if (!TryReadEnvironmentPath(L"ProgramData", directory) &&
        !TryReadEnvironmentPath(L"ALLUSERSPROFILE", directory)) {
        directory.clear();
        return false;
    }
    directory += L"\\";
    directory += AudioPort::kDiagnosticsDirectory;
    return true;
}

std::string NarrowForDiagnostic(const std::wstring& value) {
    std::string result;
    result.reserve(value.size());
    for (wchar_t ch : value) result.push_back(ch >= 0x20 && ch <= 0x7e ? static_cast<char>(ch) : '?');
    return result;
}

class AudioDiagnostics {
public:
    std::atomic<uint64_t> usbOpenAttempts{0};
    std::atomic<uint64_t> bootSessions{0};
    std::atomic<uint64_t> runtimeSessions{0};
    std::atomic<uint64_t> firmwareUploads{0};
    std::atomic<uint64_t> firmwareFailures{0};
    std::atomic<uint64_t> wasapiEndpointSearches{0};
    std::atomic<uint64_t> wasapiOpenFailures{0};
    std::atomic<uint64_t> wasapiPackets{0};
    std::atomic<uint64_t> wasapiFrames{0};
    std::atomic<uint64_t> wasapiSilentFrames{0};
    std::atomic<uint64_t> wasapiDiscontinuities{0};
    std::atomic<uint64_t> publishedFrames{0};
    std::atomic<uint64_t> pipeClients{0};
    std::atomic<uint64_t> pipeFrames{0};
    std::atomic<uint64_t> captureRate{0};
    std::atomic<uint64_t> captureChannels{0};
    std::atomic<uint64_t> captureBits{0};
    std::atomic<uint64_t> captureFormatTag{0};

    void SetEndpointName(const std::wstring& value) {
        std::lock_guard<std::mutex> guard(m_lock);
        m_endpointName = NarrowForDiagnostic(value);
    }

    void SetStage(const char* stage, DWORD error = ERROR_SUCCESS, const char* detail = "") {
        {
            std::lock_guard<std::mutex> guard(m_lock);
            m_stage = stage ? stage : "unknown";
            m_detail = detail ? detail : "";
            m_lastError = error;
        }
        Write(true);
    }

    void Write(bool force = false) {
        const ULONGLONG now = GetTickCount64();
        std::string stage;
        std::string detail;
        std::string endpoint;
        DWORD lastError = ERROR_SUCCESS;
        {
            std::lock_guard<std::mutex> guard(m_lock);
            if (!force && m_lastWriteTick != 0 && now - m_lastWriteTick < 500) return;
            m_lastWriteTick = now;
            stage = m_stage;
            detail = m_detail;
            endpoint = m_endpointName;
            lastError = m_lastError;
        }

        std::ostringstream text;
        text << "version=11\r\n";
        text << "heartbeat_ms=" << now << "\r\n";
        text << "audio_transport_model=winusb-boot-uac-runtime-wasapi\r\n";
        text << "boot_usb_pid=02ad\r\n";
        text << "runtime_usb_pid=02bb\r\n";
        text << "runtime_capture=wasapi-shared\r\n";
        text << "raw_audio_pipe=Kinect360RemoldAudio\r\n";
        text << "acoustic_pipe=Kinect360RemoldAcoustic\r\n";
        text << "audio_pipe_fanout=independent-monitor-and-acoustic\r\n";
        text << "firmware_kind=Microsoft-Kinect-SDK-UACFirmware\r\n";
        text << "firmware_bytes=" << gRemoldAudioFirmwareSize << "\r\n";
        text << "firmware_load_address=0x00080000\r\n";
        text << "firmware_entry_address=0x00080030\r\n";
        text << "stage=" << stage << "\r\n";
        text << "detail=" << detail << "\r\n";
        text << "last_error=" << lastError << "\r\n";
        text << "endpoint_name=" << endpoint << "\r\n";
        text << "usb_open_attempts=" << usbOpenAttempts.load() << "\r\n";
        text << "boot_sessions=" << bootSessions.load() << "\r\n";
        text << "runtime_sessions=" << runtimeSessions.load() << "\r\n";
        text << "firmware_uploads=" << firmwareUploads.load() << "\r\n";
        text << "firmware_failures=" << firmwareFailures.load() << "\r\n";
        text << "wasapi_endpoint_searches=" << wasapiEndpointSearches.load() << "\r\n";
        text << "wasapi_open_failures=" << wasapiOpenFailures.load() << "\r\n";
        text << "wasapi_packets=" << wasapiPackets.load() << "\r\n";
        text << "wasapi_frames=" << wasapiFrames.load() << "\r\n";
        text << "wasapi_silent_frames=" << wasapiSilentFrames.load() << "\r\n";
        text << "wasapi_discontinuities=" << wasapiDiscontinuities.load() << "\r\n";
        text << "capture_sample_rate=" << captureRate.load() << "\r\n";
        text << "capture_channels=" << captureChannels.load() << "\r\n";
        text << "capture_bits=" << captureBits.load() << "\r\n";
        text << "capture_format_tag=" << captureFormatTag.load() << "\r\n";
        text << "published_frames=" << publishedFrames.load() << "\r\n";
        text << "pipe_clients=" << pipeClients.load() << "\r\n";
        text << "pipe_frames=" << pipeFrames.load() << "\r\n";

        std::wstring directory;
        if (!TryResolveCommonDataDirectory(directory)) return;
        if (!CreateDirectoryW(directory.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) return;
        const std::wstring path = directory + L"\\" + AudioPort::kDiagnosticsFileName;
        const std::wstring temporary = path + L".tmp";
        HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS,
                                  FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) return;
        const std::string body = text.str();
        DWORD written = 0;
        const BOOL ok = WriteFile(file, body.data(), static_cast<DWORD>(body.size()), &written, nullptr);
        FlushFileBuffers(file);
        CloseHandle(file);
        if (ok && written == body.size()) {
            (void)MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
        } else {
            (void)DeleteFileW(temporary.c_str());
        }
    }

private:
    std::mutex m_lock;
    std::string m_stage{"starting"};
    std::string m_detail;
    std::string m_endpointName;
    DWORD m_lastError = ERROR_SUCCESS;
    ULONGLONG m_lastWriteTick = 0;
};

AudioDiagnostics gDiagnostics;

class AudioPortServer {
public:
    explicit AudioPortServer(const wchar_t* pipeName) : m_pipeName(pipeName ? pipeName : L"") {}
    ~AudioPortServer() { Stop(); }

    HRESULT Start() {
        if (m_thread.joinable()) return S_OK;
        m_stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!m_stopEvent) return HrLastError();
        try { m_thread = std::thread([this] { ServerLoop(); }); }
        catch (const std::system_error&) {
            CloseHandle(m_stopEvent); m_stopEvent = nullptr;
            return E_OUTOFMEMORY;
        }
        return S_OK;
    }

    void Stop() {
        if (m_stopEvent) SetEvent(m_stopEvent);
        m_cv.notify_all();
        if (m_thread.joinable()) m_thread.join();
        if (m_stopEvent) CloseHandle(m_stopEvent);
        m_stopEvent = nullptr;
        m_clientActive.store(false, std::memory_order_release);
    }

    bool ClientActive() const noexcept { return m_clientActive.load(std::memory_order_acquire); }

    void Publish(const int32_t* interleaved, uint32_t channelMask) {
        if (!ClientActive() || !interleaved || channelMask == 0) return;
        QueuedFrame frame;
        frame.header.channelMask = channelMask & 0x0fu;
        frame.header.frameNumber = ++m_frameNumber;
        frame.header.tickMs = GetTickCount64();
        frame.payload.resize(AudioPort::kPayloadBytes);
        std::memcpy(frame.payload.data(), interleaved, frame.payload.size());
        {
            std::lock_guard<std::mutex> guard(m_lock);
            if (!ClientActive()) return;
            if (m_queue.size() >= kMaxAudioPortQueueFrames) m_queue.pop_front();
            m_queue.push_back(std::move(frame));
            ++gDiagnostics.pipeFrames;
        }
        m_cv.notify_all();
    }

private:
    struct QueuedFrame {
        AudioPort::FrameHeader header{};
        std::vector<uint8_t> payload;
    };

    std::wstring m_pipeName;
    std::thread m_thread;
    HANDLE m_stopEvent = nullptr;
    std::atomic<bool> m_clientActive{false};
    std::atomic<uint64_t> m_frameNumber{0};
    std::mutex m_lock;
    std::condition_variable m_cv;
    std::deque<QueuedFrame> m_queue;

    bool Stopping() const noexcept {
        return !gRun.load() || (m_stopEvent && WaitForSingleObject(m_stopEvent, 0) == WAIT_OBJECT_0);
    }

    bool TransferExact(HANDLE pipe, void* data, DWORD bytes, bool write, DWORD timeoutMs) {
        auto* cursor = static_cast<uint8_t*>(data);
        DWORD total = 0;
        while (total < bytes && !Stopping()) {
            HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
            if (!event) return false;
            OVERLAPPED ov{}; ov.hEvent = event;
            DWORD done = 0;
            BOOL ok = write ? WriteFile(pipe, cursor + total, bytes - total, &done, &ov)
                            : ReadFile(pipe, cursor + total, bytes - total, &done, &ov);
            if (!ok && GetLastError() == ERROR_IO_PENDING) {
                HANDLE waits[2]{m_stopEvent, event};
                const DWORD wait = WaitForMultipleObjects(2, waits, FALSE, timeoutMs);
                if (wait != WAIT_OBJECT_0 + 1) {
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
        m_clientActive.store(false, std::memory_order_release);
        std::lock_guard<std::mutex> guard(m_lock);
        m_queue.clear();
    }

    void ServeClient(HANDLE pipe) {
        AudioPort::Request request{};
        if (!TransferExact(pipe, &request, sizeof(request), false, 5000)) return;
        AudioPort::Reply reply{};
        if (request.magic != AudioPort::kMagic || request.version != AudioPort::kVersion ||
            request.command != AudioPort::Command::SubscribeMicrophones || request.reserved != 0) {
            reply.result = static_cast<int32_t>(E_INVALIDARG);
            (void)TransferExact(pipe, &reply, sizeof(reply), true, 1000);
            return;
        }
        if (!TransferExact(pipe, &reply, sizeof(reply), true, 1000)) return;
        m_clientActive.store(true, std::memory_order_release);
        ++gDiagnostics.pipeClients;
        gDiagnostics.Write();

        while (!Stopping()) {
            QueuedFrame frame;
            {
                std::unique_lock<std::mutex> lock(m_lock);
                m_cv.wait_for(lock, std::chrono::milliseconds(100), [this] {
                    return Stopping() || !m_queue.empty() || !ClientActive();
                });
                if (Stopping() || !ClientActive()) break;
                if (!ClientStillConnected(pipe)) break;
                if (m_queue.empty()) continue;
                frame = std::move(m_queue.front());
                m_queue.pop_front();
            }
            if (!TransferExact(pipe, &frame.header, sizeof(frame.header), true, 2000)) break;
            if (!TransferExact(pipe, frame.payload.data(), static_cast<DWORD>(frame.payload.size()), true, 2000)) break;
        }
        ClearClient();
    }

    void ServerLoop() {
        PSECURITY_DESCRIPTOR descriptor = nullptr;
        SECURITY_ATTRIBUTES security{}; security.nLength = sizeof(security);
        if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
                L"D:P(A;;GA;;;SY)(A;;GRGW;;;BA)(A;;GRGW;;;AU)", SDDL_REVISION_1,
                &descriptor, nullptr)) security.lpSecurityDescriptor = descriptor;

        while (!Stopping()) {
            HANDLE pipe = CreateNamedPipeW(
                m_pipeName.c_str(),
                PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                1,
                static_cast<DWORD>(sizeof(AudioPort::FrameHeader) + AudioPort::kPayloadBytes),
                static_cast<DWORD>(sizeof(AudioPort::Request)),
                0, security.lpSecurityDescriptor ? &security : nullptr);
            if (pipe == INVALID_HANDLE_VALUE) break;
            HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
            if (!event) { CloseHandle(pipe); break; }
            OVERLAPPED ov{}; ov.hEvent = event;
            BOOL connected = ConnectNamedPipe(pipe, &ov);
            DWORD error = connected ? ERROR_SUCCESS : GetLastError();
            bool ready = connected || error == ERROR_PIPE_CONNECTED;
            if (!ready && error == ERROR_IO_PENDING) {
                HANDLE waits[2]{m_stopEvent, event};
                const DWORD wait = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
                if (wait == WAIT_OBJECT_0 + 1) {
                    DWORD transferred = 0;
                    ready = GetOverlappedResult(pipe, &ov, &transferred, FALSE) != FALSE;
                } else {
                    (void)CancelIoEx(pipe, &ov);
                }
            }
            CloseHandle(event);
            if (ready) ServeClient(pipe);
            (void)DisconnectNamedPipe(pipe);
            CloseHandle(pipe);
        }
        if (descriptor) LocalFree(descriptor);
    }
};

class AudioPortFanout {
public:
    AudioPortFanout(AudioPortServer& monitor, AudioPortServer& acoustic)
        : m_monitor(monitor), m_acoustic(acoustic) {}
    void Publish(const int32_t* interleaved, uint32_t channelMask) {
        m_monitor.Publish(interleaved, channelMask);
        m_acoustic.Publish(interleaved, channelMask);
    }
private:
    AudioPortServer& m_monitor;
    AudioPortServer& m_acoustic;
};

struct UsbSession {
    HANDLE file = INVALID_HANDLE_VALUE;
    Usb::Handle primary = nullptr;
    std::vector<Usb::Handle> interfaces;
    Usb::Handle selected = nullptr;
    UCHAR inputPipe = 0;
    UCHAR outputPipe = 0;

    ~UsbSession() {
        for (auto it = interfaces.rbegin(); it != interfaces.rend(); ++it) {
            if (*it) Usb::Get().Free(*it);
        }
        interfaces.clear();
        primary = nullptr;
        selected = nullptr;
        if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
        file = INVALID_HANDLE_VALUE;
    }
};

bool FindBootPipes(Usb::Handle iface, UCHAR& input, UCHAR& output) {
    auto& api = Usb::Get();
    for (UCHAR alt = 0; alt < 16; ++alt) {
        USB_INTERFACE_DESCRIPTOR desc{};
        if (!api.QueryInterfaceSettings(iface, alt, &desc)) continue;
        bool haveIn = false, haveOut = false;
        for (UCHAR i = 0; i < desc.bNumEndpoints; ++i) {
            Usb::PipeInformation pipe{};
            if (!api.QueryPipe(iface, alt, i, &pipe) || pipe.PipeType != UsbdPipeTypeBulk) continue;
            if (pipe.PipeId == kBootInEndpoint) { input = pipe.PipeId; haveIn = true; }
            else if (pipe.PipeId == kBootOutEndpoint) { output = pipe.PipeId; haveOut = true; }
        }
        if (haveIn && haveOut) {
            if (!api.SetCurrentAlternateSetting(iface, alt)) return false;
            return true;
        }
    }
    return false;
}

std::unique_ptr<UsbSession> OpenBootAudioUsb() {
    ++gDiagnostics.usbOpenAttempts;
    if (!Usb::Ready()) {
        gDiagnostics.SetStage("winusb-load-error", Usb::Get().LoadError(), "system winusb.dll is unavailable");
        return {};
    }
    auto& api = Usb::Get();
    HDEVINFO set = SetupDiGetClassDevsW(&Hardware::kAudioTransportGuid, nullptr, nullptr,
                                        DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (set == INVALID_HANDLE_VALUE) return {};
    std::unique_ptr<UsbSession> result;
    for (DWORD index = 0; !result; ++index) {
        SP_DEVICE_INTERFACE_DATA ifaceData{}; ifaceData.cbSize = sizeof(ifaceData);
        if (!SetupDiEnumDeviceInterfaces(set, nullptr, &Hardware::kAudioTransportGuid, index, &ifaceData)) break;
        DWORD bytes = 0;
        SetupDiGetDeviceInterfaceDetailW(set, &ifaceData, nullptr, 0, &bytes, nullptr);
        if (bytes < sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W)) continue;
        std::vector<uint8_t> storage(bytes);
        auto* detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(storage.data());
        detail->cbSize = sizeof(*detail);
        if (!SetupDiGetDeviceInterfaceDetailW(set, &ifaceData, detail, bytes, nullptr, nullptr)) continue;

        auto session = std::make_unique<UsbSession>();
        session->file = CreateFileW(detail->DevicePath, GENERIC_READ | GENERIC_WRITE,
                                    FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
                                    FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED, nullptr);
        if (session->file == INVALID_HANDLE_VALUE) continue;
        Usb::Handle primary = nullptr;
        if (!api.Initialize(session->file, &primary)) continue;
        session->primary = primary;
        session->interfaces.push_back(primary);
        for (UCHAR associatedIndex = 0; associatedIndex < 8; ++associatedIndex) {
            Usb::Handle associated = nullptr;
            if (!api.GetAssociatedInterface(primary, associatedIndex, &associated)) break;
            session->interfaces.push_back(associated);
        }
        for (auto iface : session->interfaces) {
            UCHAR in = 0, out = 0;
            if (FindBootPipes(iface, in, out)) {
                session->selected = iface;
                session->inputPipe = in;
                session->outputPipe = out;
                result = std::move(session);
                break;
            }
        }
    }
    SetupDiDestroyDeviceInfoList(set);
    return result;
}

bool BulkWrite(UsbSession& session, const void* data, ULONG bytes) {
    UINT transferred = 0;
    return Usb::Get().WritePipe(session.selected, session.outputPipe,
                                const_cast<PUCHAR>(static_cast<const UCHAR*>(data)), bytes,
                                &transferred, nullptr) && transferred == bytes;
}

HRESULT BulkReadPacket(UsbSession& session, void* data, ULONG capacity, ULONG expectedBytes) {
    if (!data || capacity < expectedBytes) return E_INVALIDARG;
    UINT transferred = 0;
    if (!Usb::Get().ReadPipe(session.selected, session.inputPipe, static_cast<PUCHAR>(data), capacity,
                             &transferred, nullptr)) {
        return HrLastError();
    }
    if (transferred != expectedBytes) return HRESULT_FROM_WIN32(ERROR_BAD_LENGTH);
    return S_OK;
}

HRESULT ReadBootStatus(UsbSession& session, uint32_t tag) {
    std::array<uint8_t, 512> reply{};
    HRESULT hr = BulkReadPacket(session, reply.data(), static_cast<ULONG>(reply.size()), static_cast<ULONG>(sizeof(BootStatus)));
    if (FAILED(hr)) return hr;
    BootStatus status{};
    std::memcpy(&status, reply.data(), sizeof(status));
    if (status.magic != Hardware::Audio::kBootStatusMagic || status.tag != tag || status.status != 0) {
        return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
    }
    return S_OK;
}

bool IsUsbDeviceGone(DWORD error) {
    return error == ERROR_DEVICE_NOT_CONNECTED || error == ERROR_NO_SUCH_DEVICE ||
           error == ERROR_GEN_FAILURE || error == ERROR_OPERATION_ABORTED || error == ERROR_INVALID_HANDLE;
}

HRESULT UploadUacFirmware(UsbSession& session) {
    if (!session.selected || gRemoldAudioFirmwareSize == 0) return E_UNEXPECTED;

    uint32_t tag = kUacInitialTag;
    BootCommand probe{Hardware::Audio::kBootCommandMagic, tag, kUacProbeBytes, 0u, kUacProbeAddress, 0u};
    if (!BulkWrite(session, &probe, static_cast<ULONG>(sizeof(probe)))) return HrLastError();

    // The UAC loader protocol has one 96-byte version reply before the normal
    // 12-byte status reply; the UAC image uses the raw bootloader layout.
    std::array<uint8_t, 512> versionReply{};
    HRESULT hr = BulkReadPacket(session, versionReply.data(), static_cast<ULONG>(versionReply.size()), kUacProbeBytes);
    if (FAILED(hr)) return hr;
    hr = ReadBootStatus(session, tag);
    if (FAILED(hr)) return hr;
    ++tag;

    uint32_t address = kUacLoadAddress;
    uint32_t sent = 0;
    while (sent < gRemoldAudioFirmwareSize && gRun.load()) {
        const uint32_t page = std::min<uint32_t>(Hardware::Audio::kFirmwarePageBytes, gRemoldAudioFirmwareSize - sent);
        BootCommand command{Hardware::Audio::kBootCommandMagic, tag, page,
                            Hardware::Audio::kBootWriteCommand, address, 0u};
        if (!BulkWrite(session, &command, static_cast<ULONG>(sizeof(command)))) return HrLastError();
        uint32_t pageSent = 0;
        while (pageSent < page) {
            const uint32_t chunk = std::min<uint32_t>(Hardware::Audio::kFirmwareChunkBytes, page - pageSent);
            if (!BulkWrite(session, gRemoldAudioFirmware + sent + pageSent, chunk)) return HrLastError();
            pageSent += chunk;
        }
        hr = ReadBootStatus(session, tag);
        if (FAILED(hr)) return hr;
        sent += page;
        address += page;
        ++tag;
    }
    if (!gRun.load()) return HRESULT_FROM_WIN32(ERROR_CANCELLED);

    BootCommand launch{Hardware::Audio::kBootCommandMagic, tag, 0u,
                       Hardware::Audio::kBootLaunchCommand, kUacEntryAddress, 0u};
    if (!BulkWrite(session, &launch, static_cast<ULONG>(sizeof(launch)))) return HrLastError();
    hr = ReadBootStatus(session, tag);
    if (FAILED(hr) && !IsUsbDeviceGone(HRESULT_CODE(hr))) return hr;
    return S_OK;
}

bool ContainsInsensitive(const std::wstring& text, const wchar_t* needle) {
    if (!needle || !*needle) return true;
    std::wstring lhs(text);
    std::wstring rhs(needle);
    std::transform(lhs.begin(), lhs.end(), lhs.begin(), [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
    std::transform(rhs.begin(), rhs.end(), rhs.begin(), [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
    return lhs.find(rhs) != std::wstring::npos;
}

std::wstring EndpointPropertyString(IMMDevice* device, REFPROPERTYKEY key) {
    if (!device) return {};
    ComPtr<IPropertyStore> store;
    if (FAILED(device->OpenPropertyStore(STGM_READ, &store))) return {};
    PROPVARIANT value;
    PropVariantInit(&value);
    std::wstring result;
    if (SUCCEEDED(store->GetValue(key, &value)) && value.vt == VT_LPWSTR && value.pwszVal) {
        result = value.pwszVal;
    }
    PropVariantClear(&value);
    return result;
}

HRESULT FindKinectUacCaptureEndpoint(ComPtr<IMMDevice>& endpoint, std::wstring& friendlyName) {
    ++gDiagnostics.wasapiEndpointSearches;
    endpoint.Reset();
    friendlyName.clear();
    ComPtr<IMMDeviceEnumerator> enumerator;
    HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&enumerator));
    if (FAILED(hr)) return hr;
    ComPtr<IMMDeviceCollection> collection;
    hr = enumerator->EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE, &collection);
    if (FAILED(hr)) return hr;
    UINT count = 0;
    hr = collection->GetCount(&count);
    if (FAILED(hr)) return hr;

    for (UINT index = 0; index < count; ++index) {
        ComPtr<IMMDevice> candidate;
        if (FAILED(collection->Item(index, &candidate))) continue;
        const std::wstring name = EndpointPropertyString(candidate.Get(), PKEY_Device_FriendlyName);
        const std::wstring instanceId = EndpointPropertyString(candidate.Get(), PKEY_Device_InstanceId);
        const bool exactRuntime = ContainsInsensitive(instanceId, L"VID_045E&PID_02BB") &&
                                  ContainsInsensitive(instanceId, L"MI_02");
        if (exactRuntime) {
            endpoint = candidate;
            friendlyName = name.empty() ? instanceId : name;
            return S_OK;
        }
    }
    return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
}

enum class SampleEncoding { Unsupported, Pcm16, Pcm24, Pcm32, Float32 };

SampleEncoding DetectEncoding(const WAVEFORMATEX* format) {
    if (!format) return SampleEncoding::Unsupported;
    WORD tag = format->wFormatTag;
    GUID subtype{};
    if (tag == WAVE_FORMAT_EXTENSIBLE && format->cbSize >= 22) {
        const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
        subtype = ext->SubFormat;
        if (IsEqualGUID(subtype, kSubTypeFloat) && format->wBitsPerSample == 32) return SampleEncoding::Float32;
        if (!IsEqualGUID(subtype, kSubTypePcm)) return SampleEncoding::Unsupported;
        tag = WAVE_FORMAT_PCM;
    }
    if (tag == WAVE_FORMAT_IEEE_FLOAT && format->wBitsPerSample == 32) return SampleEncoding::Float32;
    if (tag != WAVE_FORMAT_PCM) return SampleEncoding::Unsupported;
    switch (format->wBitsPerSample) {
        case 16: return SampleEncoding::Pcm16;
        case 24: return SampleEncoding::Pcm24;
        case 32: return SampleEncoding::Pcm32;
        default: return SampleEncoding::Unsupported;
    }
}

bool IsCompatibleCaptureFormat(const WAVEFORMATEX* format) {
    if (!format || format->nSamplesPerSec != AudioPort::kSampleRate ||
        format->nChannels < AudioPort::kChannels || format->nBlockAlign == 0) return false;
    return DetectEncoding(format) != SampleEncoding::Unsupported;
}

int32_t ReadSample(const uint8_t* sample, SampleEncoding encoding) {
    if (!sample) return 0;
    switch (encoding) {
        case SampleEncoding::Pcm16: {
            int16_t value = 0;
            std::memcpy(&value, sample, sizeof(value));
            return static_cast<int32_t>(value) << 16;
        }
        case SampleEncoding::Pcm24: {
            int32_t value = static_cast<int32_t>(sample[0]) |
                            (static_cast<int32_t>(sample[1]) << 8) |
                            (static_cast<int32_t>(sample[2]) << 16);
            if (value & 0x00800000) value |= static_cast<int32_t>(0xff000000u);
            return value << 8;
        }
        case SampleEncoding::Pcm32: {
            int32_t value = 0;
            std::memcpy(&value, sample, sizeof(value));
            return value;
        }
        case SampleEncoding::Float32: {
            float value = 0.0f;
            std::memcpy(&value, sample, sizeof(value));
            if (!std::isfinite(value)) value = 0.0f;
            value = std::max(-1.0f, std::min(1.0f, value));
            const double scaled = static_cast<double>(value) * 2147483647.0;
            return static_cast<int32_t>(scaled);
        }
        default: return 0;
    }
}

class WasapiFrameAssembler {
public:
    explicit WasapiFrameAssembler(AudioPortFanout& port) : m_port(port) {}

    void Push(const BYTE* data, UINT32 frames, DWORD flags, const WAVEFORMATEX* format, SampleEncoding encoding) {
        if (!format || frames == 0) return;
        const uint32_t channels = format->nChannels;
        const uint32_t sampleBytes = format->wBitsPerSample / 8u;
        if (channels < AudioPort::kChannels || sampleBytes == 0 ||
            format->nBlockAlign < channels * sampleBytes) return;
        const bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
        if (silent) gDiagnostics.wasapiSilentFrames.fetch_add(frames);
        if (flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) ++gDiagnostics.wasapiDiscontinuities;

        for (UINT32 frame = 0; frame < frames; ++frame) {
            const BYTE* frameData = silent || !data ? nullptr : data + static_cast<size_t>(frame) * format->nBlockAlign;
            for (uint32_t channel = 0; channel < AudioPort::kChannels; ++channel) {
                const BYTE* sample = frameData ? frameData + static_cast<size_t>(channel) * sampleBytes : nullptr;
                m_frame[m_frames * AudioPort::kChannels + channel] = silent ? 0 : ReadSample(sample, encoding);
            }
            ++m_frames;
            ++gDiagnostics.wasapiFrames;
            if (m_frames == AudioPort::kSamplesPerChannel) {
                m_port.Publish(m_frame.data(), 0x0fu);
                ++gDiagnostics.publishedFrames;
                m_frames = 0;
            }
        }
    }

private:
    AudioPortFanout& m_port;
    std::array<int32_t, AudioPort::kSamplesPerChannel * AudioPort::kChannels> m_frame{};
    uint32_t m_frames = 0;
};

HRESULT CaptureUacRuntime(IMMDevice* endpoint, const std::wstring& friendlyName, AudioPortFanout& port) {
    if (!endpoint) return E_POINTER;
    gDiagnostics.SetEndpointName(friendlyName);
    ComPtr<IAudioClient> audioClient;
    HRESULT hr = endpoint->Activate(__uuidof(IAudioClient), CLSCTX_INPROC_SERVER, nullptr,
                                    reinterpret_cast<void**>(audioClient.GetAddressOf()));
    if (FAILED(hr)) return hr;

    WAVEFORMATEX* mixFormat = nullptr;
    hr = audioClient->GetMixFormat(&mixFormat);
    if (FAILED(hr) || !mixFormat) return FAILED(hr) ? hr : E_UNEXPECTED;

    WAVEFORMATEXTENSIBLE desired{};
    desired.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    desired.Format.nChannels = static_cast<WORD>(AudioPort::kChannels);
    desired.Format.nSamplesPerSec = AudioPort::kSampleRate;
    desired.Format.wBitsPerSample = 32;
    desired.Format.nBlockAlign = static_cast<WORD>(AudioPort::kChannels * sizeof(int32_t));
    desired.Format.nAvgBytesPerSec = desired.Format.nSamplesPerSec * desired.Format.nBlockAlign;
    desired.Format.cbSize = 22;
    desired.Samples.wValidBitsPerSample = 32;
    desired.dwChannelMask = 0;
    desired.SubFormat = kSubTypePcm;

    WAVEFORMATEX* closest = nullptr;
    WAVEFORMATEX* selected = nullptr;
    bool selectedNeedsFree = false;
    if (IsCompatibleCaptureFormat(mixFormat)) {
        selected = mixFormat;
    } else {
        const HRESULT supported = audioClient->IsFormatSupported(AUDCLNT_SHAREMODE_SHARED, &desired.Format, &closest);
        if (supported == S_OK) selected = &desired.Format;
        else if (supported == S_FALSE && closest && IsCompatibleCaptureFormat(closest)) {
            selected = closest;
            selectedNeedsFree = true;
        }
    }
    if (!selected) {
        if (closest) CoTaskMemFree(closest);
        CoTaskMemFree(mixFormat);
        return AUDCLNT_E_UNSUPPORTED_FORMAT;
    }

    const SampleEncoding encoding = DetectEncoding(selected);
    if (encoding == SampleEncoding::Unsupported) {
        if (selectedNeedsFree && closest) CoTaskMemFree(closest);
        CoTaskMemFree(mixFormat);
        return AUDCLNT_E_UNSUPPORTED_FORMAT;
    }

    gDiagnostics.captureRate = selected->nSamplesPerSec;
    gDiagnostics.captureChannels = selected->nChannels;
    gDiagnostics.captureBits = selected->wBitsPerSample;
    gDiagnostics.captureFormatTag = selected->wFormatTag;

    HANDLE readyEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!readyEvent) {
        if (selectedNeedsFree && closest) CoTaskMemFree(closest);
        CoTaskMemFree(mixFormat);
        return HrLastError();
    }

    const DWORD streamFlags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_NOPERSIST |
                              AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
    hr = audioClient->Initialize(AUDCLNT_SHAREMODE_SHARED, streamFlags, kWasapiBufferDuration, 0, selected, nullptr);
    if (SUCCEEDED(hr)) hr = audioClient->SetEventHandle(readyEvent);
    ComPtr<IAudioCaptureClient> captureClient;
    if (SUCCEEDED(hr)) hr = audioClient->GetService(IID_PPV_ARGS(&captureClient));
    if (SUCCEEDED(hr)) hr = audioClient->Start();

    if (FAILED(hr)) {
        if (selectedNeedsFree && closest) CoTaskMemFree(closest);
        CoTaskMemFree(mixFormat);
        CloseHandle(readyEvent);
        return hr;
    }

    ++gDiagnostics.runtimeSessions;
    gDiagnostics.SetStage("uac-runtime-capturing", ERROR_SUCCESS,
                          "Kinect USB Audio is active through the Microsoft USB Audio class driver and WASAPI");
    WasapiFrameAssembler assembler(port);
    HRESULT result = S_OK;
    while (gRun.load()) {
        const DWORD wait = WaitForSingleObject(readyEvent, kWasapiWaitMs);
        if (wait == WAIT_TIMEOUT) { gDiagnostics.Write(); continue; }
        if (wait != WAIT_OBJECT_0) { result = HrLastError(); break; }

        UINT32 packetFrames = 0;
        hr = captureClient->GetNextPacketSize(&packetFrames);
        if (FAILED(hr)) { result = hr; break; }
        while (packetFrames != 0 && gRun.load()) {
            BYTE* data = nullptr;
            UINT32 frames = 0;
            DWORD flags = 0;
            UINT64 devicePosition = 0;
            UINT64 qpcPosition = 0;
            hr = captureClient->GetBuffer(&data, &frames, &flags, &devicePosition, &qpcPosition);
            if (FAILED(hr)) { result = hr; break; }
            (void)devicePosition;
            (void)qpcPosition;
            ++gDiagnostics.wasapiPackets;
            assembler.Push(data, frames, flags, selected, encoding);
            hr = captureClient->ReleaseBuffer(frames);
            if (FAILED(hr)) { result = hr; break; }
            hr = captureClient->GetNextPacketSize(&packetFrames);
            if (FAILED(hr)) { result = hr; break; }
        }
        if (FAILED(hr)) break;
        gDiagnostics.Write();
    }
    (void)audioClient->Stop();
    if (selectedNeedsFree && closest) CoTaskMemFree(closest);
    CoTaskMemFree(mixFormat);
    CloseHandle(readyEvent);
    return result;
}

void CaptureLoop(AudioPortFanout* port) {
    const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(com) && com != RPC_E_CHANGED_MODE) {
        gDiagnostics.SetStage("com-initialize-error", HRESULT_CODE(com), "WASAPI COM initialization failed");
        return;
    }
    const bool uninitialize = SUCCEEDED(com);
    gDiagnostics.SetStage("uac-searching");

    while (gRun.load()) {
        ComPtr<IMMDevice> endpoint;
        std::wstring endpointName;
        const HRESULT endpointResult = FindKinectUacCaptureEndpoint(endpoint, endpointName);
        if (SUCCEEDED(endpointResult) && endpoint) {
            const HRESULT capture = CaptureUacRuntime(endpoint.Get(), endpointName, *port);
            if (FAILED(capture) && gRun.load()) {
                ++gDiagnostics.wasapiOpenFailures;
                gDiagnostics.SetStage("uac-runtime-error", HRESULT_CODE(capture), "WASAPI capture stopped; retrying endpoint discovery");
                Sleep(kAudioRetryMs);
            }
            continue;
        }

        auto boot = OpenBootAudioUsb();
        if (boot) {
            ++gDiagnostics.bootSessions;
            gDiagnostics.SetStage("uac-firmware-uploading", ERROR_SUCCESS,
                                  "uploading Microsoft Kinect SDK UACFirmware through 02AD WinUSB bulk endpoints");
            const HRESULT upload = UploadUacFirmware(*boot);
            boot.reset();
            if (SUCCEEDED(upload)) {
                ++gDiagnostics.firmwareUploads;
                gDiagnostics.SetStage("uac-firmware-launched", ERROR_SUCCESS,
                                      "waiting for 045E:02BB Kinect USB Audio re-enumeration");
                Sleep(kPostFirmwareDelayMs);
            } else {
                ++gDiagnostics.firmwareFailures;
                gDiagnostics.SetStage("uac-firmware-error", HRESULT_CODE(upload),
                                      "UACFirmware upload/bootloader handshake failed");
                Sleep(kAudioRetryMs);
            }
            continue;
        }

        gDiagnostics.SetStage("uac-endpoint-not-found", ERROR_NOT_FOUND,
                              "neither 045E:02BB Kinect USB Audio nor 045E:02AD WinUSB boot transport is available");
        Sleep(kAudioRetryMs);
    }

    if (uninitialize) CoUninitialize();
    gDiagnostics.SetStage("stopped");
}

int RunHost() {
    gDiagnostics.SetStage("starting");
    AudioPortServer monitorPort(AudioPort::kPipeName);
    AudioPortServer acousticPort(AudioPort::kAcousticPipeName);
    if (FAILED(monitorPort.Start())) return 2;
    if (FAILED(acousticPort.Start())) { monitorPort.Stop(); return 3; }
    AudioPortFanout fanout(monitorPort, acousticPort);
    std::thread capture(CaptureLoop, &fanout);
    while (gRun.load()) Sleep(200);
    acousticPort.Stop();
    monitorPort.Stop();
    if (capture.joinable()) capture.join();
    return 0;
}

SERVICE_STATUS_HANDLE gServiceHandle = nullptr;
SERVICE_STATUS gServiceStatus{};

void WINAPI ServiceControl(DWORD control) {
    if (control != SERVICE_CONTROL_STOP && control != SERVICE_CONTROL_SHUTDOWN) return;
    gRun.store(false);
    gServiceStatus.dwCurrentState = SERVICE_STOP_PENDING;
    gServiceStatus.dwControlsAccepted = 0;
    gServiceStatus.dwCheckPoint = 1;
    gServiceStatus.dwWaitHint = 5000;
    if (gServiceHandle) SetServiceStatus(gServiceHandle, &gServiceStatus);
}

void WINAPI ServiceMain(DWORD, wchar_t**) {
    gServiceHandle = RegisterServiceCtrlHandlerW(L"Kinect360RemoldAudioBridge", ServiceControl);
    if (!gServiceHandle) return;
    gServiceStatus.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    gServiceStatus.dwCurrentState = SERVICE_START_PENDING;
    gServiceStatus.dwControlsAccepted = 0;
    gServiceStatus.dwWin32ExitCode = NO_ERROR;
    gServiceStatus.dwCheckPoint = 1;
    gServiceStatus.dwWaitHint = 5000;
    SetServiceStatus(gServiceHandle, &gServiceStatus);
    gRun.store(true);
    gServiceStatus.dwCurrentState = SERVICE_RUNNING;
    gServiceStatus.dwControlsAccepted = SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN;
    gServiceStatus.dwCheckPoint = 0;
    gServiceStatus.dwWaitHint = 0;
    SetServiceStatus(gServiceHandle, &gServiceStatus);
    const int rc = RunHost();
    gServiceStatus.dwCurrentState = SERVICE_STOPPED;
    gServiceStatus.dwControlsAccepted = 0;
    gServiceStatus.dwWin32ExitCode = rc == 0 ? NO_ERROR : ERROR_SERVICE_SPECIFIC_ERROR;
    gServiceStatus.dwServiceSpecificExitCode = static_cast<DWORD>(rc);
    gServiceStatus.dwCheckPoint = 0;
    gServiceStatus.dwWaitHint = 0;
    SetServiceStatus(gServiceHandle, &gServiceStatus);
}

BOOL WINAPI ConsoleControl(DWORD control) {
    if (control == CTRL_C_EVENT || control == CTRL_BREAK_EVENT || control == CTRL_CLOSE_EVENT ||
        control == CTRL_SHUTDOWN_EVENT) { gRun.store(false); return TRUE; }
    return FALSE;
}
} // namespace

int wmain() {
    SERVICE_TABLE_ENTRYW table[] = {
        {const_cast<LPWSTR>(L"Kinect360RemoldAudioBridge"), ServiceMain},
        {nullptr, nullptr}
    };
    if (StartServiceCtrlDispatcherW(table)) return 0;
    if (GetLastError() != ERROR_FAILED_SERVICE_CONTROLLER_CONNECT) return 1;
    (void)SetConsoleCtrlHandler(ConsoleControl, TRUE);
    gRun.store(true);
    return RunHost();
}
