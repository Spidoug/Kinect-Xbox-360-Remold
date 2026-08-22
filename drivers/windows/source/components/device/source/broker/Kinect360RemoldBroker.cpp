#ifndef NOMINMAX
#define NOMINMAX
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <setupapi.h>
#include <sddl.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cwchar>
#include <mutex>
#include <thread>
#include <vector>

#include "Kinect360RemoldControlProtocol.h"
#include "Kinect360RemoldDevicePolicy.h"
#include "Kinect360RemoldWinUsb.h"
#include "Kinect360RemoldHardwareProfile.h"

#pragma comment(lib, "setupapi.lib")
#pragma comment(lib, "advapi32.lib")

namespace {
using Kinect360RemoldControl::CameraActivitySource;
using Kinect360RemoldControl::Command;
using Kinect360RemoldControl::Reply;
using Kinect360RemoldControl::Request;
using Kinect360RemoldControl::Transport;

namespace Policy = Kinect360RemoldDevicePolicy;
namespace WinUsb = Kinect360RemoldWinUsb;
namespace Hardware = Kinect360RemoldHardware;

std::atomic<bool> gRun{true};
std::mutex gPhysicalNuiMutex;
std::atomic<ULONGLONG> gVirtualCameraTick{0};
std::atomic<ULONGLONG> gScannerCameraTick{0};
std::atomic<ULONGLONG> gIpCameraTick{0};

HRESULT HrFromLastError() {
    const DWORD error = GetLastError();
    return HRESULT_FROM_WIN32(error ? error : ERROR_GEN_FAILURE);
}

uint32_t CurrentCameraActivityMask() {
    const ULONGLONG now = GetTickCount64();
    uint32_t mask = 0;
    const ULONGLONG virtualCamera = gVirtualCameraTick.load(std::memory_order_relaxed);
    const ULONGLONG scannerCamera = gScannerCameraTick.load(std::memory_order_relaxed);
    const ULONGLONG ipCamera = gIpCameraTick.load(std::memory_order_relaxed);
    if (virtualCamera != 0 && now - virtualCamera <= Policy::kCameraActivityLeaseMs) mask |= 0x1u;
    if (scannerCamera != 0 && now - scannerCamera <= Policy::kCameraActivityLeaseMs) mask |= 0x2u;
    if (ipCamera != 0 && now - ipCamera <= Policy::kCameraActivityLeaseMs) mask |= 0x4u;
    return mask;
}

HRESULT RecordCameraActivity(int32_t source) {
    const ULONGLONG now = GetTickCount64();
    switch (static_cast<CameraActivitySource>(source)) {
        case CameraActivitySource::VirtualCamera:
            gVirtualCameraTick.store(now, std::memory_order_relaxed);
            return S_OK;
        case CameraActivitySource::Scanner3D:
            gScannerCameraTick.store(now, std::memory_order_relaxed);
            return S_OK;
        case CameraActivitySource::IpCamera:
            gIpCameraTick.store(now, std::memory_order_relaxed);
            return S_OK;
        default:
            return E_INVALIDARG;
    }
}

struct PhysicalNuiSession {
    HANDLE file = INVALID_HANDLE_VALUE;
    WinUsb::Handle usb = nullptr;
    bool Ready() const noexcept { return file != INVALID_HANDLE_VALUE && usb != nullptr; }
    void Close() noexcept {
        if (usb) WinUsb::Get().Free(usb);
        if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
        usb = nullptr;
        file = INVALID_HANDLE_VALUE;
    }
    ~PhysicalNuiSession() { Close(); }
};

PhysicalNuiSession gPhysicalNuiSession;

HRESULT OpenPhysicalNui(PhysicalNuiSession& session) {
    HDEVINFO set = SetupDiGetClassDevsW(
        &Hardware::kNuiTransportGuid, nullptr, nullptr, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (set == INVALID_HANDLE_VALUE) return HrFromLastError();

    HRESULT result = HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
    for (DWORD index = 0;; ++index) {
        SP_DEVICE_INTERFACE_DATA iface{};
        iface.cbSize = sizeof(iface);
        if (!SetupDiEnumDeviceInterfaces(set, nullptr, &Hardware::kNuiTransportGuid, index, &iface)) {
            if (GetLastError() != ERROR_NO_MORE_ITEMS) result = HrFromLastError();
            break;
        }

        DWORD bytes = 0;
        SetupDiGetDeviceInterfaceDetailW(set, &iface, nullptr, 0, &bytes, nullptr);
        if (bytes < sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W)) continue;
        std::vector<BYTE> storage(bytes);
        auto* detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(storage.data());
        detail->cbSize = sizeof(*detail);
        if (!SetupDiGetDeviceInterfaceDetailW(set, &iface, detail, bytes, nullptr, nullptr)) continue;

        HANDLE file = CreateFileW(
            detail->DevicePath,
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            nullptr,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED,
            nullptr);
        if (file == INVALID_HANDLE_VALUE) continue;

        WinUsb::Handle usb = nullptr;
        if (!WinUsb::Ready() || !WinUsb::Get().Initialize(file, &usb)) {
            result = HrFromLastError();
            CloseHandle(file);
            continue;
        }

        session.file = file;
        session.usb = usb;
        result = S_OK;
        break;
    }

    SetupDiDestroyDeviceInfoList(set);
    return result;
}

HRESULT EnsurePhysicalNui() {
    if (gPhysicalNuiSession.Ready()) return S_OK;
    gPhysicalNuiSession.Close();
    return OpenPhysicalNui(gPhysicalNuiSession);
}

void InvalidatePhysicalNuiOnFailure(HRESULT hr) {
    if (FAILED(hr)) gPhysicalNuiSession.Close();
}

HRESULT ReadPhysicalStatus(PhysicalNuiSession& session, Reply& reply) {
    WinUsb::SetupPacket packet{};
    packet.RequestType = 0xC0;
    packet.Request = 0x32;
    packet.Length = 10;
    UCHAR buffer[10]{};
    UINT transferred = 0;
    if (!WinUsb::Get().ControlTransfer(session.usb, packet, buffer, sizeof(buffer), &transferred, nullptr) ||
        transferred != sizeof(buffer)) return HrFromLastError();

    reply.accelX = static_cast<short>((buffer[2] << 8) | buffer[3]);
    reply.accelY = static_cast<short>((buffer[4] << 8) | buffer[5]);
    reply.accelZ = static_cast<short>((buffer[6] << 8) | buffer[7]);
    reply.tiltTenths = static_cast<signed char>(buffer[8]) * 5;
    reply.state = buffer[9];
    return S_OK;
}

HRESULT SetPhysicalTiltHalfDegrees(PhysicalNuiSession& session, SHORT halfDegrees) {
    const SHORT minimum = static_cast<SHORT>(Policy::kTiltMinDegrees * 2);
    const SHORT maximum = static_cast<SHORT>(Policy::kTiltMaxDegrees * 2);
    halfDegrees = std::clamp<SHORT>(halfDegrees, minimum, maximum);
    WinUsb::SetupPacket packet{};
    packet.RequestType = 0x40;
    packet.Request = 0x31;
    packet.Value = static_cast<USHORT>(halfDegrees);
    UINT transferred = 0;
    return WinUsb::Get().ControlTransfer(session.usb, packet, nullptr, 0, &transferred, nullptr)
        ? S_OK : HrFromLastError();
}

bool IsValidLedMode(LONG value) {
    return value == static_cast<LONG>(Kinect360RemoldControl::LedMode::Off) ||
           value == static_cast<LONG>(Kinect360RemoldControl::LedMode::Green) ||
           value == static_cast<LONG>(Kinect360RemoldControl::LedMode::Red) ||
           value == static_cast<LONG>(Kinect360RemoldControl::LedMode::Yellow) ||
           value == static_cast<LONG>(Kinect360RemoldControl::LedMode::BlinkGreen) ||
           value == static_cast<LONG>(Kinect360RemoldControl::LedMode::BlinkYellowRed);
}

HRESULT SetPhysicalLed(PhysicalNuiSession& session, LONG value) {
    if (!IsValidLedMode(value)) return E_INVALIDARG;
    WinUsb::SetupPacket packet{};
    packet.RequestType = 0x40;
    packet.Request = 0x06;
    packet.Value = static_cast<USHORT>(value);
    UINT transferred = 0;
    return WinUsb::Get().ControlTransfer(session.usb, packet, nullptr, 0, &transferred, nullptr)
        ? S_OK : HrFromLastError();
}

HRESULT TryPhysicalNuiCommand(const Request& request, Reply& reply) {
    // Status, Tilt, LED and the connection chirp share one serialized physical
    // WinUSB owner. This prevents FaceTracker/accelerometer polling from
    // interleaving control transfers with LED or motor commands.
    std::lock_guard<std::mutex> physicalGuard(gPhysicalNuiMutex);
    const HRESULT openHr = EnsurePhysicalNui();
    if (FAILED(openHr)) return openHr;

    reply = {};
    reply.transport = Transport::PhysicalMotor;
    HRESULT hr = E_INVALIDARG;
    if (request.command == Command::Ping) hr = S_OK;
    else if (request.command == Command::Status) hr = ReadPhysicalStatus(gPhysicalNuiSession, reply);
    else if (request.command == Command::Tilt) {
        const LONG degrees = std::clamp<LONG>(request.value, Policy::kTiltMinDegrees, Policy::kTiltMaxDegrees);
        hr = SetPhysicalTiltHalfDegrees(gPhysicalNuiSession, static_cast<SHORT>(degrees * 2));
        if (SUCCEEDED(hr)) reply.tiltTenths = degrees * 10;
    } else if (request.command == Command::Led) {
        hr = SetPhysicalLed(gPhysicalNuiSession, request.value);
    }
    InvalidatePhysicalNuiOnFailure(hr);
    return hr;
}

HRESULT TryConnectionChirp() {
    if (!Policy::kConnectionChirpEnabled || Policy::kConnectionChirpCycles <= 0 ||
        Policy::kConnectionChirpStepHalfDegrees <= 0) return S_FALSE;

    std::lock_guard<std::mutex> physicalGuard(gPhysicalNuiMutex);
    HRESULT hr = EnsurePhysicalNui();
    if (FAILED(hr)) return hr;

    Reply status{};
    status.transport = Transport::PhysicalMotor;
    hr = ReadPhysicalStatus(gPhysicalNuiSession, status);
    if (FAILED(hr)) { InvalidatePhysicalNuiOnFailure(hr); return hr; }

    const SHORT minimum = static_cast<SHORT>(Policy::kTiltMinDegrees * 2);
    const SHORT maximum = static_cast<SHORT>(Policy::kTiltMaxDegrees * 2);
    const SHORT base = std::clamp<SHORT>(static_cast<SHORT>(status.tiltTenths / 5), minimum, maximum);
    const SHORT step = Policy::kConnectionChirpStepHalfDegrees;
    SHORT direction = 0;
    if (base <= maximum - step) direction = 1;
    else if (base >= minimum + step) direction = -1;
    if (direction == 0) return S_FALSE;

    const SHORT pulseTarget = static_cast<SHORT>(base + direction * step);
    for (int cycle = 0; cycle < Policy::kConnectionChirpCycles; ++cycle) {
        hr = SetPhysicalTiltHalfDegrees(gPhysicalNuiSession, pulseTarget);
        if (FAILED(hr)) break;
        Sleep(Policy::kConnectionChirpPulseMs);
        hr = SetPhysicalTiltHalfDegrees(gPhysicalNuiSession, base);
        if (FAILED(hr)) break;
        if (cycle + 1 < Policy::kConnectionChirpCycles) Sleep(Policy::kConnectionChirpPulseMs);
    }
    // Best effort restore even when one pulse fails. If restoring the measured
    // angle itself fails, invalidate the cached session so the next operation
    // re-enumerates instead of keeping a stale WinUSB handle.
    const HRESULT restoreHr = SetPhysicalTiltHalfDegrees(gPhysicalNuiSession, base);
    if (SUCCEEDED(hr) && FAILED(restoreHr)) hr = restoreHr;
    InvalidatePhysicalNuiOnFailure(hr);
    return hr;
}

HRESULT DispatchControlRequest(const Request& request, Reply& reply) {
    reply = {};
    reply.cameraActivityMask = CurrentCameraActivityMask();
    if (request.magic != Kinect360RemoldControl::kMagic ||
        request.version != Kinect360RemoldControl::kVersion) {
        return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
    }

    if (request.command == Command::Ping) return S_OK;
    if (request.command == Command::CameraActivity) {
        const HRESULT hr = RecordCameraActivity(request.value);
        reply.cameraActivityMask = CurrentCameraActivityMask();
        return hr;
    }

    const HRESULT hr = TryPhysicalNuiCommand(request, reply);
    reply.cameraActivityMask = CurrentCameraActivityMask();
    return hr;
}

void AutoLedLoop(std::atomic<bool>* active) {
    int lastApplied = -1;
    int lastDesired = -1;
    ULONGLONG lastAttempt = 0;
    ULONGLONG lastChirpAttempt = 0;
    uint32_t previousMask = 0;
    bool idleFlashOn = true;
    ULONGLONG idlePhaseStart = GetTickCount64();

    while (active->load() && gRun.load()) {
        const ULONGLONG now = GetTickCount64();
        const uint32_t mask = CurrentCameraActivityMask();
        const uint32_t newlyActiveSources = mask & ~previousMask;

        if (newlyActiveSources != 0 &&
            (lastChirpAttempt == 0 || now - lastChirpAttempt >= Policy::kConnectionChirpCooldownMs)) {
            lastChirpAttempt = now;
            (void)TryConnectionChirp();
        }

        int desired = static_cast<int>(Kinect360RemoldControl::LedMode::Off);
        if (mask != 0) {
            // Any active camera consumer owns a solid-green LED lease.
            desired = static_cast<int>(Kinect360RemoldControl::LedMode::Green);
            idleFlashOn = true;
            idlePhaseStart = now;
        } else {
            // Idle heartbeat: one short green pulse, then four seconds dark.
            if (previousMask != 0) {
                idleFlashOn = true;
                idlePhaseStart = now;
            }
            const ULONGLONG elapsed = now - idlePhaseStart;
            if (idleFlashOn && elapsed >= Policy::kLedIdleFlashMs) {
                idleFlashOn = false;
                idlePhaseStart = now;
            } else if (!idleFlashOn && elapsed >= Policy::kLedIdleOffMs) {
                idleFlashOn = true;
                idlePhaseStart = now;
            }
            desired = static_cast<int>(idleFlashOn
                ? Kinect360RemoldControl::LedMode::Green
                : Kinect360RemoldControl::LedMode::Off);
        }

        // State transitions are immediate. A failed transfer retries with
        // backoff; an already-applied state is only refreshed occasionally so
        // an unplugged/replugged Kinect recovers without hammering WinUSB.
        if (desired != lastDesired) {
            lastDesired = desired;
            lastAttempt = 0;
        }
        const bool needsApply = desired != lastApplied;
        const DWORD intervalMs = needsApply ? Policy::kLedRetryMs :
            (mask != 0 ? Policy::kLedActiveRefreshMs : Policy::kLedIdleRefreshMs);
        if (lastAttempt == 0 || now - lastAttempt >= intervalMs) {
            Request request{};
            request.command = Command::Led;
            request.value = desired;
            Reply reply{};
            if (SUCCEEDED(DispatchControlRequest(request, reply))) lastApplied = desired;
            lastAttempt = now;
        }

        previousMask = mask;
        Sleep(Policy::kLedPollMs);
    }

    Request off{};
    off.command = Command::Led;
    off.value = static_cast<int32_t>(Kinect360RemoldControl::LedMode::Off);
    Reply ignored{};
    (void)DispatchControlRequest(off, ignored);
}

void ControlServerLoop(std::atomic<bool>* active) {
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    SECURITY_ATTRIBUTES security{};
    security.nLength = sizeof(security);
    if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
            L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;AU)",
            SDDL_REVISION_1,
            &descriptor,
            nullptr)) {
        security.lpSecurityDescriptor = descriptor;
    }

    while (active->load() && gRun.load()) {
        HANDLE pipe = CreateNamedPipeW(
            Kinect360RemoldControl::kPipeName,
            PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            4,
            sizeof(Reply),
            sizeof(Request),
            1000,
            security.lpSecurityDescriptor ? &security : nullptr);
        if (pipe == INVALID_HANDLE_VALUE) {
            Sleep(250);
            continue;
        }

        BOOL connected = ConnectNamedPipe(pipe, nullptr);
        if (!connected && GetLastError() == ERROR_PIPE_CONNECTED) connected = TRUE;
        if (connected) {
            Request request{};
            DWORD read = 0;
            if (ReadFile(pipe, &request, sizeof(request), &read, nullptr) && read == sizeof(request)) {
                Reply reply{};
                const HRESULT hr = DispatchControlRequest(request, reply);
                reply.result = static_cast<int32_t>(hr);
                reply.cameraActivityMask = CurrentCameraActivityMask();
                DWORD written = 0;
                (void)WriteFile(pipe, &reply, sizeof(reply), &written, nullptr);
                (void)FlushFileBuffers(pipe);
            }
            (void)DisconnectNamedPipe(pipe);
        }
        CloseHandle(pipe);
    }
    if (descriptor) LocalFree(descriptor);
}

void WakeControlServer() {
    if (!WaitNamedPipeW(Kinect360RemoldControl::kPipeName, 100)) return;
    HANDLE pipe = CreateFileW(
        Kinect360RemoldControl::kPipeName,
        GENERIC_READ | GENERIC_WRITE,
        0,
        nullptr,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        nullptr);
    if (pipe == INVALID_HANDLE_VALUE) return;
    Request request{};
    request.command = Command::Ping;
    DWORD written = 0;
    (void)WriteFile(pipe, &request, sizeof(request), &written, nullptr);
    Reply reply{};
    DWORD read = 0;
    (void)ReadFile(pipe, &reply, sizeof(reply), &read, nullptr);
    CloseHandle(pipe);
}

int RunHost() {
    std::atomic<bool> brokerRun{true};
    std::thread controlThread(ControlServerLoop, &brokerRun);
    std::thread ledThread(AutoLedLoop, &brokerRun);
    while (gRun.load()) Sleep(250);
    brokerRun.store(false);
    WakeControlServer();
    if (controlThread.joinable()) controlThread.join();
    if (ledThread.joinable()) ledThread.join();
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
    SetServiceStatus(gServiceHandle, &gServiceStatus);
}

void WINAPI ServiceMain(DWORD, wchar_t**) {
    gServiceHandle = RegisterServiceCtrlHandlerW(L"Kinect360RemoldBroker", ServiceControl);
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

    (void)RunHost();

    gServiceStatus.dwCurrentState = SERVICE_STOPPED;
    gServiceStatus.dwControlsAccepted = 0;
    gServiceStatus.dwCheckPoint = 0;
    gServiceStatus.dwWaitHint = 0;
    SetServiceStatus(gServiceHandle, &gServiceStatus);
}
} // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc > 1 && _wcsicmp(argv[1], L"--console") == 0) {
        gRun.store(true);
        return RunHost();
    }

    SERVICE_TABLE_ENTRYW table[] = {
        { const_cast<LPWSTR>(L"Kinect360RemoldBroker"), ServiceMain },
        { nullptr, nullptr }
    };
    if (StartServiceCtrlDispatcherW(table)) return 0;

    const DWORD error = GetLastError();
    if (error == ERROR_FAILED_SERVICE_CONTROLLER_CONNECT) {
        gRun.store(true);
        return RunHost();
    }
    return static_cast<int>(error);
}
